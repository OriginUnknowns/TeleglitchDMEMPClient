# Teleglitch bomb activation path (2026-06-01)

Reverse-engineered from Ghidra 12.1, Teleglitch.exe build 2023-04-27. Sources:
`E:\projects\TMEMultiplayerClient\ghidra_bomb.txt`, `ghidra_bomb2.txt`,
`ghidra_bomb3.txt`, `ghidra_bomb4.txt`.

## Class: `TTimeBomb`

All `itype=itemtypes.explosive` items (`timebomb`, `smtimebomb`, `nailbomb`,
`meattrap`, `cangun`) are instances of `TTimeBomb`. Created exclusively via the
Lua factory `_CreateBomb(x,y,name)` → C binding `FUN_00423050` →
`operator new(0x110)` → `TTimeBomb::ctor`.

- **`TTimeBomb::vftable` = `0x00557274`**
- **ctor `FUN_00470720`** — installs vftable, sets `+0xfc = -1` (inert/disarmed),
  reads `radius` → `+0x108`, `throwspeed` → `+0x10c`, `nailcount` → `+0x104`,
  `delay` → `+0x100` from `itemtable[name]`.
- Base class ctor `FUN_0040ec90` (TItem). Bomb size = **0x110 bytes**.

### Instance layout (offsets beyond TItem base)
```
+0x14   itemname string (TItem.name, set by base ctor)
+0x50   Box2D body/fixture pointer        (TItem.body, field [0x14])
+0x98   inventory back-ptr                (TItem.inv,  field [0x26])
                                            (deref +0xc = owning TActor*)
+0xfc   fuse counter (int)  -1 = inert; >0 = burning ticks remaining
+0x100  delay frames (1/25 s) from Lua def
+0x104  nailcount (int)     shrapnel bullets to spawn at fuse=0
+0x108  radius (float)      explosion AoE / sound flag radius
+0x10c  throwspeed (float)  initial linear speed when thrown
```

## Activation = `FUN_00470aa0` (TTimeBomb::OnUse, vtable slot 20 / +0x50)

**This is the function to hook.** It is the engine's "fire-button while
explosive selected" handler. Called by the TPlayer fire dispatcher
(think1 `FUN_0045cbc0` looks up held item via inventory and invokes its
`vt[20]` aka "OnUse"). Calling convention: `__thiscall(this=TTimeBomb*)` —
appears as `__fastcall(int* param_1)` in Ghidra decomp.

Decomp behaviour (paraphrased):
```c
this->fuse       = this->delay;          // [0x3f] = [0x40]   ; +0xfc = +0x100
TActor* owner    = *(this->inv + 0xc);   // owning TPlayer / TActor
inv.RemoveOne(this);                     // FUN_0040fc80 — consume one from stack
float jitter     = (rand()%100) / 100.f;
body_pos         = FUN_0040d110(this->body);
FUN_004ccd50(this->body, body_pos, jitter); // randomize spawn offset
if (owner->GetAction() == 8) {             // 8 = "aim" (player is aiming)
    float ang   = owner->angle;            // owner[0x43]? unclear here; uses owner-anchored axis
    vec2 dir    = FUN_004aff20(ang) * this->throwspeed;   // [0x10c]
    FUN_0044dc80(this->body, dir, body_pos);              // SetLinearVelocity
    FUN_004531b0(this->body, (rand()%40)/scale);          // SetAngularVelocity (spin)
}
return 1;
```

Key bindings:
- `FUN_0040fc80(inv, item)` — inventory.removeOne (decrements stack; if 0, also
  removes the item record). This is why your existing inventory-shrink detector
  fires on bomb throws today.
- `FUN_0044dc80(body, vel, pos)` — Box2D `b2Body::SetLinearVelocity(pos, vel)`.
- `FUN_0044dde0`, `FUN_004531b0` — angular helpers.
- `FUN_0041f470(actor)` — returns the actor's `action` int (8 = aim, see memory
  notes). Bomb is only *thrown* when aiming; if not aiming, the bomb stays at
  player's feet with fuse counting down (the "drop and run" path).

After OnUse the bomb is no longer a TItem-in-inventory; it is a free TTimeBomb
in the world (`+0xfc != -1`). The next tick `vt[10]` = `FUN_00470c40` will
process it.

## Tick / explosion = `FUN_00470c40` (vtable slot 10 / +0x28)

Per-frame. Decrements `+0xfc`. When `+0xfc` reaches 0:
1. Reads world pos from body (`FUN_0040d110`).
2. **Loops `nailcount` times** (`for i in 0..*(this+0x104)`): each iteration
   `operator_new(0xc0)` and calls **`FUN_00497040`** (the known TBullet ctor)
   with `(x, y, randVx, randVy, dmg=DAT_00558f00, type=0, force=DAT_00558adc, ?)`.
   → shrapnel nails are just normal TBullets spawned in random directions.
3. `operator_new(0x7c)` → `FUN_0048e9b0(obj, x, y, radius)` — spawns a
   `TExplosion` AoE entity (this is the same fn called by the Lua-bound
   `CreateExplosion` at `FUN_00428e40`). The explosion itself ticks and applies
   AoE damage via the usual actor-hit dispatch.
4. Sets screen-shake `DAT_005747cc = const`, plays `"explosion"` sound.
5. Spawns crater sprite `spr_kraater1` via `FUN_004c5d40`.

The explosion entity at `FUN_0048e9b0` (size 0xC0 bytes) is the AoE applicator
— follow its own tick to find the `TakeDamage` calls. Damage values for AoE
and nails are read from global float constants (`DAT_00558f00`, `DAT_00558adc`,
etc.); they are not per-item Lua-tunable.

## Related sibling: `TMine` (proximity bomb, `meattrap`)
- Ctor `FUN_00471020` (vftable distinct, near 0x557 region).
- Tick `FUN_004712e0` — when `+0x94` armed-flag set and player within radius
  (`_DAT_00558d88`), calls explosion path same as TTimeBomb. No throw step.

## Hook recommendation

**Hook target: `FUN_00470aa0` @ `0x00470aa0`** (TTimeBomb::OnUse / vt[20]).

- Calling convention: `__thiscall`, single arg = `this`. Per the project's
  bullet-ctor pattern, declare as
  `void __fastcall hook_BombActivate(TTimeBomb* self, void* edx_dummy)`
  and forward `orig(self, edx)`. RET-purge: 0 (no stack args).
- At hook entry, read from `self`:
  - `body = *(void**)(self + 0x50)`; pos via `FUN_0040d110(body)`.
  - `owner = *(void**)(*(int*)(self + 0x98) + 0xc)` — the throwing TPlayer.
  - `delay = *(int*)(self + 0x100)`, `radius = *(float*)(self + 0x108)`,
    `nailcount = *(int*)(self + 0x104)`, `throwspeed = *(float*)(self + 0x10c)`.
  - item name = string at `self + 0x14` (use existing `FUN_004075d0` to read).
  - owner action via `FUN_0041f470(owner)` — if 8, it's a throw; else a drop.
  - owner angle: TPlayer angle field (existing project code already reads this
    for muzzle direction).
- Call `orig` so the engine performs the real activation, then broadcast
  `{type:"bomb_activate", item, x, y, angle, action, delay, ts}` to peers.
- Peers either: (a) spawn a cosmetic-only bomb (same Lua `Create{type=...}` to
  build the visual TTimeBomb, then mirror its body velocity / fuse), or
  (b) host-authoritative: receive the broadcast, spawn a real bomb via
  `_CreateBomb` and immediately call its native vt[20] with matching aim, so
  the explosion is fully simulated locally with the host's physics.

### Why hook here and not lower
- `FUN_00497040` (TBullet ctor) fires `nailcount` times *per explosion* — far
  too noisy.
- `FUN_0048e9b0` (explosion ctor) fires once per explosion but only after
  delay; replicating *that* gives you only the boom, not the in-flight bomb
  (peers would never see the bomb traveling, plus they need to play their own
  sound + shake).
- The Lua `_CreateBomb` binding catches both *world-spawn* (level scripts
  placing bombs) AND *player-throw*; hooking it would broadcast level-init
  noise.
- `FUN_00470aa0` fires **exactly once, only for an actively-thrown/dropped
  player bomb**, with everything you need on `this` and `this->inv`. This is
  the ideal interception point.

## Recommended wire format

Minimal payload:
```
bomb_activate {
  player_id   : peer id of activator
  item_name   : "smtimebomb" | "nailbomb" | "timebomb" | ...
  x, y        : world position at activation
  angle       : owner aim angle (radians) — peers reconstruct velocity
                from item's throwspeed table value
  thrown      : bool — true if owner action == 8 (aim), false = drop
  fuse_frames : delay (redundant; peers can read from item def, but cheap to send)
  ts          : sender tick (for fuse sync; engine runs 25Hz)
}
```

`throwspeed`, `radius`, `nailcount` are deterministic from `item_name` (Lua
`itemtable[item_name]`) — do NOT send them; peers look them up. `angle` +
`thrown` is enough to reproduce velocity. Random angular spin and small
positional jitter (the `FUN_004ccd50` call) are cosmetic; let each peer
generate its own — peers won't be pixel-perfect, but the explosion location
will be correct because the bomb travels deterministically once velocity is
set (Box2D + same delay).

For the explosion itself, no extra message is required: every peer's local
TTimeBomb tick will reach fuse=0 at the same time (assuming sync ts) and
explode locally. Damage is applied authoritatively on the host; joiner-side
explosions on puppets must NOT cause heap-corrupting puppet deaths (see the
existing puppet-hide pattern in MEMORY).

## Address summary

| addr | role |
|---|---|
| `0x00557274` | `TTimeBomb::vftable` |
| `0x00470720` | `TTimeBomb::ctor(this, x, y, name)` (size 0x110) |
| `0x00470aa0` | **`TTimeBomb::OnUse` — HOOK HERE** (vt[20]) |
| `0x00470c40` | `TTimeBomb::Tick` — fuse decrement + explode (vt[10]) |
| `0x00471840` | TTimeBomb vt[28] — likely TakeDamage / hit handler |
| `0x00471020` | `TMine::ctor` (proximity bomb) |
| `0x004712e0` | `TMine::Tick` |
| `0x00423050` | Lua `_CreateBomb` binding |
| `0x00428e40` | Lua `CreateExplosion` binding |
| `0x0048e9b0` | TExplosion ctor (AoE entity, size 0x7c) |
| `0x00497040` | TBullet ctor (used for shrapnel nails) |
| `0x0040d110` | body → world pos vec2* |
| `0x0044dc80` | b2Body::SetLinearVelocity |
| `0x004531b0` | b2Body::SetAngularVelocity |
| `0x0040fc80` | TInventory::removeOne |
| `0x0041f470` | TActor::getAction (returns int; 8 = aim) |
