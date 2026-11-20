// Lua 5.4 for Visor plugins, plus functions for the parts of Lua's API that
// are C macros, which Swift can't call.
#ifndef CLUA_H
#define CLUA_H

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static inline int clua_registryindex(void) { return LUA_REGISTRYINDEX; }
static inline int clua_upvalueindex(int i) { return lua_upvalueindex(i); }
static inline void clua_pop(lua_State *L, int n) { lua_pop(L, n); }
static inline void clua_newtable(lua_State *L) { lua_newtable(L); }
static inline const char *clua_tostring(lua_State *L, int i) { return lua_tolstring(L, i, NULL); }
static inline int clua_isnoneornil(lua_State *L, int i) { return lua_isnoneornil(L, i); }
static inline int clua_pcall(lua_State *L, int nargs, int nresults) { return lua_pcall(L, nargs, nresults, 0); }
static inline int clua_loadstring(lua_State *L, const char *source, size_t length, const char *name) {
    // Text only: precompiled chunks can crash the VM.
    return luaL_loadbufferx(L, source, length, name, "t");
}
static inline void clua_remove(lua_State *L, int i) { lua_remove(L, i); }
static inline void clua_insert(lua_State *L, int i) { lua_insert(L, i); }

/// Calls into Swift: returns the number of results pushed, or -1 with an error message on top.
typedef int (*clua_dispatch_fn)(lua_State *L, void *ctx, int fn);
void clua_set_dispatch(clua_dispatch_fn fn);
/// Pushes a Lua function that calls the dispatcher with `ctx` and `fn`.
void clua_pushfunction(lua_State *L, void *ctx, int fn);

/// A state whose allocations are capped at `limit` bytes while enforced.
lua_State *clua_newstate(size_t limit);
/// Turns the memory cap on (plugin code running) or off (Visor's own work).
void clua_enforce(lua_State *L, int on);
/// Closes a state made by clua_newstate.
void clua_close(lua_State *L);

/// Stops a call that runs too long: after `budget` instructions, raises an error.
void clua_set_budget(lua_State *L, long budget);

#endif
