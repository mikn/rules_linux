package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mikn/rules_qemu/vm"
)

// WorkRequest is the JSON structure sent by Bazel for each build action.
type WorkRequest struct {
	Arguments []string `json:"arguments"`
	Inputs    []Input  `json:"inputs"`
	RequestID int      `json:"requestId"`
}

// Input describes a declared input file for the action.
type Input struct {
	Path   string `json:"path"`
	Digest string `json:"digest"`
}

// WorkResponse is written back to Bazel after each action completes.
type WorkResponse struct {
	ExitCode  int    `json:"exitCode"`
	Output    string `json:"output"`
	RequestID int    `json:"requestId"`
}

// workerConfig holds startup configuration read once from environment variables.
type workerConfig struct {
	kernel       string
	initrd       string
	toolchainTar string
	sysrootTar   string
	memory       string
	cpus         int
	qemuSystem   string
	qemuImg      string
	ccacheDir    string
	idleTimeout  time.Duration
}

// VMWorker manages a long-lived QEMU VM and serves kernel build requests.
type VMWorker struct {
	cfg        workerConfig
	mu         sync.Mutex
	machine    *vm.VM
	agent      *vm.AgentConn
	inputDir   string
	outputDir  string
	tempDiskDir string // non-empty when ccacheDir is empty; cleaned up on shutdown
	lastUsed   time.Time
	stopIdle   chan struct{}
}

// newVMWorker reads configuration from environment variables and returns a
// ready-to-use worker. The VM is not started until the first request arrives.
func newVMWorker() (*VMWorker, error) {
	cfg, err := readWorkerConfig()
	if err != nil {
		return nil, fmt.Errorf("newVMWorker: %w", err)
	}

	inputDir, err := os.MkdirTemp("", "vmworker-input-*")
	if err != nil {
		return nil, fmt.Errorf("newVMWorker: creating input dir: %w", err)
	}
	outputDir, err := os.MkdirTemp("", "vmworker-output-*")
	if err != nil {
		os.RemoveAll(inputDir)
		return nil, fmt.Errorf("newVMWorker: creating output dir: %w", err)
	}

	w := &VMWorker{
		cfg:       cfg,
		inputDir:  inputDir,
		outputDir: outputDir,
		stopIdle:  make(chan struct{}),
	}

	go w.idleReaper()
	return w, nil
}

// readWorkerConfig reads startup configuration from environment variables.
func readWorkerConfig() (workerConfig, error) {
	cfg := workerConfig{}

	cfg.kernel = os.Getenv("VMWORKER_KERNEL")
	if cfg.kernel == "" {
		return cfg, fmt.Errorf("VMWORKER_KERNEL is required")
	}
	cfg.initrd = os.Getenv("VMWORKER_INITRD")
	if cfg.initrd == "" {
		return cfg, fmt.Errorf("VMWORKER_INITRD is required")
	}
	cfg.toolchainTar = os.Getenv("VMWORKER_TOOLCHAIN_TAR")
	if cfg.toolchainTar == "" {
		return cfg, fmt.Errorf("VMWORKER_TOOLCHAIN_TAR is required")
	}
	// sysroot is optional — empty means no sysroot extraction.
	cfg.sysrootTar = os.Getenv("VMWORKER_SYSROOT_TAR")

	cfg.memory = os.Getenv("VMWORKER_MEMORY")
	if cfg.memory == "" {
		cfg.memory = "8G"
	}

	cpusStr := os.Getenv("VMWORKER_CPUS")
	if cpusStr != "" {
		n, err := strconv.Atoi(cpusStr)
		if err != nil {
			return cfg, fmt.Errorf("VMWORKER_CPUS: %w", err)
		}
		cfg.cpus = n
	}
	if cfg.cpus == 0 {
		cfg.cpus = runtime.NumCPU()
	}

	cfg.qemuSystem = os.Getenv("VMWORKER_QEMU_SYSTEM")
	cfg.qemuImg = os.Getenv("VMWORKER_QEMU_IMG")
	cfg.ccacheDir = os.Getenv("VMWORKER_CCACHE_DIR")

	idleStr := os.Getenv("VMWORKER_IDLE_TIMEOUT")
	if idleStr == "" {
		idleStr = "5m"
	}
	d, err := time.ParseDuration(idleStr)
	if err != nil {
		return cfg, fmt.Errorf("VMWORKER_IDLE_TIMEOUT: %w", err)
	}
	cfg.idleTimeout = d

	return cfg, nil
}

// handleRequest executes a single build action and returns the response.
// It is safe to call concurrently but singleplex: the internal mutex means
// only one build runs at a time (matching Bazel's singleplex worker protocol).
func (w *VMWorker) handleRequest(req WorkRequest) WorkResponse {
	w.mu.Lock()
	defer w.mu.Unlock()

	var output strings.Builder

	// Ensure VM is running.
	if w.machine == nil || w.agent == nil {
		log.Printf("booting VM")
		if err := w.bootVM(&output); err != nil {
			return WorkResponse{
				ExitCode:  1,
				Output:    fmt.Sprintf("VM boot failed: %v\n%s", err, output.String()),
				RequestID: req.RequestID,
			}
		}
	}

	w.lastUsed = time.Now()

	resp, err := w.execute(req, &output)
	if err != nil {
		// On agent/connection failure, mark VM as dead so next request reboots.
		log.Printf("execute failed: %v — marking VM dead", err)
		w.killVM()
		return WorkResponse{
			ExitCode:  1,
			Output:    fmt.Sprintf("%v\n%s", err, output.String()),
			RequestID: req.RequestID,
		}
	}

	w.lastUsed = time.Now()
	resp.RequestID = req.RequestID
	return resp
}

// bootVM starts the QEMU VM and connects the agent.
// Must be called with w.mu held.
func (w *VMWorker) bootVM(output *strings.Builder) error {
	scratchPath, err := w.resolveScratchDisk(output)
	if err != nil {
		return fmt.Errorf("resolving scratch disk: %w", err)
	}

	ctx := context.Background()

	opts := []vm.Option{
		vm.WithKernelBoot(w.cfg.kernel, w.cfg.initrd, "console=ttyS0 panic=1 quiet"),
		vm.WithMemory(w.cfg.memory),
		vm.WithCPUs(w.cfg.cpus),
		vm.WithNoNetwork(),
		vm.WithSerialCapture(),
		vm.WithAgent(),
		vm.WithQMP(),
		vm.With9PShare("input", w.inputDir),
		vm.With9PShare("output", w.outputDir),
		vm.WithExistingDisk(scratchPath),
		vm.WithDiskFormat("qcow2"),
	}

	if w.cfg.qemuSystem != "" {
		opts = append(opts, vm.WithQemuBinary(w.cfg.qemuSystem))
	}
	if w.cfg.qemuImg != "" {
		opts = append(opts, vm.WithQemuImg(w.cfg.qemuImg))
	}

	machine, err := vm.Start(ctx, opts...)
	if err != nil {
		return fmt.Errorf("vm.Start: %w", err)
	}

	// Forward serial lines to stderr for Bazel diagnostics.
	if serial := machine.Serial(); serial != nil {
		serial.OnLine(func(line string) {
			fmt.Fprintf(os.Stderr, "[vm] %s\n", line)
		})
	}

	// Use a bounded context so ConnectAgent never hangs forever.
	connectCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()

	log.Printf("connecting to agent")
	agent, err := vm.ConnectAgent(connectCtx, machine.AgentSocketPath())
	if err != nil {
		machine.Kill() //nolint:errcheck
		return fmt.Errorf("ConnectAgent: %w", err)
	}

	w.machine = machine
	w.agent = agent

	// Guest setup: mount shares, format/mount disk, extract toolchain.
	if err := w.guestSetup(ctx, output); err != nil {
		w.killVM()
		return fmt.Errorf("guest setup: %w", err)
	}

	log.Printf("VM ready")
	return nil
}

// resolveScratchDisk returns the path of the qcow2 scratch disk, creating it
// with qemu-img if it does not already exist.
func (w *VMWorker) resolveScratchDisk(output *strings.Builder) (string, error) {
	var scratchPath string

	if w.cfg.ccacheDir != "" {
		if err := os.MkdirAll(w.cfg.ccacheDir, 0755); err != nil {
			return "", fmt.Errorf("creating ccache dir: %w", err)
		}
		hash, err := startupHash(w.cfg)
		if err != nil {
			return "", fmt.Errorf("computing startup hash: %w", err)
		}
		scratchPath = filepath.Join(w.cfg.ccacheDir, fmt.Sprintf("scratch-%s.qcow2", hash))
	} else {
		// Use a temp dir; disk is lost when the worker exits.
		// Store the path so shutdown() can clean it up.
		if w.tempDiskDir == "" {
			tmpDir, err := os.MkdirTemp("", "vmworker-disk-*")
			if err != nil {
				return "", fmt.Errorf("creating temp disk dir: %w", err)
			}
			w.tempDiskDir = tmpDir
		}
		scratchPath = filepath.Join(w.tempDiskDir, "scratch.qcow2")
	}

	if _, err := os.Stat(scratchPath); os.IsNotExist(err) {
		fmt.Fprintf(output, "creating scratch disk: %s\n", scratchPath)
		log.Printf("creating qcow2 scratch disk: %s", scratchPath)
		qemuImg := w.cfg.qemuImg
		if qemuImg == "" {
			qemuImg = "qemu-img"
		}
		if err := runQemuImg(qemuImg, "create", "-f", "qcow2", scratchPath, "30G"); err != nil {
			return "", fmt.Errorf("qemu-img create: %w", err)
		}
		return scratchPath, nil
	} else if err != nil {
		return "", fmt.Errorf("stat scratch disk: %w", err)
	}

	log.Printf("reusing existing scratch disk: %s", scratchPath)
	return scratchPath, nil
}

// guestSetup runs inside the VM after boot to mount shares, prepare the scratch
// disk, and extract the toolchain and sysroot on first use.
// Must be called with w.mu held.
func (w *VMWorker) guestSetup(ctx context.Context, output *strings.Builder) error {
	// Create mountpoints and mount 9P shares.
	mounts := []struct {
		cmd     string
		timeout int
		desc    string
	}{
		{"mkdir -p /mnt/input /mnt/output", 10, "creating share mount points"},
		{"mount -t 9p -o trans=virtio,version=9p2000.L input /mnt/input", 30, "mounting input share"},
		{"mount -t 9p -o trans=virtio,version=9p2000.L output /mnt/output", 30, "mounting output share"},
	}
	for _, s := range mounts {
		if err := w.guestExec(ctx, s.cmd, s.timeout, output); err != nil {
			return fmt.Errorf("%s: %w", s.desc, err)
		}
	}

	// Try to mount the scratch disk. If it fails (corrupt/unformatted), format it first.
	mountCmd := "mount /dev/vda /build"
	mountExit, err := w.guestExecAllowFail(ctx, mountCmd, 30, output)
	if err != nil {
		return fmt.Errorf("probing scratch disk mount: %w", err)
	}
	if mountExit != 0 {
		log.Printf("scratch disk mount exited %d — formatting", mountExit)
		if err := w.guestExec(ctx, "mkfs.ext4 /dev/vda", 60, output); err != nil {
			return fmt.Errorf("mkfs.ext4: %w", err)
		}
		if err := w.guestExec(ctx, mountCmd, 30, output); err != nil {
			return fmt.Errorf("mounting scratch disk after format: %w", err)
		}
	}

	// Ensure base layout directories exist.
	if err := w.guestExec(ctx, "mkdir -p /build/linux /build/ccache /build/toolchain /build/sysroot", 10, output); err != nil {
		return fmt.Errorf("creating build dirs: %w", err)
	}

	// Compute the current toolchain hash and compare against what is stored on
	// the disk. If the stored hash differs (or is absent), wipe and re-extract.
	currentHash, err := startupHash(w.cfg)
	if err != nil {
		return fmt.Errorf("computing startup hash for marker: %w", err)
	}

	const markerPath = "/build/.toolchain_hash"
	markerNeedsUpdate := false

	// Read the stored hash from the guest.
	readHashCmd := fmt.Sprintf("cat %s 2>/dev/null", markerPath)
	readResp, err := w.agent.Exec(ctx, readHashCmd, 10)
	if err != nil {
		return fmt.Errorf("reading toolchain hash marker: %w", err)
	}
	storedHash := strings.TrimSpace(readResp.Stdout)

	if storedHash != currentHash {
		log.Printf("toolchain hash changed (%q → %q) — wiping and re-extracting", storedHash, currentHash)
		wipeCmd := "rm -rf /build/toolchain /build/sysroot && mkdir -p /build/toolchain /build/sysroot"
		if err := w.guestExec(ctx, wipeCmd, 60, output); err != nil {
			return fmt.Errorf("wiping stale toolchain/sysroot: %w", err)
		}
		markerNeedsUpdate = true
	}

	// Extract toolchain if absent (first boot or after wipe).
	// The LLVM distribution has bin/clang at its root (not usr/bin/).
	checkToolchain := "test -x /build/toolchain/bin/clang"
	toolchainExit, err := w.guestExecAllowFail(ctx, checkToolchain, 10, output)
	if err != nil {
		return fmt.Errorf("probing toolchain marker: %w", err)
	}
	if toolchainExit != 0 {
		log.Printf("toolchain not found on disk — extracting from 9P share")
		if err := copyFile(w.cfg.toolchainTar, filepath.Join(w.inputDir, "toolchain.tar.xz")); err != nil {
			return fmt.Errorf("staging toolchain tar: %w", err)
		}
		// --strip-components=1: the LLVM distribution tarball has a top-level
		// directory (e.g., LLVM-19.1.7-Linux-X64/) that we want to skip.
		extractCmd := "tar xf /mnt/input/toolchain.tar.xz --strip-components=1 -C /build/toolchain"
		if err := w.guestExec(ctx, extractCmd, 300, output); err != nil {
			return fmt.Errorf("extracting toolchain: %w", err)
		}
		markerNeedsUpdate = true
	}

	// Extract sysroot if absent (first boot or after wipe).
	if w.cfg.sysrootTar != "" {
		checkSysroot := "test -d /build/sysroot/usr/include"
		sysrootExit, err := w.guestExecAllowFail(ctx, checkSysroot, 10, output)
		if err != nil {
			return fmt.Errorf("probing sysroot marker: %w", err)
		}
		if sysrootExit != 0 {
			log.Printf("sysroot not found on disk — extracting from 9P share")
			if err := copyFile(w.cfg.sysrootTar, filepath.Join(w.inputDir, "sysroot.tar")); err != nil {
				return fmt.Errorf("staging sysroot tar: %w", err)
			}
			extractCmd := "tar xf /mnt/input/sysroot.tar -C /build/sysroot"
			if err := w.guestExec(ctx, extractCmd, 300, output); err != nil {
				return fmt.Errorf("extracting sysroot: %w", err)
			}
			markerNeedsUpdate = true
		}
	}

	// Write the current hash as the marker so future boots can skip extraction.
	if markerNeedsUpdate {
		writeCmd := fmt.Sprintf("printf '%%s' '%s' > %s", currentHash, markerPath)
		if err := w.guestExec(ctx, writeCmd, 10, output); err != nil {
			return fmt.Errorf("writing toolchain hash marker: %w", err)
		}
	}

	return nil
}

// killVM forcefully terminates the VM and clears the references.
// Must be called with w.mu held.
func (w *VMWorker) killVM() {
	if w.agent != nil {
		w.agent.Close() //nolint:errcheck
		w.agent = nil
	}
	if w.machine != nil {
		w.machine.Kill() //nolint:errcheck
		_ = w.machine.Wait()
		w.machine = nil
	}
}

// stopVM shuts the VM down gracefully via QMP and waits for exit with a
// 30-second deadline. Falls back to Kill() if the deadline is exceeded.
// Must be called with w.mu held.
func (w *VMWorker) stopVM() {
	if w.machine == nil {
		return
	}
	log.Printf("shutting down VM")

	if qmp := w.machine.QMP(); qmp != nil {
		if err := qmp.Quit(); err != nil {
			log.Printf("QMP quit: %v (killing)", err)
			w.machine.Kill() //nolint:errcheck
		}
	} else {
		w.machine.Kill() //nolint:errcheck
	}

	// Capture machine pointer before launching the goroutine so it is not
	// affected by a concurrent nil assignment to w.machine.
	machine := w.machine
	done := make(chan struct{})
	go func() {
		machine.Wait() //nolint:errcheck
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		log.Printf("VM did not exit within 30s — killing")
		machine.Kill() //nolint:errcheck
	}

	if w.agent != nil {
		w.agent.Close() //nolint:errcheck
		w.agent = nil
	}
	w.machine = nil
}

// shutdown is called on worker exit (stdin EOF or one-shot completion).
// It stops the VM, removes the shared host directories, and cleans up the
// temp disk dir if one was used (the qcow2 is preserved when ccacheDir is set).
func (w *VMWorker) shutdown() {
	close(w.stopIdle)
	w.mu.Lock()
	defer w.mu.Unlock()
	w.stopVM()
	os.RemoveAll(w.inputDir)
	os.RemoveAll(w.outputDir)
	if w.tempDiskDir != "" {
		os.RemoveAll(w.tempDiskDir)
	}
}

// idleReaper runs as a background goroutine and shuts the VM down when it has
// been idle for longer than the configured idle timeout.
// It uses TryLock to avoid blocking a concurrent handleRequest call.
func (w *VMWorker) idleReaper() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-w.stopIdle:
			return
		case <-ticker.C:
			if !w.mu.TryLock() {
				// A request is in progress; skip this tick.
				continue
			}
			if w.machine != nil && time.Since(w.lastUsed) > w.cfg.idleTimeout {
				log.Printf("idle timeout (%s) reached — stopping VM", w.cfg.idleTimeout)
				w.stopVM()
			}
			w.mu.Unlock()
		}
	}
}

// guestExec executes a shell command inside the guest and returns an error if
// the command exits non-zero. Output is logged to stderr and appended to output.
func (w *VMWorker) guestExec(ctx context.Context, cmd string, timeoutSecs int, output *strings.Builder) error {
	log.Printf("guest exec: %s", cmd)
	resp, err := w.agent.Exec(ctx, cmd, timeoutSecs)
	if err != nil {
		return fmt.Errorf("agent.Exec(%q): %w", cmd, err)
	}
	w.logGuestOutput(resp.Stdout, resp.Stderr, output)
	if resp.ExitCode != 0 {
		return fmt.Errorf("command exited %d: %s", resp.ExitCode, cmd)
	}
	return nil
}

// guestExecAllowFail runs a guest command and returns the exit code plus any
// transport-level error. A non-zero exit code is NOT an error — callers must
// inspect exitCode themselves. err is non-nil only when the RPC itself fails
// (VM dead, connection lost, etc.), which callers should treat as fatal and
// trigger a VM restart.
func (w *VMWorker) guestExecAllowFail(ctx context.Context, cmd string, timeoutSecs int, output *strings.Builder) (exitCode int, err error) {
	log.Printf("guest probe: %s", cmd)
	resp, err := w.agent.Exec(ctx, cmd, timeoutSecs)
	if err != nil {
		return 0, fmt.Errorf("agent.Exec(%q): %w", cmd, err)
	}
	w.logGuestOutput(resp.Stdout, resp.Stderr, output)
	return resp.ExitCode, nil
}

// logGuestOutput writes captured guest stdout/stderr to both stderr and the
// provided builder.
func (w *VMWorker) logGuestOutput(stdout, stderr string, output *strings.Builder) {
	if stdout != "" {
		for _, line := range strings.Split(strings.TrimRight(stdout, "\n"), "\n") {
			msg := fmt.Sprintf("[guest] %s\n", line)
			fmt.Fprint(os.Stderr, msg)
			output.WriteString(msg)
		}
	}
	if stderr != "" {
		for _, line := range strings.Split(strings.TrimRight(stderr, "\n"), "\n") {
			msg := fmt.Sprintf("[guest stderr] %s\n", line)
			fmt.Fprint(os.Stderr, msg)
			output.WriteString(msg)
		}
	}
}

// hashFileContents returns the hex-encoded SHA-256 digest of the named file,
// streaming the data so large tarballs are never fully loaded into memory.
// Returns an error if the file cannot be opened or read.
func hashFileContents(path string) (string, error) {
	if path == "" {
		return "empty", nil
	}
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("hashFileContents: opening %s: %w", path, err)
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("hashFileContents: reading %s: %w", path, err)
	}
	return fmt.Sprintf("%x", h.Sum(nil)), nil
}

// startupHash returns a short hex hash derived from the worker startup config.
// For the toolchain and sysroot tars it hashes the actual file contents so the
// hash changes whenever the tar changes, even if the path stays the same.
// This is used to name the persistent qcow2 (different configs → different disks)
// and is also stored as a marker inside the guest so stale toolchains are re-extracted.
// The hash covers: kernel/initrd paths (used as identity, not frequently rewritten),
// toolchain tar content, sysroot tar content, memory, cpus, and qemu binary.
func startupHash(cfg workerConfig) (string, error) {
	toolchainDigest, err := hashFileContents(cfg.toolchainTar)
	if err != nil {
		return "", fmt.Errorf("startupHash: toolchain: %w", err)
	}
	sysrootDigest, err := hashFileContents(cfg.sysrootTar)
	if err != nil {
		return "", fmt.Errorf("startupHash: sysroot: %w", err)
	}

	h := sha256.New()
	fmt.Fprintf(h, "kernel=%s\ninitrd=%s\ntoolchain=%s\nsysroot=%s\nmemory=%s\ncpus=%d\nqemu=%s\n",
		cfg.kernel, cfg.initrd, toolchainDigest, sysrootDigest,
		cfg.memory, cfg.cpus, cfg.qemuSystem)
	return fmt.Sprintf("%x", h.Sum(nil))[:12], nil
}
