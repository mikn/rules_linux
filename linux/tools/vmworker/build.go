package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// defconfigPattern is the allowlist for safe defconfig values.
// Only alphanumeric characters and underscores are permitted to prevent
// shell injection when the value is interpolated into a make command.
var defconfigPattern = regexp.MustCompile(`^[a-zA-Z0-9_]+$`)

// actionArgs holds the parsed per-request build arguments.
type actionArgs struct {
	SourceTarball    string
	Config           string
	Defconfig        string
	ConfigFragments  []string
	Arch             string
	Jobs             int
	ExtraMakeFlags   []string
	OutputVmlinuz    string
	OutputSystemMap  string
	OutputModules    string
	OutputConfig     string
}

// parseActionArgs parses per-request arguments from a string slice.
// These come from WorkRequest.Arguments in persistent mode or from os.Args
// in one-shot mode.
func parseActionArgs(args []string) (actionArgs, error) {
	fs := flag.NewFlagSet("vmworker-action", flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	sourceTarball   := fs.String("source-tarball", "", "")
	config          := fs.String("config", "", "")
	defconfig        := fs.String("defconfig", "", "")
	arch            := fs.String("arch", "x86_64", "")
	jobs            := fs.Int("jobs", 0, "")
	outputVmlinuz   := fs.String("output-vmlinuz", "", "")
	outputSystemMap := fs.String("output-system-map", "", "")
	outputModules   := fs.String("output-modules", "", "")
	outputConfig    := fs.String("output-config", "", "")

	// --config-fragment and --extra-make-flag are repeatable (singular form, one value per flag).
	var fragments []string
	fs.Func("config-fragment", "", func(v string) error {
		fragments = append(fragments, v)
		return nil
	})
	var extraMakeFlags []string
	fs.Func("extra-make-flag", "", func(v string) error {
		extraMakeFlags = append(extraMakeFlags, v)
		return nil
	})

	if err := fs.Parse(args); err != nil {
		return actionArgs{}, fmt.Errorf("parseActionArgs: %w", err)
	}

	a := actionArgs{
		SourceTarball:   *sourceTarball,
		Config:          *config,
		Defconfig:       *defconfig,
		ConfigFragments: fragments,
		Arch:            normaliseArch(*arch),
		Jobs:            *jobs,
		ExtraMakeFlags:  extraMakeFlags,
		OutputVmlinuz:   *outputVmlinuz,
		OutputSystemMap: *outputSystemMap,
		OutputModules:   *outputModules,
		OutputConfig:    *outputConfig,
	}

	if err := validateActionArgs(a); err != nil {
		return actionArgs{}, err
	}
	return a, nil
}

func validateActionArgs(a actionArgs) error {
	if a.SourceTarball == "" {
		return fmt.Errorf("--source-tarball is required")
	}
	if a.Config == "" && a.Defconfig == "" {
		return fmt.Errorf("either --config or --defconfig is required")
	}
	if a.Config != "" && a.Defconfig != "" {
		return fmt.Errorf("--config and --defconfig are mutually exclusive")
	}
	if a.Defconfig != "" && !defconfigPattern.MatchString(a.Defconfig) {
		return fmt.Errorf("--defconfig %q contains invalid characters: only alphanumeric and underscore are allowed", a.Defconfig)
	}
	if a.OutputVmlinuz == "" {
		return fmt.Errorf("--output-vmlinuz is required")
	}
	if a.OutputSystemMap == "" {
		return fmt.Errorf("--output-system-map is required")
	}
	if a.OutputModules == "" {
		return fmt.Errorf("--output-modules is required")
	}
	if a.OutputConfig == "" {
		return fmt.Errorf("--output-config is required")
	}
	if a.Arch != "x86_64" && a.Arch != "arm64" {
		return fmt.Errorf("unsupported --arch %q: must be x86_64 or arm64", a.Arch)
	}
	return nil
}

// normaliseArch canonicalises arch aliases to the two canonical forms.
func normaliseArch(arch string) string {
	switch arch {
	case "amd64":
		return "x86_64"
	case "aarch64":
		return "arm64"
	default:
		return arch
	}
}

// multiarchLibDir returns the Debian-style multiarch library directory for the
// given canonical arch (e.g., "x86_64-linux-gnu" for x86_64, "aarch64-linux-gnu"
// for arm64). This is used in HOSTCFLAGS/HOSTLDFLAGS sysroot paths.
func multiarchLibDir(arch string) string {
	if arch == "arm64" {
		return "aarch64-linux-gnu"
	}
	return "x86_64-linux-gnu"
}

// karchForArch maps the canonical arch to the kernel ARCH= value.
func karchForArch(arch string) string {
	if arch == "arm64" {
		return "arm64"
	}
	return "x86"
}

// kernelImageForArch returns the make target and the relative source path for
// the built kernel image.
func kernelImageForArch(arch string) (target, path string) {
	if arch == "arm64" {
		return "Image", "arch/arm64/boot/Image"
	}
	return "bzImage", "arch/x86/boot/bzImage"
}

// jobsFlag returns the make -j argument string.
// 0 means "use nproc" (let the shell expand it).
func jobsFlag(jobs int) string {
	if jobs > 0 {
		return fmt.Sprintf("-j%d", jobs)
	}
	return "-j$(nproc)"
}

// execute runs a single kernel build action inside the running VM.
// Must be called with w.mu held and only when w.agent != nil.
func (w *VMWorker) execute(req WorkRequest, output *strings.Builder) (WorkResponse, error) {
	args, err := parseActionArgs(req.Arguments)
	if err != nil {
		// Argument errors are the caller's fault; return an error response, not
		// a transport-level error.
		return WorkResponse{ExitCode: 1, Output: err.Error()}, nil
	}

	ctx := context.Background()

	// 1. Clear staging dirs on the host.
	if err := clearDir(w.inputDir); err != nil {
		return WorkResponse{}, fmt.Errorf("clearing input dir: %w", err)
	}
	if err := clearDir(w.outputDir); err != nil {
		return WorkResponse{}, fmt.Errorf("clearing output dir: %w", err)
	}

	// 2. Stage the kernel source tarball into the 9P input share.
	absTarball, err := filepath.Abs(args.SourceTarball)
	if err != nil {
		return WorkResponse{}, fmt.Errorf("resolving source tarball: %w", err)
	}
	if err := copyFile(absTarball, filepath.Join(w.inputDir, "kernel.tar")); err != nil {
		return WorkResponse{}, fmt.Errorf("staging source tarball: %w", err)
	}

	// 3. Stage .config file if provided.
	if args.Config != "" {
		absConfig, err := filepath.Abs(args.Config)
		if err != nil {
			return WorkResponse{}, fmt.Errorf("resolving --config: %w", err)
		}
		if err := copyFile(absConfig, filepath.Join(w.inputDir, ".config")); err != nil {
			return WorkResponse{}, fmt.Errorf("staging .config: %w", err)
		}
	}

	// 4. Stage config fragments.
	for i, frag := range args.ConfigFragments {
		absFrag, err := filepath.Abs(frag)
		if err != nil {
			return WorkResponse{}, fmt.Errorf("resolving fragment %d: %w", i, err)
		}
		if err := copyFile(absFrag, filepath.Join(w.inputDir, fmt.Sprintf("fragment-%d", i))); err != nil {
			return WorkResponse{}, fmt.Errorf("staging fragment %d: %w", i, err)
		}
	}

	// 5. Clean the kernel build tree inside the VM (ccache is preserved).
	if err := w.guestExec(ctx, "rm -rf /build/linux && mkdir -p /build/linux", 60, output); err != nil {
		return WorkResponse{}, fmt.Errorf("cleaning build tree: %w", err)
	}

	// 6. Extract kernel source.
	if err := w.guestExec(ctx, "tar xf /mnt/input/kernel.tar --strip-components=1 -C /build/linux", 300, output); err != nil {
		return WorkResponse{}, fmt.Errorf("extracting kernel source: %w", err)
	}

	// 7. Configure the kernel.
	karch := karchForArch(args.Arch)
	if err := w.configureKernel(ctx, karch, args, output); err != nil {
		return WorkResponse{}, fmt.Errorf("configuring kernel: %w", err)
	}

	// 8. Detect whether the config has modules enabled.
	hasModules := false
	modResp, err := w.agent.Exec(ctx, "grep -q '^CONFIG_MODULES=y' /build/linux/.config && echo yes || echo no", 10)
	if err != nil {
		return WorkResponse{}, fmt.Errorf("checking CONFIG_MODULES: %w", err)
	}
	if strings.TrimSpace(modResp.Stdout) == "yes" {
		hasModules = true
	}

	// 9. Build the kernel.
	imageTarget, imagePath := kernelImageForArch(args.Arch)
	targets := imageTarget
	if hasModules {
		targets += " modules"
	}

	extraFlags := ""
	if len(args.ExtraMakeFlags) > 0 {
		extraFlags = " " + strings.Join(args.ExtraMakeFlags, " ")
	}

	multiarch := multiarchLibDir(args.Arch)

	// PATH: toolchain first, then standard system paths.
	// HOSTCFLAGS/HOSTLDFLAGS point host tools at the sysroot for libelf, etc.
	buildCmd := fmt.Sprintf(
		"export PATH=/build/toolchain/bin:/build/sysroot/usr/bin:/build/sysroot/usr/sbin:/usr/bin:/bin && "+
			"cd /build/linux && "+
			"CCACHE_DIR=/build/ccache "+
			"CCACHE_MAXSIZE=10G "+
			"CCACHE_BASEDIR=/build/linux "+
			"make LLVM=1 ARCH=%s "+
			"CC='ccache clang' HOSTCC='ccache clang' "+
			"HOSTCFLAGS='--sysroot=/build/sysroot -I/build/sysroot/usr/include -I/build/sysroot/usr/include/%s' "+
			"HOSTLDFLAGS='-L/build/sysroot/usr/lib/%s' "+
			"%s %s%s 2>&1",
		karch,
		multiarch,
		multiarch,
		jobsFlag(args.Jobs),
		targets,
		extraFlags,
	)
	if err := w.guestExec(ctx, buildCmd, 3300, output); err != nil { // 55-minute timeout
		return WorkResponse{}, fmt.Errorf("kernel build: %w", err)
	}

	// 10. Copy outputs to the 9P output share.
	outputSteps := []struct {
		cmd     string
		timeout int
	}{
		{fmt.Sprintf("cp /build/linux/%s /mnt/output/vmlinuz", imagePath), 30},
		{"cp /build/linux/System.map /mnt/output/System.map", 30},
		{"cp /build/linux/.config /mnt/output/.config", 30},
	}
	if hasModules {
		outputSteps = append(outputSteps,
			struct {
				cmd     string
				timeout int
			}{
				fmt.Sprintf(
					"export PATH=/build/toolchain/bin:/build/sysroot/usr/bin:/build/sysroot/usr/sbin:/usr/bin:/bin && "+
						"make -C /build/linux LLVM=1 ARCH=%s modules_install INSTALL_MOD_PATH=/mnt/output/modules 2>&1",
					karch,
				),
				300,
			},
			struct {
				cmd     string
				timeout int
			}{
				"tar cf /mnt/output/modules.tar -C /mnt/output/modules .",
				120,
			},
		)
	} else {
		outputSteps = append(outputSteps, struct {
			cmd     string
			timeout int
		}{"tar cf /mnt/output/modules.tar --files-from /dev/null", 10})
	}

	for _, step := range outputSteps {
		if err := w.guestExec(ctx, step.cmd, step.timeout, output); err != nil {
			return WorkResponse{}, fmt.Errorf("collecting outputs: %w", err)
		}
	}

	// 11. Copy outputs from the host-side 9P share to the Bazel-declared paths.
	copies := []struct{ src, dst string }{
		{filepath.Join(w.outputDir, "vmlinuz"), args.OutputVmlinuz},
		{filepath.Join(w.outputDir, "System.map"), args.OutputSystemMap},
		{filepath.Join(w.outputDir, "modules.tar"), args.OutputModules},
		{filepath.Join(w.outputDir, ".config"), args.OutputConfig},
	}
	for _, c := range copies {
		if err := copyFile(c.src, c.dst); err != nil {
			return WorkResponse{}, fmt.Errorf("finalising output %s: %w", filepath.Base(c.dst), err)
		}
	}

	return WorkResponse{ExitCode: 0}, nil
}

// configureKernel sets up the kernel .config inside the VM.
// It handles both --config (explicit file) and --defconfig (named config) paths.
func (w *VMWorker) configureKernel(ctx context.Context, karch string, args actionArgs, output *strings.Builder) error {
	pathPrefix := "export PATH=/build/toolchain/bin:/build/sysroot/usr/bin:/build/sysroot/usr/sbin:/usr/bin:/bin && "

	if args.Defconfig != "" {
		// defconfig is already validated against defconfigPattern; safe to interpolate.
		cmd := fmt.Sprintf("%smake -C /build/linux ARCH=%s LLVM=1 %s 2>&1", pathPrefix, karch, args.Defconfig)
		if err := w.guestExec(ctx, cmd, 120, output); err != nil {
			return fmt.Errorf("make %s: %w", args.Defconfig, err)
		}
	} else {
		if err := w.guestExec(ctx, "cp /mnt/input/.config /build/linux/.config", 30, output); err != nil {
			return fmt.Errorf("copying .config: %w", err)
		}
	}

	// Apply each config fragment by appending it to .config.
	// The trailing newline echo prevents the last line from being silently ignored
	// by the subsequent olddefconfig pass.
	for i := range args.ConfigFragments {
		fragPath := fmt.Sprintf("/mnt/input/fragment-%d", i)
		appendCmd := fmt.Sprintf("cat %s >> /build/linux/.config && echo >> /build/linux/.config", fragPath)
		if err := w.guestExec(ctx, appendCmd, 30, output); err != nil {
			return fmt.Errorf("appending fragment %d: %w", i, err)
		}
	}

	// Resolve any conflicts and fill in defaults.
	resolveCmd := fmt.Sprintf("%smake -C /build/linux ARCH=%s LLVM=1 olddefconfig 2>&1", pathPrefix, karch)
	if err := w.guestExec(ctx, resolveCmd, 120, output); err != nil {
		return fmt.Errorf("olddefconfig: %w", err)
	}

	return nil
}

// clearDir removes all entries inside dir without removing dir itself.
func clearDir(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("clearDir %s: %w", dir, err)
	}
	for _, e := range entries {
		if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil {
			return fmt.Errorf("clearDir %s: removing %s: %w", dir, e.Name(), err)
		}
	}
	return nil
}

// copyFile copies src to dst using streaming I/O (no full-file RAM buffer),
// creating dst's parent directories as needed.
func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return fmt.Errorf("copyFile: mkdir %s: %w", filepath.Dir(dst), err)
	}
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("copyFile: opening %s: %w", src, err)
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("copyFile: creating %s: %w", dst, err)
	}

	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return fmt.Errorf("copyFile: %s -> %s: %w", src, dst, err)
	}
	if err := out.Close(); err != nil {
		return fmt.Errorf("copyFile: closing %s: %w", dst, err)
	}
	return nil
}

// runQemuImg runs qemu-img with the given arguments and returns any error
// along with the combined output.
func runQemuImg(qemuImg string, args ...string) error {
	cmd := exec.Command(qemuImg, args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%w\n%s", err, string(out))
	}
	return nil
}
