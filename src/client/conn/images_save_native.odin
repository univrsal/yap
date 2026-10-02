#+build !wasi
package conn

import log "common:wlog"
import "core:fmt"
import "core:os"
import "core:path/filepath"

import "common:proto"

// save_image writes a picture that arrived to -image-dir, which headless
// mode uses to show what it received. A web build has no directories to
// write to and no headless mode either (see images_save_web.odin).
save_image :: proc(c: ^Voice_Client, id: proto.Blob_Id, f: ^Blob_Fetch) {
	if c.blobs.dir == "" {
		return
	}
	name := fmt.tprintf("image-%d.jpg", id)
	path, _ := filepath.join({c.blobs.dir, name}, context.temp_allocator)
	if err := os.write_entire_file(path, f.data); err != nil {
		log.errorf("could not save %s: %v", path, err)
		return
	}
	log.infof("saved picture %d to %s (%dx%d)", id, path, f.image.width, f.image.height)
}
