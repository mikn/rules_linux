// Package bootstrap_test verifies that the bootstrap kernel and initrd
// produced by kernel_extract and the initrd rule are valid artifacts.
//
// These tests serve as integration tests for the full bootstrap pipeline:
// rules_distroless apt packages → kernel_extract → initrd.
package bootstrap_test

import (
	"os"
	"path/filepath"
	"testing"
)

func envPath(t *testing.T, name string) string {
	t.Helper()
	v := os.Getenv(name)
	if v == "" {
		t.Fatalf("environment variable %s not set", name)
	}
	if filepath.IsAbs(v) {
		return v
	}
	runfilesDir := os.Getenv("RUNFILES_DIR")
	if runfilesDir == "" {
		runfilesDir = os.Getenv("TEST_SRCDIR")
	}
	if runfilesDir != "" {
		p := filepath.Join(runfilesDir, v)
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

func TestBootstrapKernel(t *testing.T) {
	kernel := envPath(t, "BOOTSTRAP_KERNEL")
	data, err := os.ReadFile(kernel)
	if err != nil {
		t.Fatalf("reading kernel: %v", err)
	}

	if len(data) == 0 {
		t.Fatal("kernel file is empty")
	}
	t.Logf("kernel size: %d bytes", len(data))

	// x86_64 bzImage: Linux boot protocol magic "HdrS" at offset 0x202
	if len(data) > 0x206 && string(data[0x202:0x206]) == "HdrS" {
		t.Logf("valid x86_64 bzImage (Linux boot protocol header at 0x202)")
		return
	}

	// ARM64 Image: magic "ARM\x64" at offset 0x38
	if len(data) > 0x3c && string(data[0x38:0x3c]) == "ARM\x64" {
		t.Logf("valid ARM64 Image (magic at 0x38)")
		return
	}

	t.Fatalf("unrecognized kernel format (first 16 bytes: %x)", data[:min(16, len(data))])
}

func TestBootstrapInitrd(t *testing.T) {
	initrd := envPath(t, "BOOTSTRAP_INITRD")
	data, err := os.ReadFile(initrd)
	if err != nil {
		t.Fatalf("reading initrd: %v", err)
	}

	if len(data) == 0 {
		t.Fatal("initrd file is empty")
	}
	t.Logf("initrd size: %d bytes (%.1f MB)", len(data), float64(len(data))/(1024*1024))

	// zstd compressed: magic 0x28B52FFD
	if len(data) >= 4 && data[0] == 0x28 && data[1] == 0xB5 && data[2] == 0x2F && data[3] == 0xFD {
		t.Logf("valid zstd-compressed initrd")
		return
	}

	// gzip compressed: magic 0x1F8B
	if len(data) >= 2 && data[0] == 0x1F && data[1] == 0x8B {
		t.Logf("valid gzip-compressed initrd")
		return
	}

	// cpio newc: magic "070701"
	if len(data) >= 6 && string(data[:6]) == "070701" {
		t.Logf("valid cpio newc initrd (uncompressed)")
		return
	}

	t.Fatalf("unrecognized initrd format (first 4 bytes: %x)", data[:min(4, len(data))])
}
