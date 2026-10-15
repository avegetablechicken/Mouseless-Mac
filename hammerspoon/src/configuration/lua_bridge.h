// Lua 5.4 C API used by Bridge.swift; symbols resolve from Hammerspoon's LuaSkin at load time.
#include <stddef.h>
#include <stdint.h>

typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);
typedef long long lua_Integer;

int lua_gettop(lua_State *L);
void lua_settop(lua_State *L, int idx);
void lua_pushvalue(lua_State *L, int idx);
int lua_type(lua_State *L, int idx);
const char *lua_tolstring(lua_State *L, int idx, size_t *len);
const char *lua_pushlstring(lua_State *L, const char *s, size_t len);
void lua_pushcclosure(lua_State *L, lua_CFunction fn, int n);
void lua_pushboolean(lua_State *L, int b);
void lua_createtable(lua_State *L, int narr, int nrec);
void lua_setfield(lua_State *L, int idx, const char *k);
int lua_setmetatable(lua_State *L, int objindex);
int lua_rawgeti(lua_State *L, int idx, lua_Integer n);
lua_State *lua_tothread(lua_State *L, int idx);
int lua_pcallk(lua_State *L, int nargs, int nresults, int errfunc, intptr_t ctx, void *k);
int luaL_ref(lua_State *L, int t);
void luaL_unref(lua_State *L, int t, int ref);
