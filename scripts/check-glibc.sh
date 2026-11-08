#!/bin/sh
# Fails if any of the given Linux binaries or libraries needs a glibc newer than
# <max> (e.g. 2.35, Ubuntu 22.04's). What a binary needs comes from the system
# it was built on: its headers (C23's strtol, for one), the libstdc++.a that is
# linked in, and the version libm's functions carry. So the Linux build runs
# on the oldest runner there is (build.yml), and this stops it creeping up.
# Usage: scripts/check-glibc.sh <max> <file>...
set -e
max=${1:?usage: check-glibc.sh <max> <file>...}
shift
status=0
for f in "$@"; do
	[ -f "$f" ] || continue
	need=$(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -n 1)
	[ -n "$need" ] || continue
	newest=$(printf '%s\n%s\n' "$max" "$need" | sort -V | tail -n 1)
	if [ "$newest" != "$max" ]; then
		echo "$f needs glibc $need (more than $max):" >&2
		objdump -T "$f" | grep "GLIBC_$need" | awk '{print "  " $NF}' >&2
		status=1
	else
		echo "$f: glibc $need"
	fi
done
exit $status
