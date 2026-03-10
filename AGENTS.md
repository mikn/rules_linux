# rules_linux

Bazel rules for building Linux boot artifacts: kernels (from source or .deb), initrds, UKIs, ISOs, and Secure Boot signing.

## Commands

```bash
bazel test //...                    # Run all tests
bazel build //...                   # Build all targets
bazel run //:gazelle                # Regenerate BUILD files after Go changes
```

## Structure

- `linux/defs.bzl` — Public API: `kernel_build`, `kernel_extract`, `initrd`, `uki_image`, `sign_image`, `iso_image`
- `linux/providers.bzl` — `LinuxKernelInfo`, `LinuxImageInfo` providers
- `linux/macros.bzl` — High-level: `usi_image`, `signed_usi_image`, `iso_multiarch`
- `linux/extensions.bzl` — Module extensions: `kernel_sources`, `ccache`, `test_artifacts`
- `linux/tools/` — Go tools: `mkiso` (ISO creation), `usi-signer` (Secure Boot signing)
- `tests/` — Build tests

## Code Quality

- **Starlark**: Fail fast with `fail()` on invalid input. Validate all rule attributes at analysis time. Use `ctx.actions.declare_file()` for outputs, never hardcode paths. Propagate providers correctly.
- **Go tools**: Static binaries (`pure = "on"`). No external deps beyond what's in `go.mod`. Error on all failures, no silent fallbacks.
- **Rules must be hermetic**: All inputs declared, no undeclared host deps. Exception: `kernel_build` needs `bc` on host (documented).
- **Test new rules**: Add analysis tests (Skylib `build_test`) in `tests/BUILD.bazel`.
- **Providers are the API contract**: Changes to `LinuxKernelInfo`/`LinuxImageInfo` fields are breaking changes.

## Releasing

See [RELEASING.md](RELEASING.md). Tag push → GitHub release → `publish-to-bcr` reusable workflow auto-opens BCR PR. No deps on other `rules_*` modules.
