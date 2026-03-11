"""Rule for extracting a kernel from a Debian package."""

load("//linux:providers.bzl", "LinuxKernelInfo")

def _kernel_extract_impl(ctx):
    """Extract kernel from a Debian package data archive."""
    data_tar = ctx.file.package

    arch = ctx.attr.arch

    # Normalize arch: accept both x86_64 and legacy amd64. arm64 is canonical.
    if arch in ("x86_64", "amd64"):
        canonical_arch = "x86_64"
        kernel_pattern = "./boot/vmlinuz-*"
    elif arch == "arm64":
        canonical_arch = "arm64"
        kernel_pattern = "./boot/vmlinuz-*"
    else:
        fail("Unsupported architecture: {}. Use x86_64 or arm64.".format(arch))

    vmlinuz = ctx.actions.declare_file(ctx.label.name + ".vmlinuz")

    ctx.actions.run_shell(
        inputs = [data_tar],
        outputs = [vmlinuz],
        command = """
            set -e
            tar -xf {data_tar} --wildcards '{pattern}' -O > {output} 2>/dev/null || {{
                echo "ERROR: Pattern '{pattern}' not found in package" >&2
                echo "Package contents:" >&2
                tar -tf {data_tar} | grep -E "(vmlinuz|\\.efi)" | head -20 >&2
                exit 1
            }}
        """.format(
            data_tar = data_tar.path,
            pattern = kernel_pattern,
            output = vmlinuz.path,
        ),
        mnemonic = "ExtractKernel",
        progress_message = "Extracting kernel from debian package",
    )

    # Extract modules if a modules package is provided
    modules_tar = None
    if ctx.file.modules_package:
        modules_tar = ctx.actions.declare_file(ctx.label.name + ".modules.tar")
        ctx.actions.run_shell(
            inputs = [ctx.file.modules_package],
            outputs = [modules_tar],
            command = """
                set -e
                TMPDIR=$(mktemp -d)
                tar -xf {data_tar} -C "$TMPDIR" './lib/modules/' 2>/dev/null || {{
                    echo "ERROR: No modules found in package" >&2
                    tar -tf {data_tar} | head -20 >&2
                    exit 1
                }}
                tar -cf {output} -C "$TMPDIR" .
                rm -rf "$TMPDIR"
            """.format(
                data_tar = ctx.file.modules_package.path,
                output = modules_tar.path,
            ),
            mnemonic = "ExtractModules",
            progress_message = "Extracting kernel modules from debian package",
        )

    output_files = [vmlinuz]
    if modules_tar:
        output_files.append(modules_tar)

    return [
        DefaultInfo(files = depset(output_files)),
        LinuxKernelInfo(
            vmlinuz = vmlinuz,
            modules = modules_tar,
            system_map = None,
            headers = None,
            version = ctx.attr.version,
            arch = canonical_arch,
        ),
    ]

kernel_extract = rule(
    implementation = _kernel_extract_impl,
    attrs = {
        "package": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Kernel debian package data archive (data.tar.gz)",
        ),
        "modules_package": attr.label(
            allow_single_file = True,
            doc = "Kernel modules debian package data archive. If provided, modules are extracted.",
        ),
        "version": attr.string(
            default = "",
            doc = "Kernel version string",
        ),
        "arch": attr.string(
            default = "x86_64",
            values = ["x86_64", "amd64", "arm64"],
            doc = "Target architecture. Use x86_64 or arm64. amd64 is accepted as a legacy alias for x86_64.",
        ),
    },
    doc = "Extract a Linux kernel (and optionally modules) from Debian package data archives.",
)
