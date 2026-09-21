/*
The few WASI calls Odin's runtime makes at start-up that emscripten
doesn't implement itself. The build targets WASI because that is where
Odin has a clock and an entropy source (which the Noise handshake can't
do without); emscripten provides those two, and these answer the rest:
a page has no command line and no directories to open.

(Emscripten copies each of these into the page on its own, so they can't
share constants: 0 is WASI's success, 8 its EBADF.)
*/
addToLibrary({
  args_sizes_get: (argc, argvBufSize) => {
    HEAPU32[argc >> 2] = 0;
    HEAPU32[argvBufSize >> 2] = 0;
    return 0;
  },
  args_get: (argv, argvBuf) => 0,
  // No preopened directories: the first descriptor asked about is bad.
  fd_prestat_get: (fd, prestat) => 8,
  fd_prestat_dir_name: (fd, path, len) => 8,
  fd_filestat_get: (fd, stat) => 8,
});
