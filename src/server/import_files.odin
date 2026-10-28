package server

import "core:crypto/hash"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "common:avatar"
import "common:imagekind"
import "common:proto"
import "mattermost"

// The importer's files and custom emoji (docs/design/mattermost-import.md, step
// 8): the files attached to posts become blobs and attachments, as a message
// that was posted with them has, and the custom emoji pictures go into the
// server's emoji folder, from which it builds its emoji sheet when it starts.

// import_emoji copies the pictures of the custom emoji that the plan keeps
// into the server's emoji folder, named as they are in yap. A JPEG is made a
// PNG, as the folder takes PNG, WebP and GIF.
import_emoji :: proc(im: ^Importer) -> bool {
	s := im.scan
	made := s.plan.made
	if len(made) == 0 {
		return true
	}
	if err := os.make_directory_all(im.emoji_dir); err != nil && !os.is_directory(im.emoji_dir) {
		log.errorf("could not make the emoji folder %s: %v", im.emoji_dir, err)
		return false
	}
	a := virtual.arena_allocator(&s.arena)
	progress := progress_start("making emoji")
	for e, i in made {
		progress_update(&progress, i64(i), i64(len(made)))
		// The server uses the first of png, webp and gif that has the name, so a
		// name that has any of them is taken.
		taken := false
		for ext in EMOJI_EXTENSIONS {
			if os.exists(
				join_path(
					im.emoji_dir,
					strings.concatenate({e.name, ext}, context.temp_allocator),
				),
			) {
				taken = true
			}
		}
		if taken {
			mattermost.note(s, .Emoji_Exists, e.name, a)
			continue
		}
		path, inside := mattermost.data_file(s.dir, s.emoji[e.index].image)
		data: []u8
		err: os.Error
		if inside {
			data, err = os.read_entire_file(path, context.temp_allocator)
		}
		if !inside || err != nil {
			mattermost.note(s, .Emoji_Unusable, fmt.tprintf("%s: can't be read", e.name), a)
			continue
		}
		if e.convert {
			png, ok := avatar.to_png(data, context.temp_allocator)
			if !ok {
				mattermost.note(
					s,
					.Emoji_Unusable,
					fmt.tprintf("%s: can't be converted", e.name),
					a,
				)
				continue
			}
			data = png
		}
		dest := strings.clone(
			join_path(im.emoji_dir, strings.concatenate({e.name, e.ext}, context.temp_allocator)),
			a,
		)
		if write_err := os.write_entire_file(
			dest,
			data,
			{.Read_User, .Write_User, .Read_Group, .Read_Other},
		); write_err != nil {
			log.errorf("could not write %s: %v", dest, write_err)
			return false
		}
		append(&im.written, dest)
		im.emoji += 1
	}
	progress.done = i64(len(made))
	progress_finish(&progress)
	return true
}

// The file types that the server's emoji folder reads (EMOJI_EXTENSIONS).
@(private = "file")
EMOJI_EXTENSIONS :: [?]string{".png", ".webp", ".gif"}

@(private = "file")
join_path :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}

// import_attachments stores the files of a post as blobs and puts them in the
// message `m`, with the flag that says so, as posting a message with files
// does. A file that isn't there (said by the scan), is empty, can't be read or
// is beyond the ten that a message can have is left out, and said. The message
// may then have none.
import_attachments :: proc(
	im: ^Importer,
	files: []mattermost.Attachment,
	sender: proto.Account_Id,
	m: ^proto.Message,
) -> bool {
	s := im.scan
	a := virtual.arena_allocator(&s.arena)
	for f in files {
		path, inside := mattermost.data_file(s.dir, f.path)
		if !inside {
			continue // the scan has said so
		}
		info, stat_err := os.stat(path, context.temp_allocator)
		if stat_err != nil || info.type != .Regular {
			continue // the scan has said so
		}
		if m.attachment_count >= proto.MAX_ATTACHMENTS {
			mattermost.note(s, .Attachments_Cut, f.path, a)
			continue
		}
		if info.size == 0 {
			mattermost.note(s, .Attachment_Empty, f.path, a)
			continue
		}
		blob, width, height, stored := import_blob(im, path, info.size, sender)
		if !stored {
			mattermost.note(s, .Attachment_Failed, f.path, a)
			continue
		}
		if im.max_attachment > 0 && u64(info.size) > im.max_attachment {
			mattermost.note(
				s,
				.Attachment_Over_Limit,
				fmt.tprintf("%s (%d MB)", f.path, info.size / (1024 * 1024)),
				a,
			)
		}
		name_buf: [proto.MAX_FILE_NAME]u8
		name := proto.sanitize_file_name(f.path, &name_buf)
		if name == "" {
			name = "file"
		}
		m.attachments[m.attachment_count] = {
			blob   = blob,
			size   = u64(info.size),
			name   = strings.clone(name, a),
			width  = width,
			height = height,
		}
		m.attachment_count += 1
	}
	if m.attachment_count > 0 {
		m.flags += {.Has_Attachments}
	}
	return true
}

// COPY_CHUNK is how much of a file is read at a time.
@(private = "file")
COPY_CHUNK :: 1024 * 1024

// import_blob stores a file as a blob without holding it in memory: it is copied
// into the store's incoming folder while its SHA-256 is worked out, and then
// adopted (a file with the same content is stored once). A picture's size is
// read from the start of the file, as it is when someone uploads one.
@(private = "file")
import_blob :: proc(
	im: ^Importer,
	path: string,
	size: i64,
	by: proto.Account_Id,
) -> (
	blob: Blob_Id,
	width, height: int,
	ok: bool,
) {
	src, open_err := os.open(path)
	if open_err != nil {
		return
	}
	defer os.close(src)
	incoming := blob_incoming_dir(im.blobs)
	if err := os.make_directory_all(incoming); err != nil && !os.is_directory(incoming) {
		return
	}
	im.parts += 1
	part := join_path(incoming, fmt.tprintf("import-%d", im.parts))
	dst, create_err := os.open(part, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if create_err != nil {
		return
	}
	copied := false
	defer if !copied {
		os.close(dst)
		os.remove(part)
	}
	ctx: hash.Context
	hash.init(&ctx, .SHA256)
	buf := make([]u8, COPY_CHUNK, context.temp_allocator)
	total: i64
	first := true
	for {
		n, read_err := os.read(src, buf)
		if n > 0 {
			if first {
				w, h, is_picture := imagekind.dimensions(buf[:min(n, ATTACH_HEADER)])
				if is_picture {
					// At most 65535 on each side, with the shape kept, so that a message can state it.
					if side := max(w, h); side > 65535 {
						w, h = max(w * 65535 / side, 1), max(h * 65535 / side, 1)
					}
					width, height = w, h
				}
				first = false
			}
			hash.update(&ctx, buf[:n])
			if _, write_err := os.write(dst, buf[:n]); write_err != nil {
				return
			}
			total += i64(n)
		}
		if read_err != nil || n <= 0 {
			break
		}
	}
	if total != size {
		return // the file changed while it was read
	}
	sum: [BLOB_HASH_SIZE]u8
	hash.final(&ctx, sum[:])
	os.close(dst)
	copied = true // from here the store owns the file
	_, existed := blob_find(im.blobs, sum)
	blob, ok = blob_adopt(im.blobs, .File, part, sum, int(total), i64(by), width, height)
	if !ok {
		os.remove(part)
		return
	}
	if !existed {
		append(&im.written, blob_path(im.blobs, sum, virtual.arena_allocator(&im.arena)))
	}
	return
}
