/*
SQLite, as the server uses it: the whole library in one translation
unit, with what the server doesn't need left out. build.sh and build.bat
compile this against the source scripts/fetch-sqlite.sh unpacks.

The options are the ones SQLite's own documentation recommends for an
application that links it statically, and that it says are safe to set
when building from the amalgamation:

  THREADSAFE=2          a connection is only ever used by one thread at a
                        time (the server's loop), but SQLite's own shared
                        state stays guarded, should another thread get a
                        connection of its own one day
  DQS=0                 "double quotes" are identifiers, never strings
  DEFAULT_MEMSTATUS=0   no bookkeeping of memory use
  DEFAULT_WAL_SYNCHRONOUS=1  in WAL mode, don't wait for the disk on every
                        commit (the server's loop relays voice)
  LIKE_DOESNT_MATCH_BLOBS, MAX_EXPR_DEPTH=0, USE_ALLOCA  small savings
  OMIT_*                things never used: loadable extensions, column
                        declared types, deprecated interfaces, the shared
                        cache
  DEFAULT_FOREIGN_KEYS=1  REFERENCES is enforced
  ENABLE_FTS5           full-text search, for searching messages
                        (server/search.odin), whose time the progress
                        callback caps
*/
#define SQLITE_THREADSAFE 2
#define SQLITE_DQS 0
#define SQLITE_DEFAULT_MEMSTATUS 0
#define SQLITE_DEFAULT_WAL_SYNCHRONOUS 1
#define SQLITE_LIKE_DOESNT_MATCH_BLOBS 1
#define SQLITE_MAX_EXPR_DEPTH 0
#define SQLITE_USE_ALLOCA 1
#define SQLITE_OMIT_LOAD_EXTENSION 1
#define SQLITE_OMIT_DECLTYPE 1
#define SQLITE_OMIT_DEPRECATED 1
#define SQLITE_OMIT_SHARED_CACHE 1
#define SQLITE_DEFAULT_FOREIGN_KEYS 1
#define SQLITE_ENABLE_FTS5 1

#include "sqlite3.c"
