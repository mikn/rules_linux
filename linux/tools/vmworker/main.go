// vmworker is a persistent Bazel worker that keeps a QEMU VM warm across
// kernel build actions. When invoked with --persistent_worker it reads
// newline-delimited JSON WorkRequest objects from stdin and writes
// WorkResponse objects to stdout. Otherwise it runs as a one-shot builder
// (same semantics as vmbuilder, useful for manual debugging).
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
)

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)
	log.SetPrefix("vmworker: ")

	// Persistent worker mode is triggered by --persistent_worker in argv.
	persistent := false
	var remainingArgs []string
	for _, arg := range os.Args[1:] {
		if arg == "--persistent_worker" {
			persistent = true
		} else {
			remainingArgs = append(remainingArgs, arg)
		}
	}

	if persistent {
		if err := runPersistent(); err != nil {
			log.Fatalf("persistent worker: %v", err)
		}
		return
	}

	// One-shot mode: parse per-request flags from remaining args and run once.
	if err := runOneShot(remainingArgs); err != nil {
		log.Fatalf("%v", err)
	}
}

// runPersistent implements the Bazel persistent worker protocol.
// It reads WorkRequest JSON from stdin and writes WorkResponse JSON to stdout,
// one object per line. The VM is booted on first request and kept warm.
func runPersistent() error {
	w, err := newVMWorker()
	if err != nil {
		return fmt.Errorf("initialising worker: %w", err)
	}
	defer w.shutdown()

	scanner := bufio.NewScanner(os.Stdin)
	// WorkRequest lines can include large base64 digests. 10MB should be ample.
	scanner.Buffer(make([]byte, 0, 10*1024*1024), 10*1024*1024)

	enc := json.NewEncoder(os.Stdout)

	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "" {
			continue
		}

		var req WorkRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			// Write an error response and keep running — don't crash the worker.
			resp := WorkResponse{
				ExitCode:  1,
				Output:    fmt.Sprintf("failed to parse WorkRequest: %v", err),
				RequestID: 0,
			}
			if encErr := enc.Encode(resp); encErr != nil {
				return fmt.Errorf("encoding error response: %w", encErr)
			}
			continue
		}

		resp := w.handleRequest(req)
		if err := enc.Encode(resp); err != nil {
			return fmt.Errorf("encoding WorkResponse: %w", err)
		}
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("reading stdin: %w", err)
	}
	return nil
}

// runOneShot boots a VM, executes one build action, and exits.
// Used for manual debugging without the Bazel worker protocol.
func runOneShot(args []string) error {
	w, err := newVMWorker()
	if err != nil {
		return fmt.Errorf("initialising worker: %w", err)
	}
	defer w.shutdown()

	req := WorkRequest{Arguments: args}
	resp := w.handleRequest(req)

	if resp.ExitCode != 0 {
		return fmt.Errorf("build failed (exit %d):\n%s", resp.ExitCode, resp.Output)
	}
	return nil
}
