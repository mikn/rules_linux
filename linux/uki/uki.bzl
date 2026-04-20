"""Rule for assembling a UKI (Unified Kernel Image) using objcopy."""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain", "use_cpp_toolchain")

def _uki_image_impl(ctx):
    """Assemble UKI using objcopy from the cc toolchain."""
    cc_toolchain = find_cpp_toolchain(ctx)

    stub = ctx.file.stub
    kernel = ctx.file.kernel
    initrd = ctx.file.initrd

    # Create kernel command line file
    cmdline_file = ctx.actions.declare_file(ctx.label.name + ".cmdline")
    ctx.actions.write(
        output = cmdline_file,
        content = ctx.attr.kernel_cmdline,
    )

    output = ctx.actions.declare_file(ctx.label.name + ".efi")
    objcopy = cc_toolchain.objcopy_executable

    ctx.actions.run(
        executable = objcopy,
        inputs = depset(
            direct = [stub, kernel, initrd, cmdline_file],
            transitive = [cc_toolchain.all_files],
        ),
        outputs = [output],
        arguments = [
            "--add-section",
            ".linux={}".format(kernel.path),
            "--set-section-flags",
            ".linux=alloc,load,readonly,data",
            "--add-section",
            ".initrd={}".format(initrd.path),
            "--set-section-flags",
            ".initrd=alloc,load,readonly,data",
            "--add-section",
            ".cmdline={}".format(cmdline_file.path),
            "--set-section-flags",
            ".cmdline=alloc,load,readonly,data",
            stub.path,
            output.path,
        ],
        mnemonic = "AssembleUKI",
        progress_message = "Assembling UKI image",
    )

    return [DefaultInfo(files = depset([output]))]

uki_image = rule(
    implementation = _uki_image_impl,
    attrs = {
        "stub": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "EFI stub (e.g., linuxx64.efi.stub)",
        ),
        "kernel": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Kernel vmlinuz file",
        ),
        "initrd": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Initrd file (cpio.zst)",
        ),
        "kernel_cmdline": attr.string(
            default = "console=ttyS0,115200",
            doc = "Kernel command line parameters",
        ),
    },
    toolchains = use_cpp_toolchain(),
    doc = "Assemble a UKI (Unified Kernel Image) from stub + kernel + initrd + cmdline.",
)
