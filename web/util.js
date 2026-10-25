/*
Helpers the other web/*.js files share (web/build.sh puts this one first).
*/

// yapWithBytes copies `bytes` to the wasm heap, calls fn(pointer, length) and
// frees the copy again. There is a NUL after the bytes, so a C string works too.
Module.yapWithBytes = (bytes, fn) => {
	const ptr = _malloc(bytes.length + 1);
	HEAPU8.set(bytes, ptr);
	HEAPU8[ptr + bytes.length] = 0;
	try {
		return fn(ptr, bytes.length);
	} finally {
		_free(ptr);
	}
};

// yapWithString is yapWithBytes for the UTF-8 of a string.
Module.yapWithString = (s, fn) => Module.yapWithBytes(new TextEncoder().encode(s), fn);
