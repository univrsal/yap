#+build !wasi
package client

import log "../common/wlog"
import "core:fmt"
import "core:os"
import "core:strings"

/*
Reading a file being sent and writing one being received, on a desktop:
plain files. A received file is written to <name>.part and only takes
its name once it's all there, so a half-received file never looks like
a whole one.
*/

File_Source :: struct {
	f: ^os.File,
}

File_Sink :: struct {
	f:    ^os.File,
	part: string, // owned
}

// file_source_open opens the file a Send_File_Command names. The name is
// the file's own, in the temp allocator.
file_source_open :: proc(cmd: Send_File_Command) -> (src: File_Source, name: string, size: u64, ok: bool) {
	f, err := os.open(cmd.path)
	if err != nil {
		log.errorf("file: could not open %s: %v", cmd.path, err)
		return
	}
	n, size_err := os.file_size(f)
	if size_err != nil || n < 0 {
		log.errorf("file: could not tell how big %s is: %v", cmd.path, size_err)
		os.close(f)
		return
	}
	return {f = f}, strings.clone(os.base(cmd.path), context.temp_allocator), u64(n), true
}

// file_source_read fills `buf` from `offset`. A file on disk is always
// ready.
file_source_read :: proc(src: ^File_Source, offset: u64, buf: []u8) -> (ready, ok: bool) {
	n, err := os.read_at(src.f, buf, i64(offset))
	return true, err == nil && n == len(buf)
}

file_source_close :: proc(src: ^File_Source) {
	if src.f != nil {
		os.close(src.f)
		src.f = nil
	}
}

/*
file_sink_create starts a file called `name` in `dir` (the downloads
folder if that's empty), or `name (1)`, `name (2)`... if that's taken. It
returns where the file will end up.
*/
file_sink_create :: proc(dir, name: string, size: u64) -> (sink: File_Sink, path: string, ok: bool) {
	dir := dir
	if dir == "" {
		dir = downloads_dir(context.temp_allocator)
		if dir == "" {
			log.error("file: could not work out where the downloads folder is")
			return
		}
	}
	if !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil {
			log.errorf("file: could not create %s: %v", dir, err)
			return
		}
	}
	stem, ext := os.split_filename(name)
	for i in 0 ..< 1000 {
		candidate := name
		if i > 0 {
			candidate = fmt.tprintf("%s (%d).%s", stem, i, ext) if ext != "" else fmt.tprintf("%s (%d)", stem, i)
		}
		full, _ := os.join_path({dir, candidate}, context.temp_allocator)
		part := strings.concatenate({full, ".part"}, context.temp_allocator)
		if os.exists(full) || os.exists(part) {
			continue
		}
		f, err := os.open(part, {.Write, .Create, .Excl}, {.Read_User, .Write_User, .Read_Group, .Read_Other})
		if err != nil {
			log.errorf("file: could not create %s: %v", part, err)
			return
		}
		return {f = f, part = strings.clone(part)}, strings.clone(full), true
	}
	log.errorf("file: every name for %q in %s is taken", name, dir)
	return
}

file_sink_write :: proc(sink: ^File_Sink, offset: u64, data: []u8) -> bool {
	n, err := os.write_at(sink.f, data, i64(offset))
	return err == nil && n == len(data)
}

// file_sink_finish closes the file and gives it its name.
file_sink_finish :: proc(sink: ^File_Sink, path: string) -> bool {
	os.close(sink.f)
	sink.f = nil
	defer {
		delete(sink.part)
		sink.part = ""
	}
	if err := os.rename(sink.part, path); err != nil {
		log.errorf("file: could not rename %s: %v", sink.part, err)
		return false
	}
	return true
}

// file_sink_abort throws away what was received.
file_sink_abort :: proc(sink: ^File_Sink) {
	if sink.f != nil {
		os.close(sink.f)
		sink.f = nil
	}
	if sink.part != "" {
		os.remove(sink.part)
		delete(sink.part)
		sink.part = ""
	}
}
