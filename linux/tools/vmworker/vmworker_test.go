// Integration tests for vmworker. Each test requires /dev/kvm and boots a
// real QEMU VM using the bootstrap kernel and initrd.
//
// Tests 1-3 drive the vm.Start / vm.ConnectAgent APIs directly (no worker
// protocol). Test 4 exercises the Bazel persistent worker protocol by
// launching the vmworker binary as a subprocess.
//
// Run with:
//
//	bazel test //linux/tools/vmworker:vmworker_test --test_tag_filters=requires-kvm
package main_test

import (
	"archive/tar"
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/mikn/rules_qemu/vm"
)

// kvmPath is the device node that must be accessible for hardware-accelerated
// tests. All tests call requireKVM as their first statement.
const kvmPath = "/dev/kvm"

// requireKVM skips the test when /dev/kvm is not accessible.
func requireKVM(t *testing.T) {
	t.Helper()
	if _, err := os.Stat(kvmPath); err != nil {
		t.Skipf("requires %s: %v", kvmPath, err)
	}
	f, err := os.OpenFile(kvmPath, os.O_RDWR, 0)
	if err != nil {
		t.Skipf("cannot open %s: %v", kvmPath, err)
	}
	f.Close()
}

// envPath resolves a Bazel rlocationpath environment variable to an absolute
// file path, consulting RUNFILES_DIR / TEST_SRCDIR as needed.
func envPath(t *testing.T, name string) string {
	t.Helper()
	v := os.Getenv(name)
	if v == "" {
		t.Fatalf("environment variable %s not set", name)
	}
	if filepath.IsAbs(v) {
		return v
	}
	for _, base := range []string{
		os.Getenv("RUNFILES_DIR"),
		os.Getenv("TEST_SRCDIR"),
	} {
		if base == "" {
			continue
		}
		p := filepath.Join(base, v)
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	abs, err := filepath.Abs(v)
	if err != nil {
		t.Fatalf("resolving %s=%q: %v", name, v, err)
	}
	return abs
}

// bootOpts returns the standard vm.Option set shared by all tests.
// It wires up the bootstrap kernel+initrd, enables the agent, QMP, and serial
// capture, and disables networking to keep boot fast.
func bootOpts(t *testing.T) []vm.Option {
	t.Helper()
	kernel := envPath(t, "BOOTSTRAP_KERNEL")
	initrd := envPath(t, "BOOTSTRAP_INITRD")
	return []vm.Option{
		vm.WithKernelBoot(kernel, initrd, "console=ttyS0 panic=1 quiet"),
		vm.WithMemory("1G"),
		vm.WithCPUs(2),
		vm.WithNoNetwork(),
		vm.WithSerialCapture(),
		vm.WithAgent(),
		vm.WithQMP(),
	}
}

// startVM boots a VM with the given options, registers a t.Cleanup that kills
// it, and returns the running VM. Serial output is forwarded to t.Log.
func startVM(t *testing.T, opts ...vm.Option) *vm.VM {
	t.Helper()
	ctx := context.Background()
	machine, err := vm.Start(ctx, opts...)
	if err != nil {
		t.Fatalf("vm.Start: %v", err)
	}
	if serial := machine.Serial(); serial != nil {
		serial.OnLine(func(line string) {
			t.Logf("[serial] %s", line)
		})
	}
	t.Cleanup(func() {
		machine.Kill() //nolint:errcheck
		machine.Wait() //nolint:errcheck
	})
	return machine
}

// connectAgent dials the agent socket, retrying until the context is
// cancelled. It registers a t.Cleanup that closes the connection.
func connectAgent(t *testing.T, machine *vm.VM) *vm.AgentConn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	agent, err := vm.ConnectAgent(ctx, machine.AgentSocketPath())
	if err != nil {
		t.Fatalf("ConnectAgent: %v", err)
	}
	t.Cleanup(func() { agent.Close() }) //nolint:errcheck
	return agent
}

// guestExec runs a shell command inside the guest. It fails the test if the
// command exits non-zero or the RPC call itself fails.
func guestExec(t *testing.T, agent *vm.AgentConn, cmd string, timeoutSecs int) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSecs+5)*time.Second)
	defer cancel()
	resp, err := agent.Exec(ctx, cmd, timeoutSecs)
	if err != nil {
		t.Fatalf("agent.Exec(%q): %v", cmd, err)
	}
	if resp.ExitCode != 0 {
		t.Fatalf("command %q exited %d\nstdout: %s\nstderr: %s",
			cmd, resp.ExitCode, resp.Stdout, resp.Stderr)
	}
	return resp.Stdout
}

// guestProbe runs a shell command inside the guest and returns whether it
// succeeded (exit 0). RPC failures are treated as errors.
func guestProbe(t *testing.T, agent *vm.AgentConn, cmd string, timeoutSecs int) bool {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSecs+5)*time.Second)
	defer cancel()
	resp, err := agent.Exec(ctx, cmd, timeoutSecs)
	if err != nil {
		t.Fatalf("agent.Exec(%q): %v", cmd, err)
	}
	return resp.ExitCode == 0
}

// createQcow2 creates an empty qcow2 image at the given path via qemu-img.
func createQcow2(t *testing.T, path, size string) {
	t.Helper()
	cmd := exec.Command("qemu-img", "create", "-f", "qcow2", path, size)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("qemu-img create: %v\n%s", err, out)
	}
}

// makeMockToolchainTar builds a small tar archive containing a handful of
// placeholder files that mimic the LLVM distribution layout the worker checks
// for (bin/clang as the marker). The files are placed under a top-level
// directory (like a real LLVM release tarball) so --strip-components=1 works.
// Returns the path to the tar file.
func makeMockToolchainTar(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	tarPath := filepath.Join(dir, "toolchain.tar")

	f, err := os.Create(tarPath)
	if err != nil {
		t.Fatalf("creating toolchain tar: %v", err)
	}
	defer f.Close()

	tw := tar.NewWriter(f)
	defer tw.Close()

	// Mimic LLVM release tarball: top-level dir + bin/ layout.
	files := []struct {
		name    string
		content string
		mode    int64
	}{
		{"LLVM-mock/bin/clang", "#!/bin/sh\nexec true\n", 0o755},
		{"LLVM-mock/bin/llvm-ar", "#!/bin/sh\nexec true\n", 0o755},
		{"LLVM-mock/bin/lld", "#!/bin/sh\nexec true\n", 0o755},
	}
	for _, fi := range files {
		hdr := &tar.Header{
			Name:     fi.name,
			Mode:     fi.mode,
			Size:     int64(len(fi.content)),
			Typeflag: tar.TypeReg,
			ModTime:  time.Now(),
		}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatalf("tar header %s: %v", fi.name, err)
		}
		if _, err := io.WriteString(tw, fi.content); err != nil {
			t.Fatalf("tar write %s: %v", fi.name, err)
		}
	}

	return tarPath
}

// TestVMWorkerBootAndAgent boots a VM using the bootstrap kernel/initrd,
// connects the guest agent, verifies echo output, then shuts down cleanly.
func TestVMWorkerBootAndAgent(t *testing.T) {
	requireKVM(t)
	if testing.Short() {
		t.Skip("skipping VM boot test in -short mode")
	}

	machine := startVM(t, bootOpts(t)...)
	agent := connectAgent(t, machine)

	out := guestExec(t, agent, "echo hello", 10)
	got := strings.TrimSpace(out)
	if got != "hello" {
		t.Fatalf("echo hello: got %q, want %q", got, "hello")
	}

	// Verify basic system is functional.
	guestExec(t, agent, "uname -r", 10)

	// Graceful QMP shutdown.
	if qmp := machine.QMP(); qmp != nil {
		if err := qmp.Quit(); err != nil {
			t.Logf("QMP quit: %v (continuing)", err)
		}
	}
}

// TestVMWorkerScratchDisk boots a VM with a qcow2 scratch disk, formats it
// ext4 inside the guest, writes a sentinel file, shuts down, reboots with the
// same qcow2, and confirms the file is still present.
func TestVMWorkerScratchDisk(t *testing.T) {
	requireKVM(t)
	if testing.Short() {
		t.Skip("skipping scratch disk test in -short mode")
	}

	diskDir := t.TempDir()
	diskPath := filepath.Join(diskDir, "scratch.qcow2")
	createQcow2(t, diskPath, "2G")

	opts := append(bootOpts(t),
		vm.WithExistingDisk(diskPath),
		vm.WithDiskFormat("qcow2"),
	)

	// --- First boot: format and write sentinel ---
	t.Log("first boot: formatting scratch disk")
	m1 := startVM(t, opts...)
	a1 := connectAgent(t, m1)

	guestExec(t, a1, "mkfs.ext4 /dev/vda", 60)
	guestExec(t, a1, "mkdir -p /build", 10)
	guestExec(t, a1, "mount /dev/vda /build", 30)
	guestExec(t, a1, "echo vmworker-sentinel > /build/sentinel.txt", 10)
	guestExec(t, a1, "sync", 10)

	// Shut down cleanly so QCOW2 journal is flushed.
	a1.Close()
	if qmp := m1.QMP(); qmp != nil {
		_ = qmp.Quit()
	}
	done := make(chan struct{})
	go func() { m1.Wait(); close(done) }() //nolint:errcheck
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Log("VM did not exit within 30s; killing")
		m1.Kill() //nolint:errcheck
	}

	// --- Second boot: verify persistence ---
	t.Log("second boot: verifying persistence")
	m2 := startVM(t, opts...)
	a2 := connectAgent(t, m2)

	guestExec(t, a2, "mkdir -p /build", 10)
	guestExec(t, a2, "mount /dev/vda /build", 30)
	out := guestExec(t, a2, "cat /build/sentinel.txt", 10)
	got := strings.TrimSpace(out)
	if got != "vmworker-sentinel" {
		t.Fatalf("sentinel.txt: got %q, want %q", got, "vmworker-sentinel")
	}
}

// TestVMWorkerToolchainExtraction creates a mock toolchain tar, boots a VM
// with a qcow2 scratch disk and a 9P input share, extracts the tar on the
// first boot, then reboots to verify the toolchain persists on the disk.
func TestVMWorkerToolchainExtraction(t *testing.T) {
	requireKVM(t)
	if testing.Short() {
		t.Skip("skipping toolchain extraction test in -short mode")
	}

	diskDir := t.TempDir()
	diskPath := filepath.Join(diskDir, "scratch.qcow2")
	createQcow2(t, diskPath, "2G")

	inputDir := t.TempDir()
	tarPath := makeMockToolchainTar(t)
	if err := copyFileForTest(tarPath, filepath.Join(inputDir, "toolchain.tar")); err != nil {
		t.Fatalf("staging toolchain tar: %v", err)
	}

	opts := append(bootOpts(t),
		vm.WithExistingDisk(diskPath),
		vm.WithDiskFormat("qcow2"),
		vm.With9PShare("input", inputDir),
	)

	// --- First boot: format disk, mount 9P, extract toolchain ---
	t.Log("first boot: extracting mock toolchain")
	m1 := startVM(t, opts...)
	a1 := connectAgent(t, m1)

	guestExec(t, a1, "mkfs.ext4 /dev/vda", 60)
	guestExec(t, a1, "mkdir -p /build/toolchain /mnt/input", 10)
	guestExec(t, a1, "mount /dev/vda /build", 30)
	guestExec(t, a1, "mount -t 9p -o trans=virtio,version=9p2000.L input /mnt/input", 30)
	guestExec(t, a1, "mkdir -p /build/toolchain", 10)
	guestExec(t, a1, "tar xf /mnt/input/toolchain.tar --strip-components=1 -C /build/toolchain", 30)

	if !guestProbe(t, a1, "test -x /build/toolchain/bin/clang", 10) {
		t.Fatal("toolchain marker /build/toolchain/bin/clang not found after extraction")
	}
	guestExec(t, a1, "sync", 10)

	// Shut down cleanly.
	a1.Close()
	if qmp := m1.QMP(); qmp != nil {
		_ = qmp.Quit()
	}
	done := make(chan struct{})
	go func() { m1.Wait(); close(done) }() //nolint:errcheck
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Log("VM did not exit within 30s; killing")
		m1.Kill() //nolint:errcheck
	}

	// --- Second boot (simulate idle-timeout restart): verify toolchain intact ---
	t.Log("second boot: verifying toolchain persistence after reboot")
	m2 := startVM(t, opts...)
	a2 := connectAgent(t, m2)

	guestExec(t, a2, "mkdir -p /build", 10)
	guestExec(t, a2, "mount /dev/vda /build", 30)

	if !guestProbe(t, a2, "test -x /build/toolchain/bin/clang", 10) {
		t.Fatal("toolchain marker not found after reboot: qcow2 did not persist toolchain")
	}
	t.Log("toolchain persisted correctly across simulated idle-timeout restart")
}

// WorkRequest / WorkResponse mirror the types in worker.go so we can
// marshal/unmarshal them without importing the main package.
type workerRequest struct {
	Arguments []string `json:"arguments"`
	Inputs    []struct {
		Path   string `json:"path"`
		Digest string `json:"digest"`
	} `json:"inputs"`
	RequestID int `json:"requestId"`
}

type workerResponse struct {
	ExitCode  int    `json:"exitCode"`
	Output    string `json:"output"`
	RequestID int    `json:"requestId"`
}

// TestVMWorkerWorkerProtocol starts the vmworker binary with
// --persistent_worker, sends a deliberately malformed WorkRequest (missing
// required flags) that will produce a WorkResponse without booting a VM, reads
// the response, and then closes stdin to verify clean shutdown.
//
// This tests the JSON framing layer end-to-end without requiring a full kernel
// build or valid VMWORKER_* environment variables. The worker parses args
// before booting the VM, so an arg-validation error returns a WorkResponse
// with exit code 1 without ever attempting a boot.
func TestVMWorkerWorkerProtocol(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping subprocess test in -short mode")
	}

	workerBin := envPath(t, "VMWORKER_BIN")
	if _, err := os.Stat(workerBin); err != nil {
		t.Fatalf("vmworker binary not found at %q: %v", workerBin, err)
	}

	// Provide minimal env so newVMWorker() doesn't fail before parsing args.
	// We set VMWORKER_KERNEL / INITRD / TOOLCHAIN_TAR to non-empty but
	// intentionally non-existent paths — the worker validates args before
	// touching those files.
	env := append(os.Environ(),
		"VMWORKER_KERNEL=/nonexistent/kernel",
		"VMWORKER_INITRD=/nonexistent/initrd",
		"VMWORKER_TOOLCHAIN_TAR=/nonexistent/toolchain.tar",
		"VMWORKER_IDLE_TIMEOUT=5s",
	)

	cmd := exec.Command(workerBin, "--persistent_worker")
	cmd.Env = env

	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("StdinPipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("StdoutPipe: %v", err)
	}
	// Capture stderr so test output isn't noisy; log it on failure.
	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	if err := cmd.Start(); err != nil {
		t.Fatalf("starting vmworker: %v", err)
	}
	t.Cleanup(func() {
		cmd.Process.Kill() //nolint:errcheck
		cmd.Wait()         //nolint:errcheck
		if t.Failed() {
			t.Logf("vmworker stderr:\n%s", stderrBuf.String())
		}
	})

	// Send a WorkRequest with arguments that will fail arg validation
	// (missing --source-tarball, --defconfig, and output flags). The worker
	// must return a WorkResponse without ever booting a VM.
	req := workerRequest{
		Arguments: []string{"--arch=x86_64"}, // incomplete; will fail parseActionArgs
		RequestID: 42,
	}
	line, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if _, err := fmt.Fprintf(stdin, "%s\n", line); err != nil {
		t.Fatalf("writing WorkRequest: %v", err)
	}

	// Read the WorkResponse from stdout with a deadline.
	readDone := make(chan struct {
		resp workerResponse
		err  error
	}, 1)
	go func() {
		scanner := bufio.NewScanner(stdout)
		if scanner.Scan() {
			var resp workerResponse
			if decErr := json.Unmarshal(scanner.Bytes(), &resp); decErr != nil {
				readDone <- struct {
					resp workerResponse
					err  error
				}{err: fmt.Errorf("unmarshal: %w", decErr)}
				return
			}
			readDone <- struct {
				resp workerResponse
				err  error
			}{resp: resp}
		} else {
			readDone <- struct {
				resp workerResponse
				err  error
			}{err: fmt.Errorf("no response line (scanner err: %v)", scanner.Err())}
		}
	}()

	select {
	case result := <-readDone:
		if result.err != nil {
			t.Fatalf("reading WorkResponse: %v", result.err)
		}
		resp := result.resp
		if resp.RequestID != 42 {
			t.Errorf("requestId: got %d, want 42", resp.RequestID)
		}
		if resp.ExitCode == 0 {
			t.Error("expected non-zero exit code for malformed request, got 0")
		}
		if resp.Output == "" {
			t.Error("expected non-empty output for malformed request")
		}
		t.Logf("WorkResponse: exitCode=%d output=%q", resp.ExitCode, resp.Output)
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for WorkResponse")
	}

	// Close stdin — the worker should detect EOF and exit cleanly.
	if err := stdin.Close(); err != nil {
		t.Logf("closing stdin: %v", err)
	}

	exitDone := make(chan error, 1)
	go func() { exitDone <- cmd.Wait() }()
	select {
	case err := <-exitDone:
		// Any exit (zero or non-zero) after stdin EOF is acceptable.
		t.Logf("vmworker exited: %v", err)
	case <-time.After(15 * time.Second):
		t.Error("vmworker did not exit within 15s after stdin EOF")
	}
}

// copyFileForTest copies src to dst using streaming I/O.
// This is a local helper so the test file has no dependency on unexported
// worker internals.
func copyFileForTest(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return fmt.Errorf("copyFileForTest mkdir: %w", err)
	}
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("copyFileForTest open %s: %w", src, err)
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("copyFileForTest create %s: %w", dst, err)
	}
	defer out.Close()

	if _, err := io.Copy(out, in); err != nil {
		return fmt.Errorf("copyFileForTest copy: %w", err)
	}
	return out.Close()
}
