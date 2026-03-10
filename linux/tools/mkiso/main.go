package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/diskfs/go-diskfs"
	"github.com/diskfs/go-diskfs/disk"
	"github.com/diskfs/go-diskfs/filesystem"
	"github.com/diskfs/go-diskfs/filesystem/iso9660"
)

var (
	usiPath    = flag.String("usi", "", "Path to USI/UKI file")
	outputPath = flag.String("output", "", "Path for output ISO file")
)

func main() {
	flag.Parse()

	if *usiPath == "" || *outputPath == "" {
		fmt.Fprintf(os.Stderr, "Usage: %s -usi <usi-file> -output <iso-file> [data-files...]\n", os.Args[0])
		flag.PrintDefaults()
		os.Exit(1)
	}

	dataFiles := flag.Args()
	if err := createUEFIBootableISO(*usiPath, dataFiles, *outputPath); err != nil {
		log.Fatalf("Failed to create ISO: %v", err)
	}

	fmt.Printf("Successfully created bootable ISO: %s\n", *outputPath)
}

func createUEFIBootableISO(usiPath string, dataFiles []string, outputPath string) error {
	// Step 1: Do a dry run to calculate exact content size
	fmt.Printf("Calculating required space...\n")
	contentSize, err := calculateContentSize(usiPath, dataFiles)
	if err != nil {
		return fmt.Errorf("failed to calculate content size: %w", err)
	}

	// Add 5% buffer plus minimum overhead for ISO structures
	bufferSize := max(int64(float64(contentSize)*0.05), 5*1024*1024)

	isoSize := contentSize + bufferSize + (10 * 1024 * 1024) // Extra 10MB for ISO metadata

	// Round up to next 32MB boundary for proper EFI booting
	// UEFI requires ISO to be aligned to 32MB increments
	alignmentSize := int64(32 * 1024 * 1024)
	isoSize = ((isoSize + alignmentSize - 1) / alignmentSize) * alignmentSize

	fmt.Printf("Content size: %d bytes (%.1f MB)\n", contentSize, float64(contentSize)/(1024*1024))
	fmt.Printf("ISO size with buffer: %d bytes (%.1f MB)\n", isoSize, float64(isoSize)/(1024*1024))

	// Step 2: Create ESP (FAT32 image) containing the USI
	espImg := filepath.Join(os.TempDir(), "esp.img")
	defer os.Remove(espImg)

	_, err = createESP(usiPath, espImg)
	if err != nil {
		return fmt.Errorf("failed to create ESP: %w", err)
	}

	// Step 3: Create ISO with El Torito boot configuration
	err = createISO(espImg, dataFiles, outputPath, isoSize)
	if err != nil {
		return fmt.Errorf("failed to create ISO: %w", err)
	}

	fmt.Printf("Successfully created bootable ISO: %s\n", outputPath)
	return nil
}

func createESP(usiPath, espPath string) (int64, error) {
	// Get USI file size to calculate ESP size
	usiInfo, err := os.Stat(usiPath)
	if err != nil {
		return 0, fmt.Errorf("failed to stat USI file: %w", err)
	}

	// get closest 32MB increment (only first 7 bits)
	usiSize := ((usiInfo.Size() + 0x1FFFFFF) >> 25) << 25

	// but at least 288MB (which is also a 32MB increment)
	// We need it to be over 260MB to force it to be FAT32
	// UEFI will not boot if it isn't an increment of 32MB
	espSize := max(usiSize, 288*1024*1024)

	// Create ESP disk image
	espDisk, err := diskfs.Create(espPath, espSize, diskfs.SectorSize512)
	if err != nil {
		return 0, fmt.Errorf("failed to create ESP disk: %w", err)
	}

	// Create FAT32 filesystem on ESP
	espFS, err := espDisk.CreateFilesystem(disk.FilesystemSpec{
		Partition: 0,
		FSType:    filesystem.TypeFat32,
	})
	if err != nil {
		return 0, fmt.Errorf("failed to create FAT32 filesystem: %w", err)
	}

	// Create EFI boot directory structure
	if err := espFS.Mkdir("/EFI"); err != nil {
		return 0, fmt.Errorf("failed to create /EFI directory: %w", err)
	}
	if err := espFS.Mkdir("/EFI/BOOT"); err != nil {
		return 0, fmt.Errorf("failed to create /EFI/BOOT directory: %w", err)
	}

	// Copy USI to ESP as BOOTX64.EFI
	usiFile, err := os.Open(usiPath)
	if err != nil {
		return 0, fmt.Errorf("failed to open USI file: %w", err)
	}
	defer usiFile.Close()

	bootFile, err := espFS.OpenFile("/EFI/BOOT/BOOTX64.EFI", os.O_CREATE|os.O_RDWR)
	if err != nil {
		return 0, fmt.Errorf("failed to create BOOTX64.EFI: %w", err)
	}
	defer bootFile.Close()

	if _, err := io.Copy(bootFile, usiFile); err != nil {
		return 0, fmt.Errorf("failed to copy USI to ESP: %w", err)
	}

	// FAT32 filesystem is automatically finalized when closed

	return espSize, nil
}

func createISO(espPath string, dataFiles []string, outputPath string, isoSize int64) error {

	// Create temporary working directory for ISO content
	workDir := filepath.Join(os.TempDir(), "iso-work")
	defer os.RemoveAll(workDir)

	if err := os.MkdirAll(workDir, 0755); err != nil {
		return fmt.Errorf("failed to create work directory: %w", err)
	}

	// Create ISO disk with 2048 byte sectors (required for ISO9660)
	isoDisk, err := diskfs.Create(outputPath, isoSize, diskfs.SectorSize(2048))
	if err != nil {
		return fmt.Errorf("failed to create ISO disk: %w", err)
	}

	// Create ISO filesystem
	isoFS, err := isoDisk.CreateFilesystem(disk.FilesystemSpec{
		Partition: 0,
		FSType:    filesystem.TypeISO9660,
		WorkDir:   workDir,
	})
	if err != nil {
		return fmt.Errorf("failed to create ISO filesystem: %w", err)
	}

	// Add ESP image to ISO
	espData, err := os.ReadFile(espPath)
	if err != nil {
		return fmt.Errorf("failed to read ESP image: %w", err)
	}

	efiImg, err := isoFS.OpenFile("/efi.img", os.O_CREATE|os.O_RDWR)
	if err != nil {
		return fmt.Errorf("failed to create efi.img in ISO: %w", err)
	}

	if _, err := efiImg.Write(espData); err != nil {
		efiImg.Close()
		return fmt.Errorf("failed to write ESP data to ISO: %w", err)
	}
	efiImg.Close()

	// Add individual data files to /data/ if provided
	if len(dataFiles) > 0 {
		if err := copyDataFilesToISO(isoFS, dataFiles); err != nil {
			return fmt.Errorf("failed to copy data files to ISO: %w", err)
		}
	}

	// Finalize the ISO with El Torito boot configuration
	iso9660FS, ok := isoFS.(*iso9660.FileSystem)
	if !ok {
		return fmt.Errorf("failed to cast to ISO9660 filesystem")
	}

	fmt.Printf("Platform constant value: %d (0x%X)", iso9660.EFI, iso9660.EFI)
	err = iso9660FS.Finalize(iso9660.FinalizeOptions{
		RockRidge:        true,
		DeepDirectories:  true,
		VolumeIdentifier: "BULLDOZER",
		ElTorito: &iso9660.ElTorito{
			BootCatalog: "/boot.catalog",
			Platform:    iso9660.EFI,
			Entries: []*iso9660.ElToritoEntry{
				{
					Platform:  iso9660.EFI,
					Emulation: iso9660.NoEmulation,
					BootFile:  "/efi.img",
					LoadSize:  0,
				},
			},
		},
	})
	if err != nil {
		return fmt.Errorf("failed to finalize ISO: %w", err)
	}

	return nil
}

func copyDataFilesToISO(isoFS filesystem.FileSystem, dataFiles []string) error {
	// Create /data directory
	if err := isoFS.Mkdir("/data"); err != nil {
		return fmt.Errorf("failed to create /data directory: %w", err)
	}

	for _, filePath := range dataFiles {
		// Check if this is a Bazel-generated file with directory structure
		// Bazel output files like "images/bottlerocket-metal-dev-x86_64.img.lz4"
		// should preserve their directory structure under /data/
		fileName := filepath.Base(filePath)
		targetPath := "/data/" + fileName

		// If the source file path contains directory structure (not just a filename),
		// preserve it under /data/
		dir := filepath.Dir(filePath)
		if dir != "." && dir != "" {
			// Get just the last directory component for Bazel outputs
			// e.g., "bazel-out/.../images/file.img" -> "images/file.img"
			parts := strings.Split(filePath, "/")
			for i := len(parts) - 2; i >= 0; i-- {
				if parts[i] == "images" {
					// Found images directory, use from here
					relPath := strings.Join(parts[i:], "/")
					targetPath = "/data/" + relPath
					break
				}
			}
		}

		// Ensure parent directory exists
		parentDir := filepath.Dir(targetPath)
		if parentDir != "/data" && parentDir != "/" {
			if err := ensureDir(isoFS, parentDir); err != nil {
				return fmt.Errorf("failed to create parent directory %s: %w", parentDir, err)
			}
		}

		// Open source file
		srcFile, err := os.Open(filePath)
		if err != nil {
			return fmt.Errorf("failed to open source file %s: %w", filePath, err)
		}

		// Create destination file in ISO
		isoFile, err := isoFS.OpenFile(targetPath, os.O_CREATE|os.O_RDWR)
		if err != nil {
			srcFile.Close()
			return fmt.Errorf("failed to create file %s in ISO: %w", targetPath, err)
		}

		// Copy file content
		if _, err := io.Copy(isoFile, srcFile); err != nil {
			srcFile.Close()
			isoFile.Close()
			return fmt.Errorf("failed to copy file content for %s: %w", filePath, err)
		}

		srcFile.Close()
		isoFile.Close()

		fmt.Printf("Copied %s to %s in ISO\n", filePath, targetPath)
	}

	return nil
}

func calculateContentSize(usiPath string, dataFiles []string) (int64, error) {
	// Start with USI file size
	usiInfo, err := os.Stat(usiPath)
	if err != nil {
		return 0, fmt.Errorf("failed to stat USI file: %w", err)
	}

	usiSize := usiInfo.Size()

	// Calculate ESP size (USI + 15% overhead, minimum 32MB)
	espSize := usiSize + (usiSize * 15 / 100)
	if espSize < 32*1024*1024 {
		espSize = 32 * 1024 * 1024
	}

	// Round ESP up to next 512-byte boundary
	sectorSize := int64(512)
	espSize = ((espSize + sectorSize - 1) / sectorSize) * sectorSize

	contentSize := espSize

	// Add data files sizes
	for _, filePath := range dataFiles {
		fileInfo, err := os.Stat(filePath)
		if err != nil {
			return 0, fmt.Errorf("failed to stat data file %s: %w", filePath, err)
		}
		contentSize += fileInfo.Size()
	}

	return contentSize, nil
}

func ensureDir(isoFS filesystem.FileSystem, dirPath string) error {
	// Recursively create parent directories
	parts := strings.Split(strings.Trim(dirPath, "/"), "/")
	currentPath := ""

	for _, part := range parts {
		if part == "" {
			continue
		}
		currentPath += "/" + part

		// Try to create directory, ignore if it already exists
		isoFS.Mkdir(currentPath)
	}

	return nil
}
