# Known Issues

## 🟡 AGL grenade fuse drifts between firer and receiver (2026-06-19)

Networked AGL (`bullettypes.explode2` / TAdhesiveGrenade) explodes at
different wall-clock times on firer vs receiver. The longer the flight
before impact, the wider the gap. Firer behaves as if the fuse only
starts ticking after the grenade sticks; receiver fuses from spawn.

**What was tried:**
1. Lua-side fuse pre-advance (write `+0xB8 += 0.02..0.05` after ctor) —
   makes short-throw explosions misalign in the other direction; no
   single constant works because the firer's "fuse from impact"
   behavior makes the offset travel-time-dependent.
2. Native hook on vt[23] @ 0x495e20 (the per-tick fuse + movement
   step). Hook calls orig (so movement runs) then restores +0xB8 to
   its pre-call value whenever `vx*vx + vy*vy > 0.25` (still flying).
   Goal: receiver only fuses after impact, matching firer. Result:
   still mismatched — either the velocity gate isn't tight, or the
   firer's gate lives elsewhere (engine-side per-tick dispatch may
   skip vt[23] on flying grenades; we couldn't find it in vt[11] or
   FUN_00498f50).

**Where to look next:**
- Find the engine caller of vt[23] (search xrefs to vftable+0x5c on
  TAdhesiveGrenade) — there may be a "stuck" predicate gating the
  call that isn't visible from vt[23] alone.
- TAdhesiveGrenade `+0x6D` (set to 0 in ctor) — vt[11] case 0x10
  (wall hit) checks it before calling `FUN_0040e750(+0x2E = 1)`. Could
  be the "is stuck" flag.

For now: cosmetic. Grenades still explode and damage; just the visual
beat between two clients can be off by hundreds of ms.

## 🟡 Networked TLaser does almost no damage (2026-06-19)

Lasgun fired through the on/off replication protocol does ~0.2hp per
shot instead of the engine's 16hp. One clip = ~3hp instead of ~240hp.
Affects every path that goes through `create_tlaser` on the receiver:

| Firer | Target | Path                       | Damage |
|-------|--------|----------------------------|--------|
| Host  | Mob    | Host's local TLaser raycast | ✅ full |
| Host  | Joiner | Receiver-spawned TLaser    | ❌ ~0.2hp/shot |
| Joiner| Mob    | Receiver(host)-spawned TLaser | ❌ ~0.2hp/shot |
| Joiner| Host   | Receiver(host)-spawned TLaser | ❌ ~0.2hp/shot |

**Why:** We write our `dmg` int (16) to `+0xBC` / `+0xC0` post-ctor like
the engine does — but those fields are NOT damage. Engine reads them as
floats inside `FUN_0044db40` (raycast) as a direction/range vector,
NOT as damage. The actual damage value lives on the `+0xCC` sub-object
(probably `TRayCastBulletCallback` — its vtable is at 0x5587f4). The
callback's `ReportFixture` (Box2D standard) applies damage when an
actor fixture is hit; we haven't yet located which field of the sub-
object holds the damage value.

**What we tried**:
- Writing damage as float bit pattern (`union { int i; float f; }`) to
  `+0xBC`/`+0xC0` broke the beam visual entirely (vt[22]'s raycast
  reads these as a direction vector, not damage — float values gave
  bogus direction).

**Fix path:**
- Decompile `FUN_004c4760` (creates the +0xCC sub-object) to see where
  it reads the damage init.
- Decompile `TRayCastBulletCallback::ReportFixture` (in the sub-object's
  vtable) to see what field it reads when applying damage.
- Find the offset on the callback sub-object that holds the damage int
  (likely 4-byte field initialized from some constant during ctor).
- Write our `dmg` to that offset on the sub-object post-ctor.

## 🟡 Weapon-subclass replication gap (2026-06-17)

Partially fixed. `TNail` (nailguns) and `TExplodingBullet` (rocket
launchers etc.) now replicate via vtable swap — both subclasses call
TBullet's ctor internally, so the existing TBullet hook captures the
shot with a `g_pending_subclass` tag set by the subclass-ctor hook,
and the receiver's `swap_bullet_subclass` rewrites the spawned TBullet's
vtable to the subclass. vt[20] (impact effect) dispatches the right
visual / behavior.

**Still broken:** TCannonBullet, TLaser, TRailgunRay, TRocket,
TBlueRocket — these bypass TBullet's ctor entirely (use TProjectile
base, allocate their own sub-objects, etc.), so vtable-swap on a fresh
TBullet leaves them in an inconsistent state. Need real native bindings.

### Data already gathered (see ghidra_*.txt for full output)

| Subclass         | vtable      | ctor      | size  | ctor stack args |
|------------------|-------------|-----------|-------|-----------------|
| TBullet          | 0x5583ec    | 0x497040  | 0xc0  | 8 (x,y,vx,vy,dmg,owner,force,const) |
| TCannonBullet    | 0x558454    | 0x497660  | 0xbc  | 6 (x,y,vx,vy,dmg,owner) — flat dmg via vt[23]=1.0 |
| TExplodingBullet | 0x558384    | 0x497140  | 0xc0  | 8 (calls TBullet ctor inside) ✅ working |
| TNail            | 0x55831c    | 0x497200  | 0xc4  | 9 (TBullet args + range float) ✅ working |
| TLaser           | 0x5584bc    | 0x497cd0  | 0xe0  | 7 (x,y,vx,vy,?,owner,char) — owns 2× operator_new(0x84) sub-objects |
| TRailgunRay      | 0x5585ac    | 0x499d70  | 0x9c  | ? |
| TRocket          | 0x5586c4    | 0x49a5c0  | 0xd8  | ? |
| TBlueRocket      | 0x558604    | 0x49aa10  | 0xd8  | ? |

Engine registration after ctor: `FUN_004b3a90(obj, lua_state)` — same
call the Lua `CreateBullet` binding uses post-ctor.

### Plan for the next pass
For each missing subclass: write a Lua-callable native
`create_<subclass>(x, y, vx, vy, dmg, owner)` that does
`operator_new(SIZE)` → `__thiscall ctor(this, args…)` → `FUN_004b3a90`.
Add capture-side hook on the subclass ctor so the firer sends
`bullet_fire {subclass = <id>}`. Receiver dispatches by subclass id to
the new native instead of `CreateBullet` + `swap_bullet_subclass`.

`operator_new` address: TBC (search for any caller of size 0xc0).

## 🟢 Cannon AoE shipped via Lua-handle-aware AV recovery (2026-06-22)

Fully working — cannon now fires, replicates, hits, AoE-explodes, and
shrapnel-sprays just like single-player. Two layers got us there:

1. **Arity bugs in our own hooks (resolved 2026-06-19/20).** Ghidra's
   decomp under-counted stack args on multiple ctor/dispatch hooks. The
   real shapes (confirmed via `GetCannonPurge.java` reading the RET
   purge byte):
     - `hook_CannonCtor` 6→7 args (RET 0x1c)
     - `hook_NailCtor` 8→9 args (RET 0x24) — *this* was the cannon
       boom crash: it spawns 20 nails in a row, the per-call 4-byte
       stack drift compounded inside the boom frame and clobbered
       locals on the way out
     - `hook_ActorBulletDispatch` 5→7 args (RET 0x1c on FUN_0044f210)

2. **`mp_damage_tally_veh` vectored exception handler.** Cannon's
   TPlahvatus AoE damages the firer themselves; the engine's damage
   tally then iterates an "attackers" list, and entries get poisoned
   by the long-running heap corruptor (task #2) — the buffer's memory
   gets recycled to Lua TValue arrays that have the engine's own
   `lua_setfield(L,"entity",…)` imprint at +0x14.

   The VEH matches any `mov <reg>,[<reg>+disp8]; call <same-reg>`
   pattern (general virtual-call shape) whose operand reads from one of
   those Lua-handle-shaped objects, and skips 5 bytes past the call.
   The fingerprint check is the literal `"entity"` string at +0x14
   (`0x69746e65 0x00007974`) — engine emits exactly that on every Lua
   handle table it builds, and no genuine C++ entity has that layout,
   so it can't false-positive. Catches both observed crash sites
   (`FUN_00417720` vt[10] @ +0x17894 and `FUN_00419330` vt[13] @
   +0x19757) and any other accessor that gets added later without
   needing per-site enumeration.

**Remaining cosmetic:** receiver-side cannon flies faster than the
firer's (`speed = 15` fixed in Lua bullet_fire dispatch vs the engine's
natural ~2.7 units/tick from the weapon table). So the replicated
cannon arrives at impact earlier than the firer's. Visual only — both
sides spawn their own cannon and damage applies locally on each, so
the gameplay outcome is the same. Fix is one Lua tweak in
`init.lua` bullet_fire dispatch (subclass == 8 branch) to send +use
the real per-shot speed instead of the hardcoded 15.

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
