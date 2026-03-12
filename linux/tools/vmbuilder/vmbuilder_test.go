package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestKarchForArch(t *testing.T) {
	tests := []struct {
		arch string
		want string
	}{
		{"x86_64", "x86"},
		{"arm64", "arm64"},
		{"unknown", "x86"}, // default case
	}
	for _, tt := range tests {
		t.Run(tt.arch, func(t *testing.T) {
			if got := karchForArch(tt.arch); got != tt.want {
				t.Errorf("karchForArch(%q) = %q, want %q", tt.arch, got, tt.want)
			}
		})
	}
}

func TestKernelImageForArch(t *testing.T) {
	tests := []struct {
		arch       string
		wantTarget string
		wantPath   string
	}{
		{"x86_64", "bzImage", "arch/x86/boot/bzImage"},
		{"arm64", "Image", "arch/arm64/boot/Image"},
	}
	for _, tt := range tests {
		t.Run(tt.arch, func(t *testing.T) {
			target, path := kernelImageForArch(tt.arch)
			if target != tt.wantTarget {
				t.Errorf("target = %q, want %q", target, tt.wantTarget)
			}
			if path != tt.wantPath {
				t.Errorf("path = %q, want %q", path, tt.wantPath)
			}
		})
	}
}

func TestKernelCmdline(t *testing.T) {
	got := kernelCmdline()
	if got != "console=ttyS0 panic=1 quiet" {
		t.Errorf("kernelCmdline() = %q", got)
	}
}

func TestCopyFile(t *testing.T) {
	t.Run("BasicCopy", func(t *testing.T) {
		src := filepath.Join(t.TempDir(), "src.txt")
		dst := filepath.Join(t.TempDir(), "dst.txt")

		content := []byte("vmlinuz contents")
		if err := os.WriteFile(src, content, 0644); err != nil {
			t.Fatal(err)
		}

		if err := copyFile(src, dst); err != nil {
			t.Fatalf("copyFile: %v", err)
		}

		got, err := os.ReadFile(dst)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != string(content) {
			t.Errorf("got %q, want %q", got, content)
		}
	})

	t.Run("NonExistentSource", func(t *testing.T) {
		dst := filepath.Join(t.TempDir(), "dst.txt")
		if err := copyFile("/nonexistent/vmlinuz", dst); err == nil {
			t.Error("expected error for non-existent source")
		}
	})

	t.Run("ReadOnlyDestination", func(t *testing.T) {
		src := filepath.Join(t.TempDir(), "src.txt")
		if err := os.WriteFile(src, []byte("data"), 0644); err != nil {
			t.Fatal(err)
		}
		if err := copyFile(src, "/proc/nonexistent"); err == nil {
			t.Error("expected error for unwritable destination")
		}
	})
}
