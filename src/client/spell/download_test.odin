#+build !wasi
#+build !js
package spell

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_catalog_well_formed :: proc(t: ^testing.T) {
	testing.expect(t, len(CATALOG) > 50)
	seen := make(map[string]bool, context.temp_allocator)
	for e in CATALOG {
		testing.expectf(t, !seen[e.dir], "%s twice", e.dir)
		seen[e.dir] = true
		testing.expectf(t, e.license != "", "%s: no license", e.dir)
		for part in Catalog_Part {
			f := catalog_file(e, part)
			testing.expectf(t, f.size > 0 && len(f.sha256) == 64, "%s %v: %v", e.dir, part, f)
		}
	}
	// The ones the settings default to are there.
	for tag in ([]string{"en", "en-GB", "de", "fr", "es"}) {
		testing.expectf(t, seen[tag], "no %s", tag)
	}
	en: Catalog_Entry
	for e in CATALOG {
		if e.dir == "en-GB" {
			en = e
		}
	}
	testing.expect(t, strings.has_suffix(catalog_url(en, .Dic), "/dictionaries/en-GB/index.dic"))
	testing.expect(t, strings.has_prefix(catalog_url(en, .Dic), CATALOG_BASE))
}

@(test)
test_catalog_check :: proc(t: ^testing.T) {
	// SHA-256 of "abc".
	f := Catalog_File{3, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}
	testing.expect(t, catalog_check(f, transmute([]u8)string("abc")))
	testing.expect(t, !catalog_check(f, transmute([]u8)string("abd")))
	testing.expect(t, !catalog_check(f, transmute([]u8)string("abcd")))
}

@(test)
test_catalog_install :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir := strings.concatenate({base, "/yap-spell-test/dictionaries"}, context.temp_allocator)
	defer os.remove_all(strings.concatenate({base, "/yap-spell-test"}, context.temp_allocator))
	e := Catalog_Entry {
		dir = "en-GB",
	}
	testing.expect(t, !catalog_installed(dir, e))
	files := [Catalog_Part][]u8 {
		.Aff     = transmute([]u8)string("SET UTF-8\n"),
		.Dic     = transmute([]u8)string("1\nhouse\n"),
		.License = transmute([]u8)string("license"),
	}
	testing.expect(t, catalog_install(dir, e, files))
	testing.expect(t, catalog_installed(dir, e))
	p := catalog_paths(dir, e)
	testing.expect(t, strings.has_suffix(p[.Dic], "/en_GB.dic"))
	data, err := os.read_entire_file(p[.Dic], context.temp_allocator)
	testing.expect(t, err == nil && string(data) == "1\nhouse\n")
	testing.expect(t, !os.exists(strings.concatenate({p[.Dic], ".part"}, context.temp_allocator)))
	catalog_remove(dir, e)
	testing.expect(t, !catalog_installed(dir, e))
	testing.expect(t, !os.exists(p[.License]))
}
