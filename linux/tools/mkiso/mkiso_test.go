package main

import (
	"os"
	"testing"
)

func TestEfiBootFilename(t *testing.T) {
	tests := []struct {
		arch    string
		want    string
		wantErr bool
	}{
		{"x86_64", "BOOTX64.EFI", false},
		{"amd64", "BOOTX64.EFI", false},
		{"arm64", "BOOTAA64.EFI", false},
		{"aarch64", "BOOTAA64.EFI", false},
		{"riscv64", "", true},
		{"", "", true},
	}
	for _, tt := range tests {
		t.Run(tt.arch, func(t *testing.T) {
			got, err := efiBootFilename(tt.arch)
			if (err != nil) != tt.wantErr {
				t.Fatalf("efiBootFilename(%q) error = %v, wantErr %v", tt.arch, err, tt.wantErr)
			}
			if got != tt.want {
				t.Errorf("efiBootFilename(%q) = %q, want %q", tt.arch, got, tt.want)
			}
		})
	}
}

func TestCalculateContentSize(t *testing.T) {
	t.Run("SmallFile", func(t *testing.T) {
		f := t.TempDir() + "/tiny.efi"
		if err := os.WriteFile(f, make([]byte, 1024), 0644); err != nil {
			t.Fatal(err)
		}

		size, err := calculateContentSize(f, nil)
		if err != nil {
			t.Fatalf("calculateContentSize: %v", err)
		}

		// ESP minimum is 32MB (for files smaller than 32MB after 15% overhead)
		minESP := int64(32 * 1024 * 1024)
		if size < minESP {
			t.Errorf("size %d < minimum ESP %d", size, minESP)
		}
	})

	t.Run("WithDataFiles", func(t *testing.T) {
		usi := t.TempDir() + "/boot.efi"
		data := t.TempDir() + "/data.img"
		if err := os.WriteFile(usi, make([]byte, 1024), 0644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(data, make([]byte, 5*1024*1024), 0644); err != nil {
			t.Fatal(err)
		}

		sizeWithout, _ := calculateContentSize(usi, nil)
		sizeWith, _ := calculateContentSize(usi, []string{data})

		if sizeWith <= sizeWithout {
			t.Errorf("size with data (%d) should exceed size without (%d)", sizeWith, sizeWithout)
		}
	})

	t.Run("NonExistentFile", func(t *testing.T) {
		_, err := calculateContentSize("/nonexistent/boot.efi", nil)
		if err == nil {
			t.Error("expected error for non-existent file")
		}
	})
}
