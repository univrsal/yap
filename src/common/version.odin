package common

import "core:fmt"
import "core:strings"

// The build scripts (build.sh, build.bat and web/build.sh, via
// scripts/build/version-defines.sh) fill in the version of this build from git:
//
//	-define:YAP_VERSION="1.2.0"    the release tag being built, if any
//	-define:YAP_COMMIT="0fb9278"   the short commit hash, "-dirty" added
//	                               if the tree had uncommitted changes
//
// The values are quoted because Odin would parse an unquoted value that
// looks like a number (a hash that's all digits, or a version like 1.0) as
// a number. The quotes end up in the string, and version() and commit()
// strip them off.
//
// A build without these defines (for example `odin build src/client` run
// by hand, or a build from a source archive without git) reports the
// version "dev" and has no commit.
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
