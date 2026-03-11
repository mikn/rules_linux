# rules_linux

Bazel rules for building Linux boot artifacts: kernels, initrds, UKIs, ISOs, and Secure Boot signing.

Supports x86_64 and ARM64 targets. Linux and macOS hosts are supported (macOS support for `kernel_build` is best-effort).

## Setup

```starlark
# MODULE.bazel
bazel_dep(name = "rules_linux", version = "0.1.0")
```

## Rules

All rules are exported from `@rules_linux//linux:defs.bzl`.

### `kernel_build`

Build a Linux kernel from source using hermetic toolchains (LLVM, flex, bison, python3, perl, make).

**Host support:** Tested on Linux x86_64 and Linux ARM64. macOS (Apple Silicon and Intel) is best-effort — the kernel build system supports `LLVM=1` cross-compilation, but GNU/BSD tool differences may surface. Cross-architecture builds (e.g. building an ARM64 kernel on an x86_64 host) work via `LLVM=1 ARCH=arm64`.

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

## Macros

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

### ccache extension

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
