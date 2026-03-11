"""Rule for extracting a kernel from a Debian package."""

load("//linux:providers.bzl", "LinuxKernelInfo")

_TAR_TOOLCHAIN_TYPE = "@aspect_bazel_lib//lib:tar_toolchain_type"

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

    # Hermetic bsdtar from aspect_bazel_lib
    bsdtar = ctx.toolchains[_TAR_TOOLCHAIN_TYPE]
    bsdtar_path = bsdtar.tarinfo.binary.path
    bsdtar_inputs = bsdtar.default.files

    vmlinuz = ctx.actions.declare_file(ctx.label.name + ".vmlinuz")

    ctx.actions.run_shell(
        inputs = depset(direct = [data_tar], transitive = [bsdtar_inputs]),
        outputs = [vmlinuz],
        command = """
            set -e
            BSDTAR="{bsdtar}"
            "$BSDTAR" -xf {data_tar} --include='{pattern}' -O > {output} 2>/dev/null || {{
                echo "ERROR: Pattern '{pattern}' not found in package" >&2
                echo "Package contents:" >&2
                "$BSDTAR" -tf {data_tar} 2>&1 | while IFS= read -r line; do
                    case "$line" in *vmlinuz*|*.efi*) echo "$line" >&2 ;; esac
                done
                exit 1
            }}
        """.format(
            bsdtar = bsdtar_path,
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
            inputs = depset(direct = [ctx.file.modules_package], transitive = [bsdtar_inputs]),
            outputs = [modules_tar],
            command = """
                set -e
                BSDTAR="{bsdtar}"
                TMPDIR=$(mktemp -d)
                "$BSDTAR" -xf {data_tar} -C "$TMPDIR" --include='./lib/modules/*' 2>/dev/null || {{
                    echo "ERROR: No modules found in package" >&2
                    n=0; "$BSDTAR" -tf {data_tar} 2>&1 | while IFS= read -r line; do
                        echo "$line" >&2; n=$((n+1)); [ "$n" -ge 20 ] && break
                    done
                    exit 1
                }}
                "$BSDTAR" -cf {output} -C "$TMPDIR" .
                rm -rf "$TMPDIR"
            """.format(
                bsdtar = bsdtar_path,
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
    toolchains = [_TAR_TOOLCHAIN_TYPE],
    doc = "Extract a Linux kernel (and optionally modules) from Debian package data archives.",
)
