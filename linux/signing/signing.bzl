"""Rule for signing UKI/USI images for Secure Boot."""

def _sign_image_impl(ctx):
    """Sign a PE image for Secure Boot using usi-signer."""
    usi_file = ctx.file.image

    signed_output = ctx.actions.declare_file(ctx.label.name + ".efi")

    # Build certificate arguments
    cert_args = "-cert {}".format(ctx.file.cert.path)
    if ctx.files.additional_certs:
        cert_args += " " + " ".join([
            "-additional-cert {}".format(cert.path)
            for cert in ctx.files.additional_certs
        ])

    if ctx.attr.key_provider == "sops":
        if not ctx.executable.sops:
            fail("sops binary required when key_provider is 'sops'")
        if not ctx.file.sops_env_yaml:
            fail("sops_env_yaml required when key_provider is 'sops'")

        script = ctx.actions.declare_file(ctx.label.name + "_sign.sh")
        script_content = """#!/bin/bash
set -euo pipefail
"$PWD/{sops}" exec-env {sops_env_yaml} "$PWD/{signer} -input {usi} -output {output} {cert_args} -key-env {key_env_var}"
""".format(
            sops = ctx.executable.sops.path,
            sops_env_yaml = ctx.file.sops_env_yaml.path,
            usi = usi_file.path,
            cert_args = cert_args,
            output = signed_output.path,
            signer = ctx.executable.signer.path,
            key_env_var = ctx.attr.key_env_var,
        )

        ctx.actions.write(output = script, content = script_content, is_executable = True)

        ctx.actions.run(
            executable = script,
            inputs = [usi_file, ctx.file.cert] + ctx.files.additional_certs + [
                ctx.file.sops_env_yaml,
                ctx.executable.sops,
                ctx.executable.signer,
            ],
            outputs = [signed_output],
            mnemonic = "SignImage",
            progress_message = "Signing image with Secure Boot certificate chain",
            use_default_shell_env = True,
        )
    elif ctx.attr.key_provider == "env":
        script = ctx.actions.declare_file(ctx.label.name + "_sign.sh")
        script_content = """#!/bin/bash
set -euo pipefail
{signer} -input {usi} -output {output} {cert_args} -key-env {key_env_var}
""".format(
            usi = usi_file.path,
            cert_args = cert_args,
            output = signed_output.path,
            signer = ctx.executable.signer.path,
            key_env_var = ctx.attr.key_env_var,
        )

        ctx.actions.write(output = script, content = script_content, is_executable = True)

        ctx.actions.run(
            executable = script,
            inputs = [usi_file, ctx.file.cert] + ctx.files.additional_certs + [ctx.executable.signer],
            outputs = [signed_output],
            mnemonic = "SignImage",
            progress_message = "Signing image with Secure Boot certificate (env key)",
            use_default_shell_env = True,
        )
    else:
        fail("Unknown key_provider: {}".format(ctx.attr.key_provider))

    return [DefaultInfo(files = depset([signed_output]))]

sign_image = rule(
    implementation = _sign_image_impl,
    attrs = {
        "image": attr.label(
            mandatory = True,
            allow_single_file = [".efi"],
            doc = "Image to sign",
        ),
        "cert": attr.label(
            mandatory = True,
            allow_single_file = [".crt", ".pem", ".cer"],
            doc = "X.509 certificate file for signing",
        ),
        "additional_certs": attr.label_list(
            allow_files = [".crt", ".pem", ".cer"],
            doc = "Additional certificate files for the chain",
        ),
        "key_provider": attr.string(
            default = "sops",
            values = ["sops", "env"],
            doc = "Key provider: 'sops' (decrypt via SOPS) or 'env' (read from environment)",
        ),
        "sops_env_yaml": attr.label(
            allow_single_file = [".yaml", ".yml"],
            doc = "SOPS-encrypted YAML file (required for sops provider)",
        ),
        "key_env_var": attr.string(
            default = "SECUREBOOT_KEY",
            doc = "Environment variable name for the private key",
        ),
        "signer": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "usi-signer binary",
        ),
        "sops": attr.label(
            executable = True,
            cfg = "exec",
            doc = "SOPS binary (required for sops key_provider)",
        ),
    },
    doc = "Sign a PE image for Secure Boot. Supports SOPS or environment variable key providers.",
)
