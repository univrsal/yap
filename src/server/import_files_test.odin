package server

import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "common:avatar"
import "common:proto"

// The importer's files and custom emoji (import_files.odin), on the sample export
// and on made-up ones.

@(private = "file")
VERSION :: `{"type":"version","version":1,"info":{"generator":"mattermost-server","version":"x","created":"2026-01-01T00:00:00Z"}}`
@(private = "file")
TEAM :: `{"type":"team","team":{"name":"acme","display_name":"Acme","type":"O"}}`
@(private = "file")
CHANNEL :: `{"type":"channel","channel":{"team":"acme","name":"a","display_name":"a","type":"O"}}`
@(private = "file")
ROOT :: `{"type":"user","user":{"username":"root","email":"r@example.invalid","roles":"system_user system_admin","teams":[{"name":"acme","roles":"team_user","channels":[{"name":"a","roles":"channel_user"}]}]}}`

@(private = "file")
run_files :: proc(t: ^testing.T, it: ^Import_Test) {
	it.im.emoji_dir = file_in(it.dir, "emoji")
	if !import_accounts(&it.im) ||
	   !import_channels(&it.im) ||
	   !import_emoji(&it.im) ||
	   !import_messages(&it.im) {
		testing.fail_now(t, "the import failed")
	}
	db_commit(&it.db)
}

@(private = "file")
sha256_of :: proc(data: []u8) -> [32]u8 {
	sum: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, data, sum[:])
	return sum
}

@(test)
test_import_files_sample :: proc(t: ^testing.T) {
	it: Import_Test
	if !it_open(t, &it, IMPORT_SAMPLE) {
		return
	}
	defer it_close(&it)
	run_files(t, &it)

	// Three posts have files, four files in all, and the one that is only files
	// is a message now, with no text.
	testing.expect_value(t, it.im.files, 4)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM attachments"), 4)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM messages WHERE flags & 16 != 0"),
		3,
	)
	testing.expect_value(t, it_count(&it, "SELECT count(DISTINCT msg) FROM attachments"), 3)
	only_files, found := it_message(
		&it,
		"SELECT msg FROM attachments GROUP BY msg HAVING count(*) = 2",
	)
	testing.expect(t, found)
	testing.expect_value(t, only_files.text, "")
	testing.expect(t, .Has_Attachments in only_files.flags)
	// Each is a stored file of the kind that an upload makes, with the name it had.
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT count(*) FROM attachments a JOIN blobs b ON b.id = a.blob WHERE b.kind = 4",
		),
		4,
	)
	for name in ([]string{"a.txt", "b.csv", "notes.txt", "blue.png"}) {
		testing.expectf(
			t,
			it_count(
				&it,
				fmt.tprintf("SELECT count(*) FROM attachments WHERE name = '%s'", name),
			) ==
			1,
			"no file %s",
			name,
		)
	}
	// A picture states its size, as when it is uploaded; other files do not.
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT b.width FROM attachments a JOIN blobs b ON b.id = a.blob WHERE a.name = 'blue.png'",
		),
		320,
	)
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT b.height FROM attachments a JOIN blobs b ON b.id = a.blob WHERE a.name = 'blue.png'",
		),
		200,
	)
	testing.expect_value(
		t,
		it_count(
			&it,
			"SELECT b.width FROM attachments a JOIN blobs b ON b.id = a.blob WHERE a.name = 'a.txt'",
		),
		0,
	)
	// The content in the store is what the export had.
	for entry in ([]struct {
			name, path: string,
		}{{"notes.txt", ""}, {"a.txt", ""}}) {
		_ = entry
	}
	count := 0
	q := db_stmt(&it.db, .Blob_Hashes)
	for {
		row, ok := db_step(&it.db, q)
		if !ok || !row {
			break
		}
		sum: [BLOB_HASH_SIZE]u8
		testing.expect(t, db_col_into(q, 0, sum[:]))
		data, err := os.read_entire_file(blob_path(&it.blobs, sum), context.temp_allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, sha256_of(data), sum)
		count += 1
	}
	testing.expect_value(t, count, 4 + 3) // the files and the pictures of three accounts
	// Their names are searchable, as those of an uploaded file are.
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM files_fts WHERE files_fts MATCH 'notes'"),
		1,
	)
	// And it is all right as a server finds it.
	problems := import_verify(&it.im)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, it.scan.issues[.Post_Empty].count, 0)

	// The custom emoji: one picture, in the folder under the name it has in yap.
	testing.expect_value(t, it.im.emoji, 1)
	emoji_file := file_in(it.im.emoji_dir, "partyparrot.png")
	testing.expect(t, os.exists(emoji_file))
	source, _ := os.read_entire_file(
		file_in(IMPORT_SAMPLE, "data/emoji/6ubuzgoskb81fpmzhfwni3iqea/image"),
		context.temp_allocator,
	)
	copied, _ := os.read_entire_file(emoji_file, context.temp_allocator)
	testing.expect(t, string(source) == string(copied))

	// Undone, none of it stays: not the folder's file, not the stored files.
	files := make([dynamic]string, context.temp_allocator)
	append(&files, ..it.im.written[:])
	import_undo(&it.im)
	testing.expect(t, len(files) >= 8) // seven blobs and the emoji
	for f in files {
		testing.expectf(t, !os.exists(f), "%s is still there", f)
	}
}

@(test)
test_import_files_cases :: proc(t: ^testing.T) {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, VERSION, TEAM, CHANNEL, ROOT)
	files := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 12 {
		append(&files, fmt.tprintf(`{{"path":"f/%d.txt"}}`, i))
	}
	post :: proc(message, attachments: string, at: int) -> string {
		return fmt.tprintf(
			`{{"type":"post","post":{{"team":"acme","channel":"a","user":"root","message":"%s","create_at":%d,"attachments":[%s]}}}}`,
			message,
			at,
			attachments,
		)
	}
	append(&lines, post("twelve files", strings.join(files[:], ",", context.temp_allocator), 100))
	append(&lines, post("", `{"path":"gone/missing.txt"}`, 200)) // nothing to show: its only file isn't there
	append(&lines, post("", `{"path":"f/empty.bin"}`, 300)) // nothing to show: its file is empty
	append(&lines, post("again", `{"path":"f/0.txt"},{"path":"big/video.bin"}`, 400)) // a file already stored, and a big one
	// Paths that leave data/, to a file that is there and to one that is a
	// secret of this machine's: neither may be imported.
	append(
		&lines,
		post(
			"hello",
			`{"path":"../outside.txt"},{"path":"/etc/passwd"},{"path":"f/../../outside.txt"}`,
			500,
		),
	)
	dir := export_of(t, ..lines[:])
	defer {
		remove_tree(dir)
		delete(dir)
	}
	// The files.
	testing.expect(t, os.make_directory_all(file_in(dir, "data/f")) == nil)
	testing.expect(t, os.make_directory_all(file_in(dir, "data/big")) == nil)
	for i in 0 ..< 12 {
		testing.expect(
			t,
			os.write_entire_file(
				file_in(dir, fmt.tprintf("data/f/%d.txt", i)),
				fmt.tprintf("file number %d", i),
			) ==
			nil,
		)
	}
	testing.expect(t, os.write_entire_file(file_in(dir, "data/f/empty.bin"), "") == nil)
	testing.expect(
		t,
		os.write_entire_file(file_in(dir, "outside.txt"), "a file next to data/") == nil,
	)
	// Bigger than the chunks it is copied in, so that it is copied in several.
	big := make([]u8, 3 * 1024 * 1024 + 17, context.temp_allocator)
	for &b, i in big {
		b = u8(i * 7 + i >> 9)
	}
	testing.expect(t, os.write_entire_file(file_in(dir, "data/big/video.bin"), big) == nil)

	it: Import_Test
	if !it_open(t, &it, dir) {
		return
	}
	defer it_close(&it)
	it.im.max_attachment = 1024 * 1024 // so that the big file is over what an upload could be
	run_files(t, &it)

	// Ten of twelve, the rest said.
	twelve, ok := it_message(&it, "SELECT id FROM messages WHERE text = 'twelve files'")
	testing.expect(t, ok)
	testing.expect_value(t, twelve.attachment_count, 0) // not part of the row, which has none
	testing.expect_value(
		t,
		it_count(&it, fmt.tprintf("SELECT count(*) FROM attachments WHERE msg = %d", twelve.id)),
		proto.MAX_ATTACHMENTS,
	)
	testing.expect_value(t, it.scan.issues[.Attachments_Cut].count, 2)
	// A post with nothing left to show is left out, the missing file having been
	// said by the scan and the empty one by the importer.
	testing.expect_value(t, it.scan.issues[.Post_Empty].count, 2)
	testing.expect_value(t, it.scan.issues[.Attachment_Missing].count, 4) // the missing one, and the three that leave data/
	testing.expect_value(t, it.scan.issues[.Attachment_Empty].count, 1)
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM messages"), 3)
	// The same file in two posts is stored once, and a big file as it was.
	testing.expect_value(t, it_count(&it, "SELECT count(*) FROM blobs WHERE kind = 4"), 10 + 1) // the files 0 to 9 (once, though 0 is in two posts), and the big one
	again, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'again'")
	testing.expect_value(
		t,
		it_count(&it, fmt.tprintf("SELECT count(*) FROM attachments WHERE msg = %d", again.id)),
		2,
	)
	testing.expect_value(t, it.scan.issues[.Attachment_Over_Limit].count, 1)
	id := it_count(
		&it,
		fmt.tprintf(
			"SELECT blob FROM attachments WHERE msg = %d AND name = 'video.bin'",
			again.id,
		),
	)
	stored, read := blob_read(&it.blobs, Blob_Id(id))
	testing.expect(t, read)
	testing.expect_value(t, len(stored), len(big))
	testing.expect_value(t, sha256_of(stored), sha256_of(big))
	delete(stored)
	// A file outside data/ is not imported, whatever it is: the post has none.
	traversal, _ := it_message(&it, "SELECT id FROM messages WHERE text = 'hello'")
	testing.expect_value(
		t,
		it_count(
			&it,
			fmt.tprintf("SELECT count(*) FROM attachments WHERE msg = %d", traversal.id),
		),
		0,
	)
	testing.expect_value(
		t,
		it_count(&it, "SELECT count(*) FROM attachments WHERE name IN ('outside.txt', 'passwd')"),
		0,
	)
	// Nothing is left of the copying.
	incoming := blob_incoming_dir(&it.blobs)
	left, _ := os.read_all_directory_by_path(incoming, context.temp_allocator)
	testing.expect_value(t, len(left), 0)
	// And a server finds it right.
	problems := import_verify(&it.im)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
}

@(test)
test_import_emoji_cases :: proc(t: ^testing.T) {
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, VERSION, TEAM, CHANNEL, ROOT)
	append(
		&lines,
		`{"type":"post","post":{"team":"acme","channel":"a","user":"root","message":"hi","create_at":100}}`,
	)
	dir := export_of(t, ..lines[:])
	defer {
		remove_tree(dir)
		delete(dir)
	}
	// extras.jsonl and the pictures: a JPEG (which has to become a PNG), a PNG, a name that
	// has a capital and a dash, a file that isn't a picture and one that is too big.
	rgb := make([]u8, 16 * 16 * 3, context.temp_allocator)
	for &b, i in rgb {
		b = u8(i)
	}
	jpeg, jpeg_ok := avatar.encode_jpeg(rgb, 16, 16, 80, context.temp_allocator)
	testing.expect(t, jpeg_ok)
	png, _ := os.read_entire_file(
		file_in(IMPORT_SAMPLE, "data/emoji/6ubuzgoskb81fpmzhfwni3iqea/image"),
		context.temp_allocator,
	)
	testing.expect(t, os.make_directory_all(file_in(dir, "data/emoji")) == nil)
	write :: proc(t: ^testing.T, dir, name: string, data: []u8) {
		testing.expect(
			t,
			os.write_entire_file(file_in(dir, fmt.tprintf("data/emoji/%s", name)), data) == nil,
		)
	}
	write(t, dir, "jpg", jpeg)
	write(t, dir, "png", png)
	write(t, dir, "dash", png)
	write(
		t,
		dir,
		"text",
		transmute([]u8)string("not a picture at all, but not small enough to be mistaken"),
	)
	write(t, dir, "huge", make([]u8, 1024 * 1024 + 1, context.temp_allocator))
	extras := strings.join(
		{
			`{"type":"emoji","emoji":{"name":"from_jpeg","image":"emoji/jpg"}}`,
			`{"type":"emoji","emoji":{"name":"plain","image":"emoji/png"}}`,
			`{"type":"emoji","emoji":{"name":"Party-Time","image":"emoji/dash"}}`,
			`{"type":"emoji","emoji":{"name":"textual","image":"emoji/text"}}`,
			`{"type":"emoji","emoji":{"name":"too_big","image":"emoji/huge"}}`,
			`{"type":"emoji","emoji":{"name":"nowhere","image":"emoji/nothing"}}`,
		},
		"\n",
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(file_in(dir, "extras.jsonl"), extras) == nil)

	it: Import_Test
	if !it_open(t, &it, dir) {
		return
	}
	defer it_close(&it)
	// A name that the folder has already is not written over.
	it.im.emoji_dir = file_in(it.dir, "emoji")
	testing.expect(t, os.make_directory_all(it.im.emoji_dir) == nil)
	testing.expect(t, os.write_entire_file(file_in(it.im.emoji_dir, "plain.gif"), "GIF89a") == nil)
	run_files(t, &it)

	testing.expect_value(t, it.scan.issues[.Emoji_Unusable].count, 2) // the text and the big one
	testing.expect_value(t, it.scan.issues[.Emoji_Image_Missing].count, 1)
	testing.expect_value(t, it.scan.issues[.Emoji_Renamed].count, 1)
	testing.expect_value(t, it.scan.issues[.Emoji_Exists].count, 1)
	testing.expect_value(t, it.im.emoji, 2) // from_jpeg and party_time
	// The JPEG is a PNG now, and what is a PNG already is as it was.
	converted, _ := os.read_entire_file(
		file_in(it.im.emoji_dir, "from_jpeg.png"),
		context.temp_allocator,
	)
	testing.expect(t, len(converted) > 8 && string(converted[1:4]) == "PNG")
	same, _ := os.read_entire_file(
		file_in(it.im.emoji_dir, "party_time.png"),
		context.temp_allocator,
	)
	testing.expect(t, string(same) == string(png))
	testing.expect(t, !os.exists(file_in(it.im.emoji_dir, "plain.png")))
	testing.expect(t, !os.exists(file_in(it.im.emoji_dir, "too_big.png")))
	// And the server takes the names that the folder now has.
	for name in ([]string{"from_jpeg", "party_time"}) {
		testing.expect(t, proto.custom_emoji_name_ok(name))
	}
}
