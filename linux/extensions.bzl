"""Module extensions for rules_linux."""

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

# === Debian packages (wraps rules_distroless apt) ===

load("@rules_distroless//apt/private:deb_import.bzl", "deb_import")
load("@rules_distroless//apt/private:deb_resolve.bzl", "deb_resolve")
load("@rules_distroless//apt/private:deb_translate_lock.bzl", "deb_translate_lock")
load("@rules_distroless//apt/private:lockfile.bzl", "lockfile")

def _generate_manifest_yaml(packages, arch, snapshot, distro, components):
    """Generate a rules_distroless manifest YAML string from structured attrs."""
    lines = ["version: 1", ""]

    # Sources
    channel = distro + " " + " ".join(components)
    url = "https://snapshot.debian.org/archive/debian/" + snapshot
    lines.append("sources:")
    lines.append("  - channel: " + channel)
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

            # Create resolve repo (for `bazel run @name_resolve//:lock`)
            deb_resolve(
                name = pkg.name + "_resolve",
                manifest = "@" + pkg.name + "_manifest//:manifest.yaml",
                resolve_transitive = True,
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
