#!/bin/sh
# Runs the harness against deps/thirdparty/tinyrequests, or against another copy of
# tinyrequests.h whose directory is the argument.
set -e
here=$(cd "$(dirname "$0")" && pwd)
lib=${1:-$here/../../deps/thirdparty/tinyrequests}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cc -D__APPLE__ -w -I"$here" -I"$lib" "$here/harness.c" -o "$out/harness"
"$out/harness"
