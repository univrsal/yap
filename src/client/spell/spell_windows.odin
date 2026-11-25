#+build windows
package spell

import log "common:wlog"
import win "core:sys/windows"

// Windows' own spell checker (Windows 8 and later), through its COM interface:
// a factory that knows which languages are installed and makes a checker for
// each. COM is set up on the calling thread if it isn't already.

@(private = "file")
CLSID_SpellCheckerFactory := win.GUID {
	0x7AB36653,
	0x1796,
	0x484B,
	{0xBD, 0xFA, 0xE7, 0x4F, 0x1D, 0xB7, 0xC1, 0xDC},
}

@(private = "file")
IID_ISpellCheckerFactory := win.GUID {
	0x8E018A9D,
	0x2415,
	0x4677,
	{0xBF, 0x08, 0x79, 0x4E, 0xA6, 0x1F, 0x94, 0xBB},
}

@(private = "file")
S_FALSE :: win.HRESULT(1)

@(private = "file")
ISpellCheckerFactory :: struct #raw_union {
	#subtype IUnknown: win.IUnknown,
	using Vtbl: ^ISpellCheckerFactory_Vtbl,
}

@(private = "file")
ISpellCheckerFactory_Vtbl :: struct {
	using IUnknownVtbl:     win.IUnknownVtbl,
	get_SupportedLanguages: proc "system" (
		this: ^ISpellCheckerFactory,
		value: ^^win.IEnumString,
	) -> win.HRESULT,
	IsSupported:            proc "system" (
		this: ^ISpellCheckerFactory,
		tag: win.LPCWSTR,
		value: ^win.BOOL,
	) -> win.HRESULT,
	CreateSpellChecker:     proc "system" (
		this: ^ISpellCheckerFactory,
		tag: win.LPCWSTR,
		value: ^^ISpellChecker,
	) -> win.HRESULT,
}

// Only the start of ISpellChecker's table, up to what is used.
@(private = "file")
ISpellChecker :: struct #raw_union {
	#subtype IUnknown: win.IUnknown,
	using Vtbl: ^ISpellChecker_Vtbl,
}

@(private = "file")
ISpellChecker_Vtbl :: struct {
	using IUnknownVtbl: win.IUnknownVtbl,
	get_LanguageTag:    proc "system" (this: ^ISpellChecker, value: ^win.LPWSTR) -> win.HRESULT,
	Check:              proc "system" (
		this: ^ISpellChecker,
		text: win.LPCWSTR,
		value: ^^IEnumSpellingError,
	) -> win.HRESULT,
	Suggest:            proc "system" (
		this: ^ISpellChecker,
		word: win.LPCWSTR,
		value: ^^win.IEnumString,
	) -> win.HRESULT,
}

@(private = "file")
IEnumSpellingError :: struct #raw_union {
	#subtype IUnknown: win.IUnknown,
	using Vtbl: ^IEnumSpellingError_Vtbl,
}

@(private = "file")
IEnumSpellingError_Vtbl :: struct {
	using IUnknownVtbl: win.IUnknownVtbl,
	Next:               proc "system" (
		this: ^IEnumSpellingError,
		value: ^^win.IUnknown,
	) -> win.HRESULT,
}

// A checker for one language.
Handle :: ^ISpellChecker

@(private = "file")
g_factory: ^ISpellCheckerFactory

@(private = "file")
g_failed: bool

@(private = "file")
factory :: proc() -> ^ISpellCheckerFactory {
	if g_factory == nil && !g_failed {
		// Already set up on this thread is just as good.
		win.CoInitializeEx(nil, .APARTMENTTHREADED)
		hr := win.CoCreateInstance(
			&CLSID_SpellCheckerFactory,
			nil,
			win.CLSCTX_INPROC_SERVER,
			&IID_ISpellCheckerFactory,
			cast(^win.LPVOID)&g_factory,
		)
		if win.FAILED(hr) {
			log.warnf("spell: no spell checker in Windows (0x%x)", u32(hr))
			g_factory, g_failed = nil, true
		}
	}
	return g_factory
}

@(private = "file")
wide :: proc(s: string) -> win.LPCWSTR {
	return win.utf8_to_wstring(s, context.temp_allocator)
}

// take_string is the string that COM handed over, in `allocator`, and frees it.
@(private = "file")
take_string :: proc(s: win.LPOLESTR, allocator := context.allocator) -> string {
	out, _ := win.wstring_to_utf8(s, -1, allocator)
	win.CoTaskMemFree(rawptr(s))
	return out
}

// take_strings are the strings of `e`, in `allocator`, and lets go of it.
@(private = "file")
take_strings :: proc(e: ^win.IEnumString, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for {
		s: win.LPOLESTR
		fetched: win.ULONG
		if e->Next(1, &s, &fetched) != win.S_OK || fetched != 1 {
			break
		}
		append(&out, take_string(s, allocator))
	}
	e->Release()
	return out[:]
}

@(private)
backend_available :: proc() -> bool {
	return factory() != nil
}

@(private)
backend_languages :: proc(dirs: []string, allocator := context.allocator) -> []string {
	f := factory()
	if f == nil {
		return nil
	}
	e: ^win.IEnumString
	if win.FAILED(f->get_SupportedLanguages(&e)) || e == nil {
		return nil
	}
	return take_strings(e, allocator)
}

@(private)
backend_open :: proc(tag: string, dirs: []string) -> (h: Handle, ok: bool) {
	f := factory()
	if f == nil {
		return nil, false
	}
	supported: win.BOOL
	if win.FAILED(f->IsSupported(wide(tag), &supported)) || !supported {
		log.warnf("spell: Windows has no %s", tag)
		return nil, false
	}
	if hr := f->CreateSpellChecker(wide(tag), &h); win.FAILED(hr) || h == nil {
		log.warnf("spell: couldn't check %s (0x%x)", tag, u32(hr))
		return nil, false
	}
	return h, true
}

@(private)
backend_close :: proc(h: Handle) {
	h->Release()
}

@(private)
backend_check :: proc(h: Handle, word: string) -> bool {
	e: ^IEnumSpellingError
	if win.FAILED(h->Check(wide(word), &e)) || e == nil {
		return true // nothing to go on
	}
	defer e->Release()
	err: ^win.IUnknown
	if e->Next(&err) != win.S_OK || err == nil {
		return true // S_FALSE: no errors
	}
	err->Release()
	return false
}

@(private)
backend_suggest :: proc(h: Handle, word: string, allocator := context.allocator) -> []string {
	e: ^win.IEnumString
	hr := h->Suggest(wide(word), &e)
	// S_FALSE: the word is right, and the list holds just it.
	if win.FAILED(hr) || hr == S_FALSE || e == nil {
		if e != nil {
			e->Release()
		}
		return nil
	}
	return take_strings(e, allocator)
}
