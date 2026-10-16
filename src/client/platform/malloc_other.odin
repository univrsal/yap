#+build !linux
package platform

// malloc_tune is for glibc's malloc (malloc_linux.odin); other systems'
// allocators are left as they are.
malloc_tune :: proc() {}
