# rules_linux

Bazel rules for building Linux boot artifacts: kernels, initrds, UKIs, ISOs, and Secure Boot signing.

## Setup

```starlark
# MODULE.bazel
bazel_dep(name = "rules_linux", version = "0.1.0")
```

## Rules

All rules are exported from `@rules_linux//linux:defs.bzl`.

### `kernel_build`

Build a Linux kernel from source using hermetic toolchains.

```starlark
load("@rules_linux//linux:defs.bzl", "kernel_build")

kernel_build(
    name = "linux_6_12",
    source_tarball = "@linux_6_12//:linux-6.12.13.tar.xz",
    defconfig = "defconfig",
    config_fragments = [":kvm.fragment"],
    arch = "x86_64",
    version = "6.12.13",
)
```

### `kernel_extract`

Extract a pre-built kernel from a Debian package.

```starlark
load("@rules_linux//linux:defs.bzl", "kernel_extract")

kernel_extract(
    name = "debian_kernel",
    package = "@linux_image_deb//file",
    version = "6.1.0-28-amd64",
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

Strip profiles: `STRIP_PROFILE_NONE`, `STRIP_PROFILE_SERVER` (removes docs, locales, firmware, dev tools), `STRIP_PROFILE_MINIMAL`.

### `uki_image`

Assemble a Unified Kernel Image (EFI executable) from kernel + initrd.

```starlark
load("@rules_linux//linux:defs.bzl", "uki_image")

uki_image(
    name = "system_uki",
    stub = "@systemd//:linuxx64.efi.stub",
    kernel = ":linux_6_12",
    initrd = ":rootfs_initrd",
    kernel_cmdline = "console=ttyS0",
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

Create a bootable ISO from a UKI.

```starlark
load("@rules_linux//linux:defs.bzl", "iso_image")

iso_image(
    name = "boot_iso",
    usi = ":system_uki",
)
```

## Macros

High-level macros are in `@rules_linux//linux:macros.bzl`:

- `usi_image` — builds a complete USI (kernel extraction + initrd + UKI) in one step
- `signed_usi_image` — builds and signs a USI
- `iso_multiarch` — builds ISOs for multiple architectures

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

## Providers

| Provider | Fields |
|----------|--------|
| `LinuxKernelInfo` | `vmlinuz`, `modules`, `system_map`, `headers`, `version`, `arch` |
| `LinuxImageInfo` | `image`, `format`, `kernel`, `initrd`, `cmdline`, `signed` |
