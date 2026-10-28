package mattermost

import "core:bufio"
import "core:io"
import "core:os"

// Lines reads a file of JSON lines one at a time, and says where each begins.
// Posts are read twice (docs/design/mattermost-import.md, "The importer"):
// pass 1 keeps the offset of each, and pass 2 comes back to them in time order,
// so a line is read by its offset (line_at) as well as in turn.
Lines :: struct {
	file:   ^os.File,
	reader: bufio.Reader,
	offset: i64, // where the next line starts
	size:   i64, // of the file
	number: int, // of the line that was read last, from 1
}

// lines_open opens `path`. `err` is a sentence for the user if it can't.
lines_open :: proc(l: ^Lines, path: string) -> (err: string) {
	file, open_err := os.open(path)
	if open_err != nil {
		return "could not open the file"
	}
	size, size_err := os.file_size(file)
	if size_err != nil {
		os.close(file)
		return "could not read the file's size"
	}
	l^ = {
		file = file,
		size = size,
	}
	bufio.reader_init(&l.reader, io.to_reader(os.to_stream(file)), 1 << 20)
	return ""
}

lines_close :: proc(l: ^Lines) {
	if l.file != nil {
		bufio.reader_destroy(&l.reader)
		os.close(l.file)
	}
	l^ = {}
}

// lines_next reads the next line, without its newline, allocated with
// `allocator`. `at` is where it starts in the file and `ok` is false at the end.
// A last line without a newline counts as a line.
lines_next :: proc(l: ^Lines, allocator := context.allocator) -> (line: []u8, at: i64, ok: bool) {
	for {
		bytes, err := bufio.reader_read_bytes(&l.reader, '\n', allocator)
		if len(bytes) == 0 && err != nil {
			delete(bytes, allocator)
			return
		}
		at = l.offset
		l.offset += i64(len(bytes))
		l.number += 1
		line = bytes
		if len(line) > 0 && line[len(line) - 1] == '\n' {
			line = line[:len(line) - 1]
		}
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		// Blank lines are not part of the format, and aren't an error.
		if len(line) == 0 {
			delete(bytes, allocator)
			continue
		}
		return line, at, true
	}
}

// line_at reads the line that starts at `at` in `file`, which has to be a line
// that was seen by lines_next. `length` is what pass 1 recorded.
line_at :: proc(
	file: ^os.File,
	at: i64,
	length: int,
	allocator := context.allocator,
) -> (
	line: []u8,
	ok: bool,
) {
	buf := make([]u8, length, allocator)
	n, err := os.read_at(file, buf, at)
	if err != nil || n != length {
		delete(buf, allocator)
		return
	}
	return buf, true
}
