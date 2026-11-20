// An instruction budget for one plugin call, so a loop that never ends can't
// hang Visor: the hook runs every 1000 instructions and raises an error once
// the budget is spent.
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

void clua_set_dispatch(clua_dispatch_fn fn) { clua_dispatcher = fn; }

static int clua_trampoline(lua_State *L) {
    void *ctx = lua_touserdata(L, lua_upvalueindex(1));
    int fn = (int)lua_tointeger(L, lua_upvalueindex(2));
    int n = clua_dispatcher(L, ctx, fn);
    if (n < 0) return lua_error(L);
    return n;
}

void clua_pushfunction(lua_State *L, void *ctx, int fn) {
    lua_pushlightuserdata(L, ctx);
    lua_pushinteger(L, fn);
    lua_pushcclosure(L, clua_trampoline, 2);
}
