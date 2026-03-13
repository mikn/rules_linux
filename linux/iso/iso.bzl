"""Rule for creating bootable ISO images from UKI/USI files."""

def _iso_image_impl(ctx):
    """Create a bootable ISO from a USI/UKI file."""
    mkiso_tool = ctx.executable.mkiso_tool
    usi_file = ctx.file.usi

    iso_output = ctx.actions.declare_file(ctx.label.name + ".iso")

    args = ctx.actions.args()
    args.add("-usi", usi_file.path)
    args.add("-output", iso_output.path)
    args.add("-arch", ctx.attr.arch)
    args.add("-volume-id", ctx.attr.volume_id)

    inputs = [usi_file]

    if ctx.files.data_files:
        for data_file in ctx.files.data_files:
            args.add(data_file.path)
            inputs.append(data_file)

    ctx.actions.run(
        executable = mkiso_tool,
        arguments = [args],
        inputs = inputs,
        outputs = [iso_output],
        mnemonic = "MkISO",
        progress_message = "Creating bootable ISO {} ({})".format(ctx.label.name, ctx.attr.arch),
    )

    return [DefaultInfo(files = depset([iso_output]))]

iso_image = rule(
    implementation = _iso_image_impl,
    attrs = {
        "usi": attr.label(
            mandatory = True,
            allow_single_file = [".efi"],
            doc = "USI/UKI file to make bootable",
        ),
        "data_files": attr.label_list(
            allow_files = True,
            doc = "Files to include under /data/ on the ISO",
        ),
        "mkiso_tool": attr.label(
            default = "//linux/tools/mkiso",
            executable = True,
            cfg = "exec",
            doc = "mkiso binary for ISO creation",
        ),
        "arch": attr.string(
            default = "x86_64",
            values = ["x86_64", "arm64"],
            doc = "Target architecture for EFI boot filename. x86_64 → BOOTX64.EFI, arm64 → BOOTAA64.EFI.",
        ),
        "volume_id": attr.string(
            default = "LINUX",
            doc = "ISO 9660 volume identifier (max 32 characters).",
        ),
    },
    doc = "Build a bootable ISO image from a USI/UKI file.",
)

def iso_multiarch(name, usi_amd64, usi_arm64 = None, volume_id = "LINUX", data_files = [], visibility = None, **kwargs):
    """Build ISO images for multiple architectures.

    Args:
        name: Base name for ISO targets. Creates {name}_amd64 and optionally {name}_arm64.
        usi_amd64: Label of the x86_64 USI/UKI file.
        usi_arm64: Label of the arm64 USI/UKI file (optional).
        volume_id: ISO 9660 volume identifier.
        data_files: Files to include under /data/ on the ISO.
        visibility: Target visibility.
        **kwargs: Additional arguments passed to iso_image.
    """
    iso_image(
        name = name + "_amd64",
        usi = usi_amd64,
        arch = "x86_64",
        volume_id = volume_id,
        data_files = data_files,
        visibility = visibility,
        **kwargs
    )

    if usi_arm64:
        iso_image(
            name = name + "_arm64",
            usi = usi_arm64,
            arch = "arm64",
            volume_id = volume_id,
            data_files = data_files,
            visibility = visibility,
            **kwargs
        )
