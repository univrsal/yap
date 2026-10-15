package platform

import log "common:wlog"
import "core:strings"
import "core:unicode"

// Links in chat messages: http(s):// URLs and bare www. addresses. The text
// shown is always the URL itself, so what you click is what opens.

Link :: struct {
	start, end: int, // byte range in the text
}

@(private = "file")
LINK_PREFIXES := [?]string{"https://", "http://", "www."}

// find_links returns the links in `text`, in order.
find_links :: proc(text: string, allocator := context.temp_allocator) -> []Link {
	links := make([dynamic]Link, allocator)
	i := 0
	outer: for i < len(text) {
		// Links only start at the beginning of a word, so "xhttp://" isn't a link.
		if i > 0 && is_word_byte(text[i - 1]) {
			i += 1
			continue
		}
		for prefix in LINK_PREFIXES {
			if len(text) - i <= len(prefix) ||
			   !strings.equal_fold(text[i:][:len(prefix)], prefix) {
				continue
			}
			end := link_end(text, i)
			if end - i > len(prefix) {
				append(&links, Link{i, end})
				i = end
				continue outer
			}
		}
		i += 1
	}
	return links[:]
}

// link_url returns the address to open for a link (bare www. links get
// https:// in front).
link_url :: proc(text: string, l: Link, allocator := context.temp_allocator) -> string {
	s := text[l.start:l.end]
	if len(s) >= 4 && strings.equal_fold(s[:4], "www.") {
		return strings.concatenate({"https://", s}, allocator)
	}
	return strings.clone(s, allocator)
}

// link_end finds where a link starting at `start` ends: at whitespace or a
// character that can't be in a URL, excluding trailing punctuation that more
// likely belongs to the sentence ("see https://example.com.") and closing
// brackets without a matching opening one ("(https://example.com)").
@(private = "file")
link_end :: proc(text: string, start: int) -> int {
	end := len(text)
	for r, i in text[start:] {
		if unicode.is_space(r) || unicode.is_control(r) || strings.contains_rune(`<>"{}|\^`, r) {
			end = start + i
			break
		}
	}
	for end > start {
		s := text[start:end]
		last := s[len(s) - 1]
		switch last {
		case '.', ',', ';', ':', '!', '?', '\'', '*':
			end -= 1
			continue
		case ')':
			if strings.count(s, "(") < strings.count(s, ")") {
				end -= 1
				continue
			}
		case ']':
			if strings.count(s, "[") < strings.count(s, "]") {
				end -= 1
				continue
			}
		}
		break
	}
	return end
}

@(private = "file")
is_word_byte :: proc(b: u8) -> bool {
	return(
		(b >= 'a' && b <= 'z') ||
		(b >= 'A' && b <= 'Z') ||
		(b >= '0' && b <= '9') ||
		b == '_' ||
		b >= 0x80 \
	)
}

// open_url opens a web address in the default browser. Anything but
// http(s) is refused, so a message can't make us run other handlers.
open_url :: proc(url: string) {
	lower := strings.to_lower(url, context.temp_allocator)
	if !strings.has_prefix(lower, "https://") && !strings.has_prefix(lower, "http://") {
		log.warnf("not opening %q: only http and https links are opened", url)
		return
	}
	for r in url {
		if unicode.is_space(r) || unicode.is_control(r) {
			log.warnf("not opening %q: it contains spaces or control characters", url)
			return
		}
	}
	log.infof("opening %s", url)
	if !platform_open_url(url) {
		log.errorf("could not open %s in the browser", url)
	}
}

// Extensions of files that the desktop may "open" from a saved attachment:
// pictures, videos, audio, archives and plain documents. A saved attachment
// came from someone else, and too many other kinds run code when opened
// (.exe and .js, but also .msc, .appref-ms, .settingcontent-ms, .chm,
// .webloc, .mobileconfig, .deb, ... and whatever is added next), so this is a
// list of what may be opened rather than of what may not. Disk images (.iso,
// .img, .vhd) and .cab are left out: Windows mounts or unpacks them, which
// has been used to get files past the Mark of the Web. Anything else can
// still be shown in its folder (open_folder).
@(rodata, private = "file")
OPENABLE_EXTENSIONS := [?]string {
	// Pictures
	"png",
	"jpg",
	"jpeg",
	"gif",
	"webp",
	"bmp",
	"tif",
	"tiff",
	"heic",
	"heif",
	"avif",
	// Videos
	"mp4",
	"m4v",
	"mkv",
	"webm",
	"mov",
	"avi",
	"wmv",
	"mpg",
	"mpeg",
	"ogv",
	// Audio
	"mp3",
	"m4a",
	"flac",
	"wav",
	"ogg",
	"opus",
	"aac",
	// Archives
	"zip",
	"rar",
	"7z",
	"tar",
	"gz",
	"tgz",
	"bz2",
	"xz",
	"zst",
	// Documents
	"pdf",
	"txt",
	"md",
	"csv",
	"log",
}

// file_openable says whether open_file opens the file at `path`.
file_openable :: proc(path: string) -> bool {
	dot := strings.last_index_byte(path, '.')
	sep := strings.last_index_any(path, `/\`)
	if dot <= sep || dot == len(path) - 1 {
		return false
	}
	ext := path[dot + 1:]
	for allowed in OPENABLE_EXTENSIONS {
		if strings.equal_fold(ext, allowed) {
			return true
		}
	}
	return false
}

// open_file opens a saved file with the system's default application, if it
// is of a kind that may be opened (file_openable).
open_file :: proc(path: string) {
	if !file_openable(path) {
		log.warnf(
			"not opening %q: only pictures, videos, audio, archives and documents are opened",
			path,
		)
		return
	}
	log.infof("opening %s", path)
	if !platform_open_url(path) {
		log.errorf("could not open %s", path)
	}
}

// open_folder shows a folder in the system's file manager.
open_folder :: proc(path: string) {
	log.infof("opening %s", path)
	if !platform_open_url(path) {
		log.errorf("could not open %s", path)
	}
}

// open_mailto opens the mail program with a new mail to `to` with the subject
// `subject`. Both may only contain the characters an address or a code is made
// of (letters, digits and . _ + -, plus @ in the address), so nothing else can
// end up in the link and nothing needs escaping.
open_mailto :: proc(to, subject: string) {
	plain :: proc(s: string, at_ok: bool) -> bool {
		if s == "" {
			return false
		}
		for i in 0 ..< len(s) {
			switch s[i] {
			case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '+', '-':
			case '@':
				if !at_ok {
					return false
				}
			case:
				return false
			}
		}
		return true
	}
	if !plain(to, true) || !plain(subject, false) {
		log.warnf("not writing a mail to %q about %q", to, subject)
		return
	}
	url := strings.concatenate({"mailto:", to, "?subject=", subject}, context.temp_allocator)
	log.infof("opening %s", url)
	if !platform_open_url(url) {
		log.errorf("could not open %s", url)
	}
}
