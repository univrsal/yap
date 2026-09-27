/*
tinydialogs (tinydialogs.h, MIT or Unlicense), native file dialogs,
compiled as one translation unit for yap; see dialogs.odin. On Linux and
the BSDs it runs zenity or kdialog, on Windows it's the shell's
IFileDialog, and on macOS NSOpenPanel, so there it's built as
Objective-C.
*/
#define TINYDIALOGS_IMPLEMENTATION
#include "../../../deps/thirdparty/tinydialogs/tinydialogs.h"
