"""Module extensions for rules_linux."""

# buildifier: disable=bzl-visibility
load("@rules_distroless//apt/private:deb_import.bzl", "deb_import")

# buildifier: disable=bzl-visibility
load("@rules_distroless//apt/private:deb_resolve.bzl", "internal_resolve")

# buildifier: disable=bzl-visibility
load("@rules_distroless//apt/private:deb_translate_lock.bzl", "deb_translate_lock")

# buildifier: disable=bzl-visibility
load("@rules_distroless//apt/private:lockfile.bzl", "lockfile")

# === Kernel source tarball download ===

def _kernel_source_repo_impl(ctx):
    major = ctx.attr.version.split(".")[0]

    urls = ctx.attr.urls
    if not urls:
        urls = [
            "https://cdn.kernel.org/pub/linux/kernel/v{major}.x/linux-{version}.tar.xz".format(
                major = major,
                version = ctx.attr.version,
            ),
        ]

    filename = "linux-{version}.tar.xz".format(version = ctx.attr.version)

    ctx.download(
        url = urls,
        output = filename,
        sha256 = ctx.attr.sha256,
    )

    ctx.file("BUILD.bazel", """exports_files(
    ["{filename}"],
    visibility = ["//visibility:public"],
)
""".format(filename = filename))

_kernel_source_repo = repository_rule(
    implementation = _kernel_source_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "urls": attr.string_list(default = []),
    },
)

def _kernel_sources_impl(module_ctx):
    for mod in module_ctx.modules:
        for source in mod.tags.source:
            _kernel_source_repo(
                name = source.name,
                version = source.version,
                sha256 = source.sha256,
                urls = source.urls,
            )

_source_tag = tag_class(
    attrs = {
        "name": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "urls": attr.string_list(default = []),
    },
)

kernel_sources = module_extension(
    implementation = _kernel_sources_impl,
    tag_classes = {"source": _source_tag},
)

# === ccache download ===

_CCACHE_VERSIONS = {
    "4.13": {
        "linux-x86_64": {
            "url": "https://github.com/ccache/ccache/releases/download/v4.13/ccache-4.13-linux-x86_64-glibc.tar.xz",
            "sha256": "c405e18c3ce2d27439078941cd0d41552672ad5629400218223756868a5eb978",
            "strip_prefix": "ccache-4.13-linux-x86_64-glibc",
        },
        "linux-aarch64": {
            "url": "https://github.com/ccache/ccache/releases/download/v4.13/ccache-4.13-linux-aarch64-glibc.tar.xz",
            "sha256": "c95059893afcdbb9657294c5c1dc794a149137e54e51ccdf623f1333635aed06",
            "strip_prefix": "ccache-4.13-linux-aarch64-glibc",
        },
        "darwin": {
            # Universal binary covering both x86_64 and arm64 (Apple Silicon).
            "url": "https://github.com/ccache/ccache/releases/download/v4.13/ccache-4.13-darwin.tar.gz",
            "sha256": "5e1b2835dc3629e6e85133f18e90b00e6fb0c7ecc3cfb8a46de3e20cbc4297d1",
            "strip_prefix": "ccache-4.13-darwin",
        },
    },
}

def _detect_host_platform(ctx):
    """Detect the host platform from repository_ctx.os.

    # Requires repository_ctx (has .os attribute), not module_ctx.

    Returns a platform key matching _CCACHE_VERSIONS entries:
      "linux-x86_64", "linux-aarch64", or "darwin".
    Returns None if the host is not recognised.
    """
    os_name = ctx.os.name.lower()
    os_arch = ctx.os.arch.lower()

    if os_name == "linux":
        if os_arch in ("x86_64", "amd64"):
            return "linux-x86_64"
        if os_arch in ("aarch64", "arm64"):
            return "linux-aarch64"
    elif os_name.startswith("mac") or os_name == "darwin":
        # ccache ships a universal binary for Darwin — covers both Intel and Apple Silicon.
        return "darwin"

    return None

def _ccache_repo_impl(ctx):
    version = ctx.attr.version
    platform = ctx.attr.platform

    # Auto-detect host platform when platform == "auto".
    if platform == "auto":
        platform = _detect_host_platform(ctx)
        if not platform:
            fail(
                "ccache: could not auto-detect host platform " +
                "(os={}, arch={}). ".format(ctx.os.name, ctx.os.arch) +
                "Set platform explicitly to one of: linux-x86_64, linux-aarch64, darwin.",
            )

    info = _CCACHE_VERSIONS.get(version, {}).get(platform)
    if not info:
        fail("No ccache binary for version={}, platform={}. Available platforms for this version: {}".format(
            version,
            platform,
            ", ".join(_CCACHE_VERSIONS.get(version, {}).keys()),
        ))

    ctx.download_and_extract(
        url = info["url"],
        sha256 = info["sha256"],
        stripPrefix = info["strip_prefix"],
    )

    ctx.file("BUILD.bazel", """exports_files(["ccache"], visibility = ["//visibility:public"])
""")

_ccache_repo = repository_rule(
    implementation = _ccache_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
)

def _ccache_impl(module_ctx):
    for mod in module_ctx.modules:
        for dl in mod.tags.download:
            _ccache_repo(
                name = dl.name,
                version = dl.version,
                platform = dl.platform,
            )

_ccache_tag = tag_class(
    attrs = {
        "name": attr.string(default = "ccache"),
        "version": attr.string(default = "4.13"),
        "platform": attr.string(
            default = "auto",
            doc = """Host platform for the ccache binary.

Supported values:
  "auto"          — detect from repository_ctx.os at fetch time (default)
  "linux-x86_64"  — Linux on x86_64 (glibc)
  "linux-aarch64" — Linux on ARM64 (glibc)
  "darwin"        — macOS universal binary (Intel + Apple Silicon)
""",
        ),
    },
)

ccache = module_extension(
    implementation = _ccache_impl,
    tag_classes = {"download": _ccache_tag},
    os_dependent = True,
)

# === Test artifacts (generic file downloads) ===

def _http_file_repo_impl(ctx):
    """Download a single file and expose it."""
    ctx.download(
        url = ctx.attr.urls,
        output = ctx.attr.downloaded_file_name,
        sha256 = ctx.attr.sha256,
        executable = ctx.attr.executable,
    )
    ctx.file("BUILD.bazel", """exports_files(
    ["{filename}"],
    visibility = ["//visibility:public"],
)
""".format(filename = ctx.attr.downloaded_file_name))

_http_file_repo = repository_rule(
    implementation = _http_file_repo_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(default = ""),
        "downloaded_file_name": attr.string(default = "file"),
        "executable": attr.bool(default = False),
    },
)

def _test_artifacts_impl(module_ctx):
    for mod in module_ctx.modules:
        for f in mod.tags.http_file:
            _http_file_repo(
                name = f.name,
                urls = f.urls,
                sha256 = f.sha256,
                downloaded_file_name = f.downloaded_file_name,
                executable = f.executable,
            )

_http_file_tag = tag_class(
    attrs = {
        "name": attr.string(mandatory = True),
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(default = ""),
        "downloaded_file_name": attr.string(default = "file"),
        "executable": attr.bool(default = False),
    },
)

test_artifacts = module_extension(
    implementation = _test_artifacts_impl,
    tag_classes = {"http_file": _http_file_tag},
)

# === VM toolchain (Linux LLVM distribution for kernel_build VM) ===

_LLVM_BASE_URL = "https://github.com/llvm/llvm-project/releases/download/llvmorg-{version}"

def _vm_llvm_repo_impl(ctx):
    """Download the Linux LLVM binary distribution for use inside the kernel_build VM."""
    version = ctx.attr.version
    arch = ctx.attr.arch

    # LLVM release naming is inconsistent across architectures:
    #   x86_64: LLVM-{version}-Linux-X64.tar.xz (new scheme, LLVM 19+)
    #   arm64:  clang+llvm-{version}-aarch64-linux-gnu.tar.xz (legacy scheme)
    if arch == "amd64":
        filename = "LLVM-{version}-Linux-X64.tar.xz".format(version = version)
    elif arch == "arm64":
        filename = "clang+llvm-{version}-aarch64-linux-gnu.tar.xz".format(version = version)
    else:
        fail("Unsupported arch for vm_llvm: %s (expected amd64 or arm64)" % arch)

    urls = ctx.attr.urls
    if not urls:
        urls = [
            "{base}/{filename}".format(
                base = _LLVM_BASE_URL.format(version = version),
                filename = filename,
            ),
        ]

    ctx.download(
        url = urls,
        output = filename,
        sha256 = ctx.attr.sha256,
    )

    # Create a stable name so consumers don't need to know the version.
    ctx.symlink(filename, "llvm.tar.xz")

    ctx.file("BUILD.bazel", """\
exports_files(
    ["llvm.tar.xz"],
    visibility = ["//visibility:public"],
)
""")

_vm_llvm_repo = repository_rule(
    implementation = _vm_llvm_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "arch": attr.string(mandatory = True),
        "sha256": attr.string(default = ""),
        "urls": attr.string_list(default = []),
    },
)

def _vm_toolchain_impl(module_ctx):
    created_names = {}
    root_direct_deps = []
    root_direct_dev_deps = []

    # module_ctx.modules iterates root-first, so the consumer's version
    # takes priority over the default version provided by rules_linux.
    for mod in module_ctx.modules:
        for llvm in mod.tags.llvm:
            name = llvm.name

            if name in created_names:
                # Already created by a higher-priority module (root wins).
                continue
            created_names[name] = True

            # Resolve per-arch SHA-256 and URLs from dict attrs.
            amd64_sha = llvm.sha256.get("amd64", "")
            arm64_sha = llvm.sha256.get("arm64", "")
            amd64_urls = llvm.urls.get("amd64", [])
            arm64_urls = llvm.urls.get("arm64", [])

            _vm_llvm_repo(
                name = name + "_amd64",
                version = llvm.version,
                arch = "amd64",
                sha256 = amd64_sha,
                urls = amd64_urls,
            )
            _vm_llvm_repo(
                name = name + "_arm64",
                version = llvm.version,
                arch = "arm64",
                sha256 = arm64_sha,
                urls = arm64_urls,
            )

            if mod.is_root:
                names = [name + "_amd64", name + "_arm64"]
                if module_ctx.is_dev_dependency(llvm):
                    root_direct_dev_deps.extend(names)
                else:
                    root_direct_deps.extend(names)

    return module_ctx.extension_metadata(
        root_module_direct_deps = root_direct_deps,
        root_module_direct_dev_deps = root_direct_dev_deps,
    )

_llvm_tag = tag_class(
    attrs = {
        "name": attr.string(default = "vm_llvm"),
        "version": attr.string(
            mandatory = True,
            doc = "LLVM version to download (e.g., '19.1.7'). Use the same version as your toolchains_llvm registration.",
        ),
        "sha256": attr.string_dict(
            default = {},
            doc = 'Per-arch SHA-256 digests: {"amd64": "...", "arm64": "..."}. Omit for non-hermetic fetches.',
        ),
        "urls": attr.string_list_dict(
            default = {},
            doc = 'Per-arch URL overrides: {"amd64": ["..."], "arm64": ["..."]}. Defaults to GitHub releases.',
        ),
    },
    doc = """Download the Linux LLVM binary distribution for the kernel_build VM worker.

The VM worker boots a Linux QEMU VM to build kernels on macOS. It needs Linux-native
LLVM binaries (clang, lld, llvm-ar, etc.) — the host macOS toolchain can't run inside
the VM. This extension downloads the official LLVM release for Linux.

Use the same LLVM version as your toolchains_llvm registration to ensure parity:

```starlark
LLVM_VERSION = "19.1.7"

llvm = use_extension("@toolchains_llvm//toolchain/extensions:llvm.bzl", "llvm")
llvm.toolchain(name = "llvm_toolchain", llvm_versions = {"": LLVM_VERSION})

vm_toolchain = use_extension("@rules_linux//linux:extensions.bzl", "vm_toolchain")
vm_toolchain.llvm(version = LLVM_VERSION)
use_repo(vm_toolchain, "vm_llvm_amd64", "vm_llvm_arm64")
```

Then `@vm_llvm_amd64` and `@vm_llvm_arm64` are available as toolchain inputs.
""",
)

vm_toolchain = module_extension(
    implementation = _vm_toolchain_impl,
    tag_classes = {"llvm": _llvm_tag},
)

# === Debian packages (wraps rules_distroless apt) ===

_RESOLVE_BUILD = """\
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

filegroup(
    name = "lockfile",
    srcs = ["lock.json"],
    tags = ["manual"],
    visibility = ["//visibility:public"],
)

sh_binary(
    name = "lock",
    srcs = ["copy.sh"],
    data = ["lock.json"],
    tags = ["manual"],
    args = ["$(location :lock.json)"],
    visibility = ["//visibility:public"],
)
"""

_RESOLVE_COPY_SH = """\
#!/usr/bin/env bash
set -euo pipefail
lock=$(realpath "$1")
cd "$BUILD_WORKSPACE_DIRECTORY"
echo "Writing lockfile to {lock_path}"
cp "$lock" "{lock_path}"
"""

def _packages_resolve_impl(rctx):
    """Resolve Debian packages and generate a lock file with correct output path."""
    lockf = internal_resolve(
        rctx,
        rctx.attr.yq_toolchain_prefix,
        rctx.attr.manifest,
        rctx.attr.resolve_transitive,
    )
    lockf.write("lock.json")

    rctx.file("copy.sh", _RESOLVE_COPY_SH.format(
        lock_path = rctx.attr.lock_path,
    ), executable = True)

    rctx.file("BUILD.bazel", _RESOLVE_BUILD)

_packages_resolve = repository_rule(
    implementation = _packages_resolve_impl,
    attrs = {
        "manifest": attr.label(mandatory = True),
        "resolve_transitive": attr.bool(default = True),
        "lock_path": attr.string(mandatory = True),
        "yq_toolchain_prefix": attr.string(default = "yq"),
    },
)

def _generate_manifest_yaml(packages, arch, snapshot, distro, components):
    """Generate a rules_distroless manifest YAML string from structured attrs."""
    lines = ["version: 1", ""]

    # Sources — one entry per component to match rules_distroless expectations
    url = "https://snapshot.debian.org/archive/debian/" + snapshot
    lines.append("sources:")
    for component in components:
        lines.append("  - channel: " + distro + " " + component)
        lines.append("    url: " + url)
    lines.append("")

    # Architectures
    lines.append("archs:")
    lines.append("  - " + arch)
    lines.append("")

    # Packages
    lines.append("packages:")
    for pkg in packages:
        lines.append("  - " + pkg)

    return "\n".join(lines) + "\n"

def _debian_manifest_repo_impl(ctx):
    """Repository rule that generates a manifest YAML from attrs."""
    ctx.file("manifest.yaml", ctx.attr.content)
    ctx.file("BUILD.bazel", """\
exports_files(["manifest.yaml"], visibility = ["//visibility:public"])
""")

_debian_manifest_repo = repository_rule(
    implementation = _debian_manifest_repo_impl,
    attrs = {
        "content": attr.string(mandatory = True),
    },
)

def _packages_impl(module_ctx):
    root_direct_deps = []
    root_direct_dev_deps = []

    for mod in module_ctx.modules:
        for pkg in mod.tags.debian:
            yaml_content = _generate_manifest_yaml(
                packages = pkg.packages,
                arch = pkg.arch,
                snapshot = pkg.snapshot,
                distro = pkg.distro,
                components = pkg.components,
            )

            # Generate manifest repo (for lock regeneration and documentation)
            _debian_manifest_repo(
                name = pkg.name + "_manifest",
                content = yaml_content,
            )

            # Compute workspace-relative lock path from label
            if pkg.lock:
                lock_path = "{}{}".format(
                    ("%s/" % pkg.lock.package) if pkg.lock.package else "",
                    pkg.lock.name,
                )
            else:
                lock_path = pkg.name + ".lock.json"

            # Create resolve repo (for `bazel run @name_resolve//:lock`)
            _packages_resolve(
                name = pkg.name + "_resolve",
                manifest = "@" + pkg.name + "_manifest//:manifest.yaml",
                resolve_transitive = True,
                lock_path = lock_path,
            )

            if pkg.lock:
                # Production path: use checked-in lock file
                lock_content = module_ctx.read(pkg.lock)
                lockf = lockfile.from_json(module_ctx, lock_content)

                for package in lockf.packages():
                    package_key = lockfile.make_package_key(
                        package["name"],
                        package["version"],
                        package["arch"],
                    )
                    deb_import(
                        name = "%s_%s" % (pkg.name, package_key),
                        urls = package["urls"],
                        sha256 = package["sha256"],
                    )

                deb_translate_lock(
                    name = pkg.name,
                    lock = pkg.lock,
                    lock_content = lockf.as_json(),
                )
            else:
                # Bootstrap path: resolve on-the-fly (non-hermetic)
                # buildifier: disable=print
                print("\nNo lock file for '%s'. Run `bazel run @%s_resolve//:lock` to generate one." % (pkg.name, pkg.name))

                # Still create the translate repo with empty content so
                # the repo name exists (avoids confusing errors)
                lockf = lockfile.from_json(module_ctx, None)
                deb_translate_lock(
                    name = pkg.name,
                    lock_content = lockf.as_json(),
                )

            if mod.is_root:
                if module_ctx.is_dev_dependency(pkg):
                    root_direct_dev_deps.append(pkg.name)
                    root_direct_dev_deps.append(pkg.name + "_resolve")
                else:
                    root_direct_deps.append(pkg.name)
                    root_direct_deps.append(pkg.name + "_resolve")

    return module_ctx.extension_metadata(
        root_module_direct_deps = root_direct_deps,
        root_module_direct_dev_deps = root_direct_dev_deps,
    )

_debian_tag = tag_class(
    attrs = {
        "name": attr.string(
            mandatory = True,
            doc = "Name of the generated repository. Use @name//:flat for the merged rootfs tar.",
        ),
        "packages": attr.string_list(
            mandatory = True,
            doc = "List of Debian package names to install.",
        ),
        "arch": attr.string(
            default = "amd64",
            doc = "Debian architecture (amd64, arm64, etc.).",
        ),
        "snapshot": attr.string(
            mandatory = True,
            doc = "Debian snapshot timestamp (e.g., '20250101T000000Z').",
        ),
        "distro": attr.string(
            default = "bookworm",
            doc = "Debian distribution codename.",
        ),
        "components": attr.string_list(
            default = ["main"],
            doc = "Repository components (e.g., ['main', 'non-free-firmware']).",
        ),
        "lock": attr.label(
            doc = "Lock file for hermetic builds. Generate with: bazel run @<name>_resolve//:lock",
        ),
    },
    doc = """Declare Debian packages to install into a rootfs.

Example:
```starlark
packages = use_extension("@rules_linux//linux:extensions.bzl", "packages")
packages.debian(
    name = "my_debian",
    packages = ["nginx", "curl", "ca-certificates"],
    arch = "amd64",
    snapshot = "20250101T000000Z",
    lock = "//:my_debian.lock.json",
)
use_repo(packages, "my_debian")
```

Then use `@my_debian//:flat` in your rootfs composition.
""",
)

packages = module_extension(
    implementation = _packages_impl,
    tag_classes = {"debian": _debian_tag},
)
