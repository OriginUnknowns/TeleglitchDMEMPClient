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

// TBullet ctor @ 0x497040 — called by EVERY bullet in the engine.
// Verified via Ghidra + live crash analysis: __thiscall, `this` in ECX plus
// 8 stack args, RET 0x20 (callee purges the 32 bytes of stack args; ECX is
// not purged). `this` is the freshly new'd TBullet; the 8 stack args are
// posx, posy, velx, vely, damage, type, force, ? (args 1-4 are raw float
// bits). We model thiscall as __fastcall(self=ecx, edx_dummy, a1..a8): this
// keeps ECX(this) intact AND declares all 8 stack args so the hook cleans
// the full 32 bytes (RET 0x20) — matching the original exactly.
//
// History: the very first hook used __fastcall with only 4 stack args, so it
// cleaned 16 instead of 32 — leaking 16 bytes/bullet (the random-crash bug).
// A subsequent __stdcall attempt dropped ECX entirely, so the ctor wrote its
// vtable to a garbage `this` and crashed instantly. This form fixes both.
typedef void* (__fastcall *BulletCtorFn)(void* self, void* edx,
                                         int a1, int a2, int a3, int a4,
                                         int a5, int a6, int a7, int a8);
static BulletCtorFn orig_BulletCtor = nullptr;
static int g_bullet_count = 0;

// Bullet ring buffer for Lua to drain: pos/vel + the engine's real per-shot
// damage (ctor a5), force (a7) and bullet type (a6). This is the authoritative
// per-weapon damage — no Lua-side GetEquippedItem guesswork.
#define BULLET_RING_SIZE 128
struct BulletEvt { float x, y, vx, vy, dmg, force; int type; };
static BulletEvt g_bullet_ring[BULLET_RING_SIZE] = {0};
static volatile int g_bullet_write_idx = 0;
static int g_bullet_read_idx = 0;
// When false, the hook still passes the bullet through to the engine but does
// NOT record it for Lua to drain. Lua mutes capture around its own
// CreateBullet calls (replicated/cosmetic bullets) so they aren't re-broadcast
// — without this, every spawned bullet would feed back into the drain and
// amplify infinitely.
static volatile bool g_bullet_capture = true;

static void* __fastcall hook_BulletCtor(void* self, void* edx,
                                        int a1, int a2, int a3, int a4,
                                        int a5, int a6, int a7, int a8) {
    g_bullet_count++;
    if (!g_bullet_capture) {
        return orig_BulletCtor(self, edx, a1, a2, a3, a4, a5, a6, a7, a8);
    }
    // a1-a4 = pos/vel float bits; a5 = damage (float, -> TBullet+0xB0),
    // a6 = bullet type (int id), a7 = force (float, -> TBullet+0xB8).
    union { int i; float f; } px, py, vx, vy, dmgf, forcef;
    px.i = a1; py.i = a2; vx.i = a3; vy.i = a4; dmgf.i = a5; forcef.i = a7;
    int idx = g_bullet_write_idx % BULLET_RING_SIZE;
    g_bullet_ring[idx].x = px.f;
    g_bullet_ring[idx].y = py.f;
    g_bullet_ring[idx].vx = vx.f;
    g_bullet_ring[idx].vy = vy.f;
    g_bullet_ring[idx].dmg = dmgf.f;
    g_bullet_ring[idx].force = forcef.f;
    g_bullet_ring[idx].type = a6;
    g_bullet_write_idx++;
    if (g_bullet_count <= 16 || (g_bullet_count % 50) == 0) {
        host_log("hook_BulletCtor #%d: pos=(%.2f,%.2f) vel=(%.2f,%.2f) dmg=%.1f type=%d force=%.2f",
                 g_bullet_count, px.f, py.f, vx.f, vy.f, dmgf.f, a6, forcef.f);
    }
    return orig_BulletCtor(self, edx, a1, a2, a3, a4, a5, a6, a7, a8);
}

// Lua-callable: consume one bullet event. Returns nil if none, or 7 numbers
// (x, y, vx, vy, damage, force, type). Caller loops until nil.
typedef void (*LuaPushNumberFn)(lua_State*, double);
static int l_consume_bullet(lua_State* L) {
    if (g_bullet_read_idx >= g_bullet_write_idx) {
        api.pushnil(L);
        return 1;
    }
    BulletEvt e = g_bullet_ring[g_bullet_read_idx % BULLET_RING_SIZE];
    g_bullet_read_idx++;
    static LuaPushNumberFn lua_pushnumber_p = nullptr;
    if (!lua_pushnumber_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_pushnumber_p = (LuaPushNumberFn)GetProcAddress(lm, "lua_pushnumber");
    }
    lua_pushnumber_p(L, e.x);
    lua_pushnumber_p(L, e.y);
    lua_pushnumber_p(L, e.vx);
    lua_pushnumber_p(L, e.vy);
    lua_pushnumber_p(L, e.dmg);
    lua_pushnumber_p(L, e.force);
    lua_pushnumber_p(L, (double)e.type);
    return 7;  // x, y, vx, vy, damage, force, type
}

// Central damage entry: TNewLiving::ApplyHit(attacker, ...). Located via
// RTTI: TEnemy::OnBulletHit (slot 28) calls this; same for TPlayer. So
// this is the shared "process a hit on this entity" function. One hook
// catches all entity damage events from any source.
// Caller (TEnemy::OnBulletHit at 0x4554c0) pushes 5 stack args before
// calling 0x44ee80 with `this` in ecx. So signature is __thiscall with 5
// stack args. Mismatched arg count = stack imbalance on return = crash.
typedef void (__thiscall *HitFn)(void* self, void* a1, int a2, int a3, int a4, int a5);
static HitFn orig_CentralHit = nullptr;
static int g_central_hit_count = 0;

// Forward decls for ring buffer (defined later, shared with hook_common)
#define HIT_RING_SIZE 256
extern DWORD g_hit_targets[HIT_RING_SIZE];
extern volatile int g_hit_write_idx;

static void __fastcall hook_CentralHit(void* self, void* /*edx*/,
                                       void* a1, int a2, int a3, int a4, int a5) {
    g_central_hit_count++;
    g_hit_targets[g_hit_write_idx % HIT_RING_SIZE] = (DWORD)self;
    g_hit_write_idx++;
    if (g_central_hit_count <= 32 || (g_central_hit_count % 25) == 0) {
        host_log("hook_CentralHit #%d: target=%p arg1=%p",
                 g_central_hit_count, self, a1);
    }
    orig_CentralHit(self, a1, a2, a3, a4, a5);
}

static int l_install_central_hit_hook(lua_State* L) {
    HMODULE m = GetModuleHandleA(NULL);
    if (!m) { api.pushboolean(L, 0); return 1; }
    BYTE* target = (BYTE*)m + 0x4ee80;
    MH_STATUS s = MH_CreateHook(target, (LPVOID)&hook_CentralHit, (LPVOID*)&orig_CentralHit);
    host_log("MH_CreateHook(CentralHit @%p): status=%d", target, s);
    if (s != MH_OK) { api.pushboolean(L, 0); return 1; }
    s = MH_EnableHook(target);
    host_log("MH_EnableHook(CentralHit): status=%d", s);
    api.pushboolean(L, s == MH_OK ? 1 : 0);
    return 1;
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

// Ring buffer of recent hit target addresses. Lua polls via consume_hit()
// which returns one address per call, or 0 when empty.
// (HIT_RING_SIZE defined above near hook_CentralHit forward decl.)
DWORD g_hit_targets[HIT_RING_SIZE] = {0};
volatile int g_hit_write_idx = 0;
static int g_hit_read_idx = 0;

static void hook_common(int slot, void* self, float damage, float kind) {
    g_takedmg_count++;
    g_hit_targets[g_hit_write_idx % HIT_RING_SIZE] = (DWORD)self;
    g_hit_write_idx++;
    if (g_takedmg_count <= 32 || (g_takedmg_count % 200) == 0) {
        host_log("hook[slot %d] #%d: target=%p", slot, g_takedmg_count, self);
    }
    g_origs[slot](self, damage, kind);
}

// Lua-callable: returns the integer address backing a userdata. Lua side
// compares this to consume_hit() return values to match hits to puppets.
typedef void* (*LuaToPointerFn)(lua_State*, int);
static int l_addr_of(lua_State* L) {
    static LuaToPointerFn lua_topointer_p = nullptr;
    if (!lua_topointer_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_topointer_p = (LuaToPointerFn)GetProcAddress(lm, "lua_topointer");
    }
    void* p = lua_topointer_p ? lua_topointer_p(L, 1) : nullptr;
    api.pushinteger(L, (int)(DWORD)p);
    return 1;
}

// Lua-callable: returns one target address per call, or 0 if no more hits.
// Lua side maps the address to its known mob puppets to detect a real hit.
static int l_consume_hit(lua_State* L) {
    if (g_hit_read_idx >= g_hit_write_idx) {
        api.pushinteger(L, 0);
        return 1;
    }
    DWORD t = g_hit_targets[g_hit_read_idx % HIT_RING_SIZE];
    g_hit_read_idx++;
    api.pushinteger(L, (int)t);
    return 1;
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

    // ONLY hook slot 24 (+0x60) — SetHealth-flag=1 path. vtable[+0x4c]
    // turned out to be the per-frame Update method (fires 100x/sec per
    // entity), not a bullet-hit handler. Need to find a different hook
    // target for bullet hits.
    int try_offsets[] = { 0x60 };
    int installed = 0;
    for (int oi = 0; oi < (int)(sizeof(try_offsets)/sizeof(try_offsets[0])); oi++) {
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

// Lua-callable: kill_actor(ptr) — force an actor to die through the engine so
// it leaves a real corpse (death sprite + blood + gibs + deathsound). The
// joiner's mob puppets are Create{}-handles that DON'T expose :SetHealth, so
// Lua can't kill them; we poke the C++ object directly instead.
//
// From the decompiled TActor::TakeDamage (0x44e3e0): health is a float at
// object+0xBC and armor at +0xC0. Writing health negative makes the actor's
// next native Update run its death path. We validate the vtable is in module
// range first so a stale/freed pointer can never make us scribble on garbage.
static int l_kill_actor(lua_State* L) {
    typedef void* (*LuaToPointerFn)(lua_State*, int);
    static LuaToPointerFn lua_topointer_p = nullptr;
    if (!lua_topointer_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_topointer_p = (LuaToPointerFn)GetProcAddress(lm, "lua_topointer");
    }
    void* udblock = lua_topointer_p ? lua_topointer_p(L, 1) : nullptr;
    if (!udblock) { api.pushboolean(L, 0); return 1; }

    HMODULE me = GetModuleHandleA(NULL);
    DWORD mod_base = (DWORD)me;
    #define KA_IN_RANGE(p) (((DWORD)(p) - mod_base) < 0x200000)

    // .pointer is light userdata -> udblock IS the entity. Fall back to one
    // dereference (full userdata) if the light path's vtable looks bogus.
    void* entity = nullptr;
    {
        void** v = *(void***)udblock;
        if (KA_IN_RANGE(v)) entity = udblock;
    }
    if (!entity) {
        void* full = *(void**)udblock;
        if (full) {
            void** v = *(void***)full;
            if (KA_IN_RANGE(v)) entity = full;
        }
    }
    if (!entity) {
        host_log("kill_actor: no in-range vtable, refusing (udblock=%p)", udblock);
        api.pushboolean(L, 0);
        return 1;
    }

    *(float*)((char*)entity + 0xBC) = -9999.0f;  // health
    *(float*)((char*)entity + 0xC0) = 0.0f;      // armor
    host_log("kill_actor: poked entity=%p health=-9999 (corpse pending)", entity);
    api.pushboolean(L, 1);
    return 1;
}

// Lua-callable: set_frame(ptr, frame) — write the actor's animation frame.
// From the decompiled SetFrame binding (0x4bd4c0): the frame is a float at
// actor+0x70. Pure visual field (no engine logic triggered), so unlike
// kill_actor this is safe to poke freely. Used to mirror a remote player's
// pose (hold/shoot/stab/reload) onto their puppet, whose thin Create-handle
// has no :SetFrame. Validates the vtable is in module range before writing.
static int l_set_frame(lua_State* L) {
    typedef void* (*LuaToPointerFn)(lua_State*, int);
    typedef double (*LuaToNumberFn)(lua_State*, int, int*);
    static LuaToPointerFn lua_topointer_p = nullptr;
    static LuaToNumberFn lua_tonumber_p = nullptr;
    if (!lua_topointer_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_topointer_p = (LuaToPointerFn)GetProcAddress(lm, "lua_topointer");
        lua_tonumber_p = (LuaToNumberFn)GetProcAddress(lm, "lua_tonumberx");
    }
    void* udblock = lua_topointer_p ? lua_topointer_p(L, 1) : nullptr;
    if (!udblock) { api.pushboolean(L, 0); return 1; }
    float frame = lua_tonumber_p ? (float)lua_tonumber_p(L, 2, nullptr) : 0.0f;

    HMODULE me = GetModuleHandleA(NULL);
    DWORD mod_base = (DWORD)me;
    #define SF_IN_RANGE(p) (((DWORD)(p) - mod_base) < 0x200000)
    void* entity = nullptr;
    {
        void** v = *(void***)udblock;
        if (SF_IN_RANGE(v)) entity = udblock;
    }
    if (!entity) {
        void* full = *(void**)udblock;
        if (full) { void** v = *(void***)full; if (SF_IN_RANGE(v)) entity = full; }
    }
    if (!entity) { api.pushboolean(L, 0); return 1; }

    *(float*)((char*)entity + 0x70) = frame;
    api.pushboolean(L, 1);
    return 1;
}

// Lua-callable: set_capture(bool) — mute/unmute bullet-hook recording. Lua
// wraps its own CreateBullet calls with set_capture(false)/set_capture(true)
// so replicated/cosmetic bullets aren't re-captured and re-broadcast.
static int l_set_capture(lua_State* L) {
    typedef int (*LuaToBoolFn)(lua_State*, int);
    static LuaToBoolFn lua_toboolean_p = nullptr;
    if (!lua_toboolean_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_toboolean_p = (LuaToBoolFn)GetProcAddress(lm, "lua_toboolean");
    }
    int on = lua_toboolean_p ? lua_toboolean_p(L, 1) : 1;
    g_bullet_capture = (on != 0);
    return 0;
}

// Shared pointer resolver for actor-field accessors. Returns the validated
// C++ entity pointer behind a Lua light/full userdata (its .pointer), or null.
static void* resolve_entity(lua_State* L, int idx) {
    typedef void* (*LuaToPointerFn)(lua_State*, int);
    static LuaToPointerFn lua_topointer_p = nullptr;
    if (!lua_topointer_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_topointer_p = (LuaToPointerFn)GetProcAddress(lm, "lua_topointer");
    }
    void* udblock = lua_topointer_p ? lua_topointer_p(L, idx) : nullptr;
    if (!udblock) return nullptr;
    HMODULE me = GetModuleHandleA(NULL);
    DWORD mod_base = (DWORD)me;
    #define RE_IN_RANGE(p) (((DWORD)(p) - mod_base) < 0x200000)
    { void** v = *(void***)udblock; if (RE_IN_RANGE(v)) return udblock; }
    { void* full = *(void**)udblock; if (full) { void** v = *(void***)full; if (RE_IN_RANGE(v)) return full; } }
    return nullptr;
}

// Lua-callable: get_action(ptr) -> int. Reads the actor's current action id
// (the int the engine's SetAction writes) at actor+0xB4. Used to read the
// LOCAL player's real action for syncing to peers.
static int l_get_action(lua_State* L) {
    void* e = resolve_entity(L, 1);
    if (!e) { api.pushinteger(L, -1); return 1; }
    api.pushinteger(L, *(int*)((char*)e + 0xB4));
    return 1;
}

// Lua-callable: set_action(ptr, id) -> bool. Writes actor+0xB4, exactly what
// the engine's own SetAction (FUN_0044ddc0) does. SAFE (unlike set_frame):
// the action is UPSTREAM of the anim state, so the engine rebuilds a
// consistent animation from it each frame. Drives the remote player's puppet
// to play the real walk/shoot/aim/etc. animation.
static int l_set_action(lua_State* L) {
    typedef ptrdiff_t (*LuaToIntFn)(lua_State*, int, int*);
    static LuaToIntFn lua_tointeger_p = nullptr;
    if (!lua_tointeger_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tointeger_p = (LuaToIntFn)GetProcAddress(lm, "lua_tointegerx");
    }
    void* e = resolve_entity(L, 1);
    if (!e) { api.pushboolean(L, 0); return 1; }
    int id = lua_tointeger_p ? (int)lua_tointeger_p(L, 2, nullptr) : 0;
    *(int*)((char*)e + 0xB4) = id;
    api.pushboolean(L, 1);
    return 1;
}

// The engine's global "main player" pointer (DAT_005747a4, RVA 0x1747a4) —
// what the camera/input/HUD follow. The TPlayer ctor OVERWRITES it, so when we
// CreatePlayer() a remote player it would steal the camera. We save the local
// player's pointer and restore it right after creating each remote TPlayer.
#define MAIN_PLAYER_RVA 0x1747a4

// get_main_player() -> integer address of the current main player.
static int l_get_main_player(lua_State* L) {
    HMODULE me = GetModuleHandleA(NULL);
    void* p = *(void**)((char*)me + MAIN_PLAYER_RVA);
    api.pushinteger(L, (int)(DWORD)p);
    return 1;
}

// set_main_player(ptr) — restore the main player global to a saved pointer
// (passed as a .pointer light userdata). Resolves the raw entity address and
// writes it to DAT_005747a4.
static int l_set_main_player(lua_State* L) {
    typedef void* (*LuaToPointerFn)(lua_State*, int);
    static LuaToPointerFn lua_topointer_p = nullptr;
    if (!lua_topointer_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_topointer_p = (LuaToPointerFn)GetProcAddress(lm, "lua_topointer");
    }
    void* p = lua_topointer_p ? lua_topointer_p(L, 1) : nullptr;
    if (!p) { api.pushboolean(L, 0); return 1; }
    HMODULE me = GetModuleHandleA(NULL);
    *(void**)((char*)me + MAIN_PLAYER_RVA) = p;
    host_log("set_main_player: restored main=%p", p);
    api.pushboolean(L, 1);
    return 1;
}

// Passive remote players: a remote player is a real TPlayer (so it animates
// with proper weapon-coupled rendering), but the engine runs each player's
// per-frame think on EVERY player. think1 (vtable[10]=FUN_0045cbc0) reads OUR
// input and can fire weapons; think2 (vtable[11]=FUN_0045bff0) recomputes the
// global camera zoom AND contains the RENDER/DRAW block.
//
// The old approach SKIPPED both think fns for non-main players — but that also
// skipped think2's render block, so the remote turned invisible/crashed. The
// fix: WRAP orig and neuter only the coupling, so render/anim run untouched:
//   * input  — swap the shared input device (DAT_00574798) to a zeroed dummy
//     for the duration of the call: every input query reads "nothing pressed".
//   * self-shoot — force the engine's OWN per-instance fire gate (byte
//     this+0xE4) non-zero around think1, so all fire/reload/drop blocks skip.
//   * camera zoom — save/restore the global view-zoom (DAT_00572700/0057588c)
//     around think2 so the remote computes-and-discards its zoom contribution.
// The main-player/camera global DAT_005747a4 is NOT touched by either think
// (only the ctor writes it — handled by save/restore around CreatePlayer in Lua).
//
// Input device ABI (TCombinedInputDevice, vtable @0x558974) resolved statically:
//   +0x00 ret 0xC  out-point getter (out,in0,in1 -> fills 2 floats, returns out)
//   +0x04 ret 0x4  out-point getter (out -> fills 2 floats, returns out)
//   +0x08/0x0c/0x10/0x14/0x1c/0x44 ret 0  (int/bool queries + ack)
// Modeled as __fastcall(ecx=this, edx_dummy, <stack args>) so g++ emits the
// matching ret N — same thiscall-mimic trick as the bullet-ctor hook.
#define INPUT_DEV_RVA  0x174798   // DAT_00574798  shared input/command device ptr
#define VIEW_ZOOM_RVA  0x172700   // DAT_00572700  global view zoom
#define VIEW_ZOOM2_RVA 0x15888c   // DAT_0057588c  zoom compare/target
#define FIRE_GATE_OFF  0xE4       // byte this+0xE4 (local_18[0x39]): !=0 -> no fire
#define HP_OFF         0xBC       // float this+0xBC: actor health
#define INVULN_OFF     0xFC       // byte  this+0xFC: invulnerable flag

static BYTE* g_base = nullptr;
static inline BYTE* mod_base() { if (!g_base) g_base = (BYTE*)GetModuleHandleA(NULL); return g_base; }

// Zeroed dummy input device: a fake object whose [0] is a vtable of no-op stubs.
static void* __fastcall dev_point3(void* ecx, void* edx, float* out, unsigned i0, unsigned i1) {
    (void)ecx; (void)edx; (void)i0; (void)i1; if (out) { out[0] = 0.0f; out[1] = 0.0f; } return out;
}
static void* __fastcall dev_point1(void* ecx, void* edx, float* out) {
    (void)ecx; (void)edx; if (out) { out[0] = 0.0f; out[1] = 0.0f; } return out;
}
static int __fastcall dev_ret0(void* ecx, void* edx) { (void)ecx; (void)edx; return 0; }
static void* g_dummy_vtbl[20];
static void* g_dummy_dev[2];
static bool g_dummy_ready = false;
static void init_dummy_device() {
    if (g_dummy_ready) return;
    for (int i = 0; i < 20; ++i) g_dummy_vtbl[i] = (void*)&dev_ret0;  // ret 0 default
    g_dummy_vtbl[0] = (void*)&dev_point3;   // +0x00 (ret 0xC)
    g_dummy_vtbl[1] = (void*)&dev_point1;   // +0x04 (ret 0x4)
    g_dummy_dev[0] = (void*)g_dummy_vtbl;
    g_dummy_dev[1] = nullptr;
    g_dummy_ready = true;
}

typedef int (__thiscall *PThinkFn)(void* self);
static PThinkFn orig_PThink1 = nullptr;
static PThinkFn orig_PThink2 = nullptr;

static bool is_passive_player(void* self) {
    void* mainp = *(void**)(mod_base() + MAIN_PLAYER_RVA);
    return self != mainp;   // not the local/controlled player -> passive
}

static int __fastcall hook_PThink1(void* self, void* /*edx*/) {
    if (!is_passive_player(self)) return orig_PThink1(self);
    init_dummy_device();
    void** ip = (void**)(mod_base() + INPUT_DEV_RVA);
    unsigned char* gate = (unsigned char*)self + FIRE_GATE_OFF;
    void* saved_in = *ip;
    unsigned char saved_gate = *gate;
    *ip = (void*)g_dummy_dev;   // every input query reads "nothing pressed"
    *gate = 1;                  // engine's own gate: skip fire/reload/drop/shoot
    int r = orig_PThink1(self); // anim state machine + position + aim cache run
    *gate = saved_gate;
    *ip = saved_in;
    return r;
}

static int __fastcall hook_PThink2(void* self, void* /*edx*/) {
    if (!is_passive_player(self)) return orig_PThink2(self);
    init_dummy_device();
    void** ip = (void**)(mod_base() + INPUT_DEV_RVA);
    float* zoom  = (float*)(mod_base() + VIEW_ZOOM_RVA);
    float* zoom2 = (float*)(mod_base() + VIEW_ZOOM2_RVA);
    void* saved_in = *ip;
    float sz = *zoom, sz2 = *zoom2;
    *ip = (void*)g_dummy_dev;
    int r = orig_PThink2(self);  // render/draw block runs (this+0xFD==0); zoom discarded
    *zoom = sz; *zoom2 = sz2;
    *ip = saved_in;
    return r;
}

static int l_install_passive_player_hooks(lua_State* L) {
    g_base = (BYTE*)GetModuleHandleA(NULL);
    init_dummy_device();
    BYTE* t1 = g_base + 0x5cbc0;   // FUN_0045cbc0 (vtable[10] think1)
    BYTE* t2 = g_base + 0x5bff0;   // FUN_0045bff0 (vtable[11] think2/render)
    MH_STATUS s1 = MH_CreateHook(t1, (LPVOID)&hook_PThink1, (LPVOID*)&orig_PThink1);
    if (s1 == MH_OK) s1 = MH_EnableHook(t1);
    MH_STATUS s2 = MH_CreateHook(t2, (LPVOID)&hook_PThink2, (LPVOID*)&orig_PThink2);
    if (s2 == MH_OK) s2 = MH_EnableHook(t2);
    host_log("install_passive_player_hooks: think1=%d think2=%d", s1, s2);
    api.pushboolean(L, (s1 == MH_OK && s2 == MH_OK) ? 1 : 0);
    return 1;
}

// pin_hp(ptr) — write a positive health to actor+0xBC so a passive remote never
// reaches HP<=0 locally (which would run the death branch + gameover HUD over
// OUR screen). Called each snapshot for tplayer remotes.
static int l_pin_hp(lua_State* L) {
    void* e = resolve_entity(L, 1);
    if (!e) { api.pushboolean(L, 0); return 1; }
    *(float*)((char*)e + HP_OFF) = 9999.0f;
    api.pushboolean(L, 1);
    return 1;
}

// set_invulnerable(ptr, bool) — write actor+0xFC (mirrors engine SetInvulnerable
// FUN_0045ede0), gating the damage screen-shake path for passive remotes.
static int l_set_invulnerable(lua_State* L) {
    typedef int (*LuaToBoolFn)(lua_State*, int);
    static LuaToBoolFn lua_toboolean_p = nullptr;
    if (!lua_toboolean_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_toboolean_p = (LuaToBoolFn)GetProcAddress(lm, "lua_toboolean");
    }
    void* e = resolve_entity(L, 1);
    if (!e) { api.pushboolean(L, 0); return 1; }
    int on = lua_toboolean_p ? lua_toboolean_p(L, 2) : 1;
    *(unsigned char*)((char*)e + INVULN_OFF) = on ? 1 : 0;
    api.pushboolean(L, 1);
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

    // Build a table of native functions. Size the hash part for the EXACT field
    // count (18) up front: an under-sized hint (was 0,4) makes lua52 luaH_resize/
    // realloc the table's array repeatedly mid-population, and under full page heap
    // those guard-paged grows turn lua52's trailing TValue write into a hard fault
    // (the recurring heap corruptor — see KNOWN_ISSUES.md). 18 = the field count below.
    api.createtable(L, 0, 18);
    api.pushcclosure(L, l_hello, 0);
    api.setfield(L, -2, "hello");
    api.pushcclosure(L, l_log, 0);
    api.setfield(L, -2, "log");
    api.pushcclosure(L, l_install_hook_bullet, 0);
    api.setfield(L, -2, "install_bullet_hook");
    api.pushcclosure(L, l_install_hook_takedmg, 0);
    api.setfield(L, -2, "install_takedamage_hook");
    api.pushcclosure(L, l_consume_hit, 0);
    api.setfield(L, -2, "consume_hit");
    api.pushcclosure(L, l_addr_of, 0);
    api.setfield(L, -2, "addr_of");
    api.pushcclosure(L, l_install_central_hit_hook, 0);
    api.setfield(L, -2, "install_central_hit_hook");
    api.pushcclosure(L, l_consume_bullet, 0);
    api.setfield(L, -2, "consume_bullet");
    api.pushcclosure(L, l_kill_actor, 0);
    api.setfield(L, -2, "kill_actor");
    api.pushcclosure(L, l_set_frame, 0);
    api.setfield(L, -2, "set_frame");
    api.pushcclosure(L, l_set_capture, 0);
    api.setfield(L, -2, "set_capture");
    api.pushcclosure(L, l_get_action, 0);
    api.setfield(L, -2, "get_action");
    api.pushcclosure(L, l_set_action, 0);
    api.setfield(L, -2, "set_action");
    api.pushcclosure(L, l_get_main_player, 0);
    api.setfield(L, -2, "get_main_player");
    api.pushcclosure(L, l_set_main_player, 0);
    api.setfield(L, -2, "set_main_player");
    api.pushcclosure(L, l_install_passive_player_hooks, 0);
    api.setfield(L, -2, "install_passive_player_hooks");
    api.pushcclosure(L, l_pin_hp, 0);
    api.setfield(L, -2, "pin_hp");
    api.pushcclosure(L, l_set_invulnerable, 0);
    api.setfield(L, -2, "set_invulnerable");
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
