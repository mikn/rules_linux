"""Convenience macros for rules_linux."""

load("@rules_pkg//pkg:tar.bzl", "pkg_tar")
load("//linux/initrd:initrd.bzl", "initrd")
load("//linux/uki:uki.bzl", "uki_image")
load("//linux/signing:signing.bzl", "sign_image")
load("//linux/iso:iso.bzl", "iso_image")

_TAR_TOOLCHAIN_TYPE = "@aspect_bazel_lib//lib:tar_toolchain_type"

def _tar_extract_impl(ctx):
    """Extract a single file from a tar archive using hermetic bsdtar."""
    bsdtar = ctx.toolchains[_TAR_TOOLCHAIN_TYPE]
    src = ctx.file.src
    output = ctx.actions.declare_file(ctx.label.name + ctx.attr.out_ext)

    ctx.actions.run_shell(
        inputs = depset(direct = [src], transitive = [bsdtar.default.files]),
        outputs = [output],
        command = """
            set -e
            "{bsdtar}" -xf {src} --include='{pattern}' -O > {output} 2>/dev/null || {{
                echo "ERROR: Pattern '{pattern}' not found in archive" >&2
                exit 1
            }}
        """.format(
            bsdtar = bsdtar.tarinfo.binary.path,
            src = src.path,
            pattern = ctx.attr.pattern,
            output = output.path,
        ),
        mnemonic = "TarExtract",
        progress_message = "Extracting %s from archive" % ctx.attr.pattern,
    )

    return [DefaultInfo(files = depset([output]))]

_tar_extract = rule(
    implementation = _tar_extract_impl,
    attrs = {
        "src": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Source tar archive",
        ),
        "pattern": attr.string(
            mandatory = True,
            doc = "Include pattern for bsdtar extraction (e.g., './boot/vmlinuz-*')",
        ),
        "out_ext": attr.string(
            mandatory = True,
            doc = "Output file extension (e.g., '.vmlinuz', '.stub')",
        ),
    },
    toolchains = [_TAR_TOOLCHAIN_TYPE],
    doc = "Extract a single file matching a pattern from a tar archive using hermetic bsdtar.",
)

def usi_image(name, rootfs, kernel_cmdline = "console=ttyS0,115200",
              kernel_package = None, systemd_boot_package = None,
              arch = "x86_64", strip_profile = None, extra_excludes = [],
              extra_includes = [], **kwargs):
    """Build a USI (Unified System Image) - UKI with complete OS rootfs as initrd.

    Args:
        name: Target name
        rootfs: Rootfs tar file
        kernel_cmdline: Kernel command line parameters
        kernel_package: Kernel debian package data archive
        systemd_boot_package: systemd-boot package data archive
        arch: Target architecture (x86_64 or arm64). amd64 accepted as legacy alias for x86_64.
        strip_profile: Strip profile for initrd (default: STRIP_PROFILE_SERVER)
        extra_excludes: Additional --exclude patterns for initrd
        extra_includes: Patterns to remove from exclusions
        **kwargs: Additional arguments
    """
    if kernel_package == None:
        fail("kernel_package is required")
    if systemd_boot_package == None:
        fail("systemd_boot_package is required")

    # Normalize arch: accept legacy amd64 as alias for x86_64
    if arch in ("x86_64", "amd64"):
        stub_pattern = "./usr/lib/systemd/boot/efi/linuxx64.efi.stub"
    elif arch == "arm64":
        stub_pattern = "./usr/lib/systemd/boot/efi/linuxaa64.efi.stub"
    else:
        fail("Unsupported architecture: {}. Use x86_64 or arm64.".format(arch))

    # Extract kernel using hermetic bsdtar
    _tar_extract(
        name = name + "_kernel",
        src = kernel_package,
        pattern = "./boot/vmlinuz-*",
        out_ext = ".vmlinuz",
        visibility = ["//visibility:private"],
    )

    # Extract stub using hermetic bsdtar
    _tar_extract(
        name = name + "_stub",
        src = systemd_boot_package,
        pattern = stub_pattern,
        out_ext = ".stub",
        visibility = ["//visibility:private"],
    )

    # Create initrd
    initrd_kwargs = {}
    if strip_profile != None:
        initrd_kwargs["strip_profile"] = strip_profile
    if extra_excludes:
        initrd_kwargs["extra_excludes"] = extra_excludes
    if extra_includes:
        initrd_kwargs["extra_includes"] = extra_includes

    initrd(
        name = name + "_initrd",
        rootfs = rootfs,
        visibility = ["//visibility:private"],
        **initrd_kwargs
    )

    # Assemble UKI
    uki_image(
        name = name,
        stub = ":" + name + "_stub",
        kernel = ":" + name + "_kernel",
        initrd = ":" + name + "_initrd",
        kernel_cmdline = kernel_cmdline,
        **kwargs
    )

def signed_usi_image(name, rootfs, cert, signer, kernel_cmdline = "console=ttyS0,115200",
                     additional_certs = [], key_env_var = "SECUREBOOT_KEY",
                     key_provider = "sops", sops = None, sops_env_yaml = None, **kwargs):
    """Build and sign a USI image in one step.

    Args:
        name: Target name
        rootfs: Rootfs tar file
        cert: Signing certificate
        signer: usi-signer binary label
        kernel_cmdline: Kernel command line parameters
        additional_certs: Additional certificate files
        key_env_var: Environment variable for private key
        key_provider: Key provider (sops or env)
        sops: SOPS binary label (required for sops provider)
        sops_env_yaml: SOPS encrypted YAML (required for sops provider)
        **kwargs: Additional arguments passed to usi_image
    """
    usi_kwargs = {k: v for k, v in kwargs.items() if k != "visibility"}
    usi_image(
        name = name + "_unsigned",
        rootfs = rootfs,
        kernel_cmdline = kernel_cmdline,
        **usi_kwargs
    )

    sign_image(
        name = name,
        image = ":" + name + "_unsigned",
        cert = cert,
        additional_certs = additional_certs,
        signer = signer,
        key_provider = key_provider,
        sops = sops,
        sops_env_yaml = sops_env_yaml,
        key_env_var = key_env_var,
        **{k: v for k, v in kwargs.items() if k in ["visibility", "tags", "testonly"]}
    )

def signed_usi(name, usi, cert, signer, sops_env_yaml = None, additional_certs = [],
               key_env_var = "SECUREBOOT_KEY", key_provider = "sops", sops = None, **kwargs):
    """Sign a USI image for Secure Boot.

    Args:
        name: Target name
        usi: USI image to sign
        cert: Signing certificate
        signer: usi-signer binary label
        sops_env_yaml: SOPS encrypted YAML (required for sops provider)
        additional_certs: Additional certificate files
        key_env_var: Environment variable for private key
        key_provider: Key provider (sops or env)
        sops: SOPS binary label (required for sops provider)
        **kwargs: Additional arguments
    """
    sign_image(
        name = name,
        image = usi,
        cert = cert,
        additional_certs = additional_certs,
        key_provider = key_provider,
        signer = signer,
        sops = sops,
        sops_env_yaml = sops_env_yaml,
        key_env_var = key_env_var,
        **kwargs
    )

def iso_multiarch(name, usi_base, mkiso_tool, data_files = [], archs = ["x86_64"], **kwargs):
    """Build ISO images for multiple architectures.

    Args:
        name: Base name for ISO targets
        usi_base: Base name for USI targets
        mkiso_tool: mkiso binary label
        data_files: Files to include under /data/
        archs: List of architectures to build ISOs for (default: ["x86_64"])
        **kwargs: Additional arguments
    """
    for arch in archs:
        iso_image(
            name = name + "_" + arch,
            usi = ":" + usi_base + "_" + arch,
            mkiso_tool = mkiso_tool,
            arch = arch,
            data_files = data_files,
            **kwargs
        )
