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
#include <math.h>
#include "lua52_min.h"
#include "include/MinHook.h"
#include "puff/puff.h"   // Mark Adler's raw-DEFLATE reference inflate (zlib license)
#include <set>
#include <stdlib.h>

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
    // Timestamped + PID-tagged. Two instances append to the same file;
    // without these tags we can't tell which one fired a hook, nor when.
    SYSTEMTIME st; GetLocalTime(&st);
    fprintf(g_log, "[%02d:%02d:%02d.%03d %lu] ",
            st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
            (unsigned long)GetCurrentProcessId());
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

// Thread ID of the thread that loaded our module (= the thread that holds
// the lua_State at load time). Captured in luaopen_mp_native. Kept for
// diagnostics; the actual race protection is the depth-counted model below.
static DWORD g_main_tid = 0;

// =====================================================================
// Thread-safe Lua access — DEPTH-COUNTED model (no critical section).
// =====================================================================
// Lua 5.2 is single-threaded. The engine drives all Lua on its main game
// thread; OUR hooks must never touch Lua from any other thread. The
// original crash (lua_rawseti+0xb5 UAF) was caused by us calling Lua
// from NVIDIA's GL worker thread via PeekMessageA.
//
// The fix: ALL our Lua work happens on the main thread, at points where
// the engine has just RETURNED from its own Lua call (so we know Lua is
// idle). We hook the engine's two Lua entry points (lua_resume,
// lua_pcallk) and maintain a per-process nesting counter. When the
// counter goes back to zero, we know we're at the outermost engine→Lua
// call boundary — safe to run MP_FRAME_TICK.
//
// The worker-thread PeekMessageA hook does ESC handling only — no Lua
// access whatsoever, so no race possible.
//
// Why a counter instead of a critical section:
//   - CS deadlocks: worker thread holding CS while main thread tries to
//     enter lua_resume blocks the engine's render path (window freeze).
//   - Hooking lua_resume only is incomplete: the engine ALSO calls
//     lua_pcallk directly for button callbacks etc., bypassing our CS.
//   - With depth counting we don't need cross-thread sync at all — all
//     access stays on one thread.
// =====================================================================

// Frame-tick state (referenced by hook_PeekMessageA further down too).
static volatile bool g_frame_tick_armed = false;
static volatile bool g_in_frame_tick    = false;
static DWORD         g_last_tick_ms     = 0;

// Interp-tick state (separate from MP_FRAME_TICK). Runs at ~30 ms so
// puppet positions can be interpolated between 100 ms snapshots without
// the visual jitter of snap-to-latest. Calls _G.MP_INTERP_TICK; that Lua
// function reads each puppet's snapshot buffer and SetPosition's the
// interpolated value at (now - interp_delay).
static volatile bool g_in_interp_tick    = false;
static DWORD         g_last_interp_ms    = 0;
#define INTERP_TICK_PERIOD_MS 30

// Nesting depth of engine→Lua calls (lua_resume + lua_pcallk). When this
// returns to 0 after a top-level call, Lua is idle and we can safely
// piggy-back MP_FRAME_TICK on the same (main) thread.
static int g_lua_nest_depth = 0;

// Cross-thread mutex for OUR injected Lua entry points (MP_RENDER in the swap
// hook and the MP_FRAME_TICK fallback in the PeekMessageA hook). The frame-tick
// fallback can fire on a non-main thread (NVIDIA's GL driver pumps PeekMessageA
// on a worker thread), so it can otherwise touch g_L at the same instant the
// main-thread swap hook is running MP_RENDER → concurrent lua_State access →
// heap corruption (STATUS_LONGJUMP / lua52 AV). Both sites try-acquire this with
// InterlockedCompareExchange and SKIP (never block) if the other holds it, which
// serializes all our Lua entries without any chance of deadlock.
static volatile LONG g_lua_entry_busy = 0;
static inline bool lua_entry_try_acquire() {
    return InterlockedCompareExchange(&g_lua_entry_busy, 1, 0) == 0;
}
static inline void lua_entry_release() {
    InterlockedExchange(&g_lua_entry_busy, 0);
}

typedef int (*LuaResumeFn)(lua_State* L, lua_State* from, int nargs);
typedef int (*LuaPcallkFn)(lua_State* L, int nargs, int nresults,
                           int errfunc, intptr_t ctx, void* k);
static LuaResumeFn orig_lua_resume = nullptr;
static LuaPcallkFn orig_lua_pcallk = nullptr;

static inline void maybe_run_interp_tick(lua_State* L) {
    if (g_lua_nest_depth != 0) return;
    if (g_in_frame_tick || g_in_interp_tick) return;
    if (g_L != L || !api.pcall || !api.getglobal) return;
    DWORD now = GetTickCount();
    if ((now - g_last_interp_ms) < INTERP_TICK_PERIOD_MS) return;
    g_last_interp_ms = now;
    g_in_interp_tick = true;
    api.getglobal(L, "MP_INTERP_TICK");
    int rc = orig_lua_pcallk
        ? orig_lua_pcallk(L, 0, 0, 0, 0, nullptr)
        : api.pcall(L, 0, 0, 0, 0, nullptr);
    if (rc != 0) {
        const char* err = api.tolstring(L, -1, nullptr);
        // Throttle the error log — interp ticks fire ~33Hz so a Lua bug
        // would spam dllhost.log. Print every 100th error only.
        static int s_err_n = 0;
        if ((s_err_n++ % 100) == 0) {
            host_log("MP_INTERP_TICK error (#%d): %s", s_err_n, err ? err : "?");
        }
        api.settop(L, -2);
    }
    g_in_interp_tick = false;
}

static inline void maybe_run_frame_tick(lua_State* L) {
    if (g_lua_nest_depth != 0) return;                  // still nested — not safe
    if (!g_frame_tick_armed || g_in_frame_tick) return;
    if (g_L != L || !api.pcall || !api.getglobal) return;
    DWORD now = GetTickCount();
    if ((now - g_last_tick_ms) < 250) return;           // throttle
    g_last_tick_ms = now;
    g_in_frame_tick = true;
    api.getglobal(L, "MP_FRAME_TICK");
    // Call the original pcallk directly so we don't recursively bump
    // g_lua_nest_depth via our own hook (the trampoline reaches the
    // real lua_pcallk).
    if (orig_lua_pcallk
        ? orig_lua_pcallk(L, 0, 0, 0, 0, nullptr)
        : api.pcall(L, 0, 0, 0, 0, nullptr)) {
        const char* err = api.tolstring(L, -1, nullptr);
        host_log("MP_FRAME_TICK error: %s", err ? err : "?");
        api.settop(L, -2);
    }
    g_in_frame_tick = false;
}

static int hook_lua_resume(lua_State* L, lua_State* from, int nargs) {
    g_lua_nest_depth++;
    int r = orig_lua_resume(L, from, nargs);
    g_lua_nest_depth--;
    maybe_run_interp_tick(L);
    maybe_run_frame_tick(L);
    return r;
}

static int hook_lua_pcallk(lua_State* L, int nargs, int nresults,
                           int errfunc, intptr_t ctx, void* k) {
    g_lua_nest_depth++;
    int r = orig_lua_pcallk(L, nargs, nresults, errfunc, ctx, k);
    g_lua_nest_depth--;
    maybe_run_interp_tick(L);
    maybe_run_frame_tick(L);
    return r;
}

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
// subclass: 0=TBullet (normal), 1=TNail, 2=TExplodingBullet, 8=TCannonBullet
struct BulletEvt { float x, y, vx, vy, dmg, force; int type; int subclass; };
static BulletEvt g_bullet_ring[BULLET_RING_SIZE] = {0};

// Set by hook_NailCtor / hook_ExplodingBulletCtor right BEFORE they invoke
// the (inherited) TBullet ctor, cleared right after. The TBullet hook reads
// this and tags the ring entry — gives the receiver the subclass id without
// needing a separate ring per ctor. thread_local is overkill for the
// engine's single-threaded shoot path, but cheap insurance.
static thread_local int g_pending_subclass = 0;
static volatile int g_bullet_write_idx = 0;
static int g_bullet_read_idx = 0;
// When false, the hook still passes the bullet through to the engine but does
// NOT record it for Lua to drain. Lua mutes capture around its own
// CreateBullet calls (replicated/cosmetic bullets) so they aren't re-broadcast
// — without this, every spawned bullet would feed back into the drain and
// amplify infinitely.
static volatile bool g_bullet_capture = true;

static void track_entity_birth(void* ptr, unsigned short tag);  // body defined further down (near the damage-tally VEH)

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
    g_bullet_ring[idx].subclass = g_pending_subclass;  // 0 unless wrapped by a subclass-ctor hook
    g_bullet_write_idx++;
    if (g_bullet_count <= 16 || (g_bullet_count % 50) == 0) {
        host_log("hook_BulletCtor #%d: pos=(%.2f,%.2f) vel=(%.2f,%.2f) dmg=%.1f type=%d force=%.2f",
                 g_bullet_count, px.f, py.f, vx.f, vy.f, dmgf.f, a6, forcef.f);
    }
    void* r = orig_BulletCtor(self, edx, a1, a2, a3, a4, a5, a6, a7, a8);
    // Track for the damage-tally crash forensics (tag 1 = TBullet base).
    track_entity_birth(r, 1);
    return r;
}

// Subclass ctor hooks — both TExplodingBullet (0x497140) and TNail (0x497200)
// invoke the TBullet ctor (0x497040) internally. We tag g_pending_subclass
// before the call so hook_BulletCtor stamps the ring entry, and clear it on
// return. Subclass ids match Lua's bullettypes table:
//   1 = nails, 2 = explode (0 = normal).
//
// Stack-arg counts (RET purge confirmed via GetCannonPurge):
//   TNail            (FUN_00497200)  RET 0x24 = 9 stack args
//   TExplodingBullet (FUN_00497140)  RET 0x20 = 8 stack args
// The two had the same typedef historically; nail needs ONE more arg.
// Cannon's boom spawns 20 TNail in a row, so a 4-byte stack drift per
// nail accumulates inside the boom frame and clobbers locals → crash
// later in the boom (looked like a "puppet AV" but was our own bug).
typedef void* (__fastcall *NailCtorFn)(void* self, void* edx,
                                       int a1, int a2, int a3, int a4,
                                       int a5, int a6, int a7, int a8, int a9);
typedef void* (__fastcall *ExplodeCtorFn)(void* self, void* edx,
                                          int a1, int a2, int a3, int a4,
                                          int a5, int a6, int a7, int a8);
static NailCtorFn    orig_NailCtor    = nullptr;
static ExplodeCtorFn orig_ExplodeCtor = nullptr;

static void* __fastcall hook_NailCtor(void* self, void* edx,
                                      int a1, int a2, int a3, int a4,
                                      int a5, int a6, int a7, int a8, int a9) {
    int prev = g_pending_subclass;
    g_pending_subclass = 1;  // bullettypes.nails
    void* r = orig_NailCtor(self, edx, a1, a2, a3, a4, a5, a6, a7, a8, a9);
    g_pending_subclass = prev;
    track_entity_birth(r, 2);  // TNail
    return r;
}

static void* __fastcall hook_ExplodeCtor(void* self, void* edx,
                                         int a1, int a2, int a3, int a4,
                                         int a5, int a6, int a7, int a8) {
    int prev = g_pending_subclass;
    g_pending_subclass = 2;  // bullettypes.explode
    void* r = orig_ExplodeCtor(self, edx, a1, a2, a3, a4, a5, a6, a7, a8);
    g_pending_subclass = prev;
    track_entity_birth(r, 3);  // TExplode
    return r;
}

// FUN_00436aa0 — called from the shoot dispatcher right after every
// ctor (cannon / nail / bullet / grenade / etc.) with (bullet, player,
// stats_obj). Decomp shows it's a stats hit-counter, not a register-
// with-engine call. We hook + log to see whether the post-ctor crash
// happens before, during, or after this call.
typedef void* (__cdecl *PostCtorStatsFn)(unsigned arg1, unsigned arg2, void* stats);
static PostCtorStatsFn orig_PostCtorStats = nullptr;
static int g_pcs_calls = 0;
static void* __cdecl hook_PostCtorStats(unsigned arg1, unsigned arg2, void* stats) {
    ++g_pcs_calls;
    int n = g_pcs_calls;
    host_log("PostCtorStats #%d ENTRY a1=%08x a2=%08x stats=%p", n, arg1, arg2, stats);
    void* r = orig_PostCtorStats(arg1, arg2, stats);
    host_log("PostCtorStats #%d RETURN", n);
    return r;
}

// FUN_0049ee40 — Steam stats counter, called after FUN_00436aa0 in the
// shoot dispatcher. Hook + log to bracket the post-ctor sequence.
typedef void (__fastcall *SteamStatsFn)(void* self, void* edx, void* name);
static SteamStatsFn orig_SteamStats = nullptr;
static int g_ss_calls = 0;
static void __fastcall hook_SteamStats(void* self, void* edx, void* name) {
    ++g_ss_calls;
    int n = g_ss_calls;
    host_log("SteamStats #%d ENTRY self=%p name=%p", n, self, name);
    orig_SteamStats(self, edx, name);
    host_log("SteamStats #%d RETURN", n);
}

// FUN_00498ad0 — TCannonBullet / TBullet / TAdhesiveGrenade vt[11]
// (per-tick movement + collision). Shared across multiple subclasses;
// we filter on cannon vftable so we only log cannons. Logging entry +
// exit lets us tell whether the crash is inside vt[11] (entry but no
// exit) or somewhere else in the engine's per-frame loop (no entry).
static BYTE* g_cannon_vftable_va = nullptr;  // populated at hook install
static bool is_registered_puppet(void* self);  // body lives near the puppet registry, below
typedef void (__fastcall *Vt11Fn)(void* self);
static Vt11Fn orig_Vt11 = nullptr;
static int    g_vt11_cannon_calls = 0;
static void __fastcall hook_Vt11(void* self) {
    bool is_cannon = (self && *(void**)self == (void*)g_cannon_vftable_va);
    if (is_cannon) {
        ++g_vt11_cannon_calls;
        host_log("VT11 cannon ENTRY #%d self=%p pos=(%.3f,%.3f) vel=(%.3f,%.3f) "
                 "alive_byte=%u 6c=%u 6e=%u",
                 g_vt11_cannon_calls, self,
                 *(float*)((char*)self + 0x74), *(float*)((char*)self + 0x78),
                 *(float*)((char*)self + 0x90), *(float*)((char*)self + 0x94),
                 *((unsigned char*)self + 0x2e),
                 *((unsigned char*)self + 0x6c),
                 *((unsigned char*)self + 0x6e));
    }
    orig_Vt11(self);
    if (is_cannon) {
        host_log("VT11 cannon RETURN #%d self=%p (survived)", g_vt11_cannon_calls, self);
    }
}

// FUN_0044f210 — TPlayer::vt[19] / TActor::vt[19]: the per-actor bullet
// dispatch. vt[11] of a flying bullet calls this when its raycast hits
// an actor. Switches on bullet's +0x5c subclass tag: case 8 → vt[28]
// (the cannon/TBullet path), 0x10 → vt[26], 0x20 → vt[27], 0x100 → vt[29]
// (laser). Logging every call here is too noisy globally — we only log
// when the bullet looks like a CANNON (vtable matches TCannonBullet's).
// FUN_0044f210 — actor bullet dispatch. RET 0x1c = 7 stack args, not 5
// (Ghidra decomp under-counted). Wrong arg count = stack imbalance →
// caller (vt[11]) crashes after we return.
//
// PUPPET FILTER: when a cannon shrapnel nail collides with a TPlayer
// puppet on the firer's host, the original dispatch AVs deep inside
// the engine's nail-on-actor path (likely the puppet's render-gated /
// kinematic / hooked-think state confuses the nail's response handler).
// Short-circuit: if the actor is a registered puppet AND the bullet is
// a TNail, return without calling orig. The puppet doesn't take damage
// locally — that's correct: the real damage is replicated to the
// actual remote player on their own client.
typedef void (__fastcall *ActorBulletDispatchFn)(void* self, void* edx,
                                                 int bullet, int p2, int p3, int p4,
                                                 int p5, int p6, int p7);
static ActorBulletDispatchFn orig_ActorBulletDispatch = nullptr;
static BYTE* g_nail_vftable_va = nullptr;  // populated at hook install
static void __fastcall hook_ActorBulletDispatch(void* self, void* edx,
                                                int bullet, int p2, int p3, int p4,
                                                int p5, int p6, int p7) {
    if (is_registered_puppet(self)) {
        // Puppet on the host shouldn't be damaged locally — the real
        // damage is replicated to the remote player via bullet_fire.
        // The vanilla engine path (case 0x20 explosion / case 8 shrapnel
        // nail) AVs on puppets because the puppet's render-gated /
        // kinematic state confuses the engine's response handler. Short-
        // circuit the whole dispatch.
        return;
    }
    orig_ActorBulletDispatch(self, edx, bullet, p2, p3, p4, p5, p6, p7);
}

// FUN_00497770 — cannon impact handler. Spawns 20 TNail shrapnel + a
// TPlahvatus AoE entity. Now runs naturally; the actual crash lives
// downstream in FUN_00417720 (the TPlayer damage-tally iterator) and
// is caught by hook_DamageTally below.
typedef void (__fastcall *CannonBoomFn)(int self);
static CannonBoomFn orig_CannonBoom = nullptr;
static void __fastcall hook_CannonBoom(int self) {
    orig_CannonBoom(self);
}

// FUN_00417720 — TPlayer damage-tally iterator. Walks an internal
// "attackers" list and calls vt[10] on each entry. One or more entries
// is actually a Lua TValue array (cdb-confirmed: entity contents have
// "entity" ASCII + NaN-boxed values where C++ object state should be)
// — the long-running lua52 heap corruptor (task #2) bleeding Lua memory
// into engine entity lists. Reading vt[10] on those poisoned entries
// AVs at the specific instruction `mov eax,[edx+28h]` at engine+0x17894.
//
// Tracking strategy: register a ring of every TPlayer-class ctor we hook
// (TBullet / TNail / TExplode / TCannon / TAdhesive / TPlahvatus etc).
// When the VEH below fires, look up the ECX (= corrupted "entity") in
// the ring — if it matches a known ctor, we know what kind it was and
// when it was created. Combined with the dump of its current contents,
// that pins which entity got freed-then-Lua-repurposed.
//
// Recovery still happens (skip 5 bytes past the bad call) so gameplay
// continues, but every recovery emits a forensics dump we can mine.
#define ENTITY_TRACK_RING 256
struct EntityBirth { void* ptr; DWORD ms; unsigned short tag; unsigned short pad; };
static EntityBirth g_entity_births[ENTITY_TRACK_RING] = {0};
static volatile int g_entity_births_write = 0;
static void track_entity_birth(void* ptr, unsigned short tag) {
    if (!ptr) return;
    int idx = (g_entity_births_write++) % ENTITY_TRACK_RING;
    g_entity_births[idx].ptr = ptr;
    g_entity_births[idx].ms  = GetTickCount();
    g_entity_births[idx].tag = tag;
}
// Tag enum (short id we put in the log so it's compact):
//   1=TBullet  2=TNail  3=TExplode  5=TAdhesive  8=TCannon  20=TPlahvatus
static const char* entity_tag_name(unsigned short t) {
    switch (t) {
        case 1: return "TBullet";
        case 2: return "TNail";
        case 3: return "TExplode";
        case 5: return "TAdhesive";
        case 8: return "TCannon";
        case 20: return "TPlahvatus";
        default: return "?";
    }
}
static const EntityBirth* find_entity_birth(void* ptr) {
    for (int i = 0; i < ENTITY_TRACK_RING; ++i) {
        if (g_entity_births[i].ptr == ptr) return &g_entity_births[i];
    }
    return nullptr;
}

// The damage-tally iteration site comes in many flavors — vt[10] in
// FUN_00417720 (EIP 0x17894), vt[13] in FUN_00419330 (EIP 0x19757), and
// likely others as the engine touches each entity for additional
// accessors. All share the byte pattern `mov eax,[edx+N]; call eax`
// (5 bytes total). Rather than enumerate EIPs, we identify by the
// CORRUPTED ENTITY shape: if the "entity" at ECX has the Lua-table
// fingerprint (the literal string "entity" at +0x14, which is the
// engine's setfield(L, "entity", value) imprint on every Lua handle
// table it builds), skip the 5-byte virtual call. The genuine engine
// path never hits this guard because real C++ entities never have
// "entity"/0x69746e65/0x00007974 at offset +0x14.
static int g_damage_tally_recoveries = 0;
static int g_damage_tally_dumps      = 0;
static bool looks_like_lua_entity_table(void* ecx) {
    if (IsBadReadPtr(ecx, 0x1C)) return false;
    unsigned int* p = (unsigned int*)ecx;
    return p[5] == 0x69746e65u             /* "enti" */
        && (p[6] & 0x0000FFFFu) == 0x00007974u  /* "ty\0" */;
}
// Examine the iterated "entity" for the Lua-handle fingerprint via the
// context registers. Different iterators load the vtable into different
// registers before the virtual call; we need to identify which register
// holds the entity pointer per the instruction encoding.
static LONG WINAPI mp_damage_tally_veh(EXCEPTION_POINTERS* info) {
    if (!info || !info->ExceptionRecord || !info->ContextRecord) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    if (info->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    BYTE* eip = (BYTE*)info->ContextRecord->Eip;
    if (IsBadReadPtr(eip, 5)) return EXCEPTION_CONTINUE_SEARCH;
    // Match `mov <dst>,[<src>+disp8]; call <dst>` for any reg pair.
    // ModR/M with mod=01 → byte = 01 reg r/m (reg=dst, r/m=src).
    // Following `call <dst>` is FF /2 register form → FF (C0|0x10|dst).
    if (eip[0] != 0x8B) return EXCEPTION_CONTINUE_SEARCH;
    BYTE modrm = eip[1];
    if ((modrm & 0xC0) != 0x40) return EXCEPTION_CONTINUE_SEARCH;  // mod != 01 → bail
    BYTE dst = (modrm >> 3) & 0x07;
    BYTE src = modrm & 0x07;
    if (src == 4 /* SIB */ || src == 5 /* ebp special */) return EXCEPTION_CONTINUE_SEARCH;
    if (eip[3] != 0xFF) return EXCEPTION_CONTINUE_SEARCH;
    if ((eip[4] & 0xF8) != 0xD0) return EXCEPTION_CONTINUE_SEARCH;  // call <reg>
    if ((eip[4] & 0x07) != dst)   return EXCEPTION_CONTINUE_SEARCH;  // must call the just-loaded reg
    BYTE disp = eip[2];
    // Pick the source register's value from the CONTEXT — that's the
    // pointer being dereferenced (the corrupted "vtable").
    const CONTEXT* c = info->ContextRecord;
    DWORD vtable = 0;
    switch (src) {
        case 0: vtable = c->Eax; break;
        case 1: vtable = c->Ecx; break;
        case 2: vtable = c->Edx; break;
        case 3: vtable = c->Ebx; break;
        case 6: vtable = c->Esi; break;
        case 7: vtable = c->Edi; break;
    }
    // The "entity" pointer for this iteration step is whatever object
    // PRODUCED that vtable. Caller path varies; ECX is almost always the
    // `this` pointer, but if it isn't shaped right, also try the value
    // at *vtable (sometimes the "vtable" register is actually an entity
    // pointer chain). Fingerprint either one.
    bool match_ecx = looks_like_lua_entity_table((void*)c->Ecx);
    bool match_eax = looks_like_lua_entity_table((void*)c->Eax);
    bool match_edx = looks_like_lua_entity_table((void*)c->Edx);
    if (!match_ecx && !match_eax && !match_edx) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    ++g_damage_tally_recoveries;
    if (g_damage_tally_dumps < 32) {
        ++g_damage_tally_dumps;
        void* entity = match_ecx ? (void*)c->Ecx : (match_eax ? (void*)c->Eax : (void*)c->Edx);
        unsigned int* p = (unsigned int*)entity;
        static const char* regs[] = { "eax","ecx","edx","ebx","esp","ebp","esi","edi" };
        host_log("DamageTally AV recovered #%d EIP=%p (mov %s,[%s+0x%02x]; call %s) "
                 "vtable=%08x entity=%p {%08x %08x %08x %08x %08x %08x %08x %08x}",
                 g_damage_tally_recoveries, eip,
                 regs[dst], regs[src], disp, regs[dst],
                 vtable, entity,
                 p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    }
    // mov+call together = 3+2 = 5 bytes.
    info->ContextRecord->Eip = (DWORD)(eip + 5);
    return EXCEPTION_CONTINUE_EXECUTION;
}

// FUN_0048e9b0 — TPlahvatus (explosion entity) ctor called inside the
// cannon's boom. Wraps body-init (FUN_004ccd50, same one our puppet
// think guard already touches). Bracketing it lets us tell whether it
// completes successfully or AVs mid-init.
typedef void* (__fastcall *PlahvatusCtorFn)(void* self, void* edx,
                                            int p1, int p2, int p3);
static PlahvatusCtorFn orig_PlahvatusCtor = nullptr;
static int g_plah_calls = 0;
static void* __fastcall hook_PlahvatusCtor(void* self, void* edx,
                                           int p1, int p2, int p3) {
    int n = ++g_plah_calls;
    host_log("PLAH #%d ENTRY self=%p p1=%08x p2=%08x p3=%08x", n, self, p1, p2, p3);
    void* r = orig_PlahvatusCtor(self, edx, p1, p2, p3);
    host_log("PLAH #%d RETURN ret=%p", n, r);
    track_entity_birth(r, 20);  // TPlahvatus
    return r;
}

// TCannonBullet ctor (0x497660) — cannon (bullettypes.cannon=8). Like
// AGL, it calls TProjectile (FUN_00498920) as its base — not TBullet —
// so hook_BulletCtor never fires. Capture directly here. Signature: 6
// stack args (x, y, vx, vy, dmg, owner).
// Cannon ctor takes 7 stack args (RET 0x1c confirmed) — Ghidra's decomp
// only showed 6, but the binary pops 28 bytes. Last arg (a7) is unused
// inside the ctor body but the caller pushes it. Mismatch = stack
// imbalance → next dispatcher op crashes (security cookie / EIP).
typedef void* (__fastcall *CannonCtorFn)(void* self, void* edx,
                                         int a1, int a2, int a3, int a4,
                                         int a5, int a6, int a7);
static CannonCtorFn orig_CannonCtor = nullptr;
static void* __fastcall hook_CannonCtor(void* self, void* edx,
                                        int a1, int a2, int a3, int a4,
                                        int a5, int a6, int a7) {
    union { int i; float f; } px, py, vx, vy, dmgf;
    px.i = a1; py.i = a2; vx.i = a3; vy.i = a4; dmgf.i = a5;
    host_log("CANNON ctor ENTRY self=%p args: x=%.3f y=%.3f vx=%.3f vy=%.3f dmg=%.3f owner=%08x a7=%08x",
             self, px.f, py.f, vx.f, vy.f, dmgf.f, (unsigned)a6, (unsigned)a7);
    // MSVC __thiscall ctors return `this` in EAX. Must propagate
    // orig's return value or callers read EAX = garbage from our hook
    // and the next op on the bullet AVs.
    void* ret = orig_CannonCtor(self, edx, a1, a2, a3, a4, a5, a6, a7);
    // Post-ctor field dump — read what the engine actually wrote so we
    // can spot bad init (e.g. velocity blowup, missing vtable). Field
    // offsets per TProjectile/TCannonBullet ctor: vtable=+0x00,
    // type_tag=+0x5c (8), pos=+0x74/+0x78, vel=+0x90/+0x94, dmg=+0xb8,
    // alive_byte=+0x2e, mask_byte=+0x6e.
    void* vt    = *(void**)self;
    int   tag   = *(int*)((char*)self + 0x5c);
    float ppx   = *(float*)((char*)self + 0x74);
    float ppy   = *(float*)((char*)self + 0x78);
    float pvx   = *(float*)((char*)self + 0x90);
    float pvy   = *(float*)((char*)self + 0x94);
    float pdmg  = *(float*)((char*)self + 0xb8);
    unsigned char mask = *((unsigned char*)self + 0x6e);
    unsigned char alive = *((unsigned char*)self + 0x2e);
    host_log("CANNON ctor RETURN self=%p ret=%p vt=%p tag=%d pos=(%.3f,%.3f) vel=(%.3f,%.3f) "
             "dmg=%.3f alive_byte=%u mask_byte=%u",
             self, ret, vt, tag, ppx, ppy, pvx, pvy, pdmg, alive, mask);
    if (g_bullet_capture) {
        int idx = g_bullet_write_idx % BULLET_RING_SIZE;
        g_bullet_ring[idx].x = px.f;
        g_bullet_ring[idx].y = py.f;
        g_bullet_ring[idx].vx = vx.f;
        g_bullet_ring[idx].vy = vy.f;
        g_bullet_ring[idx].dmg = dmgf.f;
        g_bullet_ring[idx].force = 0.0f;
        g_bullet_ring[idx].type = 8;
        g_bullet_ring[idx].subclass = 8;
        g_bullet_write_idx++;
    }
    track_entity_birth(ret, 8);  // TCannon
    return ret;
}

// vt[23] @ 0x495e20 — TAdhesiveGrenade per-tick step: moves the grenade
// AND increments the fuse counter (+0xB8). Engine increments fuse
// unconditionally each tick, so the receiver's mid-flight grenade ticks
// fuse from spawn while the firer's grenade observably fuses only after
// impact (probable engine-side gate we haven't found). To match: gate
// here in our hook — call orig so movement runs, then if velocity is
// still high (still flying), restore the pre-call fuse value so the
// increment is effectively undone. Once the grenade stops (impact),
// fuse ticks normally on both sides.
typedef void (__fastcall *AdhFuseTickFn)(void* self);
static AdhFuseTickFn orig_AdhFuseTick = nullptr;
static void __fastcall hook_AdhFuseTick(void* self) {
    if (!self) { return; }
    float pre_fuse = *(float*)((char*)self + 0xB8);
    orig_AdhFuseTick(self);
    float vx = *(float*)((char*)self + 0x90);
    float vy = *(float*)((char*)self + 0x94);
    if ((vx*vx + vy*vy) > 0.25f) {
        *(float*)((char*)self + 0xB8) = pre_fuse;
    }
}

// TAdhesiveGrenade ctor (0x4958b0) — AGL (bullettypes.explode2=5). Unlike
// TNail/TExplodingBullet, this calls TProjectile (FUN_00498920) as its
// base — NOT the TBullet ctor — so our hook_BulletCtor never fires for
// AGL shots. We capture the args directly here and write a ring entry
// just like hook_BulletCtor would, tagged subclass=5 (explode2). Args
// match the AGL ctor signature: 5 stack args (x, y, vx, vy, owner).
typedef void (__fastcall *AdhgrenadeCtorFn)(void* self, void* edx,
                                            int a1, int a2, int a3, int a4,
                                            int a5);
static AdhgrenadeCtorFn orig_AdhgrenadeCtor = nullptr;
static void __fastcall hook_AdhgrenadeCtor(void* self, void* edx,
                                           int a1, int a2, int a3, int a4,
                                           int a5) {
    orig_AdhgrenadeCtor(self, edx, a1, a2, a3, a4, a5);
    track_entity_birth(self, 5);  // TAdhesiveGrenade
    if (!g_bullet_capture) return;
    union { int i; float f; } px, py, vx, vy;
    px.i = a1; py.i = a2; vx.i = a3; vy.i = a4;
    int idx = g_bullet_write_idx % BULLET_RING_SIZE;
    g_bullet_ring[idx].x = px.f;
    g_bullet_ring[idx].y = py.f;
    g_bullet_ring[idx].vx = vx.f;
    g_bullet_ring[idx].vy = vy.f;
    // Damage is hardcoded inside the ctor (DAT_00558ab8 written to +0xB8);
    // we read it back from the constructed object so the receiver gets the
    // engine's authoritative value rather than a Lua-side guess.
    union { int i; float f; } dmgback;
    dmgback.i = *(int*)((char*)self + 0xB8);
    g_bullet_ring[idx].dmg = dmgback.f;
    g_bullet_ring[idx].force = 0.0f;
    g_bullet_ring[idx].type = 5;          // bullettypes.explode2
    g_bullet_ring[idx].subclass = 5;
    g_bullet_write_idx++;
    host_log("hook_AdhgrenadeCtor: pos=(%.2f,%.2f) vel=(%.2f,%.2f) dmg=%.1f",
             px.f, py.f, vx.f, vy.f, dmgback.f);
}

// =============== TLASER LIFETIME DIAGNOSTIC HOOKS ===============
// Track every vt[22] call (per-tick laser update) and every FUN_0040e750
// (mark-dead) so we can see exactly when our receiver-side laser stops
// ticking — and whether the engine cleans up firer's lasers the same way
// it doesn't clean ours. Tagged with a sequence id so individual lasers
// can be correlated through their full lifetime.
static int g_tlaser_id_counter = 0;
struct TLaserDbg { void* obj; int id; int initial_b8; };
#define TLASER_DBG_MAX 64
static TLaserDbg g_tlaser_dbg[TLASER_DBG_MAX];
static int       g_tlaser_dbg_n = 0;
static int laser_dbg_id_for(void* obj) {
    for (int i = 0; i < g_tlaser_dbg_n; ++i) {
        if (g_tlaser_dbg[i].obj == obj) return g_tlaser_dbg[i].id;
    }
    return -1;
}
static void laser_dbg_register(void* obj, int initial_b8) {
    if (g_tlaser_dbg_n >= TLASER_DBG_MAX) return;
    g_tlaser_dbg[g_tlaser_dbg_n].obj = obj;
    g_tlaser_dbg[g_tlaser_dbg_n].id  = ++g_tlaser_id_counter;
    g_tlaser_dbg[g_tlaser_dbg_n].initial_b8 = initial_b8;
    g_tlaser_dbg_n++;
}
static void laser_dbg_unregister(void* obj) {
    for (int i = 0; i < g_tlaser_dbg_n; ++i) {
        if (g_tlaser_dbg[i].obj == obj) {
            g_tlaser_dbg[i] = g_tlaser_dbg[--g_tlaser_dbg_n];
            return;
        }
    }
}

// FF victim pointer (our local TPlayer), set from Lua via set_ff_watch_player.
// The laser deals damage inside its per-tick raycast (not via ApplyBulletDamage),
// so we detect laser friendly fire by watching OUR hp across the tick.
static void* g_ff_local_player = nullptr;
static void ff_record_laser_hit(void* laser, float hp_before);  // defined after the hit ring

// Hook on TLaser vt[22] (FUN_00498770) — fires every tick the engine
// processes the laser. Log per-tick state so we can see counter
// decrement, dead-flag transitions, and start/end position progression.
typedef void (__fastcall *Vt22Fn)(void* self);
static Vt22Fn orig_TLaserTick = nullptr;
static void __fastcall hook_TLaserTick(void* self, void* /*edx*/) {
    // FF probe: snapshot our hp, run the tick (which does the beam's damage),
    // and if our hp dropped this laser hit us → record (victim=us, attacker=laser).
    float ff_hp_before = g_ff_local_player ? *(float*)((char*)g_ff_local_player + 0xBC) : 0.0f;
    orig_TLaserTick(self);
    if (g_ff_local_player) ff_record_laser_hit(self, ff_hp_before);
    // Per-tick diag, throttled (this fires every frame per laser → log spam).
    static int s_tick = 0;
    if ((s_tick++ % 60) == 0) {
        int b8_after = *(int*)((char*)self + 0xB8);
        unsigned char dead_after = *((unsigned char*)self + 0x2E);
        host_log("TLaser TICK id=%d obj=%p b8=%d dead=%d",
                 laser_dbg_id_for(self), self, b8_after, (int)dead_after);
    }
}

// Hook on FUN_0040e750 — the "mark dead" call. Logs which laser the
// engine has flagged for cleanup and at what counter value.
typedef void (__fastcall *MarkDeadFn)(void* self);
static MarkDeadFn orig_MarkDead = nullptr;
static void __fastcall hook_MarkDead(void* self, void* /*edx*/) {
    int id = laser_dbg_id_for(self);
    int b8 = *(int*)((char*)self + 0xB8);
    void** vt = *(void***)self;
    BYTE* base = (BYTE*)GetModuleHandleA(NULL);
    bool is_laser = vt && ((BYTE*)vt == base + 0x1584bc);
    host_log("MARK_DEAD obj=%p id=%d b8=%d is_laser=%d",
             self, id, b8, (int)is_laser);
    if (is_laser) laser_dbg_unregister(self);
    orig_MarkDead(self);
}

// Body-NULL guard on FUN_004b2e30 — the actor anim/position update that
// dereferences `*(this+0x50)` (Box2D body) and crashes if NULL. Our
// receiver-side TLaser has body=NULL (the ctor doesn't make one for laser),
// so without this guard the world-tick AVs the moment we register the
// laser. The original function does nothing useful when body is NULL —
// bail before the deref.
typedef void (__thiscall *BodyAnimUpdateFn)(void* self, float param_1);
static BodyAnimUpdateFn orig_BodyAnimUpdate = nullptr;
static void __fastcall hook_BodyAnimUpdate(void* self, void* /*edx*/, float param_1) {
    void* body = *(void**)((char*)self + 0x50);
    if (!body) return;
    orig_BodyAnimUpdate(self, param_1);
}

// TLaser ctor (0x497cd0) does NOT call TBullet ctor internally — it goes
// straight to TProjectile base — so the g_pending_subclass tag relay won't
// catch it. Write the ring entry directly. Arg shape (from disasm at
// 0x46ebd3): muzzle_x, muzzle_y, stack_temp_ptr, const_0a, const_0b,
// aim_float, owner, char_flag. Damage isn't a ctor arg — engine writes it
// to obj+0xBC right AFTER the ctor returns, so we read it back then.
// 7 stack args (RET 0x1c verified). Arg map from disasm at 0x46ebd3:
//   a1=muzzle_x, a2=muzzle_y, a3=const0, a4=const0,
//   a5=aim_float, a6=owner, a7=char_flag.
typedef void* (__fastcall *_LaserCtorFn)(void* self, void* edx,
                                         int a1, int a2, int a3, int a4,
                                         int a5, int a6, int a7);
static _LaserCtorFn orig_LaserCtor = nullptr;
static void* __fastcall hook_LaserCtor(void* self, void* edx,
                                       int a1, int a2, int a3, int a4,
                                       int a5, int a6, int a7) {
    union { int i; float f; } xf, yf;
    xf.i = a1; yf.i = a2;
    // Read aim angle from the ACTIVE PLAYER global DAT_005747a4 (= local
    // TPlayer) at +0xB0 — that's the canonical angle field engine writes
    // each think frame. owner via a6 was returning 0.200 consistently
    // (might be a player sub-object, not the player itself, depending on
    // which call site dispatched the ctor).
    float aim_angle = 0.0f;
    // DAT_005747a4 (RVA 0x1747a4) — defined as MAIN_PLAYER_RVA later but
    // we can't forward-use a #define in C++, so spell out the RVA here.
    HMODULE _m = GetModuleHandleA(NULL);
    void* active = _m ? *(void**)((BYTE*)_m + 0x1747a4) : nullptr;
    if (active && !IsBadReadPtr((char*)active + 0xB0, 4)) {
        aim_angle = *(float*)((char*)active + 0xB0);
    }
    void* r = orig_LaserCtor(self, edx, a1, a2, a3, a4, a5, a6, a7);
    // Diag: register for lifetime tracking (firer-side ctor).
    laser_dbg_register(self, *(int*)((char*)self + 0xB8));
    host_log("TLaser CTOR (firer) obj=%p id=%d initial_b8=%d",
             self, laser_dbg_id_for(self), *(int*)((char*)self + 0xB8));
    if (g_bullet_capture) {
        int idx = g_bullet_write_idx % BULLET_RING_SIZE;
        g_bullet_ring[idx].x = xf.f;
        g_bullet_ring[idx].y = yf.f;
        // Encode aim as (cos, sin) so the existing atan2 recovery on the
        // broadcast path round-trips the angle correctly.
        g_bullet_ring[idx].vx = (float)cos((double)aim_angle);
        g_bullet_ring[idx].vy = (float)sin((double)aim_angle);
        g_bullet_ring[idx].dmg = 0.0f;
        g_bullet_ring[idx].force = 0.0f;
        g_bullet_ring[idx].type = a6;      // owner ptr
        g_bullet_ring[idx].subclass = 3;   // bullettypes.laser
        g_bullet_write_idx++;
        host_log("hook_LaserCtor: pos=(%.2f,%.2f) aim=%.3f owner=%p",
                 xf.f, yf.f, aim_angle, (void*)(intptr_t)a6);
    }
    return r;
}

// Receiver-side: after Lua CreateBullet spawns a base TBullet, this swaps the
// object's vtable to the target subclass. vt[20] dispatches the impact-effect
// behavior (nail trail / explode AoE) so the visual + behavioral payload comes
// through. Cannon is intentionally excluded — its ctor bypasses TBullet and
// damage works differently (vt[23] flat 1.0); a vtable-swap alone would mis-
// damage. See KNOWN_ISSUES.md.
#define VT_TBULLET      0x5583ec
#define VT_TNAIL        0x55831c
#define VT_TEXPLODE     0x558384
#define VT_TCANNON      0x558454

// Forward decls — bodies live further down.
static void* resolve_entity(lua_State* L, int idx);
static inline BYTE* mod_base();

// ============================================================================
// Subclass spawn natives — bypass Lua's CreateBullet (always TBullet) to
// produce real TLaser / TCannon / etc. on the receiver. Each does:
//   1. operator_new(SIZE)
//   2. thiscall ctor (RVA + arg shape per subclass, from Ghidra ctor decomps)
//   3. post-ctor field setup the engine does (damage at +0xBC/+0xC0 etc.)
//   4. trigger vt[22] (one-shot "fire" call the engine makes right after)
//   5. FUN_004b3a90 to register with engine + push the {pointer,objtype}
//      table to Lua so the caller gets a normal entity handle.
//
// `operator_new` lives at the IAT slot 0x130398 (the engine calls it via
// `CALL dword ptr [0x00530398]` — RVA 0x130398 holds the import thunk).
// ============================================================================
typedef void* (__cdecl *OperatorNewFn)(size_t);
typedef void (__thiscall *RegisterFromLuaFn)(void* self, lua_State* L);
typedef void (__thiscall *EntityVtFn)(void* self);
// TLaser ctor cleans RET 0x1c → 7 stack args (verified via GetCtorRetPurge).
// __fastcall pattern: ECX=this, EDX=ignored, then 7 args on stack.
typedef void* (__fastcall *TLaserCtorFn)(void* self, void* edx,
                                         int a1, int a2, int a3, int a4,
                                         int a5, int a6, int a7);

static OperatorNewFn     g_op_new       = nullptr;
static RegisterFromLuaFn g_register     = nullptr;
static TLaserCtorFn      g_tlaser_ctor  = nullptr;

static bool init_subclass_spawn() {
    if (g_op_new) return true;
    BYTE* base = mod_base();
    if (!base) return false;
    // operator_new is an import — RVA 0x130398 holds the resolved thunk
    // address (the engine calls `[0x530398]` indirectly throughout).
    void** op_new_slot = (void**)(base + 0x130398);
    if (IsBadReadPtr(op_new_slot, 4)) return false;
    g_op_new      = (OperatorNewFn)(*op_new_slot);
    g_register    = (RegisterFromLuaFn)(base + 0xb3a90);
    g_tlaser_ctor = (TLaserCtorFn)(base + 0x97cd0);
    host_log("init_subclass_spawn: op_new=%p register=%p tlaser=%p",
             g_op_new, g_register, g_tlaser_ctor);
    return g_op_new != nullptr;
}

// create_tlaser(x, y, angle, dmg, owner_ptr) — replicate a TLaser shot the
// firer just made. Reconstructs the engine's lasgun-fire sequence on the
// receiver so we get a real beam visual + raycast damage instead of a
// vanilla TBullet replica.
static int l_create_tlaser(lua_State* L) {
    typedef double (*LuaToNumberFn)(lua_State*, int, int*);
    typedef int    (*LuaToIntegerFn)(lua_State*, int, int*);
    static LuaToNumberFn  lua_tonumber_p  = nullptr;
    static LuaToIntegerFn lua_tointeger_p = nullptr;
    if (!lua_tonumber_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tonumber_p  = (LuaToNumberFn)GetProcAddress(lm, "lua_tonumberx");
        lua_tointeger_p = (LuaToIntegerFn)GetProcAddress(lm, "lua_tointegerx");
    }
    if (!init_subclass_spawn()) { api.pushnil(L); return 1; }

    union { int i; float f; } x, y, ang;
    x.f   = (float)lua_tonumber_p(L, 1, nullptr);
    y.f   = (float)lua_tonumber_p(L, 2, nullptr);
    ang.f = (float)lua_tonumber_p(L, 3, nullptr);
    int dmg = lua_tointeger_p(L, 4, nullptr);
    void* owner = resolve_entity(L, 5);
    if (!owner) {
        host_log("create_tlaser: no owner — bailing");
        api.pushnil(L); return 1;
    }

    void* obj = g_op_new(0xE0);
    if (!obj) { api.pushnil(L); return 1; }

    // Ctor arg shape — 7 stack args (RET 0x1c, verified). Earlier 8-arg
    // count was wrong; one of the PUSHes I counted near the call site was
    // actually for the engine's `vt[0x58/4]` virtual call (the muzzle-pos
    // getter), not for the TLaser ctor.
    //   1: muzzle_x (float)
    //   2: muzzle_y (float)
    //   3: DAT_00573e00 — const 0
    //   4: DAT_00573e04 — const 0
    //   5: aim_float — engine passes player+0x114 (cached aim angle)
    //   6: owner (TPlayer*)
    //   7: char flag — pass 0 (not 1) to enter the ctor's
    //      `if (param_7 == 0) FUN_0040e7c0(+0xC4, 30)` branch. Without
    //      that init, vt[22]'s render gate
    //      (`DAT_00558b04 < FUN_004b00b0(+0xC4)`) never opens and the
    //      beam-render call inside vt[22] never fires → invisible beam.
    g_tlaser_ctor(obj, nullptr,
                  x.i, y.i, 0, 0, ang.i,
                  (int)(intptr_t)owner, 0);

    // Engine post-ctor sequence. Two damage-related field sets:
    //   +0xB0 (float): bullet damage read by FUN_0044dd70, called from
    //                  TActor/TPlayer vt[29] (the dispatch for bullet
    //                  category 0x100 = laser). TPlayer + TActor share
    //                  this vt[29] — both read +0xB0 and call vt[24]
    //                  TakeDamage with it. Without this write, players
    //                  take garbage/0 damage.
    //   +0xBC/+0xC0:   direction vector vt[22]'s raycast reads. Must
    //                  stay as ints the engine writes (writing damage
    //                  here broke the visual entirely — vt[22] reads
    //                  it as a 2-float direction).
    union { int i; float f; } dmgf;
    dmgf.f = (float)dmg;
    *(int*)((char*)obj + 0xB0) = dmgf.i;
    *(int*)((char*)obj + 0xBC) = dmg;
    *(int*)((char*)obj + 0xC0) = dmg;
    *((unsigned char*)obj + 0x6D) = 1;

    // Diag: register for lifetime tracking (receiver-side native spawn).
    host_log("create_tlaser RECEIVER obj=%p id=%d initial_b8=%d",
             obj, laser_dbg_id_for(obj), *(int*)((char*)obj + 0xB8));

    // Call vt[22] once + register. Engine's per-tick keeps calling vt[22]
    // (extends beam, makes it visible). Engine never auto-kills these
    // (+0xC8 decrement-enable stays 0 — same as firer's own lasers, but
    // somehow firer's get cleaned up by a path we haven't identified).
    // Lua side schedules a delayed mark_laser_dead via the returned
    // pointer to clean up after the visual has rendered for a few frames.
    void** vt = *(void***)obj;
    if (vt && !IsBadReadPtr(vt + 22, 4)) {
        EntityVtFn fire = (EntityVtFn)vt[22];
        if (fire) fire(obj);
    }
    g_register(obj, L);
    // g_register pushed a {pointer=,objtype=} table onto the Lua stack.
    // Lua side reads .pointer and schedules the kill.
    return 1;
}

// Read the local fire button (LMB) state — Win32 GetAsyncKeyState on
// VK_LBUTTON. Used by the firer-side laser on/off state machine to
// detect press/release transitions independently of TLaser ctor cadence
// (lasgun's natural fire rate is too slow to make per-shot replication
// look continuous on the receiver).
static int l_lmb_pressed(lua_State* L) {
    SHORT s = GetAsyncKeyState(VK_LBUTTON);
    api.pushboolean(L, (s & 0x8000) ? 1 : 0);
    return 1;
}

// Returns two values: current_down (high bit), transitioned_since_last
// (low bit — set if LMB was pressed at any point between this call and
// the previous one, even if released before the call returned). Used by
// the firer-side laser on/off state machine to detect press+release
// cycles that happen between net-tick polls (otherwise the receiver's
// laser would stick on for the stale-watcher's full timeout).
static int l_lmb_state(lua_State* L) {
    SHORT s = GetAsyncKeyState(VK_LBUTTON);
    api.pushboolean(L, (s & 0x8000) ? 1 : 0);
    api.pushboolean(L, (s & 0x0001) ? 1 : 0);
    return 2;
}

// create_adhgrenade(x, y, vx, vy, owner_ptr) — spawn an AGL grenade on
// the receiver. Mirrors how the engine builds TAdhesiveGrenade: a 0xC0
// object, __thiscall ctor at 0x4958b0 with (x, y, vx, vy, owner), then
// register-from-lua so the engine picks it up like a normal entity.
typedef void (__fastcall *AdhgrenadeCtorCallFn)(void* self, void* edx,
                                                int a1, int a2, int a3, int a4,
                                                int a5);
static int l_create_adhgrenade(lua_State* L) {
    typedef double (*LuaToNumberFn)(lua_State*, int, int*);
    static LuaToNumberFn lua_tonumber_p = nullptr;
    if (!lua_tonumber_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tonumber_p = (LuaToNumberFn)GetProcAddress(lm, "lua_tonumberx");
    }
    if (!init_subclass_spawn()) { api.pushnil(L); return 1; }

    union { int i; float f; } x, y, vx, vy;
    x.f  = (float)lua_tonumber_p(L, 1, nullptr);
    y.f  = (float)lua_tonumber_p(L, 2, nullptr);
    vx.f = (float)lua_tonumber_p(L, 3, nullptr);
    vy.f = (float)lua_tonumber_p(L, 4, nullptr);
    void* owner = resolve_entity(L, 5);
    // Optional arg 6: pre-advance the fuse counter (+0xB8 float) by this
    // amount. vt[23] increments +0xB8 each tick by _DAT_00558a9c and
    // explodes when it reaches DAT_00558bb0 (~1.0). Adding a small
    // fraction here compensates for network latency so the receiver's
    // grenade explodes ~same wall-clock time as the firer's.
    float fuse_advance = (float)lua_tonumber_p(L, 6, nullptr);
    if (!owner) {
        host_log("create_adhgrenade: no owner — bailing");
        api.pushnil(L); return 1;
    }

    void* obj = g_op_new(0xC0);
    if (!obj) { api.pushnil(L); return 1; }

    // Mute the ctor hook for this call — we're SPAWNING for the receiver
    // and don't want to re-broadcast our own replicated grenade.
    bool prev_capture = g_bullet_capture;
    g_bullet_capture = false;
    AdhgrenadeCtorCallFn ctor = (AdhgrenadeCtorCallFn)(mod_base() + 0x958b0);
    ctor(obj, nullptr, x.i, y.i, vx.i, vy.i, (int)(intptr_t)owner);
    g_bullet_capture = prev_capture;

    if (fuse_advance > 0.0f) {
        float* fuse = (float*)((char*)obj + 0xB8);
        *fuse += fuse_advance;
    }

    g_register(obj, L);
    host_log("create_adhgrenade RECEIVER obj=%p pos=(%.2f,%.2f) vel=(%.2f,%.2f) fuse_adv=%.3f",
             obj, x.f, y.f, vx.f, vy.f, fuse_advance);
    return 1;  // FUN_004b3a90 pushes the entity table for us
}

// create_cannon(x, y, vx, vy, dmg, owner_ptr) — spawn a TCannonBullet on
// the receiver. Mirrors how the engine builds one: 0xBC object, ctor at
// 0x497660 with (x, y, vx, vy, dmg, owner), then register-from-lua so
// the engine ticks it like any other entity. On impact, vt[22] →
// FUN_00497770 spawns the shrapnel + explosion automatically.
typedef void (__fastcall *CannonCtorCallFn)(void* self, void* edx,
                                            int a1, int a2, int a3, int a4,
                                            int a5, int a6, int a7);
static int l_create_cannon(lua_State* L) {
    typedef double (*LuaToNumberFn)(lua_State*, int, int*);
    typedef int    (*LuaToIntegerFn)(lua_State*, int, int*);
    static LuaToNumberFn  lua_tonumber_p  = nullptr;
    static LuaToIntegerFn lua_tointeger_p = nullptr;
    if (!lua_tonumber_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tonumber_p  = (LuaToNumberFn)GetProcAddress(lm, "lua_tonumberx");
        lua_tointeger_p = (LuaToIntegerFn)GetProcAddress(lm, "lua_tointegerx");
    }
    if (!init_subclass_spawn()) { api.pushnil(L); return 1; }

    union { int i; float f; } x, y, vx, vy, dmgf;
    x.f  = (float)lua_tonumber_p(L, 1, nullptr);
    y.f  = (float)lua_tonumber_p(L, 2, nullptr);
    vx.f = (float)lua_tonumber_p(L, 3, nullptr);
    vy.f = (float)lua_tonumber_p(L, 4, nullptr);
    dmgf.f = (float)lua_tonumber_p(L, 5, nullptr);
    void* owner = resolve_entity(L, 6);
    if (!owner) {
        host_log("create_cannon: no owner — bailing");
        api.pushnil(L); return 1;
    }

    void* obj = g_op_new(0xBC);
    if (!obj) { api.pushnil(L); return 1; }

    bool prev_capture = g_bullet_capture;
    g_bullet_capture = false;
    CannonCtorCallFn ctor = (CannonCtorCallFn)(mod_base() + 0x97660);
    ctor(obj, nullptr, x.i, y.i, vx.i, vy.i, dmgf.i, (int)(intptr_t)owner, 0);
    g_bullet_capture = prev_capture;

    g_register(obj, L);
    host_log("create_cannon RECEIVER obj=%p pos=(%.2f,%.2f) vel=(%.2f,%.2f) dmg=%.1f",
             obj, x.f, y.f, vx.f, vy.f, dmgf.f);
    return 1;
}

// Refresh an existing TLaser by re-calling its vt[22] — updates the beam
// endpoint from the current owner state without re-allocating. Used by
// the receiver to keep a held laser pointing at the firer's current aim.
static int l_refresh_tlaser(lua_State* L) {
    void* obj = resolve_entity(L, 1);
    if (!obj || IsBadReadPtr(obj, 4)) { api.pushboolean(L, 0); return 1; }
    void** vt = *(void***)obj;
    if (vt && !IsBadReadPtr(vt + 22, 4)) {
        EntityVtFn fire = (EntityVtFn)vt[22];
        if (fire) fire(obj);
    }
    api.pushboolean(L, 1);
    return 1;
}

// Set the laser's "dead" flag (+0x2E) so the engine's cleanup sweep frees
// it. Called from Lua via a delayed coroutine after the visual has had
// time to render. Without this every TLaser persists forever (engine's
// auto-decrement at vt[22] is gated on +0xC8 which is 0 by default).
static int l_mark_laser_dead(lua_State* L) {
    void* e = resolve_entity(L, 1);
    if (!e || IsBadWritePtr((char*)e + 0x2E, 1)) {
        api.pushboolean(L, 0);
        return 1;
    }
    *((unsigned char*)e + 0x2E) = 1;
    api.pushboolean(L, 1);
    return 1;
}

static int l_swap_bullet_subclass(lua_State* L) {
    typedef int (*LuaToIntegerFn)(lua_State*, int, int*);
    static LuaToIntegerFn lua_tointeger_p = nullptr;
    if (!lua_tointeger_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tointeger_p = (LuaToIntegerFn)GetProcAddress(lm, "lua_tointegerx");
    }
    void* e = resolve_entity(L, 1);
    int subclass = lua_tointeger_p ? lua_tointeger_p(L, 2, nullptr) : 0;
    if (!e || IsBadWritePtr(e, 4)) { api.pushboolean(L, 0); return 1; }
    BYTE* base = (BYTE*)mod_base();
    unsigned int new_vt = 0;
    switch (subclass) {
        case 1: new_vt = (unsigned int)(base + VT_TNAIL);    break;
        case 2: new_vt = (unsigned int)(base + VT_TEXPLODE); break;
        default: api.pushboolean(L, 0); return 1;
    }
    *(unsigned int*)e = new_vt;
    api.pushboolean(L, 1);
    return 1;
}

static void* resolve_entity(lua_State* L, int idx);  // fwd decl — body lives below
static bool is_tplayer_ptr(void* e);                 // fwd decl — body below

// Defensive hook on FUN_0042b2d0 — a 2-instruction helper called from a Lua
// script-table dispatcher. It writes to DAT_005747a4+0xFD/+0x30, but if
// main_p is NULL (e.g. during a level reset or transition window) the
// write AVs. Bail when main_p is NULL — engine continues, no NULL deref.
typedef void (*VoidFn0)(void);
static VoidFn0 orig_RenderGateSet = nullptr;
static void hook_RenderGateSet() {
    BYTE* base = (BYTE*)GetModuleHandleA(NULL);
    void* main_p = *(void**)(base + 0x1747a4);
    if (!main_p) {
        host_log("FUN_0042b2d0: main_p=NULL — bailing");
        return;
    }
    orig_RenderGateSet();
}
typedef void (*LuaPushNumberFn)(lua_State*, double);
// ---- Bomb activation hook (TTimeBomb::Activate @ 0x00470aa0) ----
// Captures bomb-activation events (left-click on explosive items) so Lua can
// broadcast them. Fires once per activation; data: item name, position,
// owner angle, fuse frames. Ring-buffered like bullets.
struct BombEvt {
    char type[32];
    float x, y, angle;
    int fuse;
};
static const int BOMB_RING_SIZE = 16;
static BombEvt g_bomb_ring[BOMB_RING_SIZE];
static volatile int g_bomb_write_idx = 0;
static int g_bomb_read_idx = 0;

typedef int (__thiscall *BombActivateFn)(void* self);
static BombActivateFn orig_BombActivate = nullptr;

// Time-window mute — arm_bomb stamps a deadline; the hook bails for any
// fire within ~200 ms after arm. The previous "fixed-count" mute (2 hook
// fires) was buggy: after joiner armed a host bomb, the next 2 hook
// fires were muted — but if the joiner's NEXT real activation happened
// before the engine's echo fired both mutes, the real activation got
// muted instead → joiner's bomb didn't reach host. A short time window
// catches the immediate echo without trapping later real activations.
static DWORD g_bomb_mute_until = 0;
#define BOMB_MUTE_WINDOW_MS 200

// Ultra-safe bomb activation capture. Read ONLY from self (the bomb actor):
// the type name (inline at +0x14) and the delay (+0x100). Skip any pointer-
// chasing (no body deref, no owner deref, no main_p reads). Position +
// angle for the broadcast are captured by the Lua side from the local
// player at the moment of inv decrease — far more reliable than reading
// any cached/uninitialized fields here.
static int __fastcall hook_BombActivate(void* self, void* /*edx*/) {
    DWORD now = GetTickCount();
    if (g_bomb_mute_until && now < g_bomb_mute_until) {
        host_log("hook_BombActivate: MUTED (window %lu ms left)", g_bomb_mute_until - now);
        return orig_BombActivate(self);
    }
    g_bomb_mute_until = 0;
    // PUPPET GUARD: only forward to orig if the activator owner is the main
    // player. Puppet activations (engine case-7/8 mirror on puppet TPlayer
    // via set_action) call orig with a bomb whose owner has no real
    // inventory, which makes orig modify state that doesn't exist → silent
    // heap corruption → surfaces later in lua_close iteration. Without
    // this guard, every multiplayer bomb activation may corrupt Lua state.
    BYTE* base = (BYTE*)GetModuleHandleA(NULL);
    void* main_p = *(void**)(base + 0x1747a4);
    void* inv = *(void**)((char*)self + 0x98);
    void* owner = inv ? *(void**)((char*)inv + 0xc) : nullptr;
    if (!main_p || !owner || owner != main_p) {
        host_log("hook_BombActivate: SKIP — owner=%p main_p=%p (puppet)",
            owner, main_p);
        return 0;
    }
    const char* type_ptr = (const char*)((char*)self + 0x14);
    int delay = *(int*)((char*)self + 0x100);
    int idx = g_bomb_write_idx % BOMB_RING_SIZE;
    strncpy(g_bomb_ring[idx].type, type_ptr, 31);
    g_bomb_ring[idx].type[31] = 0;
    g_bomb_ring[idx].x = 0;     // Lua overrides with main player pos
    g_bomb_ring[idx].y = 0;
    g_bomb_ring[idx].angle = 0; // Lua overrides with main player aim
    g_bomb_ring[idx].fuse = delay;
    g_bomb_write_idx++;
    host_log("hook_BombActivate: type=%s fuse=%d (pos/angle filled by Lua)",
        type_ptr ? type_ptr : "?", delay);
    return orig_BombActivate(self);
}

static int l_consume_bomb(lua_State* L) {
    if (g_bomb_read_idx >= g_bomb_write_idx) { api.pushnil(L); return 1; }
    BombEvt e = g_bomb_ring[g_bomb_read_idx % BOMB_RING_SIZE];
    g_bomb_read_idx++;
    static LuaPushNumberFn lua_pushnumber_p = nullptr;
    if (!lua_pushnumber_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_pushnumber_p = (LuaPushNumberFn)GetProcAddress(lm, "lua_pushnumber");
    }
    api.pushstring(L, e.type);
    lua_pushnumber_p(L, e.x);
    lua_pushnumber_p(L, e.y);
    lua_pushnumber_p(L, e.angle);
    api.pushinteger(L, e.fuse);
    return 5;
}

// validate_vtable(ptr, expected_rva) — returns true if *ptr (the vtable
// pointer slot) equals (g_base + expected_rva). Used by Lua to verify a
// TPlayer puppet's vtable is still intact (i.e. the C++ object hasn't been
// freed/recycled) BEFORE calling any binding like SetPosition. The
// recurring lua52 heap corruption is caused by binding calls on freed
// entities — this check prevents those calls.
static int l_validate_vtable(lua_State* L) {
    typedef int (*LuaToIntegerFn)(lua_State*, int, int*);
    static LuaToIntegerFn lua_tointeger_p = nullptr;
    if (!lua_tointeger_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tointeger_p = (LuaToIntegerFn)GetProcAddress(lm, "lua_tointegerx");
    }
    void* e = resolve_entity(L, 1);
    int rva = lua_tointeger_p ? lua_tointeger_p(L, 2, nullptr) : 0;
    if (!e || rva == 0) { api.pushboolean(L, 0); return 1; }
    if (IsBadReadPtr(e, 4)) { api.pushboolean(L, 0); return 1; }
    DWORD_PTR vtbl = *(DWORD_PTR*)e;
    DWORD_PTR expected = (DWORD_PTR)GetModuleHandleA(NULL) + (DWORD_PTR)(unsigned)rva;
    api.pushboolean(L, (vtbl == expected) ? 1 : 0);
    return 1;
}

// activate_bomb(ptr) — call the engine's REAL bomb activation function on a
// just-CreateItem'd bomb. Unlike arm_bomb (which just pokes +0xfc), this
// runs the full TTimeBomb::Activate path: fuse arm + velocity + any other
// state setup the engine needs. The mute counter prevents our hook from
// echoing this synthetic activation back as a network broadcast.
static int l_activate_bomb(lua_State* L) {
    void* e = resolve_entity(L, 1);
    if (!e) { api.pushboolean(L, 0); return 1; }
    if (!orig_BombActivate) { api.pushboolean(L, 0); return 1; }
    g_bomb_mute_until = GetTickCount() + BOMB_MUTE_WINDOW_MS;
    int r = orig_BombActivate(e);
    host_log("activate_bomb: invoked engine activate, ret=%d", r);
    api.pushboolean(L, 1);
    return 1;
}

// Read a bomb's fuse field (+0xfc). Returns -1 if inert, positive count if armed.
// Used by Lua-side bomb activation detection to distinguish dropped (inert)
// bombs from activated (armed) bombs after an inventory decrease.
static int l_read_fuse(lua_State* L) {
    void* e = resolve_entity(L, 1);
    if (!e) { api.pushinteger(L, -1); return 1; }
    // GATE: +0xfc is the fuse field ONLY for TTimeBomb. On any other
    // TItem subclass, that offset is something else (often the
    // 0x7FFFFFFF sentinel used by inert items) and a naive read produces
    // garbage that callers mistake for "armed bomb". Verify the vtable
    // matches TTimeBomb (RVA 0x157274) before reading.
    if (IsBadReadPtr(e, 4)) { api.pushinteger(L, -1); return 1; }
    DWORD_PTR vt = *(DWORD_PTR*)e;
    DWORD_PTR expected = (DWORD_PTR)GetModuleHandleA(NULL) + 0x157274;
    if (vt != expected) { api.pushinteger(L, -1); return 1; }
    int fuse = *(int*)((char*)e + 0xfc);
    api.pushinteger(L, fuse);
    return 1;
}

// Arm a peer-side bomb that was just CreateItem'd — write fuse, set velocity.
// fuse_frames: e.g. 25 for smtimebomb (delay field).
// vx, vy: linear velocity in world units/tick (compute from angle * throwspeed).
static int l_arm_bomb(lua_State* L) {
    typedef double (*LuaToNumberFn)(lua_State*, int, int*);
    typedef int    (*LuaToIntegerFn)(lua_State*, int, int*);
    static LuaToNumberFn lua_tonumber_p = nullptr;
    static LuaToIntegerFn lua_tointeger_p = nullptr;
    if (!lua_tonumber_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tonumber_p = (LuaToNumberFn)GetProcAddress(lm, "lua_tonumberx");
        lua_tointeger_p = (LuaToIntegerFn)GetProcAddress(lm, "lua_tointegerx");
    }
    void* e = resolve_entity(L, 1);
    if (!e) { api.pushboolean(L, 0); return 1; }
    int fuse = lua_tointeger_p ? lua_tointeger_p(L, 2, nullptr) : 25;
    float vx = lua_tonumber_p ? (float)lua_tonumber_p(L, 3, nullptr) : 0.0f;
    float vy = lua_tonumber_p ? (float)lua_tonumber_p(L, 4, nullptr) : 0.0f;
    // STRICT vtable check: must be a TTimeBomb (vftable RVA 0x157274). If
    // the pointer was recycled into another actor class, writing +0xfc
    // could corrupt that other class's fields → heap corruption surfaces
    // seconds later in ntdll's heap walk.
    if (IsBadReadPtr(e, 4)) { api.pushboolean(L, 0); return 1; }
    DWORD_PTR vt = *(DWORD_PTR*)e;
    DWORD_PTR expected = (DWORD_PTR)GetModuleHandleA(NULL) + 0x157274;
    if (vt != expected) {
        host_log("arm_bomb: REJECT — vt=%p expected TTimeBomb=%p", (void*)vt, (void*)expected);
        api.pushboolean(L, 0); return 1;
    }
    *(int*)((char*)e + 0xfc) = fuse;
    // Start a short time-window mute. Any hook fire within the next
    // BOMB_MUTE_WINDOW_MS is treated as the engine's echo of our arm
    // and gets suppressed. After the window expires, real user
    // activations broadcast normally.
    g_bomb_mute_until = GetTickCount() + BOMB_MUTE_WINDOW_MS;
    // NOTE: NOT writing body velocity. The +0x40 offset for b2Body
    // m_linearVelocity was a guess and likely caused heap corruption
    // (crash inside ntdll's heap check). For now the bomb just sits
    // where created and ticks down — same world position, same explosion
    // moment. Throw velocity replication can come later when we verify
    // the correct b2Body offset (or hook the engine's
    // SetLinearVelocity).
    (void)vx; (void)vy;
    host_log("arm_bomb: fuse=%d (velocity skipped)", fuse);
    api.pushboolean(L, 1);
    return 1;
}

// Lua-callable: consume one bullet event. Returns nil if none, or 7 numbers
// (x, y, vx, vy, damage, force, type). Caller loops until nil.
// LuaPushNumberFn typedef now lives above near the bomb code.
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
    lua_pushnumber_p(L, (double)e.subclass);
    return 8;  // x, y, vx, vy, damage, force, type, subclass
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
extern DWORD g_hit_attackers[HIT_RING_SIZE];   // parallel: attacker (bullet owner) per hit
extern int   g_hit_damage[HIT_RING_SIZE];      // parallel: HP delta (real damage) per hit
extern volatile int g_hit_write_idx;

// Latest captured ApplyHit args from a real engine-side hit. apply_damage
// reuses these as a "shape template" so we replay the engine's own call
// pattern instead of guessing at the signature. Updated every time a real
// bullet/explosion lands on a tracked entity.
static volatile bool g_apply_hit_seen = false;
static void*         g_apply_hit_last_a1 = nullptr;
static int           g_apply_hit_last_a2 = 0;
static int           g_apply_hit_last_a3 = 0;
static int           g_apply_hit_last_a4 = 0;
static int           g_apply_hit_last_a5 = 0;

static void __fastcall hook_CentralHit(void* self, void* /*edx*/,
                                       void* a1, int a2, int a3, int a4, int a5) {
    g_central_hit_count++;
    int ridx = g_hit_write_idx % HIT_RING_SIZE;
    g_hit_targets[ridx]   = (DWORD)self;
    // a1 is the BULLET (ApplyBulletDamage's projectile arg), NOT the shooter.
    // The shooter is the bullet's owner at TBullet+0x70 (TPlayer/TActor ptr). For
    // a replicated peer bullet that owner IS the shooter's puppet, so storing it
    // lets the Lua side match a teammate puppet for friendly-fire attribution.
    g_hit_attackers[ridx] = (a1 && (DWORD)a1 > 0x10000)
                            ? *(DWORD*)((char*)a1 + 0x70) : 0;
    g_hit_write_idx++;
    // Capture the freshest engine-side ApplyHit args so apply_damage can
    // replay the exact call shape.
    g_apply_hit_last_a1 = a1;
    g_apply_hit_last_a2 = a2;
    g_apply_hit_last_a3 = a3;
    g_apply_hit_last_a4 = a4;
    g_apply_hit_last_a5 = a5;
    g_apply_hit_seen    = true;
    // Read HP before+after so we know which arg is damage and what numeric
    // form (raw int vs. float-as-int).
    float hp_before = *(float*)((char*)self + 0xBC);
    union { int i; float f; } f2, f3, f4, f5;
    f2.i = a2; f3.i = a3; f4.i = a4; f5.i = a5;
    orig_CentralHit(self, a1, a2, a3, a4, a5);
    float hp_after  = *(float*)((char*)self + 0xBC);
    g_hit_damage[ridx] = (int)(hp_before - hp_after);   // real damage from this hit
    if (g_central_hit_count <= 64 || (g_central_hit_count % 25) == 0) {
        host_log("hook_CentralHit #%d: target=%p a1=%p a2=0x%08x(int=%d,f=%.3f) "
                 "a3=0x%08x(int=%d,f=%.3f) a4=0x%08x(int=%d,f=%.3f) a5=0x%08x(int=%d,f=%.3f) "
                 "hp %.1f->%.1f",
                 g_central_hit_count, self, a1,
                 a2, a2, f2.f, a3, a3, f3.f, a4, a4, f4.f, a5, a5, f5.f,
                 hp_before, hp_after);
    }
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

// ALSO hook TActor::TakeDamage at RVA 0x4e3e0 (per kill_actor comment, this
// is the function whose decompilation revealed health at +0xBC). Bullets may
// route through this instead of (or in addition to) the ApplyHit at 0x4ee80.
// Same arg-shape captures + ring-buffer slot so we can identify which fires.
typedef void (__thiscall *TakeDamage2Fn)(void* self, void* a1, int a2, int a3, int a4, int a5);
static TakeDamage2Fn orig_TakeDmg2 = nullptr;
static int g_take_dmg2_count = 0;
static volatile bool g_take_dmg2_seen = false;
static void* g_take_dmg2_last_a1 = nullptr;
static int   g_take_dmg2_last_a2 = 0;
static int   g_take_dmg2_last_a3 = 0;
static int   g_take_dmg2_last_a4 = 0;
static int   g_take_dmg2_last_a5 = 0;

static void __fastcall hook_TakeDmg2(void* self, void* /*edx*/,
                                     void* a1, int a2, int a3, int a4, int a5) {
    g_take_dmg2_count++;
    g_take_dmg2_last_a1 = a1; g_take_dmg2_last_a2 = a2;
    g_take_dmg2_last_a3 = a3; g_take_dmg2_last_a4 = a4; g_take_dmg2_last_a5 = a5;
    g_take_dmg2_seen   = true;
    float hp_before = *(float*)((char*)self + 0xBC);
    union { int i; float f; } f2, f3, f4, f5;
    f2.i = a2; f3.i = a3; f4.i = a4; f5.i = a5;
    orig_TakeDmg2(self, a1, a2, a3, a4, a5);
    float hp_after = *(float*)((char*)self + 0xBC);
    if (g_take_dmg2_count <= 64 || (g_take_dmg2_count % 25) == 0) {
        host_log("hook_TakeDmg2 #%d: target=%p a1=%p a2=0x%08x(int=%d,f=%.3f) "
                 "a3=0x%08x(int=%d,f=%.3f) a4=0x%08x(int=%d,f=%.3f) a5=0x%08x(int=%d,f=%.3f) "
                 "hp %.1f->%.1f",
                 g_take_dmg2_count, self, a1,
                 a2, a2, f2.f, a3, a3, f3.f, a4, a4, f4.f, a5, a5, f5.f,
                 hp_before, hp_after);
    }
}

static int l_install_takedmg2_hook(lua_State* L) {
    HMODULE m = GetModuleHandleA(NULL);
    if (!m) { api.pushboolean(L, 0); return 1; }
    BYTE* target = (BYTE*)m + 0x4e3e0;
    MH_STATUS s = MH_CreateHook(target, (LPVOID)&hook_TakeDmg2, (LPVOID*)&orig_TakeDmg2);
    host_log("MH_CreateHook(TakeDmg2 @%p): status=%d", target, s);
    if (s != MH_OK) { api.pushboolean(L, 0); return 1; }
    s = MH_EnableHook(target);
    host_log("MH_EnableHook(TakeDmg2): status=%d", s);
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

    // Subclass ctor hooks — tag g_pending_subclass before invoking orig so
    // the TBullet hook above stamps the ring entry with the right subclass.
    BYTE* nailCtor = (BYTE*)m + 0x97200;
    MH_STATUS ns = MH_CreateHook(nailCtor, (LPVOID)&hook_NailCtor, (LPVOID*)&orig_NailCtor);
    if (ns == MH_OK) ns = MH_EnableHook(nailCtor);
    host_log("nail ctor hook: status=%d", ns);
    BYTE* explCtor = (BYTE*)m + 0x97140;
    MH_STATUS es = MH_CreateHook(explCtor, (LPVOID)&hook_ExplodeCtor, (LPVOID*)&orig_ExplodeCtor);
    if (es == MH_OK) es = MH_EnableHook(explCtor);
    host_log("exploding bullet ctor hook: status=%d", es);
    BYTE* adhCtor = (BYTE*)m + 0x958b0;  // TAdhesiveGrenade ctor (AGL / explode2)
    MH_STATUS as = MH_CreateHook(adhCtor, (LPVOID)&hook_AdhgrenadeCtor, (LPVOID*)&orig_AdhgrenadeCtor);
    if (as == MH_OK) as = MH_EnableHook(adhCtor);
    host_log("adhesive grenade ctor hook: status=%d", as);
    BYTE* adhFuse = (BYTE*)m + 0x95e20;  // TAdhesiveGrenade vt[23] — fuse + movement
    MH_STATUS afs = MH_CreateHook(adhFuse, (LPVOID)&hook_AdhFuseTick, (LPVOID*)&orig_AdhFuseTick);
    if (afs == MH_OK) afs = MH_EnableHook(adhFuse);
    host_log("adhesive grenade fuse hook: status=%d", afs);
    BYTE* cannonCtor = (BYTE*)m + 0x97660;  // TCannonBullet ctor (cannon / type 8)
    MH_STATUS cs = MH_CreateHook(cannonCtor, (LPVOID)&hook_CannonCtor, (LPVOID*)&orig_CannonCtor);
    if (cs == MH_OK) cs = MH_EnableHook(cannonCtor);
    host_log("cannon ctor hook: status=%d", cs);
    BYTE* cannonBoom = (BYTE*)m + 0x97770;  // FUN_00497770 — pass-through
    MH_STATUS cbs = MH_CreateHook(cannonBoom, (LPVOID)&hook_CannonBoom, (LPVOID*)&orig_CannonBoom);
    if (cbs == MH_OK) cbs = MH_EnableHook(cannonBoom);
    host_log("cannon boom hook: status=%d", cbs);
    // VEH targets any AV whose `mov eax,[edx+N]; call eax` pattern is
    // dereferencing a Lua-handle-table-shaped object (detected by the
    // engine's own setfield(L,"entity",...) imprint at +0x14). Catches
    // every accessor in the damage tally chain (vt[10], vt[13], etc.)
    // without enumerating EIPs. Genuine entities never look like that
    // at +0x14 — the guard is unforgeable.
    AddVectoredExceptionHandler(1, mp_damage_tally_veh);
    host_log("damage tally VEH armed (Lua-handle-shape match)");
    BYTE* plahCtor = (BYTE*)m + 0x8e9b0;  // FUN_0048e9b0 — TPlahvatus (explosion) ctor
    MH_STATUS ps = MH_CreateHook(plahCtor, (LPVOID)&hook_PlahvatusCtor, (LPVOID*)&orig_PlahvatusCtor);
    if (ps == MH_OK) ps = MH_EnableHook(plahCtor);
    host_log("plahvatus ctor hook: status=%d", ps);
    // Cache the relocated vftable VAs so the actor bullet dispatch hook
    // can identify subclasses cheaply (file RVAs from ghidra dumps).
    g_cannon_vftable_va = (BYTE*)m + 0x158454;  // TCannonBullet::vftable
    g_nail_vftable_va   = (BYTE*)m + 0x15831c;  // TNail::vftable
    BYTE* actorDispatch = (BYTE*)m + 0x4f210;   // FUN_0044f210 (= shared TPlayer/TActor vt[19])
    MH_STATUS ds = MH_CreateHook(actorDispatch, (LPVOID)&hook_ActorBulletDispatch,
                                 (LPVOID*)&orig_ActorBulletDispatch);
    if (ds == MH_OK) ds = MH_EnableHook(actorDispatch);
    host_log("actor bullet dispatch hook: status=%d cannon_vt=%p", ds, g_cannon_vftable_va);
    BYTE* vt11 = (BYTE*)m + 0x98ad0;  // shared per-tick (TCannonBullet / TBullet / TAdhesiveGrenade)
    MH_STATUS v11s = MH_CreateHook(vt11, (LPVOID)&hook_Vt11, (LPVOID*)&orig_Vt11);
    if (v11s == MH_OK) v11s = MH_EnableHook(vt11);
    host_log("vt[11] hook: status=%d", v11s);
    BYTE* pcs = (BYTE*)m + 0x36aa0;  // FUN_00436aa0 — post-ctor stats
    MH_STATUS pcss = MH_CreateHook(pcs, (LPVOID)&hook_PostCtorStats, (LPVOID*)&orig_PostCtorStats);
    if (pcss == MH_OK) pcss = MH_EnableHook(pcs);
    host_log("post-ctor stats hook: status=%d", pcss);
    BYTE* ss2 = (BYTE*)m + 0x9ee40;  // FUN_0049ee40 — Steam stats counter
    MH_STATUS sss = MH_CreateHook(ss2, (LPVOID)&hook_SteamStats, (LPVOID*)&orig_SteamStats);
    if (sss == MH_OK) sss = MH_EnableHook(ss2);
    host_log("steam stats hook: status=%d", sss);
    BYTE* laserCtor = (BYTE*)m + 0x97cd0;
    MH_STATUS ls = MH_CreateHook(laserCtor, (LPVOID)&hook_LaserCtor, (LPVOID*)&orig_LaserCtor);
    if (ls == MH_OK) ls = MH_EnableHook(laserCtor);
    host_log("laser ctor hook: status=%d", ls);

    // Body-NULL guard for FUN_004b2e30 — see hook_BodyAnimUpdate doc above.
    BYTE* bau = (BYTE*)m + 0xb2e30;
    MH_STATUS bs2 = MH_CreateHook(bau, (LPVOID)&hook_BodyAnimUpdate, (LPVOID*)&orig_BodyAnimUpdate);
    if (bs2 == MH_OK) bs2 = MH_EnableHook(bau);
    host_log("body-anim-update guard: status=%d", bs2);

    // Diagnostic hooks for laser lifetime tracking.
    BYTE* tick = (BYTE*)m + 0x98770;
    MH_STATUS ts = MH_CreateHook(tick, (LPVOID)&hook_TLaserTick, (LPVOID*)&orig_TLaserTick);
    if (ts == MH_OK) ts = MH_EnableHook(tick);
    host_log("tlaser tick diag hook: status=%d", ts);
    BYTE* mdead = (BYTE*)m + 0xe750;
    MH_STATUS mds = MH_CreateHook(mdead, (LPVOID)&hook_MarkDead, (LPVOID*)&orig_MarkDead);
    if (mds == MH_OK) mds = MH_EnableHook(mdead);
    host_log("mark-dead diag hook: status=%d", mds);

    // Bomb activate hook re-enabled with safer reads (see hook body).
    BYTE* bomb = (BYTE*)m + 0x70aa0;
    MH_STATUS bs = MH_CreateHook(bomb, (LPVOID)&hook_BombActivate, (LPVOID*)&orig_BombActivate);
    if (bs == MH_OK) bs = MH_EnableHook(bomb);
    host_log("bomb activate hook: status=%d", bs);

    // Render-gate setter — NULL-deref guard.
    BYTE* rgs = (BYTE*)m + 0x2b2d0;   // FUN_0042b2d0 RVA
    MH_STATUS rs = MH_CreateHook(rgs, (LPVOID)&hook_RenderGateSet, (LPVOID*)&orig_RenderGateSet);
    if (rs == MH_OK) rs = MH_EnableHook(rgs);
    host_log("render-gate hook: status=%d", rs);

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
DWORD g_hit_attackers[HIT_RING_SIZE] = {0};   // parallel: attacker (bullet owner) per hit
int   g_hit_damage[HIT_RING_SIZE] = {0};      // parallel: HP delta (real damage) per hit
volatile int g_hit_write_idx = 0;
static int g_hit_read_idx = 0;

static void hook_common(int slot, void* self, float damage, float kind) {
    g_takedmg_count++;
    int ridx = g_hit_write_idx % HIT_RING_SIZE;
    g_hit_targets[ridx]   = (DWORD)self;
    g_hit_attackers[ridx] = 0;   // vtable path: no attacker info available
    g_hit_write_idx++;
    float hp_before = *(float*)((char*)self + 0xBC);
    g_origs[slot](self, damage, kind);
    float hp_after  = *(float*)((char*)self + 0xBC);
    g_hit_damage[ridx] = (int)(hp_before - hp_after);
    if (g_takedmg_count <= 96 || (g_takedmg_count % 50) == 0) {
        host_log("vtable_takedmg[slot %d] #%d: target=%p damage=%.3f kind=%.3f hp %.1f->%.1f",
                 slot, g_takedmg_count, self, damage, kind, hp_before, hp_after);
    }
}

// Record a laser-FF hit into the same ring consume_hit() drains. attacker is the
// LASER object; the Lua side maps it to the shooter via mp.peer_lasers (it can't
// be matched to a puppet directly the way a bullet's owner can).
static void ff_record_laser_hit(void* laser, float hp_before) {
    if (!g_ff_local_player) return;
    float hp_after = *(float*)((char*)g_ff_local_player + 0xBC);
    if (hp_after >= hp_before) return;   // no damage to us this tick
    int ridx = g_hit_write_idx % HIT_RING_SIZE;
    g_hit_targets[ridx]   = (DWORD)g_ff_local_player;
    g_hit_attackers[ridx] = (DWORD)laser;
    g_hit_damage[ridx]    = (int)(hp_before - hp_after);
    g_hit_write_idx++;
}

// set_ff_watch_player(playerPtr) — tell the native which entity is OUR player,
// so the laser-tick FF probe knows whose hp to watch.
static int l_set_ff_watch_player(lua_State* L) {
    g_ff_local_player = resolve_entity(L, 1);
    return 0;
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
// Returns (victim, attacker, damage) for one hit, or (0,0,0) when empty.
// attacker is the bullet's owner (a teammate puppet for friendly fire); damage
// is the HP delta. Old callers that read a single return value still work.
static int l_consume_hit(lua_State* L) {
    if (g_hit_read_idx >= g_hit_write_idx) {
        api.pushinteger(L, 0);
        api.pushinteger(L, 0);
        api.pushinteger(L, 0);
        return 3;
    }
    int ridx = g_hit_read_idx % HIT_RING_SIZE;
    DWORD t   = g_hit_targets[ridx];
    DWORD atk = g_hit_attackers[ridx];
    int   dmg = g_hit_damage[ridx];
    g_hit_read_idx++;
    api.pushinteger(L, (int)t);
    api.pushinteger(L, (int)atk);
    api.pushinteger(L, dmg);
    return 3;
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

// Lua-callable: apply_damage(ptr, dmg) — decrement an actor's health by `dmg`.
// Same trick as kill_actor (health float at entity+0xBC) but partial: read
// current HP, subtract, write back. Engine's next Update tick handles the
// death path when HP <= 0 (corpse + sfx + score, just like a real bullet).
// Returns (true, new_hp) on success, (false) on failed vtable validation.
// Used by the joiner-authoritative melee path: host receives a mob_damage
// message and applies it directly without needing a Lua-bound SetHealth
// (which not all mob classes expose).
static int l_apply_damage(lua_State* L) {
    typedef void* (*LuaToPointerFn)(lua_State*, int);
    typedef double (*LuaToNumberFn)(lua_State*, int, int*);
    static LuaToPointerFn lua_topointer_p = nullptr;
    static LuaToNumberFn lua_tonumber_p = nullptr;
    static LuaPushNumberFn lua_pushnumber_p = nullptr;
    if (!lua_topointer_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_topointer_p   = (LuaToPointerFn)GetProcAddress(lm, "lua_topointer");
        lua_tonumber_p    = (LuaToNumberFn)GetProcAddress(lm, "lua_tonumberx");
        lua_pushnumber_p  = (LuaPushNumberFn)GetProcAddress(lm, "lua_pushnumber");
    }
    void* udblock = lua_topointer_p ? lua_topointer_p(L, 1) : nullptr;
    if (!udblock) { api.pushboolean(L, 0); return 1; }
    float dmg = lua_tonumber_p ? (float)lua_tonumber_p(L, 2, nullptr) : 0.0f;

    HMODULE me = GetModuleHandleA(NULL);
    DWORD mod_base = (DWORD)me;
    #define AD_IN_RANGE(p) (((DWORD)(p) - mod_base) < 0x200000)

    void* entity = nullptr;
    {
        void** v = *(void***)udblock;
        if (AD_IN_RANGE(v)) entity = udblock;
    }
    if (!entity) {
        void* full = *(void**)udblock;
        if (full) {
            void** v = *(void***)full;
            if (AD_IN_RANGE(v)) entity = full;
        }
    }
    if (!entity) {
        host_log("apply_damage: no in-range vtable, refusing (udblock=%p)", udblock);
        api.pushboolean(L, 0);
        return 1;
    }

    // Safe HP poke at +0xBC. Works for Soldat subclass (kills them) but
    // for mutant/zombie classes the visible HP isn't here — write succeeds,
    // mob keeps walking. Returning post_hp lets Lua observe whether the
    // poke had real effect; the caller (handle_mob_damage) falls back to
    // removing the mob from snapshot tracking when it doesn't.
    // ApplyHit-at-0x4ee80 looked promising but crashed the host with our
    // best-guess signature — reverted until we can capture real arg values
    // from the central_hit hook to replay.
    float* hp_p = (float*)((char*)entity + 0xBC);
    float old_hp = *hp_p;
    float new_hp = old_hp - dmg;
    *hp_p = new_hp;
    host_log("apply_damage: entity=%p hp %.1f -> %.1f (dmg=%.1f)", entity, old_hp, new_hp, dmg);
    api.pushboolean(L, 1);
    lua_pushnumber_p(L, (double)new_hp);
    return 2;
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
    // TPlayer vtable check — set_frame writes +0x70 (frame). On a recycled
    // non-TPlayer object that offset is something else and writing corrupts.
    DWORD_PTR vt2 = *(DWORD_PTR*)entity;
    DWORD_PTR expected_tp = (DWORD_PTR)me + 0x156b14;
    if (vt2 != expected_tp) { api.pushboolean(L, 0); return 1; }

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
    if (!is_tplayer_ptr(e)) { api.pushboolean(L, 0); return 1; }
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
#define DEATH_TIMER_OFF 0xCC      // int   this+0xCC: TPlayer death timer
                                  //   TakeDamage @0x45e900 writes +0xCC=0x32 on
                                  //   HP<=0; vt[14] gameover @0x45c220 fires
                                  //   when HP<=0 && +0xCC==0. Belt-and-braces
                                  //   pin to a sentinel != 0 each frame.
#define DEATH_TIMER_SENTINEL 0x7FFFFFFF

static BYTE* g_base = nullptr;
static inline BYTE* mod_base() { if (!g_base) g_base = (BYTE*)GetModuleHandleA(NULL); return g_base; }

// Per-puppet aim target — set by hook_PThink1 before orig runs, read by the
// dummy input device's mouse-pos getters. Without this the dev_pointN slots
// always returned 0,0 → engine's case-7/8 (shoot/aim) and the stab overlay
// rendered toward (0,0) from the puppet's position → fixed "upper-right"
// aim no matter what angle we pinned via +0xB0. By making the dummy device
// answer "mouse is at (puppet_pos + dir-at-pinned-angle)" we feed the engine
// the same mouse-cursor input the LOCAL player has, so the engine writes
// +0xB0 correctly AND the overlay aims correctly.
static float g_puppet_aim_x = 0.0f;
static float g_puppet_aim_y = 0.0f;
static void* __fastcall dev_point3(void* ecx, void* edx, float* out, unsigned i0, unsigned i1) {
    (void)ecx; (void)edx; (void)i0; (void)i1;
    if (out) { out[0] = g_puppet_aim_x; out[1] = g_puppet_aim_y; }
    return out;
}
static void* __fastcall dev_point1(void* ecx, void* edx, float* out) {
    (void)ecx; (void)edx;
    if (out) { out[0] = g_puppet_aim_x; out[1] = g_puppet_aim_y; }
    return out;
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

// Camera-coupling sub at 0x45b9d0 called from inside think2 on EVERY ticking
// TPlayer. Diagnostic (tplayer_crash_diagnosis.md, 2026-06-01) traced the
// 5-frame puppet crash here: when action!=8 the sub does 24 Box2D raycasts +
// writes "discovered" flag into hit fixture user-data + walks module list +
// writes view zoom global. All of that belongs to the camera-owner — running
// it on a puppet AVs after ~5 frames as cumulative writes hit recycled
// fixtures. Fix: bail the sub at entry when we're inside a puppet's think2.
//
// CRITICAL ABI NOTE: FUN_0045b9d0 is __thiscall (Ghidra shows it as void(void)
// but the decomp reads local_18[0x2d] = +0xB4 action field, meaning ECX = this
// at entry). Hook signature MUST mirror that with __fastcall(this/ecx, edx)
// so g++ emits code that preserves ECX through the hook AND into the orig
// call. The earlier `int(void)` form scribbled ECX (whatever the engine had
// in it at the call site became `this` inside orig) → instant AV inside
// orig's first +0xB4 read. Same trick as the bullet-ctor hook elsewhere
// in this file.
typedef int (__fastcall *ThisFn)(void* self, void* edx);
static ThisFn orig_CameraSub = nullptr;
static thread_local bool g_in_puppet_think2 = false;
static int g_cam_calls = 0;
static int g_cam_skips = 0;
static int __fastcall hook_CameraSub(void* self, void* /*edx*/) {
    // Bail for ANY non-main player, not just during our think2 wrapper.
    // The flag-based gate missed the case where the sub is reached from
    // outside think2 (think1, OnAction, etc.). Reading DAT_005747a4
    // directly catches every call path.
    void* main_p = *(void**)(g_base + MAIN_PLAYER_RVA);
    bool is_passive = (self != main_p);
    if (is_passive) {
        if (++g_cam_skips <= 5) host_log("CameraSub SKIP self=%p main=%p (passive)", self, main_p);
        return 0;
    }
    if (++g_cam_calls <= 5) host_log("CameraSub PASS self=%p (main player)", self);
    // (HP diagnostic removed — proved actor +0xBC is correct; HUD reads
    // from another source we haven't located yet.)
    return orig_CameraSub(self, nullptr);
}

// Puppet registry: explicit allow-list of TPlayer pointers that ARE
// puppets. The earlier "self != main_p" check was unsafe — during
// CreatePlayer (puppet creation), we temporarily swap main_p to the new
// puppet, so for that brief window is_passive_player(local_player)
// returned true → hook_PThink1 fired on the local player and pinned its
// HP to 9999. After we restore main_p the pinning stopped, but the
// permanent 9999 remained, surfacing as "HP 9888/800 (9999 minus
// accumulated damage)" in the HUD.
//
// Lua registers each puppet via register_puppet() right after
// CreatePlayer succeeds; unregister_puppet() on puppet destroy / leave.
#define MAX_PUPPETS 16
static void* g_puppet_registry[MAX_PUPPETS] = {0};

// Local-player guard. Lua calls set_local_player(ptr) at begin_game BEFORE
// any CreatePlayer puppet exists, capturing the LOCAL TPlayer's true pointer.
// is_passive_player and register_puppet refuse to flag this address as a
// puppet — so even if obj.pointer in Lua is a dynamic DAT_005747a4 read that
// briefly resolves to the local, we never mis-pin the local's HP to 9999.
static void* g_local_player = nullptr;

static int l_set_local_player(lua_State* L) {
    void* p = resolve_entity(L, 1);
    g_local_player = p;
    host_log("set_local_player = %p", p);
    api.pushboolean(L, 1);
    return 1;
}

static int l_get_local_player(lua_State* L) {
    typedef void (*LuaPushIntegerFn)(lua_State*, ptrdiff_t);
    static LuaPushIntegerFn lua_pushinteger_p = nullptr;
    if (!lua_pushinteger_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_pushinteger_p = (LuaPushIntegerFn)GetProcAddress(lm, "lua_pushinteger");
    }
    if (lua_pushinteger_p) lua_pushinteger_p(L, (ptrdiff_t)g_local_player);
    else api.pushnil(L);
    return 1;
}

static int l_register_puppet(lua_State* L) {
    void* p = resolve_entity(L, 1);
    if (!p) { api.pushboolean(L, 0); return 1; }
    // Safety: never register the local player as a puppet. obj.pointer in Lua
    // may resolve to DAT_005747a4 live — by register time the swap may have
    // restored DAT_005747a4 to the local, so the value handed in here can be
    // the local's address by accident. Refuse explicitly.
    if (g_local_player && p == g_local_player) {
        host_log("register_puppet REFUSED: ptr=%p matches local player", p);
        api.pushboolean(L, 0);
        return 1;
    }
    for (int i = 0; i < MAX_PUPPETS; ++i) {
        if (g_puppet_registry[i] == p) { api.pushboolean(L, 1); return 1; }
    }
    for (int i = 0; i < MAX_PUPPETS; ++i) {
        if (g_puppet_registry[i] == nullptr) {
            g_puppet_registry[i] = p;
            host_log("register_puppet[%d] = %p", i, p);
            api.pushboolean(L, 1); return 1;
        }
    }
    host_log("register_puppet: registry full (>%d)", MAX_PUPPETS);
    api.pushboolean(L, 0); return 1;
}

static int l_unregister_puppet(lua_State* L) {
    void* p = resolve_entity(L, 1);
    if (!p) { api.pushboolean(L, 0); return 1; }
    for (int i = 0; i < MAX_PUPPETS; ++i) {
        if (g_puppet_registry[i] == p) {
            g_puppet_registry[i] = nullptr;
            host_log("unregister_puppet[%d] = %p", i, p);
            api.pushboolean(L, 1); return 1;
        }
    }
    api.pushboolean(L, 0); return 1;
}

static bool is_registered_puppet(void* self) {
    for (int i = 0; i < MAX_PUPPETS; ++i) {
        if (g_puppet_registry[i] == self) return true;
    }
    return false;
}

static bool is_passive_player(void* self) {
    // Strict allow-list: a TPlayer is "passive" (puppet) only if Lua
    // explicitly registered it. The old "self != main_p" check was
    // unsafe across the main_p-swap window in CreatePlayer; see the
    // registry comment above.
    // Belt-and-suspenders: even if the local somehow got into the registry
    // (Lua handle aliasing), refuse to treat it as a puppet.
    if (g_local_player && self == g_local_player) return false;
    return is_registered_puppet(self);
}

// Per-puppet angle override. The engine's TPlayer think1 case 1 (walk)
// recomputes +0xB0 (angle) from the velocity each frame — with a dummy
// input device the velocity is zero, so the angle gets stuck at 0 and
// our SetAngle from snapshot is overwritten by orig think1 on the very
// next frame. Fix: store the snapshot's angle here per-puppet, then
// re-apply it in hook_PThink1 post-orig.
struct AnglePin {
    void* who;
    float angle; float px; float py;
    int   action;           // -1 = don't pin action
    bool  valid;
};
static AnglePin g_angle_pins[8];

static int l_pin_angle(lua_State* L) {
    typedef double (*LuaToNumberFn)(lua_State*, int, int*);
    static LuaToNumberFn lua_tonumber_p = nullptr;
    if (!lua_tonumber_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tonumber_p = (LuaToNumberFn)GetProcAddress(lm, "lua_tonumberx");
    }
    typedef int (*LuaToIntegerFn)(lua_State*, int, int*);
    static LuaToIntegerFn lua_tointeger_p = nullptr;
    if (!lua_tointeger_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tointeger_p = (LuaToIntegerFn)GetProcAddress(lm, "lua_tointegerx");
    }
    void* who = resolve_entity(L, 1);
    float angle = lua_tonumber_p ? (float)lua_tonumber_p(L, 2, nullptr) : 0.0f;
    // Optional px,py (args 3,4) — puppet's world position, supplied by Lua
    // because the puppet's +0x1B8/+0x1BC cache is populated by aliveUpdate
    // which may not have run yet on a passive puppet. Without an accurate
    // origin the dummy-device aim target ends up near (0,0) and the
    // engine's case-7/8 computation gives angle-toward-origin instead of
    // the pinned angle.
    float px = lua_tonumber_p ? (float)lua_tonumber_p(L, 3, nullptr) : 0.0f;
    float py = lua_tonumber_p ? (float)lua_tonumber_p(L, 4, nullptr) : 0.0f;
    // Optional arg 5 = action to pin between snapshots. Pass -1 (or omit)
    // to leave action unmanaged. Prevents the on/off flicker on remote when
    // a player aims (action 8) or attacks (action 7) — without the pin the
    // engine's think resets +0xB4 to walk/idle within a few frames of each
    // snapshot's set_action.
    int  action = -1;
    if (lua_tointeger_p && api.gettop(L) >= 5) {
        action = lua_tointeger_p(L, 5, nullptr);
    }
    if (!who) { api.pushboolean(L, 0); return 1; }
    for (int i = 0; i < 8; ++i) {
        if (g_angle_pins[i].who == who) {
            g_angle_pins[i].angle = angle;
            g_angle_pins[i].px = px;
            g_angle_pins[i].py = py;
            g_angle_pins[i].action = action;
            g_angle_pins[i].valid = true;
            api.pushboolean(L, 1); return 1;
        }
    }
    for (int i = 0; i < 8; ++i) {
        if (!g_angle_pins[i].valid) {
            g_angle_pins[i].who = who;
            g_angle_pins[i].angle = angle;
            g_angle_pins[i].px = px;
            g_angle_pins[i].py = py;
            g_angle_pins[i].action = action;
            g_angle_pins[i].valid = true;
            api.pushboolean(L, 1); return 1;
        }
    }
    api.pushboolean(L, 0); return 1;
}

static int g_pin_debug_n = 0;
static void apply_angle_pin_after_think(void* self) {
    for (int i = 0; i < 8; ++i) {
        if (g_angle_pins[i].valid && g_angle_pins[i].who == self) {
            // Validate vtable before writing — if the engine freed/recycled
            // this puppet, its vtable pointer changes, and writing to +0xB0
            // would corrupt random memory (the long-standing lua52 heap
            // crash source). Expected: TPlayer vftable at RVA 0x156b14.
            if (IsBadReadPtr(self, 4)) {
                g_angle_pins[i].valid = false;
                host_log("pin_apply: self=%p unreadable, invalidating pin", self);
                return;
            }
            DWORD_PTR vt = *(DWORD_PTR*)self;
            DWORD_PTR expected_vt = (DWORD_PTR)mod_base() + 0x156b14;
            if (vt != expected_vt) {
                g_angle_pins[i].valid = false;
                host_log("pin_apply: self=%p vtable=%p != TPlayer %p — invalidating pin",
                    self, (void*)vt, (void*)expected_vt);
                return;
            }
            float before = *(float*)((char*)self + 0xB0);
            *(float*)((char*)self + 0xB0) = g_angle_pins[i].angle;
            // Pin action (+0xB4) too if Lua supplied one. Prevents the
            // engine's think from resetting +0xB4 to walk/idle between
            // snapshots — what was causing the aim/knife anim flicker on
            // remote puppets. action=-1 = unmanaged (don't pin).
            if (g_angle_pins[i].action != -1) {
                *(int*)((char*)self + 0xB4) = g_angle_pins[i].action;
            }
            // Log a sample when the engine's case-handler wrote a DIFFERENT
            // angle than our pin — that's the case-7/8 path overwriting us.
            // Throttled: only first 40 mismatches so it doesn't flood.
            if (g_pin_debug_n < 40 && before != g_angle_pins[i].angle) {
                int action = *(int*)((char*)self + 0xB4);
                float frame = *(float*)((char*)self + 0x70);
                host_log("pin_apply MISMATCH puppet=%p engine_angle=%.3f pin=%.3f action=%d frame=%.1f",
                    self, before, g_angle_pins[i].angle, action, frame);
                ++g_pin_debug_n;
            }
            return;
        }
    }
}

// First-N logger so we can see which puppet survived how many think frames
// before crashing. Keyed by ptr identity; per-puppet up to 16 frames.
struct PThinkLog { void* who; int frames; };
static PThinkLog g_think_log[8];
static void log_first_frames(void* self, const char* tag) {
    for (int i = 0; i < 8; ++i) {
        if (g_think_log[i].who == self) {
            if (g_think_log[i].frames < 16) {
                host_log("%s puppet=%p frame=%d hp=%.1f inv=%d cc=%d a=%d",
                    tag, self, g_think_log[i].frames,
                    *(float*)((char*)self + HP_OFF),
                    (int)*((unsigned char*)self + INVULN_OFF),
                    *(int*)((char*)self + DEATH_TIMER_OFF),
                    *(int*)((char*)self + 0xB4));
                g_think_log[i].frames++;
            }
            return;
        }
    }
    for (int i = 0; i < 8; ++i) {
        if (g_think_log[i].who == nullptr) {
            g_think_log[i].who = self;
            g_think_log[i].frames = 1;
            host_log("%s puppet=%p FRAME 0 (FIRST SEEN)", tag, self);
            return;
        }
    }
}

static int __fastcall hook_PThink1(void* self, void* /*edx*/) {
    if (!is_passive_player(self)) return orig_PThink1(self);
    log_first_frames(self, "PT1.pre");
    init_dummy_device();
    void** ip = (void**)(mod_base() + INPUT_DEV_RVA);
    unsigned char* gate = (unsigned char*)self + FIRE_GATE_OFF;
    void* saved_in = *ip;
    unsigned char saved_gate = *gate;
    *ip = (void*)g_dummy_dev;   // every input query reads "nothing pressed"
    *gate = 1;                  // engine's own gate: skip fire/reload/drop/shoot
    // Per-frame defensive pins. Lua re-pins at network rate (~10 Hz); these
    // close the ~100 ms window where an incoming hit could fire TakeDamage
    // @0x45e900 or the gameover branch @0x45c220 with cleared flags.
    //   HP    > 0 → TActor death check never trips
    //   inv   = 1 → entire TPlayer::TakeDamage body short-circuits
    //   +0xCC ≠ 0 → vt[14] gameover gate stays closed even if HP momentarily
    //                hits <= 0 (the order is HP→+0xCC=0x32; we pre-pin so the
    //                "==0" check never matches).
    *(float*)((char*)self + HP_OFF) = 9999.0f;
    *((unsigned char*)self + INVULN_OFF) = 1;
    *(int*)((char*)self + DEATH_TIMER_OFF) = DEATH_TIMER_SENTINEL;
    // Set dummy-device's mouse target so case-7/8 (shoot/aim) computes the
    // right angle from puppet's perspective. Target = puppet_pos + unit
    // vector at pinned angle. Box2D body at +0x50; world position is the
    // Box2D body's transform. We can use the cached pos field at... well
    // easier: just read GetPos via vt[2] (TActor base GetPos returns +0x50
    // body pos as 2 floats). But that's a vtable call mid-hook. Simpler:
    // use the position fields at +0x1B8/+0x1BC that aliveUpdate maintains
    // (per the diagnostic, aliveUpdate just copies XY there each frame).
    // Real input device returns mouse position RELATIVE to player (not
    // absolute world coords). Our dummy must do the same: a unit direction
    // vector at the pinned angle. Engine then computes atan2(sin, cos) =
    // pinned_angle exactly, eliminating position-dependent jitter and
    // making cases 1/7/8 all compute the correct rotation.
    float pinned_angle = 0.0f;
    for (int i = 0; i < 8; ++i) {
        if (g_angle_pins[i].valid && g_angle_pins[i].who == self) {
            pinned_angle = g_angle_pins[i].angle;
            break;
        }
    }
    g_puppet_aim_x = __builtin_cosf(pinned_angle);
    g_puppet_aim_y = __builtin_sinf(pinned_angle);
    int r = orig_PThink1(self); // anim state machine + position + aim cache run
    // Re-apply our snapshot angle. case 1 (walk) inside orig wrote +0xB0
    // from a velocity-derived value that's stuck at 0 due to dummy input.
    apply_angle_pin_after_think(self);
    log_first_frames(self, "PT1.post");
    *gate = saved_gate;
    *ip = saved_in;
    return r;
}

static int __fastcall hook_PThink2(void* self, void* /*edx*/) {
    if (!is_passive_player(self)) return orig_PThink2(self);
    log_first_frames(self, "PT2.pre");
    init_dummy_device();
    void** ip = (void**)(mod_base() + INPUT_DEV_RVA);
    void* saved_in = *ip;
    *ip = (void*)g_dummy_dev;
    // Note: do NOT re-set g_puppet_aim_x/y here. Doing so caused worse
    // visible behavior (jitter + render artifacts) — PT1's setting is
    // enough for the engine to compute case-7/8 correctly, and read-back
    // during render uses a different angle source we shouldn't touch.
    // Belt-and-braces: even with the camera-sub hook below, force action=8
    // (aim) for the duration of orig_PThink2 so that IF the hook somehow
    // misses the sub (e.g. inlined elsewhere), the action!=8 branch — the
    // 24-iter raycast loop + module walk that AVs — is not taken.
    int* act = (int*)((char*)self + 0xB4);
    int saved_act = *act;
    *act = 8;
    g_in_puppet_think2 = true;
    int r = orig_PThink2(self);  // render/draw block runs (this+0xFD==0)
    g_in_puppet_think2 = false;
    *act = saved_act;
    log_first_frames(self, "PT2.post");
    // NO zoom save/restore — DAT_0057588c is in .rdata (read-only), and
    // attempting to write it AVs. Old code did *zoom = sz; *zoom2 = sz2;
    // which crashed inside this hook (caught by our own VEH at
    // VERSION.dll+0x42c2). Since hook_CameraSub now bails on EVERY
    // non-main-player call (not just within think2), the puppet never
    // runs the camera sub at all, so there's no zoom mutation to undo.
    *ip = saved_in;
    return r;
}

// Hook purecall itself so ANY virtual-method-on-abstract-class dispatch
// becomes a silent no-op instead of aborting the process. Chasing
// individual purecall slots in TPlayer's vtable (6 found, all patched —
// the engine STILL crashed through purecall) was whack-a-mole. The crash
// chain showed esp+12=purecall after the patches, meaning either we missed
// a slot or a different class's vtable has a purecall the engine reaches.
// Hooking the stub itself catches them all. Logs the caller so we can still
// learn what's being dispatched even though we silence the abort.
static int g_purecall_hits = 0;
static void __cdecl hook_purecall() {
    // Read the return address right above ESP (cdecl, no args).
    void* ret_addr;
    asm volatile("movl 4(%%ebp), %0" : "=r"(ret_addr));
    DWORD_PTR base = (DWORD_PTR)g_base;
    DWORD_PTR r = (DWORD_PTR)ret_addr;
    DWORD_PTR rel = (r >= base && r < base + 0x800000) ? (r - base) : 0;
    if (++g_purecall_hits <= 20) {
        host_log("purecall HIT #%d  caller=%p (Teleglitch.exe+0x%lx)",
            g_purecall_hits, ret_addr, (unsigned long)rel);
    }
    // Just return. The caller expected vt[N]() to do something — usually
    // void; sometimes returning 0 is fine. For methods that returned a
    // non-zero pointer the caller might NULL-deref later, but that's still
    // strictly better than terminating right now.
}

// Patch all purecall stubs in TPlayer's vtable region. Ghidra scan found 6:
// +0x94, +0x11c, +0x134, +0x138, +0x1f8, +0x240 (RVAs from TPlayer vftable
// base 0x556b14 — i.e. 0x556ba8, 0x556c30, 0x556c48, 0x556c4c, 0x556d0c,
// 0x556d54). v1 of this patch only fixed the first; engine crashed in another
// purecall slot. TPlayer extends way past 40 slots (probably extended vtables
// for multiple inheritance / virtual bases). All purecall slots are
// intentional poison pills — replacing with a noop is no worse than crash
// for any slot the engine might dispatch on. Replacement target is the
// existing PreSubclassWindow noop stub (RVA 0x2830) used by other classes
// for "this method intentionally does nothing".
static void patch_tplayer_purecall_slot() {
    // RVAs of every purecall slot in TPlayer vftable (= 0x556b14 + slot_offset).
    // Module RVA = 0x156b14 + slot_offset (load base differs by 0x400000 from
    // Ghidra's analysis base).
    static const DWORD slot_rvas[] = {
        0x156ba8,  // +0x94
        0x156c30,  // +0x11c
        0x156c48,  // +0x134
        0x156c4c,  // +0x138
        0x156d0c,  // +0x1f8
        0x156d54,  // +0x240
    };
    DWORD noop = (DWORD)(g_base + 0x2830);   // PreSubclassWindow noop
    for (size_t i = 0; i < sizeof(slot_rvas) / sizeof(slot_rvas[0]); ++i) {
        BYTE* slot = g_base + slot_rvas[i];
        DWORD old_protect;
        if (VirtualProtect(slot, 4, PAGE_READWRITE, &old_protect)) {
            DWORD before = *(DWORD*)slot;
            *(DWORD*)slot = noop;
            DWORD ignored;
            VirtualProtect(slot, 4, old_protect, &ignored);
            host_log("patched TPlayer vt slot RVA 0x%x: 0x%08x -> 0x%08x", slot_rvas[i], before, noop);
        } else {
            host_log("patch TPlayer vt slot RVA 0x%x FAILED — err=%lu", slot_rvas[i], GetLastError());
        }
    }
}

typedef void (__cdecl *PurecallFn)(void);
static PurecallFn orig_purecall = nullptr;

// vt[14] HUD/gameover @ 0x45c220 — drawn per-TPlayer. The puppet's HUD draws
// on top of the local's (overlapping "9999" text). Skip orig when self is a
// puppet so only the local renders its HP/ammo strings.
//
// Exception: while we're spectating, the LOCAL body is moved off-map and
// the camera follows the spectated puppet. The local's HUD then renders at
// the local's off-map position (invisible) → no HUD visible. To show the
// spectated puppet's HUD instead, Lua sets g_hud_allowed_puppet = puppet,
// and we DO call orig for that one puppet.
static void* g_hud_allowed_puppet = nullptr;

static int l_set_hud_allowed_puppet(lua_State* L) {
    void* p = resolve_entity(L, 1);
    g_hud_allowed_puppet = p;
    api.pushboolean(L, 1);
    return 1;
}

typedef int (__fastcall *HudFn)(void* self, void* edx);
static HudFn orig_PHud = nullptr;
static int __fastcall hook_PHud(void* self, void* /*edx*/) {
    if (is_passive_player(self)) {
        if (self == g_hud_allowed_puppet) return orig_PHud(self, nullptr);
        return 0;
    }
    return orig_PHud(self, nullptr);
}

static int l_install_passive_player_hooks(lua_State* L) {
    g_base = (BYTE*)GetModuleHandleA(NULL);
    init_dummy_device();
    patch_tplayer_purecall_slot();
    // Hook purecall itself. Catches every vt[N]() dispatch to an unimplemented
    // virtual, regardless of which class's vtable holds it.
    BYTE* pc = g_base + 0x10d0ee;   // RVA of purecall (Ghidra: 0x0050d0ee)
    MH_STATUS spc = MH_CreateHook(pc, (LPVOID)&hook_purecall, (LPVOID*)&orig_purecall);
    if (spc == MH_OK) spc = MH_EnableHook(pc);
    host_log("purecall hook: status=%d", spc);
    BYTE* t1 = g_base + 0x5cbc0;   // FUN_0045cbc0 (vtable[10] think1)
    BYTE* t2 = g_base + 0x5bff0;   // FUN_0045bff0 (vtable[11] think2/render)
    BYTE* tc = g_base + 0x5b9d0;   // FUN_0045b9d0 (camera-coupling sub, called from think2)
    MH_STATUS s1 = MH_CreateHook(t1, (LPVOID)&hook_PThink1, (LPVOID*)&orig_PThink1);
    if (s1 == MH_OK) s1 = MH_EnableHook(t1);
    MH_STATUS s2 = MH_CreateHook(t2, (LPVOID)&hook_PThink2, (LPVOID*)&orig_PThink2);
    if (s2 == MH_OK) s2 = MH_EnableHook(t2);
    MH_STATUS sc = MH_CreateHook(tc, (LPVOID)&hook_CameraSub, (LPVOID*)&orig_CameraSub);
    if (sc == MH_OK) sc = MH_EnableHook(tc);
    BYTE* th = g_base + 0x5c220;   // FUN_0045c220 (vtable[14] HUD/gameover)
    MH_STATUS sh = MH_CreateHook(th, (LPVOID)&hook_PHud, (LPVOID*)&orig_PHud);
    if (sh == MH_OK) sh = MH_EnableHook(th);
    host_log("install_passive_player_hooks: think1=%d think2=%d camera=%d hud=%d", s1, s2, sc, sh);
    api.pushboolean(L, (s1 == MH_OK && s2 == MH_OK && sc == MH_OK && sh == MH_OK) ? 1 : 0);
    return 1;
}

// Shared TPlayer-vtable validation. Returns true if ptr's vtable is the
// known TPlayer vftable (RVA 0x156b14). Used by every native that writes
// puppet-only fields — if the engine freed/recycled this puppet, the write
// would corrupt random memory which surfaces seconds later as a lua52 heap
// crash. Skipping the write loses an anim frame but keeps the process up.
static bool is_tplayer_ptr(void* e) {
    if (!e || IsBadReadPtr(e, 4)) return false;
    DWORD_PTR vt = *(DWORD_PTR*)e;
    DWORD_PTR expected = (DWORD_PTR)mod_base() + 0x156b14;
    return vt == expected;
}

// pin_hp(ptr) — write a positive health to actor+0xBC so a passive remote never
// reaches HP<=0 locally (which would run the death branch + gameover HUD over
// OUR screen). Called each snapshot for tplayer remotes.
static int l_pin_hp(lua_State* L) {
    void* e = resolve_entity(L, 1);
    if (!is_tplayer_ptr(e)) { api.pushboolean(L, 0); return 1; }
    // For PUPPETS, we pin to 9999 so they're effectively unkillable from
    // local damage — the host's snapshot is authoritative for their HP.
    // For the LOCAL/MAIN player (death-intercept path, 2nd arg = true),
    // pin to 100 instead: same engine effect (HP > 0 → death check never
    // trips) but the HUD reads a sensible value the user expects to see
    // rather than "9999+".
    void* mainp = *(void**)(mod_base() + MAIN_PLAYER_RVA);
    float pin_value = 9999.0f;
    if (mainp && e == mainp) {
        typedef int (*LuaToBoolFn)(lua_State*, int);
        static LuaToBoolFn lua_toboolean_p = nullptr;
        if (!lua_toboolean_p) {
            HMODULE lm = GetModuleHandleA("lua52.dll");
            lua_toboolean_p = (LuaToBoolFn)GetProcAddress(lm, "lua_toboolean");
        }
        int allow_main = lua_toboolean_p ? lua_toboolean_p(L, 2) : 0;
        if (!allow_main) {
            host_log("pin_hp REFUSED on main player e=%p — pass true as 2nd arg to allow", e);
            api.pushboolean(L, 0);
            return 1;
        }
        pin_value = 100.0f;
    }
    *(float*)((char*)e + HP_OFF) = pin_value;
    // Also pin the death timer (+0xCC). On a TakeDamage that drops HP<=0,
    // the engine writes +0xCC=0x32 (50-frame countdown) then runs vt[14]
    // gameover when +0xCC==0 AND HP<=0. We just pinned HP, but if the
    // engine had already started the countdown before this call, the
    // gateover would still fire once +0xCC ticks down. Pinning +0xCC to
    // a huge sentinel keeps the countdown from ever reaching 0.
    *(int*)((char*)e + DEATH_TIMER_OFF) = DEATH_TIMER_SENTINEL;
    api.pushboolean(L, 1);
    return 1;
}

// read_hp(ptr) — return *(float*)(ptr+0xBC) as a Lua number. Used by the
// death intercept to poll the LOCAL player's HP from a cached pointer
// without going through any engine state (DAT_005747a4 / GetPlayer) that
// puppets can pollute. Returns nil on bad pointer.
static int l_read_hp(lua_State* L) {
    void* e = resolve_entity(L, 1);
    if (!e || IsBadReadPtr(e, HP_OFF + 4)) { api.pushnil(L); return 1; }
    float hp = *(float*)((char*)e + HP_OFF);
    typedef void (*LuaPushNumberFn)(lua_State*, double);
    static LuaPushNumberFn lua_pushnumber_p = nullptr;
    if (!lua_pushnumber_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_pushnumber_p = (LuaPushNumberFn)GetProcAddress(lm, "lua_pushnumber");
    }
    if (lua_pushnumber_p) lua_pushnumber_p(L, (double)hp);
    else api.pushnil(L);
    return 1;
}

// set_body_kinematic(ptr) — switch the actor's Box2D body to kinematic so
// it stops being driven by physics (no force response, no collisions push it).
// Puppet TPlayers should be kinematic — we own their world transform via
// SetPosition; dynamic bodies fight back by integrating leftover velocity
// against walls/items and accumulating drift.
//
// TActor->body is at +0x50 (see tplayer_crash_diagnosis.md).
// b2Body::m_type is at the start of the b2Body block in Box2D 2.x layouts.
// We dump the first 32 bytes the FIRST time we're called so we can verify
// the offset from the log (a live player should read 2=b2_dynamicBody;
// b2_staticBody=0, b2_kinematicBody=1).
#define ACTOR_BODY_OFF   0x50
#define B2_TYPE_OFF      0x00
#define B2_KINEMATIC     1
static int l_set_body_kinematic(lua_State* L) {
    void* e = resolve_entity(L, 1);
    if (!e || IsBadReadPtr(e, 4)) { api.pushboolean(L, 0); return 1; }
    void* body = *(void**)((char*)e + ACTOR_BODY_OFF);
    if (!body || IsBadWritePtr(body, 32)) {
        host_log("set_body_kinematic: body=%p — bad/null at e+0x50", body);
        api.pushboolean(L, 0); return 1;
    }
    static bool dumped = false;
    if (!dumped) {
        dumped = true;
        const unsigned char* b = (const unsigned char*)body;
        host_log("b2Body @%p dump (32 bytes): %02x%02x%02x%02x %02x%02x%02x%02x  "
                 "%02x%02x%02x%02x %02x%02x%02x%02x  %02x%02x%02x%02x %02x%02x%02x%02x  "
                 "%02x%02x%02x%02x %02x%02x%02x%02x",
                 body,
                 b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],
                 b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15],
                 b[16],b[17],b[18],b[19],b[20],b[21],b[22],b[23],
                 b[24],b[25],b[26],b[27],b[28],b[29],b[30],b[31]);
        host_log("  as int32 [0..7]: %d %d %d %d %d %d %d %d",
                 *(int*)(b+0),  *(int*)(b+4),  *(int*)(b+8),  *(int*)(b+12),
                 *(int*)(b+16), *(int*)(b+20), *(int*)(b+24), *(int*)(b+28));
    }
    int old_type = *(int*)((char*)body + B2_TYPE_OFF);
    *(int*)((char*)body + B2_TYPE_OFF) = B2_KINEMATIC;
    host_log("set_body_kinematic: e=%p body=%p [+%02x] was=%d set=%d",
             e, body, B2_TYPE_OFF, old_type, B2_KINEMATIC);
    api.pushboolean(L, 1);
    return 1;
}

// set_body_dynamic(ptr) — restore the actor's Box2D body to dynamic (the
// default for a live player). Used to undo set_body_kinematic on respawn.
#define B2_DYNAMIC 2
static int l_set_body_dynamic(lua_State* L) {
    void* e = resolve_entity(L, 1);
    if (!e || IsBadReadPtr(e, 4)) { api.pushboolean(L, 0); return 1; }
    void* body = *(void**)((char*)e + ACTOR_BODY_OFF);
    if (!body || IsBadWritePtr(body, 32)) { api.pushboolean(L, 0); return 1; }
    *(int*)((char*)body + B2_TYPE_OFF) = B2_DYNAMIC;
    api.pushboolean(L, 1);
    return 1;
}

// set_body_sensor(ptr) — make all of an entity's Box2D fixtures sensors so it
// no longer collides (walk-through), keeping its sprite. Used for death-loot
// chests. We FIND m_fixtureList by scanning the body for a member pointer whose
// target's m_body (b2Fixture+0x08) points back to the body — a certain match —
// then set m_isSensor (b2Fixture+0x28, best-guess; the dump confirms it). The
// m_body validation means a wrong fixture-list offset just aborts (no write).
#define B2FIX_MBODY_OFF    0x08
#define B2FIX_NEXT_OFF     0x04
// m_isSensor lives right after b2Filter (category@0x20, mask@0x22, group@0x24);
// confirmed from a live fixture dump (the byte at +0x26). +0x28 is m_userData.
#define B2FIX_SENSOR_OFF   0x26
static int l_set_body_sensor(lua_State* L) {
    void* e = resolve_entity(L, 1);
    if (!e || IsBadReadPtr(e, ACTOR_BODY_OFF + 4)) { api.pushboolean(L, 0); return 1; }
    void* body = *(void**)((char*)e + ACTOR_BODY_OFF);
    if (!body || IsBadReadPtr(body, 0x88)) { host_log("set_body_sensor: bad body=%p", body); api.pushboolean(L, 0); return 1; }
    void* fix = nullptr; int found_off = -1;
    for (int off = 0x40; off <= 0x84; off += 4) {
        void* cand = *(void**)((char*)body + off);
        if (cand && !IsBadReadPtr(cand, 0x40)
            && *(void**)((char*)cand + B2FIX_MBODY_OFF) == body) {
            fix = cand; found_off = off; break;
        }
    }
    if (!fix) { host_log("set_body_sensor: fixtureList not found (body=%p)", body); api.pushboolean(L, 0); return 1; }
    const unsigned char* fb = (const unsigned char*)fix;
    host_log("set_body_sensor: m_fixtureList@body+0x%x=%p  fixdump: "
             "%08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x",
             found_off, fix,
             *(int*)(fb+0),*(int*)(fb+4),*(int*)(fb+8),*(int*)(fb+12),
             *(int*)(fb+16),*(int*)(fb+20),*(int*)(fb+24),*(int*)(fb+28),
             *(int*)(fb+32),*(int*)(fb+36),*(int*)(fb+40),*(int*)(fb+44));
    int count = 0;
    while (fix && !IsBadReadPtr(fix, 0x40)
           && *(void**)((char*)fix + B2FIX_MBODY_OFF) == body && count < 16) {
        *((unsigned char*)fix + B2FIX_SENSOR_OFF) = 1;   // m_isSensor = true
        count++;
        fix = *(void**)((char*)fix + B2FIX_NEXT_OFF);
    }
    host_log("set_body_sensor: set sensor on %d fixture(s)", count);
    api.pushboolean(L, count > 0 ? 1 : 0);
    return 1;
}

// set_render_gate(ptr, val) — write byte to +0xFD (think2's render/draw
// gate). !=0 → draw block in think2 short-circuits, the actor becomes
// invisible. Used to hide the local player's body during spectate so the
// camera shows ONLY the teammate puppet at the spectate target.
#define RENDER_GATE_OFF 0xFD
static int l_set_render_gate(lua_State* L) {
    typedef int (*LuaToIntegerFn)(lua_State*, int, int*);
    static LuaToIntegerFn lua_tointeger_p = nullptr;
    if (!lua_tointeger_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tointeger_p = (LuaToIntegerFn)GetProcAddress(lm, "lua_tointegerx");
    }
    void* e = resolve_entity(L, 1);
    if (!e || IsBadWritePtr(e, RENDER_GATE_OFF + 1)) { api.pushboolean(L, 0); return 1; }
    int val = lua_tointeger_p ? lua_tointeger_p(L, 2, nullptr) : 0;
    *((unsigned char*)e + RENDER_GATE_OFF) = (unsigned char)(val & 0xff);
    api.pushboolean(L, 1);
    return 1;
}

// set_fire_gate(ptr, val) — write byte to +0xE4 (think1's fire/reload/drop/
// shoot gate). !=0 → all weapon blocks skip with anim intact. Used to
// disable firing while spectating.
static int l_set_fire_gate(lua_State* L) {
    typedef int (*LuaToIntegerFn)(lua_State*, int, int*);
    static LuaToIntegerFn lua_tointeger_p = nullptr;
    if (!lua_tointeger_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tointeger_p = (LuaToIntegerFn)GetProcAddress(lm, "lua_tointegerx");
    }
    void* e = resolve_entity(L, 1);
    if (!e || IsBadWritePtr(e, FIRE_GATE_OFF + 1)) { api.pushboolean(L, 0); return 1; }
    int val = lua_tointeger_p ? lua_tointeger_p(L, 2, nullptr) : 0;
    *((unsigned char*)e + FIRE_GATE_OFF) = (unsigned char)(val & 0xff);
    api.pushboolean(L, 1);
    return 1;
}

// set_body_velocity(ptr, vx, vy) — write the actor's Box2D body
// m_linearVelocity. Used on puppet TPlayers: their bodies are kinematic
// (we own position via SetPosition each snapshot) so Box2D doesn't
// integrate forces — but the engine's anim system reads velocity to decide
// when to play the walk cycle. Setting velocity from the snapshot delta
// makes the puppet's walk animation play without re-introducing drift
// (kinematic body honors velocity but our next SetPosition snaps back).
//
// b2Body::m_linearVelocity at +0x40 (b2Vec2 = 2 floats) — standard Box2D
// 2.x layout, same offset our earlier bomb-throw guess used.
#define B2_LINVEL_OFF 0x40
static int l_set_body_velocity(lua_State* L) {
    typedef double (*LuaToNumberFn)(lua_State*, int, int*);
    static LuaToNumberFn lua_tonumber_p = nullptr;
    if (!lua_tonumber_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tonumber_p = (LuaToNumberFn)GetProcAddress(lm, "lua_tonumberx");
    }
    void* e = resolve_entity(L, 1);
    if (!e || IsBadReadPtr(e, 4)) { api.pushboolean(L, 0); return 1; }
    void* body = *(void**)((char*)e + ACTOR_BODY_OFF);
    if (!body || IsBadWritePtr(body, B2_LINVEL_OFF + 8)) {
        api.pushboolean(L, 0); return 1;
    }
    float vx = lua_tonumber_p ? (float)lua_tonumber_p(L, 2, nullptr) : 0.0f;
    float vy = lua_tonumber_p ? (float)lua_tonumber_p(L, 3, nullptr) : 0.0f;
    *(float*)((char*)body + B2_LINVEL_OFF + 0) = vx;
    *(float*)((char*)body + B2_LINVEL_OFF + 4) = vy;
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
    if (!is_tplayer_ptr(e)) { api.pushboolean(L, 0); return 1; }
    int on = lua_toboolean_p ? lua_toboolean_p(L, 2) : 1;
    *(unsigned char*)((char*)e + INVULN_OFF) = on ? 1 : 0;
    api.pushboolean(L, 1);
    return 1;
}

// set_button_label(button_ptr_userdata, "new text") — write a new label
// into the C++ button object's std::string at offset +0x28. Probe found the
// classic MSVC SSO layout: 16-byte inline buffer at +0x28, size at +0x38,
// capacity at +0x3c (set to 15). For labels ≤15 chars we write directly into
// the inline buffer and update size. Strings longer than 15 chars would need
// heap allocation via the engine's allocator — not supported here, so we
// truncate. Returns true on success.
//
// SAFETY: validates the std::string capacity field is still 15 (the SSO
// sentinel) before touching anything. If a different value appears, the
// button might be using a heap-backed string and we refuse to write rather
// than scribble random memory.
static int l_set_button_label(lua_State* L) {
    typedef void* (*LuaToPointerFn)(lua_State*, int);
    static LuaToPointerFn lua_topointer_p = nullptr;
    if (!lua_topointer_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_topointer_p = (LuaToPointerFn)GetProcAddress(lm, "lua_topointer");
    }
    void* p = lua_topointer_p ? lua_topointer_p(L, 1) : nullptr;
    if (!p || IsBadWritePtr(p, 0x40)) {
        api.pushboolean(L, 0); return 1;
    }
    size_t n = 0;
    const char* txt = api.tolstring(L, 2, &n);
    if (!txt) { api.pushboolean(L, 0); return 1; }

    const int STR_OFF      = 0x28;  // inline buffer start
    const int SIZE_OFF     = 0x38;  // current size (uint32)
    const int CAP_OFF      = 0x3c;  // capacity (uint32, 15 = SSO)
    const int SSO_CAPACITY = 15;

    uint32_t cap = *(uint32_t*)((char*)p + CAP_OFF);
    if (cap != SSO_CAPACITY) {
        host_log("set_button_label: REFUSE — capacity=%u not SSO sentinel %d", cap, SSO_CAPACITY);
        api.pushboolean(L, 0); return 1;
    }

    size_t write_n = n;
    if (write_n > (size_t)SSO_CAPACITY) write_n = SSO_CAPACITY;
    char* buf = (char*)p + STR_OFF;
    memcpy(buf, txt, write_n);
    buf[write_n] = '\0';                                  // null-terminate
    *(uint32_t*)((char*)p + SIZE_OFF) = (uint32_t)write_n;
    // capacity stays at 15 (SSO)
    api.pushboolean(L, 1);
    return 1;
}

// probe_memory(ptr_userdata) — hex+ascii dump of 192 bytes starting at the
// userdata's raw address. Lua-side passes button.pointer; we hexdump so we
// can find where the C++ button object stores its label string. Logs both
// direct interpretation (pointer is the object) AND one-dereference (pointer
// is a pointer to the object) so we cover both userdata shapes.
static int l_probe_memory(lua_State* L) {
    typedef void* (*LuaToPointerFn)(lua_State*, int);
    static LuaToPointerFn lua_topointer_p = nullptr;
    if (!lua_topointer_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_topointer_p = (LuaToPointerFn)GetProcAddress(lm, "lua_topointer");
    }
    void* p = lua_topointer_p ? lua_topointer_p(L, 1) : nullptr;
    if (!p) { return 0; }

    auto dump_at = [&](const char* tag, void* base) {
        if (!base) return;
        if (IsBadReadPtr(base, 192)) {
            host_log("probe %s @%p UNREADABLE", tag, base);
            return;
        }
        char line[260];
        unsigned char* b = (unsigned char*)base;
        for (int row = 0; row < 12; row++) {
            char* pos = line;
            pos += snprintf(pos, sizeof(line) - (pos - line), "+0x%02x  ", row * 16);
            for (int c = 0; c < 16; c++) {
                pos += snprintf(pos, sizeof(line) - (pos - line), "%02x ", b[row*16 + c]);
            }
            pos += snprintf(pos, sizeof(line) - (pos - line), " ");
            for (int c = 0; c < 16; c++) {
                unsigned char ch = b[row*16 + c];
                *pos++ = (ch >= 0x20 && ch < 0x7f) ? (char)ch : '.';
            }
            *pos = 0;
            host_log("probe %s %s", tag, line);
        }
    };

    dump_at("DIRECT", p);
    void* p2 = nullptr;
    if (!IsBadReadPtr(p, sizeof(void*))) p2 = *(void**)p;
    if (p2 && p2 != p) dump_at("DEREF1", p2);
    return 0;
}

// Frame tick: hook user32!PeekMessageA so we run a Lua callback per Win32
// frame even at title-menu state (where engine-tracked coroutines / Wait()
// can't be used safely). Throttles to ~10Hz so we don't burn CPU. The
// callback name is the global "MP_FRAME_TICK". A reentrancy guard avoids
// double-entry if the callback itself causes another PeekMessageA call.
typedef BOOL (WINAPI *PeekMessageAFn)(LPMSG, HWND, UINT, UINT, UINT);
static PeekMessageAFn orig_PeekMessageA = nullptr;
// g_frame_tick_armed / g_in_frame_tick / g_last_tick_ms are defined up
// near hook_lua_resume so that hook can reference them.

// When true, every ESC keypress arriving via PeekMessageA gets rewritten
// to WM_NULL so the engine's native ESC handler doesn't toggle the
// paused MP-disconnected user back into the running level.
static volatile bool g_suppress_esc = false;
// Counter: while > 0, the next ESC message is allowed through the
// suppression filter (decrements per ESC seen). Used by inject_esc so
// our forced pause keypress isn't swallowed by our own filter.
static volatile int  g_pass_esc_count = 0;
// When true, ESC keydown causes the hook to PostMessage WM_CLOSE to
// our window — the engine then performs a clean shutdown. Used on the
// mp_kicked notification page so the user can press ESC to exit
// instead of clicking OK.
static volatile bool g_esc_quits = false;
// When true, an ESC keydown sets g_esc_pressed = true (and is
// swallowed). The Lua tick polls this from check_esc_pressed() and
// runs the lobby-leave action when on mp_waiting.
static volatile bool g_esc_leaves_lobby = false;
// When true, ESC keydown is swallowed and g_esc_pressed latched, same as
// g_esc_leaves_lobby but armed during in-game MP. Engine never sees the
// ESC, so its vanilla pause overlay can't appear — Lua tick instead
// flips menu state to "game=false" and switches the active page to
// mp_pause, giving us a single canonical MP pause UI.
static volatile bool g_esc_opens_mp_pause = false;
static volatile bool g_esc_pressed      = false;
// Low-level keyboard hook handle. Required because Teleglitch reads
// keyboard via DirectInput / GetAsyncKeyState — its key events never
// arrive via PeekMessageA, so our existing hook can't see them.
static HHOOK g_kbd_ll_hook = NULL;
// Cached top-level HWND of our process. Populated by inject_esc /
// hook_PeekMessageA on first use; reused by the ESC-quits path.
static HWND g_our_hwnd = NULL;

struct EnumOurWindow { DWORD pid; HWND hwnd; };
static BOOL CALLBACK enum_our_window_cb(HWND hwnd, LPARAM lp) {
    EnumOurWindow* ed = (EnumOurWindow*)lp;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == ed->pid && GetWindow(hwnd, GW_OWNER) == NULL && IsWindowVisible(hwnd)) {
        ed->hwnd = hwnd;
        return FALSE;
    }
    return TRUE;
}
static HWND find_our_hwnd() {
    if (g_our_hwnd && IsWindow(g_our_hwnd)) return g_our_hwnd;
    EnumOurWindow ed = { GetCurrentProcessId(), NULL };
    EnumWindows(enum_our_window_cb, (LPARAM)&ed);
    g_our_hwnd = ed.hwnd;
    return g_our_hwnd;
}

static LONG WINAPI mp_unhandled_filter(EXCEPTION_POINTERS*);  // fwd decl — body lives below DllMain
static BOOL WINAPI hook_PeekMessageA(LPMSG lpMsg, HWND hWnd,
                                     UINT wMsgFilterMin, UINT wMsgFilterMax,
                                     UINT wRemoveMsg) {
    BOOL r = orig_PeekMessageA(lpMsg, hWnd, wMsgFilterMin, wMsgFilterMax, wRemoveMsg);
    // Re-arm our SEH filter every message-pump iteration. Engine or a plugin
    // may install its own filter later in startup; SetUnhandledExceptionFilter
    // is last-writer-wins, so we need to keep stomping it back to ours.
    SetUnhandledExceptionFilter(mp_unhandled_filter);
    // Swallow ESC keydown/keyup while suppression is armed. Has to be
    // done both for KEYDOWN (would trigger the pause toggle) and
    // KEYUP/CHAR so the engine doesn't see a half-event.
    if (r && lpMsg) {
        bool esc = false;
        if ((lpMsg->message == WM_KEYDOWN || lpMsg->message == WM_KEYUP ||
             lpMsg->message == WM_SYSKEYDOWN || lpMsg->message == WM_SYSKEYUP)
            && lpMsg->wParam == VK_ESCAPE) {
            esc = true;
        }
        if (esc) {
            host_log("hook: ESC msg=%u wParam=%u pass=%d quits=%d leaves=%d suppress=%d",
                     lpMsg->message, (unsigned)lpMsg->wParam,
                     g_pass_esc_count, g_esc_quits ? 1 : 0,
                     g_esc_leaves_lobby ? 1 : 0, g_suppress_esc ? 1 : 0);
            if (g_pass_esc_count > 0) {
                g_pass_esc_count--;        // injected ESC — let it through
            } else if (g_esc_quits) {
                // Translate ESC into a clean close request — engine
                // performs its own shutdown via WM_CLOSE.
                if (lpMsg->message == WM_KEYDOWN) {
                    HWND h = find_our_hwnd();
                    if (h) PostMessageA(h, WM_CLOSE, 0, 0);
                }
                lpMsg->message = WM_NULL;
                lpMsg->wParam  = 0;
                lpMsg->lParam  = 0;
            } else if (g_esc_leaves_lobby || g_esc_opens_mp_pause) {
                // Note the ESC for the Lua tick to consume and act on:
                //   leaves_lobby → call lobby_leave_room
                //   opens_mp_pause → SetPage(mp_pause) + SetState(game,false)
                if (lpMsg->message == WM_KEYDOWN) g_esc_pressed = true;
                lpMsg->message = WM_NULL;
                lpMsg->wParam  = 0;
                lpMsg->lParam  = 0;
            } else if (g_suppress_esc) {
                lpMsg->message = WM_NULL;
                lpMsg->wParam  = 0;
                lpMsg->lParam  = 0;
            }
        }
    }
    // Only fire the tick when the queue is EMPTY (r == FALSE) AND the
    // caller was draining with PM_REMOVE. That's the idle slot in the
    // game's main loop — every message has been dispatched, the engine
    // is about to render. Calling Lua during PM_NOREMOVE peeks (which
    // happen mid-callback in many places) reenters Lua at an unsafe
    // point and corrupts the stack → crash.
    // Worker-thread MP_FRAME_TICK fallback for menu states.
    //
    // At the menu, the engine often doesn't call lua_resume / lua_pcallk
    // for many seconds — there's no per-frame Lua tick like there is in
    // game. Without this path, the joiner can sit at mp_waiting forever
    // without ever draining the socket to see the host's "game_started".
    //
    // We guard with g_lua_nest_depth == 0: that proves the main thread
    // is currently NOT inside any engine→Lua call, so calling Lua here
    // (from whatever thread Win32 dispatched PeekMessageA on) doesn't
    // race the engine. The depth counter is the same one updated by
    // hook_lua_resume / hook_lua_pcallk. There's a small race window
    // between the check and the first api.getglobal, but at the menu
    // depth stays at 0 reliably; in game the depth-counted path covers
    // us and this fallback rarely fires.
    if (!r && wRemoveMsg == PM_REMOVE
        && g_frame_tick_armed && !g_in_frame_tick && g_L
        && api.pcall && api.getglobal
        && g_lua_nest_depth == 0) {
        DWORD now = GetTickCount();
        // Try-acquire the cross-thread Lua mutex: if the main-thread swap hook
        // is mid-MP_RENDER (or another pump is mid-tick), skip this iteration
        // rather than racing g_L. Prevents the worker-thread vs main-thread
        // heap corruption that crashes while the game-over overlay is up.
        if ((now - g_last_tick_ms) >= 250 && lua_entry_try_acquire()) {
            g_last_tick_ms = now;
            g_in_frame_tick = true;
            api.getglobal(g_L, "MP_FRAME_TICK");
            // Call the original pcallk directly (bypass our hook so we
            // don't bump g_lua_nest_depth here — depth tracking is for
            // ENGINE→Lua entries only).
            int rc = orig_lua_pcallk
                ? orig_lua_pcallk(g_L, 0, 0, 0, 0, nullptr)
                : api.pcall(g_L, 0, 0, 0, 0, nullptr);
            if (rc != 0) {
                const char* err = api.tolstring(g_L, -1, nullptr);
                host_log("MP_FRAME_TICK error: %s", err ? err : "?");
                api.settop(g_L, -2);
            }
            g_in_frame_tick = false;
            lua_entry_release();
        }
    }
    return r;
}

// ============ NETWORKED CHAT — key capture ============
// When g_chat_capture is true, kbd_ll_proc translates keydowns to ASCII,
// pushes them into g_chat_ring, and SWALLOWS every key (returns 1) so the
// engine's DirectInput / GetAsyncKeyState never sees them — the player can't
// move / shoot / use items while the chat box is open ("blocks input"). The
// Lua frame tick drains the ring via consume_chat_key() and builds the typed
// string. Mirrors the g_bullet_ring single-producer/single-consumer pattern.
// NO Lua calls happen in the hook (it runs on an input-dispatch thread) — per
// the thread-safety rule, only flags + ring writes here; Lua drains on the
// main thread.
static volatile bool g_chat_capture = false;
// Shift state tracked in-hook: we can't trust GetAsyncKeyState for a key we
// may be swallowing, so we watch the L/R shift up/down ourselves.
static bool g_chat_shift = false;
#define CHAT_RING_SIZE 256
static int g_chat_ring[CHAT_RING_SIZE] = {0};
static volatile int g_chat_write_idx = 0;
static int g_chat_read_idx = 0;

static void chat_ring_push(int code) {
    int idx = g_chat_write_idx % CHAT_RING_SIZE;
    g_chat_ring[idx] = code;
    g_chat_write_idx++;
}

// US-layout virtual-key -> ASCII. Returns 0 for keys we don't type (the hook
// still swallows them). Control keys map to their ASCII control codes so the
// Lua side can branch: Enter=13 (send), Backspace=8 (delete), Escape=27
// (cancel).
static int chat_vk_to_ascii(DWORD vk, bool shift, bool caps) {
    if (vk >= 'A' && vk <= 'Z') {
        bool upper = (shift != caps);  // XOR: shift OR caps, not both
        return upper ? (int)vk : (int)(vk - 'A' + 'a');
    }
    if (vk >= '0' && vk <= '9') {
        if (!shift) return (int)vk;
        static const char* sym = ")!@#$%^&*(";  // 0..9 shifted (US)
        return (int)sym[vk - '0'];
    }
    if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) return (int)('0' + (vk - VK_NUMPAD0));
    switch (vk) {
        case VK_SPACE:     return ' ';
        case VK_RETURN:    return 13;   // send
        case VK_BACK:      return 8;    // backspace
        case VK_ESCAPE:    return 27;   // cancel
        case VK_OEM_1:     return shift ? ':' : ';';
        case VK_OEM_PLUS:  return shift ? '+' : '=';
        case VK_OEM_COMMA: return shift ? '<' : ',';
        case VK_OEM_MINUS: return shift ? '_' : '-';
        case VK_OEM_PERIOD:return shift ? '>' : '.';
        case VK_OEM_2:     return shift ? '?' : '/';
        case VK_OEM_3:     return shift ? '~' : '`';
        case VK_OEM_4:     return shift ? '{' : '[';
        case VK_OEM_5:     return shift ? '|' : '\\';
        case VK_OEM_6:     return shift ? '}' : ']';
        case VK_OEM_7:     return shift ? '"' : '\'';
        case VK_DECIMAL:   return '.';
        case VK_MULTIPLY:  return '*';
        case VK_ADD:       return '+';
        case VK_SUBTRACT:  return '-';
        case VK_DIVIDE:    return '/';
    }
    return 0;
}

// Test hotkey (KP*) press flag — set by kbd_ll_proc, drained by consume_testkey.
static volatile bool g_testkey_pressed = false;
// Game-over screen state: g_gameover_bg = screen up (swap hook clears to black);
// g_gameover_dismiss = ESC pressed while it's up (drained by Lua to hide it).
static volatile bool g_gameover_bg      = false;
static volatile bool g_gameover_dismiss = false;

// Low-level keyboard hook. Per MSDN this must return quickly (within
// the LowLevelHooksTimeout) or Windows silently unhooks us. The
// callback also runs on whatever thread posted the key event, so any
// file I/O here (host_log) risks races + slow paths. Keep it minimal:
// check flags, set flag or post message, return.
static LRESULT CALLBACK kbd_ll_proc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode == HC_ACTION) {
        KBDLLHOOKSTRUCT* p = (KBDLLHOOKSTRUCT*)lParam;
        // Chat capture takes priority: while the chat box is open we swallow
        // EVERY key so the engine sees no input, and record typed chars. Only
        // active when our window is foreground (don't eat keys after alt-tab).
        if (g_chat_capture && p) {
            HWND fg = GetForegroundWindow();
            if (g_our_hwnd && fg == g_our_hwnd) {
                bool down = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
                bool up   = (wParam == WM_KEYUP   || wParam == WM_SYSKEYUP);
                DWORD vk  = p->vkCode;
                if (vk == VK_SHIFT || vk == VK_LSHIFT || vk == VK_RSHIFT) {
                    if (down) g_chat_shift = true;
                    else if (up) g_chat_shift = false;
                } else if (down) {
                    bool caps = (GetKeyState(VK_CAPITAL) & 1) != 0;
                    int c = chat_vk_to_ascii(vk, g_chat_shift, caps);
                    if (c) chat_ring_push(c);
                }
                return 1;  // block the engine from seeing any key while typing
            }
        }
        if (p && p->vkCode == VK_ESCAPE &&
            (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN)) {
            HWND fg  = GetForegroundWindow();
            HWND own = g_our_hwnd;  // already cached; avoid EnumWindows here
            if (own && fg == own) {
                if (g_gameover_bg) {           // ESC dismisses the game-over screen
                    g_gameover_dismiss = true;
                    return 1;
                }
                if (g_esc_quits) {
                    PostMessageA(own, WM_CLOSE, 0, 0);
                    return 1;
                }
                if (g_esc_leaves_lobby || g_esc_opens_mp_pause) {
                    g_esc_pressed = true;
                    return 1;
                }
                if (g_suppress_esc) {
                    return 1;
                }
            }
        }
        // Test hotkey (KP*): flag a press for the Lua menu tick to consume.
        // The engine reads menu input natively, so input.KeyDown never reaches
        // Lua at the title menu — this LL hook does. Not swallowed; the engine
        // ignores KP* at the menu anyway.
        if (p && p->vkCode == VK_MULTIPLY &&
            (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN)) {
            if (g_our_hwnd && GetForegroundWindow() == g_our_hwnd) {
                g_testkey_pressed = true;
            }
        }
    }
    return CallNextHookEx(g_kbd_ll_hook, nCode, wParam, lParam);
}

static int l_arm_frame_tick(lua_State* L) {
    // Need both lua_pcallk and lua_getglobal exported by lua52.dll to
    // invoke the Lua callback. If either is missing, refuse to arm —
    // calling a null function pointer would crash on the first frame.
    if (!api.pcall || !api.getglobal) {
        host_log("arm_frame_tick: missing lua_pcallk or lua_getglobal symbol");
        api.pushboolean(L, 0);
        return 1;
    }
    if (!orig_PeekMessageA) {
        HMODULE user32 = GetModuleHandleA("user32.dll");
        if (!user32) user32 = LoadLibraryA("user32.dll");
        if (!user32) { api.pushboolean(L, 0); return 1; }
        void* target = (void*)GetProcAddress(user32, "PeekMessageA");
        if (!target) { api.pushboolean(L, 0); return 1; }
        MH_STATUS s = MH_CreateHook(target, (LPVOID)&hook_PeekMessageA, (LPVOID*)&orig_PeekMessageA);
        host_log("MH_CreateHook(PeekMessageA @%p): status=%d", target, s);
        if (s != MH_OK) { api.pushboolean(L, 0); return 1; }
        s = MH_EnableHook(target);
        host_log("MH_EnableHook(PeekMessageA): status=%d", s);
        if (s != MH_OK) { api.pushboolean(L, 0); return 1; }
    }
    // While we're arming the frame tick (called once at module init),
    // also install a low-level keyboard hook so we can catch ESC
    // presses the engine reads via DirectInput. Without this the
    // suppression / leaves-lobby flags would never see user keys.
    if (!g_kbd_ll_hook) {
        // Cache the HWND before installing so the LL callback can
        // skip the slow EnumWindows path. The callback runs hot
        // (every keystroke) so we keep it free of file I/O too.
        find_our_hwnd();
        g_kbd_ll_hook = SetWindowsHookExA(WH_KEYBOARD_LL, kbd_ll_proc,
                                          GetModuleHandleA(NULL), 0);
        host_log("SetWindowsHookExA(WH_KEYBOARD_LL) -> %p", g_kbd_ll_hook);
    }
    g_frame_tick_armed = true;
    api.pushboolean(L, 1);
    return 1;
}

// ---- Screen-space render hook (wglSwapBuffers) ----
// The engine renders the frame, then calls opengl32!wglSwapBuffers to present.
// We hook it and invoke Lua MP_RENDER just BEFORE the real swap — that runs
// inside the live render pass (GL context current, back buffer drawn), which is
// the only place the engine's immediate-mode DrawText actually draws. Same
// main-thread + nest-depth discipline as MP_FRAME_TICK. At swap time the engine
// is in native render code (not inside a lua_resume), so nest_depth is 0.
typedef BOOL (WINAPI *WglSwapBuffersFn)(HDC);
static WglSwapBuffersFn orig_wglSwapBuffers = nullptr;
static volatile bool g_render_armed = false;
static volatile bool g_in_render    = false;

// GL entry points used to set a fixed 320x240 ortho (with a 4:3 letterboxed
// viewport) before MP_RENDER, so DrawText coords are window-size-independent.
typedef void (WINAPI *GLvoidFn)(void);
typedef void (WINAPI *GLviewportFn)(int, int, int, int);
typedef void (WINAPI *GLmatrixModeFn)(unsigned int);
typedef void (WINAPI *GLorthoFn)(double, double, double, double, double, double);
typedef void (WINAPI *GLenumFn)(unsigned int);
typedef void (WINAPI *GLclearFn)(unsigned int);
typedef void (WINAPI *GLclearColorFn)(float, float, float, float);
static GLviewportFn   p_glViewport     = nullptr;
static GLmatrixModeFn p_glMatrixMode   = nullptr;
static GLorthoFn      p_glOrtho        = nullptr;
static GLvoidFn       p_glLoadIdentity = nullptr;
static GLvoidFn       p_glPushMatrix   = nullptr;
static GLvoidFn       p_glPopMatrix    = nullptr;
static GLenumFn       p_glDisable      = nullptr;
static GLenumFn       p_glEnable       = nullptr;
static GLclearFn      p_glClear        = nullptr;
static GLclearColorFn p_glClearColor   = nullptr;
static bool g_gl_loaded = false;
#define MP_GL_PROJECTION 0x1701
#define MP_GL_MODELVIEW  0x1700
#define MP_GL_DEPTH_TEST 0x0B71
#define MP_GL_COLOR_BUFFER_BIT 0x4000

static void mp_load_gl() {
    if (g_gl_loaded) return;
    HMODULE gl = GetModuleHandleA("opengl32.dll");
    if (!gl) return;
    p_glViewport     = (GLviewportFn)GetProcAddress(gl, "glViewport");
    p_glMatrixMode   = (GLmatrixModeFn)GetProcAddress(gl, "glMatrixMode");
    p_glOrtho        = (GLorthoFn)GetProcAddress(gl, "glOrtho");
    p_glLoadIdentity = (GLvoidFn)GetProcAddress(gl, "glLoadIdentity");
    p_glPushMatrix   = (GLvoidFn)GetProcAddress(gl, "glPushMatrix");
    p_glPopMatrix    = (GLvoidFn)GetProcAddress(gl, "glPopMatrix");
    p_glDisable      = (GLenumFn)GetProcAddress(gl, "glDisable");
    p_glEnable       = (GLenumFn)GetProcAddress(gl, "glEnable");
    p_glClear        = (GLclearFn)GetProcAddress(gl, "glClear");
    p_glClearColor   = (GLclearColorFn)GetProcAddress(gl, "glClearColor");
    g_gl_loaded = p_glViewport && p_glMatrixMode && p_glOrtho &&
                  p_glLoadIdentity && p_glPushMatrix && p_glPopMatrix &&
                  p_glDisable && p_glEnable && p_glClear && p_glClearColor;
}

// The engine's 2D-UI ortho setup (FUN_004b56d0, __cdecl(width,height)), called
// after the world render and before the HUD. We hook it to glClear→black on the
// first call per frame when the game-over screen is up, blacking the world so
// the HUD + deferred scoreboard text render on a black background.
typedef void (__cdecl *Begin2DFn)(float, float);
static Begin2DFn orig_begin2d = nullptr;
static volatile bool g_begin2d_cleared = false; // per-frame guard, reset at swap

static void __cdecl hook_begin2d(float w, float h) {
    orig_begin2d(w, h);   // (begin-2D clear approach abandoned; clear now at swap)
}

static BOOL WINAPI hook_wglSwapBuffers(HDC hdc) {
    // NOTE: no g_lua_nest_depth==0 gate here. In-game the engine drives its
    // render from inside Lua, so wglSwapBuffers fires at nest depth > 0 (seen:
    // nest=3); requiring 0 meant the overlay only ever drew at the menu. The
    // swap point is a fixed end-of-frame location, safe to draw from at any
    // nesting. We call orig_lua_pcallk (balanced getglobal+pcall) on the main
    // thread only, holding the cross-thread mutex — the worker-thread frame
    // tick can't collide (it still requires nest==0), and g_in_render blocks
    // our own reentrancy.
    if (g_render_armed && !g_in_render
        && g_L && api.getglobal && (orig_lua_pcallk || api.pcall)
        && g_main_tid != 0 && GetCurrentThreadId() == g_main_tid
        && lua_entry_try_acquire()) {   // serialize vs worker-thread frame tick
        g_in_render = true;
        // Set a fixed 320x240 ortho on a 4:3 letterboxed viewport so the
        // overlay is the same size/position at any window size. DrawText's
        // texture/blend state at swap time already works (the probe rendered);
        // only the projection needed fixing.
        mp_load_gl();
        bool gl_ok = false;
        if (g_gl_loaded) {
            int w = 0, h = 0;
            HWND hw = g_our_hwnd ? g_our_hwnd : find_our_hwnd();
            RECT rc;
            if (hw && GetClientRect(hw, &rc)) { w = rc.right - rc.left; h = rc.bottom - rc.top; }
            if (w > 0 && h > 0) {
                int vw, vh, vx, vy;
                if (w * 3 >= h * 4) { vh = h; vw = h * 4 / 3; vx = (w - vw) / 2; vy = 0; }
                else                { vw = w; vh = w * 3 / 4; vx = 0; vy = (h - vh) / 2; }
                p_glMatrixMode(MP_GL_PROJECTION); p_glPushMatrix(); p_glLoadIdentity();
                p_glOrtho(0.0, 320.0, 240.0, 0.0, -1.0, 1.0);
                p_glMatrixMode(MP_GL_MODELVIEW);  p_glPushMatrix(); p_glLoadIdentity();
                p_glViewport(vx, vy, vw, vh);
                // Painter's order for the overlay (backdrop behind, text on top).
                p_glDisable(MP_GL_DEPTH_TEST);
                // Game-over backdrop: erase the finished frame to black here, then
                // the scoreboard DrawText below draws on top of the black.
                if (g_gameover_bg) {
                    p_glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
                    p_glClear(MP_GL_COLOR_BUFFER_BIT);
                }
                gl_ok = true;
            }
        }
        api.getglobal(g_L, "MP_RENDER");
        int rc = orig_lua_pcallk
            ? orig_lua_pcallk(g_L, 0, 0, 0, 0, nullptr)
            : api.pcall(g_L, 0, 0, 0, 0, nullptr);
        if (rc != 0) {
            const char* err = api.tolstring(g_L, -1, nullptr);
            static int s_n = 0;
            if ((s_n++ % 200) == 0) host_log("MP_RENDER error (#%d): %s", s_n, err ? err : "?");
            api.settop(g_L, -2);
        }
        if (gl_ok) {
            p_glEnable(MP_GL_DEPTH_TEST);   // restore for the engine's next frame
            p_glMatrixMode(MP_GL_PROJECTION); p_glPopMatrix();
            p_glMatrixMode(MP_GL_MODELVIEW);  p_glPopMatrix();
        }
        g_in_render = false;
        lua_entry_release();
    }
    g_begin2d_cleared = false;   // re-arm the per-frame black clear for next frame
    return orig_wglSwapBuffers(hdc);
}

// arm_render() — install the wglSwapBuffers hook (once) and enable MP_RENDER.
static int l_arm_render(lua_State* L) {
    if (!orig_wglSwapBuffers) {
        HMODULE gl = GetModuleHandleA("opengl32.dll");
        if (!gl) gl = LoadLibraryA("opengl32.dll");
        void* target = gl ? (void*)GetProcAddress(gl, "wglSwapBuffers") : nullptr;
        if (!target) { host_log("arm_render: wglSwapBuffers not found"); api.pushboolean(L, 0); return 1; }
        MH_STATUS s = MH_CreateHook(target, (LPVOID)&hook_wglSwapBuffers, (LPVOID*)&orig_wglSwapBuffers);
        host_log("MH_CreateHook(wglSwapBuffers @%p): status=%d", target, s);
        if (s != MH_OK) { api.pushboolean(L, 0); return 1; }
        s = MH_EnableHook(target);
        host_log("MH_EnableHook(wglSwapBuffers): status=%d", s);
        if (s != MH_OK) { api.pushboolean(L, 0); return 1; }
    }
    // Also hook the 2D-UI ortho setup so we can black the world behind the
    // game-over screen. Address is static (exe base 0x400000, no ASLR).
    if (!orig_begin2d) {
        // base + RVA (0x4b56d0 - 0x400000) to survive ASLR, like the other hooks.
        void* target = (void*)((BYTE*)GetModuleHandleA(NULL) + 0xb56d0);
        MH_STATUS s = MH_CreateHook(target, (LPVOID)&hook_begin2d, (LPVOID*)&orig_begin2d);
        host_log("MH_CreateHook(begin2d @%p): status=%d", target, s);
        if (s == MH_OK) {
            s = MH_EnableHook(target);
            host_log("MH_EnableHook(begin2d): status=%d", s);
        }
    }
    g_render_armed = true;
    host_log("arm_render: MP_RENDER armed");
    api.pushboolean(L, 1);
    return 1;
}

// set_gameover_bg(bool) — when true, the begin2d hook clears the framebuffer to
// black once per frame (the game-over screen's backdrop).
static int l_set_gameover_bg(lua_State* L) {
    typedef int (*LuaToBoolFn)(lua_State*, int);
    static LuaToBoolFn lua_toboolean_p = nullptr;
    if (!lua_toboolean_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_toboolean_p = (LuaToBoolFn)GetProcAddress(lm, "lua_toboolean");
    }
    g_gameover_bg = lua_toboolean_p ? (lua_toboolean_p(L, 1) != 0) : false;
    if (!g_gameover_bg) g_gameover_dismiss = false;   // clear stale dismiss on hide
    host_log("set_gameover_bg(%d)", g_gameover_bg ? 1 : 0);
    api.pushboolean(L, 1);
    return 1;
}

// consume_gameover_dismiss() — atomic read+clear of the "ESC while game-over
// screen up" flag. Lua polls this to hide the screen.
static int l_consume_gameover_dismiss(lua_State* L) {
    bool was = g_gameover_dismiss;
    g_gameover_dismiss = false;
    api.pushboolean(L, was ? 1 : 0);
    return 1;
}

static int l_disarm_frame_tick(lua_State* L) {
    g_frame_tick_armed = false;
    api.pushboolean(L, 1);
    return 1;
}

// inject_esc() — post ESC keydown+keyup to OUR PROCESS's main window
// via PostMessageA. PostMessage targets a specific HWND and bypasses
// focus requirements, so when the host clicks Kick the resulting
// injection on the joiner's process still lands in the joiner's
// window (SendInput would route to whatever window has system focus,
// usually the host's). Pass-through counter prevents our own
// suppression hook from eating these events.
static int l_inject_esc(lua_State* L) {
    HWND h = find_our_hwnd();
    if (!h) {
        host_log("inject_esc: could not find our top-level window");
        api.pushboolean(L, 0);
        return 1;
    }
    g_pass_esc_count = 2;        // exactly: our keydown + keyup
    PostMessageA(h, WM_KEYDOWN, VK_ESCAPE, 0x00010001);
    PostMessageA(h, WM_KEYUP,   VK_ESCAPE, 0xC0010001);
    host_log("inject_esc: posted ESC to hwnd=%p", h);
    api.pushboolean(L, 1);
    return 1;
}

// simulate_esc() — fire an ESC keystroke via SendInput so it appears in
// the system keyboard buffer. Unlike inject_esc (PostMessage), this
// reaches DirectInput, which is how Teleglitch reads keys at gameplay
// time. Used to force the engine to pause from Lua (e.g. after a
// mid-game kick). Caller MUST own foreground focus — SendInput targets
// the focused window. Pass-through count is bumped so our own kbd_ll /
// PeekMessageA hooks don't swallow the event.
static int l_simulate_esc(lua_State* L) {
    g_pass_esc_count = 2;
    INPUT inputs[2] = {0};
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wVk = VK_ESCAPE;
    inputs[0].ki.wScan = MapVirtualKeyA(VK_ESCAPE, MAPVK_VK_TO_VSC);
    inputs[0].ki.dwFlags = 0;
    inputs[1].type = INPUT_KEYBOARD;
    inputs[1].ki.wVk = VK_ESCAPE;
    inputs[1].ki.wScan = MapVirtualKeyA(VK_ESCAPE, MAPVK_VK_TO_VSC);
    inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;
    UINT sent = SendInput(2, inputs, sizeof(INPUT));
    host_log("simulate_esc: SendInput sent=%u (of 2)", sent);
    api.pushboolean(L, 1);
    return 1;
}

// set_esc_leaves_lobby(bool) — when true, the hook records ESC keydowns
// into g_esc_pressed (and swallows the message). The Lua tick polls
// via check_esc_pressed() and triggers lobby_leave_room.
static int l_set_esc_leaves_lobby(lua_State* L) {
    typedef int (*LuaToBoolFn)(lua_State*, int);
    static LuaToBoolFn lua_toboolean_p = nullptr;
    if (!lua_toboolean_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_toboolean_p = (LuaToBoolFn)GetProcAddress(lm, "lua_toboolean");
    }
    int on = lua_toboolean_p ? lua_toboolean_p(L, 1) : 0;
    g_esc_leaves_lobby = (on != 0);
    if (!g_esc_leaves_lobby) g_esc_pressed = false;
    host_log("set_esc_leaves_lobby(%d)", g_esc_leaves_lobby ? 1 : 0);
    api.pushboolean(L, 1);
    return 1;
}

// check_esc_pressed() — atomic read+clear. Returns true if ESC was
// pressed since the last call. Used by the Lua tick to act on ESC in
// the lobby waiting room.
static int l_check_esc_pressed(lua_State* L) {
    bool was = g_esc_pressed;
    g_esc_pressed = false;
    if (was) host_log("check_esc_pressed -> TRUE (leaves_lobby=%d quits=%d suppress=%d)",
                      g_esc_leaves_lobby ? 1 : 0, g_esc_quits ? 1 : 0, g_suppress_esc ? 1 : 0);
    api.pushboolean(L, was ? 1 : 0);
    return 1;
}

// consume_testkey() — atomic read+clear of the KP* test-hotkey flag. Lua polls
// this from the menu tick (input.KeyDown doesn't reach Lua at the title menu).
static int l_consume_testkey(lua_State* L) {
    bool was = g_testkey_pressed;
    g_testkey_pressed = false;
    api.pushboolean(L, was ? 1 : 0);
    return 1;
}

// set_chat_capture(bool) — arm/disarm chat key capture. While armed,
// kbd_ll_proc swallows all keys (engine sees no input) and records typed
// chars into g_chat_ring. On arm we discard any stray queued keys and reset
// shift so the box starts clean.
static int l_set_chat_capture(lua_State* L) {
    typedef int (*LuaToBoolFn)(lua_State*, int);
    static LuaToBoolFn lua_toboolean_p = nullptr;
    if (!lua_toboolean_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_toboolean_p = (LuaToBoolFn)GetProcAddress(lm, "lua_toboolean");
    }
    int on = lua_toboolean_p ? lua_toboolean_p(L, 1) : 0;
    g_chat_capture = (on != 0);
    if (g_chat_capture) {
        g_chat_read_idx = g_chat_write_idx;  // drop anything queued before open
        g_chat_shift = false;
    }
    host_log("set_chat_capture(%d)", g_chat_capture ? 1 : 0);
    api.pushboolean(L, 1);
    return 1;
}

// consume_chat_key() — drain one captured key. Returns the ASCII/control code
// as a number, or nil when the ring is empty. The Lua tick loops until nil.
static int l_consume_chat_key(lua_State* L) {
    if (g_chat_read_idx >= g_chat_write_idx) { api.pushnil(L); return 1; }
    int c = g_chat_ring[g_chat_read_idx % CHAT_RING_SIZE];
    g_chat_read_idx++;
    static LuaPushNumberFn lua_pushnumber_p = nullptr;
    if (!lua_pushnumber_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_pushnumber_p = (LuaPushNumberFn)GetProcAddress(lm, "lua_pushnumber");
    }
    lua_pushnumber_p(L, (double)c);
    return 1;
}

// mp_inflate(deflated_bytes, uncompressed_len) -> string | nil
// Raw-DEFLATE decompress (matches Node's zlib.deflateRaw on the relay). The
// caller passes the exact uncompressed length (the relay prefixes it on the
// wire) so we allocate once — no dynamic growth. Returns nil on any error so
// the Lua side can drop the frame instead of crashing. Bounded to 16 MB to
// stop a malformed/hostile frame from exhausting memory.
#define MP_INFLATE_MAX (16u * 1024u * 1024u)
static int l_mp_inflate(lua_State* L) {
    typedef int (*LuaToIntegerFn)(lua_State*, int, int*);
    typedef void (*LuaPushLStringFn)(lua_State*, const char*, size_t);
    static LuaToIntegerFn   lua_tointeger_p  = nullptr;
    static LuaPushLStringFn lua_pushlstring_p = nullptr;
    if (!lua_tointeger_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_tointeger_p   = (LuaToIntegerFn)GetProcAddress(lm, "lua_tointegerx");
        lua_pushlstring_p = (LuaPushLStringFn)GetProcAddress(lm, "lua_pushlstring");
    }
    if (!lua_tointeger_p || !lua_pushlstring_p) { api.pushnil(L); return 1; }

    size_t srclen = 0;
    const char* src = api.tolstring(L, 1, &srclen);
    long ulen_signed = lua_tointeger_p(L, 2, nullptr);
    if (!src || ulen_signed < 0 || (unsigned long)ulen_signed > MP_INFLATE_MAX) {
        api.pushnil(L); return 1;
    }
    unsigned long ulen = (unsigned long)ulen_signed;
    if (ulen == 0) { lua_pushlstring_p(L, "", 0); return 1; }

    unsigned char* dest = (unsigned char*)malloc(ulen);
    if (!dest) { api.pushnil(L); return 1; }
    unsigned long destlen = ulen;        // available space (in) / written (out)
    unsigned long sourcelen = (unsigned long)srclen;
    int r = puff(dest, &destlen, (const unsigned char*)src, &sourcelen);
    if (r == 0 && destlen == ulen) {
        lua_pushlstring_p(L, (const char*)dest, destlen);
    } else {
        host_log("mp_inflate: puff failed r=%d destlen=%lu ulen=%lu srclen=%lu",
                 r, destlen, ulen, (unsigned long)srclen);
        api.pushnil(L);
    }
    free(dest);
    return 1;
}

// set_esc_opens_mp_pause(bool) — armed by Lua during in-game MP. Same
// swallow + latch as g_esc_leaves_lobby; the Lua tick dispatches on
// mp.in_game to open mp_pause instead of leaving the lobby.
static int l_set_esc_opens_mp_pause(lua_State* L) {
    typedef int (*LuaToBoolFn)(lua_State*, int);
    static LuaToBoolFn lua_toboolean_p = nullptr;
    if (!lua_toboolean_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_toboolean_p = (LuaToBoolFn)GetProcAddress(lm, "lua_toboolean");
    }
    int on = lua_toboolean_p ? lua_toboolean_p(L, 1) : 0;
    g_esc_opens_mp_pause = (on != 0);
    if (!g_esc_opens_mp_pause && !g_esc_leaves_lobby) g_esc_pressed = false;
    host_log("set_esc_opens_mp_pause(%d)", g_esc_opens_mp_pause ? 1 : 0);
    api.pushboolean(L, 1);
    return 1;
}

// set_esc_quits(bool) — when true, ESC keypresses (after the
// pass-through count has drained) get translated into WM_CLOSE so
// the engine cleanly exits. Used for the mp_kicked notification page.
static int l_set_esc_quits(lua_State* L) {
    typedef int (*LuaToBoolFn)(lua_State*, int);
    static LuaToBoolFn lua_toboolean_p = nullptr;
    if (!lua_toboolean_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_toboolean_p = (LuaToBoolFn)GetProcAddress(lm, "lua_toboolean");
    }
    int on = lua_toboolean_p ? lua_toboolean_p(L, 1) : 0;
    g_esc_quits = (on != 0);
    host_log("set_esc_quits(%d)", g_esc_quits ? 1 : 0);
    api.pushboolean(L, 1);
    return 1;
}

// set_suppress_esc(bool) — when true, the per-frame PeekMessageA hook
// rewrites every VK_ESCAPE message to WM_NULL so the engine never sees
// it. Used after MP Disconnect/kick to stop the user from toggling
// back into the still-loaded MP level. Re-enable (pass false) when the
// user genuinely enters a new game so they can pause normally again.
static int l_set_suppress_esc(lua_State* L) {
    typedef int (*LuaToBoolFn)(lua_State*, int);
    static LuaToBoolFn lua_toboolean_p = nullptr;
    if (!lua_toboolean_p) {
        HMODULE lm = GetModuleHandleA("lua52.dll");
        lua_toboolean_p = (LuaToBoolFn)GetProcAddress(lm, "lua_toboolean");
    }
    int on = lua_toboolean_p ? lua_toboolean_p(L, 1) : 0;
    g_suppress_esc = (on != 0);
    // When enabling, hard-clear any leftover pass-through count so a
    // stale inject_esc credit can't sneak a real ESC through after we
    // arm suppression.
    if (g_suppress_esc) g_pass_esc_count = 0;
    host_log("set_suppress_esc(%d) pass_count=%d", g_suppress_esc ? 1 : 0, g_pass_esc_count);
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
    g_main_tid = GetCurrentThreadId();
    host_log("luaopen_mp_native: L=%p main_tid=%lu api resolved", (void*)L, g_main_tid);

    // Initialize MinHook once; safe to call multiple times.
    MH_Initialize();

    // Hook the two engine→Lua entry points (lua_resume + lua_pcallk).
    // Both bump g_lua_nest_depth at entry and decrement at exit; when
    // the depth returns to 0 after a top-level call we piggy-back
    // MP_FRAME_TICK on the same (main) thread.
    {
        HMODULE lua = GetModuleHandleA("lua52.dll");
        FARPROC pResume  = lua ? GetProcAddress(lua, "lua_resume")  : nullptr;
        FARPROC pPcallk  = lua ? GetProcAddress(lua, "lua_pcallk")  : nullptr;
        if (pResume) {
            MH_STATUS st = MH_CreateHook((LPVOID)pResume,
                                         (LPVOID)hook_lua_resume,
                                         (LPVOID*)&orig_lua_resume);
            host_log("lua_resume hook @%p: status=%d", (void*)pResume, (int)st);
            if (st == MH_OK) MH_EnableHook((LPVOID)pResume);
        } else {
            host_log("lua_resume hook: lua_resume not found");
        }
        if (pPcallk) {
            MH_STATUS st = MH_CreateHook((LPVOID)pPcallk,
                                         (LPVOID)hook_lua_pcallk,
                                         (LPVOID*)&orig_lua_pcallk);
            host_log("lua_pcallk hook @%p: status=%d", (void*)pPcallk, (int)st);
            if (st == MH_OK) MH_EnableHook((LPVOID)pPcallk);
        } else {
            host_log("lua_pcallk hook: lua_pcallk not found");
        }
    }

    // Build a table of native functions. Size the hash part for the EXACT field
    // count (18) up front: an under-sized hint (was 0,4) makes lua52 luaH_resize/
    // realloc the table's array repeatedly mid-population, and under full page heap
    // those guard-paged grows turn lua52's trailing TValue write into a hard fault
    // (the recurring heap corruptor — see KNOWN_ISSUES.md). 18 = the field count below.
    api.createtable(L, 0, 80);   // MUST be >= the number of setfields below;
                                 // under-hinting reallocs mid-build → heap corruption
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
    api.pushcclosure(L, l_set_ff_watch_player, 0);
    api.setfield(L, -2, "set_ff_watch_player");
    api.pushcclosure(L, l_set_body_sensor, 0);
    api.setfield(L, -2, "set_body_sensor");
    api.pushcclosure(L, l_install_central_hit_hook, 0);
    api.setfield(L, -2, "install_central_hit_hook");
    api.pushcclosure(L, l_install_takedmg2_hook, 0);
    api.setfield(L, -2, "install_takedmg2_hook");
    api.pushcclosure(L, l_consume_bullet, 0);
    api.setfield(L, -2, "consume_bullet");
    api.pushcclosure(L, l_swap_bullet_subclass, 0);
    api.setfield(L, -2, "swap_bullet_subclass");
    api.pushcclosure(L, l_create_tlaser, 0);
    api.setfield(L, -2, "create_tlaser");
    api.pushcclosure(L, l_create_adhgrenade, 0);
    api.setfield(L, -2, "create_adhgrenade");
    api.pushcclosure(L, l_create_cannon, 0);
    api.setfield(L, -2, "create_cannon");
    api.pushcclosure(L, l_mark_laser_dead, 0);
    api.setfield(L, -2, "mark_laser_dead");
    api.pushcclosure(L, l_lmb_pressed, 0);
    api.setfield(L, -2, "lmb_pressed");
    api.pushcclosure(L, l_lmb_state, 0);
    api.setfield(L, -2, "lmb_state");
    api.pushcclosure(L, l_refresh_tlaser, 0);
    api.setfield(L, -2, "refresh_tlaser");
    api.pushcclosure(L, l_kill_actor, 0);
    api.setfield(L, -2, "kill_actor");
    api.pushcclosure(L, l_apply_damage, 0);
    api.setfield(L, -2, "apply_damage");
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
    api.pushcclosure(L, l_read_hp, 0);
    api.setfield(L, -2, "read_hp");
    api.pushcclosure(L, l_set_local_player, 0);
    api.setfield(L, -2, "set_local_player");
    api.pushcclosure(L, l_get_local_player, 0);
    api.setfield(L, -2, "get_local_player");
    api.pushcclosure(L, l_pin_angle, 0);
    api.setfield(L, -2, "pin_angle");
    api.pushcclosure(L, l_consume_bomb, 0);
    api.setfield(L, -2, "consume_bomb");
    api.pushcclosure(L, l_arm_bomb, 0);
    api.setfield(L, -2, "arm_bomb");
    api.pushcclosure(L, l_activate_bomb, 0);
    api.setfield(L, -2, "activate_bomb");
    api.pushcclosure(L, l_read_fuse, 0);
    api.setfield(L, -2, "read_fuse");
    api.pushcclosure(L, l_validate_vtable, 0);
    api.setfield(L, -2, "validate_vtable");
    api.pushcclosure(L, l_set_invulnerable, 0);
    api.setfield(L, -2, "set_invulnerable");
    api.pushcclosure(L, l_set_body_kinematic, 0);
    api.setfield(L, -2, "set_body_kinematic");
    api.pushcclosure(L, l_set_body_dynamic, 0);
    api.setfield(L, -2, "set_body_dynamic");
    api.pushcclosure(L, l_set_fire_gate, 0);
    api.setfield(L, -2, "set_fire_gate");
    api.pushcclosure(L, l_set_render_gate, 0);
    api.setfield(L, -2, "set_render_gate");
    api.pushcclosure(L, l_set_hud_allowed_puppet, 0);
    api.setfield(L, -2, "set_hud_allowed_puppet");
    api.pushcclosure(L, l_set_body_velocity, 0);
    api.setfield(L, -2, "set_body_velocity");
    api.pushcclosure(L, l_register_puppet, 0);
    api.setfield(L, -2, "register_puppet");
    api.pushcclosure(L, l_unregister_puppet, 0);
    api.setfield(L, -2, "unregister_puppet");
    api.pushcclosure(L, l_probe_memory, 0);
    api.setfield(L, -2, "probe_memory");
    api.pushcclosure(L, l_set_button_label, 0);
    api.setfield(L, -2, "set_button_label");
    api.pushcclosure(L, l_arm_frame_tick, 0);
    api.setfield(L, -2, "arm_frame_tick");
    api.pushcclosure(L, l_disarm_frame_tick, 0);
    api.setfield(L, -2, "disarm_frame_tick");
    api.pushcclosure(L, l_set_suppress_esc, 0);
    api.setfield(L, -2, "set_suppress_esc");
    api.pushcclosure(L, l_inject_esc, 0);
    api.setfield(L, -2, "inject_esc");
    api.pushcclosure(L, l_simulate_esc, 0);
    api.setfield(L, -2, "simulate_esc");
    api.pushcclosure(L, l_set_esc_quits, 0);
    api.setfield(L, -2, "set_esc_quits");
    api.pushcclosure(L, l_set_esc_leaves_lobby, 0);
    api.setfield(L, -2, "set_esc_leaves_lobby");
    api.pushcclosure(L, l_set_esc_opens_mp_pause, 0);
    api.setfield(L, -2, "set_esc_opens_mp_pause");
    api.pushcclosure(L, l_check_esc_pressed, 0);
    api.setfield(L, -2, "check_esc_pressed");
    api.pushcclosure(L, l_consume_testkey, 0);
    api.setfield(L, -2, "consume_testkey");
    api.pushcclosure(L, l_arm_render, 0);
    api.setfield(L, -2, "arm_render");
    api.pushcclosure(L, l_set_gameover_bg, 0);
    api.setfield(L, -2, "set_gameover_bg");
    api.pushcclosure(L, l_consume_gameover_dismiss, 0);
    api.setfield(L, -2, "consume_gameover_dismiss");
    api.pushcclosure(L, l_set_chat_capture, 0);
    api.setfield(L, -2, "set_chat_capture");
    api.pushcclosure(L, l_consume_chat_key, 0);
    api.setfield(L, -2, "consume_chat_key");
    api.pushcclosure(L, l_mp_inflate, 0);
    api.setfield(L, -2, "mp_inflate");
    return 1;  // return the table
}

// Vectored exception handler — fires BEFORE SEH (which the CRT / Lua may
// hijack) on EVERY exception including first-chance. We filter to the codes
// that mean "we crashed", log, then chain. SetUnhandledExceptionFilter alone
// missed our AV — likely the CRT installed its own filter or the exception
// is RaiseFailFastException which bypasses unhandled filters by design.
//
// Filter heuristic: only the bad ones. C++ exceptions, breakpoint asserts,
// and SEH unwind targets will be skipped. Stack overflow gets a partial dump
// (filter runs on the broken stack but we'll get EIP at least).
static volatile LONG g_in_filter = 0;
static LONG WINAPI mp_unhandled_filter(EXCEPTION_POINTERS* ep) {
    if (!ep || !ep->ExceptionRecord || !ep->ContextRecord) return EXCEPTION_CONTINUE_SEARCH;
    EXCEPTION_RECORD* er = ep->ExceptionRecord;
    DWORD c = er->ExceptionCode;
    bool is_crash = (c == EXCEPTION_ACCESS_VIOLATION)
                 || (c == EXCEPTION_STACK_OVERFLOW)
                 || (c == EXCEPTION_ILLEGAL_INSTRUCTION)
                 || (c == EXCEPTION_PRIV_INSTRUCTION)
                 || (c == EXCEPTION_INT_DIVIDE_BY_ZERO)
                 || (c == 0xC0000409)  // STATUS_STACK_BUFFER_OVERRUN / __fastfail
                 || (c == 0xC0000374); // STATUS_HEAP_CORRUPTION
    if (!is_crash) return EXCEPTION_CONTINUE_SEARCH;
    // Recursion guard. If our own handler faults, we don't want to spiral.
    if (InterlockedExchange(&g_in_filter, 1) != 0) return EXCEPTION_CONTINUE_SEARCH;
    CONTEXT* ctx = ep->ContextRecord;
    HMODULE tg = GetModuleHandleA(NULL);
    DWORD_PTR base = (DWORD_PTR)tg;
    DWORD_PTR eip = (DWORD_PTR)er->ExceptionAddress;
    DWORD_PTR rel = (eip >= base && eip < base + 0x800000) ? (eip - base) : 0;
    const char* code_name = "?";
    switch (er->ExceptionCode) {
        case EXCEPTION_ACCESS_VIOLATION:    code_name = "ACCESS_VIOLATION"; break;
        case EXCEPTION_STACK_OVERFLOW:      code_name = "STACK_OVERFLOW"; break;
        case EXCEPTION_INT_DIVIDE_BY_ZERO:  code_name = "DIV0"; break;
        case EXCEPTION_PRIV_INSTRUCTION:    code_name = "PRIV_INSTR"; break;
        case EXCEPTION_ILLEGAL_INSTRUCTION: code_name = "ILLEGAL_INSTR"; break;
    }
    host_log("==== EXCEPTION %s code=0x%08lx ====", code_name, er->ExceptionCode);
    // Identify which module EIP is in. GetModuleHandleEx with the address
    // returns the module's HMODULE. If EIP is inside Teleglitch.exe show
    // the RVA; otherwise show the module name + offset within it.
    HMODULE eip_mod = NULL;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                       | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       (LPCSTR)eip, &eip_mod);
    char modname[MAX_PATH] = "(unknown)";
    if (eip_mod) {
        char path[MAX_PATH];
        if (GetModuleFileNameA(eip_mod, path, MAX_PATH)) {
            const char* fn = strrchr(path, '\\');
            if (!fn) fn = strrchr(path, '/');
            snprintf(modname, sizeof(modname), "%s", fn ? fn + 1 : path);
        }
        DWORD_PTR mod_off = eip - (DWORD_PTR)eip_mod;
        host_log("  EIP=%p  (%s+0x%lx)", (void*)eip, modname, (unsigned long)mod_off);
    } else {
        host_log("  EIP=%p  (no module — heap/jit?)", (void*)eip);
    }
    if (er->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && er->NumberParameters >= 2) {
        const char* op = (er->ExceptionInformation[0] == 0) ? "READ"
                       : (er->ExceptionInformation[0] == 1) ? "WRITE"
                       : (er->ExceptionInformation[0] == 8) ? "DEP" : "?";
        host_log("  fault: %s addr=%p", op, (void*)er->ExceptionInformation[1]);
    }
    host_log("  EAX=%08lx  EBX=%08lx  ECX=%08lx  EDX=%08lx",
        ctx->Eax, ctx->Ebx, ctx->Ecx, ctx->Edx);
    host_log("  ESI=%08lx  EDI=%08lx  EBP=%08lx  ESP=%08lx",
        ctx->Esi, ctx->Edi, ctx->Ebp, ctx->Esp);
    // Walk the stack via EBP frames (works for non-fpo code). Print up to 16
    // return addresses, mapped relative to Teleglitch.exe when in range.
    host_log("  stack walk (EBP chain):");
    DWORD_PTR ebp = ctx->Ebp;
    for (int i = 0; i < 16; ++i) {
        if (ebp == 0 || IsBadReadPtr((void*)ebp, 8)) break;
        DWORD_PTR ret = *(DWORD_PTR*)(ebp + 4);
        DWORD_PTR next_ebp = *(DWORD_PTR*)ebp;
        DWORD_PTR rret = (ret >= base && ret < base + 0x800000) ? (ret - base) : 0;
        host_log("    [%d] ret=%p  (Teleglitch.exe+0x%08lx)", i, (void*)ret, (unsigned long)rret);
        if (next_ebp <= ebp) break;  // sanity: frames grow toward higher addresses
        ebp = next_ebp;
    }
    // Also walk a small slice of the raw stack as a backup if EBP is FPO'd.
    host_log("  raw ESP+0..+16 returns:");
    DWORD_PTR esp = ctx->Esp;
    for (int i = 0; i < 16; ++i) {
        DWORD_PTR addr = esp + i * 4;
        if (IsBadReadPtr((void*)addr, 4)) break;
        DWORD_PTR v = *(DWORD_PTR*)addr;
        if (v >= base && v < base + 0x800000) {
            host_log("    esp+%02d = %p  (Teleglitch.exe+0x%08lx)",
                i*4, (void*)v, (unsigned long)(v - base));
        }
    }
    host_log("==== END EXCEPTION ====");
    if (g_log) { fflush(g_log); }
    InterlockedExchange(&g_in_filter, 0);
    return EXCEPTION_CONTINUE_SEARCH;  // let the OS terminate normally
}

// Stack-walk helper used by both the SEH filter and the exit hooks. Logs
// up to 16 EBP-chain frames mapped relative to Teleglitch.exe (paste those
// addresses straight into Ghidra). Caller passes a starting EBP — either
// the exception context's, or a fresh __builtin_frame_address(0).
static void log_stack_walk_from_ebp(DWORD_PTR ebp, DWORD_PTR base, const char* tag) {
    host_log("  %s stack walk (EBP=%p):", tag, (void*)ebp);
    for (int i = 0; i < 16; ++i) {
        if (ebp == 0 || IsBadReadPtr((void*)ebp, 8)) break;
        DWORD_PTR ret = *(DWORD_PTR*)(ebp + 4);
        DWORD_PTR next_ebp = *(DWORD_PTR*)ebp;
        DWORD_PTR rret = (ret >= base && ret < base + 0x800000) ? (ret - base) : 0;
        host_log("    [%d] ret=%p  (Teleglitch.exe+0x%08lx)",
            i, (void*)ret, (unsigned long)rret);
        if (next_ebp <= ebp) break;
        ebp = next_ebp;
    }
}

typedef VOID (WINAPI *ExitProcessFn)(UINT);
typedef BOOL (WINAPI *TerminateProcessFn)(HANDLE, UINT);
static ExitProcessFn orig_ExitProcess = nullptr;
static TerminateProcessFn orig_TerminateProcess = nullptr;
static VOID WINAPI hook_ExitProcess(UINT code) {
    DWORD_PTR base = (DWORD_PTR)GetModuleHandleA(NULL);
    host_log("==== ExitProcess(%u) called ====", code);
    DWORD_PTR ebp;
    asm volatile("movl %%ebp, %0" : "=r"(ebp));
    log_stack_walk_from_ebp(ebp, base, "ExitProcess");
    host_log("==== END ExitProcess ====");
    if (g_log) fflush(g_log);
    if (orig_ExitProcess) orig_ExitProcess(code);
    else ExitProcess(code);
}
static BOOL WINAPI hook_TerminateProcess(HANDLE proc, UINT code) {
    if (proc == GetCurrentProcess() || proc == (HANDLE)-1) {
        DWORD_PTR base = (DWORD_PTR)GetModuleHandleA(NULL);
        host_log("==== TerminateProcess(self, %u) called ====", code);
        DWORD_PTR ebp;
        asm volatile("movl %%ebp, %0" : "=r"(ebp));
        log_stack_walk_from_ebp(ebp, base, "TerminateProcess");
        host_log("==== END TerminateProcess ====");
        if (g_log) fflush(g_log);
    }
    return orig_TerminateProcess ? orig_TerminateProcess(proc, code) : TerminateProcess(proc, code);
}
static void install_exit_hooks() {
    HMODULE k = GetModuleHandleA("kernel32.dll");
    if (!k) return;
    void* ep = (void*)GetProcAddress(k, "ExitProcess");
    void* tp = (void*)GetProcAddress(k, "TerminateProcess");
    if (ep) {
        if (MH_CreateHook(ep, (LPVOID)&hook_ExitProcess, (LPVOID*)&orig_ExitProcess) == MH_OK)
            MH_EnableHook(ep);
    }
    if (tp) {
        if (MH_CreateHook(tp, (LPVOID)&hook_TerminateProcess, (LPVOID*)&orig_TerminateProcess) == MH_OK)
            MH_EnableHook(tp);
    }
    host_log("dllhost: exit hooks installed");
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

        // SEH UEF + VEH + exit hooks. Belt-and-suspenders coverage:
        //   - VEH catches first-chance AVs and fail-fast (the latter bypasses
        //     SEH entirely). Recursion-guarded so it can't trip on its own
        //     log code.
        //   - UEF is the second-chance net. We re-arm it from PeekMessageA
        //     so any late writer (engine / lua52 / a plugin) gets overwritten.
        //   - ExitProcess/TerminateProcess hooks catch abort()/exit() paths
        //     that don't go through an exception at all.
        AddVectoredExceptionHandler(1, mp_unhandled_filter);
        SetUnhandledExceptionFilter(mp_unhandled_filter);
        host_log("dllhost: vectored + unhandled exception filters installed");
        install_exit_hooks();

        load_native_mods();
    }
    return TRUE;
}
