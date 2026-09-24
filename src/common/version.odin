package common

import "core:fmt"
import "core:strings"

/*
What this build is, filled in by the build scripts (build.sh, build.bat,
web/build.sh, via scripts/version-defines.sh) from git:

	-define:YAP_VERSION="1.2.0"    the release tag being built, if any
	-define:YAP_COMMIT="0fb9278"   the short commit hash, "-dirty" added
	                               if the tree had uncommitted changes

The values are quoted because Odin takes an unquoted value that looks
like a number (a hash that's all digits, a version like 1.0) as one; the
quotes end up in the string, and version()/commit() take them off.

A build without them (odin build src/client by hand, or from a source
archive without git) is "dev" with no commit.
*/
@(private = "file")
VERSION_DEFINE :: #config(YAP_VERSION, "dev")
@(private = "file")
COMMIT_DEFINE :: #config(YAP_COMMIT, "")

version :: proc() -> string {
	return strings.trim(VERSION_DEFINE, "\"")
}

commit :: proc() -> string {
	return strings.trim(COMMIT_DEFINE, "\"")
}

// version_string is the version and, if known, the commit: "1.2.0 (0fb9278)".
version_string :: proc() -> string {
	if commit() == "" {
		return version()
	}
	return fmt.tprintf("%s (%s)", version(), commit())
}
