// An instruction budget for one plugin call, so a loop that never ends can't
// hang Visor: the hook runs every 1000 instructions and raises an error once
// the budget is spent.
#include <stdlib.h>
#include "CLua.h"

static void clua_budget_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    long *left = (long *)lua_getextraspace(L);
    *left -= 1000;
    if (*left <= 0) {
        lua_sethook(L, NULL, 0, 0);
        luaL_error(L, "took too long (instruction budget used up)");
    }
}

void clua_set_budget(lua_State *L, long budget) {
    long *left = (long *)lua_getextraspace(L);
    *left = budget;
    if (budget > 0) {
        lua_sethook(L, clua_budget_hook, LUA_MASKCOUNT, 1000);
    } else {
        lua_sethook(L, NULL, 0, 0);
    }
}

// Swift functions for Lua. Each is a C closure over (context, function number);
// the dispatcher does the work and returns how many results it pushed, or -1
// with an error message on top of the stack. The error is raised here, in C,
// so Lua's longjmp never unwinds through Swift frames.
static clua_dispatch_fn clua_dispatcher;
void clua_enforce(lua_State *L, int on);

void clua_set_dispatch(clua_dispatch_fn fn) { clua_dispatcher = fn; }

static int clua_over(lua_State *L);

static int clua_trampoline(lua_State *L) {
    void *ctx = lua_touserdata(L, lua_upvalueindex(1));
    int fn = (int)lua_tointeger(L, lua_upvalueindex(2));
    // Swift's pushes may not fail midway: no cap while it runs, checked after.
    clua_enforce(L, 0);
    int n = clua_dispatcher(L, ctx, fn);
    if (n >= 0 && clua_over(L)) {
        lua_pushliteral(L, "not enough memory (plugin limit)");
        n = -1;
    }
    clua_enforce(L, 1);
    if (n < 0) return lua_error(L);
    return n;
}

void clua_pushfunction(lua_State *L, void *ctx, int fn) {
    lua_pushlightuserdata(L, ctx);
    lua_pushinteger(L, fn);
    lua_pushcclosure(L, clua_trampoline, 2);
}

// A memory cap per plugin. Enforced only while plugin code runs (clua_enforce):
// Visor's own pushes into the state never fail halfway, and a plugin that asks
// for too much gets Lua's "not enough memory" error instead of taking Visor down.
typedef struct { size_t used, limit; int enforce; } clua_mem;

static void *clua_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    clua_mem *m = (clua_mem *)ud;
    size_t old = ptr ? osize : 0;  // without ptr, osize is a type tag, not a size
    if (nsize == 0) {
        m->used -= old;
        free(ptr);
        return NULL;
    }
    if (m->enforce && nsize > old && m->used + (nsize - old) > m->limit) return NULL;
    void *p = realloc(ptr, nsize);
    if (p) m->used = m->used - old + nsize;
    return p;
}

lua_State *clua_newstate(size_t limit) {
    clua_mem *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->limit = limit;
    lua_State *L = lua_newstate(clua_alloc, m);
    if (!L) free(m);
    return L;
}

void clua_enforce(lua_State *L, int on) {
    void *ud;
    lua_getallocf(L, &ud);
    ((clua_mem *)ud)->enforce = on;
}

static int clua_over(lua_State *L) {
    void *ud;
    lua_getallocf(L, &ud);
    clua_mem *m = (clua_mem *)ud;
    return m->used > m->limit;
}

void clua_close(lua_State *L) {
    void *ud;
    lua_getallocf(L, &ud);
    lua_close(L);
    free(ud);
}
