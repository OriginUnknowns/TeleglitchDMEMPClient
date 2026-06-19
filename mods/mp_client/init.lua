-- mp_client.lua — Teleglitch multiplayer client.

local function dump_err(label, err)
    local f = io.open("mp_client_startup_error.txt", "a")
    if f then
        f:write(os.date("%H:%M:%S ") .. label .. ": " .. tostring(err) .. "\n")
        f:close()
    end
end

-- Native modloader bridge (modloader dllhost). Optional: if the DLL isn't
-- installed, we just skip and continue with the pure-Lua mod.
local mp_native = nil
do
    local loader, lerr = package.loadlib("version.dll", "luaopen_mp_native")
    if loader then
        local ok, mod = pcall(loader)
        if ok and type(mod) == "table" then
            mp_native = mod
            if mp_native.log then mp_native.log("mp_client: native bridge connected") end
            -- Install all native hooks. These do NOT cause the pre-existing
            -- apply_item_list spawn-burst crash (verified by disabling all
            -- hooks and reproducing the same crash anyway).
            if mp_native.install_bullet_hook then
                local hook_ok = mp_native.install_bullet_hook()
                if mp_native.log then mp_native.log("install_bullet_hook returned " .. tostring(hook_ok)) end
            end
            -- Passivate remote TPlayers: skip their per-frame think so they
            -- don't steal input/camera or shoot themselves (we drive them).
            if mp_native.install_passive_player_hooks then
                local ok = mp_native.install_passive_player_hooks()
                if mp_native.log then mp_native.log("install_passive_player_hooks returned " .. tostring(ok)) end
            end
            -- central_hit + takedamage hooks DISABLED (2026-05-29). They fed
            -- the old consume_hit -> mob_damage path, which bullet replication
            -- has fully superseded — so they're redundant (and risk double-
            -- counting). Removing them also shrinks the native code-patch
            -- surface while we chase the remaining heap corruptor. Only the
            -- bullet ctor hook (needed for the joiner bullet drain) stays.
            -- central_hit + takedmg2 (0x4ee80, 0x4e3e0) hooks DISABLED —
            -- signature was wrong (last call crashed host on bullet hit).
            -- Direct damage on host parked for future RE session.
            _G.MP_NATIVE = mp_native
            local f = io.open("mp_client_native.txt", "w")
            if f then
                f:write("native bridge active. hello() returned: " ..
                    tostring(mp_native.hello and mp_native.hello() or "(no hello)") .. "\n")
                f:close()
            end
        else
            dump_err("luaopen_mp_native call", mod)
        end
    else
        -- DLL not installed; this is fine, we just run without native hooks.
        local f = io.open("mp_client_native.txt", "w")
        if f then f:write("native bridge NOT available (" .. tostring(lerr) .. ")\n"); f:close() end
    end
end

local ok_sock, socket = pcall(require, "socket")
if not ok_sock then dump_err("require(socket)", socket); return end

local ok_json, json = pcall(dofile, "mods/mp_json.lua")
if not ok_json then dump_err("dofile(mp_json)", json); return end

local ok_cfg, config = pcall(dofile, "mods/mp_config.lua")
if not ok_cfg then dump_err("dofile(mp_config)", config); return end

local ok_id, identity = pcall(dofile, "mods/mp_identity.lua")
if not ok_id then dump_err("dofile(mp_identity)", identity); return end

local resolved_name, name_source = identity.get_name(config.name_override)
config.name = resolved_name
config.name_source = name_source

dump_err("init OK — name=" .. tostring(config.name) .. " source=" .. tostring(config.name_source), "(start)")

-- ============ STATE ============
local mp = {
    sock = nil,
    rx_buf = "",
    my_id = nil,
    host_id = nil,
    is_host = false,
    puppets = {},        -- map[player_id] = { obj, name, hp, last_x, last_y }
    mob_puppets = {},
    host_mobs = {},
    next_mob_id = 1,
    -- Item sync: host-authoritative, ID-based.
    -- HOST: Create-wraps assign monotonic IDs at spawn. After level loads,
    --       sends item_list snapshot once. Per-tick poll detects local pickups
    --       (vanished objs) -> broadcasts {item_picked, id}.
    -- JOINER: tracks local spawns for cleanup. On item_list receive: wipes
    --         local items and respawns from host's list, keyed by host's IDs.
    -- Receiver of item_picked: items[id]:Delete(); items[id]=nil.
    items = {},               -- id -> { obj, type, x, y }
    item_obj_to_id = {},      -- obj_table -> id (dedup by Lua table identity; ptr is recycled by engine!)
    next_item_id = 1,         -- host-only counter
    item_snapshot_sent = false,
    item_snapshot_received = false,
    pending_item_list = nil,  -- joiner: received before level loaded
    cleanup_done = false,
    last_send = 0,
    last_mob_send = 0,
    last_label_update = 0,
    last_pickup_scan = 0,
    pickup_scan_start_after = 0,
    test_mode = false,
    coro_running = false,
    log_file = nil,
    session_seed = nil,
    last_inv_send = 0,
    last_inv_sent_counts = nil,
    peer_inventories = {},  -- player_id -> {type -> count}
}

local function logf(fmt, ...)
    local msg = string.format(fmt, ...)
    if not mp.log_file then mp.log_file = io.open("mp_client.log", "a") end
    if mp.log_file then
        mp.log_file:write(os.date("%H:%M:%S ") .. msg .. "\n")
        mp.log_file:flush()
    end
    if console and console.Print then pcall(function() console.Print("[MP] " .. msg) end) end
end

logf("mp_client.lua loading…")

-- Back up the current (good) settings.lua to mods/ where Steam verify won't touch it.
-- Future launches can restore from this backup if settings.lua was corrupted by a hard kill.
pcall(function()
    local src = io.open("settings.lua", "rb")
    if src then
        local content = src:read("*a")
        src:close()
        if content and #content > 50 then  -- only backup if non-empty + non-trivial
            local dst = io.open("mods/settings_backup.lua", "wb")
            if dst then dst:write(content); dst:close() end
        end
    end
end)

-- ============ REGISTER PUPPET TYPE ============
if not soldatbase then
    logf("ERROR: soldatbase not loaded; cannot register puppet type")
else
    enemylist.mp_remote_player = {
        sprite = "spr_mees",
        damagedsprite = "spr_mees",
        health = 999999,
        itemdropchance = 0,
        meleedamage = 0,
        meleecooldown = 999999,
        painchance = 0,
        painthreshold = 999999,
        fallthreshold = 999999,
        dismemberthreshold = 999999,
        bulletforcemult = 0,
        hitsound = "s6dur_l88b",
        seeplayersound = "s6dur_l88b",
        lostplayersound = "s6dur_l88b",
        bullethitsound = "zombi_hit",
        painsound = "zombi_valu",
        deathsound = "vastane_kukkub",
        huntsound = "s6dur_l88b",
        huntsoundchance = 0,
        -- AI fields aggressively neutered. alertradius=0 keeps "basic" AI from
        -- targeting players, but the AI still rotates each tick to face — set
        -- shootfrequency huge and ranges to 0 so nothing in the AI tries to act.
        ai = {
            aitype = "basic",
            alertradius = 0,
            visionradius = 0,
            shootfrequency = 999999,
            shootrange = 0,
            optimalrange = 0,
            minimumrange = 0,
            patrolprobability = 0,
        },
        movingsystem = {
            movertype = "walk",
            maxspeed = 0, accelration = 0,
            stepsound = "s6dur_samm", animspeedmult = 0.1, stepsounddelay = 999999,
            turnspeed = 0,
        },
        -- Animations neutered (frozen at frame 0). Driving the puppet's
        -- animation is IMPOSSIBLE without crashing — proven via frame poke,
        -- action+attack-frames, and action+walk-only (all null-deref the
        -- engine's actor render/anim code). Remote-player animation needs the
        -- TPlayer rework, not an enemy puppet.
        animations = {
            ["walk"] = { startf = 0, endf = 0, speed = 0, repeating = true },
            ["pain"] = { startf = 0, endf = 0, speed = 0, repeating = false },
            ["fall"] = { startf = 0, endf = 0, speed = 0, repeating = false },
            ["rise"] = { startf = 0, endf = 0, speed = 0, repeating = false },
            ["hit"]  = { startf = 0, endf = 0, speed = 0, repeating = false },
        },
    }
    MakeParent(enemylist.mp_remote_player, soldatbase)
    logf("registered enemylist.mp_remote_player")
end

-- ============ REGISTER INERT VARIANTS FOR ALL MOB TYPES ============
do
    local enemy_type_names = {}
    for k, _ in pairs(enemylist) do
        if type(k) == "string" and string.sub(k, 1, 3) ~= "mp_" then
            table.insert(enemy_type_names, k)
        end
    end
    for _, type_name in ipairs(enemy_type_names) do
        local inert_name = "mp_remote_" .. type_name
        local parent = enemylist[type_name]
        local inert_ms = {}
        local parent_ms = parent.movingsystem or {}
        for k, v in pairs(parent_ms) do inert_ms[k] = v end
        inert_ms.maxspeed = 0
        inert_ms.minspeed = 0
        inert_ms.accelration = 0
        inert_ms.minaccelration = 0
        inert_ms.maxaccelration = 0
        inert_ms.stepsounddelay = 999999
        inert_ms.turnspeed = 0  -- AI cannot rotate puppet; SetAngle direct-setter still snaps

        -- MINIMAL inert def: inherit AI from parent (so the puppet remains a
        -- full Soldat class with GetHealth/SetHealth) but zero out movement
        -- and disable damage-dealing. Suppresses sounds via inert_ms only.
        local inert_def = {
            health = 999999,   -- prevents local puppet death (engine cleanup crashes)
            meleedamage = 0,
            meleecooldown = 999999,
            itemdropchance = 0,
            movingsystem = inert_ms,
        }
        enemylist[inert_name] = inert_def
        MakeParent(enemylist[inert_name], parent)
    end
    logf("registered %d inert mob variants", #enemy_type_names)
end

-- ============ INVENTORY ITEM DETECTION ============
-- pl:GiveItem internally creates entities the engine sees as items. We don't
-- want those tracked as world items. Wrap CreatePlayer so right after the
-- player exists we wrap pl:GiveItem; that wrap sets a flag for the duration
-- of the call so our Create wraps skip tracking.
local in_giveitem = false

if type(CreatePlayer) == "function" then
    local orig_CreatePlayer = CreatePlayer
    CreatePlayer = function(...)
        local pl = orig_CreatePlayer(...)
        if pl and type(pl) == "table" and type(pl.GiveItem) == "function"
           and not rawget(pl, "_mp_give_wrapped") then
            local orig_give = pl.GiveItem
            local give_count = 0
            pl.GiveItem = function(self, type_name, ...)
                -- Block pickups while dead. Initial inventory grants happen
                -- at level start when is_dead=false, so this only filters
                -- spectate-time pickups (engine touch-pickup, etc).
                if mp.is_dead then
                    logf("GIVEITEM blocked (dead, spectating): type=%s", tostring(type_name))
                    return
                end
                give_count = give_count + 1
                logf("GIVEITEM #%d type=%s in_giveitem_was=%s",
                    give_count, tostring(type_name), tostring(in_giveitem))
                local prev = in_giveitem
                in_giveitem = true
                local ok, err = pcall(orig_give, self, type_name, ...)
                in_giveitem = prev
                if not ok then error(err) end
            end
            -- Wrap DropItem too. Logs every call so we can tell whether the
            -- engine's drop key handler reaches us via the Lua binding.
            if type(pl.DropItem) == "function" then
                local orig_drop = pl.DropItem
                pl.DropItem = function(self, ...)
                    local args = {...}
                    logf("DROPITEM CALLED arg1=%s nargs=%d", tostring(args[1]), select("#", ...))
                    return orig_drop(self, ...)
                end
                logf("DROPITEM wrap installed on player")
            end
            pcall(function() rawset(pl, "_mp_give_wrapped", true) end)
            logf("GIVEITEM wrap installed on player")
        end
        return pl
    end
end

-- ============ LEVEL CLEAR HOOK ============
-- GenerateLevel retries on placement failure (`while tries<20 ... level.Clear() ...`).
-- Each retry spawns items that our wraps track. On failure engine does
-- level.Clear() (destroys C-side state) but our Lua mp.items / joiner_pre_snapshot
-- list still holds refs. Across retries we accumulate ghosts → memory bloat → OOM.
-- Reset our tracking on every level.Clear so retries start fresh.
if type(level) == "table" and type(level.Clear) == "function" then
    local orig_clear = level.Clear
    level.Clear = function(...)
        mp.items = {}
        mp.item_obj_to_id = {}
        mp.next_item_id = 1
        mp.host_mobs = {}
        mp.next_mob_id = 1
        mp.containers = {}      -- id -> {x, y, sprite, items={type,...}, obj=cont}
        mp.next_container_id = 1
        mp.container_obj_to_id = {}  -- pointer string -> id
        mp.container_snapshot_sent = false
        -- Puppets / mob_puppets reference engine entities that level.Clear
        -- destroys. Discard our Lua-side handles so handle_join doesn't keep
        -- returning early on stale wrappers (which caused ghost puppets).
        mp.puppets = {}
        mp.mob_puppets = {}
        -- joiner_pre_snapshot list is reset in apply_item_list, no need here
        return orig_clear(...)
    end
    logf("wrapped level.Clear to reset MP tracking on level retries")
end

-- ============ MENU PAUSE OVERRIDE ============
-- The engine's ESC handler likely resets the active page back to
-- "mainmenu". Two complementary intercepts:
--   1) Wrap menu.SetPage so any call to switch to "mainmenu" while we're
--      in an MP game gets redirected to "mp_pause". A bypass flag lets
--      our own Exit-to-Title button reach the real mainmenu.
--   2) Wrap menu.SetState as a backup (in case the engine does call it).
-- Both wraps also log so we can tell which path the engine uses.
mp._pause_bypass = false   -- set true by Exit-to-Title to allow real mainmenu
if type(menu) == "table" and type(menu.SetPage) == "function" then
    local orig_SetPage = menu.SetPage
    menu.SetPage = function(name, ...)
        -- Defensive: callers occasionally invoke this with a button
        -- userdata instead of a page name (engine internals or a Lua
        -- typo). Just pass through unmodified — never try to compare
        -- a userdata against the "mainmenu" string or our redirect
        -- logic, and never log it (the verbose log was hammering
        -- mp_client.log at >1Hz).
        if type(name) ~= "string" then
            return orig_SetPage(name, ...)
        end
        if name == "mainmenu" and mp.in_game and not mp._pause_bypass then
            name = "mp_pause"
        end
        return orig_SetPage(name, ...)
    end
    logf("wrapped menu.SetPage (intercepts mainmenu→mp_pause in MP)")
end
if type(menu) == "table" and type(menu.SetState) == "function" then
    local orig_SetState = menu.SetState
    menu.SetState = function(state, val, ...)
        if state == "game" and val == false and mp.in_game then
            logf("SetState('game', false) in MP — pre-targeting mp_pause")
            pcall(function() menu.SetPage("mp_pause") end)
        end
        return orig_SetState(state, val, ...)
    end
    logf("wrapped menu.SetState")
end

-- ============ DETERMINISTIC LEVEL GEN ============
-- C-side cstartfrom() consumes math.random before reaching GenerateLevel, so
-- our pre-StartFrom math.randomseed() drifts. Re-apply session_seed inside
-- GenerateLevel so both clients enter module-shuffle with identical RNG state.
if type(GenerateLevel) == "function" then
    local orig_GenerateLevel = GenerateLevel
    GenerateLevel = function(ldata)
        if mp.session_seed then
            math.randomseed(mp.session_seed)
            logf("GenerateLevel: re-seeded to %s", tostring(mp.session_seed))
        end
        -- Instrumentation: count math.random calls + checksum first/last values
        local orig_random = math.random
        local count = 0
        local first_vals, last_vals = {}, {}
        math.random = function(...)
            count = count + 1
            local r = orig_random(...)
            if count <= 5 then table.insert(first_vals, tostring(r)) end
            return r
        end
        local result = orig_GenerateLevel(ldata)
        math.random = orig_random
        logf("GenerateLevel: math.random called %d times; first5=[%s]",
            count, table.concat(first_vals, ","))
        return result
    end
    logf("wrapped GenerateLevel for deterministic level gen")
end

-- ============ WIRE PROTOCOL (length-prefixed JSON) ============
local function pack_u32_be(n)
    return string.char(
        bit32.band(bit32.rshift(n, 24), 0xff),
        bit32.band(bit32.rshift(n, 16), 0xff),
        bit32.band(bit32.rshift(n, 8),  0xff),
        bit32.band(n, 0xff))
end
local function unpack_u32_be(s)
    local a, b, c, d = string.byte(s, 1, 4)
    return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end

local function send_msg(msg)
    if not mp.sock then return end
    local body = json.encode(msg)
    local frame = pack_u32_be(#body) .. body
    -- Non-blocking socket: partial sends require a loop. Critical guard:
    -- bound the loop iterations + abort on no-progress, otherwise a
    -- persistently-full kernel buffer (engine not pumping reads) hangs
    -- the whole game in this loop ("not responding"). On hang, abort
    -- the send and disconnect — better than locking the game forever.
    local sent = 0
    local total = #frame
    local max_iters = 100
    local last_sent = -1
    local stuck = 0
    for i = 1, max_iters do
        if sent >= total then return end
        local ok, err, partial = mp.sock:send(frame, sent + 1)
        sent = ok or partial or sent
        if not ok then
            if err == "timeout" then
                if sent == last_sent then
                    stuck = stuck + 1
                    if stuck >= 5 then
                        logf("send STUCK at %d/%d — disconnecting", sent, total)
                        mp.sock:close(); mp.sock = nil; return
                    end
                else
                    stuck = 0
                    last_sent = sent
                end
            else
                logf("send error: %s sent=%d/%d — disconnecting",
                    tostring(err), sent, total)
                mp.sock:close(); mp.sock = nil; return
            end
        end
    end
    logf("send hit max_iters at %d/%d — disconnecting", sent, total)
    mp.sock:close(); mp.sock = nil
end

local function try_recv_msg()
    if #mp.rx_buf < 4 then return nil end
    local len = unpack_u32_be(mp.rx_buf)
    if len > 1024 * 1024 then
        logf("oversize frame %d — bailing", len)
        mp.sock:close(); mp.sock = nil; mp.rx_buf = ""
        return nil
    end
    if #mp.rx_buf < 4 + len then return nil end
    local body = string.sub(mp.rx_buf, 5, 4 + len)
    mp.rx_buf = string.sub(mp.rx_buf, 5 + len)
    local ok, msg = pcall(json.decode, body)
    if not ok then
        logf("json decode error: %s", tostring(msg))
        return nil
    end
    return msg
end

-- ============ HELPERS ============
local function get_obj_pos(obj)
    if not (obj and obj.GetPosition) then return nil, nil end
    local ok, x, y = pcall(function() return obj:GetPosition() end)
    if ok and x and y then return x, y end
    return nil, nil
end

-- ============ ITEM TRACKING (ID-based) ============
-- HOST: assigns a monotonic id to every spawned item, stored in mp.items[id].
-- JOINER: only tracks AFTER item_list snapshot arrives. Pre-snapshot local spawns
-- are wiped wholesale, then we recreate from host's snapshot keyed by host's ids.

-- DO NOT call methods on tracked item objs after spawn — the engine may have deleted
-- them (R6025 pure virtual). Liveness is detected by pointer comparison against
-- GetObjectsInCircle results (just reading .pointer fields, no method dispatch).

-- Wrap obj.Delete so we know when the engine destroys an item (level-gen overlap
-- resolution, scripts, etc). Keeps mp.items / item_ptr_to_id always accurate
-- without needing a post-hoc world-scan filter.
local function hook_item_delete(obj, on_deleted)
    if not (obj and type(obj) == "table") then return end
    local orig = obj.Delete
    if type(orig) ~= "function" then return end
    obj.Delete = function(self, ...)
        pcall(on_deleted)
        return orig(self, ...)
    end
end

local function track_item_host(obj, type_name, x, y)
    if in_giveitem then
        logf("TRACK SKIP-GIVE host type=%s x=%.2f y=%.2f", tostring(type_name), x or -999, y or -999)
        return
    end
    if not (obj and type_name) then return end
    if type(obj) ~= "table" then
        logf("TRACK SKIP-NONTBL host type=%s obj_type=%s", tostring(type_name), type(obj))
        return
    end
    -- Dedup by Lua TABLE identity, NOT C++ pointer. Engine recycles ptrs
    -- across destroyed objects, so ptr-based dedup falsely skips new items.
    if mp.item_obj_to_id[obj] then
        return
    end
    local id = mp.next_item_id
    mp.next_item_id = id + 1
    local wx, wy = get_obj_pos(obj)
    mp.items[id] = { obj = obj, type = type_name, x = wx or x or 0, y = wy or y or 0 }
    mp.item_obj_to_id[obj] = id
    logf("TRACK HOST id=%d type=%s pos=(%.2f,%.2f) src=(%.2f,%.2f)",
        id, type_name, wx or x or 0, wy or y or 0, x or -999, y or -999)
    -- If this spawn happened after the initial snapshot was sent, broadcast it so
    -- joiners can spawn the same item locally.
    if mp.item_snapshot_sent and mp.sock then
        send_msg({ type = "item_spawned",
                   item = { id = id, type = type_name,
                            x = mp.items[id].x, y = mp.items[id].y } })
        logf("broadcast item_spawned id=%d type=%s", id, type_name)
        -- Loot ejection: if this new item appeared right next to a tracked
        -- container that holds this type, treat it as a loot pop. Decrement
        -- the container's shadow + broadcast so joiners stay in sync.
        local CONTAINER_LOOT_R2 = 4.0   -- ~2u radius; containers are 5-7u wide
        for cid, c in pairs(mp.containers or {}) do
            if c.items and #c.items > 0 then
                local dx, dy = (c.x or 0) - mp.items[id].x, (c.y or 0) - mp.items[id].y
                if dx*dx + dy*dy <= CONTAINER_LOOT_R2 then
                    for i, it in ipairs(c.items) do
                        if it == type_name then
                            table.remove(c.items, i)
                            logf("CONTAINER LOOT id=%d ejected %s (n=%d remain)",
                                cid, type_name, #c.items)
                            send_msg({ type = "container_item_taken",
                                       container_id = cid, item_type = type_name })
                            break
                        end
                    end
                    break
                end
            end
        end
    end
end

local joiner_pre_snapshot_items = {}  -- list of {obj, type, x, y}
local joiner_pre_snapshot_objs = {}   -- obj_table -> true for dedup by identity
local joiner_track_seq = 0
local function track_item_joiner_pre(obj, type_name)
    if in_giveitem then
        logf("TRACK SKIP-GIVE join type=%s", tostring(type_name))
        return
    end
    if not (obj and type(obj) == "table") then
        logf("TRACK SKIP-NONTBL join type=%s obj_type=%s", tostring(type_name), type(obj))
        return
    end
    if joiner_pre_snapshot_objs[obj] then return end
    joiner_pre_snapshot_objs[obj] = true
    local wx, wy = get_obj_pos(obj)
    table.insert(joiner_pre_snapshot_items, { obj = obj, type = type_name, x = wx, y = wy })
    joiner_track_seq = joiner_track_seq + 1
    logf("TRACK JOIN seq=%d type=%s pos=(%.2f,%.2f)",
        joiner_track_seq, tostring(type_name), wx or -999, wy or -999)
end

-- Scan the world for item-like entities and Delete them. Used by joiner before
-- spawning the host's snapshot, because the engine's level data spawns items
-- via a C-side path that bypasses our Create wraps.
-- Scan world by pointer against the supplied ptr_set. Delete any matching objs.
-- Tag-based ID failed: GetObjectsInCircle returns fresh wrappers, so fields don't persist.
local function clear_items_by_ptrs(ptr_set)
    local pl = player.GetPlayer()
    local px, py = 0, 0
    if pl then pcall(function() px, py = pl:GetPosition() end) end
    local objs = GetObjectsInCircle(px, py, 1000)
    if type(objs) ~= "table" then return 0, 0 end
    local matched, deleted, batch = 0, 0, 0
    for _, o in ipairs(objs) do
        if type(o) == "table" and o.pointer then
            local p = tostring(o.pointer)
            if ptr_set[p] then
                matched = matched + 1
                if type(o.Delete) == "function" then
                    pcall(function() o:Delete() end)
                    deleted = deleted + 1
                    batch = batch + 1
                    if batch >= 10 then Wait(0); batch = 0 end
                end
            end
        end
    end
    return matched, deleted
end

-- Diagnostic: count items in world via pointer match
local function count_items_in_world(ptr_set)
    local pl = player.GetPlayer()
    local px, py = 0, 0
    if pl then pcall(function() px, py = pl:GetPosition() end) end
    local objs = GetObjectsInCircle(px, py, 1000)
    if type(objs) ~= "table" then return 0 end
    local n = 0
    for _, o in ipairs(objs) do
        if type(o) == "table" and o.pointer and ptr_set[tostring(o.pointer)] then
            n = n + 1
        end
    end
    return n
end

-- Apply host's item_list by ADOPTING locally-generated items (deterministic
-- gen means same items at same positions on both sides). For each host
-- snapshot item, find a local item of matching type at matching position
-- and assign the host's id to it. Items that don't match anything still
-- get Created (rare for deterministic gen). Orphan local items (we have
-- but host doesn't) get Deleted.
--
-- This replaces the old wipe+respawn burst that was causing heap corruption
-- in the engine. We do at most a handful of Create/Delete calls instead of
-- 30+ of each.
local POS_TOL = 0.05  -- positions match within this many world units
local function apply_item_list(items)
    logf("apply_item_list (adopt): BEGIN pre_snapshot=%d host_items=%d",
        #joiner_pre_snapshot_items, #(items or {}))
    pcall(function() if SetVolume then SetVolume(0) end end)

    -- 1. Build "alive" pointer set from world scan (filter out ghost items
    --    the engine destroyed during overlap resolution).
    local pl = player.GetPlayer()
    local px, py = 0, 0
    if pl then pcall(function() px, py = pl:GetPosition() end) end
    local alive_ptrs = {}
    do
        local objs = GetObjectsInCircle(px, py, 1000)
        if type(objs) == "table" then
            for _, o in ipairs(objs) do
                if type(o) == "table" and o.pointer then
                    alive_ptrs[tostring(o.pointer)] = true
                end
            end
        end
    end

    -- 2. Bucket alive local items by type, keep position for matching.
    local local_by_type = {}  -- type → list of {obj, x, y, taken=false}
    local alive_local = 0
    for _, e in ipairs(joiner_pre_snapshot_items) do
        local ptr_ok, ptr = pcall(function() return tostring(e.obj.pointer or e.obj) end)
        if ptr_ok and alive_ptrs[ptr] then
            local_by_type[e.type] = local_by_type[e.type] or {}
            table.insert(local_by_type[e.type], { obj = e.obj, x = e.x, y = e.y, taken = false })
            alive_local = alive_local + 1
        end
    end
    logf("apply_item_list: %d alive local items bucketed", alive_local)

    mp.items = {}
    mp.item_obj_to_id = {}
    mp.item_snapshot_received = true

    -- 3. For each host item, find best matching local item by position and
    --    ADOPT it (claim with host's id). This is the only step that runs
    --    now: Create (for host-only items) and Delete (for joiner-only
    --    orphans) are SKIPPED — both touched the engine item table in ways
    --    that intermittently corrupted the heap a few seconds later
    --    (Task #2). Cost of skipping:
    --      * Host-only items (chest drops, etc.) are invisible to joiner.
    --      * Joiner-only items (level-gen divergence) clutter the joiner's
    --        view but the host doesn't know about them.
    --    Adoption alone is enough for joiner to pick up the items it CAN
    --    see in sync with host — that's the main goal here.
    local adopted = 0
    for _, it in ipairs(items or {}) do
        local bucket = local_by_type[it.type]
        local best_idx, best_d2 = nil, 1e9
        if bucket then
            for i, cand in ipairs(bucket) do
                if not cand.taken and cand.x and cand.y then
                    local dx, dy = cand.x - it.x, cand.y - it.y
                    local d2 = dx*dx + dy*dy
                    if d2 < best_d2 and d2 < (POS_TOL*POS_TOL) then
                        best_idx, best_d2 = i, d2
                    end
                end
            end
        end
        if best_idx then
            local cand = bucket[best_idx]
            cand.taken = true
            mp.items[it.id] = { obj = cand.obj, type = it.type, x = it.x, y = it.y }
            mp.item_obj_to_id[cand.obj] = it.id
            adopted = adopted + 1
        end
    end

    joiner_pre_snapshot_items = {}
    joiner_pre_snapshot_objs = {}

    pcall(function() if SetVolume then SetVolume(100) end end)
    logf("apply_item_list (adopt-only) DONE: adopted=%d of %d host items (Create/Delete skipped — Task #2)",
        adopted, #(items or {}))
end

-- Host: build & send item_list snapshot once after level populates.
-- The obj.Delete hook doesn't intercept engine-side C dispatch reliably, so we
-- filter mp.items against actual world presence here. Ghosts (items the engine
-- spawned then immediately destroyed during level-gen overlap resolution) get
-- dropped from both the wire AND local state.
local function host_send_item_list()
    if mp.item_snapshot_sent or not mp.is_host or not mp.sock then return end
    local pl = player.GetPlayer()
    local px, py = 0, 0
    if pl then pcall(function() px, py = pl:GetPosition() end) end
    local alive = {}
    local objs = GetObjectsInCircle(px, py, 1000)
    if type(objs) == "table" then
        for _, o in ipairs(objs) do
            if type(o) == "table" and o.pointer then alive[tostring(o.pointer)] = true end
        end
    end
    local list, ghosts, dead_ids = {}, 0, {}
    for id, entry in pairs(mp.items) do
        -- Liveness: compare C++ ptr address from the obj we stored.
        local ptr_str = nil
        if entry.obj then
            local ok, p = pcall(function() return tostring(entry.obj.pointer or entry.obj) end)
            if ok then ptr_str = p end
        end
        if ptr_str and alive[ptr_str] then
            table.insert(list, { id = id, type = entry.type, x = entry.x, y = entry.y })
        else
            ghosts = ghosts + 1
            table.insert(dead_ids, id)
        end
    end
    logf("host_send_item_list filter: ground=%d ghosts=%d", #list, ghosts)
    for _, it in ipairs(list) do
        logf("SNAPSHOT  id=%d type=%s pos=(%.2f,%.2f)", it.id, it.type, it.x, it.y)
    end
    for _, id in ipairs(dead_ids) do
        mp.items[id] = nil
        for p, pid in pairs(mp.item_obj_to_id) do
            if pid == id then mp.item_obj_to_id[p] = nil end
        end
    end
    send_msg({ type = "item_list", items = list })
    mp.item_snapshot_sent = true
    logf("host sent item_list: %d real items (dropped %d ghosts)", #list, ghosts)
end

-- Host: enumerate tracked containers + contents, send to relay so joiners
-- get an authoritative snapshot. Containers spawn during levelgen on both
-- sides (identical seed = identical layout), but contents could drift if
-- anything diverged — this lets joiners verify/adopt host state.
local function host_send_container_list()
    if mp.container_snapshot_sent or not mp.is_host or not mp.sock then return end
    local list = {}
    for id, c in pairs(mp.containers) do
        table.insert(list, {
            id = id, x = c.x, y = c.y, angle = c.angle,
            sprite = c.sprite, items = c.items,
        })
    end
    -- Sort by id for stable log/transport ordering.
    table.sort(list, function(a, b) return a.id < b.id end)
    local total_items = 0
    for _, c in ipairs(list) do total_items = total_items + #(c.items or {}) end
    logf("host_send_container_list: %d containers, %d items total", #list, total_items)
    for _, c in ipairs(list) do
        logf("  CONTAINER SNAPSHOT id=%d pos=(%.2f,%.2f) sprite=%s items=[%s]",
            c.id, c.x or 0, c.y or 0, tostring(c.sprite), table.concat(c.items or {}, ","))
    end
    send_msg({ type = "container_list", containers = list })
    mp.container_snapshot_sent = true
end

-- Pickup detection via pl:GiveItem hook. Engine calls pl:GiveItem(type) whenever
-- the local player gains an item (pickup or scripted grant). We match it to the
-- nearest tracked item of matching type within pickup radius, broadcast its id,
-- and drop it from our map. No polling, no method calls on world objects.
local PICKUP_NEAR_RADIUS_SQ = 9.0  -- 3u; player must be near the matched item
local giveitem_hook_installed = false

-- Engine never calls obj:Delete for pickups (C-side direct destruction) and
-- never fires def.onpickup/ongroundupdate for non-lua-type items. Pickup
-- detection runs via inventory diff (see below).

local PICKUP_MATCH_RADIUS_SQ = 25  -- 5u — generous; multi-pickup can be sloppy
local last_inv_counts = nil

local function snapshot_inventory()
    local pl = player.GetPlayer()
    if not pl or type(pl.GetInventory) ~= "function" then return nil end
    local inv
    if not pcall(function() inv = pl:GetInventory() end) then return nil end
    if type(inv) ~= "table" then return nil end
    local counts = {}
    -- Inventory shape unknown — handle array of {type=,count=}, array of strings,
    -- or map of type->count.
    for k, v in pairs(inv) do
        if type(v) == "table" then
            local tn = v.type or v.name or v[1]
            local cn = v.count or v.amount or v[2] or 1
            if tn then counts[tn] = (counts[tn] or 0) + cn end
        elseif type(v) == "string" then
            counts[v] = (counts[v] or 0) + 1
        elseif type(k) == "string" and type(v) == "number" then
            counts[k] = (counts[k] or 0) + v
        end
    end
    return counts
end

local function broadcast_pickup_of_type(type_name, px, py)
    local best_id, best_d2 = nil, math.huge
    for id, entry in pairs(mp.items) do
        if entry.type == type_name then
            local dx, dy = entry.x - px, entry.y - py
            local d2 = dx * dx + dy * dy
            if d2 < best_d2 then best_id, best_d2 = id, d2 end
        end
    end
    if not best_id or best_d2 > PICKUP_MATCH_RADIUS_SQ then
        logf("inv diff: gained %s but NO tracked match nearby (best_d=%.2f)",
            type_name, best_id and math.sqrt(best_d2) or -1)
        return
    end
    local entry = mp.items[best_id]
    mp.items[best_id] = nil
    for p, pid in pairs(mp.item_obj_to_id) do
        if pid == best_id then mp.item_obj_to_id[p] = nil end
    end
    if mp.sock then
        send_msg({ type = "item_picked", id = best_id, picker_id = mp.my_id })
    end
    logf("inv diff: picked id=%s type=%s d=%.2f BROADCAST",
        tostring(best_id), type_name, math.sqrt(best_d2))
end

-- When the player's inventory of `type_name` decreased, scan a small radius
-- around the player for any object of that type that's NOT already in our
-- tracking map — that's the dropped item. Add it, broadcast to peers.
-- Engine's drop key handler (TPlayer vt[31] @0x460b00) creates the world
-- item via a native call that bypasses our Lua Create / _CreateWeapon
-- wraps, so this scan is how we catch drops.
-- Keep a snapshot of all world-object pointers around the player so we can
-- detect newly-appeared objects (drops). All world items appear as
-- objtype="object" with no distinguishing GetName, so the only reliable
-- way is "this pointer wasn't here a tick ago". Refresh on diff_inventory
-- — same cadence as pickup detection.
local DROP_SCAN_RADIUS = 30.0
local last_world_ptrs = nil    -- set of pointer userdata → true
local last_world_objs = nil    -- map pointer userdata → obj (so we can read pos after)

local function refresh_world_snapshot(px, py)
    local objs = GetObjectsInCircle(px, py, DROP_SCAN_RADIUS)
    if type(objs) ~= "table" then return end
    local ptrs, ents = {}, {}
    for _, obj in ipairs(objs) do
        if type(obj) == "table" and obj.pointer then
            ptrs[obj.pointer] = true
            ents[obj.pointer] = obj
        end
    end
    last_world_ptrs = ptrs
    last_world_objs = ents
end

local DROP_FOOT_RADIUS = 1.5    -- drops land near player's feet
local function detect_drop_of_type(type_name, px, py, prior_ptrs)
    -- Snapshot diff was unreliable due to engine pointer recycling — a
    -- "new" drop often reuses a pointer that was visible in the prior
    -- snapshot (representing a different object). Use a positional
    -- heuristic instead: find the closest untracked-by-us object within
    -- 1.5u of the player. Drops land at player's feet; walls there would
    -- prevent the player from being there. The only false-positive risk
    -- is another player/mob standing exactly on us — usually fine.
    local objs = GetObjectsInCircle(px, py, DROP_FOOT_RADIUS)
    if type(objs) ~= "table" then return end
    -- Build "known" set: tracked items + mob puppets + player puppets.
    local known_ptrs = {}
    for _, e in pairs(mp.items or {}) do
        if e and e.obj and e.obj.pointer then known_ptrs[e.obj.pointer] = true end
    end
    for _, e in pairs(mp.mob_puppets or {}) do
        if e and e.obj and e.obj.pointer then known_ptrs[e.obj.pointer] = true end
    end
    for _, e in pairs(mp.puppets or {}) do
        if e and e.obj and e.obj.pointer then known_ptrs[e.obj.pointer] = true end
    end
    -- Local player itself
    local pl = player.GetPlayer()
    if pl and pl.pointer then known_ptrs[pl.pointer] = true end
    -- Pick closest unknown obj
    local best_obj, best_d2, best_x, best_y = nil, math.huge, 0, 0
    for _, obj in ipairs(objs) do
        if type(obj) == "table" and obj.pointer and not known_ptrs[obj.pointer] then
            local x, y = get_obj_pos(obj)
            if x and y then
                local dx, dy = x - px, y - py
                local d2 = dx*dx + dy*dy
                if d2 < best_d2 then
                    best_obj, best_d2 = obj, d2
                    best_x, best_y = x, y
                end
            end
        end
    end
    if not best_obj then
        logf("DROP %s: no untracked obj within %.1fu of (%.2f,%.2f)",
            type_name, DROP_FOOT_RADIUS, px, py); return
    end
    -- Read fuse to distinguish a passive drop from an activated bomb.
    -- ARMED bombs (fuse > 0) are handled by the NATIVE bomb-activation
    -- hook which broadcasts bomb_activated. To avoid duplicate
    -- broadcasts (and the heap corruption that pointer-reuse causes on
    -- the receiver), we ONLY broadcast item_spawned for inert items.
    local fuse = -1
    if _G.MP_NATIVE and _G.MP_NATIVE.read_fuse and best_obj.pointer then
        pcall(function() fuse = _G.MP_NATIVE.read_fuse(best_obj.pointer) end)
    end
    if fuse and fuse > 0 then
        logf("DROP DETECTED (armed bomb fuse=%d, skip — native hook handles)", fuse)
        return
    end
    -- Peer-namespaced IDs prevent collision with host's item_list IDs
    -- (which are 1..N) and other peers' drops. Host keeps using numeric
    -- IDs; joiners use "p<my_id>_<n>" strings. handle_item_spawned uses
    -- mp.items[id] lookup which tolerates either type.
    local n = mp.next_item_id
    mp.next_item_id = n + 1
    local id
    if mp.is_host then
        id = n
    else
        id = "p" .. tostring(mp.my_id or "?") .. "_" .. tostring(n)
    end
    mp.items[id] = { obj = best_obj, type = type_name, x = best_x, y = best_y }
    mp.item_obj_to_id[best_obj] = id
    logf("DROP DETECTED id=%s type=%s pos=(%.2f,%.2f) d=%.2f is_host=%s",
        tostring(id), type_name, best_x, best_y, math.sqrt(best_d2), tostring(mp.is_host))
    if mp.sock then
        send_msg({ type = "item_spawned",
                   item = { id = id, type = type_name, x = best_x, y = best_y } })
    end
end

local function diff_inventory()
    if not mp.sock then return end
    local now_counts = snapshot_inventory()
    if not now_counts then return end
    if not last_inv_counts then last_inv_counts = now_counts; return end
    -- Dead/spectating: local body is parked off-map (pickup scan finds
    -- nothing). No drop-back needed; just skip the diff entirely so we
    -- don't broadcast phantom inventory changes.
    if mp.is_dead then
        last_inv_counts = now_counts
        return
    end
    local pl = player.GetPlayer()
    local px, py = 0, 0
    if pl then pcall(function() px, py = pl:GetPosition() end) end
    -- IMPORTANT: snapshot BEFORE checking inventory delta. We compare the
    -- current world to this snapshot — anything new (and matching an INV
    -- DECREASE) is a drop.
    local pre_drop_ptrs = last_world_ptrs   -- save the prior snapshot
    refresh_world_snapshot(px, py)
    for type_name, cur_n in pairs(now_counts) do
        local prev_n = last_inv_counts[type_name] or 0
        local delta = cur_n - prev_n
        if delta > 0 then
            logf("INV CHANGE type=%s prev=%d cur=%d gained=%d", type_name, prev_n, cur_n, delta)
            for i = 1, delta do
                logf("INV ATTEMPT %d/%d for type=%s", i, delta, type_name)
                broadcast_pickup_of_type(type_name, px, py)
            end
        elseif delta < 0 then
            logf("INV DECREASE type=%s prev=%d cur=%d lost=%d", type_name, prev_n, cur_n, -delta)
            for i = 1, -delta do
                detect_drop_of_type(type_name, px, py, pre_drop_ptrs)
            end
        end
    end
    -- Catch removed-from-inventory keys (lost everything of that type)
    for type_name, prev_n in pairs(last_inv_counts) do
        if not now_counts[type_name] and prev_n > 0 then
            logf("INV DECREASE type=%s prev=%d cur=0 lost=%d", type_name, prev_n, prev_n)
            for i = 1, prev_n do
                detect_drop_of_type(type_name, px, py, pre_drop_ptrs)
            end
        end
    end
    last_inv_counts = now_counts
end

-- Ammo polling: pl:GetAmmo(N) where N is bullettype 0-10. Ground ammo items
-- (pyammo, ppammo, pexpammo, nailbox, etc.) put bullets into one of these slots
-- on pickup. We diff each slot per tick; when a slot grows, broadcast pickup of
-- the nearest matching-or-any ground "ammo" item.
local AMMO_SLOTS = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
local last_ammo_counts = nil

local function snapshot_ammo()
    local pl = player.GetPlayer()
    if not pl or type(pl.GetAmmo) ~= "function" then return nil end
    local out = {}
    for _, n in ipairs(AMMO_SLOTS) do
        local ok, v = pcall(function() return pl:GetAmmo(n) end)
        if ok and type(v) == "number" then out[n] = v end
    end
    return out
end

-- Item-type names that count as "ammo on the ground". When an ammo slot grows,
-- we search for the nearest tracked item of any of these types.
local AMMO_ITEM_TYPES = {
    pyammo = true, ppammo = true, pexpammo = true, auammo = true,
    nailbox = true, ldammo = true, brammo = true, ammo = true,
}

local function broadcast_ammo_pickup(px, py)
    local best_id, best_d2 = nil, math.huge
    for id, entry in pairs(mp.items) do
        if AMMO_ITEM_TYPES[entry.type] then
            local dx, dy = entry.x - px, entry.y - py
            local d2 = dx * dx + dy * dy
            if d2 < best_d2 then best_id, best_d2 = id, d2 end
        end
    end
    if not best_id or best_d2 > PICKUP_MATCH_RADIUS_SQ then
        logf("ammo diff: gained ammo but NO ammo item match nearby (best_d=%.2f)",
            best_id and math.sqrt(best_d2) or -1)
        return
    end
    local entry = mp.items[best_id]
    mp.items[best_id] = nil
    for p, pid in pairs(mp.item_obj_to_id) do
        if pid == best_id then mp.item_obj_to_id[p] = nil end
    end
    if mp.sock then
        send_msg({ type = "item_picked", id = best_id, picker_id = mp.my_id })
    end
    logf("ammo diff: picked id=%s type=%s d=%.2f BROADCAST",
        tostring(best_id), entry.type, math.sqrt(best_d2))
end

local function diff_ammo()
    if not mp.sock then return end
    local now_ammo = snapshot_ammo()
    if not now_ammo then return end
    if not last_ammo_counts then last_ammo_counts = now_ammo; return end
    local total_gained = 0
    for slot, cur in pairs(now_ammo) do
        local prev = last_ammo_counts[slot] or 0
        if cur > prev then total_gained = total_gained + 1 end  -- 1 broadcast per slot that grew
    end
    if total_gained > 0 then
        local pl = player.GetPlayer()
        local px, py = 0, 0
        if pl then pcall(function() px, py = pl:GetPosition() end) end
        for _ = 1, total_gained do
            broadcast_ammo_pickup(px, py)
        end
    end
    last_ammo_counts = now_ammo
end

local function install_giveitem_hook()
    if giveitem_hook_installed then return end
    last_inv_counts = snapshot_inventory()
    last_ammo_counts = snapshot_ammo()
    giveitem_hook_installed = true
    local parts = {}
    if last_inv_counts then
        for k, v in pairs(last_inv_counts) do table.insert(parts, k .. "=" .. tostring(v)) end
    end
    logf("inv diff: baselined inventory contents=[%s]", table.concat(parts, ", "))
    local pl = player.GetPlayer()
    if pl and type(pl.GetAmmo) == "function" then
        local ammos = {}
        -- Engine only has 11 ammo slots (0-10). Going past that = out-of-bounds
        -- read on the engine's ammo array — caught by PageHeap as instant
        -- access violation. Was the source of recurring heap-corruption crashes.
        for n = 0, 10 do
            local ok, v = pcall(function() return pl:GetAmmo(n) end)
            if ok then table.insert(ammos, n .. "=" .. tostring(v)) end
        end
        logf("AMMO BASELINE: %s", table.concat(ammos, ", "))
    end
end

-- Inventory sync: each player polls own inventory at 4 Hz, broadcasts on
-- change. Peers store in mp.peer_inventories and log on receive.
local function counts_equal(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

local function sync_own_inventory()
    if not mp.sock or not mp.my_id then return end
    local cur = snapshot_inventory()
    if not cur then return end
    if counts_equal(cur, mp.last_inv_sent_counts) then return end
    mp.last_inv_sent_counts = cur
    send_msg({ type = "inventory", counts = cur, sender_id = mp.my_id })
    local parts = {}
    for k, v in pairs(cur) do table.insert(parts, k .. "x" .. v) end
    logf("INVENTORY SENT: [%s]", table.concat(parts, ", "))
end

local function handle_inventory(msg)
    if msg.sender_id == mp.my_id then return end
    mp.peer_inventories[msg.sender_id] = msg.counts
    local parts = {}
    if msg.counts then
        for k, v in pairs(msg.counts) do table.insert(parts, k .. "x" .. v) end
    end
    logf("INVENTORY RX from id=%s: [%s]", tostring(msg.sender_id), table.concat(parts, ", "))
end

-- ============ CREATE WRAPS (track items at spawn) ============
-- Joiner uses STUB_MOB to silently no-op post-cleanup enemy spawns (e.g. spawn waves).
local stub_methods = {
    SetPatrolPoints = function() end, SetName = function() end,
    SetPosition = function() end, SetAngle = function() end,
    SetColor = function() end, Delete = function() end, Alert = function() end,
    GetPosition = function() return 0, 0 end, GetAngle = function() return 0 end,
    GetName = function() return "" end,
}
local STUB_MOB = setmetatable({ pointer = "stub", objtype = "stub" }, { __index = stub_methods })

do
    local orig_create = Create
    Create = function(data)
        local trace = mp.spawn_test_scene  -- only log loudly during explicit test spawns
        if data and type(data) == "table" and data.type then
            local t = data.type
            local is_enemy = enemylist[t] and string.sub(t, 1, 3) ~= "mp_"
            if is_enemy and (not mp.is_host) and mp.cleanup_done then
                return STUB_MOB
            end
            if mp.test_mode and (not mp.spawn_test_scene) and (not mp.item_snapshot_received) then
                if is_enemy or (itemtable and itemtable[t]) then
                    return STUB_MOB
                end
            end
            -- HOST MP: do NOT block joiner item spawns here. Both sides must
            -- run identical Create calls or math.random state diverges and
            -- module shuffles produce different rooms. Joiner tracks its local
            -- spawns; apply_item_list wipes them when host's snapshot arrives.
            if trace then logf("CW>before orig_create type=%s pos=(%.2f,%.2f)", t, data.x or -999, data.y or -999) end
        end
        local obj = orig_create(data)
        if trace then logf("CW>after orig_create type=%s obj_type=%s", data and data.type or "?", type(obj)) end
        if obj and data and type(data) == "table" and data.type then
            local t = data.type
            if mp.is_host and enemylist[t] and string.sub(t, 1, 3) ~= "mp_" then
                if trace then logf("CW>tracking mob") end
                local ptr_str = tostring(obj.pointer)
                mp.host_mobs[ptr_str] = { id = mp.next_mob_id, type = t, obj = obj }
                mp.next_mob_id = mp.next_mob_id + 1
            end
            -- Container tracking: containers are spawned by levelgen on both
            -- host AND joiner (same seed -> same shuffles -> identical sets),
            -- but the host is authoritative on which items they hold (SpawnItems
            -- calls AddItem in shuffle order). Both sides track; on level load
            -- the host broadcasts container_list so joiners can verify/adopt
            -- contents. We wrap the returned cont:AddItem to capture each
            -- item added — the engine fills them via cont:AddItem(type) during
            -- levelgen.
            if t == "container" and obj then
                local id = mp.next_container_id
                mp.next_container_id = id + 1
                local ptr_str = tostring(obj.pointer)
                local entry = {
                    id = id, x = data.x, y = data.y, angle = data.angle or 0,
                    sprite = data.sprite, items = {}, obj = obj,
                }
                mp.containers[id] = entry
                mp.container_obj_to_id[ptr_str] = id
                logf("CONTAINER tracked id=%d ptr=%s pos=(%.2f,%.2f) sprite=%s",
                    id, ptr_str, entry.x or 0, entry.y or 0, tostring(entry.sprite))
                if type(obj.AddItem) == "function" and not rawget(obj, "_mp_add_wrapped") then
                    local orig_add = obj.AddItem
                    obj.AddItem = function(self, item_type, ...)
                        local r = orig_add(self, item_type, ...)
                        local eid = mp.container_obj_to_id[tostring(self.pointer)]
                        if eid and mp.containers[eid] then
                            table.insert(mp.containers[eid].items, item_type)
                            logf("CONTAINER addItem id=%d type=%s (n=%d)",
                                eid, tostring(item_type), #mp.containers[eid].items)
                        end
                        return r
                    end
                    pcall(function() rawset(obj, "_mp_add_wrapped", true) end)
                end
            end
            -- Items are tracked in the _Create* low-level wraps only, NOT here.
            -- The engine wraps the same C++ entity in TWO different Lua tables —
            -- one returned by the low-level call, one returned by Create{} —
            -- so tracking both paths produces duplicate IDs for the same item.
        end
        if trace then logf("CW>returning obj") end
        return obj
    end
end

-- Wrap the lower-level item Create functions. CreateItem in relvad.lua calls these
-- directly, bypassing the Create{} wrap above.
do
    local fns = { "_CreateWeapon", "_CreateAmmo", "_CreateSimpleItem",
                  "_CreateMedkit", "_CreateBomb", "_CreateLuaItem", "_CreateShield" }
    for _, fn_name in ipairs(fns) do
        local orig = _G[fn_name]
        if type(orig) == "function" then
            _G[fn_name] = function(x, y, nimi)
                local trace = mp.spawn_test_scene
                if mp.test_mode and (not mp.spawn_test_scene) and (not mp.item_snapshot_received)
                   and itemtable and itemtable[nimi] then
                    return 0
                end
                -- HOST MP: don't block; need RNG parity for module shuffle.
                if trace then logf("LL>before %s type=%s pos=(%.2f,%.2f)", fn_name, tostring(nimi), x or -999, y or -999) end
                local obj = orig(x, y, nimi)
                if trace then logf("LL>after %s obj_type=%s", fn_name, type(obj)) end
                if obj and itemtable and itemtable[nimi] then
                    if mp.is_host then
                        if trace then logf("LL>about to track_item_host") end
                        track_item_host(obj, nimi, x, y)
                        if trace then logf("LL>track_item_host returned") end
                    elseif not mp.item_snapshot_received then
                        track_item_joiner_pre(obj, nimi)
                    elseif mp.sock and not in_giveitem then
                        -- Joiner post-snapshot: a new item appeared locally.
                        -- This is almost always a container loot pop on the
                        -- joiner's side (the engine ejects items when the
                        -- player USEs a container). Detect proximity to a
                        -- tracked container and broadcast container_item_taken
                        -- + an item_spawned with a peer-namespaced id so the
                        -- host sees the world item appear.
                        local CONTAINER_LOOT_R2 = 4.0
                        local wx, wy = x, y
                        pcall(function()
                            if obj.GetPosition then wx, wy = obj:GetPosition() end
                        end)
                        for cid, c in pairs(mp.containers or {}) do
                            if c.items and #c.items > 0 then
                                local dx, dy = (c.x or 0) - (wx or 0), (c.y or 0) - (wy or 0)
                                if dx*dx + dy*dy <= CONTAINER_LOOT_R2 then
                                    for i, it in ipairs(c.items) do
                                        if it == nimi then
                                            table.remove(c.items, i)
                                            logf("CONTAINER LOOT (joiner) id=%d ejected %s (n=%d remain)",
                                                cid, nimi, #c.items)
                                            -- Session-monotonic counter so each ejection gets a
                                            -- globally-unique id. Using container index (i)
                                            -- collided after table.remove shifts everything down.
                                            mp.peer_loot_seq = (mp.peer_loot_seq or 0) + 1
                                            local peer_iid = "p" .. tostring(mp.my_id or "?") .. "_c" .. tostring(cid) .. "_" .. tostring(mp.peer_loot_seq)
                                            -- Add to local mp.items so the joiner's own pickup
                                            -- detector (ammo diff / inventory diff) can find the
                                            -- item by id and broadcast item_picked when grabbed.
                                            mp.items[peer_iid] = { obj = obj, type = nimi, x = wx or 0, y = wy or 0 }
                                            mp.item_obj_to_id[obj] = peer_iid
                                            send_msg({ type = "item_spawned",
                                                       item = { id = peer_iid, type = nimi,
                                                                x = wx or 0, y = wy or 0 } })
                                            send_msg({ type = "container_item_taken",
                                                       container_id = cid, item_type = nimi })
                                            break
                                        end
                                    end
                                    break
                                end
                            end
                        end
                    end
                end
                return obj
            end
        end
    end
end

-- ============ MESSAGE HANDLERS ============
local handle_join  -- forward decl
local dev_menu     -- forward decl — actual init in dev menu section below

local PROXIMITY_RANGE = 6.0
local function refresh_objective_string()
    if not (level and level.IsLoaded and level.IsLoaded()) then return end
    if dev_menu and dev_menu.visible then return end  -- dev menu owns the line
    local pl = player.GetPlayer()
    local px, py
    if pl then px, py = pl:GetPosition() end
    local role = mp.is_host and "HOST" or "JOIN"

    local nearest, nearest_dist = nil, math.huge
    if px and py then
        for _, entry in pairs(mp.puppets) do
            if entry.last_x and entry.last_y then
                local dx, dy = entry.last_x - px, entry.last_y - py
                local d = math.sqrt(dx*dx + dy*dy)
                if d < nearest_dist then nearest, nearest_dist = entry, d end
            end
        end
    end

    local line
    if mp.is_dead then
        line = string.format("*** YOU ARE DEAD ***  spectating — revive at next level exit")
    elseif nearest and nearest_dist <= PROXIMITY_RANGE then
        line = string.format(">> %s <<  %s   HP:%d   dist:%.1f",
            role, nearest.name, nearest.hp or 0, nearest_dist)
    else
        local n = 0
        for _ in pairs(mp.puppets) do n = n + 1 end
        line = string.format(">> %s <<  you=%s   peers=%d", role, config.name, n)
    end
    pcall(function() level.SetObjectiveString(line) end)
end

-- ============ DEATH INTERCEPT helper (task #8) ============
-- Polls the LOCAL player's HP each call; when it dips to the threshold,
-- pins +0xBC > 0 (so the engine's native death branch and gameover HUD
-- vt[14] FUN_0045c220 can't trip) and flips mp.is_dead so the rest of
-- the client enters spectate mode.
--
-- Called from net_tick_loop at network rate (~10 Hz). Originally lived
-- inside MP_FRAME_TICK, but the engine's in-game Lua dispatch bypasses
-- our lua_resume/lua_pcallk hooks, so MP_FRAME_TICK never fires once
-- begin_game runs. net_tick_loop's coroutine IS resumed every tick
-- (Wait yields go through lua_resume), so the helper runs reliably.
local function tick_death_intercept()
    if not mp.in_game then return end
    if not (_G.MP_NATIVE and _G.MP_NATIVE.pin_hp) then return end
    -- Local player ptr was captured in begin_game; this is just a fallback.
    if not mp.local_player_obj then
        local pl0 = player.GetPlayer()
        if pl0 and pl0.pointer then
            mp.local_player_obj = pl0
            mp.local_player_ptr = pl0.pointer
        end
    end
    local pl = mp.local_player_obj
    if not (pl and pl.pointer) then return end
    local target_ptr = mp.local_player_ptr or pl.pointer
    -- Externally-triggered death (dev menu / host-confirmed): pin + announce.
    if mp.is_dead and not mp.death_announced_at then
        mp.death_announced_at = (socket and socket.gettime) and socket.gettime() or 0
        logf("DEATH externally triggered → pin + announce")
        pcall(function() _G.MP_NATIVE.pin_hp(target_ptr, true) end)
        pcall(function()
            if _G.MP_NATIVE.set_invulnerable then
                _G.MP_NATIVE.set_invulnerable(pl.pointer, true)
            end
        end)
        -- Spectate ergonomics: kinematic body (no collisions / physics
        -- jitter against the teammate we're glued to) and fire-gate set
        -- (engine's own gate that no-ops shoot/reload/drop).
        pcall(function()
            if _G.MP_NATIVE.set_body_kinematic then _G.MP_NATIVE.set_body_kinematic(target_ptr) end
            if _G.MP_NATIVE.set_fire_gate then _G.MP_NATIVE.set_fire_gate(target_ptr, 1) end
        end)
        pcall(refresh_objective_string)
        if mp.sock then pcall(function() send_msg({ type = "player_died" }) end) end
    end
    if mp.is_dead then
        -- Keep pinning so any incoming damage can't tip HP <= 0.
        pcall(function() _G.MP_NATIVE.pin_hp(target_ptr, true) end)
        -- One-time on death-entry: park local body far off-map so the
        -- engine's item pickup scan finds nothing near us.
        if not mp.local_parked_off_map then
            mp.local_parked_off_map = true
            if pl.SetPosition then
                pcall(function() pl:SetPosition(-99999, -99999) end)
            end
            if _G.MP_NATIVE.set_body_velocity then
                pcall(function() _G.MP_NATIVE.set_body_velocity(target_ptr, 0, 0) end)
            end
        end
        -- Pick the nearest LIVING teammate to spectate.
        local target, target_d2 = nil, math.huge
        for _, entry in pairs(mp.puppets or {}) do
            if type(entry) == "table" and not entry.is_dead and entry.obj
               and entry.obj.pointer and entry.last_x and entry.last_y then
                local dx = entry.last_x - (-99999)
                local dy = entry.last_y - (-99999)
                local d2 = dx*dx + dy*dy
                if d2 < target_d2 then target, target_d2 = entry, d2 end
            end
        end
        if target and target.obj and target.obj.pointer then
            -- Redirect camera + HUD to the spectated puppet. set_main_player
            -- writes DAT_005747a4 → engine camera follows that ptr.
            -- set_hud_allowed_puppet lets vt[14] render for this puppet
            -- (normally we skip puppet HUD to avoid the overlap bug).
            if mp.spectate_target_ptr ~= target.obj.pointer then
                mp.spectate_target_ptr = target.obj.pointer
                pcall(function()
                    if _G.MP_NATIVE.set_main_player then _G.MP_NATIVE.set_main_player(target.obj.pointer) end
                    if _G.MP_NATIVE.set_hud_allowed_puppet then _G.MP_NATIVE.set_hud_allowed_puppet(target.obj.pointer) end
                end)
                logf("SPECTATE target switched to puppet ptr=%s",
                    tostring(_G.MP_NATIVE.addr_of and _G.MP_NATIVE.addr_of(target.obj.pointer)))
            end
        end
        return
    end
    -- Alive: poll HP directly from cached pointer (avoids GetHealth() going
    -- through engine state puppets can pollute).
    local hp = nil
    if _G.MP_NATIVE.read_hp then
        pcall(function() hp = _G.MP_NATIVE.read_hp(target_ptr) end)
    else
        pcall(function() if pl.GetHealth then hp = pl:GetHealth() end end)
    end
    mp._last_logged_hp = mp._last_logged_hp or -1
    if hp ~= mp._last_logged_hp then
        logf("DEATH poll: hp=%s", tostring(hp))
        mp._last_logged_hp = hp
    end
    -- Threshold of 30: a single bullet (~26 dmg) can drop 100→0 in one
    -- tick, so we must catch BEFORE the lethal hit. Also accept hp<=0
    -- (engine may have started death but pin_hp + +0xCC sentinel still
    -- close the gameover gate). Negative hp is the "already shot past 0"
    -- case from a one-shot heavy weapon.
    if type(hp) == "number" and hp <= 30 then
        logf("DEATH intercept: hp=%s → pinning + entering spectate", tostring(hp))
        mp.is_dead = true
        mp.death_announced_at = (socket and socket.gettime) and socket.gettime() or 0
        pcall(function() _G.MP_NATIVE.pin_hp(target_ptr, true) end)
        pcall(function()
            if _G.MP_NATIVE.set_invulnerable then
                _G.MP_NATIVE.set_invulnerable(pl.pointer, true)
            end
        end)
        -- Spectate ergonomics: kinematic body (no jitter against teammate
        -- we follow) + fire-gate set (engine's own no-fire/no-reload gate)
        -- + render-gate set (think2 draw skip, local body invisible so the
        -- camera shows only the teammate puppet).
        pcall(function()
            if _G.MP_NATIVE.set_body_kinematic then _G.MP_NATIVE.set_body_kinematic(target_ptr) end
            if _G.MP_NATIVE.set_fire_gate then _G.MP_NATIVE.set_fire_gate(target_ptr, 1) end
            if _G.MP_NATIVE.set_render_gate then _G.MP_NATIVE.set_render_gate(target_ptr, 1) end
        end)
        pcall(refresh_objective_string)
        if mp.sock then pcall(function() send_msg({ type = "player_died" }) end) end
    end
end

-- Toggle: represent remote players as REAL TPlayer instances (proper weapon-
-- coupled animation) vs. the old stripped enemy puppet.
-- TPlayer WIP (2026-05-30): proven to ANIMATE, but a real player is deeply
-- coupled — it claims the camera and runs a per-frame think that reads our
-- input / can self-shoot. Skipping the think wholesale (passive hooks) breaks
-- rendering + crashes. Needs SURGICAL neutering of just the input+camera reads
-- inside the think. Gated OFF until then; puppets are the stable path.
_G.MP_USE_TPLAYER = true   -- Path A v3 (2026-06-01): no GiveItem, no
                            -- set_action. Pure CreatePlayer + invuln/pin.
                            -- If this is stable, the puppet stands frozen
                            -- in idle pose at network-driven position — but
                            -- it gives us a baseline to iterate from.

handle_join = function(p)
    if mp.puppets[p.id] then return end
    local pl = player.GetPlayer()
    local px, py = 0, 0
    if pl then px, py = pl:GetPosition() end
    local sx, sy = p.x or (px + 3), p.y or (py + 3)
    local obj, is_tplayer = nil, false
    -- Proper remote player: a real TPlayer. CreatePlayer overwrites the global
    -- main-player pointer (camera/input/HUD), so save the LOCAL player's ptr
    -- and restore it immediately — keeping the camera on us.
    if _G.MP_USE_TPLAYER and CreatePlayer and _G.MP_NATIVE and _G.MP_NATIVE.set_main_player and pl and pl.pointer then
        local saved = pl.pointer
        local main_before, local_addr
        pcall(function() main_before = _G.MP_NATIVE.get_main_player() end)
        pcall(function() local_addr = _G.MP_NATIVE.addr_of(pl.pointer) end)
        -- Path A v4 (2026-06-01): spawn the puppet FAR off-map. v3 (host-stable,
        -- joiner-crash) suggested the issue is TPlayer-vs-TPlayer collision
        -- between the puppet and the joiner's own local player at level start
        -- (joiner spawns near origin; the host's reported pos is also near
        -- origin). Spawning at (-9999, -9999) avoids any collision dispatch
        -- before SetPosition (via handle_snapshot) brings the puppet to its
        -- real position on the next network tick.
        local SAFE_SPAWN = -9999
        pcall(function() obj = CreatePlayer(SAFE_SPAWN, SAFE_SPAWN) end)
        local main_after_create
        pcall(function() main_after_create = _G.MP_NATIVE.get_main_player() end)
        pcall(function() _G.MP_NATIVE.set_main_player(saved) end)
        local main_after_restore, remote_addr
        pcall(function() main_after_restore = _G.MP_NATIVE.get_main_player() end)
        if obj then pcall(function() remote_addr = _G.MP_NATIVE.addr_of(obj.pointer) end) end
        logf("TPLAYER join id=%s: local=%s main_before=%s main_after_create=%s remote=%s main_after_restore=%s",
            tostring(p.id), tostring(local_addr), tostring(main_before),
            tostring(main_after_create), tostring(remote_addr), tostring(main_after_restore))
        if obj then
            is_tplayer = true
            pcall(function() obj:SetAngle(p.angle or 0) end)
            -- Keep the remote alive & damage-inert: a mob (or stray hit) dropping
            -- its HP<=0 would run the death branch + gameover HUD over OUR screen.
            -- The wrapped think neuters its own input; HP-pin + invuln cover
            -- external damage. (Natives are absent/no-op on the puppet path.)
            pcall(function()
                -- Register FIRST so hook_PThink1's strict allow-list
                -- recognizes this puppet on its very first think frame.
                -- Before the registry, "self != main_p" was the gate, which
                -- mis-fired during CreatePlayer's brief main_p swap and
                -- pinned the local player's HP to 9999.
                if _G.MP_NATIVE.register_puppet then _G.MP_NATIVE.register_puppet(obj.pointer) end
                if _G.MP_NATIVE.set_invulnerable then _G.MP_NATIVE.set_invulnerable(obj.pointer, true) end
                if _G.MP_NATIVE.pin_hp then _G.MP_NATIVE.pin_hp(obj.pointer) end
                if _G.MP_NATIVE.set_body_kinematic then
                    _G.MP_NATIVE.set_body_kinematic(obj.pointer)
                end
            end)
            -- Path A v3 (2026-06-01): NO GiveItem on the puppet. v2 equipped
            -- pystol up-front; both clients froze+crashed after preamble. The
            -- GiveItem also tripped our own GIVEITEM wrap (logged as
            -- "TRACK SKIP-GIVE join type=pystol") so something in the inventory
            -- path got confused. Try the puppet WITHOUT touching inventory:
            -- just CreatePlayer + invuln/pin. No GiveItem, no set_action
            -- (filtered to nothing below). If this is stable the puppet stays
            -- idle but at least we have a baseline to iterate from.
        end
    end
    if not obj then
        pcall(function() obj = Create{ type = "mp_remote_player", x = sx, y = sy, angle = p.angle or 0 } end)
    end
    local display_name = (p.name or "?") .. "#" .. tostring(p.id)
    if obj then pcall(function() obj:SetName("mp_player_" .. tostring(p.id)) end) end
    local init_text = display_name .. " HP:" .. tostring(p.hp or 100)
    local nameplate
    pcall(function() nameplate = CreateTextObj(sx, sy - 1.2, init_text) end)
    mp.puppets[p.id] = {
        obj = obj, is_tplayer = is_tplayer, name = display_name, hp = p.hp or 100,
        last_x = sx, last_y = sy,
        created_at = socket.gettime(),
        nameplate = nameplate, nameplate_text = init_text,
    }
    logf("join id=%s name=%s pos=(%.2f, %.2f) tplayer=%s", tostring(p.id), display_name, sx, sy, tostring(is_tplayer))
    refresh_objective_string()
end

-- Defined in the menu integration block. game_started / late-join welcome
-- handlers call into it; forward-declared so they can reach it.
local begin_game
local apply_waiting_labels   -- set by the menu integration; updates the
                             -- player-slot button labels on the waiting page
local apply_pause_labels     -- updates the in-game ESC menu player slots

-- Forward decl — defined after the item-list handler below; handle_welcome
-- needs to call it when the relay piggy-backs a container_list on welcome.
local handle_container_list  -- forward decl
local handle_container_item_taken  -- forward decl

local function handle_welcome(msg)
    mp.my_id = msg.id
    mp.room_id = msg.room_id
    mp.room_name = msg.room_name
    mp.host_id = msg.host_id
    mp.is_host = (msg.host_id == msg.id)
    mp.session_seed = msg.seed
    mp.pending_initial_players = msg.players or {}
    -- Live room roster (excludes self — UI prepends self when drawing).
    mp.room_players = {}
    for _, p in ipairs(msg.players or {}) do
        if p.id ~= mp.my_id then
            table.insert(mp.room_players, { id = p.id, name = p.name })
        end
    end
    if not mp.is_host and type(msg.item_list) == "table" and #msg.item_list > 0 then
        mp.pending_item_list = msg.item_list
    end
    if not mp.is_host and type(msg.container_list) == "table" and #msg.container_list > 0 then
        logf("welcome: container_list pending n=%d", #msg.container_list)
        handle_container_list({ containers = msg.container_list })
    end
    logf("welcome async: my_id=%s room='%s' host_id=%s is_host=%s status=%s players=%d",
        tostring(mp.my_id), tostring(msg.room_name), tostring(msg.host_id),
        tostring(mp.is_host), tostring(msg.status), #(msg.players or {}))
    if apply_waiting_labels then pcall(apply_waiting_labels) end
    -- Late join (host already started before we joined) — drop straight in.
    if msg.status == "in_game" and begin_game then begin_game() end
end

-- Liveness cache: scan world ONCE per tick, reuse for all puppet checks.
-- Caches a set of alive pointer strings for ~0.5s. Calling entity_alive
-- 28x per tick was tanking FPS (each call scanned hundreds of objects).
local alive_ptr_cache = nil
local alive_ptr_cache_at = 0
local function refresh_alive_cache()
    local now = socket.gettime()
    if alive_ptr_cache and (now - alive_ptr_cache_at) < 0.5 then return end
    local pl = player.GetPlayer()
    local px, py = 0, 0
    if pl then pcall(function() px, py = pl:GetPosition() end) end
    local set = {}
    local objs = GetObjectsInCircle(px, py, 2000)  -- generous radius — mobs can be far from player
    if type(objs) == "table" then
        for _, o in ipairs(objs) do
            if type(o) == "table" and o.pointer then set[tostring(o.pointer)] = true end
        end
    end
    alive_ptr_cache = set
    alive_ptr_cache_at = now
end

local function entity_alive(obj)
    if not obj or type(obj) ~= "table" or not obj.pointer then return false end
    refresh_alive_cache()
    return alive_ptr_cache[tostring(obj.pointer)] == true
end

-- Liveness-gated Delete. The engine recycles freed C++ pointers and, when a
-- binding (Delete/SetPosition/GetHealth/…) is called on freed memory, aborts
-- INSIDE native code — pcall cannot catch it and the heap gets scribbled, which
-- surfaces seconds later as the RtlReAllocateHeap/luaL_gsub crash. So before
-- Deleting any handle the engine MAY have freed out-of-band (item picked up
-- locally, entity destroyed during a Wait yield, …), force a FRESH world scan
-- and only Delete if the exact pointer is still present. Returns true when the
-- object is gone (deleted now, or already gone — nothing to do).
local function safe_delete(obj)
    if not obj or type(obj) ~= "table" or not obj.pointer then return true end
    alive_ptr_cache_at = 0           -- never trust a stale set for a Delete
    if not entity_alive(obj) then return true end   -- already freed/recycled away
    pcall(function() if obj.Delete then obj:Delete() end end)
    return true
end

local function handle_leave(msg)
    local entry = mp.puppets[msg.id]
    if entry then
        if entry.obj and entry.obj.pointer and _G.MP_NATIVE
           and _G.MP_NATIVE.unregister_puppet then
            pcall(function() _G.MP_NATIVE.unregister_puppet(entry.obj.pointer) end)
        end
        safe_delete(entry.obj)
        -- Nameplate is a TextObj (not in the actor scan); we own its lifetime
        -- and Delete it exactly once here, so a plain guarded Delete is safe.
        if entry.nameplate then pcall(function() entry.nameplate:Delete() end) end
    end
    mp.puppets[msg.id] = nil
    logf("left id=%s", tostring(msg.id))
    refresh_objective_string()
end

local function handle_snapshot(msg)
    if not mp.my_id or not msg.players then return end
    for _, p in ipairs(msg.players) do
        if p.id ~= mp.my_id then
            local entry = mp.puppets[p.id]
            if not entry then handle_join(p); entry = mp.puppets[p.id] end
            if entry and entry.obj then
                -- Liveness check. For mp_remote puppets, use GetObjectsInCircle
                -- scan via entity_alive. For TPlayer puppets, that scan misses
                -- objects outside its radius — instead validate that the
                -- puppet pointer still holds the TPlayer vtable. If the
                -- engine freed/recycled the C++ object, the vtable pointer
                -- changes (or is garbage) → we skip the binding call to
                -- avoid AV inside lua52 (the long-standing heap corruptor).
                local stale = false
                if entry.is_tplayer then
                    if _G.MP_NATIVE and _G.MP_NATIVE.validate_vtable and entry.obj.pointer then
                        local ok = false
                        pcall(function() ok = _G.MP_NATIVE.validate_vtable(entry.obj.pointer, 0x156b14) end)
                        stale = not ok
                    end
                else
                    stale = not entity_alive(entry.obj)
                end
                if stale then
                    logf("PUPPET STALE id=%s last=(%.1f,%.1f) age=%.1fs tplayer=%s — recreating",
                        tostring(p.id), entry.last_x or 0, entry.last_y or 0,
                        socket.gettime() - (entry.created_at or 0),
                        tostring(entry.is_tplayer))
                    mp.puppets[p.id] = nil
                    handle_join(p)
                    entry = mp.puppets[p.id]
                end
                if entry and entry.obj then
                    -- Diagnostic counter so we can correlate the LAST snapshot
                    -- before a crash with the dllhost think log. Logs every
                    -- 30th update (~3 s at 10 Hz) to keep the log readable.
                    entry._dbg_n = (entry._dbg_n or 0) + 1
                    if entry.is_tplayer and (entry._dbg_n % 30 == 1) then
                        logf("[PUP-DBG] id=%s ptr=%s n=%d p.x=%.1f p.y=%.1f p.act=%s p.hp=%s",
                            tostring(p.id), tostring(entry.obj.pointer), entry._dbg_n,
                            p.x or 0, p.y or 0, tostring(p.act), tostring(p.hp))
                    end
                    -- If this peer is marked dead (server forwarded
                    -- player_died → handle_peer_died), pin their puppet
                    -- far off-map so the host's mob AI's nearest-target
                    -- scan never picks them. The dying peer is in
                    -- spectate and may keep sending state from on top of
                    -- a teammate; without this their puppet would cluster
                    -- mob aggro on the spectated player.
                    local DEAD_HIDE = -9999
                    if entry.is_dead then
                        pcall(function() entry.obj:SetPosition(DEAD_HIDE, DEAD_HIDE) end)
                        entry.last_x = p.x  -- still track reported pos for spectate-target picks
                        entry.last_y = p.y
                        if p.hp then entry.hp = p.hp end
                        goto continue_puppet
                    end
                    -- VELOCITY-BASED CATCH-UP (no per-snapshot snap):
                    -- Instead of SetPosition snapping each snapshot (which
                    -- causes the rubberband visible-jitter), compute a
                    -- velocity that will move the kinematic body from its
                    -- CURRENT position to the authoritative target over the
                    -- next snapshot interval (~100ms). The body integrates
                    -- smoothly toward the target. On next snapshot, we
                    -- update velocity to the new target. No snaps → no
                    -- rubberband. Drift self-corrects each tick because
                    -- velocity points toward authoritative.
                    if entry.is_tplayer and _G.MP_NATIVE and _G.MP_NATIVE.set_body_velocity then
                        local catchup = 0.1   -- target arrival time (sec)
                        local cur_x, cur_y = p.x, p.y
                        pcall(function() cur_x, cur_y = entry.obj:GetPosition() end)
                        local vx = (p.x - cur_x) / catchup
                        local vy = (p.y - cur_y) / catchup
                        -- Safety: if puppet has drifted FAR (>5 units, e.g.
                        -- engine teleported it, level reset, lag spike),
                        -- snap rather than chase at insane velocity.
                        local dx, dy = p.x - cur_x, p.y - cur_y
                        if (dx*dx + dy*dy) > 25 then
                            pcall(function() entry.obj:SetPosition(p.x, p.y) end)
                            vx, vy = 0, 0
                        end
                        pcall(function() _G.MP_NATIVE.set_body_velocity(entry.obj.pointer, vx, vy) end)
                    else
                        -- Non-TPlayer puppets keep the immediate snap.
                        pcall(function() entry.obj:SetPosition(p.x, p.y) end)
                    end
                    if p.angle then
                        pcall(function() entry.obj:SetAngle(p.angle) end)
                        -- Pin angle natively so the engine's case-1 walk
                        -- handler doesn't reset +0xB0 to a velocity-derived
                        -- value (which is 0 because dummy input). Without
                        -- this, the puppet snaps to last-set angle every
                        -- ~33 ms but otherwise faces angle 0.
                        if entry.is_tplayer and _G.MP_NATIVE and _G.MP_NATIVE.pin_angle then
                            -- Pass position too — the puppet's +0x1B8/+0x1BC
                            -- cache can be stale if aliveUpdate hasn't run,
                            -- and the dummy-device aim target needs an
                            -- accurate origin to produce the right angle.
                            pcall(function() _G.MP_NATIVE.pin_angle(entry.obj.pointer, p.angle, p.x, p.y, p.act or -1) end)
                        end
                    end
                    -- Mirror the exact body sprite frame too — action sync
                    -- alone leaves attack frames (stab 27..29, shoot 6,
                    -- aim 5) partially driven because the engine ramps
                    -- through them in response to mouse-input events the
                    -- puppet never receives. Writing the raw frame value
                    -- forces the matching pose.
                    if entry.is_tplayer and p.f and entry.obj.pointer
                       and _G.MP_NATIVE and _G.MP_NATIVE.set_frame
                       and entity_alive(entry.obj) then
                        -- Only mirror "meaningful" frames — weapon hold (5),
                        -- shoot (6), and stab swing (27..29.5). Below 5 is
                        -- idle (0) / walk cycle (1..4) where the puppet's own
                        -- engine think drives the anim smoothly. Mirroring
                        -- those at 30 Hz against local 60 Hz interpolation
                        -- gives sub-frame jitter visible at idle.
                        if p.f >= 5 then
                            pcall(function() _G.MP_NATIVE.set_frame(entry.obj.pointer, p.f) end)
                        end
                    end
                    -- Drive the puppet's ANIMATION by mirroring the remote
                    -- player's action id onto its +0xB4 field (the engine's own
                    -- SetAction target). This is UPSTREAM of the anim state, so
                    -- the engine rebuilds a consistent animation each frame —
                    -- safe, unlike poking the downstream frame. Makes the puppet
                    -- play the real walk/shoot/aim animation. Guard: live + a
                    -- moment to initialize.
                    -- Keep the remote alive & damage-inert each tick (idempotent,
                    -- cheap). Prevents a mob hit from popping its death HUD on our
                    -- screen. Runs BEFORE we drive the obj below.
                    if entry.is_tplayer and entry.obj.pointer and _G.MP_NATIVE
                       and entity_alive(entry.obj) then
                        pcall(function()
                            if _G.MP_NATIVE.pin_hp then _G.MP_NATIVE.pin_hp(entry.obj.pointer) end
                            if _G.MP_NATIVE.set_invulnerable then _G.MP_NATIVE.set_invulnerable(entry.obj.pointer, true) end
                        end)
                    end
                    -- Drive the remote player's ANIMATION via the engine's own
                    -- +0xB4 SetAction field. Filtered to "safe" actions:
                    --   0=idle 1=walk 2=fall 3=rise 4=pain 6=hit 13=sprint
                    -- DROPPED on TPlayer puppets:
                    --   5=lay  (touches inventory)
                    --   7=shoot 8=aim  (fire weapon-effect callback at attack
                    --   frames → null-deref if the puppet has no weapon or the
                    --   weapon ptr isn't set up the way render expects)
                    --   9..12=vehib1/vehib2/hide/dig (vehicle / interactive
                    --   subsystems we don't track)
                    -- This costs visible aim/shoot anim on puppets but stops the
                    -- "crash ~Ns into play" we saw on the first MP_USE_TPLAYER=true
                    -- flight (2026-06-01). Restore shoot/aim once the puppet has
                    -- a real weapon and we trust the render path.
                    -- Mirror remote's action including idle/walk. Skipping
                    -- 0/1 left puppets stuck in stale anim after the local
                    -- transitioned. Engine on the puppet doesn't derive
                    -- action from position because dummy input drives no
                    -- velocity → it must be told explicitly.
                    if entry.is_tplayer and p.act and entry.obj.pointer
                       and _G.MP_NATIVE and _G.MP_NATIVE.set_action
                       and entity_alive(entry.obj) then
                        pcall(function() _G.MP_NATIVE.set_action(entry.obj.pointer, p.act) end)
                    end
                    entry.last_x = p.x
                    entry.last_y = p.y
                    if p.hp then entry.hp = p.hp end
                    ::continue_puppet::
                end
            end
        end
    end
end

local NAMEPLATE_PLAYER_RANGE = 3.0
local NAMEPLATE_CURSOR_RANGE = 1.25
local NAMEPLATE_HIDE_POS     = -9999
local function update_nameplates()
    local pl = player.GetPlayer()
    if not pl then return end
    -- While spectating, hide ALL puppet nameplates. Our local body is
    -- teleported on top of the spectated puppet, so its nameplate floats
    -- right where the camera sits — looks like our own name tag.
    if mp.is_dead then
        for _, entry in pairs(mp.puppets) do
            if entry.nameplate then
                pcall(function() entry.nameplate:SetPosition(NAMEPLATE_HIDE_POS, NAMEPLATE_HIDE_POS) end)
            end
        end
        return
    end
    local ppx, ppy = pl:GetPosition()
    local mwx, mwy
    pcall(function()
        local mx, my = GetMousePosition()
        if mx and my then mwx, mwy = GetWorldPoint(mx, my) end
    end)
    for _, entry in pairs(mp.puppets) do
        if entry.is_dead and entry.nameplate then
            -- Hide nameplate of dead peers — they're spectating on top of a
            -- teammate, and their name would float over the teammate's head.
            pcall(function() entry.nameplate:SetPosition(NAMEPLATE_HIDE_POS, NAMEPLATE_HIDE_POS) end)
        elseif entry.last_x and entry.nameplate then
            local dx, dy = entry.last_x - ppx, entry.last_y - ppy
            local visible = (dx*dx + dy*dy) <= (NAMEPLATE_PLAYER_RANGE * NAMEPLATE_PLAYER_RANGE)
            if not visible and mwx then
                local cx, cy = entry.last_x - mwx, entry.last_y - mwy
                visible = (cx*cx + cy*cy) <= (NAMEPLATE_CURSOR_RANGE * NAMEPLATE_CURSOR_RANGE)
            end
            if visible then
                local tx, ty = entry.last_x, entry.last_y - 1.2
                pcall(function() entry.nameplate:SetPosition(tx, ty) end)
                local new_text = entry.name .. " HP:" .. tostring(entry.hp or 0)
                if new_text ~= entry.nameplate_text then
                    pcall(function() entry.nameplate:Delete() end)
                    local newobj
                    pcall(function() newobj = CreateTextObj(tx, ty, new_text) end)
                    entry.nameplate = newobj
                    entry.nameplate_text = new_text
                end
            else
                pcall(function() entry.nameplate:SetPosition(NAMEPLATE_HIDE_POS, NAMEPLATE_HIDE_POS) end)
            end
        end
    end
end

local function handle_host_changed(msg)
    mp.host_id = msg.host_id
    mp.is_host = (msg.host_id == mp.my_id)
    logf("host_changed: new host_id=%s (is_host=%s)", tostring(mp.host_id), tostring(mp.is_host))
    refresh_objective_string()
end

-- ID-based pickup receiver: find item by host-assigned id, delete locally.
-- If we have an obj ref, Delete it directly. Otherwise scan a tiny radius at the
-- cached position for any item-like entity and delete that.
local function handle_item_picked(msg)
    if msg.picker_id == mp.my_id then return end
    if not msg.id then return end
    local entry = mp.items[msg.id]
    if not entry then
        logf("item_picked: NO entry id=%s from peer %s", tostring(msg.id), tostring(msg.picker_id))
        return
    end
    local deleted = false
    if entry.obj then
        -- We hold a handle: liveness-gated Delete. The item may already have
        -- been destroyed C-side by a local pickup — Deleting that freed handle
        -- is the prime heap corruptor, so safe_delete confirms it's still live.
        safe_delete(entry.obj)
        deleted = true
    else
        -- No local handle: find the item by position. Freshly-scanned objects
        -- are live, so Deleting one is heap-safe.
        local objs = GetObjectsInCircle(entry.x, entry.y, 0.4)
        if type(objs) == "table" then
            for _, o in ipairs(objs) do
                if type(o) == "table" and o.Delete and not o.Alert then
                    pcall(function() o:Delete() end)
                    deleted = true
                    break
                end
            end
        end
    end
    mp.items[msg.id] = nil
    for ptr, pid in pairs(mp.item_obj_to_id) do
        if pid == msg.id then mp.item_obj_to_id[ptr] = nil end
    end
    logf("item_picked: id=%s type=%s deleted=%s from peer %s",
        tostring(msg.id), tostring(entry.type), tostring(deleted), tostring(msg.picker_id))
end

-- Peer-side bomb activation replication. Host's TTimeBomb::Activate hook
-- captures (type, pos, angle, fuse). Peer creates a bomb at the same pos,
-- then natively arms its fuse + sets the same thrown velocity so both
-- engines tick down together and explode at the same world location.
local function handle_bomb_activated(msg)
    if not (msg and msg.btype) then return end
    -- Set in_giveitem so track_item_host/joiner_pre skip this CreateItem
    -- — otherwise on HOST the wrap broadcasts item_spawned, joiner gets it,
    -- joiner CreateItems ANOTHER bomb. End result: 2 bombs per activation
    -- (the real one from local engine + the echo from host's re-broadcast).
    -- Use CreateItem (the right dispatch for itype=explosive → _CreateBomb).
    local prev_in_give = in_giveitem
    in_giveitem = true
    local obj
    pcall(function() obj = CreateItem(msg.x or 0, msg.y or 0, msg.btype) end)
    in_giveitem = prev_in_give
    if not (obj and obj.pointer) then
        logf("bomb_activated: CreateItem failed type=%s", tostring(msg.btype))
        return
    end
    -- Throw velocity: cos(angle)*throwspeed, sin(angle)*throwspeed. Use the
    -- local itemtable's throwspeed so both peers compute the same value.
    local def = itemtable and itemtable[msg.btype]
    local ts = (def and def.throwspeed) or 10
    local vx = math.cos(msg.angle or 0) * ts
    local vy = math.sin(msg.angle or 0) * ts
    local fuse = msg.fuse or (def and def.delay) or 25
    -- activate_bomb (calling engine orig) crashed at NULL+12 because the
    -- engine activate expects an inventory back-ptr (+0x98) that a
    -- CreateItem'd bomb doesn't have. Stick with arm_bomb (manual fuse
    -- poke). Bombs may not tick properly without more state — TBD.
    if _G.MP_NATIVE and _G.MP_NATIVE.arm_bomb then
        pcall(function() _G.MP_NATIVE.arm_bomb(obj.pointer, fuse, vx, vy) end)
    end
    logf("bomb_activated RX: type=%s pos=(%.2f,%.2f) fuse=%d v=(%.2f,%.2f)",
        msg.btype, msg.x, msg.y, fuse, vx, vy)
end

local function handle_item_spawned(msg)
    -- Both host AND joiner replicate. Originally host-skipped because
    -- the CreateItem wrap fires track_item_host on host, which re-
    -- broadcasts and infinite-loops. The in_giveitem flag below blocks
    -- that re-broadcast (same pattern as handle_bomb_activated). Without
    -- this fix, joiner drops never appear on host's screen.
    local it = msg.item
    if not (it and it.id and it.type) then return end
    if mp.items[it.id] then return end  -- already have it (id space is
    -- now disjoint between host & joiner via peer-namespacing, so a
    -- collision here means a legitimate duplicate)
    mp.item_snapshot_received = true  -- bypass spawn-block wraps
    local obj
    local prev_in_give = in_giveitem
    in_giveitem = true
    pcall(function() obj = CreateItem(it.x, it.y, it.type) end)
    in_giveitem = prev_in_give
    local store_obj = (type(obj) == "table") and obj or nil
    mp.items[it.id] = { obj = store_obj, type = it.type, x = it.x, y = it.y }
    if store_obj then mp.item_obj_to_id[store_obj] = it.id end
    logf("handle_item_spawned: id=%s type=%s pos=(%.1f,%.1f) ok=%s is_host=%s",
        tostring(it.id), it.type, it.x, it.y, tostring(store_obj ~= nil), tostring(mp.is_host))
end

-- Run apply_item_list in its own coroutine so the net loop keeps receiving
-- state snapshots while spawns are being processed (otherwise the net coro
-- blocks on Wait() inside the spawn loop and puppet positions don't update).
local function start_apply_coro(items)
    local co = coroutine.create(function()
        local ok, err = pcall(apply_item_list, items)
        if not ok then logf("apply_item_list coro CRASH: %s", tostring(err)) end
    end)
    coroutine.resume(co)
end

-- Joiner: handle host's container snapshot. Log every container received
-- and verify against locally-tracked containers (created by identical
-- levelgen). For MVP we just log diffs — no rewrite of local state yet.
handle_container_list = function(msg)
    local n = (type(msg.containers) == "table") and #msg.containers or 0
    logf("handle_container_list: is_host=%s msg.containers_n=%d", tostring(mp.is_host), n)
    if mp.is_host then return end
    if n == 0 then logf("handle_container_list: empty"); return end
    -- AUTHORITATIVE OVERRIDE: levelgen on host and joiner produces different
    -- container layouts/contents despite identical RNG (engine internals
    -- consume math.random asymmetrically). The fix that matches what
    -- apply_item_list does for items: wipe everything we have locally and
    -- recreate from the host's snapshot. The Create + AddItem wraps will
    -- re-populate mp.containers as we go.
    local wiped = 0
    for _, lc in pairs(mp.containers or {}) do
        if lc.obj and type(lc.obj.Delete) == "function" then
            local ok = pcall(function() lc.obj:Delete() end)
            if ok then wiped = wiped + 1 end
        end
    end
    mp.containers = {}
    mp.container_obj_to_id = {}
    mp.next_container_id = 1
    logf("handle_container_list: wiped %d local containers", wiped)
    -- Recreate each. Order is host's broadcast order (sorted by host id).
    local recreated, items_added = 0, 0
    for _, c in ipairs(msg.containers) do
        local cont
        local ok = pcall(function()
            cont = Create({ type = "container", x = c.x, y = c.y,
                            angle = c.angle or 0, sprite = c.sprite })
        end)
        if not ok or not cont then
            logf("  CONTAINER recreate FAIL host_id=%d pos=(%.2f,%.2f) sprite=%s",
                c.id, c.x or 0, c.y or 0, tostring(c.sprite))
        else
            recreated = recreated + 1
            for _, it in ipairs(c.items or {}) do
                local addok = pcall(function() cont:AddItem(it) end)
                if addok then items_added = items_added + 1 end
            end
        end
    end
    logf("handle_container_list: recreated %d containers, added %d items", recreated, items_added)
    -- Optional: re-key the freshly-tracked containers (the Create wrap
    -- assigned them new local IDs 1..N in iteration order) to host's IDs.
    -- Since we iterate msg.containers in host-id order and assign local
    -- IDs in Create order (also 1..N in the same iteration), they should
    -- already match. Verify.
    local mismatched_ids = 0
    for _, c in ipairs(msg.containers) do
        if not mp.containers[c.id] then mismatched_ids = mismatched_ids + 1 end
    end
    if mismatched_ids > 0 then
        logf("handle_container_list: WARN %d host IDs missing in local containers", mismatched_ids)
    end
end

-- Host loot pop forwarded by the relay. Update our shadow record and, if
-- the engine container is still around, recreate it with the new contents
-- so the joiner can't re-loot the already-taken item.
handle_container_item_taken = function(msg)
    -- Both host AND joiner apply the shadow update + engine container
    -- rebuild: if a joiner loots a container locally, the host needs to
    -- decrement its own container so subsequent loot stays in sync.
    local cid, it = msg.container_id, msg.item_type
    local c = mp.containers and mp.containers[cid]
    if not c then
        logf("container_item_taken: id=%d UNKNOWN", cid or -1)
        return
    end
    local removed = false
    for i, v in ipairs(c.items or {}) do
        if v == it then table.remove(c.items, i); removed = true; break end
    end
    logf("container_item_taken: id=%d type=%s removed=%s remain=%d",
        cid, tostring(it), tostring(removed), #(c.items or {}))
    -- Recreate the engine container with the new (smaller) inventory so
    -- a joiner-side USE doesn't pop the host-already-claimed item.
    -- Capture the desired post-loot inventory NOW, before we trigger any
    -- AddItem wraps that mutate state.
    local target_items = {}
    for _, v in ipairs(c.items or {}) do table.insert(target_items, v) end
    if c.obj and type(c.obj.Delete) == "function" then
        pcall(function() c.obj:Delete() end)
        mp.containers[cid] = nil
        local newcont
        pcall(function()
            newcont = Create({ type = "container", x = c.x, y = c.y,
                               angle = c.angle or 0, sprite = c.sprite })
        end)
        if newcont then
            -- Create wrap assigned the new container a fresh local id.
            -- Find it, then re-key to host's cid.
            local fresh_id
            for fid, fc in pairs(mp.containers) do
                if fc.obj == newcont then fresh_id = fid; break end
            end
            if fresh_id then
                local e = mp.containers[fresh_id]
                mp.containers[fresh_id] = nil
                mp.containers[cid] = e
                for ptr, pid in pairs(mp.container_obj_to_id) do
                    if pid == fresh_id then mp.container_obj_to_id[ptr] = cid end
                end
                -- AddItem wrap will append to mp.containers[cid].items.
                for _, it2 in ipairs(target_items) do
                    pcall(function() newcont:AddItem(it2) end)
                end
            end
        end
    end
end

local function handle_item_list(msg)
    local n = (type(msg.items) == "table") and #msg.items or 0
    logf("handle_item_list: is_host=%s snapshot_received=%s msg.items_n=%d level_loaded=%s",
        tostring(mp.is_host), tostring(mp.item_snapshot_received), n,
        tostring(level and level.IsLoaded and level.IsLoaded()))
    if mp.is_host then return end
    if mp.item_snapshot_received then logf("handle_item_list: SKIP (already received)"); return end
    if n == 0 then logf("handle_item_list: SKIP (empty list)"); return end
    if not (level and level.IsLoaded and level.IsLoaded()) then
        mp.pending_item_list = msg.items
        logf("item_list received pre-level-load: %d items (stashed via handler)", n)
        return
    end
    logf("handle_item_list: spawning apply coro with %d items", n)
    start_apply_coro(msg.items)
end

local MAX_SPAWNS_PER_TICK = 3
-- Puppet reposition toggle. Left in as a diagnostic switch; bisect (2026-05-29)
-- cleared puppet movement as a crash source, so it's enabled (true) normally.
_G.MP_BISECT_PUPPET_MOVE = true
local function handle_mob_snapshot(msg)
    if mp.is_host or not mp.cleanup_done or not msg.mobs then return end
    if not mp._mob_snap_logged then
        logf("MOB SNAPSHOT first received: %d mobs", #msg.mobs)
        mp._mob_snap_logged = true
    end
    local seen = {}
    local spawned = 0
    for _, m in ipairs(msg.mobs) do
        seen[m.id] = true
        local entry = mp.mob_puppets[m.id]
        -- Defensive: somewhere mp.mob_puppets[id] ends up as a number, which
        -- crashes `entry.obj`. Log once so we can investigate, then recover.
        if entry ~= nil and type(entry) ~= "table" then
            if not mp._logged_bad_puppet_type then
                logf("BAD mob_puppets[%s] type=%s value=%s — recovering",
                    tostring(m.id), type(entry), tostring(entry))
                mp._logged_bad_puppet_type = true
            end
            mp.mob_puppets[m.id] = nil
            entry = nil
        end
        if not entry then
            if spawned < MAX_SPAWNS_PER_TICK then
                local inert = "mp_remote_" .. m.type
                if not enemylist[inert] then inert = "mp_remote_zombie" end
                local obj
                pcall(function() obj = Create{ type = inert, x = m.x, y = m.y, angle = m.a or 0 } end)
                if obj then
                    pcall(function() obj:SetName("mp_mob_" .. tostring(m.id)) end)
                    -- SetHealth on spawn disabled: caused mid-spawn-burst crashes
                end
                mp.mob_puppets[m.id] = { obj = obj, type = m.type, h_baseline = 999999, mh = m.mh, created_at = socket.gettime() }
                spawned = spawned + 1
            end
        else
            if entry.obj then
                -- Verify puppet still exists in world before SetPosition.
                -- SetPosition on a freed C entity calls abort() in native
                -- code which pcall cannot catch — process-killing crash.
                -- Grace period: trust newly-created puppets for first 1s
                -- (engine scan may not include freshly Created objects).
                local alive = true
                local age = socket.gettime() - (entry.created_at or 0)
                if age > 1.0 then
                    refresh_alive_cache()
                    alive = entry.obj.pointer and alive_ptr_cache[tostring(entry.obj.pointer)] == true
                end
                if alive then
                    -- BISECT (2026-05-29): puppet repositioning temporarily
                    -- disabled to test whether SetPosition/SetAngle on a
                    -- stale/freed entity is the joiner heap corruptor. Puppets
                    -- freeze where spawned. If the joiner stops crashing, this
                    -- path is the culprit. Re-enable after confirming.
                    if _G.MP_BISECT_PUPPET_MOVE ~= false then
                        pcall(function() entry.obj:SetPosition(m.x, m.y) end)
                        if m.a then pcall(function() entry.obj:SetAngle(m.a) end) end
                    end
                    -- SetHealth sync disabled — was triggering native abort.
                    -- Joiner's puppet HP starts at def.health (999999); damage
                    -- diff still reports drops correctly to host.
                    if m.h and not entry.h_baseline then entry.h_baseline = 999999 end
                    entry.mh = m.mh or entry.mh
                else
                    logf("MOB PUPPET id=%d type=%s gone from world — dropping", m.id, tostring(entry.type))
                    mp.mob_puppets[m.id] = nil
                end
            end
        end
    end
    -- Death is now handled by explicit mob_died events (see handle_mob_died).
    -- The previous "remove puppets missing from snapshot" path raced badly with
    -- snapshot processing and crashed the host on every mob death.
end

-- Joiner side: puppet HP is synced to host's authoritative value each
-- snapshot. Between snapshots, the local engine processes hits and
-- decrements it. We poll GetHealth, compare to the host-set baseline, and
-- forward any drop as a damage report. We clamp to >=1 locally so the
-- engine doesn't start a death animation before the host confirms.
local function diff_mob_damage()
    if mp.is_host or not mp.sock then return end
    refresh_alive_cache()
    if not mp._diff_logged then
        local n = 0
        for _ in pairs(mp.mob_puppets) do n = n + 1 end
        if n > 0 then
            logf("DIFF MOB DAMAGE: first run with %d puppets", n)
            mp._diff_logged = true
        end
    end
    for id, entry in pairs(mp.mob_puppets) do
        if type(entry) == "table" and entry.obj and entry.h_baseline then
            -- Skip freed entities. GetHealth/SetHealth on freed C++ entity
            -- aborts the process — same crash mode as SetPosition.
            local age = socket.gettime() - (entry.created_at or 0)
            local alive = age <= 1.0
                or (entry.obj.pointer and alive_ptr_cache[tostring(entry.obj.pointer)] == true)
            -- Health-poll damage detection deferred: mob puppet wrappers
            -- don't expose GetHealth on this code path. Need a different
            -- approach (input-replication or projectile hook).
            do end
        end
    end
end

local function handle_mob_damage(msg)
    if not mp.is_host or type(msg.id) ~= "number" or type(msg.dmg) ~= "number" then return end
    for ptr, info in pairs(mp.host_mobs) do
        if info.id == msg.id and info.obj then
            -- Try the native HP poke (works for Soldat subclasses). For mob
            -- classes whose visible HP isn't at +0xBC the poke is harmless
            -- but ineffective — accumulate joiner damage and once it crosses
            -- a generous threshold, DROP the mob from host_mobs. Removal
            -- stops sending it in snapshots; the joiner's puppet then
            -- despawns and stops "reviving". Mob may still be alive on the
            -- host's screen, but the joiner sees its kill stick — which is
            -- the visible behavior the joiner-authoritative path promises.
            if _G.MP_NATIVE and _G.MP_NATIVE.apply_damage and info.obj.pointer then
                local ok, new_hp = _G.MP_NATIVE.apply_damage(info.obj.pointer, msg.dmg)
                info.joiner_damage = (info.joiner_damage or 0) + msg.dmg
                local KILL_THRESHOLD = 100  -- ~3 stabs at 35 dmg
                if info.joiner_damage >= KILL_THRESHOLD then
                    logf("mob_damage RX id=%d type=%s acc=%d >= %d -> dropping from snapshot",
                        msg.id, tostring(info.type), info.joiner_damage, KILL_THRESHOLD)
                    -- Inform peers via the normal mob_died channel.
                    if mp.sock then
                        pcall(function() send_msg({ type = "mob_died", id = info.id }) end)
                    end
                    mp.host_mobs[ptr] = nil
                else
                    logf("mob_damage RX id=%d type=%s dmg=%s acc=%d new_hp=%s",
                        msg.id, tostring(info.type), tostring(msg.dmg), info.joiner_damage, tostring(new_hp))
                end
            end
            return
        end
    end
    logf("mob_damage RX id=%s: not in host_mobs (dead/untracked?)", tostring(msg.id))
end

-- Host receives a bullet_fire event from a joiner. Re-create the bullet
-- in the host's world so it propagates collision with real mobs.
-- Uses Lua's CreateBullet(x, y, angle, speed, type, force, owner). We
-- compute angle/speed from the velocity vector; type/force/owner hardcoded
-- for MVP (pistol bullet owned by the host's own player).
local function handle_bullet_fire(msg)
    if not _G.MP_LOGGED_BFIRE then
        _G.MP_LOGGED_BFIRE = true
        logf("FIRST bullet_fire: is_host=%s x=%s y=%s angle=%s speed=%s btype=%s dmg=%s",
            tostring(mp.is_host),
            tostring(msg.x), tostring(msg.y), tostring(msg.angle),
            tostring(msg.speed), tostring(msg.btype), tostring(msg.dmg))
    end
    if type(msg.x) ~= "number" or type(msg.y) ~= "number" then return end
    if type(msg.angle) ~= "number" or type(msg.speed) ~= "number" then return end
    -- CreateBullet(x, y, angle, speed, ARG5, ARG6, owner)
    -- Decompilation finding: the engine writes ARG5 raw into TBullet+0xB0
    -- and ARG6 into TBullet+0xB8. At hit time TActor::TakeDamage reads
    -- both AS FLOATS: hp -= ARG5 (armorless) or hp -= ARG5*ARG6 (armored).
    -- So ARG5 is DAMAGE (a float), NOT a bullettype id. ARG6 is the
    -- force/multiplier that also drives knockback and tick decay.
    -- Owner MUST be host's own player so the engine treats this as a
    -- player-fired bullet (mob-owned bullets damage players instead).
    --
    -- The HOST spawns a REAL bullet (full damage) for an incoming joiner shot
    -- — that's authoritative combat. A JOINER spawns a COSMETIC bullet
    -- (damage 0) so you SEE peers shooting without applying phantom damage to
    -- the joiner's inert puppets. Either way we mute the capture flag around
    -- CreateBullet so the spawned bullet isn't re-drained and re-broadcast
    -- (that would feed back into an infinite amplification loop).
    -- Owner = the FIRING peer's representation on THIS client. Critical:
    -- the engine's collision dispatch excludes only the bullet's owner from
    -- hits. If we naïvely use player.GetPlayer() (= local player), then on
    -- the HOST side, an incoming joiner bullet has owner=host_local — so
    -- the engine happily collides it with the joiner's PUPPET (a separate
    -- TPlayer object) and triggers a pain anim on the puppet. The puppet
    -- then visibly reacts as if joiner shot themselves.
    --
    -- Resolution: look up mp.puppets[msg.from] and use that puppet's
    -- pointer as owner. Fall back to local player only if the puppet isn't
    -- known (shouldn't happen but defensive).
    local owner = nil
    if msg.from and mp.puppets and mp.puppets[msg.from]
       and mp.puppets[msg.from].obj then
        owner = mp.puppets[msg.from].obj
    end
    if not owner then owner = player.GetPlayer() end
    -- Real bullet on BOTH sides. Previously the joiner spawned cosmetic
    -- (damage 0) bullets for host shots — which meant host bullets did
    -- nothing to the joiner's local TPlayer. With real damage on both
    -- sides, host→joiner and joiner→host are symmetric: the receiver's
    -- engine applies the firer's damage to its own local body. Mob
    -- puppets sit at HP 999999 so a stray hit is harmless visually,
    -- and player puppets have set_invulnerable=1 to gate TakeDamage.
    local bdmg = (type(msg.dmg) == "number") and msg.dmg or 10
    -- Real force from the firing weapon (ctor a7); fall back to 2.0. Force also
    -- drives knockback + bullet range (tick decay), so the replicated shot
    -- behaves like the original weapon.
    local bforce = (type(msg.force) == "number" and msg.force > 0) and msg.force or 2.0
    -- Subclass dispatch BEFORE CreateBullet — TLaser has its own native
    -- spawner because vtable-swap on a TBullet won't give a working
    -- raycast laser (TLaser owns sub-objects + uses TProjectile base).
    logf("handle_bullet_fire: subclass=%s create_tlaser=%s",
        tostring(msg.subclass), tostring(_G.MP_NATIVE and _G.MP_NATIVE.create_tlaser ~= nil))
    if msg.subclass == 3 and _G.MP_NATIVE and _G.MP_NATIVE.create_tlaser then
        -- msg.angle was reconstructed from (vx,vy) = (cos,sin) on the firer.
        local fang = msg.angle or 0
        -- Lasgun damage isn't a ctor arg — the engine writes it post-ctor;
        -- our firer-side hook can't grab it from the ctor frame. Fall back
        -- to the static weapon damage from relvad.lua (lasgun=16).
        local laser_dmg = (type(msg.dmg) == "number" and msg.dmg > 0) and msg.dmg or 16
        -- owner is the puppet's Lua TABLE handle ({pointer=…}); the native
        -- resolve_entity expects light userdata, so pass the .pointer
        -- field directly.
        local owner_ptr = owner and owner.pointer
        if not owner_ptr then
            logf("create_tlaser SKIP: no owner_ptr")
            return
        end
        -- Track one active laser per peer. The first bullet_fire of a
        -- fire-stream spawns it; subsequent laser_keepalive messages
        -- refresh it; laser_end (or a 0.5s grace timeout for stragglers)
        -- kills it. Per-shot spawn-then-kill never matched the firer's
        -- continuous look because lasgun fires 1-3 Hz — gaps too big.
        mp.peer_lasers = mp.peer_lasers or {}
        local existing = mp.peer_lasers[msg.from]
        if existing and existing.obj and existing.obj.pointer then
            -- Refresh existing laser instead of spawning new (avoids
            -- visual stacking). vt[22] re-runs with owner's current
            -- state, extending beam in updated aim direction.
            pcall(function() _G.MP_NATIVE.refresh_tlaser(existing.obj.pointer) end)
            existing.last_t = socket.gettime()
        else
            local laser_obj
            pcall(function()
                if _G.MP_NATIVE.set_capture then _G.MP_NATIVE.set_capture(false) end
                laser_obj = _G.MP_NATIVE.create_tlaser(msg.x, msg.y, fang, laser_dmg, owner_ptr)
                if _G.MP_NATIVE.set_capture then _G.MP_NATIVE.set_capture(true) end
            end)
            if laser_obj and laser_obj.pointer then
                mp.peer_lasers[msg.from] = {
                    obj = laser_obj, last_t = socket.gettime(),
                }
            end
        end
        logf("bullet_fire: TLaser native spawn pos=(%.2f,%.2f) ang=%.3f dmg=%d",
            msg.x, msg.y, fang, laser_dmg)
        return
    end

    local bullet_obj
    pcall(function()
        if _G.MP_NATIVE and _G.MP_NATIVE.set_capture then _G.MP_NATIVE.set_capture(false) end
        bullet_obj = CreateBullet(msg.x, msg.y, msg.angle, msg.speed, bdmg, bforce, owner)
        if _G.MP_NATIVE and _G.MP_NATIVE.set_capture then _G.MP_NATIVE.set_capture(true) end
    end)
    -- Subclass dispatch: Lua CreateBullet only spawns base TBullet. For
    -- nails/explode, swap the vtable so the engine's impact effect (vt[20])
    -- runs the subclass behavior — nail trail / AoE explosion. Cannon is
    -- intentionally unsupported (different ctor + flat-damage path).
    if bullet_obj and bullet_obj.pointer and msg.subclass and msg.subclass ~= 0
       and _G.MP_NATIVE and _G.MP_NATIVE.swap_bullet_subclass then
        pcall(function() _G.MP_NATIVE.swap_bullet_subclass(bullet_obj.pointer, msg.subclass) end)
        if not _G.MP_LOGGED_SUBCLASS then
            _G.MP_LOGGED_SUBCLASS = true
            logf("bullet_fire: subclass=%d swapped (1=nail 2=explode)", msg.subclass)
        end
    end
end

-- A remote player stabbed. Only the host is authoritative for mobs, so the
-- host finds mobs within knife reach and frontal arc of the attacker and
-- applies melee damage + lets the knockback system react (visible feedback).
local MELEE_RANGE = 2.6      -- knife reach (world units; a touch generous)
local MELEE_ARC_DOT = 0.5    -- cos of half-arc (~±60° in front)
local MELEE_DAMAGE = 35      -- base knife damage (engine value is native; tune here)
local function handle_melee(msg)
    if not mp.is_host then return end
    if type(msg.x) ~= "number" or type(msg.y) ~= "number" or type(msg.angle) ~= "number" then return end
    local dx, dy = math.cos(msg.angle), math.sin(msg.angle)
    -- Liveness gate: never call methods on a freed mob (vtable NULL → native
    -- abort). Same safety the snapshot builder uses.
    refresh_alive_cache()
    local best_id, best_obj, best_d = nil, nil, math.huge
    for ptr, info in pairs(mp.host_mobs) do
        if info.obj and info.obj.pointer and alive_ptr_cache[tostring(info.obj.pointer)] == true then
            local mx, my
            pcall(function() mx, my = info.obj:GetPosition() end)
            if mx and my then
                local rx, ry = mx - msg.x, my - msg.y
                local dist = math.sqrt(rx * rx + ry * ry)
                if dist > 0.01 and dist <= MELEE_RANGE then
                    local ndot = (rx * dx + ry * dy) / dist   -- frontal check
                    if ndot >= MELEE_ARC_DOT and dist < best_d then
                        best_d, best_id, best_obj = dist, info.id, info.obj
                    end
                end
            end
        end
    end
    if best_obj then
        local h
        pcall(function() if best_obj.GetHealth then h = best_obj:GetHealth() end end)
        if h then
            pcall(function() best_obj:SetHealth(h - MELEE_DAMAGE, 1) end)
            logf("melee from=%s HIT mob id=%d %d->%d", tostring(msg.from), best_id, h, h - MELEE_DAMAGE)
        end
    end
end

local function handle_mob_died(msg)
    if mp.is_host or not msg.id then return end
    local entry = mp.mob_puppets[msg.id]
    if not entry then return end
    -- Untrack FIRST so the snapshot handler never SetPositions a dying/freed
    -- object (that path calls native abort, which pcall can't catch).
    mp.mob_puppets[msg.id] = nil
    if entry.obj and entity_alive(entry.obj) then
        -- CORPSE-VIA-ENGINE-DEATH DISABLED (2026-05-29). kill_actor poked the
        -- puppet's health negative to make the engine run native death — but
        -- that triggers the engine's puppet death-cleanup, which corrupts the
        -- heap and crashes ~tens of seconds later in free(). This is exactly
        -- why the inert def uses health=999999 ("prevents local puppet death —
        -- engine cleanup crashes"). Confirmed: every test with kill_actor
        -- enabled crashed; hiding is stable. Corpses need a SAFE method later
        -- (spawn a separate decorative corpse sprite, not kill the puppet).
        pcall(function() entry.obj:SetPosition(-500, -500) end)
    end
    logf("mob_died: id=%d hidden (corpse disabled — was crash source)", msg.id)
end

-- Async lobby messages. The synchronous handshake reads its own welcome /
-- room_created / game_started; if any straggler arrives later (extra room
-- update, late hello_ack), the async dispatcher routes through these.
local function apply_lobby_stats_labels()
    if not (_G.MP_NATIVE and _G.MP_NATIVE.set_button_label) then return end
    local lc = tonumber(mp.lobby_count) or 0
    local ic = tonumber(mp.in_game_count) or 0
    if mp.lobby_stats_lobby_btn and mp.lobby_stats_lobby_btn.pointer then
        pcall(function() _G.MP_NATIVE.set_button_label(
            mp.lobby_stats_lobby_btn.pointer,
            string.format("Lobby: %d", lc)) end)
    end
    if mp.lobby_stats_active_btn and mp.lobby_stats_active_btn.pointer then
        pcall(function() _G.MP_NATIVE.set_button_label(
            mp.lobby_stats_active_btn.pointer,
            string.format("Active: %d", ic)) end)
    end
end

local function handle_room_list(m)
    mp.lobby_rooms = m.rooms or {}
    mp.lobby_count    = m.lobby_count
    mp.in_game_count  = m.in_game_count
    apply_lobby_stats_labels()
    logf("room_list: %d lobby, %d active (sent %d entries)",
        tonumber(mp.lobby_count) or 0, tonumber(mp.in_game_count) or 0,
        #mp.lobby_rooms)
end
local function handle_room_updated(m)
    mp.last_room_update = m.room
end
local function handle_left_room(_)
    logf("left_room ack")
end
local function handle_join_failed(m)
    if m.reason == "room_full" then
        logf("Join failed: room is FULL (4/4 players already in).")
    elseif m.reason == "no_such_room" then
        logf("Join failed: that room no longer exists. Click Refresh List.")
    else
        logf("Join failed: %s", tostring(m.reason))
    end
end

local function handle_kicked(m)
    local reason = tostring(m.reason or "")
    logf("KICKED from room (by id=%s reason=%s in_game=%s)",
        tostring(m.by), reason, tostring(mp.in_game))
    mp.was_kicked = true
    mp.kicked_reason = reason
    if mp.sock then pcall(function() mp.sock:close() end); mp.sock = nil end
    if mp.in_game then
        -- Mid-game disconnect: need the full "Disconnected from Room"
        -- notification + restart Teleglitch path (level + puppet state
        -- can't be safely unwound here).
        mp.pending_kick_cleanup = true
    else
        -- Still in lobby/waiting room → no level loaded, no MP entities
        -- to leak. Just go back to mp_lobby so the joiner can join
        -- another room or create one.
        mp.room_id = nil
        mp.is_host = false
        mp.room_players = {}
        mp.game_started_pending = false
        if _G.MP_NATIVE and _G.MP_NATIVE.set_esc_leaves_lobby then
            pcall(function() _G.MP_NATIVE.set_esc_leaves_lobby(false) end)
        end
        pcall(function() menu.SetPage("mp_lobby") end)
    end
end
local function handle_game_started(m)
    if m.seed then mp.session_seed = m.seed end
    mp.game_started_pending = true   -- caller drains & checks; we do NOT call
                                     -- begin_game from inside a sock receive
                                     -- loop (state change mid-loop crashes).
    logf("game_started async: seed=%s (flagged for caller)", tostring(m.seed))
end
local function handle_room_created(m)
    -- Echo only — handshake captured the canonical create. Log for visibility.
    logf("room_created async: room_id=%s", tostring(m.room_id))
end
local function handle_hello_ack(m)
    logf("hello_ack async: client_id=%s", tostring(m.client_id))
end

-- Peer reported dead via server forward of player_died. Mark the puppet
-- so spectate target selection skips them. Reset on level transition
-- (task #10) and on handle_leave (puppet vanishes anyway).
local function handle_peer_died(m)
    if not m or not m.id then return end
    local entry = mp.puppets[m.id]
    if entry then
        entry.is_dead = true
        -- Hide the puppet immediately so the host's mob AI deaggros this
        -- frame, without waiting for the next state snapshot to arrive.
        if entry.obj then
            pcall(function() entry.obj:SetPosition(-9999, -9999) end)
        end
        logf("peer_died id=%s name=%s — puppet hidden off-map", tostring(m.id), tostring(entry.name))
    else
        logf("peer_died for unknown id=%s (puppet not tracked yet)", tostring(m.id))
    end
end

-- Laser on/off protocol — receiver state machine. Firer broadcasts these
-- between bullet_fire and laser_end to keep the persistent TLaser alive
-- in the direction the firer is currently aiming.
local function handle_laser_keepalive(msg)
    if not msg.from then return end
    mp.peer_lasers = mp.peer_lasers or {}
    local entry = mp.peer_lasers[msg.from]
    if entry and entry.obj and entry.obj.pointer
       and _G.MP_NATIVE and _G.MP_NATIVE.refresh_tlaser then
        pcall(function() _G.MP_NATIVE.refresh_tlaser(entry.obj.pointer) end)
        entry.last_t = socket.gettime()
    end
end

local function handle_laser_end(msg)
    if not msg.from then return end
    mp.peer_lasers = mp.peer_lasers or {}
    local entry = mp.peer_lasers[msg.from]
    if entry and entry.obj and entry.obj.pointer
       and _G.MP_NATIVE and _G.MP_NATIVE.mark_laser_dead then
        pcall(function() _G.MP_NATIVE.mark_laser_dead(entry.obj.pointer) end)
    end
    mp.peer_lasers[msg.from] = nil
end

local handlers = {
    welcome = handle_welcome,
    join = function(m) handle_join(m) end,
    leave = handle_leave,
    snapshot = handle_snapshot,
    peer_died = handle_peer_died,
    bomb_activated = handle_bomb_activated,
    host_changed = handle_host_changed,
    mob_snapshot = handle_mob_snapshot,
    mob_died = handle_mob_died,
    mob_damage = handle_mob_damage,
    bullet_fire = handle_bullet_fire,
    laser_keepalive = handle_laser_keepalive,
    laser_end = handle_laser_end,
    melee = handle_melee,
    item_picked = handle_item_picked,
    item_list = handle_item_list,
    container_list = handle_container_list,
    container_item_taken = function(m) handle_container_item_taken(m) end,
    item_spawned = handle_item_spawned,
    inventory = handle_inventory,
    -- New lobby / multi-room messages.
    hello_ack    = handle_hello_ack,
    room_list    = handle_room_list,
    room_created = handle_room_created,
    room_updated = handle_room_updated,
    left_room    = handle_left_room,
    join_failed  = handle_join_failed,
    game_started = handle_game_started,
    kicked       = handle_kicked,
}

-- Build a mob snapshot from the host's tracked mobs. Filters out dead/invalid entries.
local function build_mob_snapshot()
    local mobs = {}
    local dead_ids = {}
    local dead_ptrs = {}
    -- Build "alive in world" pointer set so we never call methods on a
    -- freed C++ entity (vtable becomes NULL, hard-crashes the host).
    local alive_set = {}
    do
        local pl = player.GetPlayer()
        local px, py = 0, 0
        if pl then pcall(function() px, py = pl:GetPosition() end) end
        -- Huge radius: the scan is a SAFETY filter (don't call methods on a
        -- freed C++ entity), not a relevance filter. A small radius centered
        -- on the host player falsely culls mobs the roaming joiner is fighting.
        local objs = GetObjectsInCircle(px, py, 1000000)
        if type(objs) == "table" then
            for _, o in ipairs(objs) do
                if type(o) == "table" and o.pointer then
                    alive_set[tostring(o.pointer)] = true
                end
            end
        end
    end
    -- Debounce: a mob absent from the scan for ONE frame is NOT proof of death
    -- (the scan glitches / can miss live entities). Only declare a mob dead
    -- after it's been absent MISS_LIMIT consecutive snapshots. This was the
    -- "mobs revive" bug: a single-frame scan miss fired a false mob_died, the
    -- joiner killed the puppet, then the still-alive mob respawned it.
    local MISS_LIMIT = 3
    for ptr, info in pairs(mp.host_mobs) do
        local in_world = info.obj and info.obj.pointer and alive_set[tostring(info.obj.pointer)]
        if not in_world then
            info.miss = (info.miss or 0) + 1
            if info.miss >= MISS_LIMIT then
                table.insert(dead_ids, info.id)
                table.insert(dead_ptrs, ptr)
            else
                -- Not confirmed dead yet — keep last known position in the
                -- snapshot so the puppet doesn't flicker or get re-spawned.
                if info.last_x then
                    table.insert(mobs, { id = info.id, type = info.type,
                        x = info.last_x, y = info.last_y, a = info.last_a or 0,
                        h = info.last_h, mh = info.mh })
                end
            end
        else
            info.miss = 0
            local x, y, a, h, mh
            local ok = pcall(function()
                x, y = info.obj:GetPosition()
                a = info.obj:GetAngle()
                if info.obj.GetHealth then h = info.obj:GetHealth() end
                if info.obj.GetMaxHealth then mh = info.obj:GetMaxHealth() end
            end)
            if ok and x and y and (not h or h > 0) then
                -- Cache last-known state for the debounce path above.
                info.last_x, info.last_y, info.last_a, info.last_h = x, y, a or 0, h
                table.insert(mobs, { id = info.id, type = info.type, x = x, y = y, a = a or 0, h = h, mh = mh })
            else
                -- Confirmed dead: GetHealth <= 0 (real death, not a scan miss).
                table.insert(dead_ids, info.id)
                table.insert(dead_ptrs, ptr)
            end
        end
    end
    for _, ptr in ipairs(dead_ptrs) do mp.host_mobs[ptr] = nil end
    -- Broadcast explicit death event for each newly-dead mob so joiners can
    -- cleanly remove the puppet without inferring death from "missing from
    -- snapshot" (which raced badly with the snapshot processing).
    for _, id in ipairs(dead_ids) do
        if mp.sock then
            send_msg({ type = "mob_died", id = id })
            logf("mob_died broadcast id=%d", id)
        end
    end
    return mobs
end

-- ============ CONNECTION ============
-- Synchronous frame send/recv used during the handshake. After handshake
-- completes, net_tick_loop owns the socket and parses frames asynchronously.
local function _send_frame(sock, msg)
    local body = json.encode(msg)
    return sock:send(pack_u32_be(#body) .. body)
end
local function _recv_frame(sock)
    local len_bytes, e1 = sock:receive(4)
    if not len_bytes then return nil, e1 end
    local body_len = unpack_u32_be(len_bytes)
    local body_str, e2 = sock:receive(body_len)
    if not body_str then return nil, e2 end
    local ok, m = pcall(json.decode, body_str)
    if not ok then return nil, "bad json" end
    return m
end
-- Read until we get the message type we want. Other messages (room_list,
-- room_updated, etc.) get queued for the post-handshake dispatcher to handle.
-- Bounded by a wall-clock deadline so a missing message can't hang us.
local function _recv_until(sock, want_type, deadline_s, queue)
    local deadline = (socket.gettime and socket.gettime() or os.time()) + (deadline_s or 8)
    while true do
        local now = socket.gettime and socket.gettime() or os.time()
        if now > deadline then return nil, "timeout waiting for " .. want_type end
        local m, err = _recv_frame(sock)
        if not m then return nil, err end
        if m.type == want_type then return m end
        if queue then table.insert(queue, m) end
    end
end

local function _apply_welcome(welcome)
    mp.puppets = {}
    mp.peer_lasers = {}
    mp.items = {}
    mp.item_obj_to_id = {}
    mp.next_item_id = 1
    mp.item_snapshot_sent = false
    mp.item_snapshot_received = false
    mp.pending_item_list = nil
    -- Cross-session state that must NOT leak from a prior room. Without
    -- these, host→leave→join can either premature-trigger begin_game
    -- (stale pending) or block it forever (stale in_game).
    mp.in_game = false
    mp.game_started_pending = false
    mp.is_dead = false
    mp.death_announced_at = nil
    mp.local_player_obj = nil
    mp.local_player_ptr = nil
    mp.last_laser_t = nil
    mp.laser_was_held = false
    joiner_pre_snapshot_items = {}
    joiner_pre_snapshot_objs = {}
    mp.my_id = welcome.id
    mp.room_id = welcome.room_id
    mp.room_name = welcome.room_name
    mp.host_id = welcome.host_id
    mp.is_host = (welcome.host_id == welcome.id)
    mp.session_seed = welcome.seed
    mp.pending_initial_players = welcome.players or {}
    -- Live roster for the waiting-room UI (excludes self).
    mp.room_players = {}
    for _, p in ipairs(welcome.players or {}) do
        if p.id ~= mp.my_id then
            table.insert(mp.room_players, { id = p.id, name = p.name })
        end
    end
    if not mp.is_host and type(welcome.item_list) == "table" and #welcome.item_list > 0 then
        mp.pending_item_list = welcome.item_list
        logf("welcome: stashed pending_item_list n=%d", #welcome.item_list)
    end
    logf("welcome: room_id=%s room='%s' my_id=%d seed=%s host_id=%s is_host=%s status=%s players=%d",
        tostring(welcome.room_id), tostring(welcome.room_name),
        welcome.id, tostring(welcome.seed), tostring(welcome.host_id),
        tostring(mp.is_host), tostring(welcome.status), #(welcome.players or {}))
    if apply_waiting_labels then pcall(apply_waiting_labels) end
end

-- New-protocol handshake. Connects to the relay, sends `hello`, then either
-- create_room (host) or list_rooms + join_room (joiner). Phase 1 keeps the
-- 'click-and-play' feel by auto-sending start_game after a host's create.
-- Phase 2 will route through the lobby UI (mp_lobby page) and let the host
-- decide when to start.
local function connect_and_handshake(proposed_seed)
    logf("connecting to %s:%d as '%s'…", config.host, config.port, config.name)
    local sock = socket.tcp()
    sock:settimeout(5)
    local ok, err = sock:connect(config.host, config.port)
    if not ok then logf("connect failed: %s", tostring(err)); return false, err end
    pcall(function() sock:setoption("tcp-nodelay", true) end)

    -- Catch any out-of-band messages (room_list pushes etc.) that arrive
    -- between the messages we explicitly expect. After handshake we replay
    -- them through the main dispatcher.
    local queued = {}

    -- Server sends hello_ack on connect.
    local ack, err1 = _recv_until(sock, "hello_ack", 5, queued)
    if not ack then sock:close(); logf("no hello_ack: %s", tostring(err1)); return false, err1 end
    logf("hello_ack: client_id=%s", tostring(ack.client_id))

    -- Send our hello (just name now — no auto-session).
    local ok2, err2 = _send_frame(sock, { type = "hello", name = config.name })
    if not ok2 then sock:close(); return false, err2 end

    local is_host = proposed_seed ~= nil
    local welcome
    if is_host then
        -- Host: create the room. Server auto-joins us and sends welcome.
        local room_name = (config.name or "Player") .. "'s game"
        _send_frame(sock, { type = "create_room", name = room_name, seed = proposed_seed })
        local rc, e3 = _recv_until(sock, "room_created", 5, queued)
        if not rc then sock:close(); return false, "no room_created: " .. tostring(e3) end
        logf("room_created: room_id=%d", rc.room_id)
        local w, e4 = _recv_until(sock, "welcome", 5, queued)
        if not w then sock:close(); return false, "no welcome (host): " .. tostring(e4) end
        welcome = w
        _apply_welcome(welcome)
        -- Phase 1 auto-start. Phase 2 will defer this to a Start button.
        _send_frame(sock, { type = "start_game" })
        local gs, e5 = _recv_until(sock, "game_started", 5, queued)
        if not gs then sock:close(); return false, "no game_started (host): " .. tostring(e5) end
        mp.session_seed = gs.seed  -- canonical post-start seed
    else
        -- Joiner: list, pick the first available room, join, wait for start.
        _send_frame(sock, { type = "list_rooms" })
        local rl, e3 = _recv_until(sock, "room_list", 5, queued)
        if not rl then sock:close(); return false, "no room_list: " .. tostring(e3) end
        if not rl.rooms or #rl.rooms == 0 then
            sock:close()
            logf("no rooms available to join")
            return false, "no rooms"
        end
        local target = rl.rooms[1]
        logf("joining room id=%d name='%s' host_id=%s", target.room_id, tostring(target.name), tostring(target.host_id))
        _send_frame(sock, { type = "join_room", room_id = target.room_id })
        local w, e4 = _recv_until(sock, "welcome", 5, queued)
        if not w then sock:close(); return false, "no welcome (joiner): " .. tostring(e4) end
        welcome = w
        _apply_welcome(welcome)
        if welcome.status ~= "in_game" then
            -- Host hasn't started yet — block until they do (up to 60s).
            local gs, e5 = _recv_until(sock, "game_started", 60, queued)
            if not gs then sock:close(); return false, "no game_started (joiner): " .. tostring(e5) end
            mp.session_seed = gs.seed
        end
    end

    -- Hand the socket off to the async dispatcher and replay anything that
    -- arrived out-of-order during the handshake.
    sock:settimeout(0)
    mp.sock = sock
    mp.rx_buf = ""
    mp.handshake_queued = queued  -- net_tick_loop drains this first

    return true, mp.session_seed
end

local function disconnect_only()
    if mp.sock then pcall(function() mp.sock:close() end); mp.sock = nil end
    mp.rx_buf = ""
    for _, entry in pairs(mp.puppets) do
        safe_delete(entry.obj)
        if entry.nameplate then pcall(function() entry.nameplate:Delete() end) end
    end
    mp.puppets = {}
    mp.items = {}
    mp.item_obj_to_id = {}
    mp.next_item_id = 1
    mp.item_snapshot_sent = false
    mp.item_snapshot_received = false
    mp.pending_item_list = nil
    joiner_pre_snapshot_items = {}
    joiner_pre_snapshot_objs = {}
    mp.my_id = nil
end

local function disconnect()
    disconnect_only()
    logf("disconnected")
end

-- ============ NETWORK COROUTINE ============
local function net_tick_loop()
    local send_interval = 1.0 / config.send_rate_hz
    -- Drain any messages the handshake queued (lobby pushes that arrived
    -- between expected handshake replies). Routed through the normal
    -- handlers table before the socket loop starts pulling new frames.
    if mp.handshake_queued and #mp.handshake_queued > 0 then
        for _, m in ipairs(mp.handshake_queued) do
            local h = handlers[m.type]
            if h then pcall(h, m) else logf("handshake-queue unknown type=%s", tostring(m.type)) end
        end
        mp.handshake_queued = nil
    end
    while true do
        -- Mob-class vtable takedmg hook DISABLED — signature mismatch on
        -- non-Soldat classes crashed the host on first bullet hit. Direct
        -- damage on host is parked (Task: joiner melee). The accumulator
        -- snapshot-drop in handle_mob_damage keeps the joiner-side feel.
        if mp.sock then
            local chunk, err, partial = mp.sock:receive(4096)
            if chunk then
                mp.rx_buf = mp.rx_buf .. chunk
            elseif err == "timeout" and partial and #partial > 0 then
                mp.rx_buf = mp.rx_buf .. partial
            elseif err == "closed" then
                logf("server closed connection")
                disconnect()
            end
            while mp.sock do
                local msg = try_recv_msg()
                if not msg then break end
                if msg.type ~= "snapshot" and msg.type ~= "mob_snapshot" and msg.type ~= "state" then
                    logf("RX msg type=%s", tostring(msg.type))
                end
                local h = handlers[msg.type]
                if h then
                    local hok, herr = pcall(h, msg)
                    if not hok then logf("handler %s crashed: %s", tostring(msg.type), tostring(herr)) end
                else
                    logf("unknown msg type: %s", tostring(msg.type))
                end
            end
            -- Death intercept: poll local HP + drive spectate state.
            -- Runs here (not MP_FRAME_TICK) because the engine's in-game
            -- Lua dispatch bypasses our lua_resume/lua_pcallk hooks, so
            -- MP_FRAME_TICK doesn't fire after begin_game. This coroutine
            -- IS resumed on every tick (Wait yields go through lua_resume).
            pcall(tick_death_intercept)
            local now = socket.gettime()
            if mp.sock and now - mp.last_send >= send_interval then
                local pl = player.GetPlayer()
                if pl then
                    local x, y = pl:GetPosition()
                    -- Use the engine's committed body angle (+0xB0). During
                    -- stab/aim the engine locks +0xB0 to the attack
                    -- direction it captured when the attack started — that
                    -- IS the angle the local body renders at, so the
                    -- puppet should match it. Mouse-derived angles drift
                    -- away from the locked attack direction (user-visible
                    -- mismatch). Outside attack states +0xB0 still tracks
                    -- mouse via the engine's normal case-1/case-8 logic.
                    local a = pl:GetAngle()
                    local hp = pl:GetHealth()
                    -- Sync the player's animation frame. GetFrame() returns the
                    -- body sprite frame, which encodes the full pose (per-weapon
                    -- hold/shoot/reload/stab). The puppet can't SetFrame from Lua
                    -- (thin handle), so the remote side pokes it natively by ptr.
                    local f
                    pcall(function() if pl.GetFrame then f = pl:GetFrame() end end)
                    -- Read the player's real ACTION id (engine field +0xB4) to
                    -- sync to peers. Unlike the frame, the action is upstream of
                    -- the anim state, so writing it on the puppet is safe and
                    -- drives the real walk/shoot/aim animation.
                    local act
                    if _G.MP_NATIVE and _G.MP_NATIVE.get_action and pl.pointer then
                        pcall(function() act = _G.MP_NATIVE.get_action(pl.pointer) end)
                    end
                    -- Melee detection via the body frame (knife stab = frames
                    -- 27..29). JOINER-AUTHORITATIVE: when WE stab, pick the mob
                    -- PUPPET we're hitting (the one we can see) and tell the host
                    -- to damage that exact mob by id over the mob_damage channel.
                    -- Trusting the joiner's own pick is far more reliable than the
                    -- host re-deriving the hit from a lagged position. Only the
                    -- joiner has mob_puppets, so this no-ops on the host (whose own
                    -- stabs the local engine already applies).
                    local is_stab = f and f >= 26.5 and f <= 30.5
                    if is_stab and not _G.MP_WAS_STABBING and not mp.is_host then
                        local cdx, cdy = math.cos(a), math.sin(a)
                        local best_id, best_entry, best_d = nil, nil, math.huge
                        refresh_alive_cache()
                        for id, entry in pairs(mp.mob_puppets) do
                            if type(entry) == "table" and entry.obj and entry.obj.pointer
                               and entity_alive(entry.obj) then
                                local mx, my
                                pcall(function() mx, my = entry.obj:GetPosition() end)
                                if mx and my then
                                    local rx, ry = mx - x, my - y
                                    local dist = math.sqrt(rx * rx + ry * ry)
                                    if dist <= MELEE_RANGE then
                                        local ndot = (dist > 0.01) and ((rx * cdx + ry * cdy) / dist) or 1.0
                                        if ndot >= MELEE_ARC_DOT and dist < best_d then
                                            best_d, best_id, best_entry = dist, id, entry
                                        end
                                    end
                                end
                            end
                        end
                        if best_id then
                            -- Armored/robotic mobs resist the knife (knifedamagemult
                            -- in monsterstats, e.g. 0.2). Compute final damage here
                            -- (the host trusts whatever the joiner reports).
                            local mult = 1.0
                            local ms = _G.monsterstats
                            if ms and best_entry.type and ms[best_entry.type]
                               and type(ms[best_entry.type].knifedamagemult) == "number" then
                                mult = ms[best_entry.type].knifedamagemult
                            end
                            local dmg = math.floor(MELEE_DAMAGE * mult + 0.5)
                            send_msg({ type = "mob_damage", id = best_id, dmg = dmg })
                            logf("stab -> mob_damage id=%d dmg=%d type=%s dist=%.2f",
                                best_id, dmg, tostring(best_entry.type), best_d)
                        end
                    end
                    _G.MP_WAS_STABBING = is_stab
                    send_msg({ type = "state", x = x, y = y, angle = a, hp = hp, f = f, act = act })
                end
                mp.last_send = now
            end
            -- 20 Hz mob sync (was 10). build_mob_snapshot also detects deaths
            -- and fires mob_died, so this rate doubles as the death-event rate
            -- — faster corpses on the joiner and smoother mob motion. Cheap on
            -- localhost; still fine for Railway (a few mobs * 20 Hz).
            if mp.is_host and mp.sock and now - mp.last_mob_send >= 0.05 then
                send_msg({ type = "mob_snapshot", mobs = build_mob_snapshot() })
                mp.last_mob_send = now
            end
            -- Apply any stashed item_list once level is up (joiner).
            if (not mp.is_host) and mp.pending_item_list and level and level.IsLoaded and level.IsLoaded() then
                logf("tick_loop: spawning apply coro for pending_item_list (n=%d)", #(mp.pending_item_list or {}))
                local list = mp.pending_item_list
                mp.pending_item_list = nil
                start_apply_coro(list)
            end
            if not giveitem_hook_installed and now >= mp.pickup_scan_start_after then
                pcall(install_giveitem_hook)
            end
            -- Inventory diff every tick (~30 Hz) — smallest window we can afford.
            -- A pickup local-to-broadcast-to-remote-delete cycle now sits around
            -- one game tick locally + RTT, so simultaneous space-presses by two
            -- players become very unlikely.
            if giveitem_hook_installed then
                pcall(diff_inventory)
                pcall(diff_ammo)
            end
            -- Joiner-only: report puppet HP drops as authoritative damage to host.
            if not mp.is_host then pcall(diff_mob_damage) end
            pcall(update_nameplates)
            -- Broadcast own inventory at 4 Hz (on change inside fn)
            if giveitem_hook_installed and now - mp.last_inv_send >= 0.25 then
                mp.last_inv_send = now
                pcall(sync_own_inventory)
            end
            if now - mp.last_label_update >= 0.5 then
                mp.last_label_update = now
                if not (dev_menu and dev_menu.visible) then
                    refresh_objective_string()
                end
            end
        end
        Wait(1/30)
    end
end

local function start_net_coro()
    if mp.coro_running then return end
    mp.coro_running = true
    local co = coroutine.create(function()
        local ok, err = pcall(net_tick_loop)
        if not ok then logf("net coroutine crashed: %s", tostring(err)) end
        mp.coro_running = false
    end)
    coroutine.resume(co)
end

-- ============ JOINER: clear local mobs after level load ============
local function clear_local_mobs()
    local pl = player.GetPlayer()
    if not pl then mp.cleanup_done = true; return end
    local px, py = pl:GetPosition()
    local my_ptr = tostring(pl.pointer)
    local objs = GetObjectsInCircle(px, py, 1000)
    if type(objs) ~= "table" then mp.cleanup_done = true; return end
    -- Belt-and-suspenders: never Delete one of our OWN tracked puppets even if
    -- GetName misfires — a dangling entry.obj would later be double-freed.
    local owned = {}
    for _, e in pairs(mp.puppets) do
        if type(e) == "table" and e.obj and e.obj.pointer then owned[tostring(e.obj.pointer)] = true end
    end
    for _, e in pairs(mp.mob_puppets) do
        if type(e) == "table" and e.obj and e.obj.pointer then owned[tostring(e.obj.pointer)] = true end
    end
    local deleted, batch = 0, 0
    for _, obj in ipairs(objs) do
        if type(obj) == "table" and obj.Alert and obj.Delete and tostring(obj.pointer) ~= my_ptr
           and not owned[tostring(obj.pointer)] then
            local nm = ""
            pcall(function() nm = obj:GetName() or "" end)
            if string.sub(nm, 1, 3) ~= "mp_" then
                local ok = pcall(function() obj:Delete() end)
                if ok then deleted = deleted + 1 end
                batch = batch + 1
                if batch >= 5 then Wait(0.05); batch = 0 end
            end
        end
    end
    logf("clear_local: deleted %d mobs", deleted)
    mp.cleanup_done = true
end

local function start_joiner_cleanup_coro()
    if mp.is_host then mp.cleanup_done = true; return end
    local co = coroutine.create(function()
        local ok, err = pcall(function()
            Wait(1.5)
            clear_local_mobs()
        end)
        if not ok then logf("joiner cleanup crashed: %s", tostring(err)) end
    end)
    coroutine.resume(co)
end

-- ============ TEST ROOM ============
-- Controlled scene: wipes everything, spawns a tiny known set.
-- HOST spawns 2 items + 1 mob at fixed positions and sends snapshot.
-- JOINER's wraps already block local item spawns; just clears mobs and waits.
-- Minimal scene to isolate crashes: 1 item, no mob.
-- We'll add more once the baseline is stable.
local TEST_ITEMS = {
    { type = "pystol",     dx = 1.5, dy = 0 },
}
local TEST_MOBS = {}

local function wipe_all_mobs(reason)
    local pl = player.GetPlayer()
    if not pl then return 0 end
    local px, py = pl:GetPosition()
    local my_ptr = tostring(pl.pointer)
    local objs = GetObjectsInCircle(px, py, 1000)
    if type(objs) ~= "table" then return 0 end
    local deleted, batch = 0, 0
    for _, obj in ipairs(objs) do
        if type(obj) == "table" and obj.Alert and obj.Delete and tostring(obj.pointer) ~= my_ptr then
            local nm = ""
            pcall(function() nm = obj:GetName() or "" end)
            if string.sub(nm, 1, 3) ~= "mp_" then
                pcall(function() obj:Delete() end)
                deleted = deleted + 1
                batch = batch + 1
                if batch >= 5 then Wait(0.05); batch = 0 end
            end
        end
    end
    -- Clear host's mob tracking too
    if mp.is_host then mp.host_mobs = {} end
    logf("test_room: wiped %d mobs (%s)", deleted, tostring(reason))
    return deleted
end

local function setup_test_room()
    Wait(1.5)  -- let level1 finish loading
    logf("test_room: BEGIN setup is_host=%s", tostring(mp.is_host))

    if mp.is_host then
        local pl = player.GetPlayer()
        local px, py = 0, 0
        if pl then pcall(function() px, py = pl:GetPosition() end) end
        logf("test_room: host player pos=(%.2f,%.2f) — spawning relative to here", px, py)
        mp.spawn_test_scene = true  -- bypass the test-mode spawn-block
        for _, item in ipairs(TEST_ITEMS) do
            local ix, iy = px + item.dx, py + item.dy
            local ok = pcall(function() Create{ type = item.type, x = ix, y = iy, angle = 0 } end)
            logf("test_room: spawn item type=%s pos=(%.1f,%.1f) ok=%s",
                item.type, ix, iy, tostring(ok))
            Wait(0.1)
        end
        for _, m in ipairs(TEST_MOBS) do
            local mx, my = px + m.dx, py + m.dy
            local ok = pcall(function() Create{ type = m.type, x = mx, y = my, angle = 0 } end)
            logf("test_room: spawn mob type=%s pos=(%.1f,%.1f) ok=%s",
                m.type, mx, my, tostring(ok))
            Wait(0.1)
        end
        mp.spawn_test_scene = false
        Wait(0.3)
        host_send_item_list()
    end
    mp.cleanup_done = true
    logf("test_room: setup DONE host_items=%d", (function() local n=0; for _ in pairs(mp.items) do n=n+1 end; return n end)())
end

-- ============ DEV MENU (multi-category) ============
-- KP+ toggle, KP4/KP6 switch category, Up/Down cycle action, Enter run.
-- Available on BOTH host and joiner so the joiner can test their own death
-- intercept without being shot first.
local ITEM_TYPES = {
    "pystol", "pump", "agl", "revolver",
    "pyammo", "ppammo", "auammo", "pexpammo",
    "smtimebomb", "nailbomb", "rocketitem",
    "cmeat", "medkit", "smmedkit",
    "armor", "smarmor",
    "emptycan", "tube", "metalplate", "hardware", "nailbox",
}

local dev_spawn_counter = 0
local function spawn_at_player(name)
    local pl = player.GetPlayer()
    if not pl then return false, "no player" end
    local px, py = pl:GetPosition()
    dev_spawn_counter = dev_spawn_counter + 1
    local angle = dev_spawn_counter * 0.7
    local radius = 1.2 + (dev_spawn_counter % 4) * 0.4
    local ix = px + math.cos(angle) * radius
    local iy = py + math.sin(angle) * radius
    mp.spawn_test_scene = true
    local ok, err = pcall(function() Create{ type = name, x = ix, y = iy, angle = 0 } end)
    mp.spawn_test_scene = false
    return ok, err
end

-- Categories: each = { name, actions = { {label, run}, ... } }.
-- Built lazily so it can reference functions defined later in this file
-- (refresh_objective_string, send_msg, etc. are already in scope here).
local DEV_CATEGORIES
local function build_dev_categories()
    if DEV_CATEGORIES then return DEV_CATEGORIES end

    -- Test triggers — available on both host and joiner.
    local test_actions = {
        { label = "Kill self (enter spectate)", run = function()
            if mp.is_dead then logf("dev: already dead"); return end
            mp.is_dead = true
            mp.death_announced_at = nil  -- frame_tick will pin + announce
            logf("dev: kill_self → mp.is_dead = true")
        end },
        { label = "Revive (clear dead state)", run = function()
            mp.is_dead = false
            mp.death_announced_at = nil
            local pl = player.GetPlayer()
            if pl and pl.pointer and _G.MP_NATIVE and _G.MP_NATIVE.set_invulnerable then
                pcall(function() _G.MP_NATIVE.set_invulnerable(pl.pointer, false) end)
            end
            pcall(refresh_objective_string)
            logf("dev: revive")
        end },
        { label = "Dump MP state", run = function()
            local n_puppets = 0
            for _, e in pairs(mp.puppets or {}) do
                n_puppets = n_puppets + 1
                logf("  puppet id=? name=%s is_dead=%s pos=(%.1f,%.1f)",
                    tostring(e.name), tostring(e.is_dead),
                    e.last_x or 0, e.last_y or 0)
            end
            logf("MP STATE: in_game=%s is_host=%s is_dead=%s puppets=%d room='%s'",
                tostring(mp.in_game), tostring(mp.is_host),
                tostring(mp.is_dead), n_puppets, tostring(mp.room_name))
        end },
        { label = "Force send player_died", run = function()
            if mp.sock then
                pcall(function() send_msg({ type = "player_died" }) end)
                logf("dev: forced player_died send")
            end
        end },
    }

    -- Items category — host-only spawn (joiner spawn would desync).
    local item_actions = {}
    for _, name in ipairs(ITEM_TYPES) do
        local n = name
        table.insert(item_actions, { label = "Spawn " .. n, run = function()
            if not mp.is_host then logf("dev: items host-only"); return end
            local ok, err = spawn_at_player(n)
            logf("dev: spawn %s ok=%s err=%s", n, tostring(ok), tostring(err))
        end })
    end

    -- Debug probes — survives from old kp_1/2/3 inline code.
    local debug_actions = {
        { label = "TextObj probe (spawn HELLO MP)", run = function()
            local pl = player.GetPlayer()
            local px, py = 0, 0
            if pl then pcall(function() px, py = pl:GetPosition() end) end
            local ok, res = pcall(function() return CreateTextObj(px, py + 1.5, "HELLO MP") end)
            logf("dev: TextObj probe ok=%s value=%s", tostring(ok), tostring(res))
            if ok and type(res) == "table" then mp._probe_textobj = res end
        end },
        { label = "TextObj follow player", run = function()
            if not mp._probe_textobj then logf("dev: no probe yet"); return end
            local pl = player.GetPlayer()
            if not pl then return end
            local px, py = pl:GetPosition()
            pcall(function() mp._probe_textobj:SetPosition(px, py + 1.5) end)
        end },
        { label = "Print local player HP", run = function()
            local pl = player.GetPlayer()
            if not pl then return end
            local hp = nil
            pcall(function() if pl.GetHealth then hp = pl:GetHealth() end end)
            logf("dev: local HP = %s", tostring(hp))
        end },
    }

    DEV_CATEGORIES = {
        { name = "Test",  actions = test_actions  },
        { name = "Items", actions = item_actions  },
        { name = "Debug", actions = debug_actions },
    }
    return DEV_CATEGORIES
end

-- World-space multi-line menu rendered via CreateTextObj (same path as
-- nameplates). Lines follow the player so the menu is always on screen.
-- Text objects are CACHED — only recreated when content changes, to
-- avoid per-frame allocation churn that hammered the engine.
dev_menu = {
    visible    = false,
    cat        = 1,
    idx        = 1,
    text_objs  = {},   -- array of CreateTextObj handles
    text_cache = {},   -- last-set text per line — skip recreate if unchanged
}

local DEV_LINE_DY    = 0.35   -- world-units between menu rows (top to bottom)
local DEV_TOP_OFFSET = 3.5    -- world-units above player for the first line
local DEV_HIDE_POS   = -9999

local function dev_menu_clear_lines()
    for _, t in ipairs(dev_menu.text_objs) do
        if t then pcall(function() t:Delete() end) end
    end
    dev_menu.text_objs  = {}
    dev_menu.text_cache = {}
end

local function dev_menu_build_lines()
    local cats = build_dev_categories()
    local cat  = cats[dev_menu.cat]
    if not cat then return {} end
    local lines = {}
    -- Header (with simple ASCII frame to fake a "panel" without a sprite).
    table.insert(lines, "================================")
    table.insert(lines, string.format("  DEV  [%s]  (KP4/6=cat)", cat.name))
    table.insert(lines, "--------------------------------")
    for i, act in ipairs(cat.actions) do
        local marker = (i == dev_menu.idx) and ">> " or "   "
        table.insert(lines, marker .. act.label)
    end
    table.insert(lines, "--------------------------------")
    table.insert(lines, "Up/Dn=move  Enter=run  KP+=close")
    table.insert(lines, "================================")
    return lines
end

local function dev_menu_render()
    if not (level and level.IsLoaded and level.IsLoaded()) then return end
    if not dev_menu.visible then
        if #dev_menu.text_objs > 0 then dev_menu_clear_lines() end
        return
    end
    local pl = player.GetPlayer()
    if not pl then return end
    local px, py = pl:GetPosition()
    local lines = dev_menu_build_lines()
    -- Grow/shrink text_objs to match lines.
    while #dev_menu.text_objs < #lines do
        local idx = #dev_menu.text_objs + 1
        local ty = py + DEV_TOP_OFFSET - (idx - 1) * DEV_LINE_DY
        local obj
        pcall(function() obj = CreateTextObj(px, ty, lines[idx]) end)
        table.insert(dev_menu.text_objs,  obj)
        table.insert(dev_menu.text_cache, lines[idx])
    end
    while #dev_menu.text_objs > #lines do
        local last = table.remove(dev_menu.text_objs)
        table.remove(dev_menu.text_cache)
        if last then pcall(function() last:Delete() end) end
    end
    -- Update each line: reposition every frame, only recreate when text changes.
    for i, txt in ipairs(lines) do
        local ty  = py + DEV_TOP_OFFSET - (i - 1) * DEV_LINE_DY
        local obj = dev_menu.text_objs[i]
        if dev_menu.text_cache[i] ~= txt then
            if obj then pcall(function() obj:Delete() end) end
            local newobj
            pcall(function() newobj = CreateTextObj(px, ty, txt) end)
            dev_menu.text_objs[i]  = newobj
            dev_menu.text_cache[i] = txt
        elseif obj then
            pcall(function() obj:SetPosition(px, ty) end)
        end
    end
end

local function dev_menu_run_current()
    local cats = build_dev_categories()
    local cat = cats[dev_menu.cat]
    local act = cat and cat.actions[dev_menu.idx]
    if not act then return end
    logf("dev: run [%s] %s", cat.name, act.label)
    pcall(act.run)
end

local function kp(name)
    if not (input and input.KeyPressed) then return false end
    local ok, r = pcall(function() return input.KeyPressed(name) end)
    return ok and r == true
end

-- Manual "pick up nearest tracked item" — bypasses engine pickup so we can
-- exercise the network path while we figure out a real pickup-detection mechanism.
-- Works on BOTH host and joiner. Bound to Numpad -.
local function manual_pickup_nearest()
    local pl = player.GetPlayer()
    if not pl then return end
    local px, py = pl:GetPosition()
    local best_id, best_d2 = nil, math.huge
    for id, entry in pairs(mp.items) do
        local dx, dy = entry.x - px, entry.y - py
        local d2 = dx * dx + dy * dy
        if d2 < best_d2 then best_id, best_d2 = id, d2 end
    end
    if not best_id then logf("manual_pickup: NO tracked items"); return end
    local entry = mp.items[best_id]
    mp.items[best_id] = nil
    for p, pid in pairs(mp.item_obj_to_id) do
        if pid == best_id then mp.item_obj_to_id[p] = nil end
    end
    if entry.obj then safe_delete(entry.obj) end
    if mp.sock then
        send_msg({ type = "item_picked", id = best_id, picker_id = mp.my_id })
        logf("manual_pickup: id=%d type=%s d=%.2f BROADCAST",
            best_id, tostring(entry.type), math.sqrt(best_d2))
    end
end

-- Key names from lua/keys.lua — keypad +, arrow up/down, return/kp_enter.
local function dev_menu_tick()
    -- Drain native hit events and forward to host as mob_damage. Each event
    -- is a c-side entity address; we match against our local puppet pointers
    -- to find the mp mob id. Deduplicate via a short cooldown per id.
    -- Joiner: drain native bullet events, send to host so host re-fires.
    -- Include current weapon stats (speed + bullettype) so host creates a
    -- correctly-tuned bullet (speed AND damage come from bullet type).
    -- Drain on BOTH sides now: the joiner's shots reach the host for real
    -- damage, AND every shot is broadcast so peers can render a cosmetic copy
    -- (so you SEE other players shooting). handle_bullet_fire decides real vs
    -- cosmetic per receiver.
    if _G.MP_NATIVE and _G.MP_NATIVE.consume_bullet and mp.sock then
        -- Real per-shot stats come straight from the engine's TBullet ctor
        -- (captured natively): damage (a5), force (a7), bullet type (a6). Speed
        -- and angle are recovered from the real velocity. No GetEquippedItem/
        -- itemtable lookup (GetName returned nil — removed).
        for _ = 1, 16 do
            local x, y, vx, vy, dmg, force, btype, subclass = _G.MP_NATIVE.consume_bullet()
            if not x then break end
            local angle = math.atan2(vy, vx)
            -- Engine ctor gives vx/vy in PER-TICK world units (very small;
            -- sqrt -> ~1-3). Lua CreateBullet's `speed` arg is in the larger
            -- per-second scale (typical weapon defs use 12-25). Re-fire with
            -- a stable 15 — the value the old itemtable-lookup path fell back
            -- to and that visibly worked. dmg/force come straight from the
            -- ctor (real per-weapon values). btype (a6) is actually the owner
            -- pointer, not a bullet-type id — drop it.
            local raw_speed = math.sqrt(vx * vx + vy * vy)
            local speed = 15
            if not _G.MP_LOGGED_BSTATS then
                _G.MP_LOGGED_BSTATS = true
                logf("bullet stats (from ctor): dmg=%s force=%s raw_speed=%.2f -> tx_speed=%d",
                    tostring(dmg), tostring(force), raw_speed, speed)
            end
            send_msg({ type = "bullet_fire", x = x, y = y, angle = angle, speed = speed,
                       dmg = dmg or 10, force = force, subclass = subclass or 0 })
            if (subclass or 0) == 3 then
                -- Mark recent-laser-shot so the LMB keepalive loop below
                -- knows to emit laser_keepalive while LMB stays held.
                mp.last_laser_t = socket.gettime()
            end
        end
        -- Laser on/off protocol: lasgun's natural fire rate is 1-3 Hz which
        -- can't make a brief per-shot beam look continuous on the receiver.
        -- Instead, while LMB stays held AFTER a laser shot, broadcast
        -- laser_keepalive at 10Hz with current muzzle + aim. Receiver
        -- maintains a single persistent TLaser and refreshes it on each
        -- keepalive. On LMB release, broadcast laser_end → receiver kills.
        if _G.MP_NATIVE and _G.MP_NATIVE.lmb_pressed and mp.sock then
            local now = socket.gettime()
            local lmb = _G.MP_NATIVE.lmb_pressed()
            -- Tight window: 200ms (vs old 500). If reloading or out of
            -- ammo, no new laser ctor fires → window expires within 200ms
            -- → we treat the laser as ended and broadcast laser_end so
            -- the receiver kills its beam even though LMB is still held.
            local recent_laser = (now - (mp.last_laser_t or 0)) < 0.2
            local should_be_active = lmb and recent_laser
            local pl_for_aim = player.GetPlayer()
            if should_be_active and pl_for_aim then
                if (now - (mp.last_laser_keepalive_t or 0)) > 0.1 then
                    local lx, ly = pl_for_aim:GetPosition()
                    local la = pl_for_aim:GetAngle()
                    send_msg({ type = "laser_keepalive", x = lx, y = ly,
                               angle = la, from = mp.my_id })
                    mp.last_laser_keepalive_t = now
                end
                mp.laser_was_held = true
            elseif mp.laser_was_held and not should_be_active then
                -- Transition active→inactive — either LMB released OR
                -- ammo ran out / reload kicked in (no recent ctor).
                send_msg({ type = "laser_end", from = mp.my_id })
                mp.laser_was_held = false
            end
        end
        -- Drain bomb activation events from the native hook. Hook captures
        -- type + fuse only (safest data). We fill the position + aim angle
        -- from the LOCAL player here at consume time — that's the
        -- activator and the most reliable source.
        if _G.MP_NATIVE.consume_bomb then
            for _ = 1, 8 do
                local btype, _ux, _uy, _ua, fuse = _G.MP_NATIVE.consume_bomb()
                if not btype then break end
                local pl_loc = player.GetPlayer()
                local lx, ly, la = 0, 0, 0
                if pl_loc then
                    pcall(function() lx, ly = pl_loc:GetPosition() end)
                    pcall(function() la = pl_loc:GetAngle() end)
                end
                logf("BOMB activated: type=%s pos=(%.2f,%.2f) angle=%.3f fuse=%d",
                    tostring(btype), lx, ly, la, fuse or 0)
                send_msg({ type = "bomb_activated",
                           btype = btype, x = lx, y = ly, angle = la, fuse = fuse })
            end
        end
    end
    if _G.MP_NATIVE and _G.MP_NATIVE.consume_hit and _G.MP_NATIVE.addr_of and (not mp.is_host) and mp.sock then
        if not _G.MP_HIT_COOLDOWN then _G.MP_HIT_COOLDOWN = {} end
        if not _G.MP_HIT_PUPPET_ADDRS then _G.MP_HIT_PUPPET_ADDRS = {} end
        -- Refresh addr→id map periodically (puppet creation rate is low).
        if (not _G.MP_HIT_ADDR_REFRESH) or (socket.gettime() - _G.MP_HIT_ADDR_REFRESH > 1.0) then
            _G.MP_HIT_ADDR_REFRESH = socket.gettime()
            local map = {}
            for id, entry in pairs(mp.mob_puppets) do
                if type(entry) == "table" and entry.obj and entry.obj.pointer then
                    local ok, addr = pcall(function() return _G.MP_NATIVE.addr_of(entry.obj.pointer) end)
                    if ok and addr and addr ~= 0 then map[addr] = id end
                end
            end
            _G.MP_HIT_PUPPET_ADDRS = map
        end
        -- Drain up to 32 hits per tick
        local now = socket.gettime()
        for _ = 1, 32 do
            local addr = _G.MP_NATIVE.consume_hit()
            if not addr or addr == 0 then break end
            local mob_id = _G.MP_HIT_PUPPET_ADDRS[addr]
            if mob_id then
                local last = _G.MP_HIT_COOLDOWN[mob_id] or 0
                if (now - last) > 0.1 then
                    _G.MP_HIT_COOLDOWN[mob_id] = now
                    send_msg({ type = "mob_damage", id = mob_id, dmg = 10 })
                    logf("native hit -> mob_damage id=%d", mob_id)
                end
            end
        end
    end
    -- (Per-puppet vtable[+0x60] scan removed — central hit hook covers
    -- everything via the shared TNewLiving::ApplyHit base method.)
    -- Manual pickup key works on BOTH sides (host AND joiner).
    -- Numpad 0: disconnect from relay (safe — lets the user recover from
    -- accidentally clicking Host twice or other double-connect bugs).
    if kp("kp_0") then
        logf("manual disconnect (Numpad 0)")
        if mp and mp.sock then
            pcall(disconnect)
        end
    end
    if kp("kp_minus") then
        logf("manual pickup key pressed")
        manual_pickup_nearest()
    end

    -- Keep dev menu text on screen against any other writers
    -- (refresh_objective_string overwrites it each tick).
    if dev_menu.visible then dev_menu_render() end

    -- KP+ toggle — works on BOTH host and joiner so joiners can trigger
    -- the death intercept on themselves without being shot first.
    if kp("kp_plus") then
        dev_menu.visible = not dev_menu.visible
        logf("dev_menu: toggle visible=%s", tostring(dev_menu.visible))
        if not dev_menu.visible then
            dev_menu_clear_lines()
            pcall(refresh_objective_string)
        else
            dev_menu_render()
        end
    end
    if not dev_menu.visible then return end

    local cats = build_dev_categories()
    local cat  = cats[dev_menu.cat]
    if not cat then return end

    -- KP4/KP6 switch category, wraps around. Reset action index.
    if kp("kp_4") then
        dev_menu.cat = ((dev_menu.cat - 2) % #cats) + 1
        dev_menu.idx = 1
        dev_menu_render()
    elseif kp("kp_6") then
        dev_menu.cat = (dev_menu.cat % #cats) + 1
        dev_menu.idx = 1
        dev_menu_render()
    end

    -- Up/Down cycle action within category.
    if kp("down") then
        dev_menu.idx = (dev_menu.idx % #cat.actions) + 1
        dev_menu_render()
    elseif kp("up") then
        dev_menu.idx = ((dev_menu.idx - 2) % #cat.actions) + 1
        dev_menu_render()
    end

    if kp("return") or kp("kp_enter") then
        dev_menu_run_current()
    end
end

local function start_dev_menu_coro()
    local co = coroutine.create(function()
        while true do
            pcall(dev_menu_tick)
            Wait(1/30)
        end
    end)
    coroutine.resume(co)
end

-- ============ MENU INTEGRATION (Phase 2 lobby) ============
local _mp_integration_ok, _mp_integration_err = pcall(function()
    if not (menu and menu.GetPage and menu.AddPage and menu.SetPage) then
        logf("menu API missing — skipping MP menu integration")
        return
    end
    local mainmenu_page = menu.GetPage("mainmenu")
    if not mainmenu_page or not mainmenu_page.AddButton then
        logf("mainmenu page missing — skipping MP menu integration")
        return
    end
    logf("MP menu integration: starting")

    pcall(function() mainmenu_page:AddButton(21, 82, "- MP MOD -", "by OriginUnknowns", function() end) end)

    -- ------------------------------------------------------------------
    -- begin_game: triggered when game_started arrives (or when joining a
    -- room already in_game). Does the post-handshake work the old
    -- enter_mp did inline. Forward-declared above so message handlers
    -- can reach it.
    -- ------------------------------------------------------------------
    begin_game = function()
        if mp.in_game then return end
        mp.in_game = true
        mp.test_mode = false
        -- Restore normal ESC behavior — a previous Disconnect may have
        -- left it suppressed or in quits-mode.
        if _G.MP_NATIVE and _G.MP_NATIVE.set_suppress_esc then
            pcall(function() _G.MP_NATIVE.set_suppress_esc(false) end)
        end
        if _G.MP_NATIVE and _G.MP_NATIVE.set_esc_quits then
            pcall(function() _G.MP_NATIVE.set_esc_quits(false) end)
        end
        if _G.MP_NATIVE and _G.MP_NATIVE.set_esc_leaves_lobby then
            pcall(function() _G.MP_NATIVE.set_esc_leaves_lobby(false) end)
        end
        -- Just clear our own force flag. The Lua-side puppet / mob /
        -- item maps are reset by the level.Clear wrap that level.StartFrom
        -- below invokes internally — re-clearing them here would race
        -- with that and could leave the engine and our Lua state out
        -- of sync mid-frame.
        mp.force_kicked_page = false
        -- Death intercept (task #8): cleared at level start; per-frame
        -- HP polling in MP_FRAME_TICK drives the dead state.
        mp.is_dead = false
        mp.death_announced_at = nil
        mp.local_player_obj = nil  -- repopulated by death-intercept block on first tick
        mp.local_player_ptr = nil
        local seed = mp.session_seed or 1779843477
        logf("begin_game: seed=%s is_host=%s room='%s'",
            tostring(seed), tostring(mp.is_host), tostring(mp.room_name))
        math.randomseed(seed)
        local lok, lerr = pcall(function() level.StartFrom("level1", 0) end)
        if not lok then logf("begin_game: StartFrom CRASH: %s", tostring(lerr)) end
        pcall(function() menu.SetState("game", true) end)
        -- Pre-select the pause/ESC menu so it shows up if the user hits
        -- ESC mid-game. The engine remembers the most recently set page
        -- when bouncing in/out of game state.
        pcall(function() menu.SetPage("mp_pause") end)
        -- Lock down the LOCAL TPlayer pointer BEFORE any handle_join runs.
        -- After level.StartFrom, DAT_005747a4 is the local. handle_join's
        -- CreatePlayer swaps DAT_005747a4 to the puppet briefly; if Lua's
        -- player handle resolves .pointer dynamically from DAT_005747a4,
        -- obj.pointer at register_puppet time can be the LOCAL's address —
        -- which we'd then mis-pin to 9999, surfacing as the HUD HP bug.
        -- set_local_player captures the real local ptr now; the native
        -- register_puppet / is_passive_player gates refuse this address.
        if _G.MP_NATIVE and _G.MP_NATIVE.set_local_player then
            local pl_lock = player.GetPlayer()
            if pl_lock and pl_lock.pointer then
                pcall(function() _G.MP_NATIVE.set_local_player(pl_lock.pointer) end)
                mp.local_player_obj = pl_lock
                mp.local_player_ptr = pl_lock.pointer
            end
        end
        for _, p in ipairs(mp.pending_initial_players or {}) do
            if p.id ~= mp.my_id then handle_join(p) end
        end
        mp.pending_initial_players = nil
        pcall(refresh_objective_string)
        mp.pickup_scan_start_after = socket.gettime() + 2.5
        start_net_coro()      -- safe here — we're now in game state
        start_dev_menu_coro()
        start_joiner_cleanup_coro()
        if mp.is_host then
            local co = coroutine.create(function()
                pcall(function()
                    Wait(1.5)
                    host_send_item_list()
                    host_send_container_list()
                end)
            end)
            coroutine.resume(co)
        end
        -- Debug starter loadout: give every player a representative slice of
        -- weapons + ammo so we can exercise multi-bullet (pump), explode,
        -- cannon, nailgun, and energy paths without hunting for them.
        -- in_giveitem brackets the grant so the item Create wraps skip
        -- tracking (otherwise each grant queues a phantom item_spawned).
        do
            local co = coroutine.create(function()
                pcall(function()
                    Wait(0.5)
                    local pl = player.GetPlayer()
                    if not pl or not pl.GiveItem then return end
                    local prev = in_giveitem
                    in_giveitem = true
                    -- Loadout uses only bullettype.normal weapons, the
                    -- shape our hooks cover end-to-end. Cannon (own ctor),
                    -- agl (explode2), lasgun (laser), tesla (electro)
                    -- need extra subclass support — see KNOWN_ISSUES.md.
                    -- Ammo types from relvad.lua: pump→ppammo, rifle→riammo,
                    -- smg→pyammo, lasgun→battery (ammotype 5).
                    local STARTER = {
                        weapons = { "pump", "rifle", "smg", "lasgun" },
                        ammo    = { "ppammo", "riammo", "pyammo", "battery" },
                    }
                    for _, w in ipairs(STARTER.weapons) do
                        pcall(function() pl:GiveItem(w) end)
                    end
                    for _, a in ipairs(STARTER.ammo) do
                        for _ = 1, 3 do pcall(function() pl:GiveItem(a) end) end
                    end
                    in_giveitem = prev
                    logf("debug starter loadout granted")
                end)
            end)
            coroutine.resume(co)
        end
        logf("begin_game: DONE")
    end

    -- ------------------------------------------------------------------
    -- Lobby helpers. Phase 3 design:
    --
    -- Coroutine-based async is OUT at title-menu state — Wait() called
    -- inside an engine-untracked coroutine hard-crashes the host (the
    -- probe confirmed: "coro started" logs but resume never returns and
    -- the process dies). So everything here is synchronous.
    --
    -- Flow:
    --   Create Room → connect + create_room + read welcome → mp_waiting
    --     (host).
    --     Host clicks "Start Game" → send start_game + read game_started
    --     → begin_game.
    --   Join Open Room → connect + list_rooms + read room_list + send
    --     join_room + read welcome.
    --     If room is in_game → begin_game (late join).
    --     If lobby → mp_waiting (joiner) with a "Check Status" button
    --     the joiner clicks to drain the socket; when game_started
    --     arrives, begin_game.
    --
    -- Manual Check is klunky but reliable; the alternative (block-on
    -- sock:receive) freezes the menu indefinitely.
    -- ------------------------------------------------------------------

    -- Lobby-state handlers. Distinct from the global `handlers` table:
    -- those spawn entities (puppets, mobs) and would hard-crash at
    -- title-menu state where no level is loaded. The lobby variants
    -- only touch mp state used by the waiting-room UI.
    local lobby_handlers = {
        welcome      = function(m) handle_welcome(m) end,
        hello_ack    = function(m) end,
        room_list    = function(m)
            mp.lobby_rooms = m.rooms or {}
            mp.lobby_count   = m.lobby_count
            mp.in_game_count = m.in_game_count
            pcall(apply_lobby_stats_labels)
        end,
        room_created = function(m) end,
        room_updated = function(m) mp.last_room_update = m.room end,
        left_room    = function(m) end,
        join_failed  = function(m) handle_join_failed(m) end,
        host_changed = function(m)
            mp.host_id = m.host_id
            mp.is_host = (m.host_id == mp.my_id)
            logf("lobby host_changed: host_id=%s is_host=%s", tostring(m.host_id), tostring(mp.is_host))
            if apply_waiting_labels then pcall(apply_waiting_labels) end
        end,
        game_started = function(m)
            if m.seed then mp.session_seed = m.seed end
            mp.game_started_pending = true
            logf("lobby game_started: seed=%s (flagged)", tostring(m.seed))
        end,
        join = function(m)
            mp.room_players = mp.room_players or {}
            for _, p in ipairs(mp.room_players) do
                if p.id == m.id then p.name = m.name; return end
            end
            table.insert(mp.room_players, { id = m.id, name = m.name })
            logf("lobby join: id=%s name='%s'", tostring(m.id), tostring(m.name))
            if apply_waiting_labels then pcall(apply_waiting_labels) end
        end,
        leave = function(m)
            if mp.room_players then
                for i, p in ipairs(mp.room_players) do
                    if p.id == m.id then table.remove(mp.room_players, i); break end
                end
            end
            -- Also mirror to mp.puppets so the in-game pause UI
            -- (which reads mp.puppets via apply_pause_labels) sees
            -- the player drop off without waiting for the net
            -- coroutine to resume.
            if mp.puppets and mp.puppets[m.id] then
                pcall(function() safe_delete(mp.puppets[m.id].obj) end)
                if mp.puppets[m.id].nameplate then
                    pcall(function() mp.puppets[m.id].nameplate:Delete() end)
                end
                mp.puppets[m.id] = nil
            end
            logf("lobby leave: id=%s", tostring(m.id))
            if apply_waiting_labels then pcall(apply_waiting_labels) end
        end,
        kicked = function(m) handle_kicked(m) end,
    }

    -- Pull frames from mp.sock at title-menu state. Lobby-known messages
    -- dispatch through lobby_handlers; anything else is queued for the
    -- normal net coroutine (started by begin_game) to replay once we're
    -- actually in the game.
    --
    -- Fully non-blocking + hard cap of 16 messages per call. We're invoked
    -- from a Win32 PeekMessageA hook on the engine's main thread — any
    -- sock:receive that blocks freezes the entire game. The cap also
    -- guarantees the tick can never starve other Windows messages.
    local function drain_sock_sync()
        if not mp.sock then return 0 end
        mp.handshake_queued = mp.handshake_queued or {}
        local drained = 0
        for _ = 1, 16 do
            mp.sock:settimeout(0)
            local len_bytes = mp.sock:receive(4)
            if not len_bytes then break end
            local body_len = unpack_u32_be(len_bytes)
            -- Header arrived → body is virtually certain to be right after
            -- (TCP segments are typically together). Use a tiny timeout so
            -- we don't spin if the body trails the header by microseconds.
            mp.sock:settimeout(0.05)
            local body = mp.sock:receive(body_len)
            mp.sock:settimeout(0)
            if not body then break end
            local ok, msg = pcall(json.decode, body)
            if ok and msg then
                drained = drained + 1
                local lh = lobby_handlers[msg.type]
                if lh then
                    pcall(lh, msg)
                else
                    table.insert(mp.handshake_queued, msg)
                end
            end
        end
        return drained
    end

    local function arm_esc_leaves_lobby()
        if _G.MP_NATIVE and _G.MP_NATIVE.set_esc_leaves_lobby then
            pcall(function() _G.MP_NATIVE.set_esc_leaves_lobby(true) end)
        end
    end
    local function disarm_esc_leaves_lobby()
        if _G.MP_NATIVE and _G.MP_NATIVE.set_esc_leaves_lobby then
            pcall(function() _G.MP_NATIVE.set_esc_leaves_lobby(false) end)
        end
    end

    local function lobby_create_room_flow()
        logf("lobby: Create flow")
        -- Open the socket and finish hello/hello_ack synchronously so
        -- mp.sock is live and ready for room ops without any coroutine.
        local sock = socket.tcp()
        sock:settimeout(5)
        local cok, cerr = sock:connect(config.host, config.port)
        if not cok then logf("Create: connect failed: %s", tostring(cerr)); return end
        pcall(function() sock:setoption("tcp-nodelay", true) end)
        local ack = _recv_frame(sock)
        if not ack or ack.type ~= "hello_ack" then sock:close(); logf("Create: no hello_ack"); return end
        mp.my_id = ack.client_id
        _send_frame(sock, { type = "hello", name = config.name })
        -- Create the room and wait for welcome.
        local room_name = (config.name or "Player") .. "'s Game"
        _send_frame(sock, { type = "create_room", name = room_name, seed = 1779843477 })
        local queued = {}
        local rc = _recv_until(sock, "room_created", 5, queued)
        if not rc then sock:close(); logf("Create: no room_created"); return end
        local welcome = _recv_until(sock, "welcome", 5, queued)
        if not welcome then sock:close(); logf("Create: no welcome"); return end
        _apply_welcome(welcome)
        sock:settimeout(0)
        mp.sock = sock
        mp.rx_buf = ""
        mp.handshake_queued = queued
        logf("Create: in lobby — room_id=%d, navigating to mp_waiting", welcome.room_id)
        arm_esc_leaves_lobby()
        menu.SetPage("mp_waiting")
    end

    -- Open a fresh socket and run the hello handshake. Returns the live
    -- non-blocking socket on success (or nil + err). Shared by the lobby
    -- "list rooms" probe and the actual create/join flows.
    local function lobby_handshake_socket()
        local sock = socket.tcp()
        sock:settimeout(5)
        local cok, cerr = sock:connect(config.host, config.port)
        if not cok then return nil, "connect: " .. tostring(cerr) end
        pcall(function() sock:setoption("tcp-nodelay", true) end)
        local ack = _recv_frame(sock)
        if not ack or ack.type ~= "hello_ack" then sock:close(); return nil, "no hello_ack" end
        mp.my_id = ack.client_id
        _send_frame(sock, { type = "hello", name = config.name })
        return sock
    end

    -- Refresh the room list. Connects to relay, asks, logs results,
    -- closes. Repopulates mp.lobby_rooms (kept across clicks). Called
    -- when the user clicks "Refresh List" or whenever a slot button
    -- is clicked (so the slot resolves a fresh room id).
    -- Build a compact 15-char-max label for one slot. Slot label fits the
    -- C++ button's std::string SSO buffer (max 15 chars). Format:
    --   "1:Kito 1/4"  (room index, short host name, count/max)
    --   "(empty)"     (no room at that slot)
    local function format_slot_label(idx, room)
        if not room then return "(empty)" end
        local host = tostring(room.host_name or "?"):sub(1, 6)
        local cnt  = tonumber(room.count) or 0
        local mx   = tonumber(room.max)   or 4
        return string.format("%d:%s %d/%d", idx, host, cnt, mx)
    end

    local function total_pages()
        local n = (mp.lobby_rooms and #mp.lobby_rooms) or 0
        if n == 0 then return 1 end
        return math.ceil(n / 4)
    end

    local function apply_slot_labels()
        if not (mp.lobby_slot_btns and _G.MP_NATIVE and _G.MP_NATIVE.set_button_label) then return end
        mp.lobby_page = mp.lobby_page or 1
        -- Clamp page to current room count (rooms may have closed since
        -- last paint; never strand the user on an empty page).
        local tp = total_pages()
        if mp.lobby_page > tp then mp.lobby_page = tp end
        if mp.lobby_page < 1 then mp.lobby_page = 1 end
        local offset = (mp.lobby_page - 1) * 4
        for i = 1, 4 do
            local btn = mp.lobby_slot_btns[i]
            local room = mp.lobby_rooms and mp.lobby_rooms[offset + i]
            if btn and btn.pointer then
                local label = format_slot_label(i, room)
                pcall(function() _G.MP_NATIVE.set_button_label(btn.pointer, label) end)
            end
        end
        if mp.lobby_page_btn and mp.lobby_page_btn.pointer then
            local label = string.format("Page %d/%d", mp.lobby_page, tp)
            pcall(function() _G.MP_NATIVE.set_button_label(mp.lobby_page_btn.pointer, label) end)
        end
    end

    local function lobby_refresh_rooms()
        local sock, err = lobby_handshake_socket()
        if not sock then logf("==== LOBBY ROOMS ==== refresh failed: %s", tostring(err)); return end
        _send_frame(sock, { type = "list_rooms" })
        local rl = _recv_until(sock, "room_list", 5, nil)
        sock:close()
        if not rl then logf("==== LOBBY ROOMS ==== no room_list reply"); return end
        mp.lobby_rooms = rl.rooms or {}
        mp.lobby_count = rl.lobby_count
        mp.in_game_count = rl.in_game_count
        pcall(apply_lobby_stats_labels)
        logf("==== LOBBY ROOMS (%d) ====", #mp.lobby_rooms)
        for i = 1, 4 do
            local r = mp.lobby_rooms[i]
            if r then
                logf("  Slot %d │ %s │ host: %s │ %d/%d players │ %s",
                    i, tostring(r.name), tostring(r.host_name),
                    tonumber(r.count) or 0, tonumber(r.max) or 4,
                    tostring(r.status))
            else
                logf("  Slot %d │ (empty)", i)
            end
        end
        if #mp.lobby_rooms > 4 then
            logf("  (%d more rooms not shown — only first 4 fit in slots)", #mp.lobby_rooms - 4)
        end
        apply_slot_labels()
    end

    -- Join a specific room by 1-based slot index on the current page.
    -- Re-fetches the list first so a slot click is always against fresh
    -- data (handles the case where a room closed since last paint).
    local function lobby_join_slot(idx)
        lobby_refresh_rooms()
        local page   = mp.lobby_page or 1
        local offset = (page - 1) * 4
        local target = mp.lobby_rooms and mp.lobby_rooms[offset + idx]
        if not target then
            logf("Join Slot %d (page %d): no room at that slot", idx, page)
            return
        end
        logf("Join Slot %d: room_id=%d name='%s' status=%s",
            idx, target.room_id, tostring(target.name), tostring(target.status))
        local sock, err = lobby_handshake_socket()
        if not sock then logf("Join Slot %d: %s", idx, tostring(err)); return end
        _send_frame(sock, { type = "join_room", room_id = target.room_id })
        local queued = {}
        local welcome = _recv_until(sock, "welcome", 5, queued)
        if not welcome then sock:close(); logf("Join Slot %d: no welcome", idx); return end
        _apply_welcome(welcome)
        sock:settimeout(0)
        mp.sock = sock
        mp.rx_buf = ""
        mp.handshake_queued = queued
        if welcome.status == "in_game" then
            logf("Join Slot %d: room already in_game — entering directly", idx)
            if begin_game then begin_game() end
        else
            logf("Join Slot %d: room in lobby — navigating to mp_waiting", idx)
            arm_esc_leaves_lobby()
            menu.SetPage("mp_waiting")
        end
    end

    -- Legacy "Join first" (kept for ergonomics). Just an alias for slot 1
    -- after a refresh.
    local function lobby_join_flow()
        lobby_join_slot(1)
    end

    local function lobby_start_game()
        if not mp.sock then logf("Start: no socket"); return end
        if not mp.is_host then logf("Start: not host, ignoring"); return end
        send_msg({ type = "start_game" })
        -- Host doesn't wait for the relay's broadcast echo. mp.session_seed
        -- was already set in welcome (= room.seed), and the relay broadcasts
        -- game_started to joiners. The previous 50-iter drain loop had no
        -- sleep between iterations so it completed in microseconds — well
        -- before TCP could roundtrip the echo. Just begin locally now.
        mp.game_started_pending = true
        logf("Start: sent start_game, beginning game locally (seed=%s)",
             tostring(mp.session_seed))
        if begin_game then begin_game() end
    end

    local function lobby_refresh_status()
        if not mp.sock then logf("Refresh: no socket"); return end
        mp.game_started_pending = false
        local n = drain_sock_sync()
        -- Re-label the waiting room (player slots + start button) from the
        -- mp state that drain_sock_sync's handlers just updated.
        if apply_waiting_labels then pcall(apply_waiting_labels) end
        -- Log the roster for visibility (slot buttons show first 15 chars).
        local roster = {}
        if mp.my_id then
            table.insert(roster, (config.name or "?")
                .. (mp.is_host and " (host,me)" or " (me)"))
        end
        for _, p in ipairs(mp.room_players or {}) do
            if p.id ~= mp.my_id then
                table.insert(roster, tostring(p.name or "?")
                    .. (p.id == mp.host_id and " (host)" or ""))
            end
        end
        logf("Refresh: room='%s' players=%d  ── roster: %s  ── drained=%d  game_started=%s",
            tostring(mp.room_name), #roster, table.concat(roster, ", "),
            n, tostring(mp.game_started_pending))
        if mp.game_started_pending and begin_game then begin_game() end
    end

    local function lobby_leave_room()
        logf("lobby_leave_room: entry — was_host=%s, in_game=%s, mp.sock=%s",
            tostring(mp.is_host), tostring(mp.in_game), tostring(mp.sock ~= nil))
        if mp.sock then
            pcall(function() send_msg({ type = "leave_room" }) end)
            pcall(function() mp.sock:close() end)
            mp.sock = nil
            mp.rx_buf = ""
        end
        -- Clean up engine-side state so the next room isn't polluted by
        -- stale handles. Same shape as pending_kick_cleanup (the only
        -- other path that resets the full set correctly).
        for _, entry in pairs(mp.puppets or {}) do
            if entry.obj then pcall(function() safe_delete(entry.obj) end) end
            if entry.nameplate then pcall(function() entry.nameplate:Delete() end) end
        end
        mp.puppets = {}
        mp.peer_lasers = {}     -- new state from laser on/off protocol
        mp.is_host = false
        mp.in_game = false      -- critical: stale in_game blocks future begin_game
        mp.game_started_pending = false  -- critical: stale flag premature-triggers begin_game
        mp.is_dead = false
        mp.death_announced_at = nil
        mp.local_player_obj = nil
        mp.local_player_ptr = nil
        mp.room_players = {}
        mp.room_id = nil
        mp.host_id = nil
        mp.session_seed = nil
        mp.pending_initial_players = nil
        mp.handshake_queued = nil
        mp.last_laser_t = nil
        mp.laser_was_held = false
        disarm_esc_leaves_lobby()
        menu.SetPage("mp_lobby")
    end

    -- ------------------------------------------------------------------
    -- Lobby page. Phase 2: only Create / Join First / Back. No waiting
    -- room — host auto-starts, joiner late-joins straight into the
    -- running game.
    -- ------------------------------------------------------------------
    -- ------------------------------------------------------------------
    -- mp_lobby = entry page. Just two actions + Back. Clean.
    -- ------------------------------------------------------------------
    local mp_lobby_page
    local pok1, perr1 = pcall(function()
        mp_lobby_page = menu.AddPage("mp_lobby", "mainmenu")
        if not mp_lobby_page then error("AddPage('mp_lobby') returned nil") end
        pcall(function() mp_lobby_page:AddBackground("gfx/menubg.bmp") end)

        -- Stats line at the top, auto-updated by handle_room_list as the
        -- server's auto-pushed room_list (or any explicit list_rooms reply)
        -- comes in. Two side-by-side info buttons (each fits the 15-char
        -- SSO label budget). Empty tooltips so nothing pops on hover.
        local stats_lobby = mp_lobby_page:AddButton(40,  84, "Lobby: 0",  "", function() end)
        local stats_active = mp_lobby_page:AddButton(140, 84, "Active: 0", "", function() end)
        mp.lobby_stats_lobby_btn  = stats_lobby
        mp.lobby_stats_active_btn = stats_active

        local create_btn = mp_lobby_page:AddButton(60, 110, "Create Room",
            "Host a new multiplayer game (up to 4 players)",
            function()
                local cok, cerr = pcall(lobby_create_room_flow)
                if not cok then logf("Create Room crash: %s", tostring(cerr)) end
            end)
        local browse_btn = mp_lobby_page:AddButton(60, 132, "Browse Rooms",
            "See open rooms and join one",
            function()
                pcall(lobby_refresh_rooms)   -- pre-populate before page render
                menu.SetPage("mp_browse")
            end)
        pcall(function()
            local back = mp_lobby_page:GetButton("BACK")
            create_btn:SetNext("down", browse_btn); browse_btn:SetNext("up", create_btn)
            if back then
                browse_btn:SetNext("down", back); back:SetNext("up", browse_btn)
            end
        end)
    end)
    logf("MP page mp_lobby: ok=%s err=%s", tostring(pok1), tostring(perr1))

    -- ------------------------------------------------------------------
    -- mp_browse = room slot picker. 4 slot buttons + page prev/next + Back.
    -- Slot labels ARE dynamic — apply_slot_labels writes via the native
    -- set_button_label (which pokes the C++ button's std::string SSO buffer
    -- directly, 15-char max — see format_slot_label). Refresh is triggered
    -- inside lobby_join_slot before resolving the click so a stale slot
    -- click never joins the wrong room.
    -- ------------------------------------------------------------------
    local mp_browse_page
    local pok1b, perr1b = pcall(function()
        mp_browse_page = menu.AddPage("mp_browse", "mp_lobby")
        if not mp_browse_page then error("AddPage('mp_browse') returned nil") end
        pcall(function() mp_browse_page:AddBackground("gfx/menubg.bmp") end)

        -- Top: page indicator (read-only — clicking refreshes manually
        -- which is essentially free with the existing list connection).
        local page_btn = mp_browse_page:AddButton(60, 88, "Page 1/1",
            "Current page of the room list (auto-updates on navigation)",
            function() pcall(lobby_refresh_rooms) end)
        mp.lobby_page_btn = page_btn

        local prev_btn = mp_browse_page:AddButton(60, 108, "< Prev Page",
            "Previous page of rooms",
            function()
                mp.lobby_page = math.max(1, (mp.lobby_page or 1) - 1)
                pcall(lobby_refresh_rooms)
            end)

        local slot_btns = {}
        for i = 1, 4 do
            slot_btns[i] = mp_browse_page:AddButton(60, 128 + (i-1)*14,
                "(empty)",
                "Join the room shown in this slot",
                function()
                    local sok, serr = pcall(function() lobby_join_slot(i) end)
                    if not sok then logf("Join Slot %d crash: %s", i, tostring(serr)) end
                end)
        end
        mp.lobby_slot_btns = slot_btns

        local next_btn = mp_browse_page:AddButton(60, 188, "Next Page >",
            "Next page of rooms",
            function()
                local tp = 1
                local n = (mp.lobby_rooms and #mp.lobby_rooms) or 0
                if n > 0 then tp = math.ceil(n / 4) end
                mp.lobby_page = math.min(tp, (mp.lobby_page or 1) + 1)
                pcall(lobby_refresh_rooms)
            end)

        pcall(function()
            local back = mp_browse_page:GetButton("BACK")
            page_btn:SetNext("down", prev_btn);  prev_btn:SetNext("up", page_btn)
            prev_btn:SetNext("down", slot_btns[1]); slot_btns[1]:SetNext("up", prev_btn)
            for i = 1, 3 do
                slot_btns[i]:SetNext("down", slot_btns[i+1])
                slot_btns[i+1]:SetNext("up", slot_btns[i])
            end
            slot_btns[4]:SetNext("down", next_btn); next_btn:SetNext("up", slot_btns[4])
            if back then
                next_btn:SetNext("down", back); back:SetNext("up", next_btn)
            end
        end)
    end)
    logf("MP page mp_browse: ok=%s err=%s", tostring(pok1b), tostring(perr1b))

    -- ------------------------------------------------------------------
    -- Waiting room page. Reached after Create (host) or Join into a
    -- lobby-status room (joiner). Buttons differ by role but page is
    -- shared. Joiner uses "Refresh" to manually drain the socket since
    -- we can't run a coroutine here.
    -- ------------------------------------------------------------------
    local mp_waiting_page
    local pok2, perr2 = pcall(function()
        mp_waiting_page = menu.AddPage("mp_waiting", "mp_lobby")
        if not mp_waiting_page then error("AddPage('mp_waiting') returned nil") end
        pcall(function() mp_waiting_page:AddBackground("gfx/menubg.bmp") end)

        -- 4 player-slot buttons (info display via native label setter).
        -- They're real buttons because the menu API has no static-text
        -- runtime-update path; we relabel them on every state change.
        --
        -- Clicking any player slot ALSO drains the socket + updates the
        -- roster — same "ambient refresh" as the action buttons, so the
        -- player can poke any button to refresh.
        local player_btns = {}
        for i = 1, 4 do
            player_btns[i] = mp_waiting_page:AddButton(60, 80 + (i-1)*14,
                "(empty)",
                "Player slot (click any waiting-room button to refresh)",
                function()
                    if mp.sock then drain_sock_sync() end
                    if apply_waiting_labels then pcall(apply_waiting_labels) end
                end)
        end
        mp.lobby_player_btns = player_btns

        -- Ambient-refresh wrappers: every action button on this page does
        -- a drain + apply BEFORE its action, so the player never has to
        -- click "Refresh" explicitly. Pure polling — Wait()-based
        -- coroutines crash the host at title-menu state, so there's no
        -- automatic background poll yet.
        local function auto_refresh()
            if mp.sock then drain_sock_sync() end
            if apply_waiting_labels then pcall(apply_waiting_labels) end
        end

        local start_btn = mp_waiting_page:AddButton(21, 154, "Start Game",
            "Host only: begin the level for everyone in this room",
            function() auto_refresh(); pcall(lobby_start_game) end)
        mp.lobby_start_btn = start_btn
        local leave_btn = mp_waiting_page:AddButton(21, 176, "Leave Room",
            "Disconnect and return to the lobby",
            function() auto_refresh(); pcall(lobby_leave_room) end)
        pcall(function()
            local back = mp_waiting_page:GetButton("BACK")
            start_btn:SetNext("down", leave_btn);  leave_btn:SetNext("up", start_btn)
            if back then
                leave_btn:SetNext("down", back);   back:SetNext("up", leave_btn)
            end
        end)
    end)
    logf("MP page mp_waiting: ok=%s err=%s", tostring(pok2), tostring(perr2))

    -- Background auto-refresh: hook user32!PeekMessageA per frame and
    -- call _G.MP_FRAME_TICK at ~10Hz. Engine-tracked coroutines (Wait)
    -- crash at title-menu state, but a Win32-API hook fires every frame
    -- regardless. Tick body just drains the socket + relabels.
    -- Debug heartbeat: log every 30th tick (~3s at 10Hz) so we can confirm
    -- frame_tick is firing on each instance. Remove once thread-gate
    -- regression is sorted.
    mp._frame_tick_dbg_count = mp._frame_tick_dbg_count or 0
    -- ==========================================================
    -- MP_INTERP_TICK — disabled. The interp architecture (buffer
    -- snapshots, lerp at render time) needs more work; the previous
    -- implementation fired once per session then stopped, leaving
    -- puppets at SAFE_SPAWN. Keep this as a no-op stub so the native
    -- hook's getglobal succeeds without errors.
    -- ==========================================================
    _G.MP_INTERP_TICK = function() end
    -- Old interp body kept below for reference (currently dead code via
    -- the early `return` above). Will be revived when re-architected.
    local INTERP_DELAY = 0.15
    local _UNUSED_INTERP_TICK = function()
        -- DIAG: log once per ~3s what state we're in (BEFORE any guard)
        mp._interp_dbg_n = (mp._interp_dbg_n or 0) + 1
        if (mp._interp_dbg_n % 100) == 1 then
            local n_pup, n_tp, n_buf = 0, 0, 0
            for _, e in pairs(mp.puppets or {}) do
                if type(e) == "table" then
                    n_pup = n_pup + 1
                    if e.is_tplayer then n_tp = n_tp + 1 end
                    if e.snap_buf then n_buf = n_buf + #e.snap_buf end
                end
            end
            logf("INTERP n=%d in_game=%s puppets=%d tplayers=%d total_snaps=%d",
                 mp._interp_dbg_n, tostring(mp.in_game), n_pup, n_tp, n_buf)
        end
        if not mp.in_game then return end
        local now_t = (socket and socket.gettime) and socket.gettime() or 0
        local render_t = now_t - INTERP_DELAY
        for _, entry in pairs(mp.puppets or {}) do
            if type(entry) == "table"
               and entry.is_tplayer and not entry.is_dead
               and entry.obj and entry.obj.pointer
               and entry.snap_buf and #entry.snap_buf >= 1 then
                local buf = entry.snap_buf
                local x, y, ang, vx, vy
                if #buf == 1 then
                    -- Only one snapshot so far — snap to it. No interp data
                    -- yet, but better than leaving the puppet at SAFE_SPAWN.
                    local s = buf[1]
                    x, y, ang, vx, vy = s.x, s.y, s.angle, 0, 0
                else
                    -- Find pair (a,b) bracketing render_t: a.t <= render_t <= b.t
                    local a, b
                    for i = 1, #buf - 1 do
                        if buf[i].t <= render_t and buf[i+1].t >= render_t then
                            a, b = buf[i], buf[i+1]
                            break
                        end
                    end
                    if a and b then
                        local span = b.t - a.t
                        local alpha = (span > 0.0001) and ((render_t - a.t) / span) or 1
                        if alpha < 0 then alpha = 0 elseif alpha > 1 then alpha = 1 end
                        x   = a.x + (b.x - a.x) * alpha
                        y   = a.y + (b.y - a.y) * alpha
                        ang = a.angle + (b.angle - a.angle) * alpha
                        if span > 0.0001 then
                            vx = (b.x - a.x) / span
                            vy = (b.y - a.y) / span
                        else
                            vx, vy = 0, 0
                        end
                    else
                        -- render_t outside the buffered range: hold the
                        -- latest position. Skip extrapolation to avoid
                        -- prediction overshoot when snapshots arrive late.
                        local last = buf[#buf]
                        x, y, ang, vx, vy = last.x, last.y, last.angle, 0, 0
                    end
                end
                pcall(function() entry.obj:SetPosition(x, y) end)
                if _G.MP_NATIVE and _G.MP_NATIVE.set_body_velocity then
                    pcall(function()
                        _G.MP_NATIVE.set_body_velocity(entry.obj.pointer, vx, vy)
                    end)
                end
                -- NOTE: angle pin still fires from handle_snapshot at
                -- snapshot rate. Visual angle jitter is lower-impact than
                -- position jitter; revisit if needed.
            end
        end
    end

    _G.MP_FRAME_TICK = function()
        mp._frame_tick_dbg_count = (mp._frame_tick_dbg_count or 0) + 1
        if (mp._frame_tick_dbg_count % 30) == 1 then
            local hp_val = "?"
            -- Only probe HP when in-game; at menu pl exists but has no
            -- backing TPlayer, so calling :GetHealth nullderefs the engine.
            if mp.in_game then
                local pl_for_hp = player.GetPlayer()
                if pl_for_hp and pl_for_hp.GetHealth then
                    pcall(function() hp_val = tostring(pl_for_hp:GetHealth()) end)
                end
            end
            logf("frame_tick HB n=%d in_game=%s sock=%s pending=%s is_dead=%s hp=%s",
                 mp._frame_tick_dbg_count,
                 tostring(mp.in_game), tostring(mp.sock ~= nil),
                 tostring(mp.game_started_pending), tostring(mp.is_dead), hp_val)
        end
        -- ESC pressed in the lobby waiting room → leave the room.
        -- (Native hook latches the keypress + swallows the event; we
        -- run the action here in safe Lua context.)
        if _G.MP_NATIVE and _G.MP_NATIVE.check_esc_pressed then
            local was = false
            pcall(function() was = _G.MP_NATIVE.check_esc_pressed() end)
            if was then
                logf("ESC in waiting room — calling lobby_leave_room")
                pcall(lobby_leave_room)
            end
        end

        -- Death intercept also called here for the menu/lobby case, but
        -- the real driver is net_tick_loop because the engine bypasses
        -- our resume/pcallk hooks in-game (MP_FRAME_TICK doesn't fire).
        pcall(tick_death_intercept)
        if false and mp.in_game and _G.MP_NATIVE and _G.MP_NATIVE.pin_hp then
            -- Cache the LOCAL player handle on first tick after begin_game.
            -- Polling via player.GetPlayer() each frame is unsafe once puppets
            -- exist: the engine's GetPlayer / GetHealth can resolve to a puppet
            -- pinned to 9999, so the threshold check never trips and the real
            -- local dies through the engine death branch. The cached handle
            -- (taken before any CreatePlayer puppet exists) gives us a stable
            -- pointer to read +0xBC from directly via MP_NATIVE.read_hp.
            if not mp.local_player_obj then
                local pl0 = player.GetPlayer()
                if pl0 and pl0.pointer then
                    mp.local_player_obj = pl0
                    mp.local_player_ptr = pl0.pointer
                    logf("DEATH intercept: cached local player ptr=%s",
                        tostring(_G.MP_NATIVE.addr_of and _G.MP_NATIVE.addr_of(pl0.pointer)))
                end
            end
            local pl = mp.local_player_obj
            if pl and pl.pointer then
                -- Allow external triggers (dev menu Kill Self, future
                -- host-confirmed death) to flip mp.is_dead directly. If
                -- it's set but we haven't pinned yet, pin now + announce.
                if mp.is_dead and not mp.death_announced_at then
                    mp.death_announced_at = (socket and socket.gettime) and socket.gettime() or 0
                    logf("DEATH externally triggered → pin + announce")
                    pcall(function() _G.MP_NATIVE.pin_hp(mp.local_player_ptr or pl.pointer, true) end)  -- 2nd arg = allow main player (death intercept)
                    pcall(function()
                        if _G.MP_NATIVE.set_invulnerable then
                            _G.MP_NATIVE.set_invulnerable(pl.pointer, true)
                        end
                    end)
                    pcall(refresh_objective_string)
                    if mp.sock then
                        pcall(function() send_msg({ type = "player_died" }) end)
                    end
                end
                if mp.is_dead then
                    -- Keep pinning so any incoming damage can't tip HP <= 0.
                    pcall(function() _G.MP_NATIVE.pin_hp(mp.local_player_ptr or pl.pointer, true) end)  -- 2nd arg = allow main player (death intercept)
                    -- Spectate: each frame, teleport our corpse onto the
                    -- nearest LIVING teammate. last_x/last_y are the most
                    -- recent host-broadcast positions from handle_snapshot.
                    -- We pick by current distance from us, then SetPosition.
                    -- Skip puppets with is_dead set (server-forwarded
                    -- peer_died) so we don't anchor to another corpse.
                    local target, target_d2 = nil, math.huge
                    local mx, my = 0, 0
                    pcall(function() mx, my = pl:GetPosition() end)
                    for _, entry in pairs(mp.puppets or {}) do
                        if type(entry) == "table" and not entry.is_dead
                           and entry.last_x and entry.last_y then
                            local dx = entry.last_x - mx
                            local dy = entry.last_y - my
                            local d2 = dx*dx + dy*dy
                            if d2 < target_d2 then
                                target, target_d2 = entry, d2
                            end
                        end
                    end
                    if target and pl.SetPosition then
                        pcall(function() pl:SetPosition(target.last_x, target.last_y) end)
                    end
                else
                    local hp = nil
                    -- Read +0xBC directly from the cached local pointer.
                    -- pl:GetHealth() goes through engine state that puppets
                    -- pollute (returned 9999 from a puppet instead of the
                    -- real local HP), making the threshold check miss.
                    if _G.MP_NATIVE.read_hp then
                        pcall(function() hp = _G.MP_NATIVE.read_hp(mp.local_player_ptr or pl.pointer) end)
                    else
                        pcall(function() if pl.GetHealth then hp = pl:GetHealth() end end)
                    end
                    -- Per-tick log: any change in HP gets recorded.
                    -- Logs are throttled by VALUE change to avoid spam.
                    mp._last_logged_hp = mp._last_logged_hp or -1
                    if hp ~= mp._last_logged_hp then
                        local lp_addr = _G.MP_NATIVE.addr_of and _G.MP_NATIVE.addr_of(mp.local_player_ptr) or "?"
                        local mainp = _G.MP_NATIVE.get_main_player and _G.MP_NATIVE.get_main_player() or "?"
                        logf("DEATH poll: cached_ptr=%s main_p=%s hp=%s",
                            tostring(lp_addr), tostring(mainp), tostring(hp))
                        mp._last_logged_hp = hp
                    end
                    -- Threshold of 5: gives a frame of slack before the
                    -- engine's <=0 death check fires.
                    if type(hp) == "number" and hp > 0 and hp <= 5 then
                        logf("DEATH intercept: hp=%s → pinning + entering spectate", tostring(hp))
                        mp.is_dead = true
                        mp.death_announced_at = (socket and socket.gettime) and socket.gettime() or 0
                        pcall(function() _G.MP_NATIVE.pin_hp(mp.local_player_ptr or pl.pointer, true) end)  -- 2nd arg = allow main player (death intercept)
                        pcall(function()
                            if _G.MP_NATIVE.set_invulnerable then
                                _G.MP_NATIVE.set_invulnerable(pl.pointer, true)
                            end
                        end)
                        -- Refresh the on-screen banner immediately so the
                        -- player sees the dead state without waiting for
                        -- the next objective-string refresh tick.
                        pcall(refresh_objective_string)
                        -- Tell the server (other clients can mark us dead
                        -- in their rosters once the server forwards it).
                        if mp.sock then
                            pcall(function() send_msg({ type = "player_died" }) end)
                        end
                    end
                end
            end
        end
        -- ============ END DEATH INTERCEPT ============

        -- Deferred kick / disconnect cleanup. CRUCIAL: do NOT call
        -- menu.SetState("game", false) — that boolean is "needs fresh
        -- init" not "exit game", so it actually pulls the user BACK
        -- into the level (this is what Continue uses). We just swap
        -- the current page and let whichever state the user is in
        -- handle the rest:
        --   * Kicked while playing → page set to mp_kicked; user keeps
        --     playing until they press ESC, then sees the notice.
        --     Objective-string banner makes the kick visible in-world.
        --   * Disconnect from pause → user is already in menu state,
        --     so SetPage swap is immediately visible as mainmenu.
        if mp.pending_kick_cleanup then
            mp.pending_kick_cleanup = false
            mp.room_id = nil
            mp.is_host = false
            mp.in_game = false
            mp.is_dead = false
            mp.death_announced_at = nil
            mp.local_player_obj = nil
            mp.local_player_ptr = nil
            mp.room_players = {}
            mp.game_started_pending = false
            -- Same cross-session cleanup as Disconnect: destroy engine
            -- entities first, then drop the Lua bookkeeping so the
            -- next join is clean.
            for _, entry in pairs(mp.puppets or {}) do
                if type(entry) == "table" then
                    if entry.obj then pcall(function() safe_delete(entry.obj) end) end
                    if entry.nameplate then
                        pcall(function() entry.nameplate:Delete() end)
                    end
                end
            end
            for _, entry in pairs(mp.mob_puppets or {}) do
                if type(entry) == "table" and entry.obj then
                    pcall(function() safe_delete(entry.obj) end)
                end
            end
            for _, entry in pairs(mp.items or {}) do
                if type(entry) == "table" and entry.obj then
                    pcall(function() safe_delete(entry.obj) end)
                end
            end
            mp.puppets = {}
            mp.mob_puppets = {}
            mp.host_mobs = {}
            mp.items = {}
            mp.item_obj_to_id = {}
            mp.next_mob_id = 1
            mp.next_item_id = 1
            mp.pending_initial_players = nil
            mp.pending_item_list = nil
            mp.force_kicked_page = true
            mp._pause_bypass = true
            pcall(function() menu.SetPage("mp_kicked") end)
            mp._pause_bypass = false
            if _G.MP_NATIVE and _G.MP_NATIVE.set_suppress_esc then
                pcall(function() _G.MP_NATIVE.set_suppress_esc(true) end)
            end
            -- On mp_kicked, ESC quits Teleglitch (same as clicking OK).
            if _G.MP_NATIVE and _G.MP_NATIVE.set_esc_quits then
                pcall(function() _G.MP_NATIVE.set_esc_quits(true) end)
            end
            if _G.MP_NATIVE and _G.MP_NATIVE.inject_esc then
                pcall(function() _G.MP_NATIVE.inject_esc() end)
            end
            return
        end

        -- The engine's native ESC handler resets the active page to
        -- mainmenu when it pauses. After a kick we just injected ESC
        -- and set the page to mp_kicked — the engine then overwrote
        -- it. Re-force mp_kicked here every ~500ms until the user
        -- clicks OK (which clears the flag).
        if mp.force_kicked_page then
            local now = (socket and socket.gettime) and socket.gettime() or os.time()
            if (now - (mp._last_kicked_force or 0)) >= 0.5 then
                mp._pause_bypass = true
                pcall(function() menu.SetPage("mp_kicked") end)
                mp._pause_bypass = false
                mp._last_kicked_force = now
            end
        end
        -- (pending_to_mainmenu used to be processed here; Disconnect is
        -- now handled inline from the button callback so the SetPage
        -- swap actually sticks while the engine is still in menu state.)

        -- Force mp_pause as the active page while in MP, but throttle
        -- to ~750ms — fast enough that ESC swaps to mp_pause within
        -- one beat, slow enough that the engine's button-click
        -- dispatch can complete between forces without being clobbered.
        if mp.in_game and not mp._pause_bypass then
            local now = (socket and socket.gettime) and socket.gettime() or os.time()
            if (now - (mp._last_pause_force or 0)) >= 0.75 then
                pcall(function() menu.SetPage("mp_pause") end)
                mp._last_pause_force = now
            end
        end

        -- Drain the socket here as well so events arriving WHILE the
        -- game is paused (the net coroutine is yielded in Wait and
        -- therefore not processing messages) still get dispatched.
        -- This is what makes the host see a kicked joiner disappear
        -- from the pause-page roster without having to resume first.
        if mp.sock then pcall(drain_sock_sync) end
        if apply_waiting_labels then pcall(apply_waiting_labels) end
        if apply_pause_labels   then pcall(apply_pause_labels)   end
        -- Only re-fire begin_game if we actually have a live socket and
        -- haven't already entered the game. Without these guards a
        -- stale game_started_pending flag (e.g. from a previous run
        -- before Disconnect) drags the user right back into the level.
        if mp.game_started_pending and mp.sock and not mp.in_game and begin_game then
            pcall(begin_game)
        end
    end
    if _G.MP_NATIVE and _G.MP_NATIVE.arm_frame_tick then
        pcall(function() _G.MP_NATIVE.arm_frame_tick() end)
        logf("frame_tick: armed")
    end

    -- ------------------------------------------------------------------
    -- mp_pause = in-game pause/ESC menu. Set as the active page when
    -- begin_game runs, so ESC shows it instead of the main menu.
    -- 4 player-slot buttons act as kick targets for the host; for non-
    -- hosts the slots are info-only.
    -- ------------------------------------------------------------------
    local function pause_kick_slot(idx)
        if not mp.is_host then return end
        if not mp.sock then return end
        local target = mp.pause_roster and mp.pause_roster[idx]
        if not target or target.self then return end
        logf("pause: kicking id=%s name=%s", tostring(target.id), tostring(target.name))
        send_msg({ type = "kick_player", target_id = target.id })
    end

    local function pause_resume()
        pcall(function() menu.SetState("game", true) end)
    end

    -- Disconnect: clicked from a button on mp_pause, so we're in a
    -- safe Lua context. Do everything INLINE: the engine sees
    -- SetPage("mainmenu") during click dispatch and stays in menu
    -- state showing main menu. No SetState (that boolean would
    -- RESUME the game), no level.Clear (crashes from this context).
    --   * Host   → "close_room" tears down the room (joiners kicked).
    --   * Joiner → "leave_room" leaves quietly; host stays.
    -- Disconnect goes through the same notification flow as a kick.
    -- The user sees the mp_kicked page (telling them the game must be
    -- restarted) and clicking OK calls ExitGame. We reuse the
    -- pending_kick_cleanup tick path so the page reliably appears in
    -- both menu-state and in-game-state.
    local function pause_disconnect()
        logf("DISCONNECT: entry, was_host=%s — showing restart notification", tostring(mp.is_host))
        if mp.sock then
            if mp.is_host then
                pcall(function() send_msg({ type = "close_room" }) end)
            else
                pcall(function() send_msg({ type = "leave_room" }) end)
            end
            pcall(function() mp.sock:close() end)
            mp.sock = nil
        end
        -- Hand off to the kicked-cleanup path so the same notification
        -- page + ESC-injection works.
        mp.pending_kick_cleanup = true
    end

    -- Exit to Title: leave the room (without closing it for joiners
    -- still in) and return to main menu. Same deferred-cleanup pattern
    -- as Disconnect.
    local function pause_exit_to_title()
        if mp.sock then
            pcall(function() send_msg({ type = "leave_room" }) end)
            pcall(function() mp.sock:close() end)
            mp.sock = nil
        end
        mp.pending_to_mainmenu = true
        logf("pause: exit to title (deferred)")
    end

    local mp_pause_page
    local pok3, perr3 = pcall(function()
        mp_pause_page = menu.AddPage("mp_pause", nil)  -- no parent → no BACK
        if not mp_pause_page then error("AddPage('mp_pause') returned nil") end
        pcall(function() mp_pause_page:AddBackground("gfx/menubg.bmp") end)

        -- Two columns: player name (left, info) + kick button (right,
        -- host-only action). Labels are updated each tick via
        -- apply_pause_labels: kick buttons show "Kick" for host on
        -- non-self/non-empty slots, and blank otherwise.
        local pause_player_btns = {}
        local pause_kick_btns   = {}
        for i = 1, 4 do
            pause_player_btns[i] = mp_pause_page:AddButton(40, 80 + (i-1)*14,
                "(empty)",
                "Player slot",
                function() end)
            pause_kick_btns[i] = mp_pause_page:AddButton(150, 80 + (i-1)*14,
                "",
                "Host: kick this player",
                function() pcall(function() pause_kick_slot(i) end) end)
        end
        mp.pause_player_btns = pause_player_btns
        mp.pause_kick_btns   = pause_kick_btns

        local resume_btn = mp_pause_page:AddButton(21, 154, "Resume",
            "Return to the game",
            function() pcall(pause_resume) end)
        local disc_btn = mp_pause_page:AddButton(21, 176, "Disconnect",
            "Leave the MP room and return to the main menu (host: closes the room)",
            function() pcall(pause_disconnect) end)
        pcall(function()
            for i = 1, 4 do
                pause_player_btns[i]:SetNext("right", pause_kick_btns[i])
                pause_kick_btns[i]:SetNext("left",    pause_player_btns[i])
            end
            for i = 1, 3 do
                pause_player_btns[i]:SetNext("down", pause_player_btns[i+1])
                pause_player_btns[i+1]:SetNext("up", pause_player_btns[i])
                pause_kick_btns[i]:SetNext("down",   pause_kick_btns[i+1])
                pause_kick_btns[i+1]:SetNext("up",   pause_kick_btns[i])
            end
            pause_player_btns[4]:SetNext("down", resume_btn)
            resume_btn:SetNext("up", pause_player_btns[4])
            -- Quick host-shortcut: Resume's right → first kickable slot.
            resume_btn:SetNext("right", pause_kick_btns[2])
            pause_kick_btns[2]:SetNext("down", resume_btn)
            resume_btn:SetNext("down", disc_btn);  disc_btn:SetNext("up", resume_btn)
        end)
    end)
    logf("MP page mp_pause: ok=%s err=%s", tostring(pok3), tostring(perr3))

    -- ------------------------------------------------------------------
    -- mp_kicked: shown to a player who got kicked or whose host closed
    -- the room. Just a static notification + OK button.
    -- ------------------------------------------------------------------
    local mp_kicked_page
    local pok4, perr4 = pcall(function()
        mp_kicked_page = menu.AddPage("mp_kicked", nil)
        if not mp_kicked_page then error("AddPage('mp_kicked') returned nil") end
        pcall(function() mp_kicked_page:AddBackground("gfx/menubg.bmp") end)

        -- Short button labels (long ones get clipped to the button
        -- width). AddTextElement renders as a wide hit-box that blocks
        -- the OK click, so we avoid it. Each info button has an empty
        -- tooltip so nothing pops up on hover.
        mp_kicked_page:AddButton(100, 110, "DISCONNECTED",    "", function() end)
        mp_kicked_page:AddButton(100, 140, "Restart to play", "", function() end)
        mp_kicked_page:AddButton(100, 156, "another MP game", "", function() end)
        mp_kicked_page:AddButton(150, 190, "OK", "",
            function()
                mp.force_kicked_page = false
                pcall(function() ExitGame() end)
            end)
    end)
    logf("MP page mp_kicked: ok=%s err=%s", tostring(pok4), tostring(perr4))

    -- Re-labels the pause page's player slots based on the in-game
    -- roster: mp.my_id + mp.puppets (other players). Player slot shows
    -- name+marker; kick column shows "Kick" for host on others, "" else.
    apply_pause_labels = function()
        if not (_G.MP_NATIVE and _G.MP_NATIVE.set_button_label) then return end
        local roster = {}
        if mp.my_id then
            table.insert(roster, {
                id = mp.my_id,
                name = (config.name or "Player"),
                self = true,
                is_host = mp.is_host,
            })
        end
        for pid, entry in pairs(mp.puppets or {}) do
            if pid ~= mp.my_id then
                table.insert(roster, {
                    id = pid,
                    name = (entry and entry.name) or "?",
                    is_host = (pid == mp.host_id),
                })
            end
        end
        mp.pause_roster = roster
        if mp.pause_player_btns then
            for i = 1, 4 do
                local btn  = mp.pause_player_btns[i]
                local kbtn = mp.pause_kick_btns and mp.pause_kick_btns[i]
                local p    = roster[i]
                if btn and btn.pointer then
                    local label
                    if p then
                        local nm = tostring(p.name or "?")
                        local suffix = (p.is_host and "*" or "") .. (p.self and "(me)" or "")
                        local prefix = i .. ":"
                        local max_name = 15 - #prefix - #suffix
                        if max_name < 1 then max_name = 1 end
                        label = prefix .. nm:sub(1, max_name) .. suffix
                    else
                        label = "(empty)"
                    end
                    pcall(function() _G.MP_NATIVE.set_button_label(btn.pointer, label) end)
                end
                if kbtn and kbtn.pointer then
                    -- Kick label is intentionally short — padded with
                    -- spaces so the clickable area is comfortably wide
                    -- without dragging the target's name into it.
                    local label = (mp.is_host and p and not p.self) and "   Kick   " or ""
                    pcall(function() _G.MP_NATIVE.set_button_label(kbtn.pointer, label) end)
                end
            end
        end
    end

    -- Concrete implementation of the forward-declared apply_waiting_labels.
    -- Re-labels the 4 player slot buttons + Start button on each state
    -- change (welcome / join / leave / host_changed / refresh).
    apply_waiting_labels = function()
        if not (_G.MP_NATIVE and _G.MP_NATIVE.set_button_label) then return end
        -- Build a roster ordered: self first, then others by id.
        local roster = {}
        if mp.my_id then
            table.insert(roster, {
                id = mp.my_id,
                name = (config.name or "Player"),
                self = true,
                is_host = (mp.my_id == mp.host_id),
            })
        end
        for _, p in ipairs(mp.room_players or {}) do
            if p.id ~= mp.my_id then
                table.insert(roster, { id = p.id, name = p.name, is_host = (p.id == mp.host_id) })
            end
        end
        if mp.lobby_player_btns then
            for i = 1, 4 do
                local btn = mp.lobby_player_btns[i]
                if btn and btn.pointer then
                    local p = roster[i]
                    local label
                    if p then
                        local nm = tostring(p.name or "?")
                        local suffix = (p.is_host and "*" or "") .. (p.self and "(me)" or "")
                        -- 15-char SSO budget. Reserve room for "i:" + suffix.
                        local prefix = i .. ":"
                        local max_name = 15 - #prefix - #suffix
                        if max_name < 1 then max_name = 1 end
                        label = prefix .. nm:sub(1, max_name) .. suffix
                    else
                        label = "(empty)"
                    end
                    pcall(function() _G.MP_NATIVE.set_button_label(btn.pointer, label) end)
                end
            end
        end
        if mp.lobby_start_btn and mp.lobby_start_btn.pointer then
            local label = mp.is_host and "Start Game" or "Wait for host"
            pcall(function() _G.MP_NATIVE.set_button_label(mp.lobby_start_btn.pointer, label) end)
        end
    end

    -- ------------------------------------------------------------------
    -- Main-menu entry — single Multiplayer button. Just navigates; the
    -- relay connection happens when the user clicks Create or Join.
    -- ------------------------------------------------------------------
    local mp_btn = mainmenu_page:AddButton(144, 104, "Multiplayer",
        "Open the multiplayer lobby (or pause menu while in MP game)",
        function()
            local cok, cerr = pcall(function()
                if mp.in_game then
                    logf("multiplayer: in MP game — opening mp_pause")
                    menu.SetPage("mp_pause")
                else
                    if not pok1 then logf("mp_lobby page failed: %s", tostring(perr1)); return end
                    logf("multiplayer: opening mp_lobby")
                    -- Refresh stats counts so "Lobby:" / "Active:" reflect
                    -- the current server state when the page renders.
                    pcall(lobby_refresh_rooms)
                    menu.SetPage("mp_lobby")
                end
            end)
            if not cok then logf("Multiplayer click crash: %s", tostring(cerr)) end
        end)

    pcall(function()
        local continue_btn = mainmenu_page:GetButton("Continue")
        local newgame_btn  = mainmenu_page:GetButton("New Game")
        if continue_btn then
            continue_btn:SetNext("right", mp_btn)
            mp_btn:SetNext("left", continue_btn)
        end
        if newgame_btn then
            newgame_btn:SetNext("right", mp_btn)
        end
    end)
end)
if not _mp_integration_ok then
    logf("MP MENU INTEGRATION FAILED: %s", tostring(_mp_integration_err))
end

logf("mp_client.lua init done")
