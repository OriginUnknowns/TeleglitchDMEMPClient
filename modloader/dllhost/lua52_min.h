// Minimal Lua 5.2 ABI declarations. We resolve these from lua52.dll at
// runtime via GetProcAddress, so we don't link against lua52 at build time
// (avoiding the need for the .lib import library).
//
// Lua uses __cdecl calling convention on Windows, which matches g++ default
// for free functions, so our function-pointer types just work.

#ifndef LUA52_MIN_H
#define LUA52_MIN_H

#include <windows.h>
#include <stddef.h>

typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State* L);

// Indices
#define LUA_REGISTRYINDEX (-1001000)

// API function pointer table — populated by lua_resolve_api().
struct LuaApi {
    void (*pushcclosure)(lua_State*, lua_CFunction, int);
    void (*pushstring)(lua_State*, const char*);
    void (*pushinteger)(lua_State*, int);
    void (*pushboolean)(lua_State*, int);
    void (*pushnil)(lua_State*);
    int  (*gettop)(lua_State*);
    void (*settop)(lua_State*, int);
    const char* (*tolstring)(lua_State*, int, size_t*);
    void (*setfield)(lua_State*, int, const char*);
    void (*createtable)(lua_State*, int, int);
    void (*setglobal)(lua_State*, const char*);
    void (*getglobal)(lua_State*, const char*);
    // lua_pcallk's full 6-arg signature: nargs, nresults, errfunc, ctx, k.
    // We always call with ctx=0, k=nullptr (equivalent to lua_pcall macro).
    int  (*pcall)(lua_State*, int nargs, int nresults, int errfunc, intptr_t ctx, void* k);
    int  (*next)(lua_State*, int);
};

static inline int lua_resolve_api(struct LuaApi* api) {
    HMODULE m = GetModuleHandleA("lua52.dll");
    if (!m) m = LoadLibraryA("lua52.dll");
    if (!m) return 0;

    #define R(field, sym) api->field = (decltype(api->field))GetProcAddress(m, sym); \
                          if (!api->field) return 0
    R(pushcclosure, "lua_pushcclosure");
    R(pushstring,   "lua_pushstring");
    R(pushinteger,  "lua_pushinteger");
    R(pushboolean,  "lua_pushboolean");
    R(pushnil,      "lua_pushnil");
    R(gettop,       "lua_gettop");
    R(settop,       "lua_settop");
    R(tolstring,    "lua_tolstring");
    R(setfield,     "lua_setfield");
    R(createtable, "lua_createtable");
    R(setglobal,    "lua_setglobal");
    R(next,         "lua_next");
    // These two are used only by the per-frame tick hook. In Lua 5.2,
    // lua_pcall is a MACRO over lua_pcallk; the linker symbol is the
    // 'k' continuation-style function. lua_getglobal is exported as a
    // real function. Missing symbols here must NOT fail the whole load
    // — the rest of the native bridge is still usable without them.
    api->pcall = (decltype(api->pcall))GetProcAddress(m, "lua_pcallk");
    api->getglobal = (decltype(api->getglobal))GetProcAddress(m, "lua_getglobal");
    #undef R
    return 1;
}

#define lua_pushcfunction(L, f) (api.pushcclosure(L, f, 0))
#define lua_pop(L, n)           (api.settop(L, -(n) - 1))

#endif
