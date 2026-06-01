# TPlayer puppet rotation diagnostic

**Date:** 2026-06-01
**Scope:** Why the joiner's animated TPlayer puppet shows (a) idle jitter, (b) wrong rotation during stab frames 27..29, (c) wrong rotation during aim (action 8), (d) "wrap" artifact when looking near angle 0.

## 1. Field map (re-confirmed, byte offsets)

All `local_18[N]` indices in `FUN_0045cbc0` (think1) and `FUN_0045bff0` (think2) are **DWORD indices** — actual byte offsets are `N * 4`:

| local idx | byte off | meaning                                              |
|-----------|----------|------------------------------------------------------|
| 0x1c      | 0x70     | animation frame (float)                              |
| 0x1d      | 0x74     | frame velocity                                       |
| 0x27      | 0x9C     | inventory ptr                                        |
| 0x2c      | 0xB0     | **angle** (the actor-angle field, target of vt[4])   |
| 0x2d      | 0xB4     | action id (idle=0 walk=1 shoot=7 aim=8 ...)          |
| 0x3a/0x3b | 0xE8/0xEC| **walk-target vector** (slot[1] of input dev)        |
| 0x3c/0x3d | 0xF0/0xF4| **aim-target vector** (slot[0] of input dev)         |
| 0x3e      | 0xF8     | aim-angle bias (recoil etc.)                         |
| 0x40      | 0x100    | DAT_00558adc — fire-anim offset/decay (case 7/8)     |
| 0x44      | 0x110    | zoom velocity for FUN_0045b9d0                       |
| 0xfc      | 0xFC     | invuln byte                                          |
| 0xfd      | 0xFD     | render-skip byte (must stay 0 to draw)               |

So the "`+0x3c`" mentioned in earlier notes is **byte +0xF0**, not 0x3C. This is the dword-index/byte confusion that's been polluting our investigation.

## 2. What writes `+0xF0/+0xF4` (the aim-target)?

In `FUN_0045bff0` think2 line 815:
```c
puVar1 = (**(code **)(*param_1 + 8))(local_2c,...);     // vt[2] GetPosition → world pos
piVar2 = (int *)(**(code **)*DAT_00574798)              // input dev slot[0]
            (local_34, *puVar1, puVar1[1], 0x45c045);
local_14[0x3c] = *piVar2;                               // store aim x at +0xF0
local_14[0x3d] = piVar2[1];                             // store aim y at +0xF4
```
Slot[0] of TCombinedInputDevice (vtable +0x00 @ 0x4bae00, retN=0xC) takes `(out_vec*, posX, posY)` and returns a **2D world point** — the world-space mouse cursor, derived from the active player's position. Then in think1 SetAngle is:
```c
fVar10 = (float10)FUN_004ae1f0((float*)(local_18 + 0x3c));   // atan2(F0..F4 - pos?)
(**(code **)(*local_18 + 0x10))((float)fVar10, ...);         // vt[4] SetAngle → writes +0xB0
```
`FUN_004ae1f0` is `atan2`-style normalize of a 2-vector. The vector passed is `+0xF0..+0xF4`, which on the *local* player is `(cursorX, cursorY)` minus position — actually it's whatever slot[0] returns. So the engine *reads world-space cursor-relative-to-player from the input device every think2*.

## 3. Where slots[0] / slot[1] resolve on the puppet

The dllhost dummy device returns `(g_puppet_aim_x, g_puppet_aim_y) = (px + cos(angle), py + sin(angle))` from slot[0]. The think2 code line 815 calls slot[0] with `(out, *puVar1, puVar1[1])` — these are the player's own pos (puppet's px,py). The dummy ignores those args and returns `(px+cos, py+sin)`.

Think1 then calls `FUN_004ae1f0(&aim_xy)` with the *raw* 2-vector `(px+cos, py+sin)`, **not the delta**. `FUN_004ae1f0` is `atan2(y, x)`. So the resulting angle is `atan2(py+sin(a), px+cos(a))` — **this is wildly off** for any player not at world origin. For a puppet at (50, 30) with angle 0, you get `atan2(30, 51) ≈ 0.531 rad`. For angle = π, `atan2(30, 49) ≈ 0.548 rad`. The puppet's angle SetAngle output is dominated by its world position, not the stored pin.

**This is the dominant bug.** The local player works because... wait, look at think2 line 815 again: it calls slot[0] with `(*puVar1, puVar1[1])` — these are passed as args 2 and 3. Slot[0]'s real implementation (in non-dummy) uses these as the *player position* and returns the cursor in player-relative form (the math inside `FUN_004ba5b0` mixes mouse delta with these). So the engine expects slot[0] to return **a direction-or-position relative to the player**.

The dummy returns `px + cos(a)` which is `position + unit_dir` — and the engine then atan2's this. atan2(y, x) of `(py + sin(a), px + cos(a))` is NOT `a`; it's `atan2(py + sin(a), px + cos(a))`. The "+ cos / + sin" trick was designed to make the cursor be at distance 1 *in front of the player*. But the engine likely treats the output as ALREADY-relative (subtraction happens inside `FUN_004ba5b0` of the real device).

Look at lines 198-201 of think1:
```c
pfVar5 = (float*)FUN_0040d110(local_18[0x14]);   // body's world pos
local_54 = *pfVar5;
local_50 = pfVar5[1];
```
…and walk uses slot +4 (which fills `+0xE8/+0xEC`) — the WALK target. Then case-1 calls `FUN_004ae1f0(+0xE8)` getting the walk angle. If `+0xE8` is also `(px+something, py+something)`, the same problem would break walk too — but walking works on the local player, so the real input device's slot output is **relative** (delta from player).

**Fix:** the dummy must return `(cos(angle), sin(angle))` — a unit DIRECTION VECTOR — NOT `(px+cos, py+sin)`. Then `atan2(sin, cos) = angle` cleanly. This single change should fix idle drift, stab direction, and aim direction simultaneously.

## 4. The "wrap at angle 0" artifact

`FUN_004ae1f0` = atan2 returns `[-π, π]`. Lua `GetAngle` reads `+0xB0` (vt[3] = `FUN_004b2e00`) which is whatever was last `SetAngle`'d — the engine itself produces atan2 values, so naturally `[-π, π]`. When the local player aims slightly above-right vs slightly below-right, atan2 goes from `+0.05` to `-0.05` — a 0.1 rad jump *only if you linearly interpolate*. But we don't interpolate; we `SetAngle(p.angle)` once per snapshot.

However: `apply_angle_pin_after_think` overwrites `+0xB0` AFTER the engine's think1 has just SetAngle'd from the (broken) aim vector. There's a one-frame race: think1 writes a garbage angle into +0xB0 via the SetAngle call, and the post-think pin restores the correct one. The body draws at the pinned angle (think2 read `+0xB0` via vt[3] AFTER think1 → if pin runs *between* think1 and think2, render is correct; if pin runs after think2, body draws garbage for one frame).

**Order:** main loop calls vt[10] (think1) THEN vt[11] (think2) THEN our post-think hook runs apply_angle_pin. So think2 reads +0xB0 with the BROKEN angle from think1's SetAngle, draws sprite, THEN we overwrite. **The render uses the broken angle**, the pin is too late.

**Fix:** apply the angle pin BEFORE think1, not after. Or hook vt[3] (`FUN_004b2e00` GetAngle) to return the pinned angle when called on a puppet. Or pin `+0xB0` inside `hook_PThink1` *before* `orig_PThink1` AND again before `orig_PThink2`, AND stub vt[4] (SetAngle, `FUN_004b2e30`) to no-op on puppets so think1's case-1/7/8 SetAngle calls don't corrupt it.

## 5. Stab (frames 27..29) and aim (action 8) direction

The stab is purely frame-animated (frame 27..29 inside spr_mees draw) — **there is no separate stab-direction field**. The body sprite is drawn at `GetAngle()` (= `+0xB0`) in think2 line 834: `(**(code**)(*local_14+0xc))(...)` = vt[3] GetAngle, fed into `FUN_004ab0b0` body-sprite draw.

Action 8 (aim) case in think1 line 743-744:
```c
fVar10 = FUN_004ae1f0((float*)(local_18 + 0x3c));   // atan2 of +0xF0/F4
(**(code**)(*local_18 + 0x10))((float)fVar10, ...);  // SetAngle
local_18[0x40] = (int)DAT_00558adc;                  // bias/recoil
```
Action 7 (shoot) line 732-733 is identical. Action 1 (walk) line 720 uses `+0x3c` too. So **all three actions** route through the same `atan2(+0xF0/F4) → SetAngle`. They share the same bug. Fixing the dummy input device's slot[0] to return `(cos(a), sin(a))` fixes all three at once.

## 6. Idle jitter (action 0)

In case 0: `local_18[0x2d] = 8; local_18[0x1c] = 0`. The engine **immediately transitions idle → aim** on every frame where the dummy isn't actively firing. So the puppet is always in action 8, never truly in action 0. The "idle" jitter is the same atan2-of-position bug being recomputed every frame. As the *active player* moves (camera global writes to position cache?), the puppet's relative perspective shifts and atan2 wobbles.

## 7. Body sprite render confirmation

think2 lines 826-845:
```c
if (uVar3 == 0) {                                    // +0xFD == 0 (render gate)
  pfVar4 = (float*)FUN_0040d110(local_14[0x14]);     // body pos
  local_20 = *pfVar4; local_1c = pfVar4[1];
  FUN_0040e5b0(&local_20, DAT_00558eb0);             // offset
  FUN_004b4f50(2);                                   // sprite layer
  fVar7 = (float10)(**(code**)(*local_14 + 0xc))(...);  // vt[3] GetAngle → +0xB0
  FUN_004ab0b0(local_14[0x1b], local_20+frame_off, local_1c+frame_off, fVar7, ...);   // BODY DRAW
  ...
  fVar7 = (float10)(**(code**)(*local_14 + 0xc))(...);  // vt[3] GetAngle again
  FUN_004ab0b0(local_14[0x1b], local_20, local_1c, fVar7, ...);                       // OVERLAY DRAW
}
```
**Confirmed**: body sprite + overlay both draw at `vt[3] GetAngle() = +0xB0`. No separate stab-knife sprite. Frame number `+0x70` selects the pose (27..29 = stab pose). The stab "direction" is whatever `+0xB0` holds at think2 time.

## 8. Action transitions and `+0x100`

`local_18[0x40] = (int)DAT_00558adc` in cases 7/8 — that's the float-cast bias for recoil/fire animation, not a direction. `+0x100` is animated via the lerp at think2 line 821-822. Irrelevant to rotation.

## 9. Recommended fixes (priority order)

1. **(critical)** Change dllhost's dummy slot[0] (and slot[1]) to return a **unit direction vector** `(cos(pin_angle), sin(pin_angle))` instead of `(px+cos, py+sin)`. This fixes cases 1/7/8 simultaneously. Discard the px,py args from the engine — they're the player position, and the real device returns mouse-relative to player.
2. **(critical)** Apply the angle pin BEFORE `orig_PThink2` (or both before and after think1) so the render in think2 sees the pinned value. Currently the engine's own SetAngle inside think1 stomps `+0xB0` with garbage and our post-hook fix is too late for the same-frame draw.
3. **(belt-and-braces)** Hook vt[4] (`FUN_004b2e30` SetAngle) to no-op when called on a puppet. This prevents think1 from ever corrupting `+0xB0`, removing the one-frame race entirely.
4. **(wrap fix)** Lua `pl:GetAngle()` returns `[-π, π]` (atan2 output). When sending via snapshot, do NOT unwrap or accumulate; send raw. On the receiver, SetAngle directly — no normalization needed. The "wrap at 0" is likely a snapshot interpolation artifact in Lua or a print/format that's wrapping at `2π`. Verify Lua does not modulo or wrap the angle anywhere before the snapshot send.
5. **(idle action force)** Force `+0xB4 = 8` (aim) before think1 to stop the engine from re-transitioning to action 1 (walk) when velocity goes nonzero (it can't, since dummy returns no movement) — already mostly fine, but case-0→8 transition means the puppet runs case 8 every frame regardless.

## 10. Key addresses

| Sym | Addr | Note |
|-----|------|------|
| TPlayer::think1 | 0x45cbc0 | reads input dev, SetAngle from +0xF0 |
| TPlayer::think2 | 0x45bff0 | calls slot[0] to refill +0xF0, draws body |
| FUN_004ae1f0 | 0x4ae1f0 | atan2(y,x) normalize of 2-vec |
| vt[3] GetAngle | 0x4b2e00 | returns *(float*)(this+0xB0) |
| vt[4] SetAngle | 0x4b2e30 | writes *(float*)(this+0xB0) |
| TCombinedInputDevice vtable | 0x558974 | slot[0]@0x4bae00 retN=0xC |
| FUN_004ab0b0 | 0x4ab0b0 | sprite draw (pos, angle) |
| input dev global | DAT_00574798 (RVA 0x174798) | active device ptr |

