package client

import "core:strings"
import "core:time"

// The undo history of a text area (the composer's box).
//
// It doesn't follow the keys that edit the text but the text itself: each
// frame the text area says what its text is (history_note), and when that
// isn't what it was, the old text is kept. So changes that aren't typing, like
// a completion, a markdown key or starting to edit a message, can be undone
// too, without each of them having to know about the history.
//
// Changes close together are one step. A change starts a new step when the
// last one is older than HISTORY_GAP, when it is larger than HISTORY_BURST
// bytes (a paste, a cut, a completion), or when it goes the other way (typing
// then deleting). Undoing or redoing always ends a step.

HISTORY_GAP :: 500 * time.Millisecond
HISTORY_BURST :: 16
HISTORY_STEPS :: 100
// The most text that the history keeps. The oldest steps go first.
HISTORY_BYTES :: 1 << 20

History_Step :: struct {
	text: string,
	sel:  [2]int,
}

Text_History :: struct {
	undo, redo: [dynamic]History_Step,
	now:        History_Step, // the text at the last note
	bytes:      int, // what undo and redo hold
	at:         time.Tick, // of the last change
	grew:       bool, // the last change added text
	new_step:   bool, // the next change starts a step (after an undo or redo)
	started:    bool, // `now` is set
}

// history_note says what the text is. When it differs from the last note, the
// change is recorded.
history_note :: proc(h: ^Text_History, text: string, sel: [2]int, at: time.Tick) {
	if !h.started {
		h.started = true
		h.now = History_Step{clone_text(text), sel}
		return
	}
	if text == h.now.text {
		h.now.sel = sel // so an undo goes back to where the caret was
		return
	}
	grew := len(text) > len(h.now.text)
	delta := abs(len(text) - len(h.now.text))
	if h.new_step ||
	   delta > HISTORY_BURST ||
	   grew != h.grew ||
	   time.tick_diff(h.at, at) >= HISTORY_GAP {
		history_push(h, &h.undo, h.now)
		for s in h.redo {
			h.bytes -= len(s.text)
			delete(s.text)
		}
		clear(&h.redo)
	} else {
		delete(h.now.text)
	}
	h.now = History_Step{clone_text(text), sel}
	h.grew, h.at, h.new_step = grew, at, false
}

// history_undo steps back. It returns the text to put back and the selection
// that goes with it, or false when there is nothing to undo.
history_undo :: proc(h: ^Text_History, text: string) -> (to: History_Step, ok: bool) {
	return history_move(h, &h.undo, &h.redo, text)
}

history_redo :: proc(h: ^Text_History, text: string) -> (to: History_Step, ok: bool) {
	return history_move(h, &h.redo, &h.undo, text)
}

// history_clear forgets everything: the text was sent, or is another's now.
history_clear :: proc(h: ^Text_History) {
	for s in h.undo {
		delete(s.text)
	}
	for s in h.redo {
		delete(s.text)
	}
	delete(h.undo)
	delete(h.redo)
	delete(h.now.text)
	h^ = {}
}

@(private = "file")
history_move :: proc(
	h: ^Text_History,
	from, to: ^[dynamic]History_Step,
	text: string,
) -> (
	step: History_Step,
	ok: bool,
) {
	if len(from) == 0 || !h.started {
		return
	}
	// The text as it is, if it hasn't been noted yet, is what goes the other way.
	if text != h.now.text {
		delete(h.now.text)
		h.now.text = clone_text(text)
	}
	step = pop(from)
	h.bytes -= len(step.text)
	history_push(h, to, h.now)
	h.now = step // valid until the next note
	h.new_step = true
	return step, true
}

// history_push puts a step on a stack, which takes over its text.
@(private = "file")
history_push :: proc(h: ^Text_History, stack: ^[dynamic]History_Step, step: History_Step) {
	append(stack, step)
	h.bytes += len(step.text)
	for len(h.undo) > HISTORY_STEPS || (h.bytes > HISTORY_BYTES && len(h.undo) > 1) {
		h.bytes -= len(h.undo[0].text)
		delete(h.undo[0].text)
		ordered_remove(&h.undo, 0)
	}
}

@(private = "file")
clone_text :: proc(text: string) -> string {
	s, _ := strings.clone(text)
	return s
}
