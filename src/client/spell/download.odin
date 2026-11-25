package spell

import "core:crypto/hash"
import "core:encoding/hex"
import "core:os"
import "core:strings"

// Dictionaries to download, for where spelling is checked with Hunspell: the
// catalog (catalog.odin, made by tools/spell_catalog.py) lists them, with the
// sizes and SHA-256 hashes of their files, and the client downloads them
// (ui_spell_download.odin) and installs them here into a directory of its
// own, which Hunspell looks in first (see languages and speller_set_languages).
//
// A dictionary is installed as `<name>.aff` and `<name>.dic`, the name being its
// tag with underscores ("en_GB"), as Hunspell's own are named, and its license
// beside them as `<name>.license`.

// One file of a dictionary: its size and SHA-256 hash, in hex.
Catalog_File :: struct {
	size:   int,
	sha256: string,
}

// One dictionary of the catalog.
Catalog_Entry :: struct {
	dir:          string, // under CATALOG_BASE, which is also its tag ("en-GB")
	license:      string, // SPDX
	aff, dic:     Catalog_File,
	license_file: Catalog_File,
}

// The three files of a dictionary, in the order they are downloaded.
Catalog_Part :: enum {
	Aff,
	Dic,
	License,
}

// catalog_tag is the tag of a dictionary of the catalog ("en-GB").
catalog_tag :: proc(e: Catalog_Entry) -> string {
	return e.dir
}

// catalog_size is how much there is to download for a dictionary.
catalog_size :: proc(e: Catalog_Entry) -> int {
	return e.aff.size + e.dic.size + e.license_file.size
}

// catalog_file is one of the files of a dictionary.
catalog_file :: proc(e: Catalog_Entry, part: Catalog_Part) -> Catalog_File {
	switch part {
	case .Aff:
		return e.aff
	case .Dic:
		return e.dic
	case .License:
		return e.license_file
	}
	return {}
}

// catalog_url is where one of the files of a dictionary is (temp allocator).
catalog_url :: proc(e: Catalog_Entry, part: Catalog_Part) -> string {
	NAMES := [Catalog_Part]string {
		.Aff     = "index.aff",
		.Dic     = "index.dic",
		.License = "license",
	}
	return strings.concatenate({CATALOG_BASE, e.dir, "/", NAMES[part]}, context.temp_allocator)
}

// catalog_check is whether `data` is the file `f` (its size and hash).
catalog_check :: proc(f: Catalog_File, data: []u8) -> bool {
	if len(data) != f.size {
		return false
	}
	sum: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, data, sum[:])
	got := string(hex.encode(sum[:], context.temp_allocator))
	return got == f.sha256
}

// catalog_paths are where a dictionary of the catalog is installed in `dir`
// (temp allocator).
catalog_paths :: proc(dir: string, e: Catalog_Entry) -> [Catalog_Part]string {
	name, _ := strings.replace_all(e.dir, "-", "_", context.temp_allocator)
	base := strings.concatenate({dir, "/", name}, context.temp_allocator)
	return {
		.Aff = strings.concatenate({base, ".aff"}, context.temp_allocator),
		.Dic = strings.concatenate({base, ".dic"}, context.temp_allocator),
		.License = strings.concatenate({base, ".license"}, context.temp_allocator),
	}
}

// catalog_installed is whether a dictionary of the catalog is installed in `dir`.
catalog_installed :: proc(dir: string, e: Catalog_Entry) -> bool {
	p := catalog_paths(dir, e)
	return os.exists(p[.Aff]) && os.exists(p[.Dic])
}

// catalog_install puts a dictionary's files, already checked, into `dir`,
// which is made if it isn't there. Each file is written next to where it goes
// and then moved there, and the .dic, which Hunspell looks for, comes last.
// Returns false if any of it couldn't be written (and leaves none of it).
catalog_install :: proc(dir: string, e: Catalog_Entry, files: [Catalog_Part][]u8) -> bool {
	if os.make_directory_all(dir) != nil && !os.exists(dir) {
		return false
	}
	p := catalog_paths(dir, e)
	for part in ([]Catalog_Part{.License, .Aff, .Dic}) {
		tmp := strings.concatenate({p[part], ".part"}, context.temp_allocator)
		if os.write_entire_file(tmp, files[part]) != nil || os.rename(tmp, p[part]) != nil {
			os.remove(tmp)
			catalog_remove(dir, e)
			return false
		}
	}
	return true
}

// catalog_remove removes a dictionary of the catalog from `dir`.
catalog_remove :: proc(dir: string, e: Catalog_Entry) {
	p := catalog_paths(dir, e)
	// The .dic first, so that a half-removed one isn't taken for installed.
	for part in ([]Catalog_Part{.Dic, .Aff, .License}) {
		os.remove(p[part])
	}
}
