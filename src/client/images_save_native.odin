#+build !wasi
package client

import "core:fmt"
import log "../common/wlog"
import "core:os"
import "core:path/filepath"

// See the note where this is called in images.odin.
save_image :: proc(c: ^Voice_Client, id: u32, img: ^Client_Image) {
	if c.images.dir == "" {
		return
	}
	name := fmt.tprintf("image-%d.jpg", id)
	path, _ := filepath.join({c.images.dir, name}, context.temp_allocator)
	if err := os.write_entire_file(path, img.data); err != nil {
		log.errorf("could not save %s: %v", path, err)
		return
	}
	log.infof("saved image %d to %s (%dx%d)", id, path, img.info.width, img.info.height)
}
