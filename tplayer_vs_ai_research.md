# TPlayer Puppet vs. AI Patch — Architectural Recommendation
**Date:** 2026-06-01
**Sources:** Ghidra 12.1 decomp of Teleglitch.exe (2023-04-27 build); see
`ghidra_tplayer_ai_path.txt`, `ghidra_itempickup_etc.txt`, prior `ghidra_ai_research{,2,3,4}.txt`,
memory files `teleglitch-engine-internals.md` + `teleglitch-mob-ai.md`.

---

## 1. TPlayer think internals — triggers we must suppress on puppets

### Updated vtable map (verified from binary)
TPlayer vftable @ `0x556b14`. Slots that DIFFER from inherited TActor:
| slot | off | addr | role | notes |
|---|---|---|---|---|
| 9 | +0x24 | `0x45ef70` | Lua bindings registrar | adds SetFrame/GetAmmo/GiveStimulant/SetInvulnerable/GetInventory |
| 10 | +0x28 | `0x45cbc0` | **think1** (input + powerups + teleport + drop) | giant fn (~10 KB), gated heavily on `DAT_00574798` (input) and `DAT_005747a0` (gamestate) |
| 11 | +0x2c | `0x45bff0` | **think2** = body sprite render | gated `(byte)this+0xfd == 0` |
| 14 | +0x38 | `0x45c220` | **gameover/HUD** | first thing it does: `if (HP<=0) draw "gameover" + read DAT_005747a0`. Otherwise the in-world HUD (health, ammo). Gated by `+0xCC` death-timer flag |
| 21 | +0x54 | `0x45ebd0` | OnAction(id) | just calls FUN_0045b3d0 on `+0x9C` (inventory) — harmless |
| 24 | +0x60 | **`0x45e900`** | **TakeDamage OVERRIDE** | **memory was wrong** — TPlayer doesn't inherit TActor's at 0x44e3e0. Calls TActor's, then bumps `DAT_005747cc += dmg` (screen shake) + `DAT_005747a0[4]++` (playerdamaged counter) + on HP<=0 sets `+0xcc=0x32` + `+0xb4=2` (action=fall) |
| 31–35,38,39 | various | various | drop-item, ammo, hover-sound, sprint, accel — small per-mode helpers |

### Triggers fired by puppet's per-frame methods + gating points

| Trigger | Source | Gate to use |
|---|---|---|
| **Weapon fire / reload / drop** | think1 (`0x45cbc0`) — reads `DAT_00574798` (input device) and raw keyboard `DAT_00575330`; tons of `FUN_004b8780(scan)` polls and `vt[+0x08/+0x14/+0x1c]` calls on input device | **`byte this+0xE4` = `0x39`** (already documented). Swap `DAT_00574798` → dummy device around think1 (already wired in dllhost) — handles vt-based input. Keyboard polls bypass device. The `+0xE4` flag short-circuits ALL fire blocks in think1. |
| **Use button / pickup HUD** | think1 calls `(**(code **)(*DAT_00574798 + 0x1c))()` — USE button. If non-zero AND `FUN_0045b3d0(+0x9c)` (inv lookup) returns a TGun, it pops "AMMO UNLOADED" HUD. | Dummy input device returns 0 → no USE event. Also: puppet's `+0x9C` inventory pointer can be left empty (`0x27 != 0` checks gate everything). **Better:** zero `+0x9C` after ctor — kills ALL inventory branches. |
| **Item pickup via collision** | NONE. `TActor::vt[+0x6c]` (`0x44ef80`) is the bullet-touch dispatcher, not item-touch. `GiveItem` (`0x44e4d0`) is Lua-only — no collision callback path that auto-grabs items. Items only enter inventory via explicit Lua `GiveItem(actor, name)`. **Risk: ZERO.** | (none needed) |
| **Self-damage / hit screen-shake** | TPlayer's overridden `TakeDamage` (`0x45e900`) writes `DAT_005747cc += dmg` and bumps the gamestate counter at `DAT_005747a0[4]`. | **`byte this+0xFC` (invuln) gates the whole body.** SetInvulnerable (`0x45ede0`) sets it. ALREADY in dllhost as native. Sufficient. |
| **Death / gameover HUD** | vt[14] (`0x45c220`) draws "gameover" sprite when `HP<=0 && +0xCC==0`. ALSO writes to `local_18 + 0xcc = 0x32` from TakeDamage on death. | **Pin `+0xBC` (HP) > 0 every frame** (already wired: `pin_hp()`). Sufficient — gameover branch never triggered. Belt-and-braces: also pin `+0xCC = -1`. |
| **Movement physics** | think1 polls movement keys, writes velocity via `FUN_004b2e30(this, speed)`. `+0xE4` flag short-circuits all blocks that include movement input. Box2D body at `+0x50` is what mover writes to. | **Server-pushed position via `SetPosition` Lua binding will be overwritten by movement reads UNLESS** `+0xE4` is set. **Confirmed safe path:** set `+0xE4=1` once at ctor end, then SetPosition wins. |
| **Footstep / weapon click / hurt grunt sounds** | think1 plays "luukere_m66k", "mesilasrobot_l88b", "knife_berserker", "stimulant_noise" etc. via `FUN_004c19c0` / `FUN_004c49b0` (sound). Hurt sound is in TakeDamage at end ("zombi_hit"). | Hurt grunt is suppressed by `+0xFC` (invuln gates all of TakeDamage). Footsteps/weapon sounds are inside fire blocks → suppressed by `+0xE4`. **Sprint sound, stimulant noise** are in unguarded branches — minor cosmetic leak. Acceptable. |
| **think2 render** | `(byte)this+0xFD == 0` to draw. Leaving 0 makes puppets visible. **THIS IS WHAT WE WANT** — the whole point. Inside: input device call + camera coupling `FUN_0045b9d0()` which rewrites `DAT_00572700` (zoom). | **Save/restore `DAT_00572700` around think2** (already wired). |
| **aliveUpdate (`0x4542f0`)** | Surprise — it is a **tiny stub**: `*(t+0x1B8)=in_EAX[0]; *(t+0x1BC)=in_EAX[1]`. Just stores an XY pair. NOT the heavy alive-update implied by old memory. Safe to leave alone. | (none needed) |

**Verdict for Path A:** All required gates exist as known offsets. The existing `MP_USE_TPLAYER` scaffolding (pin_hp, set_invulnerable, force `+0xE4`, save/restore input device + zoom around think1/think2) is the correct shape. Remaining tweak: zero `+0x9C` post-ctor to nuke USE-button inv lookups defensively.

---

## 2. AI functions — Path B viability per-fn audit

All the listed AI fns interact with `DAT_005747a4` (the player ptr). Key question: do they reach beyond the TActor-base API onto TPlayer-only fields?

`FUN_0041f470(ptr) = *(int*)(ptr+0xB4)` = `action` field. Both TPlayer and TNewLiving have `+0xB4` (action). **Universal.**

| Fn | Player-ptr accesses | Verdict |
|---|---|---|
| `0x467290` TBasicAI.Perceive | `(*vt[+0x08])()` GetPos; reads nothing else on player ptr directly (passes it to AI's own `vt[+0x10]` OnTargetAcquired which just stores). | **puppet-safe even on TNewLiving** — only GetPos used. Stripped puppet has TNewLiving GetPos. |
| `0x466060` TNewLiving melee | `FUN_0041f470(p) == 6` (action==6 hit); reads `(byte)p+0xFE` (vehicle); reads `p[0x14]=+0x50` (Box2D body); reads `p[0x27]=+0x9C` (inventory — passes to `FUN_0040fea0` lookup); reads `p[0x37]=+0xDC` (some scalar). | **TNewLiving DOES have `+0x9C`** (it's TActor base — actually checking… TNewLiving size 0x190+, `+0x9C` exists but **for TNewLiving it's NOT inventory** — it's a different mover/sub-object pointer). Calling `FUN_0040fea0` on the puppet's `+0x9C` interpreted as inventory → garbage lookup. **NEAR-CRASH.** Could be patched but brittle. **TPlayer-required.** |
| `0x464fe0` TNewLiving detector | `DAT_005747a4[0x27]` (inventory lookup for "detector2" item via `FUN_0040fea0`); GetPos. | Same `+0x9C` problem. **TPlayer-required for safety.** |
| `0x465680` TNewLiving CanSeePlayer | Reads GetPos, does LoS raycast. (Need full trace — likely just GetPos.) | Likely **puppet-safe** — only GetPos + LoS. |
| `0x4534e0` TEnemy helper14 | Same pattern as detector — inventory lookup `DAT_005747a4[0x27]` + GetPos. | **TPlayer-required.** |
| `0x453e80` TEnemy helper33 | GetPos + `FUN_004bf260(self+0x70, DAT_005747a4)` (stores ptr to AI memory). | **puppet-safe** — just stores ptr. |
| `0x4547c0` TEnemy helper35 | GetPos + `FUN_004bf7a0(self+0x70)` (live check on stored target). | **puppet-safe.** |
| `0x4551f0` TEnemy Think | Switch on `+0x2D` (action) calling vt slots +0x84..+0xB0. Calls `FUN_00457130` (uses DAT_005747a4). | Indirect — depends on `FUN_00457130`. Worth a separate decomp; likely GetPos + LoS. |

**Verdict for Path B:** At least 3 fns (`0x466060`, `0x464fe0`, `0x4534e0`) read `DAT_005747a4 + 0x9C` and treat it as an inventory pointer. Stripped TNewLiving puppets have a different object type at `+0x9C` (mover or null). Patching Path B means either:
(a) **Hook the AI fns to redirect ONLY the inventory reads** (3+ separate hooks at `mov eax,[ecx+0x9c]` sites), or
(b) **Make the puppet's `+0x9C` field point to a fake-inventory stub** that returns "no detector / no powerknife" for all queries (`FUN_0040fea0` returns 0 → branches skipped).

Option (b) is small and clean — **a single allocation of a stub C++ object and `+0x9C` patch** makes all 3 AI fns no-op safely on a TNewLiving puppet. This dramatically reduces Path B's footprint vs. hooking each fn.

---

## 3. Item pickup / collision side-effects on TPlayer puppets

- **Collision callback for items: NONE on TActor.** Items enter inventory ONLY via Lua `GiveItem` (binding `0x44e4d0`). The TActor collision dispatcher (`0x44f210`) routes by `+0x5c` type tag: 8=bullet, 16=actor, 32=physics, 256=shield. **No item-touched branch.**
- **GiveItem is global Lua**, not auto. Puppet won't auto-grab host's items.
- **Drop behavior:** TPlayer vt[31] (`0x460b00`) is a 250-line drop/explode helper but is *called by* think1's drop key handler — gated by `+0xE4` along with all other input → suppressed.

**Net risk: ZERO.** A TPlayer puppet placed next to host's items will NOT pick them up.

---

## 4. Camera / input / HUD coupling — exhaustive audit

Xrefs to `DAT_005747a4` go to 51 distinct fns. Categorization:

| Category | Functions | Behavior with swap-around-AI-think |
|---|---|---|
| **AI consumers** (target reads, fine to swap) | `0x46xxxx` family (Perceive, melee, detector, CanSeePlayer, TEnemy helpers) | Reads only during their tick — swap window covers them. |
| **Lua bindings** `get_main_player` | `0x4293a0`, `0x429410` | Called from Lua scripts. If a script calls `get_main_player()` *during* mob think, it would see the swapped puppet. Mitigation: don't yield to Lua inside the hook window (engine is single-threaded; AI think doesn't call Lua). **Safe.** |
| **Camera / view code** | `0x40f680`, `0x415950`, `0x415ee0`, `0x424410`, `0x428700/30`, `0x42b2a0/d0` | Camera reads `DAT_005747a4` once per frame in the main render loop — OUTSIDE think. As long as swap is balanced (restore before return), camera sees host. ✓ |
| **HUD code** `0x43xxxx`, `0x437*`, `0x43d*`, `0x43c*` | Drawn AFTER think in main loop — outside swap window. ✓ |
| **Cheat/admin** `0x49xxxx`, `0x4a014e` (writer) | Editor mode — not relevant. |
| **save/load** `0x49aa10`, `0x49a5c0` | Once per game state change. Not during think. ✓ |

**Other globals to watch:**
- `DAT_00574798` (input device) — read by think1; already handled by dummy swap.
- `DAT_00572700` (view zoom) — written by think2 sub `FUN_0045b9d0`; already save/restore wired.
- `DAT_005747a0` — separate "gamestate" struct ptr (stimulant timer, playerdamaged counter, ammo counts). TPlayer think1+TakeDamage write into it. **NEW ISSUE for Path A:** If puppet's TakeDamage runs (e.g. host attacks puppet for PvP), it increments `DAT_005747a0[4]` ("playerdamaged"). Mitigation: invuln flag `+0xFC` gates the whole TakeDamage body before the increment.
- `DAT_005747b4` — another gamestate sub-struct (powerup tables); read in melee-check sub. Read-only on the AI side.
- `DAT_005747cc` — screen-shake counter; TakeDamage writes. Gated by `+0xFC`.

**No HUD code caches a player ptr at level start** (per Xref scan — all HUD code dereferences `DAT_005747a4` per-frame). So save/restore around think is sufficient.

---

## 5. Path C — Hybrid sketch

Two hybrids emerge from the analysis:

**C1 — TPlayer puppet + fake-inventory stub** (recommended hybrid)
- Joiner puppets are full TPlayer instances → free animation, free body sprite, no `+0x9C` trap.
- Per-mob-think `DAT_005747a4` swap (Path A's task #11 plan).
- Hook `+0xE4` + `+0xFC` + `+0xCC` pinning + dummy input device wraps already done.
- ZERO inventory needed — TPlayer's `+0x9C` is initialized by ctor anyway.

**C2 — TNewLiving puppets + fake-inventory stub + targeted AI hooks** (cheaper but weaker)
- Keep stripped puppets (no animation).
- Patch puppet `+0x9C` to point to stub returning empty inv.
- Hook only the AI fns that **read xy** (Perceive, melee, detector, CanSeeP, TEnemy h14/h33/h35/Think) — wrap them with a `DAT_005747a4` swap. **8 hooks vs Path A's 2.**
- No animation, no shooting visuals — known limitation.

**C3 — host runs a hidden real-TPlayer per remote, AI sees its own stripped puppets.** Two parallel object trees. Lots of bookkeeping; rejected: doubles every state sync, mob aggro still wrong, no benefit over C1.

---

## 6. Risk-ranked recommendation

### Recommendation: **Path A (TPlayer puppets) — proceed**

**Reasoning:**
1. **Path A's "unknown unknowns" are now small.** Every concern from the old memory note (camera coupling, death cascade, item auto-pickup, hurt screen-shake, inventory crashes) has a verified gate at a known byte/word offset. Item pickup is structurally impossible (no collision callback). Damage is fully contained behind `+0xFC` invuln. Death is contained behind `+0xBC` HP pin. Input is contained behind `+0xE4` + dummy input device. **All gates are already wired in dllhost behind `MP_USE_TPLAYER`.**
2. **Path B requires MORE dllhost C++** (8 AI-fn MinHooks vs Path A's 2 think wraps). Each hook is a new ABI-correctness risk (see the bullet-ctor stack-leak saga). The `+0x9C` inventory trap (3 fns) means Path B can't skip a fake-inv stub anyway — so it inherits Path A's complexity AND adds hook overhead.
3. **Path B "unknown unknown":** every game update could add new AI fns reading `DAT_005747a4` that we'd need to discover and hook. Path A doesn't care — the swap covers all current and future readers within the think window.
4. **Animation is the long-stated wall.** Three confirmed crash attempts (frame poke, action sync, walk-only action sync) prove stripped puppets cannot animate. **Only Path A delivers the visible-remote-player goal.**
5. **Revertibility is symmetric.** Both paths gate on `_G.MP_USE_TPLAYER` (Path A) / `MP_USE_AIHOOKS` (Path B) — single flag.

### Risk callouts for Path A (deploy in this order)

1. **First-flight validation:** 2-instance flat-map join. Watch for AV in TakeDamage (invuln gate) and gameover (HP pin). The existing `pin_hp` + `set_invulnerable` cover both — verify with a deliberate mob hit on the puppet.
2. **`DAT_005747a0` writes from TPlayer TakeDamage** (the `playerdamaged` counter and stimulant table). Confirmed gated by `+0xFC`. If you ever clear invuln to allow puppet hit reactions, you'll need to also save/restore `DAT_005747a0`.
3. **Sound leaks:** stimulant sound and sprint sound aren't gated by `+0xE4`. Cosmetic, ignorable. Fix later by also pinning the stimulant timer to 0 and the sprint flag at `+?`.
4. **Per-mob-think `DAT_005747a4` swap (the actual AI redirect — task #11):** still unimplemented. This is the WORK that remains. Path:
   - Hook `TNewLiving::Think1` (`0x464040`) AND `TEnemy::Think1` (`0x4551f0`).
   - On entry: find nearest live player (host local OR any joiner-puppet TPlayer) to this mob via a maintained list, save `DAT_005747a4`, write nearest.
   - On exit: restore.
   - **One subtle gotcha:** `FUN_004551f0` (TEnemy think) bails immediately if `DAT_00572707 == '\0'` (a global "game running" flag) — verify the swap happens AFTER that early-out, or before — pick before-the-tick is fine, just don't forget to restore on the early-exit path.
5. **HP pin during a real PvP damage event** to a TPlayer puppet: the pin will prevent puppet death. That's intended — host doesn't run puppet's death cleanup. PvP "kill the joiner" must instead be communicated via the network and applied by the joiner's own host-side player.

### Revert plan
Single Lua line `_G.MP_USE_TPLAYER = false` reverts to current stripped-puppet behavior. Aggro patch is independent (`MP_USE_AIHOOKS` would gate it). They compose: Path A without AI hooks = animated puppets that mobs ignore; Path A + AI hooks = full multiplayer aggro.

### Concrete next steps
1. Run the 2-instance Path A flight test that's already wired but unproven.
2. Implement the per-mob `DAT_005747a4` swap in dllhost (hook `0x464040` and `0x4551f0` — TNewLiving and TEnemy Think1 entry points). Pure C++ — no Lua side.
3. Verify mobs aggro the closer puppet by spawning a single zombie equidistant between host and joiner and walking the joiner closer.
