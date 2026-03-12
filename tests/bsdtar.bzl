"""Helper rule to extract bsdtar from the toolchain for use in tests."""

TAR_TOOLCHAIN_TYPE = "@aspect_bazel_lib//lib:tar_toolchain_type"

def _bsdtar_binary_impl(ctx):
    bsdtar = ctx.toolchains[TAR_TOOLCHAIN_TYPE]
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = bsdtar.tarinfo.binary)
    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(transitive_files = bsdtar.default.files),
    )]

bsdtar_binary = rule(
    implementation = _bsdtar_binary_impl,
    toolchains = [TAR_TOOLCHAIN_TYPE],
)
