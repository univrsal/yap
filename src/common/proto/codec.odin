package proto

import "core:encoding/endian"

// Encoding and decoding bodies. All numbers are little-endian.
//
// A body whose size is fixed is written at fixed offsets into an array of
// its size (encode_msg_pin and the like), and its decoder checks the size.
// Any other body goes through a Writer and a Reader, which stop at the end
// of the buffer and remember that they did (`overflow`), so a codec only
// has to look once, at the end.
//
// A body may grow at its end: a decoder ignores whatever follows the fields
// it knows, and a field that newer peers add at the end is read only if the
// body goes on (has_more).

@(private)
Writer :: struct {
	buf:      []byte,
	pos:      int,
	overflow: bool,
}

@(private)
put_bytes :: proc(w: ^Writer, b: []byte) {
	if w.overflow || w.pos + len(b) > len(w.buf) {
		w.overflow = true
		return
	}
	copy(w.buf[w.pos:], b)
	w.pos += len(b)
}

@(private)
put_u8 :: proc(w: ^Writer, v: u8) {
	v := v
	put_bytes(w, ([^]byte)(&v)[:1])
}

@(private)
put_u16 :: proc(w: ^Writer, v: u16) {
	b: [2]byte
	endian.unchecked_put_u16le(b[:], v)
	put_bytes(w, b[:])
}

@(private)
put_u32 :: proc(w: ^Writer, v: u32) {
	b: [4]byte
	endian.unchecked_put_u32le(b[:], v)
	put_bytes(w, b[:])
}

@(private)
put_u64 :: proc(w: ^Writer, v: u64) {
	b: [8]byte
	endian.unchecked_put_u64le(b[:], v)
	put_bytes(w, b[:])
}

// put_str8 writes [len u8][bytes]. A string that is too long for that causes an
// overflow.
@(private)
put_str8 :: proc(w: ^Writer, str: string) {
	if len(str) > int(max(u8)) {
		w.overflow = true
		return
	}
	put_u8(w, u8(len(str)))
	put_bytes(w, transmute([]byte)str)
}

// get_str8 reads [len u8][bytes]. The string points into the buffer.
@(private)
get_str8 :: proc(r: ^Reader) -> string {
	n := int(get_u8(r))
	return string(get_bytes(r, n))
}

// put_str16 writes [len u16][bytes]. A string that is too long for that causes
// an overflow.
@(private)
put_str16 :: proc(w: ^Writer, str: string) {
	if len(str) > int(max(u16)) {
		w.overflow = true
		return
	}
	put_u16(w, u16(len(str)))
	put_bytes(w, transmute([]byte)str)
}

// get_str16 reads [len u16][bytes]. The string points into the buffer.
@(private)
get_str16 :: proc(r: ^Reader) -> string {
	n := int(get_u16(r))
	return string(get_bytes(r, n))
}

@(private)
Reader :: struct {
	buf:      []byte,
	pos:      int,
	overflow: bool,
}

@(private)
get_bytes :: proc(r: ^Reader, n: int) -> []byte {
	if r.overflow || r.pos + n > len(r.buf) {
		r.overflow = true
		return nil
	}
	b := r.buf[r.pos:][:n]
	r.pos += n
	return b
}

@(private)
get_u8 :: proc(r: ^Reader) -> u8 {
	b := get_bytes(r, 1)
	return b == nil ? 0 : b[0]
}

@(private)
get_u16 :: proc(r: ^Reader) -> u16 {
	b := get_bytes(r, 2)
	return b == nil ? 0 : endian.unchecked_get_u16le(b)
}

@(private)
get_u32 :: proc(r: ^Reader) -> u32 {
	b := get_bytes(r, 4)
	return b == nil ? 0 : endian.unchecked_get_u32le(b)
}

@(private)
get_u64 :: proc(r: ^Reader) -> u64 {
	b := get_bytes(r, 8)
	return b == nil ? 0 : endian.unchecked_get_u64le(b)
}

// written is what a Writer wrote, or nil if it didn't all fit.
@(private)
written :: proc(w: ^Writer) -> []u8 {
	return nil if w.overflow else w.buf[:w.pos]
}

// has_more says whether a body goes on past what has been read, for a field
// that older peers leave out.
@(private)
has_more :: proc(r: ^Reader) -> bool {
	return !r.overflow && r.pos < len(r.buf)
}

// get_str8_opt is get_str8 for a trailing field that older peers leave out.
// It returns "" if the body has already ended.
@(private)
get_str8_opt :: proc(r: ^Reader) -> string {
	return get_str8(r) if has_more(r) else ""
}

// A body that is a single id: a message's, a blob's or an attachment's in 8
// bytes; a conversation's, a room's, an account's or a call's in 4. Decoding
// takes the id from the start of the body (which may go on, see above).
@(private)
id_put :: proc(out: []u8, id: $T) -> []u8 {
	when size_of(T) == 8 {
		endian.unchecked_put_u64le(out, u64(id))
	} else {
		#assert(size_of(T) == 4)
		endian.unchecked_put_u32le(out, u32(id))
	}
	return out[:size_of(T)]
}

@(private)
id_get :: proc($T: typeid, body: []u8) -> (id: T, ok: bool) {
	if len(body) < size_of(T) {
		return
	}
	when size_of(T) == 8 {
		return T(endian.unchecked_get_u64le(body)), true
	} else {
		#assert(size_of(T) == 4)
		return T(endian.unchecked_get_u32le(body)), true
	}
}
