// vmbuilder boots a QEMU VM, builds a Linux kernel inside it, and extracts outputs.
// Used by kernel_build on macOS where the kernel cannot be built natively.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/mikn/rules_qemu/vm"
)

var (
	flagQemu             = flag.String("qemu", "", "Path to qemu-system binary (default: qemu-system-{arch} on PATH)")
	flagKernel           = flag.String("kernel", "", "Bootstrap kernel (vmlinuz)")
	flagInitrd           = flag.String("initrd", "", "Bootstrap rootfs initrd")
	flagSourceTarball    = flag.String("source-tarball", "", "Kernel source tarball (.tar.xz, .tar.gz, etc.)")
	flagConfig           = flag.String("config", "", "Kernel .config file (mutually exclusive with --defconfig)")
	flagDefconfig        = flag.String("defconfig", "", "Defconfig target, e.g. defconfig, tinyconfig (mutually exclusive with --config)")
	flagArch             = flag.String("arch", "x86_64", "Target architecture: x86_64 or arm64")
	flagOutputVmlinuz    = flag.String("output-vmlinuz", "", "Output path for vmlinuz")
	flagOutputSystemMap  = flag.String("output-system-map", "", "Output path for System.map")
	flagOutputModulesTar = flag.String("output-modules-tar", "", "Output path for modules.tar")
	flagOutputConfig     = flag.String("output-config", "", "Output path for .config")
	flagMemory           = flag.String("memory", "8G", "VM memory (e.g. 4G, 8G)")
	flagCPUs             = flag.Int("cpus", 0, "VM CPU count (0 = runtime.NumCPU())")
	flagJobs             = flag.Int("jobs", 0, "make -j (0 = same as cpus)")
	flagConfigFragments  = flag.String("config-fragments", "", "Comma-separated paths to config fragment files")
	flagAccel            = flag.String("accel", "kvm", "QEMU accelerator: kvm, hvf, tcg")
	flagMachineType      = flag.String("machine-type", "", "QEMU machine type (e.g. q35, virt). Empty = QEMU default.")
	flagBuildTimeout     = flag.Duration("build-timeout", 55*time.Minute, "Per-command timeout for the kernel build step (0 = no limit)")
	flagTimeout          = flag.Duration("timeout", 60*time.Minute, "Overall timeout for the entire VM build (0 = no limit)")
)

func main() {
	flag.Parse()

	if err := run(); err != nil {
		log.Fatalf("vmbuilder: %v", err)
	}
}

func run() error {
	if *flagKernel == "" {
		return fmt.Errorf("--kernel is required")
	}
	if *flagInitrd == "" {
		return fmt.Errorf("--initrd is required")
	}
	if *flagSourceTarball == "" {
		return fmt.Errorf("--source-tarball is required")
	}
	if *flagConfig == "" && *flagDefconfig == "" {
		return fmt.Errorf("either --config or --defconfig is required")
	}
	if *flagConfig != "" && *flagDefconfig != "" {
		return fmt.Errorf("--config and --defconfig are mutually exclusive")
	}
	if *flagOutputVmlinuz == "" {
		return fmt.Errorf("--output-vmlinuz is required")
	}
	if *flagOutputSystemMap == "" {
		return fmt.Errorf("--output-system-map is required")
	}
	if *flagOutputModulesTar == "" {
		return fmt.Errorf("--output-modules-tar is required")
	}
	if *flagOutputConfig == "" {
		return fmt.Errorf("--output-config is required")
	}

	arch := *flagArch
	if arch == "amd64" {
		arch = "x86_64"
	}
	if arch != "x86_64" && arch != "arm64" {
		return fmt.Errorf("unsupported arch %q: must be x86_64 or arm64", arch)
	}

	cpus := *flagCPUs
	if cpus == 0 {
		cpus = runtime.NumCPU()
	}
	jobs := *flagJobs
	if jobs == 0 {
		jobs = cpus
	}

	sourceTarball, err := filepath.Abs(*flagSourceTarball)
	if err != nil {
		return fmt.Errorf("resolving --source-tarball: %w", err)
	}
	tarName := filepath.Base(sourceTarball)

	// Resolve output paths to absolute.
	outputVmlinuz, err := filepath.Abs(*flagOutputVmlinuz)
	if err != nil {
		return fmt.Errorf("resolving --output-vmlinuz: %w", err)
	}
	outputSystemMap, err := filepath.Abs(*flagOutputSystemMap)
	if err != nil {
		return fmt.Errorf("resolving --output-system-map: %w", err)
	}
	outputModulesTar, err := filepath.Abs(*flagOutputModulesTar)
	if err != nil {
		return fmt.Errorf("resolving --output-modules-tar: %w", err)
	}
	outputConfig, err := filepath.Abs(*flagOutputConfig)
	if err != nil {
		return fmt.Errorf("resolving --output-config: %w", err)
	}

	// Create a temp directory shared into the VM as the output share.
	// We write outputs here, then copy to the Bazel-declared paths on the host
	// after the VM exits. This keeps all intermediate files (modules/ dir) out
	// of the Bazel output space.
	tmpOutDir, err := os.MkdirTemp("", "vmbuilder-output-*")
	if err != nil {
		return fmt.Errorf("creating temp output dir: %w", err)
	}
	defer os.RemoveAll(tmpOutDir)

	// Create a staging directory that holds the source tarball (copied), .config,
	// and config fragments. This directory is shared into the VM via 9P.
	stageDir, err := os.MkdirTemp("", "vmbuilder-source-*")
	if err != nil {
		return fmt.Errorf("creating staging dir: %w", err)
	}
	defer os.RemoveAll(stageDir)

	// Copy source tarball into staging. Symlinks to host paths don't resolve
	// inside the guest since the host absolute path doesn't exist there.
	if err := copyFile(sourceTarball, filepath.Join(stageDir, tarName)); err != nil {
		return fmt.Errorf("copying source tarball: %w", err)
	}

	// Stage .config if provided.
	if *flagConfig != "" {
		absConfig, err := filepath.Abs(*flagConfig)
		if err != nil {
			return fmt.Errorf("resolving --config: %w", err)
		}
		if err := copyFile(absConfig, filepath.Join(stageDir, ".config")); err != nil {
			return fmt.Errorf("staging .config: %w", err)
		}
	}

	// Stage config fragments.
	var fragmentNames []string
	if *flagConfigFragments != "" {
		for _, frag := range strings.Split(*flagConfigFragments, ",") {
			frag = strings.TrimSpace(frag)
			if frag == "" {
				continue
			}
			absFrag, err := filepath.Abs(frag)
			if err != nil {
				return fmt.Errorf("resolving fragment path %q: %w", frag, err)
			}
			name := filepath.Base(absFrag)
			if err := copyFile(absFrag, filepath.Join(stageDir, name)); err != nil {
				return fmt.Errorf("staging fragment %q: %w", frag, err)
			}
			fragmentNames = append(fragmentNames, name)
		}
	}

	log.Printf("vmbuilder: starting VM (arch=%s cpus=%d memory=%s jobs=%d accel=%s)", arch, cpus, *flagMemory, jobs, *flagAccel)

	var ctx context.Context
	var cancel context.CancelFunc
	if *flagTimeout > 0 {
		ctx, cancel = context.WithTimeout(context.Background(), *flagTimeout)
	} else {
		ctx, cancel = context.WithCancel(context.Background())
	}
	defer cancel()

	opts := []vm.Option{
		vm.WithKernelBoot(*flagKernel, *flagInitrd, kernelCmdline()),
		vm.WithMemory(*flagMemory),
		vm.WithCPUs(cpus),
		vm.WithAccel(*flagAccel),
		vm.WithNoNetwork(),
		vm.WithSerialCapture(),
		vm.WithAgent(),
		vm.WithQMP(),
		vm.With9PShare("source", stageDir),
		vm.With9PShare("output", tmpOutDir),
	}
	if *flagQemu != "" {
		opts = append(opts, vm.WithQemuBinary(*flagQemu))
	}
	if *flagMachineType != "" {
		opts = append(opts, vm.WithMachineType(*flagMachineType))
	}

	machine, err := vm.Start(ctx, opts...)
	if err != nil {
		return fmt.Errorf("starting VM: %w", err)
	}
	defer machine.Kill() //nolint:errcheck

	// Forward serial output to stderr so the build log is visible in Bazel.
	if serial := machine.Serial(); serial != nil {
		serial.OnLine(func(line string) {
			log.Printf("[vm] %s", line)
		})
	}

	log.Printf("vmbuilder: connecting to agent")
	agent, err := vm.ConnectAgent(ctx, machine.AgentSocketPath())
	if err != nil {
		return fmt.Errorf("connecting to agent: %w", err)
	}
	defer agent.Close() //nolint:errcheck

	// Mount 9P shares.
	if err := execGuest(ctx, agent, "mkdir -p /mnt/source /mnt/output /build", 30); err != nil {
		return fmt.Errorf("creating mount points: %w", err)
	}
	if err := execGuest(ctx, agent, "mount -t 9p -o trans=virtio,version=9p2000.L source /mnt/source", 30); err != nil {
		return fmt.Errorf("mounting source: %w", err)
	}
	if err := execGuest(ctx, agent, "mount -t 9p -o trans=virtio,version=9p2000.L output /mnt/output", 30); err != nil {
		return fmt.Errorf("mounting output: %w", err)
	}

	// Extract kernel source using the exact tarball name, not a shell glob.
	log.Printf("vmbuilder: extracting kernel source")
	if err := execGuest(ctx, agent, fmt.Sprintf("tar xf /mnt/source/%s -C /build --strip-components=1", tarName), 300); err != nil {
		return fmt.Errorf("extracting kernel source: %w", err)
	}

	// Configure kernel.
	log.Printf("vmbuilder: configuring kernel")
	if err := configureKernel(ctx, agent, arch, *flagDefconfig, fragmentNames); err != nil {
		return fmt.Errorf("configuring kernel: %w", err)
	}

	// Build kernel.
	log.Printf("vmbuilder: building kernel (jobs=%d)", jobs)
	imageTarget, imagePath := kernelImageForArch(arch)
	karch := karchForArch(arch)

	// Check if modules are enabled — tinyconfig disables them.
	hasModules := false
	resp, err := agent.Exec(ctx, "grep -q '^CONFIG_MODULES=y' /build/.config && echo yes || echo no", 10)
	if err == nil && strings.TrimSpace(resp.Stdout) == "yes" {
		hasModules = true
	}

	targets := imageTarget
	if hasModules {
		targets += " modules"
	}
	buildCmd := fmt.Sprintf(
		"make -C /build ARCH=%s LLVM=1 -j%d %s 2>&1",
		karch, jobs, targets,
	)
	buildTimeoutSecs := int(*flagBuildTimeout / time.Second)
	if *flagBuildTimeout <= 0 {
		buildTimeoutSecs = 0 // agent treats 0 as no timeout
	}
	if err := execGuest(ctx, agent, buildCmd, buildTimeoutSecs); err != nil {
		return fmt.Errorf("kernel build: %w", err)
	}

	// Copy outputs to /mnt/output. Module installation uses a subdirectory
	// inside the temp output dir; the tarball is created there. Only the
	// final files are copied to Bazel-declared paths on the host after VM exit.
	log.Printf("vmbuilder: copying outputs")
	outputSteps := []struct {
		cmd     string
		timeout int
	}{
		{fmt.Sprintf("cp /build/%s /mnt/output/vmlinuz", imagePath), 30},
		{"cp /build/System.map /mnt/output/System.map", 30},
		{"cp /build/.config /mnt/output/.config", 30},
	}
	if hasModules {
		outputSteps = append(outputSteps,
			struct {
				cmd     string
				timeout int
			}{fmt.Sprintf("make -C /build ARCH=%s LLVM=1 modules_install INSTALL_MOD_PATH=/mnt/output/modules 2>&1", karch), 300},
			struct {
				cmd     string
				timeout int
			}{"tar cf /mnt/output/modules.tar -C /mnt/output/modules .", 120},
		)
	} else {
		// Create an empty modules tarball so the output path always exists.
		outputSteps = append(outputSteps,
			struct {
				cmd     string
				timeout int
			}{"tar cf /mnt/output/modules.tar --files-from /dev/null", 10},
		)
	}
	for _, step := range outputSteps {
		if err := execGuest(ctx, agent, step.cmd, step.timeout); err != nil {
			return fmt.Errorf("copying outputs (%s): %w", step.cmd, err)
		}
	}

	// Shut down the VM. The bootstrap init has no ACPI daemon, so use QMP quit
	// (immediate QEMU exit) instead of ACPI powerdown which would hang.
	log.Printf("vmbuilder: shutting down VM")
	if qmp := machine.QMP(); qmp != nil {
		if err := qmp.Quit(); err != nil {
			log.Printf("vmbuilder: QMP quit: %v (killing)", err)
			machine.Kill()
		}
	} else {
		machine.Kill()
	}
	_ = machine.Wait()

	// Copy outputs from the temp dir to the Bazel-declared paths.
	log.Printf("vmbuilder: writing Bazel outputs")
	copies := []struct{ src, dst string }{
		{filepath.Join(tmpOutDir, "vmlinuz"), outputVmlinuz},
		{filepath.Join(tmpOutDir, "System.map"), outputSystemMap},
		{filepath.Join(tmpOutDir, "modules.tar"), outputModulesTar},
		{filepath.Join(tmpOutDir, ".config"), outputConfig},
	}
	for _, c := range copies {
		if err := copyFile(c.src, c.dst); err != nil {
			return fmt.Errorf("finalising output %s: %w", filepath.Base(c.dst), err)
		}
	}

	log.Printf("vmbuilder: done")
	return nil
}

// execGuest runs a shell command in the guest via the agent RPC and returns
// an error (with combined stdout+stderr) if the exit code is non-zero.
// timeoutSecs is passed to the agent; 0 means no per-command timeout.
func execGuest(ctx context.Context, agent *vm.AgentConn, cmd string, timeoutSecs int) error {
	log.Printf("vmbuilder: exec: %s", cmd)
	resp, err := agent.Exec(ctx, cmd, timeoutSecs)
	if err != nil {
		return fmt.Errorf("exec %q: %w", cmd, err)
	}
	if resp.Stdout != "" {
		for _, line := range strings.Split(strings.TrimRight(resp.Stdout, "\n"), "\n") {
			log.Printf("[guest] %s", line)
		}
	}
	if resp.Stderr != "" {
		for _, line := range strings.Split(strings.TrimRight(resp.Stderr, "\n"), "\n") {
			log.Printf("[guest stderr] %s", line)
		}
	}
	if resp.ExitCode != 0 {
		return fmt.Errorf("command exited %d: %s", resp.ExitCode, cmd)
	}
	return nil
}

// configureKernel sets up the .config in the build tree and resolves it.
// If defconfig is non-empty, it runs make <defconfig> first. Otherwise it
// copies the staged .config. Then appends any fragments and runs olddefconfig.
//
// Note: fragments are applied with `cat >>` followed by `olddefconfig` to
// resolve conflicts deterministically (same behaviour as the native path).
func configureKernel(ctx context.Context, agent *vm.AgentConn, arch, defconfig string, fragmentNames []string) error {
	karch := karchForArch(arch)

	if defconfig != "" {
		// Generate config from defconfig target.
		cmd := fmt.Sprintf("make -C /build ARCH=%s LLVM=1 %s 2>&1", karch, defconfig)
		if err := execGuest(ctx, agent, cmd, 120); err != nil {
			return fmt.Errorf("make %s: %w", defconfig, err)
		}
	} else {
		// Copy the provided .config file.
		if err := execGuest(ctx, agent, "cp /mnt/source/.config /build/.config", 30); err != nil {
			return fmt.Errorf("copying .config: %w", err)
		}
	}

	// Append each config fragment to .config.
	for _, name := range fragmentNames {
		fragPath := "/mnt/source/" + name
		appendCmd := fmt.Sprintf("cat %s >> /build/.config", fragPath)
		if err := execGuest(ctx, agent, appendCmd, 30); err != nil {
			return fmt.Errorf("appending fragment %q: %w", name, err)
		}
	}

	// Resolve the config — handles conflicts and new symbols deterministically.
	resolveCmd := fmt.Sprintf("make -C /build ARCH=%s LLVM=1 olddefconfig 2>&1", karch)
	if err := execGuest(ctx, agent, resolveCmd, 120); err != nil {
		return fmt.Errorf("olddefconfig: %w", err)
	}

	return nil
}

// kernelCmdline returns the boot command line for the builder VM.
func kernelCmdline() string {
	return "console=ttyS0 panic=1 quiet"
}

// karchForArch maps the canonical arch name to the kernel ARCH= value.
func karchForArch(arch string) string {
	switch arch {
	case "arm64":
		return "arm64"
	default:
		return "x86"
	}
}

// kernelImageForArch returns the make target and relative path for the kernel image.
func kernelImageForArch(arch string) (target, path string) {
	switch arch {
	case "arm64":
		return "Image", "arch/arm64/boot/Image"
	default:
		return "bzImage", "arch/x86/boot/bzImage"
	}
}

// copyFile copies src to dst, creating dst if needed.
func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("reading %s: %w", src, err)
	}
	if err := os.WriteFile(dst, data, 0644); err != nil {
		return fmt.Errorf("writing %s: %w", dst, err)
	}
	return nil
}
