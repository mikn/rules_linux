"""Analysis tests for the initrd rule.

Note: analysis_test from rules_testing may emit "size too big" warnings.
This is expected — the rules_testing API does not expose a way to set
test size, and the default size is adequate for analysis-only tests.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")

def _initrd_none_profile_impl(env, target):
    """Verify that initrd with STRIP_PROFILE_NONE can be analyzed."""
    env.expect.that_target(target).default_outputs().contains(
        "{package}/initrd_none.cpio.zst",
    )

def _initrd_server_profile_impl(env, target):
    """Verify that initrd with STRIP_PROFILE_SERVER (default) can be analyzed."""
    env.expect.that_target(target).default_outputs().contains(
        "{package}/initrd_server.cpio.zst",
    )

def _initrd_extra_excludes_impl(env, target):
    """Verify that initrd with extra_excludes can be analyzed."""
    env.expect.that_target(target).default_outputs().contains(
        "{package}/initrd_extra_excludes.cpio.zst",
    )

def initrd_test_suite(name):
    analysis_test(
        name = name + "_none_profile",
        impl = _initrd_none_profile_impl,
        target = ":initrd_none",
    )
    analysis_test(
        name = name + "_server_profile",
        impl = _initrd_server_profile_impl,
        target = ":initrd_server",
    )
    analysis_test(
        name = name + "_extra_excludes",
        impl = _initrd_extra_excludes_impl,
        target = ":initrd_extra_excludes",
    )
    native.test_suite(
        name = name,
        tests = [
            name + "_none_profile",
            name + "_server_profile",
            name + "_extra_excludes",
        ],
    )
