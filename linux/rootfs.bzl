"""Ergonomic macros for rootfs assembly.

These macros simplify common patterns when building Linux root filesystems
with pkg_tar. They reduce boilerplate for systemd service installation,
file placement, and rootfs composition.
"""

load("@rules_pkg//pkg:tar.bzl", "pkg_tar")

def systemd_service(name, service_file, binary = None, enabled = True,
                    wanted_by = "multi-user.target", binary_dest = None,
                    extra_symlinks = {}, visibility = None, **kwargs):
    """Install a systemd service with its binary into a rootfs layer.

    Generates pkg_tar targets that place the binary and service file at
    standard systemd paths, with optional enablement symlink.

    Args:
        name: Target name. The final composed tar has this name.
        service_file: Service unit file (e.g., "myapp.service").
        binary: Optional binary label to install. If None, only the service
            file is installed (useful for services that use binaries from
            other packages).
        enabled: If True (default), create a symlink to enable the service.
        wanted_by: Systemd target for enablement (default: "multi-user.target").
            Can also be a service name (e.g., "gobgpd.service") for .wants deps.
        binary_dest: Directory for the binary (default: /usr/lib/<name>).
        extra_symlinks: Additional symlinks dict (key=link path, value=target path).
            Useful for .wants dependencies between services.
        visibility: Bazel visibility.
        **kwargs: Additional arguments passed to the final pkg_tar.
    """
    service_name = service_file.rsplit("/", 1)[-1] if "/" in service_file else service_file
    service_path = "/usr/lib/systemd/system/" + service_name

    # Build symlinks for service enablement
    symlinks = dict(extra_symlinks)
    if enabled:
        # Determine the wants directory based on the target
        if wanted_by.endswith(".target"):
            wants_dir = "/etc/systemd/system/" + wanted_by + ".wants"
        else:
            wants_dir = "/etc/systemd/system/" + wanted_by + ".wants"
        symlinks[wants_dir + "/" + service_name] = service_path

    dep_targets = []

    # Service file tar (always created)
    pkg_tar(
        name = name + "_service",
        srcs = [service_file],
        mode = "0644",
        package_dir = "/usr/lib/systemd/system",
        symlinks = symlinks if symlinks else {},
        visibility = ["//visibility:private"],
    )
    dep_targets.append(":" + name + "_service")

    # Binary tar (optional)
    if binary != None:
        dest = binary_dest if binary_dest else "/usr/lib/" + name
        pkg_tar(
            name = name + "_bin",
            srcs = [binary],
            package_dir = dest,
            visibility = ["//visibility:private"],
        )
        dep_targets.append(":" + name + "_bin")

    # Composition tar
    pkg_tar(
        name = name,
        deps = dep_targets,
        visibility = visibility,
        **kwargs
    )

def install_files(name, files, visibility = None, **kwargs):
    """Install files into a rootfs layer, grouped by destination and mode.

    Each entry in `files` specifies source files, a destination directory,
    and an optional mode. Files with the same (dest, mode) are grouped into
    a single pkg_tar target.

    Args:
        name: Target name for the composed tar.
        files: List of dicts with keys:
            - srcs: List of source file labels.
            - dest: Destination directory path (e.g., "/usr/bin").
            - mode: Optional file mode (default: "0755" for dirs like
              /usr/bin, /usr/sbin; "0644" for others).
            - symlinks: Optional dict of symlinks to create.
        visibility: Bazel visibility.
        **kwargs: Additional arguments passed to the final pkg_tar.
    """
    dep_targets = []

    for i, entry in enumerate(files):
        srcs = entry.get("srcs", [])
        dest = entry["dest"]
        mode = entry.get("mode", "0644")
        symlinks = entry.get("symlinks", {})

        sub_name = name + "_" + str(i)
        pkg_tar(
            name = sub_name,
            srcs = srcs,
            package_dir = dest,
            mode = mode,
            symlinks = symlinks if symlinks else {},
            visibility = ["//visibility:private"],
        )
        dep_targets.append(":" + sub_name)

    pkg_tar(
        name = name,
        deps = dep_targets,
        visibility = visibility,
        **kwargs
    )

def rootfs(name, base = None, services = [], files = [], extra_tars = [],
           visibility = None, **kwargs):
    """Compose a rootfs from a base image, services, files, and extra layers.

    This is a thin composition wrapper that merges multiple pkg_tar layers
    into a single rootfs tar.

    Args:
        name: Target name for the composed rootfs tar.
        base: Optional label of a base rootfs tar (e.g., "@usi_base//:flat").
        services: List of systemd_service target labels to include.
        files: List of file dicts (passed to install_files). If non-empty,
            generates an install_files target named `name + "_files"`.
        extra_tars: Additional pkg_tar targets to merge.
        visibility: Bazel visibility.
        **kwargs: Additional arguments passed to the final pkg_tar.
    """
    dep_targets = []

    if base:
        dep_targets.append(base)

    dep_targets.extend(services)

    if files:
        install_files(
            name = name + "_files",
            files = files,
            visibility = ["//visibility:private"],
        )
        dep_targets.append(":" + name + "_files")

    dep_targets.extend(extra_tars)

    pkg_tar(
        name = name,
        deps = dep_targets,
        visibility = visibility,
        **kwargs
    )
