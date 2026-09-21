#!/usr/bin/env python3
"""
Regenerates the web build's copies of the C bindings' declarations:
client/<pkg>/<pkg>_foreign_web.odin from client/<pkg>/<pkg>_foreign.odin.

On wasm, Odin names the procs of a named foreign import after the import
("system:c..yap_audio_create"), which no C object defines. The unnamed
form, `foreign _`, keeps the plain C names emscripten links against - so
the web copy is the native file without its `foreign import`, and with
`foreign lib` turned into `foreign _`. Run this after changing a
binding's declarations.
"""
import pathlib
import re

NOTE = """/*
The C declarations for a web build: the same as {native}, generated from
it by web/gen_foreign.py. On wasm Odin names a named foreign import's
procs after the import ("system:c..name"), which no C object defines;
the unnamed form, `foreign _`, keeps the plain C names that emscripten
links against.
*/
"""

# The `when ODIN_OS == ... { foreign import lib ... } else { ... }` chain
# that picks the library on a desktop.
IMPORT_CHAIN = re.compile(r"when ODIN_OS == [^\n]*\{\n\tforeign import.*?\n\}\n\n?", re.S)

root = pathlib.Path(__file__).resolve().parent.parent
for pkg in ("opus", "rnn", "miniaudio"):
    native = root / "client" / pkg / f"{pkg}_foreign.odin"
    text = native.read_text()
    tag = "#+build !wasi\n"
    assert text.startswith(tag), native
    body, found = IMPORT_CHAIN.subn("", text[len(tag):], count=1)
    assert found == 1, f"no foreign import chain in {native}"
    body = body.replace("foreign lib {", "foreign _ {")
    web = "#+build wasi\n" + NOTE.format(native=native.name) + body
    (native.parent / f"{pkg}_foreign_web.odin").write_text(web)
    print(f"wrote {native.parent.name}/{pkg}_foreign_web.odin")
