# Known Issues

## 🟡 Weapon-subclass replication gap (2026-06-17)

`Lua CreateBullet` always spawns the base `TBullet`. For weapons whose
bullettype is cannon/explode/nails/railgun, replicated shots on the
receiver appear as plain bullets — no nail-trail visual, no explosion on
impact, no railgun pierce. Damage value is correct (we capture the
ctor's a5 directly), only the subclass behavior is missing.

**Fix path:** hook subclass ctors (`TCannonBullet` 0x558454,
`TExplodingBullet` 0x558384, `TNail` 0x55831c — vtable addresses per
teleglitch-engine-internals.md; ctor offsets need Ghidra), expose native
`CreateNail` / `CreateCannonBullet` / `CreateExpl` bindings, thread
`subclass` through the `bullet_fire` message, dispatch on receive.

## 🟡 Shotgun (5-pellet rapid fire) crashes remote client (2026-06-17)

Repro: one player aims+fires a shotgun (`pump`, `bulletcount=5`),
remote player's client AVs. Stack signature: ntdll heap (`0x591a8`
`RtlpValidateHeapEntry`) → lua52.dll (`0x26a9b`). Same shape as the
heap corruptor in task #2 — the 5-rapid-bullet path stresses the same
corruption window. Not a new bug; just a new reproducer. Tie-in to
task #2's bisect.

## 🟡 Movement hitch introduced by spectate work (2026-06-17)

Holding a SINGLE movement direction (W/A/S/D) for several seconds causes a
semi-persistent ~1s hitch on live players. Does not occur when stationary or
when changing direction. Started with the spectate rework that added
`set_main_player` camera redirect, kinematic local body, fire/render/HUD
gates, and the `tick_death_intercept` poll from `net_tick_loop`.

Likely candidates to bisect:
- `hook_PHud` / `set_hud_allowed_puppet` running per-frame
- `set_main_player` redirect side effects in TPlayer think
- kinematic body interacting with sustained input
- `tick_death_intercept` alive-path doing something per tick

Files: `tick_death_intercept` (mods/mp_client/init.lua), `hook_PHud` /
`hook_PThink1` / `set_main_player` / `set_body_kinematic` /
`set_render_gate` / `set_fire_gate` (modloader/dllhost/main.cpp).

Not urgent — gameplay is otherwise solid.

## 🔴 Intermittent heap-corruption crash — NARROWED to the native bridge (2026-05-30)

**Symptom:** Joiner crashes intermittently (~every other join, and at startup under
page heap). Heap corruption; without page heap it surfaces late as
`MSVCR110!realloc -> lua52!luaL_gsub` (a Lua string/table realloc tripping over
already-corrupted heap metadata).

### MAJOR PROGRESS this session — bisected with FULL page heap
1. **Why prior page-heap attempts "couldn't find it":** they used **light** page
   heap (or it was never actually elevated). The crash dumps show
   `RtlpValidateHeapEntry`/`RtlDebugReAllocateHeap` (validate-at-realloc =
   light/standard), never a full guard-page fault. **Full page heap needs an
   ELEVATED reg import** — the HKLM IFEO key fails silently from a non-admin shell.
2. **Full page heap DOES work** (verified `!gflag` shows `hpa`). With
   `GlobalFlag=0x02000000, PageHeapFlags=0x3` (elevated) the crash is
   **deterministic at startup**. The engine allocates every object via the
   MSVCR110 CRT heap (no custom pool), so page heap can see it.
3. **The corruptor is in OUR MOD, not the base game.** Base game (mod disabled)
   runs clean under page heap; mod enabled crashes.
4. **It's the NATIVE BRIDGE (`version.dll`), not the Lua code.** Pure-Lua mod
   (native bridge disabled via `package.loadlib` -> nil) runs clean under page
   heap; loading the bridge crashes.
5. **Within the bridge it's `luaopen_mp_native`'s load-time work** — bisect:
   bridge-loaded-but-no-hooks-installed STILL crashes (intermittently), so it's
   `luaopen` itself (`lua_resolve_api` [clean] + `MH_Initialize` + the 18-entry
   Lua-C-API table build). Installing the MinHook hooks makes it **deterministic**
   (so MinHook aggravates / is likely the core).
6. **The corrupted block:** ~400 bytes (0x190) of NaN-boxed Lua TValues (lua52
   uses NaN-boxing, `7ff7a5xx` tags) — a Lua table array-part or stack — with a
   "corrupted start stamp" (`abcdbbbb`), i.e. a use-after-free/double-op or a
   buffer underrun. On the MSVCR110 heap.
7. **`ust` (GlobalFlag 0x02001000) MASKS it** -> layout-sensitive overrun (a
   Heisenbug). Use **plain** `0x02000000` to reproduce.

### Root cause (static + dump forensics, 2026-05-30, ~0.6 confidence)
Dump forensics (`!heap -s` = `HEAP_FAILURE_BUFFER_OVERRUN` on the MSVCR110 heap;
the smashed header is overwritten by a Lua value+tag `…7ff7a546`; faulting stack
is entirely `lua52`/`MSVCR110`/`ntdll` with **no version.dll/MinHook/UCRT frames**)
show the writer is **lua52 itself**, over-writing a TValue past an array end — NOT
a foreign cross-heap stomp from our DLL. The **trigger** is in `luaopen_mp_native`:
`createtable(L,0,4)` then **18** `setfield`s → lua52 reallocs the table array
repeatedly mid-population; under full page heap those guard-paged grows turn
lua52's normally-harmless trailing write into a hard fault. **MinHook makes it
deterministic** only by perturbing heap layout (not the writer). Caveat: the dump
caught the later *free* that detects the corruption, not the write itself, so the
exact site is inferred (hence 0.6).

### Fix ladder (apply cheapest first, test each under PLAIN page heap 5+ runs)
1. **APPLIED (2026-05-30):** `createtable(L,0,4)` → `createtable(L,0,18)` in
   main.cpp luaopen_mp_native — sizes the table once, no mid-build reallocs.
   Near-zero risk, correct regardless. **Needs verification under page heap.**
2. If still reproducing: move `MH_Initialize()` (and ideally the hook installs) out
   of `luaopen` into `DllMain`/`load_native_mods` so MinHook's heap/VirtualAlloc
   churn doesn't interleave with lua52's table realloc.
3. If still: reduce version.dll's load-time UCRT-heap footprint (host_log `fopen`
   FILE buffer; `std::set<void*> g_hooked_addrs`) — or rebuild version.dll
   freestanding (kernel32-only I/O via WriteFile, no `<stdio.h>`/`<set>`/UCRT) so
   it shares NO heap surface with lua52. (Heaviest; last resort.)
4. Harness: `cdb_pageheap.txt` now also catches `0xc0000409` (the verifier abort/
   fastfail) so the next reproduction actually saves `crash_ph.dmp`.

### Tooling built this session (reusable)
- `pageheap_capture.ps1` — self-elevating: enables full page heap, launches the
  joiner under cdb with `cdb_pageheap.txt`, captures the fault, **always disables
  page heap again** (try/finally). Run: `powershell -ExecutionPolicy Bypass -File
  pageheap_capture.ps1` (UAC).
- `cdb_pageheap.txt` — cdb script (verifier-stop capture or sxe av/heap-corruption).
- A Lua 5.2.2 `luac` for syntax-checking (rebuild from server-repo lua-5.2.2 src
  via WinLibs gcc).
- Bisect method: edit deployed `init.lua` to toggle (native bridge / individual
  hooks / `MH_Initialize`), run plain page heap, observe crash-vs-menu. Because
  it's intermittent, run each "clean" candidate 4-5+ times.

### Earlier (superseded) work
- `safe_delete()` liveness-gating (commit af3eff7) hardened real UAF/double-free
  hazards in the Lua item/puppet Delete paths — kept as defense-in-depth, but it
  was NOT this corruptor (this is native-bridge-side).
