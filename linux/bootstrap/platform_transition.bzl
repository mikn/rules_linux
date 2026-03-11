"""Forces a dependency to be resolved under a specific platform.

rules_distroless gates its package filegroups behind platform-aware
select() (e.g. linux_arm64 requires @platforms//os:linux +
@platforms//cpu:arm64). This means cross-architecture builds (arm64
packages on an x86_64 host) and cross-OS builds (Linux packages on
macOS) fail at analysis time.

platform_dep applies an outgoing platform transition so the inner
dependency sees the correct platform constraints regardless of the host.
"""

def _platform_transition_impl(_settings, attr):
    return {"//command_line_option:platforms": [str(attr.platform)]}

_platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _platform_dep_impl(ctx):
    # Outgoing transitions wrap attr.label in a list.
    dep = ctx.attr.dep[0]
    return [DefaultInfo(files = dep[DefaultInfo].files)]

platform_dep = rule(
    implementation = _platform_dep_impl,
    attrs = {
        "dep": attr.label(
            mandatory = True,
            cfg = _platform_transition,
        ),
        "platform": attr.label(mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Forwards files from a dependency built under a specific platform.",
)
