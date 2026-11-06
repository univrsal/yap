package main

import "core:log"
import "core:strings"

import "client:headless"

// Commands the message box does not know itself are the headless client's
// (client/headless/commands.odin), which answers by logging. The logging is
// caught here and shown: a short answer in the info line, a long one in a
// dialog.

@(private = "file")
Caught :: struct {
	text:    strings.Builder, // on the heap: the logger's own text is gone when it returns
	count:   int,
	is_warn: bool,
}

@(private = "file")
catch_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	c := cast(^Caught)data
	if c.count > 0 {
		strings.write_byte(&c.text, '\n')
	}
	strings.write_string(&c.text, text)
	c.count += 1
	c.is_warn ||= level >= .Warning
}

// run_headless_command hands a line to the headless client's parser and shows
// what it says.
run_headless_command :: proc(a: ^App, line: string) {
	caught: Caught
	strings.builder_init(&caught.text)
	defer strings.builder_destroy(&caught.text)
	saved := context.logger
	context.logger = log.Logger {
		procedure = catch_proc,
		data      = &caught,
		lowest_level = .Debug,
	}
	reader := headless.Reader {
		c = a.client,
	}
	headless.handle_line(&reader, line, &a.attached)
	context.logger = saved

	if caught.count == 0 {
		return
	}
	text := strings.to_string(caught.text)
	if caught.count == 1 && len(text) <= 100 && !strings.contains(text, ",") {
		say(a, text, caught.is_warn)
		return
	}
	show_output(a, text)
}

// show_output opens the dialog with a text in it.
show_output :: proc(a: ^App, text: string) {
	dialog_close(a)
	a.dialog.kind = .Output
	a.dialog.text = strings.clone(text)
}
