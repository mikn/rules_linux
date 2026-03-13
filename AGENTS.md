# rules_linux

Bazel rules for building Linux boot artifacts: kernels (from source or .deb), initrds, UKIs, ISOs, Secure Boot signing, and rootfs assembly.

## Commands

```bash
bazel test //... --override_module=rules_qemu=/path/to/rules_qemu   # Run all tests (needs local rules_qemu)
bazel build //...                                                    # Build all targets
bazel run //:gazelle                                                 # Regenerate BUILD files after Go changes
```

## Structure

- `linux/defs.bzl` — Public API: `kernel_build`, `kernel_extract`, `initrd`, `uki_image`, `sign_image`, `iso_image`, `systemd_service`, `install_files`, `rootfs`
- `linux/providers.bzl` — `LinuxKernelInfo`, `LinuxImageInfo` providers
- `linux/macros.bzl` — High-level: `usi_image`, `signed_usi_image`, `iso_multiarch`
- `linux/rootfs.bzl` — Rootfs assembly macros: `systemd_service`, `install_files`, `rootfs`
- `linux/extensions.bzl` — Module extensions: `kernel_sources`, `ccache`, `test_artifacts`, `packages`
- `linux/tools/` — Go tools: `mkiso` (ISO creation), `usi-signer` (Secure Boot signing), `vmworker` (persistent Bazel worker for macOS kernel build)
- `linux/bootstrap/` — Bootstrap Debian packages for initrd base
- `tests/` — Build tests and imperative verification tests

## Code Quality

- **Starlark**: Fail fast with `fail()` on invalid input. Validate all rule attributes at analysis time. Use `ctx.actions.declare_file()` for outputs, never hardcode paths. Propagate providers correctly.
- **Go tools**: Static binaries (`pure = "on"`). No external deps beyond what's in `go.mod`. Error on all failures, no silent fallbacks.
- **Go module path**: `github.com/mikn/rules_linux` (not `github.com/molnett/rules_linux`).
- **Rules must be hermetic**: All inputs declared, no undeclared host deps. Exception: `kernel_build` needs `bc` on host (documented).
- **Test new rules**: Add build tests (Skylib `build_test`) AND imperative verification tests (`verify_tar_test`) in `tests/rootfs_test/`.
- **Providers are the API contract**: Changes to `LinuxKernelInfo`/`LinuxImageInfo` fields are breaking changes.

## Pitfalls & Learnings

### pkg_tar

- **Symlinks nest under `package_dir`**: If a `pkg_tar` has both `package_dir` and `symlinks`, the symlink paths get prefixed with `package_dir`. Always put symlinks in a separate `pkg_tar` target without `package_dir`. The `systemd_service` and `install_files` macros handle this automatically.
- **`remap_paths` is broken/unreliable**: Don't use it. Use `package_dir` + separate tars instead.
- **Service file permissions**: Use `mode = "0644"` on service file tars to avoid systemd "marked executable" warnings.
- **Empty directories**: Use the `empty_dirs` attribute on `pkg_tar`, or the `empty_dirs` key in `install_files` entries.
- **No per-file renaming**: `pkg_tar` doesn't support renaming files. Use `genrule(cmd = "cp $< $@")` to rename before installation.

### rootfs.bzl macros

- **`systemd_service` label handling**: The `service_file` parameter accepts both file paths (`files/foo.service`) and labels (`//pkg:foo.service`). The macro parses the service name by checking for `:` first (label), then `/` (path). A label like `//pkg/zebra:zebra.service` would incorrectly produce `zebra:zebra.service` if only split on `/`.
- **`install_files` with dest + symlinks**: When an entry has both `dest` (→ `package_dir`) and `symlinks`, the macro automatically splits them into two sub-targets to prevent nesting. You can safely combine them in a single entry.
- **`install_files` symlink-only entries**: Entries with only `symlinks` (no `srcs`/`dest`) are valid and create absolute-path symlinks.

### packages extension

- **Manifest generation**: Each component (e.g., `main`, `non-free-firmware`) gets its own source entry in the generated YAML. Don't combine them into one channel string — `rules_distroless` expects separate entries.
- **Lock file path**: The custom `_packages_resolve` rule writes lock files to the path from the `lock` attr. The upstream `deb_resolve` derives the path from the manifest label, which breaks when the manifest is in a generated external repo.
- **Lock regeneration**: `bazel run @<name>_resolve//:lock` resolves packages and writes to the workspace.

### Kernel builds

- **kernel_build is a macro**: Dispatches via `select(@platforms//os:macos)` to `_kernel_build_native` (Linux) or `_kernel_build_vm` (macOS, QEMU).
- **allnoconfig + objtool**: x86_64 allnoconfig with objtool-disabling fragments works without libelf. Key options: `# CONFIG_OBJTOOL is not set`, `# CONFIG_STACK_VALIDATION is not set`, `CONFIG_UNWINDER_FRAME_POINTER=y`.
- **CONFIG_VIRTIO_PCI**: Must also set `CONFIG_VIRTIO_MENU=y` (it gates all virtio PCI drivers).
- **libelf dependency**: Only needed if objtool is enabled. Disable objtool in config fragments for minimal kernels.

### Initrd

- **STRIP_PROFILE_SERVER**: Strips perl, python, docs, locales, firmware, dev tools. Available tools in stripped initrd: bash, coreutils, util-linux, systemd, udev.
- **STRIP_PROFILE_MINIMAL**: Uses wildcard patterns for arch-specific library paths (e.g., `usr/lib/*/gconv/*` matches both `x86_64-linux-gnu` and `aarch64-linux-gnu`).
- **Minimal initrd boot**: (1) shebang must use `#!/bin/busybox sh`, (2) create mountpoints before mounting, (3) create `/dev/pts` AFTER devtmpfs mount, (4) install busybox applets before using commands, (5) use sleep loop not `wait` for PID 1.

### General Bazel

- **bzlmod `local_path_override` label gotcha**: `//pkg:target` resolves in root workspace, not module. Use `@module_name//pkg:target` for cross-context compatibility.
- **`alias` with `select()`**: Only analyzes the selected branch, not both — good for platform-specific dispatching.
- **`sh_binary` vs `allow_single_file=True`**: sh_binary targets don't satisfy `allow_single_file` constraints; use `filegroup` instead.
- **`realpath` portability**: Not available on older macOS — use `$PWD/path` instead.
- **`sed -i` portability**: GNU `sed -i 's/...'` vs macOS BSD `sed -i '' 's/...'`. Portable: `sed -i.bak ... && rm *.bak`.

## Self-Correction Protocol

When you receive a correction from the user about rules_linux patterns, Starlark idioms, or pkg_tar behavior, update the "Pitfalls & Learnings" section of this file to capture the correction. This prevents repeating the same mistakes across conversations.

## Releasing

See [RELEASING.md](RELEASING.md). Tag push → GitHub release → `publish-to-bcr` reusable workflow auto-opens BCR PR. No deps on other `rules_*` modules.
