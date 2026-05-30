# Known Issues

## 🔴 Intermittent joiner heap-corruption crash (UNRESOLVED — deferred 2026-05-30)

**Symptom:** The JOINER crashes intermittently — roughly *every other* join/start.
Sometimes mid-`apply_item_list` (~4 s after join), sometimes a few seconds after
picking up items. The host is unaffected. Manifests as a hard process death
(TCP `ECONNRESET` at the relay), no Lua error (so it's a native crash, not a
caught Lua exception).

**Nature:** Heap corruption. WinDbg victim stack (prior sessions) bottoms out in
`MSVCR110!realloc -> lua52!luaL_gsub -> lua_pcallk` — i.e. a later allocation
trips over already-corrupted heap metadata. The real out-of-bounds write / UAF
happened *earlier* and elsewhere. Lua is memory-safe, so the corruptor is a Lua
call into an engine C-binding with bad args (OOB write / double-free / UAF on a
freed-and-recycled pointer). Reproduces with all native dllhost hooks disabled,
so it is NOT in version.dll.

### What has been tried (don't just repeat these)
- **`safe_delete()` liveness-gating** (commit af3eff7, 2026-05-30): gated every
  stale-handle `:Delete()` (item pickup, leave, disconnect, apply orphan loop)
  behind a fresh world-scan pointer check. Hardens real UAF/double-free hazards
  but did NOT eliminate the crash — kept as defense-in-depth.
- **Full PageHeap + cdb**: the textbook tool, but attempted repeatedly across
  sessions without landing a root cause. Blockers seen: (a) the IFEO reg key is
  HKLM = needs an ELEVATED shell (a non-admin `reg import` fails with "Error
  accessing the registry"); (b) the crash is intermittent, so a single run often
  doesn't trip it. PageHeap is still the most likely to *finally* pin it IF run
  elevated AND the joiner then loots until it faults (PageHeap makes the bad
  write fault deterministically at its exact instruction).
- **Plain cdb (no PageHeap)**: only yields the victim stack (realloc/luaL_gsub),
  not the cause.

### Recommended next approaches (cheapest first)
1. **Lua flushed per-op tracer (no admin):** add `mp.log_file:flush()` after each
   `logf`, or a dedicated trace point with flush, around the hot suspects
   (apply_item_list adopt/create/orphan, handle_item_picked, diff_inventory /
   diff_ammo, handle_mob_snapshot spawn, handle_snapshot puppet SetPosition).
   Crash a handful of times; the common LAST flushed op localizes the culprit.
   Works *with* the intermittent + delayed nature where victim-stacks fail.
2. **Subsystem bisect across runs:** toggle off one subsystem per run and see
   which removal stops the crash. `_G.MP_BISECT_PUPPET_MOVE=false` already gates
   mob-puppet SetPosition; add similar flags for item-sync apply, player-puppet
   SetPosition, and the bullet/native drain.
3. **Top unaddressed static suspect — recycle race on per-frame SETTERS:** the
   alive cache (`refresh_alive_cache`) is a pointer-STRING set; it cannot tell
   "ptr X still alive" from "X freed, new object recycled to X". So
   `handle_snapshot` SetPosition (player puppet), mob-puppet move, and melee
   SetHealth can dispatch on a recycled/type-confused entity → silent scribble.
   Fix = identity-token cache: store the entity's `mp_*` SetName in the cache and
   verify it before any setter (deferred during the 2026-05-30 work).
4. **Elevated PageHeap** (only if 1–3 don't converge): from an Admin shell
   `reg import enable_pageheap.reg`, relaunch the joiner under cdb, loot until it
   faults. Revert with `reg import disable_pageheap.reg`. Game will be slow.

See `~/.claude/.../memory/teleglitch-engine-internals.md` ("Heap corruptor ROOT
CAUSE + fix") for the offset-level detail.
