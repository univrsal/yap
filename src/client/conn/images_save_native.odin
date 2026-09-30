#+build !wasi
package conn

import log "common:wlog"
import "core:fmt"
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

// save_dm_image writes a picture that came in a DM to -image-dir, like
// save_image.
save_dm_image :: proc(c: ^Voice_Client, id: u64, picture: DM_Picture) {
	if c.images.dir == "" {
		return
	}
	name := fmt.tprintf("dm-%x.jpg", id)
	path, _ := filepath.join({c.images.dir, name}, context.temp_allocator)
	if err := os.write_entire_file(path, picture.jpeg); err != nil {
		log.errorf("could not save %s: %v", path, err)
		return
	}
	log.infof("saved a DM image to %s (%dx%d)", path, picture.width, picture.height)
}
