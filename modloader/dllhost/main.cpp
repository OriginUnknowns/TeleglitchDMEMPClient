// TeleglitchDME DLL host — proxies version.dll, loads native mods.
//
// Why version.dll: Teleglitch (and most Win32 games) link version.lib,
// so version.dll loads automatically at startup. Windows DLL search
// order finds OUR copy in the game folder before the system one. We
// then LoadLibrary the real one and forward exports.
//
// On DLL_PROCESS_ATTACH we:
//   1. Load real C:\Windows\System32\version.dll
//   2. Read modloader/enabled_native.txt (one mod folder name per line)
//   3. For each, LoadLibrary("mods/<name>/mod.dll")
//   4. Call optional ModInit(const ModloaderApi*) on each
//
// Each mod DLL can:
//   - export ModInit(ModloaderApi*) to receive host services
//   - hook arbitrary Teleglitch.exe / lua52.dll functions via MinHook
//   - register Lua bindings by waiting for lua_State (mods register a
//     "luastate ready" callback)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "lua52_min.h"

// ---------------------------------------------------------------------------
// Modloader host API exposed to native mods. Versioned so we can extend.
// ---------------------------------------------------------------------------
struct ModloaderApi {
    int version;                                  // bump on breaking changes
    void (*log)(const char* fmt, ...);            // writes to modloader/dllhost.log
    void* (*get_proc)(const char* module, const char* sym);  // GetProcAddress helper
    // Future: register_luastate_callback, etc.
};

typedef void (__cdecl *ModInitFn)(const ModloaderApi*);

// ---------------------------------------------------------------------------
// Real version.dll forwarders (export-redirect via .def file).
// We don't reimplement them — the linker forwards each to the real DLL.
// ---------------------------------------------------------------------------

static HMODULE g_realVersion = nullptr;
static FILE* g_log = nullptr;

static void host_log(const char* fmt, ...) {
    if (!g_log) g_log = fopen("modloader/dllhost.log", "a");
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    fputc('\n', g_log);
    fflush(g_log);
    va_end(ap);
}

static void* host_get_proc(const char* module, const char* sym) {
    HMODULE m = GetModuleHandleA(module);
    if (!m) m = LoadLibraryA(module);
    if (!m) return nullptr;
    return (void*)GetProcAddress(m, sym);
}

static ModloaderApi g_api = {
    1,                  // version
    host_log,
    host_get_proc,
};

// ---------------------------------------------------------------------------
// Mod loading
// ---------------------------------------------------------------------------

static void load_native_mods() {
    FILE* f = fopen("modloader/enabled_native.txt", "r");
    if (!f) {
        host_log("dllhost: no enabled_native.txt — no native mods to load");
        return;
    }
    char line[260];
    while (fgets(line, sizeof(line), f)) {
        // Trim leading whitespace + newline
        char* s = line;
        while (*s == ' ' || *s == '\t') s++;
        size_t n = strlen(s);
        while (n && (s[n-1] == '\n' || s[n-1] == '\r' || s[n-1] == ' ' || s[n-1] == '\t')) s[--n] = 0;
        if (n == 0 || s[0] == '#') continue;

        char path[MAX_PATH];
        snprintf(path, sizeof(path), "mods\\%s\\mod.dll", s);
        HMODULE mod = LoadLibraryA(path);
        if (!mod) {
            host_log("dllhost: FAILED to load %s (err %lu)", path, GetLastError());
            continue;
        }
        host_log("dllhost: loaded %s", path);
        ModInitFn init = (ModInitFn)GetProcAddress(mod, "ModInit");
        if (init) {
            init(&g_api);
            host_log("dllhost: ModInit returned for %s", s);
        }
    }
    fclose(f);
}

// ---------------------------------------------------------------------------
// DLL entry. Forwards happen via the .def file's EXPORTS section; here we
// only handle process-attach init.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Lua module entry point — exported as luaopen_mp_native so mp_client.lua
// can do:   local mp = package.loadlib("version.dll", "luaopen_mp_native")()
// This is the OFFICIAL Lua C-extension hook; we get lua_State for free.
// ---------------------------------------------------------------------------

static LuaApi api;
static lua_State* g_L = nullptr;

static int l_hello(lua_State* L) {
    api.pushstring(L, "hello from native (modloader dllhost)");
    return 1;
}

static int l_log(lua_State* L) {
    size_t n = 0;
    const char* msg = api.tolstring(L, 1, &n);
    host_log("lua: %s", msg ? msg : "(nil)");
    return 0;
}

extern "C" __declspec(dllexport) int luaopen_mp_native(lua_State* L) {
    if (!lua_resolve_api(&api)) {
        // Best-effort: push nil so caller doesn't get garbage
        return 0;
    }
    g_L = L;
    host_log("luaopen_mp_native: L=%p, api resolved", (void*)L);

    // Build a table: { hello = fn, log = fn }
    api.createtable(L, 0, 4);
    api.pushcclosure(L, l_hello, 0);
    api.setfield(L, -2, "hello");
    api.pushcclosure(L, l_log, 0);
    api.setfield(L, -2, "log");
    return 1;  // return the table
}

BOOL APIENTRY DllMain(HMODULE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        // Load the real version.dll so our forwarded exports work.
        char sysdir[MAX_PATH];
        GetSystemDirectoryA(sysdir, MAX_PATH);
        char real[MAX_PATH];
        snprintf(real, sizeof(real), "%s\\version.dll", sysdir);
        g_realVersion = LoadLibraryA(real);
        host_log("dllhost: process attach, real version.dll = %p", (void*)g_realVersion);

        load_native_mods();
    }
    return TRUE;
}
