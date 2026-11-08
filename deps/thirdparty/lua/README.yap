Lua 5.4.8 (https://www.lua.org/ftp/lua-5.4.8.tar.gz, sha256
4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae), the
src/ folder without lua.c and luac.c, MIT licensed (the notice is in lua.h).
Kept in the repo so a build never depends on lua.org being reachable.

src/client/script/yap_lua.c compiles it as one file. lstrlib.c is the one
change: the original with four lines added, marked YAP (see the comment at its
top). To update Lua, copy the new src/ files here and add those lines to the
new lstrlib.c again.
