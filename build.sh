#!/bin/sh
# Builds bin/yap-server and bin/yap-client. Extra arguments are passed to
# both builds, e.g. ./build.sh -debug -define:YAP_LOSS_PERCENT=30
set -e
cd "$(dirname "$0")"
mkdir -p bin
odin build server -vet -strict-style -out:bin/yap-server "$@"
odin build client -vet -strict-style -out:bin/yap-client "$@"
