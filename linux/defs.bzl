"""Public API for rules_linux."""

load("//linux:providers.bzl", _LinuxImageInfo = "LinuxImageInfo", _LinuxKernelInfo = "LinuxKernelInfo")
load("//linux/initrd:initrd.bzl", _initrd = "initrd")
load("//linux/initrd:strip_profiles.bzl", _STRIP_PROFILE_MINIMAL = "STRIP_PROFILE_MINIMAL", _STRIP_PROFILE_NONE = "STRIP_PROFILE_NONE", _STRIP_PROFILE_SERVER = "STRIP_PROFILE_SERVER")
load("//linux/iso:iso.bzl", _iso_image = "iso_image")
load("//linux/kernel:kernel_build.bzl", _kernel_build = "kernel_build")
load("//linux/kernel:kernel_extract.bzl", _kernel_extract = "kernel_extract")
load("//linux/signing:signing.bzl", _sign_image = "sign_image")
load("//linux/uki:uki.bzl", _uki_image = "uki_image")

# Providers
LinuxKernelInfo = _LinuxKernelInfo
LinuxImageInfo = _LinuxImageInfo

# Rules
kernel_build = _kernel_build
kernel_extract = _kernel_extract
initrd = _initrd
uki_image = _uki_image
sign_image = _sign_image
iso_image = _iso_image

# Strip profiles
STRIP_PROFILE_NONE = _STRIP_PROFILE_NONE
STRIP_PROFILE_SERVER = _STRIP_PROFILE_SERVER
STRIP_PROFILE_MINIMAL = _STRIP_PROFILE_MINIMAL
