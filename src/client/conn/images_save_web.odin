#+build wasi
package conn

import "common:proto"

// Nothing to save to: a web build has no image directory, which is a
// headless option in the first place.
save_image :: proc(c: ^Voice_Client, id: proto.Blob_Id, f: ^Blob_Fetch) {}
