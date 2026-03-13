# rules_linux

Bazel rules for building Linux boot artifacts: kernels, initrds, UKIs, ISOs, and Secure Boot signing.

Supports x86_64 and ARM64 targets. Linux and macOS hosts are supported for `kernel_build`.

## Setup

```starlark
# MODULE.bazel
bazel_dep(name = "rules_linux", version = "0.1.0")
```

## Rules

All rules are exported from `@rules_linux//linux:defs.bzl`.

### `kernel_build`

Build a Linux kernel from source. This ruleset **optimizes for LLVM (`LLVM=1`) builds only** — GCC-based builds are not supported.

**Linux hosts:** Runs `make LLVM=1` directly using Bazel-managed hermetic toolchains (LLVM/clang, flex, bison, python3, perl, make, bsdtar, nproc). Only `bc` is taken from the host (no BCR module available).

**macOS hosts:** Boots a persistent QEMU VM worker with the bootstrap kernel and initrd. The LLVM toolchain (clang, lld, llvm-ar, etc.) is downloaded from the official LLVM releases via the `vm_toolchain` extension — the same version as your `toolchains_llvm` registration — and shared into the VM via 9P. Ancillary build tools (make, flex, bison, perl, etc.) and dev headers come from Debian packages in the sysroot. The VM itself stays small (no compiler in the initrd). Requires QEMU installed on the host (e.g. `brew install qemu`). Apple Silicon Macs use HVF-accelerated ARM64 VMs; Intel Macs use HVF-accelerated x86_64 VMs.

Both paths produce the same `LinuxKernelInfo` provider and output files.

#### Parallel VM builds (macOS)

The VM worker supports Bazel's persistent worker protocol. To run N kernel builds in parallel:

```sh
bazel build --worker_max_instances=KernelBuildVM=4 //...
```

#### Persistent compiler cache (ccache)

On **Linux**, pass the `ccache` binary and `ccache_dir`. The sandbox must be configured to mount the cache directory:

```python
# .bazelrc
build --sandbox_add_mount_pair=/tmp/bazel-ccache:/tmp/bazel-ccache
build --sandbox_writable_path=/tmp/bazel-ccache
```

```starlark
kernel_build(
    name = "linux",
    ccache = "@ccache//:ccache",
    ccache_dir = "/tmp/bazel-ccache",
    ...
)
```

On **macOS**, set `ccache_dir` to a host path that the VM worker will use. No sandbox configuration is needed — the VM worker accesses the host path directly:

```starlark
kernel_build(
    name = "linux",
    ccache_dir = "/tmp/bazel-ccache",
    ...
)
```

#### Examples

```starlark
load("@rules_linux//linux:defs.bzl", "kernel_build")

# x86_64 kernel
kernel_build(
    name = "linux_6_12_x86_64",
    source_tarball = "@linux_6_12//:linux-6.12.13.tar.xz",
    defconfig = "defconfig",
    config_fragments = [":kvm.fragment"],
    arch = "x86_64",
    version = "6.12.13",
)

# ARM64 kernel (cross-compiled from any host with LLVM=1)
kernel_build(
    name = "linux_6_12_arm64",
    source_tarball = "@linux_6_12//:linux-6.12.13.tar.xz",
    defconfig = "defconfig",
    arch = "arm64",
    version = "6.12.13",
)
```

### `kernel_extract`

Extract a pre-built kernel from a Debian package.

Architecture values: `x86_64` (or legacy alias `amd64`) and `arm64`.

```starlark
load("@rules_linux//linux:defs.bzl", "kernel_extract")

# x86_64 Debian kernel
kernel_extract(
    name = "debian_kernel_x86_64",
    package = "@linux_image_amd64_deb//file",
    version = "6.1.0-28-amd64",
    arch = "x86_64",
)

# ARM64 Debian kernel
kernel_extract(
    name = "debian_kernel_arm64",
    package = "@linux_image_arm64_deb//file",
    version = "6.1.0-28-arm64",
    arch = "arm64",
)
```

Both rules produce `LinuxKernelInfo` (vmlinuz, modules, headers, version, arch).

### `initrd`

Create a compressed cpio initrd from a rootfs tarball, with optional stripping.

```starlark
load("@rules_linux//linux:defs.bzl", "initrd", "STRIP_PROFILE_SERVER")

initrd(
    name = "rootfs_initrd",
    rootfs = ":rootfs_tar",
    strip_profile = STRIP_PROFILE_SERVER,
)
```

Strip profiles: `STRIP_PROFILE_NONE`, `STRIP_PROFILE_SERVER` (removes docs, locales, firmware, dev tools), `STRIP_PROFILE_MINIMAL`. `STRIP_PROFILE_MINIMAL` uses wildcard patterns for architecture-specific library paths (e.g. `usr/lib/*/gconv/*` matches both `x86_64-linux-gnu` and `aarch64-linux-gnu`).

### `uki_image`

Assemble a Unified Kernel Image (EFI executable) from kernel + initrd.

```starlark
load("@rules_linux//linux:defs.bzl", "uki_image")

# x86_64
 uki_image(
    name = "system_uki_x86_64",
    stub = "@systemd//:linuxx64.efi.stub",
    kernel = ":linux_6_12_x86_64",
    initrd = ":rootfs_initrd",
    kernel_cmdline = "console=ttyS0",
)

# ARM64 (uses linuxaa64.efi.stub)
uki_image(
    name = "system_uki_arm64",
    stub = "@systemd//:linuxaa64.efi.stub",
    kernel = ":linux_6_12_arm64",
    initrd = ":rootfs_initrd",
    kernel_cmdline = "console=ttyAMA0",
)
```

### `sign_image`

Sign a PE image for Secure Boot. Supports SOPS-encrypted keys or environment variable key providers.

```starlark
load("@rules_linux//linux:defs.bzl", "sign_image")

sign_image(
    name = "signed_uki",
    image = ":system_uki",
    cert = ":db.pem",
    key_provider = "sops",
    sops_env_yaml = ":sops.yaml",
)
```

### `iso_image`

Create a bootable ISO from a UKI. On x86_64, the EFI boot file is `BOOTX64.EFI`; on ARM64 it is `BOOTAA64.EFI`.

```starlark
load("@rules_linux//linux:defs.bzl", "iso_image")

# x86_64 ISO (default)
iso_image(
    name = "boot_iso_x86_64",
    usi = ":system_uki_x86_64",
    arch = "x86_64",
)

# ARM64 ISO
iso_image(
    name = "boot_iso_arm64",
    usi = ":system_uki_arm64",
    arch = "arm64",
)
```

## Rootfs Assembly

Macros for ergonomic rootfs composition, exported from `@rules_linux//linux:defs.bzl`.

### `systemd_service`

Installs a systemd service with its binary. Replaces the common 3-target `pkg_tar` pattern (binary tar + service file tar + enable symlink).

```starlark
load("@rules_linux//linux:defs.bzl", "systemd_service")

systemd_service(
    name = "myapp_service",
    binary = ":myapp",
    service_file = "myapp.service",
    # enabled = True (default), creates multi-user.target.wants symlink
    # wanted_by = "multi-user.target" (default)
    # binary_dest = "/usr/lib/myapp_service" (default: /usr/lib/<name>)
)
```

For services without a binary (e.g., using a binary from another package):

```starlark
systemd_service(
    name = "myapp_config",
    service_file = "myapp-config.service",
    wanted_by = "network.target",
)
```

For `.wants` dependencies between services:

```starlark
systemd_service(
    name = "gobgpd_service",
    binary = ":gobgpd",
    service_file = "gobgpd.service",
    extra_symlinks = {
        "/etc/systemd/system/gobgpd.service.wants/zebra.service": "/usr/lib/systemd/system/zebra.service",
    },
)
```

### `install_files`

Groups files by destination directory and mode into `pkg_tar` layers.

```starlark
load("@rules_linux//linux:defs.bzl", "install_files")

install_files(
    name = "app_files",
    files = [
        {"srcs": [":myapp"], "dest": "/usr/bin", "mode": "0755"},
        {"srcs": ["app.conf"], "dest": "/etc/myapp", "mode": "0644"},
        {"srcs": ["tmpfiles.conf"], "dest": "/usr/lib/tmpfiles.d", "mode": "0644"},
    ],
)
```

### `rootfs`

Composes a complete rootfs from a base image, services, files, and extra layers.

```starlark
load("@rules_linux//linux:defs.bzl", "rootfs")

rootfs(
    name = "my_rootfs",
    base = "@my_debian//:flat",
    services = [
        ":myapp_service",
        ":gobgpd_service",
    ],
    files = [
        {"srcs": [":netmgr"], "dest": "/usr/bin", "mode": "0755"},
        {"srcs": ["gobgp.conf"], "dest": "/usr/lib/tmpfiles.d", "mode": "0644"},
    ],
    extra_tars = [":boot_layer"],
)
```

## Image Macros

High-level macros are in `@rules_linux//linux:macros.bzl`:

- `usi_image` — builds a complete USI (kernel extraction + initrd + UKI) in one step. `arch` accepts `x86_64` or `arm64` (legacy `amd64` accepted for backward compatibility).
- `signed_usi_image` — builds and signs a USI
- `iso_multiarch` — builds ISOs for multiple architectures

```starlark
load("@rules_linux//linux:macros.bzl", "iso_multiarch")

iso_multiarch(
    name = "boot",
    usi_base = "system_uki",
    mkiso_tool = "//tools:mkiso",
    archs = ["x86_64", "arm64"],
)
# Produces :boot_x86_64 and :boot_arm64
```

## Module Extensions

```starlark
# MODULE.bazel
kernel_sources = use_extension("@rules_linux//linux:extensions.bzl", "kernel_sources")
kernel_sources.source(
    name = "linux_6_12",
    version = "6.12.13",
    sha256 = "...",
)
use_repo(kernel_sources, "linux_6_12")
```

### `packages` — Debian packages

Wraps `rules_distroless` to install Debian packages without manually maintaining YAML manifest files.

```starlark
# MODULE.bazel
packages = use_extension("@rules_linux//linux:extensions.bzl", "packages")
packages.debian(
    name = "my_debian",
    packages = ["nginx", "curl", "ca-certificates"],
    arch = "amd64",
    snapshot = "20250101T000000Z",
    lock = "//:my_debian.lock.json",
)
use_repo(packages, "my_debian")
```

Then use `@my_debian//:flat` as a base rootfs tar, or access individual packages like `@my_debian//nginx/amd64:data`.

To generate or update the lock file:

```sh
bazel run @my_debian_resolve//:lock
```

Options: `distro` (default `"bookworm"`), `components` (default `["main"]`).

### `vm_toolchain` — Linux LLVM for macOS VM builds

Downloads the Linux LLVM binary distribution for the kernel_build VM worker. Use the same version as your `toolchains_llvm` registration:

```starlark
# MODULE.bazel
LLVM_VERSION = "19.1.7"

# Host toolchain (runs on macOS/Linux)
llvm = use_extension("@toolchains_llvm//toolchain/extensions:llvm.bzl", "llvm")
llvm.toolchain(name = "llvm_toolchain", llvm_versions = {"": LLVM_VERSION})
use_repo(llvm, "llvm_toolchain", "llvm_toolchain_llvm")
register_toolchains("@llvm_toolchain//:all")

# Linux LLVM for VM builds (same version, Linux ELF binaries)
vm_toolchain = use_extension("@rules_linux//linux:extensions.bzl", "vm_toolchain")
vm_toolchain.llvm(version = LLVM_VERSION)
use_repo(vm_toolchain, "vm_llvm_amd64", "vm_llvm_arm64")
```

The extension downloads both x86_64 and ARM64 Linux distributions. The `kernel_build` macro automatically selects the correct architecture based on the host CPU.

### `ccache`

The ccache extension auto-detects the host platform by default. Supported platforms: `linux-x86_64`, `linux-aarch64`, `darwin` (universal binary covering Intel and Apple Silicon).

```starlark
# MODULE.bazel — let the extension auto-detect host platform (default)
ccache_ext = use_extension("@rules_linux//linux:extensions.bzl", "ccache")
ccache_ext.download()  # platform = "auto" is the default
use_repo(ccache_ext, "ccache")

# Or pin to a specific platform:
ccache_ext.download(platform = "linux-aarch64")
```

## Providers

| Provider | Fields |
|----------|--------|
| `LinuxKernelInfo` | `vmlinuz`, `modules`, `system_map`, `headers`, `version`, `arch` |
| `LinuxImageInfo` | `image`, `format`, `kernel`, `initrd`, `cmdline`, `signed` |

The `arch` field in `LinuxKernelInfo` is always `x86_64` or `arm64` regardless of which alias was used to construct it.
