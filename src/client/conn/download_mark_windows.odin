package conn

import "core:os"
import "core:strings"

/*
mark_downloaded gives a file we've saved from someone else (a DM's file,
or a message's) the mark a browser gives its downloads: the "Mark of the
Web", a Zone.Identifier stream saying it came from the internet. Windows
then asks before running it (SmartScreen), and Office opens it in
Protected View. Nothing comes of it if it can't be written.
*/
mark_downloaded :: proc(path: string) {
	stream := strings.concatenate({path, ":Zone.Identifier"}, context.temp_allocator)
	_ = os.write_entire_file(stream, "[ZoneTransfer]\r\nZoneId=3\r\n")
}
