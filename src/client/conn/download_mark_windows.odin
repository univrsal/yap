package conn

import "core:os"
import "core:strings"

// mark_downloaded gives a file we saved from someone else (an attachment of a
// DM or of a message) the "Mark of the Web" that browsers set on their
// downloads. It is a Zone.Identifier stream saying that the file came from the
// internet. Windows then asks before running the file (SmartScreen), and Office
// opens it in Protected View. Failing to write the stream is ignored.
mark_downloaded :: proc(path: string) {
	stream := strings.concatenate({path, ":Zone.Identifier"}, context.temp_allocator)
	_ = os.write_entire_file(stream, "[ZoneTransfer]\r\nZoneId=3\r\n")
}
