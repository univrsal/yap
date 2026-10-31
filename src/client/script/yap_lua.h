/*
 * Lua for the client's scripts (src/client/script), see yap_lua.c. States,
 * threads and the hook are void pointers here so that neither this header nor
 * the Odin code has to know Lua's headers.
 *
 * Errors, yields and the time limit are all setjmp/longjmp inside Lua, so they
 * happen in this file's C code and never across a frame of Odin: the
 * functions here return a status instead. That matters most in a web build,
 * where emscripten emulates longjmp.
 */
#ifndef YAP_LUA_H
#define YAP_LUA_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Lua's allocator interface (lua_Alloc). */
typedef void *(*yap_lua_alloc_fn)(void *ud, void *ptr, size_t osize, size_t nsize);

/*
 * Called by the hook every few hundred VM instructions of a running script
 * (and of every coroutine it makes). Returns 0 to carry on, 1 to suspend the
 * script until it is resumed (only done if that is possible where it is), or
 * 2 to kill it. `thread` is the thread that is running.
 */
typedef int (*yap_lua_check_fn)(void *ud, void *thread);

typedef struct yap_lua_hook {
    yap_lua_check_fn check;
    void *ud;
} yap_lua_hook;

/* The numbers of instructions between calls of the hook. */
#define YAP_LUA_HOOK_COUNT 1000

/* Results of yap_lua_spawn_* and yap_lua_resume. */
#define YAP_LUA_OK 0
#define YAP_LUA_ERROR 1
/* yap_lua_spawn_global: there is no function with that name. */
#define YAP_LUA_MISSING 2
/* yap_lua_resume: the script has not finished, it was suspended. */
#define YAP_LUA_YIELD 3

/*
 * A new state with the libraries scripts may use and nothing else (no io, os,
 * package or debug), and some of the base and string functions replaced with
 * safer ones (see the bootstrap code in yap_lua.c). `hook` must outlive the
 * state. NULL if it could not be made (out of memory).
 */
void *yap_lua_state_new(yap_lua_alloc_fn alloc, void *alloc_ud, yap_lua_hook *hook);
void yap_lua_state_close(void *state);
/* Collect all the garbage there is. */
void yap_lua_collect_garbage(void *state);

/*
 * Make a coroutine, to run with yap_lua_resume, that is
 *  - spawn_chunk: the text `src` (name for messages is "=name")
 *  - spawn_global: a call of the global function `name`, with the string `arg`
 *    as its argument unless that is NULL
 * `*thread` and `*ref` identify it; give the ref to yap_lua_release when it is
 * done with. On YAP_LUA_ERROR (a syntax error, out of memory) `err` has the
 * message and nothing needs releasing.
 */
int yap_lua_spawn_chunk(void *state, const char *src, size_t srclen, const char *name,
                        void **thread, int *ref, int *nargs, char *err, size_t errlen);
int yap_lua_spawn_global(void *state, const char *name, const char *arg, size_t arglen,
                         void **thread, int *ref, int *nargs, char *err, size_t errlen);

/* Run a task until it finishes, fails or is suspended. */
int yap_lua_resume(void *state, void *thread, int nargs, char *err, size_t errlen);

void yap_lua_release(void *state, int ref);

#ifdef __cplusplus
}
#endif

#endif
