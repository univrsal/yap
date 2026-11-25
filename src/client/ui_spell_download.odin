#+build linux, freebsd, openbsd, netbsd
package client

import log "common:wlog"
import "core:fmt"
import "core:slice"
import "core:time"
import mu "vendor:microui"

import "client:fetch"
import "client:platform"
import "client:spell"

// Downloading Hunspell dictionaries, where spelling is checked with Hunspell
// (Linux and the BSDs): the settings' Spelling category lists the catalog's
// (spell/catalog.odin) under the languages, each with a button to download or
// remove it. Downloads go one after the other, a file at a time, polled from
// the frame (spell_download_step), and each file is checked against the
// catalog before the dictionary is installed into the config directory's
// "dictionaries" folder. A dictionary that was downloaded is checked against
// from then on.

@(private = "file")
DOWNLOAD_TIMEOUT :: 120 * time.Second

@(private = "file")
Spell_Downloads :: struct {
	dir:       string, // where they are installed (owned), "" if there is no config directory
	dirs:      [1]string,
	// The one being downloaded (an index into spell.CATALOG, -1: none), the
	// file of it that is on its way, and those that have come.
	active:    int,
	part:      spell.Catalog_Part,
	download:  fetch.Download,
	files:     [spell.Catalog_Part][]u8,
	// The ones to download after it.
	queue:     [dynamic]int,
	// Which of the catalog's are installed, as of the last look.
	installed: [len(spell.CATALOG)]bool,
	looked:    bool,
	// The last one that failed, and why (owned).
	failed:    int,
	error:     string,
}

@(private = "file")
g_dl := Spell_Downloads {
	active = -1,
	failed = -1,
}

// spell_dirs are where else the spell checker looks for dictionaries: where
// they are downloaded to.
spell_dirs :: proc() -> []string {
	dl := &g_dl
	if dl.dir == "" {
		dl.dir = platform.default_config_path("dictionaries")
		dl.dirs[0] = dl.dir
	}
	return dl.dirs[:] if dl.dir != "" else nil
}

// spell_download_step moves the download on, if there is one. Called every frame.
spell_download_step :: proc(ui: ^UI) {
	dl := &g_dl
	if dl.active < 0 {
		return
	}
	e := spell.CATALOG[dl.active]
	done, body, err := fetch.poll_download(&dl.download)
	if !done {
		ui_redraw_in(ui, 100 * time.Millisecond)
		return
	}
	if err == "" && !spell.catalog_check(spell.catalog_file(e, dl.part), body) {
		err = "what came isn't what was expected"
	}
	if err != "" {
		delete(body)
		download_failed(ui, err)
		return
	}
	dl.files[dl.part] = body
	if dl.part != max(spell.Catalog_Part) {
		dl.part = spell.Catalog_Part(int(dl.part) + 1)
		download_part(ui)
		return
	}
	if !spell.catalog_install(dl.dir, e, dl.files) {
		download_failed(ui, "it couldn't be saved")
		return
	}
	log.infof("spell: downloaded the dictionary for %s", e.dir)
	tag := spell.catalog_tag(e)
	download_end(ui)
	// Checked against from now on.
	spell_settings_opened(ui)
	spell_pick_language(ui, spell_chosen_languages(ui), tag, true)
}

// download_part starts on the file dl.part of the one being downloaded.
@(private = "file")
download_part :: proc(ui: ^UI) {
	dl := &g_dl
	e := spell.CATALOG[dl.active]
	f := spell.catalog_file(e, dl.part)
	err: string
	dl.download, err = fetch.begin_download(
		spell.catalog_url(e, dl.part),
		f.size,
		DOWNLOAD_TIMEOUT,
	)
	if err != "" {
		download_failed(ui, err)
		return
	}
	ui_redraw(ui)
}

@(private = "file")
download_failed :: proc(ui: ^UI, why: string) {
	dl := &g_dl
	log.warnf(
		"spell: couldn't download the dictionary for %s: %s",
		spell.CATALOG[dl.active].dir,
		why,
	)
	delete(dl.error)
	dl.error = fmt.aprintf("Couldn't download it: %s.", why)
	dl.failed = dl.active
	download_end(ui)
}

// download_end lets go of the one being downloaded and starts on the next.
@(private = "file")
download_end :: proc(ui: ^UI) {
	dl := &g_dl
	fetch.cancel_download(&dl.download)
	for &f in dl.files {
		delete(f)
		f = nil
	}
	dl.active = -1
	dl.looked = false
	if len(dl.queue) > 0 {
		next := dl.queue[0]
		ordered_remove(&dl.queue, 0)
		download_start(ui, next)
	}
	ui_redraw(ui)
}

@(private = "file")
download_start :: proc(ui: ^UI, i: int) {
	dl := &g_dl
	if dl.active >= 0 {
		if !slice.contains(dl.queue[:], i) {
			append(&dl.queue, i)
		}
		return
	}
	if len(spell_dirs()) == 0 {
		delete(dl.error)
		dl.error = fmt.aprintf("Couldn't download it: there is no config directory.")
		dl.failed = i
		return
	}
	if dl.failed == i {
		dl.failed = -1
	}
	dl.active, dl.part = i, .Aff
	download_part(ui)
}

spell_download_destroy :: proc(ui: ^UI) {
	dl := &g_dl
	fetch.cancel_download(&dl.download)
	for f in dl.files {
		delete(f)
	}
	delete(dl.queue)
	delete(dl.error)
	delete(dl.dir)
	g_dl = {
		active = -1,
		failed = -1,
	}
}

// spell_download_settings is the list of dictionaries to download, under the
// languages in the Spelling category.
spell_download_settings :: proc(ui: ^UI) {
	ctx := &ui.ctx
	dl := &g_dl
	dir := spell_dirs()
	if len(dir) == 0 {
		return
	}
	if !dl.looked {
		dl.looked = true
		for e, i in spell.CATALOG {
			dl.installed[i] = spell.catalog_installed(dir[0], e)
		}
	}
	if .ACTIVE not_in begin_treenode(ctx, "Download dictionaries") {
		return
	}
	defer mu.end_treenode(ctx)
	mu.layout_row(ctx, {-1})
	dim_note(
		ctx,
		"From wooorm/dictionaries on GitHub, each under its own license, which is saved with it.",
	)
	if dl.error != "" {
		mu.layout_row(ctx, {-1})
		with_text_color(ctx, theme.warning, dl.error, wrap_text)
	}
	remove := -1
	for e, i in spell.CATALOG {
		mu.push_id(ctx, uintptr(i))
		defer mu.pop_id(ctx)
		tag := spell.catalog_tag(e)
		name := spell_language_name(tag)
		mb := f64(spell.catalog_size(e)) / 1e6
		shown := tag if name == "" else fmt.tprintf("%s (%s)", name, tag)
		label := fmt.tprintf("%s, %.1f MB, %s", shown, mb, e.license)
		mu.layout_row(ctx, {-(110 + ctx.style.spacing), -1})
		mu.label(ctx, label)
		switch {
		case dl.active == i:
			done := 0
			for p in spell.Catalog_Part {
				if p < dl.part {
					done += spell.catalog_file(e, p).size
				}
			}
			mu.label(ctx, fmt.tprintf("%d%%", 100 * done / max(spell.catalog_size(e), 1)))
		case slice.contains(dl.queue[:], i):
			mu.label(ctx, "Waiting")
		case dl.installed[i]:
			if .SUBMIT in stable_button(ctx, "remove", "Remove") {
				remove = i
			}
		case:
			if .SUBMIT in stable_button(ctx, "download", "Download") {
				download_start(ui, i)
			}
		}
	}
	// Done after the loop, which the list is shown by.
	if remove >= 0 {
		e := spell.CATALOG[remove]
		spell.catalog_remove(dir[0], e)
		log.infof("spell: removed the downloaded dictionary for %s", e.dir)
		dl.looked = false
		spell_settings_opened(ui)
		chosen := spell_chosen_languages(ui)
		tag := spell.catalog_tag(e)
		if slice.contains(chosen, tag) {
			spell_pick_language(ui, chosen, tag, false)
		} else {
			spell_settings_changed(ui)
		}
	}
}
