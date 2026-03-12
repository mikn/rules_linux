"""Test helper for verifying tar contents."""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

def verify_tar_test(name, tar, assertions):
    """Test that a tar file contains expected entries.

    Args:
        name: Test target name.
        tar: Label of the tar file to inspect.
        assertions: Label of the assertions file.
    """
    sh_test(
        name = name,
        srcs = ["verify_tar.sh"],
        args = ["$(location %s)" % tar, "$(location %s)" % assertions],
        data = [tar, assertions],
    )
