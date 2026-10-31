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

/*
 * A value that passes between a script and the host: what an event hands to a
 * handler, and what a host function returns or is given. A LIST has `count`
 * values in `items`; a MAP has `count` entries as 2 * count values, a STR key
 * and its value in turn.
 */
#define YAP_NIL 0
#define YAP_BOOL 1
#define YAP_INT 2
#define YAP_NUM 3
#define YAP_STR 4
#define YAP_LIST 5
#define YAP_MAP 6

typedef struct yap_value {
    int type;
    long long i;          /* BOOL, INT */
    double n;             /* NUM */
    const char *s;        /* STR */
    size_t len;           /* STR */
    struct yap_value *items;
    size_t count;         /* LIST, MAP */
} yap_value;

/*
 * The host's side of the API a script calls (yap.log and the rest, see
 * yap_lua_register). `op` is the position of the function in the names given
 * there, `args` the arguments (only nil, booleans, numbers and strings can be
 * passed). Returns 0 and the one value to return in `ret` (nil for none), or
 * 1 and a STR in `ret` for an error to raise in the script. What `ret` points
 * to has to stay valid until the next call.
 */
typedef int (*yap_lua_host_fn)(void *ud, int op, const yap_value *args, int nargs, yap_value *ret);

typedef struct yap_lua_hook {
    yap_lua_check_fn check;
    yap_lua_host_fn host;
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
/*
 * Makes the global table `yap` with a function for each of `names` ("log", or
 * "store.get" for one in a table of its own), which call the host (see
 * yap_lua_host_fn) with the name's position as `op`. `yap.log` takes any number
 * of values of any type and is a Lua function around names[0], which has to be
 * "_log" (taking one string). Returns 0, or 1 if there was no memory.
 */
int yap_lua_register(void *state, const char *const *names, int count);

/* Collect all the garbage there is. */
void yap_lua_collect_garbage(void *state);

/*
 * Make a coroutine, to run with yap_lua_resume, that is
 *  - spawn_chunk: the text `src` (name for messages is "=name")
 *  - spawn_global: a call of the global function `name`, with the value `arg`
 *    as its argument unless that is NULL
 * `*thread` and `*ref` identify it; give the ref to yap_lua_release when it is
 * done with. On YAP_LUA_ERROR (a syntax error, out of memory) `err` has the
 * message and nothing needs releasing.
 */
int yap_lua_spawn_chunk(void *state, const char *src, size_t srclen, const char *name,
                        void **thread, int *ref, int *nargs, char *err, size_t errlen);
int yap_lua_spawn_global(void *state, const char *name, const yap_value *arg,
                         void **thread, int *ref, int *nargs, char *err, size_t errlen);

/* Run a task until it finishes, fails or is suspended. */
int yap_lua_resume(void *state, void *thread, int nargs, char *err, size_t errlen);

void yap_lua_release(void *state, int ref);

#ifdef __cplusplus
}
#endif

#endif
