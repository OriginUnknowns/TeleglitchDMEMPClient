# TPlayer Puppet Crash Diagnosis — 5-Frame AV

**Date:** 2026-06-01
**Scope:** Offline binary analysis only — no runtime traces.
**Sources:** Ghidra 12.1 decomps in `ghidra_tplayer_ai_path.txt`, `ghidra_player_mgmt.txt`,
`ghidra_actor.txt`, `ghidra_vtable.txt`, `ghidra_damage_path.txt`, `tplayer_vs_ai_research.md`.

---

## Crash shape (recap)

The puppet is a real `TPlayer` (CreatePlayer at `-9999,-9999`) wrapped by `MP_USE_TPLAYER` think
hooks. It survives 5 calls (PT1→PT1→PT1→PT1→PT2 by the log labels, though more precisely
think1+think2 alternating across 3 frames):

- Frame 0: action stays 8 (aim). Likely the very first think1 was suppressed-into-noop because the
  dummy input device's vt[+0x10] (fire button) returned 0 — see below.
- Frame 3: action transitions 8→1 (aim→walk). Walks for two more frames.
- Frame 5: AV happens between PT2.post and the next per-frame call.

The HP pin (9999), invuln flag (1), and `+0xCC` sentinel (0x7FFFFFFF) all hold. Inventory pointer
`+0x9C` (`local_18[0x27]`) is real — the TPlayer ctor at `0x45b410` always news a
`TPlayerInventory` (0x28 bytes via `FUN_00412110`) at line 989-999. So this is **not** a NULL-`+0x9C`
trap.

---

## 1. What else does the engine call on a TPlayer per frame? (Q1)

### TPlayer vftable @ `0x556b14` — every slot, by RVA

```
[ 0] +0x00  0x0045b980  TPlayer::dtor
[ 1] +0x04  0x004b2bf0  TActor base: GetType (no-op getter)
[ 2] +0x08  0x004b2c40  TActor base: GetPos (returns +0x50 body pos)
[ 3] +0x0c  0x004b2e00  TActor base: GetAngle (returns +0xB0 angle)
[ 4] +0x10  0x004b2e30  TActor base: SetAngle (writes +0xB0)
[ 5] +0x14  0x004b2440  TActor base: SetVelocity / mover
[ 6] +0x18  0x004bd740  TActor base: misc getter
[ 7] +0x1c  0x00402830  PreSubclassWindow (NOOP stub)
[ 8] +0x20  0x004b3d70  TActor base: GetPos2D (used by AI, think2)
[ 9] +0x24  0x0045ef70  Lua bindings registrar (one-shot at handle creation)
[10] +0x28  0x0045cbc0  TPlayer::think1   <-- hooked
[11] +0x2c  0x0045bff0  TPlayer::think2   <-- hooked
[12] +0x30  0x00402830  NOOP
[13] +0x34  0x004028c0  NOOP (small stub)
[14] +0x38  0x0045c220  TPlayer::HUD/gameover  <-- iterated? See below
[15] +0x3c  0x004085f0  misc
[16] +0x40  0x004bd0a0  set sprite handle (init-time)
[17] +0x44  0x004b3b60  small accessor
[18] +0x48  0x00402830  NOOP
[19] +0x4c  0x0044f210  TActor::OnCollision (dispatches by +0x5c tag) <-- Box2D contact!
[20] +0x50  0x0044ddc0  TActor::SetAction (writes +0xB4)
[21] +0x54  0x0045ebd0  TPlayer::OnAction (calls FUN_0045b3d0 on +0x9C)
[22] +0x58  0x0044df30  TActor base helper
[23] +0x5c  0x0044e160  small helper
[24] +0x60  0x0045e900  TPlayer::TakeDamage OVERRIDE (writes DAT_005747cc etc.)
[25] +0x64  0x0044e340  TActor base helper
[26] +0x68  0x004024e0  NOOP trampoline (called by FUN_0044f210 case 16)
[27] +0x6c  0x0044ef80  TActor::OnHitByPhysics (called by 0044f210 case 32)
[28] +0x70  0x0044ee80  TActor::ApplyBulletDamage (called by 0044f210 case 8)
[29] +0x74  0x0044f130  TActor::OnHitByExplosion (called by 0044f210 case 256)
[30] +0x78  --no-fn--
[31] +0x7c  0x00460b00  TPlayer mode-31 helper (drop / spread / inventory; ONLY called from think1's drop path; gated by +0xE4)
[32] +0x80  0x00460ed0  per-mode helper
[33] +0x84  0x0045f250  per-mode helper
[34] +0x88  0x0045f1e0  per-mode helper
[35] +0x8c  0x0045f7d0  per-mode helper
[36] +0x90  --no-fn--
[37] +0x94  0x0050d0ee  purecall
[38] +0x98  0x00460550  per-mode helper
[39] +0x9c  0x0045f460  per-mode helper
```

Slots 31-39 are all `(this, ...)` helpers reached *from within* think1 (drop key / sprint / ammo
helpers). They are not called from the engine main loop directly; they are unreachable while the
`+0xE4` fire gate is set on the puppet.

### Is vt[14] (HUD/gameover) iterated over all TPlayers?

The function body (decomp lines 1130-1325 in `ghidra_tplayer_ai_path.txt`) draws fullscreen HUD:
"health=%d/100", "armor =%d/100", ammo counts, "gameover" sprite, "timesdead", etc. These are
single-instance UI elements — drawing them twice would be visually wrong even if it didn't crash.

Strong inference (no direct main-loop decomp yet, but supported by the body): vt[14] is called
**only on `DAT_005747a4`** (the active player), exactly like the camera and input. It is the
**HUD-for-the-local-player** dispatch, not "render-this-actor's-on-world-overlay". This matches
how `FUN_0045b9d0` (the camera-coupling sub) is structured — only one camera per frame.

**Therefore vt[14] does NOT run on the puppet.** The puppet's gameover/HUD slot is never invoked
because `DAT_005747a4` points to the local TPlayer (after the save/restore around think1).

### What about vt[19] OnCollision? It's per-Box2D-contact, not per-frame

`FUN_0044f210` is the TContactListener trampoline. It fires whenever the Box2D world step has a
contact-begin involving this actor's fixture. Per-frame in the sense that contacts are processed
during the world step, but per-contact in count. Once the puppet's Box2D body is moved to
`(host-pos)` by `SetPosition`, **its fixture overlaps the host's fixture every frame**, so
contact-begin/contact-end events fire each step. The dispatcher routes by colliding object's
`+0x5c` tag:

| Tag | Handler | Risk on puppet |
|---|---|---|
| 8 (bullet) | `*this+0x70` = `0x44ee80` ApplyBulletDamage | Damage feeds `0x45e900` TakeDamage — gated by `+0xFC` invuln. **Safe.** |
| 16 (actor) | RTTI cast → `*this+0x68` = `0x004024e0` NOOP | **Safe.** Actor-actor contacts are intentionally no-op. |
| 32 (physical) | `*this+0x6c` = `0x0044ef80` knockback | Reads `param_1[0x14]` pos, `param_1[0x1d]` damage; calls `vt[+0x5c]` and `vt[+0x60]` on self. **Safe** (`+0x60` = TakeDamage, again gated). |
| 256 (shield) | `*this+0x74` = `0x0044f130` shield bounce | Calls TakeDamage. **Safe.** |

OnCollision is not a likely crash site under our gates.

---

## 2. Does the engine iterate "all TPlayers"? (Q2)

The known xrefs list (51 functions) reads `DAT_005747a4` directly. There is no separate
`players[]` array indexed by Lua or by the engine. However, there are two iteration paths that
touch **actors** as a class (not "players" specifically):

1. **The actor list in `DAT_005747b4` (gamestate).** vt[14] reads `DAT_005747b4 + 0x68` (a counter
   field), and many AI fns read it. The actor list is the master list of TActor* maintained by
   level load and CreatePlayer/CreateZombie. Each tick the engine walks it once for
   `(actor->vftable[10])(actor)` then once for `(actor->vftable[11])(actor)` (think1, think2).
   **For TActor base class, vt[10] = `0x00402830` NOOP and vt[11] = `0x004bd250` (alive-update +
   render).** So the engine treats `vt[10]` as the "tick" slot and `vt[11]` as the "draw" slot, and
   they are virtual — for a TPlayer they resolve to `0x45cbc0`/`0x45bff0`, exactly what we hook.

2. **Box2D world step** — iterates Box2D bodies. Contact callbacks dispatch via the TContactListener
   into `FUN_0044f210` etc. (handled in §1).

**A second TPlayer in the actor list is fully iterated by both ticks.** The engine has no opinion
that "only DAT_005747a4 is a TPlayer"; it just sees a TActor* whose vtable says it's a TPlayer.
That's why our wrap hooks on `0x45cbc0`/`0x45bff0` are correct in shape — they catch ALL TPlayer
ticks, host's included.

---

## 3. What runs between TPlayer::think2 return and the next think1? (Q3)

Per the main loop pattern (vt[10] sweep → vt[11] sweep → physics step → render submit → input
poll), between PT2.post on the puppet and the next per-frame log line, the engine does, in order:

1. **The remainder of the vt[11] sweep on later actors** — including bullets (TBullet vt[11] = NOOP
   `0x00402830`), TBullet vt[10] is the ticker (`0x498ad0`) — that ran in the vt[10] phase. Mobs,
   resources, etc.
2. **Box2D world step** — `b2World::Step` invokes contact listeners. See §1.
3. **`FUN_0045b9d0` (camera coupling)** — called from **inside** think2, NOT after. It runs once
   per TPlayer that ticks. **On the puppet, this is the most suspicious code that runs every
   frame.** See §5.
4. **The render submit / HUD draw / sound mix** — `vt[14]` for the active player only (§1),
   plus the camera transform / sprite batch flush.
5. **Input device poll** — re-reads keyboard.
6. **Next frame's vt[10] sweep starts** → PT1.pre on the host's TPlayer → PT1.pre on the puppet.

The crash occurs in steps 1-5. The most-touching paths on the puppet are #2 (Box2D contacts,
benign per §1) and #3 (FUN_0045b9d0 — see §5).

---

## 4. Action 8→1 transition — what cleanup runs? (Q4)

Decomp lines 746-756 (case 8 of the action switch in think1):

```c
case 8:                                                              // aim
  cVar2 = (**(code **)(*DAT_00574798 + 0x10))(uVar17);               // fire button
  if (cVar2 == '\0') {
    local_18[0x2d] = 1;                                              // -> walk
  }
  fVar10 = (float10)FUN_004ae1f0((float *)(local_18 + 0x3c));        // pos2D normalize
  (**(code **)(*local_18 + 0x10))((float)fVar10, uVar13);            // SetAngle (vt[4]) — writes +0xB0
  local_18[0x40] = (int)DAT_00558adc;                                // some scalar (+0x100)
  local_22c = DAT_00558d58;
```

**Key observation:** the 8→1 transition does NOT clear, deref, or read any "weapon-equipped"
state. It is a pure integer write `local_18[0x2d] = 1`. **No weapon cleanup runs.** This rules
out the "leaving aim cleans up a weapon-pointer cache" hypothesis.

Case 1 (walk), on the other hand, **does** dereference inventory:

```c
case 1:                                                              // walk
  ...
  cVar2 = (**(code **)(*DAT_00574798 + 0xc))(0x45de98);              // reload button
  if (((cVar2 != '\0') && ((char)local_18[0x39] == '\0'))            // +0xE4 fire gate (we set =1, this branch SKIPS)
      && (*(char *)(*(int *)(local_18[0x27] + 0x24) + 0x10) == '\0'))   // <-- HERE: inv[+0x24]
```

Because `+0xE4 == 1` (our gate), this branch is skipped via short-circuit — `local_18[0x27]` is
never dereferenced. **So case 1's input branch is safe.**

But line 759 (always-on, after the switch):

```c
local_374 = FUN_0040fea0((void *)local_18[0x27], (undefined4 *)local_264);  // "powerlegs" inv lookup
```

This calls `FUN_0040fea0` on the inventory **every frame, ungated by +0xE4**. It searches the
inventory's bucket list for the "powerlegs" item. With a fresh ctor-allocated `TPlayerInventory`
(empty list), it returns 0 cleanly. **Safe in steady state.**

So action 8→1 is not the crash cause directly. But case 1 has a second always-on call on line
770: `FUN_0045b360((void *)local_18[0x14], local_1c4);` — sets Box2D body velocity. **`+0x50` is
the Box2D body pointer.** This dereferences the body. If between think2 (which moves the body via
`SetPosition`) and the next think1, the body has been destroyed by some other code path, the
deref AVs.

---

## 5. Camera / level-render touching the puppet (Q5) — PRIMARY SUSPECT

`FUN_0045b9d0` (think2 camera-coupling sub) is the most-active piece of code that runs **on**
the puppet, per frame, that uses TPlayer-specific data. Decomp lines 1356-1558:

```c
void FUN_0045b9d0(void) {
  ...
  if (local_18[0x2d] == 8) {        // action == aim
    local_2c = -1;  local_30 = 2;  local_34 = 1;       // loop 3 times
  } else {
    local_2c = 0;   local_30 = 0x168; local_34 = 0xf;   // loop 24 times
  }
  for (local_38 = local_2c; local_38 < local_30; local_38 += local_34) {
    ...
    // build a ray endpoint from this player's angle + 24 directional offsets
    pfVar5 = (float *)(**(code **)(*local_18 + 8))();      // vt[2] = GetPos -- reads +0x50 body
    FUN_004adf80(*pfVar5, pfVar5[1], 0x45bbc6, puVar11,
                 pfVar4, puVar12, (undefined4 *)p_Var13,
                 uVar17, piVar6, iVar7=2);                  // Box2D raycast (category 2 = walls)
    pfVar4 = (float *)(**(code **)(*local_18 + 8))(local_d0, ...);   // vt[2] GetPos AGAIN
    fVar9 = (float10)FUN_004ae2b0(pfVar4, (float *)0x45bbf6);        // distance compute
    ...
    if (local_64[0] != 0) {
      *(undefined1 *)(local_64[0] + 0x36) = 1;             // <-- WRITES into fixture's user data
    }
  }
```

**Observation:** When action != 8 (i.e. case 1, walk — which is what the puppet is in by frames
4-5), the **loop runs 24 raycasts** outward from the puppet's position. For each fixture hit,
**it writes `*(byte*)(fixture+0x36) = 1`** — a "this wall has been seen by a player" flag used by
the in-engine map/discovery system.

`local_64[0]` is filled by `FUN_004adf80` (Box2D raycast) — it's the user-data ptr stored in the
hit b2Fixture. For real walls (TInnerWall / TOuterWall), `+0x36` is a valid byte. **But the puppet
moved from `(-9999,-9999)` to `(host_pos)` on the SetPosition call.** During the very first
think2 at the new position, the 24 raycasts hit whatever walls are around the host. Each updates
their `+0x36` "discovered" byte.

Subsequent frames continue to discover. Then `FUN_00415f10(&DAT_0057588c, ...)` is called
(line 1486) — `DAT_0057588c` is another camera/map global that **the puppet should not be
writing to.**

```c
piVar6 = (int *)FUN_00415f10(&DAT_0057588c, (undefined4 *)local_84);
local_d1 = iVar7 != *piVar6;                              // compare module ID
...
if (local_d1 != '\0') {                                   // if module changed
  ...
  if (local_88 <= DAT_00572700) {                         // zoom logic
    local_18[0x44] = ... (zoom-target offset)
  }
  DAT_00572700 = DAT_00572700 + (float)local_18[0x44];    // <-- writes global view zoom
  ...
}
```

**`DAT_00572700` (view zoom)** is restored by our hook after think2. So the writes here are
shadowed. But the inner state writes are still happening — and the `FUN_00415f10` call walks the
module list.

### What can AV here?

1. **`FUN_004adf80` (Box2D raycast)** can fail catastrophically if the fixture's user data is
   recycled/freed memory. After 5 frames, the host has moved through cells and the joiner has
   moved too; if `+0x36` is written on a fixture whose Box2D body was just destroyed (level-end /
   doorway transition), this is a UAF write. **Low probability in 5 frames on a flat map, but
   possible.** Verdict: **suspect but not primary**.

2. **`FUN_0045b9d0` calls `(**(code **)(*local_18 + 8))()` — vt[2] GetPos — TWICE per iteration**
   (lines 1451 and 1466). 24 iterations × 2 = 48 vt[2] calls per frame on the puppet. vt[2] =
   `0x004b2c40` reads `*(int*)(this+0x50)` (Box2D body) and dereferences it. If the puppet's
   `+0x50` body is fine (and it is, set up by ctor), this is safe. **Safe.**

3. **`FUN_00415f10(&DAT_0057588c, local_84)`** walks the module list to find the current module
   for the puppet's position. **The puppet is at the host's position, so this should resolve fine
   on a normal-cell host position.** But if the host's position happens to lie outside the level
   geometry (e.g. at `(0,0)` — a default-uninitialized position if the joiner spawned before
   level was ready) or in a cell where the spawner module is being recycled, the call AVs.

### CONCRETE PRIMARY SUSPECT — `FUN_0045b9d0` walls-discovery loop

For frames where action != 8 (24-iteration loop), the puppet writes `+0x36=1` into every fixture
the raycast hits. **On frame 5, the cumulative discovery list crosses some threshold or hits a
fixture whose owner has been deleted.** This is consistent with "survives 5 frames, then dies",
because it takes a couple of frames for the puppet's discovery list to surface a fixture that the
host had previously interacted with.

**Recommended fix #1 (highest leverage):** Force `local_18[0x2d] == 8` *for the puppet only*
during think2 by saving/restoring action around the FUN_0045b9d0 call inside our think2 wrapper.
This drops the loop to 3 iterations and (critically) takes the camera-coupling path that does
NOT call `FUN_00415f10` walk + zoom-write logic. This matches what action=8 does in the camera
sub:

```
on entry to hook_PThink2:
  saved_action = *(int*)(puppet + 0xB4);
  *(int*)(puppet + 0xB4) = 8;        // force aim — minimizes camera sub work
  saved_zoom = DAT_00572700;
  orig_think2(puppet);
  DAT_00572700 = saved_zoom;
  *(int*)(puppet + 0xB4) = saved_action;
```

This narrows the FUN_0045b9d0 work to 3 raycasts and avoids the module-walk branch. **If the
crash is in `FUN_00415f10` or `FUN_004adf80` deeper than 3 hits, this fix removes it without
re-engineering the engine.**

**Recommended fix #2 (orthogonal — also do this):** Skip `FUN_0045b9d0` entirely on the puppet.
Look at the disassembly of `0x45bff0` (think2) — the call to `FUN_0045b9d0` is at instruction
offset ~0x70 from function start. Patch our hook so we call the **bytes BEFORE** that call and
the bytes AFTER it, but not the call itself, by inlining the render-only portion. OR simpler:
hook `FUN_0045b9d0` itself (`0x45b9d0`) and bail at entry when `DAT_005747a4 != caller`. The
camera sub's purpose is **to update DAT_00572700 for the camera** — it should never run on a
non-camera player. This is the *correct* gate.

```cpp
// hook FUN_0045b9d0 at 0x45b9d0
char __fastcall hook_CameraCoupling(void* ecx, void* edx) {
  if (g_in_puppet_think2) return; // bail: not for the puppet
  orig_CameraCoupling();
}
```

The `g_in_puppet_think2` flag is set by hook_PThink2 wrapper around the orig call. **This is
likely the real fix.**

---

## 6. Inventory ptr on a fresh CreatePlayer'd puppet (Q6)

Verified from TPlayer ctor `FUN_0045b410` decomp (lines 989-1001 of
`ghidra_tplayer_ai_path.txt`):

```c
local_50 = operator_new(0x28);
local_8._0_1_ = 3;
if (local_50 == (void *)0x0) {
  local_64 = (undefined4 *)0x0;
} else {
  local_64 = FUN_00412110(local_50, 0x14, local_18);   // TPlayerInventory ctor (size, owner)
}
...
local_18[0x27] = (int)local_64;                         // +0x9C = inventory
*(undefined4 *)(local_18[0x27] + 4) = DAT_00558e40;     // inv +0x04 = some constant
*(undefined4 *)(local_18[0x27] + 8) = DAT_00558f1c;     // inv +0x08 = some constant
```

**`+0x9C` is always populated by ctor.** It is not NULL. It is a real `TPlayerInventory` object
of 0x28 bytes. Its vtable @ `0x555f3c` has 2 slots:
- `[0] 0x004121f0`
- `[1] 0x004101f0`

The inv's `+0x24` field — read by line 676 and line 1186 (vt[14]) as
`*(int*)(inv+0x24) + 0x10` — is the "currently selected item" pointer. If the inventory is
empty, this could be NULL. **Line 676 in think1 case 1 is gated by `+0xE4` short-circuit** —
we set `+0xE4=1`, so the reload branch (and its inv+0x24 deref) is skipped via the
short-circuit `((char)local_18[0x39] == '\0')` test. **Safe.**

Line 1186 in vt[14] would AV if vt[14] runs on the puppet — but vt[14] is the local-player HUD
(§1), so it doesn't.

**Conclusion: the puppet's inventory is properly initialized and not the AV site.** Defensively
zeroing `+0x9C` (as suggested in `tplayer_vs_ai_research.md`) would actually be HARMFUL — the
think1 case-1 reload-input branch dereferences `local_18[0x27]` (+0x9C) **before** the +0xE4
gate is checked (depending on compiler ordering, but the short-circuit in decomp says +0xE4 is
checked first). Stick with the real inventory.

---

## 7. Specific suggested fix areas — summary

### Fix A (PRIMARY — likely resolves the crash)

**Hook `FUN_0045b9d0 @ 0x45b9d0` (camera coupling sub).** Bail at entry whenever the global
"in puppet think2" flag is set by `hook_PThink2`. This sub's whole purpose is updating the
camera/view-zoom for `DAT_005747a4`; running it on a non-camera TPlayer (a puppet) iterates 24
Box2D raycasts and writes to walls' "discovered" flags + walks the module list — all of which
can AV after the puppet has been moved to live world coordinates and the engine starts
recycling distant fixtures.

```cpp
// in dllhost main.cpp
static thread_local bool g_in_puppet_think2 = false;

void __fastcall hook_PThink2(void* self, void* edx) {
  bool is_puppet = (self != orig_get_main_player());
  float saved_zoom = DAT_00572700;
  if (is_puppet) g_in_puppet_think2 = true;
  orig_PThink2(self, edx);
  if (is_puppet) g_in_puppet_think2 = false;
  DAT_00572700 = saved_zoom;
}

void __fastcall hook_CameraSub() {
  if (g_in_puppet_think2) return;   // skip wall-discovery + module-walk + zoom-update
  orig_CameraSub();
}
```

### Fix B (BELT-AND-BRACES — even if A doesn't resolve, do this too)

In `hook_PThink2`, save the puppet's `+0xB4` action and force it to `8` (aim) for the duration
of the orig call. This forces the action=8 branch of `FUN_0045b9d0` if Fix A isn't applied or
the sub call site isn't hookable (e.g. inlined). Restore after.

```cpp
int saved_action = *(int*)((char*)self + 0xB4);
*(int*)((char*)self + 0xB4) = 8;          // force aim for camera sub
orig_PThink2(self, edx);
*(int*)((char*)self + 0xB4) = saved_action;
```

### Fix C (defensive — small bytes, no downside)

After CreatePlayer, write `local_18[0x44] = 0` (zoom-target accumulator at `+0x110`). This
field is added to `DAT_00572700` inside `FUN_0045b9d0`. The ctor sets it to
`(float)PTR_00558a40` (= 0.0f via the 0-float pointer), which is fine. But the sub increments
it across frames. Resetting to 0 each frame on the puppet keeps it from drifting and (with
zoom restore around think2) ensures no slow corruption of the camera.

### Things NOT to do (ruled out by this analysis)

1. **Do not zero `+0x9C`** — the ctor initializes it correctly; later think1 branches read it
   through the inventory vtable, and a NULL there would AV in `FUN_0045ebd0` (vt[21] OnAction).
2. **Do not pin `+0xCC = -1`** — `0x7FFFFFFF` is already non-zero, which is what vt[14]'s
   `*(int*)(local_18 + 0xcc) == 0` check needs. The original tplayer_vs_ai_research.md
   mentioned `-1` as belt-and-braces — that's fine too, but `0x7FFFFFFF` is not the problem.
3. **Do not skip think1 entirely** — render block in think2 needs the body sprite handle that
   think1 maintains via the action state machine (`+0x1C` shoot-frame counter is decremented in
   case 1, drives the body sprite frame).

---

## 8. Diagnostic confidence

| Suspect | Confidence | Evidence |
|---|---|---|
| `FUN_0045b9d0` wall-discovery loop (action!=8 path) | **High** | 24-iteration per-frame raycast loop with side-effect writes to fixture user-data; matches "survives a few frames, then crashes" pattern; runs on EVERY TPlayer that ticks, not gated by camera-ownership |
| `FUN_00415f10(&DAT_0057588c)` module-walk in same sub | **High** | Reached only via the same path; walks engine module list that the puppet has no business reading |
| Box2D fixture UAF in `FUN_004adf80` | Medium | Possible but requires fixture lifecycle event in 5 frames; possible if level just loaded |
| `vt[14]` (HUD) on puppet | **Low** | Body draws fullscreen UI; engine wouldn't iterate this per actor |
| Inventory `+0x9C` deref | **Very low** | Ctor sets it; gated branches don't reach it |
| Action-transition cleanup | **Ruled out** | 8→1 is pure integer write, no callbacks |
| `FUN_0044f210` collision dispatch | **Very low** | All four tag paths are gated or noop |

The fix is to ensure `FUN_0045b9d0` does not run on the puppet. Hook the sub and bail. If
hooking the sub is impractical, force action=8 on puppet around think2 to take the cheap path.
