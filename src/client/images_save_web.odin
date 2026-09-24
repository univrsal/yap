#+build wasi
package client

// Nothing to save to: a web build has no image directory, which is a
// headless option in the first place.
save_image :: proc(c: ^Voice_Client, id: u32, img: ^Client_Image) {}
