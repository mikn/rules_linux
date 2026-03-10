#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

TAG="${1:?Usage: release_prep.sh <tag>}"
PREFIX="rules_linux-${TAG:1}"
ARCHIVE="rules_linux-${TAG}.tar.gz"

# Verify MODULE.bazel version matches tag
module_version=$(grep -oP 'version = "\K[^"]+' MODULE.bazel)
if [ "$module_version" != "${TAG:1}" ]; then
  echo "ERROR: MODULE.bazel version ($module_version) does not match tag ($TAG)" >&2
  exit 1
fi

git archive --format=tar --prefix="${PREFIX}/" "${TAG}" | gzip > "$ARCHIVE"

cat <<EOF
## rules_linux ${TAG}

Bazel rules for building Linux boot artifacts.

\`\`\`starlark
bazel_dep(name = "rules_linux", version = "${TAG:1}")
\`\`\`
EOF
