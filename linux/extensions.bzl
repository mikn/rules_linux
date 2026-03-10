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
    },
}

def _ccache_repo_impl(ctx):
    version = ctx.attr.version
    platform = ctx.attr.platform

    info = _CCACHE_VERSIONS.get(version, {}).get(platform)
    if not info:
        fail("No ccache binary for version={}, platform={}".format(version, platform))

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
        "platform": attr.string(default = "linux-x86_64"),
    },
)

ccache = module_extension(
    implementation = _ccache_impl,
    tag_classes = {"download": _ccache_tag},
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
