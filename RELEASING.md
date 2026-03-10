# Releasing rules_linux

## Prerequisites (one-time)

1. Fork [bazelbuild/bazel-central-registry](https://github.com/bazelbuild/bazel-central-registry) to `mikn/bazel-central-registry`
2. Create a GitHub Classic PAT with `repo` + `workflow` scopes
3. Add it as `BCR_PUBLISH_TOKEN` in repo Settings → Secrets and variables → Actions

## Release process

1. Update the version in `MODULE.bazel`:
   ```starlark
   module(
       name = "rules_linux",
       version = "0.2.0",  # ← bump this
       compatibility_level = 0,
   )
   ```

2. Commit and tag:
   ```bash
   git commit -am "release: v0.2.0"
   git tag v0.2.0
   git push origin main v0.2.0
   ```

3. The rest is automated:
   - `release.yml` triggers on tag push → creates source archive → creates GitHub release
   - `publish.yml` triggers on release published → calls `bazel-contrib/publish-to-bcr` → opens PR to `bazelbuild/bazel-central-registry`

4. Review and merge the auto-created BCR PR.

## Publish order

`rules_linux` has no deps on other `rules_*` modules — it can be published independently.

## BCR templates

- `.bcr/metadata.template.json` — maintainer info
- `.bcr/source.template.json` — archive URL with `{TAG}`/`{VERSION}` placeholders
- `.bcr/presubmit.yml` — BCR CI matrix (Bazel 8.x + 9.x)
