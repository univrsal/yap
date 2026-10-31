/*
 * Lua for the client's scripts: the language and the libraries scripts may use,
 * in one translation unit (the release tarball has no onelua.c), and the few
 * functions around it that src/client/script/lua.odin binds. build.sh and
 * build.bat compile this against the source scripts/build/fetch.sh unpacks,
 * web/build.sh with emscripten.
 *
 * Left out on purpose: io, os, package (so no require) and debug, and with
 * them everything that reaches the machine; and the interpreter. Internal
 * symbols are static so that no other Lua in the process can clash with them.
 */
#include "lprefix.h"

#include <ctype.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <locale.h>
#include <math.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define LUA_CORE
#define LUA_LIB
#define ltable_c
#define lvm_c
#include "luaconf.h"

#undef LUAI_FUNC
#undef LUAI_DDEF
#undef LUAI_DDECL
#define LUAI_FUNC static
#define LUAI_DDEF static
#define LUAI_DDECL static

/* core */
#include "lzio.c"
#include "lctype.c"
#include "lopcodes.c"
#include "lmem.c"
#include "lundump.c"
#include "ldump.c"
#include "lstate.c"
#include "lgc.c"
#include "llex.c"
#include "lcode.c"
#include "lparser.c"
#include "ldebug.c"
#include "lfunc.c"
#include "lobject.c"
#include "ltm.c"
#include "lstring.c"
#include "ltable.c"
#include "ldo.c"
#include "lvm.c"
#include "lapi.c"

/* auxiliary library */
#include "lauxlib.c"

/* the libraries scripts get */
#include "lbaselib.c"
#include "lcorolib.c"
#include "lmathlib.c"
#include "lstrlib.c"
#include "ltablib.c"
#include "lutf8lib.c"

#include "yap_lua.h"

/*
 * What is changed before a script runs, written in Lua. A script's state is
 * its own, so none of this protects other scripts, only the program: what a
 * script could do to make the client stall, or to reach what it shouldn't.
 */
static const char bootstrap[] =
    "local rep, find, match, gmatch, gsub = string.rep, string.find, string.match, string.gmatch, string.gsub\n"
    "local load0, gc = load, collectgarbage\n"
    "local MAX_STRING, MAX_PATTERN = 1 << 20, 200\n"
    /* No binary chunks (string.dump), no files, no output on the console. */
    "string.dump, dofile, loadfile, print = nil, nil, nil, nil\n"
    /* Text only, whatever the script asks for. */
    "function load(chunk, name, mode, ...) return load0(chunk, name, 't', ...) end\n"
    /* Counting and a full collection; the rest changes how the collector
       works, which is not the script's to decide. */
    "function collectgarbage(opt)\n"
    "  if opt == 'count' then return gc('count') end\n"
    "  if opt == nil or opt == 'collect' then return gc('collect') end\n"
    "  error('collectgarbage: only \"count\" and \"collect\" are allowed', 2)\n"
    "end\n"
    /* One call to a library function can't be interrupted, so the ones that
       can run for long or allocate a lot are given limits first. */
    "function string.rep(s, n, sep)\n"
    "  local t = type(s)\n"
    "  if (t == 'string' or t == 'number') and type(n) == 'number' then\n"
    "    if (#tostring(s) + (sep and #tostring(sep) or 0)) * n > MAX_STRING then\n"
    "      error('string.rep: result too large', 2)\n"
    "    end\n"
    "  end\n"
    "  return rep(s, n, sep)\n"
    "end\n"
    "local function limited(f, name)\n"
    "  return function(s, pattern, ...)\n"
    "    if type(pattern) == 'string' and #pattern > MAX_PATTERN then\n"
    "      error(name .. ': pattern too long', 2)\n"
    "    end\n"
    "    return f(s, pattern, ...)\n"
    "  end\n"
    "end\n"
    "string.find = limited(find, 'string.find')\n"
    "string.match = limited(match, 'string.match')\n"
    "string.gmatch = limited(gmatch, 'string.gmatch')\n"
    "string.gsub = limited(gsub, 'string.gsub')\n";

/* In the extra space of every thread: the hook. New threads copy it from the
 * main one. */
static yap_lua_hook *hook_of(lua_State *L) {
    return *(yap_lua_hook **)lua_getextraspace(L);
}

static void hook(lua_State *L, lua_Debug *ar) {
    yap_lua_hook *h = hook_of(L);
    (void)ar;
    if (!h) return;
    switch (h->check(h->ud, L)) {
    case 2:
        /* Run the hook after every instruction from now on, so that a script
           that catches this error with pcall is stopped again at once. */
        lua_sethook(L, hook, LUA_MASKCOUNT, 1);
        luaL_error(L, "script ran too long");
        break;
    case 1:
        if (lua_isyieldable(L)) lua_yield(L, 0);
        break;
    default:
        break;
    }
}

static int yap_panic(lua_State *L) {
    /* Everything that can fail runs in a protected call, so this is a bug
       in this file. Say so, and let Lua abort. */
    const char *m = lua_tostring(L, -1);
    fprintf(stderr, "PANIC: unprotected error in call to Lua API (%s)\n", m ? m : "?");
    return 0;
}

static int init(lua_State *L) {
    luaL_requiref(L, "_G", luaopen_base, 1);
    luaL_requiref(L, LUA_COLIBNAME, luaopen_coroutine, 1);
    luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1);
    luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1);
    luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1);
    luaL_requiref(L, LUA_UTF8LIBNAME, luaopen_utf8, 1);
    lua_settop(L, 0);
    if (luaL_loadbufferx(L, bootstrap, sizeof bootstrap - 1, "=bootstrap", "t") != LUA_OK) lua_error(L);
    lua_call(L, 0, 0);
    return 0;
}

void *yap_lua_state_new(yap_lua_alloc_fn alloc, void *alloc_ud, yap_lua_hook *h) {
    lua_State *L = lua_newstate(alloc, alloc_ud);
    if (!L) return NULL;
    *(yap_lua_hook **)lua_getextraspace(L) = h;
    lua_atpanic(L, yap_panic);
    lua_pushcfunction(L, init);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        lua_close(L);
        return NULL;
    }
    /* The main thread's own code is the host's; coroutines made from now on
       inherit the hook (lua_newthread copies it). */
    lua_sethook(L, hook, LUA_MASKCOUNT, YAP_LUA_HOOK_COUNT);
    return L;
}

void yap_lua_state_close(void *state) {
    lua_close((lua_State *)state);
}

void yap_lua_collect_garbage(void *state) {
    lua_gc((lua_State *)state, LUA_GCCOLLECT);
}

static void copy_error(lua_State *L, char *err, size_t errlen) {
    const char *m = lua_tostring(L, -1);
    if (!m) m = lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, -1));
    if (errlen > 0) {
        strncpy(err, m, errlen - 1);
        err[errlen - 1] = 0;
    }
}

typedef struct {
    const char *src;
    size_t srclen;
    const char *name;
    const char *arg;
    size_t arglen;
    int global;
    lua_State **thread;
    int *ref;
    int *nargs;
    int missing;
} spawn_args;

/* Runs protected: making a thread can run out of memory. */
static int spawn_f(lua_State *L) {
    spawn_args *a = (spawn_args *)lua_touserdata(L, 1);
    lua_State *co = lua_newthread(L);
    *a->thread = co;
    /* The thread is kept by the registry from here on, until it is released. */
    *a->ref = luaL_ref(L, LUA_REGISTRYINDEX);
    *a->nargs = 0;
    if (!a->global) {
        if (luaL_loadbufferx(co, a->src, a->srclen, a->name, "t") != LUA_OK) {
            lua_xmove(co, L, 1);
            return lua_error(L);
        }
    } else {
        if (lua_getglobal(co, a->name) != LUA_TFUNCTION) {
            a->missing = 1;
            return 0;
        }
        if (a->arg) {
            lua_pushlstring(co, a->arg, a->arglen);
            *a->nargs = 1;
        }
    }
    return 0;
}

static int spawn(lua_State *L, spawn_args *a, char *err, size_t errlen) {
    int status;
    *a->ref = LUA_NOREF;
    a->missing = 0;
    lua_pushcfunction(L, spawn_f);
    lua_pushlightuserdata(L, a);
    status = lua_pcall(L, 1, 0, 0);
    if (status != LUA_OK) {
        copy_error(L, err, errlen);
        lua_pop(L, 1);
        if (*a->ref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, *a->ref);
        return YAP_LUA_ERROR;
    }
    if (a->missing) {
        luaL_unref(L, LUA_REGISTRYINDEX, *a->ref);
        return YAP_LUA_MISSING;
    }
    return YAP_LUA_OK;
}

int yap_lua_spawn_chunk(void *state, const char *src, size_t srclen, const char *name,
                        void **thread, int *ref, int *nargs, char *err, size_t errlen) {
    spawn_args a = {0};
    a.src = src;
    a.srclen = srclen;
    a.name = name;
    a.thread = (lua_State **)thread;
    a.ref = ref;
    a.nargs = nargs;
    return spawn((lua_State *)state, &a, err, errlen);
}

int yap_lua_spawn_global(void *state, const char *name, const char *arg, size_t arglen,
                         void **thread, int *ref, int *nargs, char *err, size_t errlen) {
    spawn_args a = {0};
    a.global = 1;
    a.name = name;
    a.arg = arg;
    a.arglen = arglen;
    a.thread = (lua_State **)thread;
    a.ref = ref;
    a.nargs = nargs;
    return spawn((lua_State *)state, &a, err, errlen);
}

int yap_lua_resume(void *state, void *thread, int nargs, char *err, size_t errlen) {
    lua_State *co = (lua_State *)thread;
    int nres = 0;
    int status = lua_resume(co, (lua_State *)state, nargs, &nres);
    if (status == LUA_OK) {
        lua_settop(co, 0);
        return YAP_LUA_OK;
    }
    if (status == LUA_YIELD) {
        /* A yield passes values to whoever resumes; there is nobody to
           pass them to. */
        lua_pop(co, nres);
        return YAP_LUA_YIELD;
    }
    copy_error(co, err, errlen);
    return YAP_LUA_ERROR;
}

void yap_lua_release(void *state, int ref) {
    luaL_unref((lua_State *)state, LUA_REGISTRYINDEX, ref);
}
