"""Analysis tests for the kernel_extract rule.

Note: analysis_test from rules_testing may emit "size too big" warnings.
This is expected — the rules_testing API does not expose a way to set
test size, and the default size is adequate for analysis-only tests.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//linux:providers.bzl", "LinuxKernelInfo")

def _provides_kernel_info_impl(env, target):
    env.expect.that_target(target).has_provider(LinuxKernelInfo)
    ki = target[LinuxKernelInfo]
    env.expect.that_str(ki.arch).equals("x86_64")
    env.expect.that_str(ki.version).equals("6.12.1")

def _amd64_normalizes_impl(env, target):
    env.expect.that_target(target).has_provider(LinuxKernelInfo)
    ki = target[LinuxKernelInfo]
    env.expect.that_str(ki.arch).equals("x86_64")

def _arm64_arch_impl(env, target):
    env.expect.that_target(target).has_provider(LinuxKernelInfo)
    ki = target[LinuxKernelInfo]
    env.expect.that_str(ki.arch).equals("arm64")

def kernel_extract_test_suite(name):
    analysis_test(
        name = name + "_provides_info",
        impl = _provides_kernel_info_impl,
        target = ":kernel_extract_x86",
    )
    analysis_test(
        name = name + "_amd64_normalizes",
        impl = _amd64_normalizes_impl,
        target = ":kernel_extract_amd64",
    )
    analysis_test(
        name = name + "_arm64_arch",
        impl = _arm64_arch_impl,
        target = ":kernel_extract_arm64",
    )
    native.test_suite(
        name = name,
        tests = [
            name + "_provides_info",
            name + "_amd64_normalizes",
            name + "_arm64_arch",
        ],
    )
