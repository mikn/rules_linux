"""Rule for creating bootable ISO images from UKI/USI files."""

def _iso_image_impl(ctx):
    """Create a bootable ISO from a USI/UKI file."""
    mkiso_tool = ctx.executable.mkiso_tool
    usi_file = ctx.file.usi

    arch = ctx.attr.arch

    iso_output = ctx.actions.declare_file(ctx.label.name + ".iso")

    args = ctx.actions.args()
    args.add("-usi", usi_file.path)
    args.add("-output", iso_output.path)
    args.add("-arch", arch)

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
        progress_message = "Creating bootable ISO {} ({})".format(ctx.label.name, arch),
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
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "mkiso binary for ISO creation",
        ),
        "arch": attr.string(
            default = "x86_64",
            values = ["x86_64", "arm64"],
            doc = "Target architecture for EFI boot filename. x86_64 → BOOTX64.EFI, arm64 → BOOTAA64.EFI.",
        ),
    },
    doc = "Build a bootable ISO image from a USI/UKI file.",
)
