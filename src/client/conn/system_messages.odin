package conn

import "core:fmt"

import "common:proto"

// conv_system_text returns the text of a system message about a channel or the
// server (proto.Conv_System), which `name` did (`mine` if it was us) to
// `arg_name`, changing what `text` says. The result is allocated in the temp
// allocator.
conv_system_text :: proc(what: u8, text: string, name, arg_name: string, mine: bool) -> string {
	who := "You" if mine else name
	old, new := proto.system_change(text)
	switch proto.Conv_System(what) {
	case .Joined:
		return fmt.tprintf("%s joined the channel", who)
	case .Left:
		return fmt.tprintf("%s left the channel", who)
	case .Added:
		return fmt.tprintf("%s added %s to the channel", who, arg_name)
	case .Removed:
		return fmt.tprintf("%s removed %s from the channel", who, arg_name)
	case .Renamed:
		return fmt.tprintf("%s renamed the channel from #%s to #%s", who, old, new)
	case .Topic_Changed:
		switch {
		case new == "":
			return fmt.tprintf("%s cleared the topic", who)
		case old == "":
			return fmt.tprintf("%s set the topic: %s", who, new)
		}
		return fmt.tprintf("%s changed the topic to: %s", who, new)
	case .Made_Private:
		return fmt.tprintf("%s made the channel private", who)
	case .Made_Public:
		return fmt.tprintf("%s made the channel public", who)
	case .Archived:
		return fmt.tprintf("%s archived the channel", who)
	case .Unarchived:
		return fmt.tprintf("%s unarchived the channel", who)
	case .Joined_Server:
		return fmt.tprintf("%s joined the server", who)
	case .Left_Server:
		return fmt.tprintf("%s left the server", who)
	}
	return "(This version cannot display this message)"
}
