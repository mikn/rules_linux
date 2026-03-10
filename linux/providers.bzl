"""Providers for rules_linux."""

LinuxKernelInfo = provider(
    doc = "Information about a Linux kernel",
    fields = {
        "vmlinuz": "File: compressed kernel image",
        "modules": "File: tar of kernel modules (optional)",
        "system_map": "File: System.map (optional)",
        "headers": "File: tar of kernel headers (optional)",
        "version": "string: kernel version",
        "arch": "string: x86_64 or aarch64",
    },
)

LinuxImageInfo = provider(
    doc = "Information about a Linux image (UKI or ISO)",
    fields = {
        "image": "File: assembled image (.efi or .iso)",
        "format": "string: uki or iso",
        "kernel": "LinuxKernelInfo: kernel used",
        "initrd": "File: cpio.zst initrd",
        "cmdline": "string: kernel command line",
        "signed": "bool: whether the image is Secure Boot signed",
    },
)
