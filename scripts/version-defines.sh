#!/bin/sh
# Prints the -define flags that tell a build what it is (see
# src/common/version.odin): the release tag being built, from $YAP_VERSION
# or an exact git tag, and the short commit hash. Prints nothing it can't
# find out, e.g. outside a git checkout.
# Usage: odin build ... $(scripts/version-defines.sh)
cd "$(dirname "$0")/.." || exit 0

version=${YAP_VERSION:-$(git describe --tags --exact-match 2>/dev/null)}
version=${version#v}
if [ -n "$version" ]; then
	printf ' -define:YAP_VERSION="%s"' "$version"
fi

if commit=$(git rev-parse --short=7 HEAD 2>/dev/null); then
	git diff --quiet HEAD 2>/dev/null || commit="$commit-dirty"
	printf ' -define:YAP_COMMIT="%s"' "$commit"
fi
