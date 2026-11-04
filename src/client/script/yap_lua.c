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

/*
 * A budget for the pattern matching of one call of string.find, match, gmatch
 * (one step of the iterator) and gsub. The instruction hook can't interrupt
 * a call of a C function, and a pattern can take a time that grows as the
 * power (or even the exponent) of the length of what it is matched against.
 * The patched lstrlib.c counts a step for every call of match and
 * singlematch and raises an error when the budget is gone, in the way it
 * does for patterns that recurse too deeply. A million-byte string with a
 * simple pattern takes about two million steps, which is much less than a
 * tenth of a second.
 *
 * The count is per thread, since scripts run on the UI and on the network
 * thread, and a call starts a new one.
 */
#define YAP_PATTERN_STEPS 1000000L
#define YAP_PATTERN_STEPS_MAX 4000000L
#if defined(_MSC_VER)
#define YAP_THREAD_LOCAL __declspec(thread)
#else
#define YAP_THREAD_LOCAL __thread
#endif
static YAP_THREAD_LOCAL long yap_steps_left;
static void yap_pattern_begin(size_t subject) {
    /* A scan of a long string takes steps in proportion to its length. */
    yap_steps_left = subject > (size_t)(YAP_PATTERN_STEPS_MAX / 4) ? YAP_PATTERN_STEPS_MAX
                                                                    : YAP_PATTERN_STEPS + 3 * (long)subject;
}
static void yap_pattern_step(lua_State *L) {
    if (--yap_steps_left < 0) luaL_error(L, "pattern too complex (it took too many steps)");
}

/* the libraries scripts get */
#include "lbaselib.c"
#include "lcorolib.c"
#include "lmathlib.c"
/* Lua's own, with the steps counted (see above). */
#include "../../../deps/thirdparty/lua/lstrlib.c"
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
    /* No finalizers. They run when the state is closed, and while the
       collector runs the instruction hook is off, so a loop in one can't be
       stopped. Lua marks an object for finalization when the metatable has a
       __gc field at the moment of setmetatable (whatever its value), and not
       later, so this is the one place to check. */
    "local setmt, rawget, type = setmetatable, rawget, type\n"
    "function setmetatable(t, mt)\n"
    "  if type(mt) == 'table' and rawget(mt, '__gc') ~= nil then\n"
    "    error('setmetatable: __gc is not allowed', 2)\n"
    "  end\n"
    "  return setmt(t, mt)\n"
    "end\n"
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
    /* table.move({}, 1, 1 << 60) loops 2^60 times without allocating. */
    "local move = table.move\n"
    "function table.move(a1, f, e, t, a2)\n"
    "  if type(f) == 'number' and type(e) == 'number' and (e + 0.0) - f >= MAX_STRING then\n"
    "    error('table.move: too many elements to move', 2)\n"
    "  end\n"
    "  return move(a1, f, e, t, a2)\n"
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

#define MAX_VALUE_DEPTH 8

/* Pushes a value; false if it is nested too deeply or the stack can't hold it. */
static int push_value(lua_State *L, const yap_value *v, int depth) {
    size_t k;
    if (depth > MAX_VALUE_DEPTH || !lua_checkstack(L, 4)) return 0;
    switch (v->type) {
    case YAP_BOOL: lua_pushboolean(L, v->i != 0); break;
    case YAP_INT: lua_pushinteger(L, (lua_Integer)v->i); break;
    case YAP_NUM: lua_pushnumber(L, (lua_Number)v->n); break;
    case YAP_STR: lua_pushlstring(L, v->s ? v->s : "", v->len); break;
    case YAP_LIST:
        lua_createtable(L, (int)v->count, 0);
        for (k = 0; k < v->count; k++) {
            if (!push_value(L, &v->items[k], depth + 1)) return 0;
            lua_rawseti(L, -2, (lua_Integer)k + 1);
        }
        break;
    case YAP_MAP:
        lua_createtable(L, 0, (int)v->count);
        for (k = 0; k < v->count; k++) {
            if (!push_value(L, &v->items[2 * k + 1], depth + 1)) return 0;
            lua_setfield(L, -2, v->items[2 * k].s); /* keys are NUL terminated, see lua.odin */
        }
        break;
    default: lua_pushnil(L); break;
    }
    return 1;
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
    const yap_value *arg;
    int global;
    int fn;     /* with global == 2: the function, a reference in the registry */
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
        int type = a->global == 2 ? lua_rawgeti(co, LUA_REGISTRYINDEX, a->fn) : lua_getglobal(co, a->name);
        if (type != LUA_TFUNCTION) {
            a->missing = 1;
            return 0;
        }
        if (a->arg) {
            if (!lua_checkstack(co, 16) || !push_value(co, a->arg, 0)) return luaL_error(L, "event too large");
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

int yap_lua_spawn_global(void *state, const char *name, const yap_value *arg,
                         void **thread, int *ref, int *nargs, char *err, size_t errlen) {
    spawn_args a = {0};
    a.global = 1;
    a.name = name;
    a.arg = arg;
    a.thread = (lua_State **)thread;
    a.ref = ref;
    a.nargs = nargs;
    return spawn((lua_State *)state, &a, err, errlen);
}

int yap_lua_spawn_ref(void *state, int fn, const yap_value *arg,
                      void **thread, int *ref, int *nargs, char *err, size_t errlen) {
    spawn_args a = {0};
    a.global = 2;
    a.fn = fn;
    a.arg = arg;
    a.thread = (lua_State **)thread;
    a.ref = ref;
    a.nargs = nargs;
    return spawn((lua_State *)state, &a, err, errlen);
}

#define MAX_RESULT_NODES 4096

/* How a table is read: kinds of key. */
#define KEYS_NONE 0
#define KEYS_INT 1
#define KEYS_STR 2

/*
 * The first of a table's two passes: checks that it can be read (it is nested
 * and large enough within limits, and is a list or a map), and adds the number of
 * values it needs room for to `nodes`. No allocation, and nothing that can raise
 * an error.
 */
static int count_value(lua_State *L, int idx, int depth, size_t *nodes) {
    int kind = KEYS_NONE;
    size_t count = 0, max_key = 0;
    if (lua_type(L, idx) != LUA_TTABLE) return 1;
    idx = lua_absindex(L, idx);
    if (depth >= MAX_VALUE_DEPTH || !lua_checkstack(L, 5)) return 0;
    lua_pushnil(L);
    while (lua_next(L, idx)) {
        int kt = lua_type(L, -2);
        if (kind == KEYS_NONE) kind = kt == LUA_TSTRING ? KEYS_STR : KEYS_INT;
        if (kind == KEYS_STR && kt != LUA_TSTRING) { lua_pop(L, 2); return 0; }
        if (kind == KEYS_INT) {
            if (kt != LUA_TNUMBER || !lua_isinteger(L, -2) || lua_tointeger(L, -2) < 1) { lua_pop(L, 2); return 0; }
            if ((size_t)lua_tointeger(L, -2) > max_key) max_key = (size_t)lua_tointeger(L, -2);
        }
        count++;
        if (!count_value(L, lua_gettop(L), depth + 1, nodes)) { lua_pop(L, 2); return 0; }
        lua_pop(L, 1);
    }
    if (kind == KEYS_INT && max_key != count) return 0; /* holes: not a list */
    *nodes += kind == KEYS_STR ? 2 * count : count;
    return *nodes <= MAX_RESULT_NODES;
}

/* The second pass: reads the value at idx into *out; tables take their room from pool. */
static void fill_value(lua_State *L, int idx, yap_value *out, yap_value *pool, size_t *pos) {
    memset(out, 0, sizeof *out);
    idx = lua_absindex(L, idx);
    switch (lua_type(L, idx)) {
    case LUA_TBOOLEAN: out->type = YAP_BOOL; out->i = lua_toboolean(L, idx); break;
    case LUA_TNUMBER:
        if (lua_isinteger(L, idx)) { out->type = YAP_INT; out->i = lua_tointeger(L, idx); }
        else { out->type = YAP_NUM; out->n = lua_tonumber(L, idx); }
        break;
    case LUA_TSTRING: out->type = YAP_STR; out->s = lua_tolstring(L, idx, &out->len); break;
    case LUA_TTABLE: {
        size_t count = 0, j = 0;
        int map = 0;
        yap_value *items;
        lua_pushnil(L);
        while (lua_next(L, idx)) {
            map = lua_type(L, -2) == LUA_TSTRING;
            count++;
            lua_pop(L, 1);
        }
        out->type = map ? YAP_MAP : YAP_LIST;
        out->count = count;
        if (count == 0) break;
        items = pool + *pos;
        *pos += map ? 2 * count : count;
        out->items = items;
        lua_pushnil(L);
        while (lua_next(L, idx)) {
            if (map) {
                memset(&items[2 * j], 0, sizeof items[0]);
                items[2 * j].type = YAP_STR;
                items[2 * j].s = lua_tolstring(L, -2, &items[2 * j].len);
                fill_value(L, lua_gettop(L), &items[2 * j + 1], pool, pos);
                j++;
            } else {
                fill_value(L, lua_gettop(L), &items[lua_tointeger(L, -2) - 1], pool, pos);
            }
            lua_pop(L, 1);
        }
        break;
    }
    default: break;
    }
}

static void read_result(lua_State *co, yap_value *result) {
    size_t nodes = 0, pos = 0;
    yap_value *pool;
    if (!count_value(co, 1, 0, &nodes)) return; /* stays nil */
    if (nodes == 0) { fill_value(co, 1, result, NULL, &pos); return; }
    pool = (yap_value *)malloc(nodes * sizeof *pool);
    if (!pool) return;
    fill_value(co, 1, result, pool, &pos);
}

void yap_lua_value_free(yap_value *v) {
    if (v && (v->type == YAP_LIST || v->type == YAP_MAP)) free(v->items);
}

int yap_lua_resume(void *state, void *thread, int nargs, char *err, size_t errlen, yap_value *result) {
    lua_State *co = (lua_State *)thread;
    int nres = 0;
    int status = lua_resume(co, (lua_State *)state, nargs, &nres);
    if (result) memset(result, 0, sizeof *result);
    if (status == LUA_OK) {
        if (result && nres > 0) read_result(co, result);
        if (!result) lua_settop(co, 0); /* else the string is kept until the task is released */
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

#define MAX_API_ARGS 8

/* Lets go of the functions among the first n arguments that the host did not
 * keep, and of the room the tables took. */
static void release_funcs(lua_State *L, yap_value *args, void **pools, int n) {
    int k;
    for (k = 0; k < n; k++) {
        if (args[k].type == YAP_FUNC) luaL_unref(L, LUA_REGISTRYINDEX, (int)args[k].i);
        free(pools[k]);
        pools[k] = NULL;
    }
}

/* What every yap.* function is: an upvalue says which one, and the host does it. */
static int api_call(lua_State *L) {
    yap_lua_hook *h = hook_of(L);
    int op = (int)lua_tointeger(L, lua_upvalueindex(1));
    int n = lua_gettop(L), k;
    yap_value args[MAX_API_ARGS];
    void *pools[MAX_API_ARGS];
    yap_value ret;
    if (!h || !h->host) return luaL_error(L, "the host does not answer");
    if (n > MAX_API_ARGS) return luaL_error(L, "too many arguments (at most %d)", MAX_API_ARGS);
    memset(args, 0, sizeof args);
    memset(pools, 0, sizeof pools);
    for (k = 0; k < n; k++) {
        yap_value *a = &args[k];
        switch (lua_type(L, k + 1)) {
        case LUA_TNIL: a->type = YAP_NIL; break;
        case LUA_TBOOLEAN: a->type = YAP_BOOL; a->i = lua_toboolean(L, k + 1); break;
        case LUA_TNUMBER:
            if (lua_isinteger(L, k + 1)) { a->type = YAP_INT; a->i = lua_tointeger(L, k + 1); }
            else { a->type = YAP_NUM; a->n = lua_tonumber(L, k + 1); }
            break;
        case LUA_TSTRING: a->type = YAP_STR; a->s = lua_tolstring(L, k + 1, &a->len); break;
        case LUA_TFUNCTION:
            lua_pushvalue(L, k + 1);
            a->type = YAP_FUNC;
            a->i = luaL_ref(L, LUA_REGISTRYINDEX); /* may run out of memory: the ones before are released below */
            break;
        case LUA_TTABLE: {
            /* A list or a map of such values, read the way a result is. */
            size_t nodes = 0, pos = 0;
            if (!count_value(L, k + 1, 0, &nodes)) {
                release_funcs(L, args, pools, k);
                return luaL_argerror(L, k + 1, "a table must have only names or only 1..n as keys, and be at most 8 levels and 4096 values");
            }
            if (nodes > 0) {
                pools[k] = malloc(nodes * sizeof(yap_value));
                if (!pools[k]) { release_funcs(L, args, pools, k); return luaL_error(L, "out of memory"); }
            }
            fill_value(L, k + 1, a, (yap_value *)pools[k], &pos);
            break;
        }
        default:
            release_funcs(L, args, pools, k);
            return luaL_argerror(L, k + 1, "only nil, booleans, numbers, strings, functions and tables can be passed");
        }
    }
    memset(&ret, 0, sizeof ret);
    if (h->host(h->ud, op, args, n, &ret) != 0) {
        release_funcs(L, args, pools, n);
        return luaL_error(L, "%s", ret.type == YAP_STR && ret.s ? ret.s : "error");
    }
    release_funcs(L, args, pools, n);
    /* Always one result, so that yap.setting("x") is nil and not nothing (tostring would fail). */
    if (ret.type == YAP_NIL) { lua_pushnil(L); return 1; }
    if (!push_value(L, &ret, 0)) return luaL_error(L, "result too large");
    return 1;
}

static const char api_prelude[] =
    "local raw = yap._log\n"
    "yap._log = nil\n"
    "function yap.log(...)\n"
    "  local t = {}\n"
    "  for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end\n"
    "  raw(table.concat(t, ' '))\n"
    "end\n";

typedef struct {
    const char *const *names;
    int count;
} register_args;

static int register_f(lua_State *L) {
    register_args *a = (register_args *)lua_touserdata(L, 1);
    int k;
    lua_newtable(L); /* yap */
    for (k = 0; k < a->count; k++) {
        const char *name = a->names[k];
        const char *dot = strchr(name, '.');
        lua_pushvalue(L, -1);
        if (dot) {
            /* ns.fn: the table `ns` inside yap */
            lua_pushlstring(L, name, (size_t)(dot - name));
            if (lua_rawget(L, -2) != LUA_TTABLE) {
                lua_pop(L, 1);
                lua_newtable(L);
                lua_pushlstring(L, name, (size_t)(dot - name));
                lua_pushvalue(L, -2);
                lua_rawset(L, -4);
            }
            lua_remove(L, -2); /* the copy of yap */
            name = dot + 1;
        }
        lua_pushinteger(L, k);
        lua_pushcclosure(L, api_call, 1);
        lua_setfield(L, -2, name);
        lua_pop(L, 1);
    }
    lua_setglobal(L, "yap");
    if (luaL_loadbufferx(L, api_prelude, sizeof api_prelude - 1, "=api", "t") != LUA_OK) lua_error(L);
    lua_call(L, 0, 0);
    return 0;
}

int yap_lua_register(void *state, const char *const *names, int count) {
    lua_State *L = (lua_State *)state;
    register_args a;
    int status;
    a.names = names;
    a.count = count;
    lua_pushcfunction(L, register_f);
    lua_pushlightuserdata(L, &a);
    status = lua_pcall(L, 1, 0, 0);
    if (status != LUA_OK) {
        lua_pop(L, 1);
        return 1;
    }
    return 0;
}
