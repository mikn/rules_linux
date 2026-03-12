#!/usr/bin/env bash
# Verify tar contents against expected entries.
# Usage: verify_tar.sh <tar_file> <assertions_file>
#
# Assertions file format (one per line):
#   file <path>                    — path must exist
#   !file <path>                   — path must NOT exist
#   symlink <path> <target>        — symlink at path must point to target
#   dir <path>                     — directory must exist
#   mode <path> <mode>             — file must have given mode (e.g., 0644)
#   content_match <pattern>        — tar listing must contain line matching pattern

set -euo pipefail

TAR="$1"
ASSERTIONS="$2"

# Get full tar listing (verbose for permissions/symlinks, and plain for paths)
LISTING=$(tar tvf "$TAR" 2>/dev/null)
PATHS=$(tar tf "$TAR" 2>/dev/null)

FAILURES=0

while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue

    # Parse assertion type and args
    read -r cmd rest <<< "$line"

    case "$cmd" in
        file)
            path="${rest#/}"  # strip leading /
            if ! echo "$PATHS" | grep -qxF "$path"; then
                echo "FAIL: expected file '$path' not found in tar"
                FAILURES=$((FAILURES + 1))
            fi
            ;;
        !file)
            path="${rest#/}"
            if echo "$PATHS" | grep -qxF "$path"; then
                echo "FAIL: unexpected file '$path' found in tar"
                FAILURES=$((FAILURES + 1))
            fi
            ;;
        symlink)
            read -r path target <<< "$rest"
            path="${path#/}"
            # Look for symlink line: lrwxr-xr-x ... path -> target
            if ! echo "$LISTING" | grep -qF "$path -> $target"; then
                echo "FAIL: expected symlink '$path -> $target' not found"
                echo "  Matching lines:"
                echo "$LISTING" | grep "$path" || echo "  (none)"
                FAILURES=$((FAILURES + 1))
            fi
            ;;
        dir)
            path="${rest#/}"
            # Directories end with / in tar listing, or appear as drwx... entries
            if ! echo "$PATHS" | grep -qxF "$path/"; then
                # Also check without trailing slash (some tar implementations)
                if ! echo "$LISTING" | grep -q "^d.*${path}$"; then
                    echo "FAIL: expected directory '$path' not found in tar"
                    FAILURES=$((FAILURES + 1))
                fi
            fi
            ;;
        mode)
            read -r path mode <<< "$rest"
            path="${path#/}"
            # Find the line and check permissions
            entry=$(echo "$LISTING" | grep -F "$path" | head -1)
            if [[ -z "$entry" ]]; then
                echo "FAIL: cannot check mode — '$path' not found in tar"
                FAILURES=$((FAILURES + 1))
            else
                actual_perms=$(echo "$entry" | awk '{print $1}')
                # Convert octal mode to permission string for comparison
                # Instead, just check the raw permission bits via tar --numeric
                actual_mode=$(tar tvf "$TAR" 2>/dev/null | grep -F "$path" | head -1 | awk '{print $1}')
                # Convert ls-style perms to octal
                case "$mode" in
                    0755) expected_pat="-rwxr-xr-x" ;;
                    0644) expected_pat="-rw-r--r--" ;;
                    0444) expected_pat="-r--r--r--" ;;
                    *) expected_pat="UNKNOWN" ;;
                esac
                if [[ "$actual_mode" != "$expected_pat" && "$actual_mode" != "h${expected_pat:1}" ]]; then
                    echo "FAIL: '$path' has mode '$actual_mode', expected '$expected_pat' ($mode)"
                    FAILURES=$((FAILURES + 1))
                fi
            fi
            ;;
        content_match)
            pattern="$rest"
            if ! echo "$PATHS" | grep -qE "$pattern"; then
                echo "FAIL: no path matches pattern '$pattern'"
                FAILURES=$((FAILURES + 1))
            fi
            ;;
        *)
            echo "WARN: unknown assertion command '$cmd'"
            ;;
    esac
done < "$ASSERTIONS"

if [[ $FAILURES -gt 0 ]]; then
    echo ""
    echo "$FAILURES assertion(s) failed"
    echo ""
    echo "=== Full tar listing ==="
    echo "$LISTING"
    exit 1
fi

echo "All assertions passed"
