// Package initrd_test verifies that the initrd rule produces correct output.
//
// These tests decompress cpio.zst archives and validate:
// - Correct zstd compression format
// - Valid cpio newc header after decompression
// - Expected files present in the archive
// - Strip profiles exclude the right files
package initrd_test

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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

// listCpioZst lists contents of a cpio.zst file using bsdtar (which created it).
func listCpioZst(t *testing.T, path string) []string {
	t.Helper()

	// Use hermetic bsdtar from Bazel toolchain
	bsdtar := envPath(t, "BSDTAR")
	cmd := exec.Command(bsdtar, "-tf", path)
	var out bytes.Buffer
	var errBuf bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errBuf

	if err := cmd.Run(); err != nil {
		t.Fatalf("bsdtar list failed: %v\nstderr: %s", err, errBuf.String())
	}

	var paths []string
	for _, line := range strings.Split(out.String(), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			paths = append(paths, line)
		}
	}
	return paths
}

func TestInitrdFormat(t *testing.T) {
	path := envPath(t, "TEST_INITRD")

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading initrd: %v", err)
	}

	if len(data) < 4 {
		t.Fatal("initrd too small")
	}

	// Must be zstd compressed (magic 0x28B52FFD)
	if data[0] != 0x28 || data[1] != 0xB5 || data[2] != 0x2F || data[3] != 0xFD {
		t.Fatalf("expected zstd magic (28B52FFD), got %x", data[:4])
	}
	t.Logf("initrd is zstd-compressed (%d bytes)", len(data))
}

func TestInitrdContainsTestFile(t *testing.T) {
	path := envPath(t, "TEST_INITRD")

	paths := listCpioZst(t, path)
	t.Logf("initrd contains %d entries", len(paths))

	found := false
	for _, p := range paths {
		if strings.HasSuffix(p, "test.txt") {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("expected test.txt in initrd, not found")
	}
}

func TestStrippedInitrdExcludesScripting(t *testing.T) {
	path := envPath(t, "TEST_INITRD_STRIPPED")

	paths := listCpioZst(t, path)
	t.Logf("stripped initrd contains %d entries", len(paths))

	// STRIP_PROFILE_SERVER should exclude python and perl
	for _, p := range paths {
		if strings.Contains(p, "usr/bin/python") {
			t.Errorf("stripped initrd should not contain python: %s", p)
		}
		if strings.Contains(p, "usr/bin/perl") {
			t.Errorf("stripped initrd should not contain perl: %s", p)
		}
		if strings.HasSuffix(p, ".pyc") {
			t.Errorf("stripped initrd should not contain .pyc files: %s", p)
		}
	}
}

func TestStrippedInitrdExcludesDocs(t *testing.T) {
	path := envPath(t, "TEST_INITRD_STRIPPED")

	paths := listCpioZst(t, path)

	for _, p := range paths {
		if strings.HasPrefix(p, "usr/share/doc/") || strings.HasPrefix(p, "./usr/share/doc/") {
			t.Errorf("stripped initrd should not contain docs: %s", p)
		}
		if strings.HasPrefix(p, "usr/share/man/") || strings.HasPrefix(p, "./usr/share/man/") {
			t.Errorf("stripped initrd should not contain man pages: %s", p)
		}
	}
}

func TestBootstrapInitrdContainsSystemd(t *testing.T) {
	path := envPath(t, "BOOTSTRAP_INITRD")

	paths := listCpioZst(t, path)
	t.Logf("bootstrap initrd contains %d entries", len(paths))

	// Bootstrap initrd should have systemd
	requiredPatterns := []string{
		"lib/systemd/systemd",
		"usr/bin/bash",
	}

	for _, pattern := range requiredPatterns {
		found := false
		for _, p := range paths {
			if strings.Contains(p, pattern) {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("bootstrap initrd missing required file matching %q", pattern)
		}
	}
}
