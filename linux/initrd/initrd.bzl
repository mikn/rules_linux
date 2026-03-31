"""Rule for creating a stripped cpio.zst initrd from a rootfs tar."""

load("//linux/initrd:strip_profiles.bzl", "STRIP_PROFILE_SERVER")

_TAR_TOOLCHAIN_TYPE = "@aspect_bazel_lib//lib:tar_toolchain_type"

def _initrd_impl(ctx):
    """Convert rootfs tar to cpio.zst format, stripping unnecessary files."""
    bsdtar = ctx.toolchains[_TAR_TOOLCHAIN_TYPE]
    rootfs_tar = ctx.file.rootfs

    output = ctx.actions.declare_file(ctx.label.name + ".cpio.zst")

    # Build exclusion list from profile + extras
    exclusions = list(ctx.attr.strip_profile)
    exclusions.extend(ctx.attr.extra_excludes)

    # Remove any entries in extra_includes
    for inc in ctx.attr.extra_includes:
        if inc in exclusions:
            exclusions.remove(inc)

    args = ctx.actions.args()
    args.add("-c")
    args.add("--format=newc")
    args.add("--zstd")
    args.add("--options")
    args.add("zstd:compression-level=5")
    args.add_all(exclusions)
    args.add("-f")
    args.add(output)
    args.add("--fflags")
    args.add(rootfs_tar, format = "@%s")

    ctx.actions.run(
        executable = bsdtar.tarinfo.binary,
        arguments = [args],
        inputs = depset(direct = [rootfs_tar], transitive = [bsdtar.default.files]),
        outputs = [output],
        mnemonic = "CompressRootfs",
        progress_message = "Creating stripped cpio.zst initrd",
    )

    return [DefaultInfo(files = depset([output]))]

initrd = rule(
    implementation = _initrd_impl,
    attrs = {
        "rootfs": attr.label(
            mandatory = True,
            allow_single_file = [".tar", ".tar.gz"],
            doc = "Rootfs tar file",
        ),
        "strip_profile": attr.string_list(
            default = STRIP_PROFILE_SERVER,
            doc = "List of --exclude patterns for stripping",
        ),
        "extra_excludes": attr.string_list(
            default = [],
            doc = "Additional --exclude patterns beyond the profile",
        ),
        "extra_includes": attr.string_list(
            default = [],
            doc = "Patterns to remove from the exclusion list (overrides)",
        ),
    },
    toolchains = [_TAR_TOOLCHAIN_TYPE],
    doc = "Create a stripped cpio.zst initrd from a rootfs tar.",
)
