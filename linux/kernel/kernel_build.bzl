"""Rule for building a Linux kernel from source using Bazel-managed toolchains.

Uses hermetic toolchains for: LLVM (CC), flex, bison, python3, perl, make.
Host dependency: bc (no BCR module available).
"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain", "use_cpp_toolchain")
load("//linux:providers.bzl", "LinuxKernelInfo")

_FLEX_TOOLCHAIN_TYPE = "@rules_flex//flex:toolchain_type"
_BISON_TOOLCHAIN_TYPE = "@rules_bison//bison:toolchain_type"
_PYTHON_TOOLCHAIN_TYPE = "@rules_python//python:toolchain_type"
_PERL_TOOLCHAIN_TYPE = "@rules_perl//perl:toolchain_type"
_MAKE_TOOLCHAIN_TYPE = "@rules_foreign_cc//toolchains:make_toolchain"

def _find_file_in_depset(files, basename):
    """Find a file by name in a depset."""
    for f in files.to_list():
        if f.basename == basename and "/bin/" in f.path:
            return f
    return None

def _find_file_by_suffix(files, suffix):
    """Find a file by path suffix in a depset."""
    for f in files.to_list():
        if f.path.endswith(suffix):
            return f
    return None

def _bin_dir(path):
    """Get the directory portion of a path."""
    return path.rsplit("/", 1)[0] if "/" in path else ""

def _kernel_build_impl(ctx):
    source_tarball = ctx.file.source_tarball
    arch = ctx.attr.arch

    # Normalize legacy amd64 alias to x86_64, matching kernel_extract behaviour.
    if arch == "amd64":
        arch = "x86_64"

    if arch == "x86_64":
        karch = "x86"
        image_target = "bzImage"
        image_path = "arch/x86/boot/bzImage"
    elif arch == "arm64":
        karch = "arm64"
        image_target = "Image"
        image_path = "arch/arm64/boot/Image"
    else:
        fail("Unsupported architecture: {}".format(arch))

    vmlinuz = ctx.actions.declare_file(ctx.label.name + ".vmlinuz")
    system_map = ctx.actions.declare_file(ctx.label.name + ".System.map")
    modules_tar = ctx.actions.declare_file(ctx.label.name + ".modules.tar")
    dot_config = ctx.actions.declare_file(ctx.label.name + ".config")

    jobs = str(ctx.attr.make_jobs) if ctx.attr.make_jobs > 0 else "$(nproc)"

    # === Resolve all toolchains ===

    # CC (LLVM)
    cc_toolchain = find_cpp_toolchain(ctx)
    llvm_bin_dir = _bin_dir(cc_toolchain.compiler_executable)

    # Flex
    flex_info = ctx.toolchains[_FLEX_TOOLCHAIN_TYPE].flex_toolchain
    flex_executable = flex_info.flex_tool.executable
    flex_bin_dir = _bin_dir(flex_executable.path)

    # Bison
    bison_info = ctx.toolchains[_BISON_TOOLCHAIN_TYPE].bison_toolchain
    bison_executable = bison_info.bison_tool.executable
    bison_bin_dir = _bin_dir(bison_executable.path)

    # Python
    py_toolchain = ctx.toolchains[_PYTHON_TOOLCHAIN_TYPE]
    py_runtime = py_toolchain.py3_runtime
    py_interpreter = py_runtime.interpreter
    py_bin_dir = _bin_dir(py_interpreter.path) if py_interpreter else ""

    # Perl
    perl_toolchain = ctx.toolchains[_PERL_TOOLCHAIN_TYPE]
    perl_info = perl_toolchain.perl_runtime
    perl_interpreter = perl_info.interpreter
    perl_bin_dir = _bin_dir(perl_interpreter.path)

    # Make (rules_foreign_cc wraps ToolInfo in .data)
    make_toolchain = ctx.toolchains[_MAKE_TOOLCHAIN_TYPE]
    make_data = make_toolchain.data
    make_tool_target = make_data.target
    make_path = make_data.path

    # === Build environment setup for flex/bison internal deps ===

    # m4 (needed by both flex and bison)
    m4_tool = _find_file_in_depset(flex_info.all_files, "m4")
    if not m4_tool:
        m4_tool = _find_file_in_depset(bison_info.all_files, "m4")

    env_lines = []
    if m4_tool:
        env_lines.append('export M4="$EXECROOT/{m4}"'.format(m4 = m4_tool.path))

    # BISON_PKGDATADIR (bison needs its data files)
    for f in bison_info.all_files.to_list():
        if f.basename == "m4sugar.m4" and "m4sugar" in f.path:
            data_dir = f.path.rsplit("/m4sugar/", 1)[0]
            env_lines.append('export BISON_PKGDATADIR="$EXECROOT/{data_dir}"'.format(data_dir = data_dir))
            break

    toolchain_env_setup = "\n".join(env_lines)

    # === Build PATH with all toolchain bin dirs ===
    # The LLVM distribution's real binaries (clang, ld.lld, etc.) live in a
    # separate repo from cc_wrapper.sh. Add both so that tools like ccache
    # and the kernel's LLVM=1 mode can find clang directly.
    llvm_dist_bin_dir = llvm_bin_dir.replace("llvm_toolchain/bin", "llvm_toolchain_llvm/bin")
    path_dirs = []
    if llvm_bin_dir:
        path_dirs.append("$EXECROOT/" + llvm_bin_dir)
    if llvm_dist_bin_dir != llvm_bin_dir:
        path_dirs.append("$EXECROOT/" + llvm_dist_bin_dir)
    if flex_bin_dir:
        path_dirs.append("$EXECROOT/" + flex_bin_dir)
    if bison_bin_dir:
        path_dirs.append("$EXECROOT/" + bison_bin_dir)
    if py_bin_dir:
        path_dirs.append("$EXECROOT/" + py_bin_dir)
    if perl_bin_dir:
        path_dirs.append("$EXECROOT/" + perl_bin_dir)

    path_setup = ":".join(path_dirs) + ":$PATH" if path_dirs else "$PATH"

    # === Resolve make path ===
    # rules_foreign_cc make toolchain provides either a built make (target != None)
    # or a preinstalled make (path is absolute)
    if make_tool_target:
        make_cmd = "$EXECROOT/" + make_path
    else:
        make_cmd = make_path

    # === ccache setup ===
    ccache_setup = ""
    if ctx.file.ccache:
        ccache_dir = ctx.attr.ccache_dir if ctx.attr.ccache_dir else "/tmp/bazel-ccache"
        # Use ccache's symlink/hardlink mode: create a directory with "clang" symlinked
        # to ccache, placed first on PATH. When invoked as "clang", ccache looks for the
        # real "clang" further down PATH and caches the compilation.
        ccache_setup = """export CCACHE_DIR="{dir}"
export CCACHE_BASEDIR="$SRCDIR"
mkdir -p "$CCACHE_DIR"
CCACHE_LINKS=$(mktemp -d)
ln -s "$EXECROOT/{ccache}" "$CCACHE_LINKS/clang"
export PATH="$CCACHE_LINKS:$PATH"
""".format(
            dir = ccache_dir,
            ccache = ctx.file.ccache.path,
        )
        # No make flags needed — LLVM=1 sets CC=clang, and our PATH-first
        # ccache symlink intercepts it.

    # === Collect all toolchain files as inputs ===
    toolchain_file_sets = [
        cc_toolchain.all_files,
        flex_info.all_files,
        bison_info.all_files,
    ]

    direct_tools = [flex_executable, bison_executable]

    if py_interpreter:
        direct_tools.append(py_interpreter)
    if py_runtime.files:
        toolchain_file_sets.append(py_runtime.files)

    direct_tools.append(perl_interpreter)
    if perl_info.runtime:
        toolchain_file_sets.append(perl_info.runtime)

    if make_tool_target:
        toolchain_file_sets.append(make_tool_target[DefaultInfo].files)

    toolchain_inputs = depset(
        direct = direct_tools,
        transitive = toolchain_file_sets,
    )

    inputs = [source_tarball]

    if ctx.file.ccache:
        inputs.append(ctx.file.ccache)

    # === Build config setup ===
    if ctx.file.config:
        config_lines = [
            'cp "{config}" "$SRCDIR/.config"'.format(config = ctx.file.config.path),
        ]
        inputs.append(ctx.file.config)

        for frag in ctx.files.config_fragments:
            config_lines.append('cat "{frag}" >> "$SRCDIR/.config"'.format(frag = frag.path))
            inputs.append(frag)

        config_lines.append(
            '{make} -C "$SRCDIR" olddefconfig ARCH={karch} -j{jobs} > /dev/null'.format(
                make = make_cmd,
                karch = karch,
                jobs = jobs,
            ),
        )
        config_setup = "\n".join(config_lines)
    elif ctx.attr.defconfig:
        config_lines = [
            '{make} -C "$SRCDIR" {defconfig} ARCH={karch} > /dev/null'.format(
                make = make_cmd,
                defconfig = ctx.attr.defconfig,
                karch = karch,
            ),
        ]

        for frag in ctx.files.config_fragments:
            config_lines.append("""
while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" == "#"* && "$line" != "# CONFIG_"* ]] && continue
    case "$line" in
        CONFIG_*=y) opt="${{line%%=*}}"; "$SRCDIR/scripts/config" --file "$SRCDIR/.config" --enable "$opt" ;;
        CONFIG_*=m) opt="${{line%%=*}}"; "$SRCDIR/scripts/config" --file "$SRCDIR/.config" --module "$opt" ;;
        CONFIG_*=*) opt="${{line%%=*}}"; val="${{line#*=}}"; "$SRCDIR/scripts/config" --file "$SRCDIR/.config" --set-val "$opt" "$val" ;;
        "# CONFIG_"*) opt=$(echo "$line" | sed 's/# \\(CONFIG_[^ ]*\\) is not set/\\1/'); "$SRCDIR/scripts/config" --file "$SRCDIR/.config" --disable "$opt" ;;
    esac
done < "{frag}" """.format(frag = frag.path))
            inputs.append(frag)

        config_lines.append(
            '{make} -C "$SRCDIR" olddefconfig ARCH={karch} -j{jobs} > /dev/null'.format(
                make = make_cmd,
                karch = karch,
                jobs = jobs,
            ),
        )
        config_setup = "\n".join(config_lines)
    else:
        fail("Either config or defconfig must be specified")

    extra_flags = " ".join(ctx.attr.extra_make_flags)

    script = """#!/bin/bash
set -euo pipefail

# Resolve toolchain paths to absolute (kernel build changes cwd)
EXECROOT=$(pwd)
export PATH="{path_setup}"
{toolchain_env_setup}

SRCDIR=$(mktemp -d)

# Extract source
tar -xf {source} -C "$SRCDIR" --strip-components=1

{ccache_setup}

# Configure
{config_setup}

# Build kernel and modules using LLVM toolchain
{make} -C "$SRCDIR" LLVM=1 ARCH={karch} -j{jobs} {image_target} modules {extra_flags}

# Copy outputs
cp "$SRCDIR/{image_path}" {vmlinuz}
cp "$SRCDIR/System.map" {system_map}
cp "$SRCDIR/.config" {dot_config}

# Install and tar modules
MODDIR=$(mktemp -d)
{make} -C "$SRCDIR" LLVM=1 ARCH={karch} modules_install INSTALL_MOD_PATH="$MODDIR" > /dev/null 2>&1
tar -cf {modules_tar} -C "$MODDIR" .

# Cleanup
rm -rf "$SRCDIR" "$MODDIR"
""".format(
        path_setup = path_setup,
        toolchain_env_setup = toolchain_env_setup,
        source = source_tarball.path,
        ccache_setup = ccache_setup,
        config_setup = config_setup,
        make = make_cmd,
        karch = karch,
        jobs = jobs,
        image_target = image_target,
        image_path = image_path,
        extra_flags = extra_flags,
        vmlinuz = vmlinuz.path,
        system_map = system_map.path,
        modules_tar = modules_tar.path,
        dot_config = dot_config.path,
    )

    execution_requirements = {
        "no-remote": "1",
    }

    ctx.actions.run_shell(
        inputs = depset(direct = inputs, transitive = [toolchain_inputs]),
        outputs = [vmlinuz, system_map, modules_tar, dot_config],
        command = script,
        mnemonic = "KernelBuild",
        progress_message = "Building Linux kernel %s (%s)" % (ctx.attr.version, arch),
        execution_requirements = execution_requirements,
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(files = depset([vmlinuz, system_map, modules_tar])),
        LinuxKernelInfo(
            vmlinuz = vmlinuz,
            modules = modules_tar,
            system_map = system_map,
            headers = None,
            version = ctx.attr.version,
            arch = arch,
        ),
        OutputGroupInfo(
            vmlinuz = depset([vmlinuz]),
            system_map = depset([system_map]),
            modules = depset([modules_tar]),
            config = depset([dot_config]),
        ),
    ]

kernel_build = rule(
    implementation = _kernel_build_impl,
    attrs = {
        "source_tarball": attr.label(
            mandatory = True,
            allow_single_file = [".tar.xz", ".tar.gz", ".tgz", ".tar.bz2", ".tar.zst", ".tar"],
            doc = "Kernel source tarball (e.g., linux-6.12.tar.xz)",
        ),
        "config": attr.label(
            allow_single_file = True,
            doc = "Full kernel .config file. Mutually exclusive with defconfig.",
        ),
        "defconfig": attr.string(
            doc = "Defconfig target (e.g., 'defconfig', 'tinyconfig'). Mutually exclusive with config.",
        ),
        "config_fragments": attr.label_list(
            allow_files = True,
            doc = "Config fragment files applied after the base config. Standard .config snippet format.",
        ),
        "arch": attr.string(
            default = "x86_64",
            values = ["x86_64", "amd64", "arm64"],
            doc = "Target architecture. amd64 is a legacy alias for x86_64.",
        ),
        "make_jobs": attr.int(
            default = 0,
            doc = "Parallel make jobs. 0 = auto (nproc).",
        ),
        "extra_make_flags": attr.string_list(
            default = [],
            doc = "Additional flags passed to make",
        ),
        "version": attr.string(
            mandatory = True,
            doc = "Kernel version string (e.g., '6.12.1')",
        ),
        "ccache": attr.label(
            allow_single_file = True,
            doc = """ccache binary for incremental compilation caching.
Point at @ccache//:ccache from the ccache extension. Requires both
--sandbox_add_mount_pair and --sandbox_writable_path in .bazelrc.""",
        ),
        "ccache_dir": attr.string(
            default = "/tmp/bazel-ccache",
            doc = "Directory for ccache storage. Must match sandbox mount pair and writable path in .bazelrc.",
        ),
    },
    toolchains = use_cpp_toolchain() + [
        _FLEX_TOOLCHAIN_TYPE,
        _BISON_TOOLCHAIN_TYPE,
        _PYTHON_TOOLCHAIN_TYPE,
        _PERL_TOOLCHAIN_TYPE,
        _MAKE_TOOLCHAIN_TYPE,
    ],
    doc = """Build a Linux kernel from source.

Uses Bazel-managed toolchains: LLVM (CC), flex, bison, python3, perl, make.
Host dependency: bc (no BCR module available).

Produces LinuxKernelInfo provider (same as kernel_extract).
The resolved .config is available via --output_groups=config.

Incremental builds with ccache:
    For faster iteration when changing config flags, use the ccache
    attribute with the Bazel-managed ccache binary and add to .bazelrc:

        build --sandbox_add_mount_pair=/tmp/bazel-ccache:/tmp/bazel-ccache
        build --sandbox_writable_path=/tmp/bazel-ccache

    Both flags are needed: mount_pair bind-mounts the host directory
    into the sandbox, writable_path makes it writable. Or set a custom
    ccache_dir and matching flags. Only translation units affected by
    config changes will recompile on subsequent builds.

Example:
    kernel_build(
        name = "linux_6_12",
        source_tarball = "@linux_6_12//:linux-6.12.13.tar.xz",
        defconfig = "defconfig",
        config_fragments = [":kvm.fragment"],
        arch = "x86_64",
        version = "6.12.13",
        ccache = "@ccache//:ccache",
    )
""",
)
