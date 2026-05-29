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
#include "include/MinHook.h"
#include <set>

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

// ---------------------------------------------------------------------------
// Hook target addresses (RVA + module base). Resolved at install time so we
// survive ASLR (Teleglitch's image base 0x400000 matches our objdump VAs,
// but be defensive).
// ---------------------------------------------------------------------------
typedef int (*LuaCFunc)(lua_State* L);

// Bullet ctor — called by EVERY bullet in the engine (Lua + C++ alike).
// thiscall convention: this in ecx, other args on the stack.
// Signature inferred from CreateBullet binding @ 0x497040 call site:
//   Bullet::Bullet(this, ?, ?, ?, ?)  // 4 stack args after this
// We don't know the precise types yet; log fact-of-call first, then iterate.
typedef void (__thiscall *BulletCtorFn)(void* self, int a, int b, int c, int d);
static BulletCtorFn orig_BulletCtor = nullptr;
static int g_bullet_count = 0;

// MinHook needs a free-function pointer; we wrap thiscall via fastcall (ecx,edx unused).
// Args reinterpret_cast to floats — Bullet ctor receives 4 floats: (pos.x, pos.y, vel.x, vel.y).
static bool g_bullet_vtable_dumped = false;
static void __fastcall hook_BulletCtor(void* self, void* /*edx*/, int a, int b, int c, int d) {
    g_bullet_count++;
    if (g_bullet_count <= 16 || (g_bullet_count % 50) == 0) {
        union { int i; float f; } px, py, vx, vy;
        px.i = a; py.i = b; vx.i = c; vy.i = d;
        host_log("hook_BulletCtor #%d: this=%p pos=(%.2f,%.2f) vel=(%.2f,%.2f)",
                 g_bullet_count, self, px.f, py.f, vx.f, vy.f);
    }
    orig_BulletCtor(self, a, b, c, d);
}

static int l_install_hook_bullet(lua_State* L) {
    HMODULE m = GetModuleHandleA(NULL);
    if (!m) { api.pushboolean(L, 0); return 1; }
    // Bullet ctor at VA 0x497040 — RVA 0x97040
    BYTE* target = (BYTE*)m + 0x97040;
    MH_STATUS s = MH_CreateHook(target, (LPVOID)&hook_BulletCtor, (LPVOID*)&orig_BulletCtor);
    host_log("MH_CreateHook(BulletCtor @%p): status=%d", target, s);
    if (s != MH_OK) { api.pushboolean(L, 0); return 1; }
    s = MH_EnableHook(target);
    host_log("MH_EnableHook(BulletCtor): status=%d", s);
    api.pushboolean(L, s == MH_OK ? 1 : 0);
    return 1;
}

// ---------------------------------------------------------------------------
// TakeDamage hook (vtable[0x60/4] on Soldat). Catches bullet hits, melee
// hits, environmental damage — anything that decrements HP. The signature
// inferred from SetHealth binding:
//   void __thiscall Soldat::TakeDamage(float damage, float someKind)
// We capture this+damage and forward; later we'll map this->id for Lua.
// ---------------------------------------------------------------------------
typedef void (__thiscall *TakeDamageFn)(void* self, float damage, float kind);
static int g_takedmg_count = 0;
static std::set<void*> g_hooked_addrs;

// Pool of hook function slots — each MinHook installation needs its own
// orig pointer (and own hook function returning the right trampoline).
#define HOOK_POOL_SIZE 8
static TakeDamageFn g_origs[HOOK_POOL_SIZE] = {0};

static void hook_common(int slot, void* self, float damage, float kind) {
    g_takedmg_count++;
    if (g_takedmg_count <= 32 || (g_takedmg_count % 25) == 0) {
        host_log("hook_TakeDamage[slot %d] #%d: target=%p dmg=%.2f kind=%.2f",
                 slot, g_takedmg_count, self, damage, kind);
    }
    g_origs[slot](self, damage, kind);
}

#define HOOK_SLOT(N) \
    static void __fastcall hook_slot##N(void* self, void* /*edx*/, float dmg, float kind) { \
        hook_common(N, self, dmg, kind); \
    }
HOOK_SLOT(0) HOOK_SLOT(1) HOOK_SLOT(2) HOOK_SLOT(3)
HOOK_SLOT(4) HOOK_SLOT(5) HOOK_SLOT(6) HOOK_SLOT(7)

static void* g_hook_slot_fns[HOOK_POOL_SIZE] = {
    (void*)hook_slot0, (void*)hook_slot1, (void*)hook_slot2, (void*)hook_slot3,
    (void*)hook_slot4, (void*)hook_slot5, (void*)hook_slot6, (void*)hook_slot7,
};
static int g_next_hook_slot = 0;

// Takes a userdata pointer (e.g. player.GetPlayer().pointer) and reads its
// vtable. Reads vtable[0x60/4] — the TakeDamage slot — and hooks it.
// Lua signature: install_takedamage_hook(soldat_ptr_as_lightuserdata_or_number)
// We accept it as a number (lua_tointeger) for simplicity — caller does
//   mp_native.install_takedamage_hook(player.GetPlayer().pointer)
// where .pointer is already a number-typed userdata field.
static int l_install_hook_takedmg(lua_State* L) {
    // arg 1 is a lightuserdata or integer holding the C++ object address.
    // Lua's lua_topointer returns void* for any reference-typed value, so
    // we try a couple paths.
    typedef void* (*LuaToPointerFn)(lua_State*, int);
    typedef ptrdiff_t (*LuaToIntegerFn)(lua_State*, int);
    static LuaToPointerFn lua_topointer_p = nullptr;
    static LuaToIntegerFn lua_tointeger_p = nullptr;
    if (!lua_topointer_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_topointer_p = (LuaToPointerFn)GetProcAddress(lm, "lua_topointer");
        lua_tointeger_p = (LuaToIntegerFn)GetProcAddress(lm, "lua_tointegerx");
    }

    // For light userdata, lua_topointer returns the stored void* (== entity).
    // For full userdata, it returns the payload start; engine stores entity
    // pointer at payload[0]. Try light first; if vtable looks bogus, retry
    // with one extra dereference.
    void* udblock = (void*)lua_topointer_p(L, 1);
    if (!udblock) {
        host_log("install_takedamage_hook: nil pointer arg");
        api.pushboolean(L, 0);
        return 1;
    }

    HMODULE me = GetModuleHandleA(NULL);
    DWORD mod_base = (DWORD)me;
    #define IN_RANGE(p) (((DWORD)(p) - mod_base) < 0x200000)

    void* entity_light = udblock;
    void* entity_full  = *(void**)udblock;
    host_log("install_takedamage_hook: udblock=%p, light_entity=%p, full_entity=%p",
             udblock, entity_light, entity_full);

    // Pick whichever yields an in-range vtable.
    void* entity = nullptr;
    void** vtbl  = nullptr;
    if (entity_light) {
        void** v = *(void***)entity_light;
        host_log("  try light: vtbl_candidate=%p in_range=%d", v, IN_RANGE(v));
        if (IN_RANGE(v)) { entity = entity_light; vtbl = v; }
    }
    if (!vtbl && entity_full) {
        void** v = *(void***)entity_full;
        host_log("  try full:  vtbl_candidate=%p in_range=%d", v, IN_RANGE(v));
        if (IN_RANGE(v)) { entity = entity_full; vtbl = v; }
    }
    if (!vtbl) {
        host_log("install_takedamage_hook: no good vtable, REFUSING");
        api.pushboolean(L, 0);
        return 1;
    }

    host_log("  chosen entity=%p vtbl=%p", entity, vtbl);
    // Dump first 28 vtable slots
    for (int i = 0; i < 28; i++) {
        DWORD addr = (DWORD)vtbl[i];
        DWORD off  = addr - mod_base;
        host_log("    vtbl[%d] = 0x%08x (mod_off=0x%x in_range=%d)", i, addr, off, off < 0x200000);
    }

    // Try slot 19 (vtable+0x4c) FIRST — that's what Bullet::Update calls on
    // hit. Slot 24 (+0x60) is the SetHealth-flag=1 path used by Lua scripts
    // (boss self-damage, etc.). Hook both for full coverage.
    int try_offsets[] = { 0x4c, 0x60 };
    int installed = 0;
    for (int oi = 0; oi < 2; oi++) {
        void* target = vtbl[try_offsets[oi] / 4];
        if (!IN_RANGE(target)) {
            host_log("install_takedamage_hook: vtable[+0x%x]=%p out of range, skipping",
                     try_offsets[oi], target);
            continue;
        }
        if (g_hooked_addrs.count(target)) continue;  // dedup silently
        if (g_next_hook_slot >= HOOK_POOL_SIZE) {
            host_log("install_takedamage_hook: hook pool exhausted (%d slots used)", g_next_hook_slot);
            break;
        }
        int slot = g_next_hook_slot++;
        g_hooked_addrs.insert(target);
        host_log("install_takedamage_hook: hooking vtable[+0x%x]=%p in slot %d",
                 try_offsets[oi], target, slot);

        MH_STATUS s = MH_CreateHook(target, g_hook_slot_fns[slot], (LPVOID*)&g_origs[slot]);
        host_log("  MH_CreateHook status=%d", s);
        if (s != MH_OK) continue;
        s = MH_EnableHook(target);
        host_log("  MH_EnableHook status=%d", s);
        if (s == MH_OK) installed++;
    }
    api.pushboolean(L, installed > 0 ? 1 : 0);
    return 1;
}

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

    // Initialize MinHook once; safe to call multiple times.
    MH_Initialize();

    // Build a table: { hello = fn, log = fn, install_bullet_hook = fn }
    api.createtable(L, 0, 4);
    api.pushcclosure(L, l_hello, 0);
    api.setfield(L, -2, "hello");
    api.pushcclosure(L, l_log, 0);
    api.setfield(L, -2, "log");
    api.pushcclosure(L, l_install_hook_bullet, 0);
    api.setfield(L, -2, "install_bullet_hook");
    api.pushcclosure(L, l_install_hook_takedmg, 0);
    api.setfield(L, -2, "install_takedamage_hook");
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
