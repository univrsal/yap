#!/bin/sh
# Runs the tests of every package that has some, one `odin test` per package
# (odin test only runs the tests of the package it is given).
#
# Prints one line per package and a total at the end. The output of a package
# is only shown if it failed (or with -v). Every package is run even if an
# earlier one fails; the exit code is non-zero if any failed.
#
# Usage: scripts/run-tests.sh [-v] [package-dir...]   (default: all of them)
cd "$(dirname "$0")/.." || exit 1
. ./scripts/build/collections.sh

verbose=0
if [ "$1" = "-v" ]; then
	verbose=1
	shift
fi

if [ $# -gt 0 ]; then
	packages="$*"
else
	packages="
		src/common/proto src/common/webp src/common/gif src/common/avatar
		src/common/imagekind src/common/memtrack
		src/client/hotkeys src/client/richtext src/client/script
		src/client/imaging src/client/settings src/client/platform
		src/client/clipboard src/client/audio src/client/audio/opus src/client/headless
		src/client/audio/rnn src/client/render src/client/conn src/client
		src/cli/tui src/cli
		src/server/webpush src/server/mail src/server/mattermost
		src/lib/http src/lib/gateway src/server
	"
fi

plural() { [ "$1" -eq 1 ] && echo test || echo tests; }

out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT

total=0
failed_tests=0
failed_packages=""
start=$(date +%s)

for p in $packages; do
	# shellcheck disable=SC2086
	odin test "$p" $collections -vet -strict-style >"$out" 2>&1
	status=$?

	# "Finished 12 tests in 3ms. All tests were successful." or
	# "Finished 12 tests in 3ms. 2 tests failed."
	line=$(grep -a '^Finished ' "$out" | tail -n 1)
	count=$(echo "$line" | sed -n 's/^Finished \([0-9][0-9]*\) tests\{0,1\} in.*/\1/p')
	took=$(echo "$line" | sed -n 's/^Finished [0-9]* tests\{0,1\} in \([^ ]*\)\. .*/\1/p')
	count=${count:-0}
	total=$((total + count))

	if [ $status -eq 0 ]; then
		printf '  ok    %-28s %4d %s  %s\n' "$p" "$count" "$(plural "$count")" "$took"
		[ $verbose -eq 1 ] && cat "$out"
	else
		bad=$(echo "$line" | sed -n 's/.* \([0-9][0-9]*\) tests\{0,1\} failed\.$/\1/p')
		if [ -n "$bad" ]; then
			failed_tests=$((failed_tests + bad))
			printf '  FAIL  %-28s %4d %s  %s (%d failed)\n' "$p" "$count" "$(plural "$count")" "$took" "$bad"
		else
			# It didn't get as far as running tests: a compile error or a crash.
			printf '  FAIL  %-28s did not run\n' "$p"
		fi
		failed_packages="$failed_packages $p"
		echo "  ---- output of $p ----"
		cat "$out"
		echo "  ----"
	fi
done

elapsed=$(($(date +%s) - start))
echo
if [ -n "$failed_packages" ]; then
	echo "FAILED in:$failed_packages ($failed_tests failed test(s), $total run, ${elapsed}s)"
	exit 1
fi
echo "All $total tests passed (${elapsed}s)."
