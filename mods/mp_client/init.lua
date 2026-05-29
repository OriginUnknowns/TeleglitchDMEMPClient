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
            -- Try installing the CreateBullet hook. Logs to dllhost.log.
            if mp_native.install_bullet_hook then
                local hook_ok = mp_native.install_bullet_hook()
                if mp_native.log then mp_native.log("install_bullet_hook returned " .. tostring(hook_ok)) end
            end
            -- TakeDamage hook needs a Soldat pointer to resolve vtable.
            -- Player isn't available at mod load time; defer to a tick
            -- coroutine that fires once player.GetPlayer() returns non-nil.
            if mp_native.install_takedamage_hook then
                _G.MP_NATIVE = mp_native
                _G.MP_INSTALL_TAKEDMG_DEFERRED = true
                if mp_native.log then mp_native.log("set MP_INSTALL_TAKEDMG_DEFERRED=true") end
            end
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
                give_count = give_count + 1
                logf("GIVEITEM #%d type=%s in_giveitem_was=%s",
                    give_count, tostring(type_name), tostring(in_giveitem))
                local prev = in_giveitem
                in_giveitem = true
                local ok, err = pcall(orig_give, self, type_name, ...)
                in_giveitem = prev
                if not ok then error(err) end
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
    local ok, err = mp.sock:send(frame)
    if not ok then
        logf("send error: %s — disconnecting", tostring(err))
        mp.sock:close()
        mp.sock = nil
    end
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
    end
end

local joiner_pre_snapshot_items = {}  -- list of obj refs
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
    table.insert(joiner_pre_snapshot_items, obj)
    joiner_track_seq = joiner_track_seq + 1
    local wx, wy = get_obj_pos(obj)
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

-- Apply host's item_list. Joiner ran level gen normally (so RNG matched host's
-- and rooms are identical); we now delete those local items and re-spawn from
-- host's authoritative snapshot, keyed by host's IDs.
local function apply_item_list(items)
    logf("apply_item_list: BEGIN  pre_snapshot_n=%d  spawn=%d",
        #joiner_pre_snapshot_items, #(items or {}))
    pcall(function() if SetVolume then SetVolume(0) end end)
    -- 1. Build "alive" pointer set so we only Delete items whose underlying
    --    C++ obj still exists. Many tracked items are "ghosts" (engine spawned
    --    them then destroyed during overlap resolution) — calling Delete on
    --    a ghost = R6025 segfault.
    local pl = player.GetPlayer()
    local px, py = 0, 0
    if pl then pcall(function() px, py = pl:GetPosition() end) end
    local alive_ptrs = {}
    local objs = GetObjectsInCircle(px, py, 1000)
    if type(objs) == "table" then
        for _, o in ipairs(objs) do
            if type(o) == "table" and o.pointer then
                alive_ptrs[tostring(o.pointer)] = true
            end
        end
    end
    -- 2. Wipe ONLY alive items
    local pre_deleted, skipped_ghosts = 0, 0
    for _, obj in ipairs(joiner_pre_snapshot_items) do
        local ptr = nil
        if obj and type(obj) == "table" then
            local ok, p = pcall(function() return tostring(obj.pointer or obj) end)
            if ok then ptr = p end
        end
        if ptr and alive_ptrs[ptr] and type(obj.Delete) == "function" then
            pcall(function() obj:Delete() end)
            pre_deleted = pre_deleted + 1
            if pre_deleted % 2 == 0 then Wait(0.2) end  -- 2 deletes per ~0.2s
        else
            skipped_ghosts = skipped_ghosts + 1
        end
    end
    Wait(0.3)
    logf("apply_item_list: wiped %d alive items (skipped %d ghosts)",
        pre_deleted, skipped_ghosts)
    joiner_pre_snapshot_items = {}
    joiner_pre_snapshot_objs = {}
    mp.items = {}
    mp.item_obj_to_id = {}
    mp.item_snapshot_received = true
    local count_in = (type(items) == "table") and #items or 0
    if count_in == 0 then
        logf("apply_item_list: SKIP (empty input)")
        pcall(function() if SetVolume then SetVolume(100) end end)
        return
    end
    local spawned, errors = 0, 0
    for i, it in ipairs(items or {}) do
        local ok, obj = pcall(function() return CreateItem(it.x, it.y, it.type) end)
        if not ok then
            errors = errors + 1
            logf("CreateItem ERROR id=%d type=%s pos=(%.1f,%.1f): %s",
                it.id, tostring(it.type), it.x, it.y, tostring(obj))
        else
            local store_obj = (type(obj) == "table") and obj or nil
            local wx, wy = nil, nil
            if store_obj then wx, wy = get_obj_pos(store_obj) end
            mp.items[it.id] = { obj = store_obj, type = it.type, x = it.x, y = it.y }
            if store_obj then mp.item_obj_to_id[store_obj] = it.id end
            logf("SPAWN id=%d type=%s requested=(%.2f,%.2f) actual=(%.2f,%.2f) ok=%s",
                it.id, it.type, it.x, it.y, wx or -999, wy or -999, tostring(store_obj ~= nil))
            spawned = spawned + 1
        end
        Wait(0.3)  -- faster than 1s, still gives physics breathing room
    end
    -- Restore volume now that the burst is done (settings volume * 100 is std).
    Wait(0.5)  -- give any in-flight sounds time to settle before unmuting
    pcall(function() if SetVolume then SetVolume(100) end end)
    logf("joiner applied item_list: requested=%d spawned=%d errors=%d  (audio restored)",
        #(items or {}), spawned, errors)
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
    logf("inv diff: picked id=%d type=%s d=%.2f BROADCAST",
        best_id, type_name, math.sqrt(best_d2))
end

local function diff_inventory()
    if not mp.sock then return end
    local now_counts = snapshot_inventory()
    if not now_counts then return end
    if not last_inv_counts then last_inv_counts = now_counts; return end
    local pl = player.GetPlayer()
    local px, py = 0, 0
    if pl then pcall(function() px, py = pl:GetPosition() end) end
    for type_name, cur_n in pairs(now_counts) do
        local prev_n = last_inv_counts[type_name] or 0
        local gained = cur_n - prev_n
        if gained > 0 then
            logf("INV CHANGE type=%s prev=%d cur=%d gained=%d", type_name, prev_n, cur_n, gained)
            for i = 1, gained do
                logf("INV ATTEMPT %d/%d for type=%s", i, gained, type_name)
                broadcast_pickup_of_type(type_name, px, py)
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
    logf("ammo diff: picked id=%d type=%s d=%.2f BROADCAST",
        best_id, entry.type, math.sqrt(best_d2))
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
        for n = 0, 12 do
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
    if nearest and nearest_dist <= PROXIMITY_RANGE then
        line = string.format(">> %s <<  %s   HP:%d   dist:%.1f",
            role, nearest.name, nearest.hp or 0, nearest_dist)
    else
        local n = 0
        for _ in pairs(mp.puppets) do n = n + 1 end
        line = string.format(">> %s <<  you=%s   peers=%d", role, config.name, n)
    end
    pcall(function() level.SetObjectiveString(line) end)
end

handle_join = function(p)
    if mp.puppets[p.id] then return end
    local pl = player.GetPlayer()
    local px, py = 0, 0
    if pl then px, py = pl:GetPosition() end
    local sx, sy = p.x or (px + 3), p.y or (py + 3)
    local obj
    pcall(function() obj = Create{ type = "mp_remote_player", x = sx, y = sy, angle = p.angle or 0 } end)
    local display_name = (p.name or "?") .. "#" .. tostring(p.id)
    if obj then pcall(function() obj:SetName("mp_player_" .. tostring(p.id)) end) end
    local init_text = display_name .. " HP:" .. tostring(p.hp or 100)
    local nameplate
    pcall(function() nameplate = CreateTextObj(sx, sy - 1.2, init_text) end)
    mp.puppets[p.id] = {
        obj = obj, name = display_name, hp = p.hp or 100,
        last_x = sx, last_y = sy,
        created_at = socket.gettime(),
        nameplate = nameplate, nameplate_text = init_text,
    }
    logf("join id=%s name=%s pos=(%.2f, %.2f)", tostring(p.id), display_name, sx, sy)
    refresh_objective_string()
end

local function handle_welcome(msg)
    mp.my_id = msg.id
    logf("welcomed my_id=%s host_id=%s is_host=%s", tostring(mp.my_id), tostring(msg.host_id), tostring(mp.is_host))
    if msg.players then
        for _, p in ipairs(msg.players) do
            if p.id ~= mp.my_id then handle_join(p) end
        end
    end
    refresh_objective_string()
end

local function handle_leave(msg)
    local entry = mp.puppets[msg.id]
    if entry and entry.obj then pcall(function() entry.obj:Delete() end) end
    if entry and entry.nameplate then pcall(function() entry.nameplate:Delete() end) end
    mp.puppets[msg.id] = nil
    logf("left id=%s", tostring(msg.id))
    refresh_objective_string()
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

local function handle_snapshot(msg)
    if not mp.my_id or not msg.players then return end
    for _, p in ipairs(msg.players) do
        if p.id ~= mp.my_id then
            local entry = mp.puppets[p.id]
            if not entry then handle_join(p); entry = mp.puppets[p.id] end
            if entry and entry.obj then
                -- Liveness check: if engine has freed the entity, recreate.
                if not entity_alive(entry.obj) then
                    logf("PUPPET STALE id=%s last=(%.1f,%.1f) age=%.1fs — recreating",
                        tostring(p.id), entry.last_x or 0, entry.last_y or 0,
                        socket.gettime() - (entry.created_at or 0))
                    mp.puppets[p.id] = nil
                    handle_join(p)
                    entry = mp.puppets[p.id]
                end
                if entry and entry.obj then
                    pcall(function() entry.obj:SetPosition(p.x, p.y) end)
                    if p.angle then
                        pcall(function() entry.obj:SetAngle(p.angle) end)
                    end
                    entry.last_x = p.x
                    entry.last_y = p.y
                    if p.hp then entry.hp = p.hp end
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
    local ppx, ppy = pl:GetPosition()
    local mwx, mwy
    pcall(function()
        local mx, my = GetMousePosition()
        if mx and my then mwx, mwy = GetWorldPoint(mx, my) end
    end)
    for _, entry in pairs(mp.puppets) do
        if entry.last_x and entry.nameplate then
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
        logf("item_picked: NO entry id=%d from peer %s", msg.id, tostring(msg.picker_id))
        return
    end
    local deleted = false
    if entry.obj then
        local ok = pcall(function() if entry.obj.Delete then entry.obj:Delete(); deleted = true end end)
        if not ok then deleted = false end
    end
    if not deleted then
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
    logf("item_picked: id=%d type=%s deleted=%s from peer %s",
        msg.id, tostring(entry.type), tostring(deleted), tostring(msg.picker_id))
end

local function handle_item_spawned(msg)
    if mp.is_host then return end
    local it = msg.item
    if not (it and it.id and it.type) then return end
    if mp.items[it.id] then return end  -- already have it
    mp.item_snapshot_received = true  -- bypass spawn-block wraps
    local obj
    pcall(function() obj = CreateItem(it.x, it.y, it.type) end)
    local store_obj = (type(obj) == "table") and obj or nil
    mp.items[it.id] = { obj = store_obj, type = it.type, x = it.x, y = it.y }
    if store_obj then mp.item_obj_to_id[store_obj] = it.id end
    logf("handle_item_spawned: id=%d type=%s pos=(%.1f,%.1f) ok=%s",
        it.id, it.type, it.x, it.y, tostring(store_obj ~= nil))
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
                    pcall(function() entry.obj:SetPosition(m.x, m.y) end)
                    if m.a then pcall(function() entry.obj:SetAngle(m.a) end) end
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
            local h
            pcall(function() if info.obj.GetHealth then h = info.obj:GetHealth() end end)
            if h then
                local new_h = h - msg.dmg
                pcall(function() info.obj:SetHealth(new_h, 1) end)
                logf("mob_damage RX id=%d dmg=%d %d->%d", msg.id, msg.dmg, h, new_h)
            end
            return
        end
    end
end

local function handle_mob_died(msg)
    if mp.is_host or not msg.id then return end
    local entry = mp.mob_puppets[msg.id]
    if not entry then return end
    mp.mob_puppets[msg.id] = nil
    if entry.obj then
        -- Hide rather than Delete (vtable may be corrupted from heap stomp).
        pcall(function() entry.obj:SetPosition(-500, -500) end)
    end
    logf("mob_died: id=%d hidden", msg.id)
end

local handlers = {
    welcome = handle_welcome,
    join = function(m) handle_join(m) end,
    leave = handle_leave,
    snapshot = handle_snapshot,
    host_changed = handle_host_changed,
    mob_snapshot = handle_mob_snapshot,
    mob_died = handle_mob_died,
    mob_damage = handle_mob_damage,
    item_picked = handle_item_picked,
    item_list = handle_item_list,
    item_spawned = handle_item_spawned,
    inventory = handle_inventory,
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
        local objs = GetObjectsInCircle(px, py, 5000)
        if type(objs) == "table" then
            for _, o in ipairs(objs) do
                if type(o) == "table" and o.pointer then
                    alive_set[tostring(o.pointer)] = true
                end
            end
        end
    end
    for ptr, info in pairs(mp.host_mobs) do
        local in_world = info.obj and info.obj.pointer and alive_set[tostring(info.obj.pointer)]
        if not in_world then
            table.insert(dead_ids, info.id)
            table.insert(dead_ptrs, ptr)
        else
            local x, y, a, h, mh
            local ok = pcall(function()
                x, y = info.obj:GetPosition()
                a = info.obj:GetAngle()
                if info.obj.GetHealth then h = info.obj:GetHealth() end
                if info.obj.GetMaxHealth then mh = info.obj:GetMaxHealth() end
            end)
            if ok and x and y and (not h or h > 0) then
                table.insert(mobs, { id = info.id, type = info.type, x = x, y = y, a = a or 0, h = h, mh = mh })
            else
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
local function connect_and_handshake(proposed_seed)
    logf("connecting to %s:%d as '%s'…", config.host, config.port, config.name)
    local sock = socket.tcp()
    sock:settimeout(3)
    local ok, err = sock:connect(config.host, config.port)
    if not ok then logf("connect failed: %s", tostring(err)); return false, err end

    local hello = { type = "hello", name = config.name }
    if proposed_seed then hello.seed = proposed_seed end
    local body = json.encode(hello)
    local ok2, err2 = sock:send(pack_u32_be(#body) .. body)
    if not ok2 then sock:close(); logf("send hello failed: %s", tostring(err2)); return false, err2 end

    local len_bytes, rerr = sock:receive(4)
    if not len_bytes then sock:close(); logf("no welcome length: %s", tostring(rerr)); return false, rerr end
    local body_len = unpack_u32_be(len_bytes)
    local body_str, rerr2 = sock:receive(body_len)
    if not body_str then sock:close(); logf("no welcome body: %s", tostring(rerr2)); return false, rerr2 end
    local ok3, welcome = pcall(json.decode, body_str)
    if not ok3 or welcome.type ~= "welcome" then sock:close(); logf("bad welcome"); return false, "bad welcome" end

    sock:settimeout(0)
    mp.sock = sock
    mp.rx_buf = ""
    mp.puppets = {}
    mp.items = {}
    mp.item_obj_to_id = {}
    mp.next_item_id = 1
    mp.item_snapshot_sent = false
    mp.item_snapshot_received = false
    mp.pending_item_list = nil
    joiner_pre_snapshot_items = {}
    joiner_pre_snapshot_objs = {}
    mp.my_id = welcome.id
    mp.host_id = welcome.host_id
    mp.is_host = (welcome.host_id == welcome.id)
    mp.session_seed = welcome.seed  -- save so GenerateLevel wrap can re-apply it
    mp.pending_initial_players = welcome.players or {}
    -- Joiners may receive an item_list inline with welcome (server-cached host snapshot
    -- minus already-picked ids). Stash for application after level loads.
    -- json decoder turns null into {}, so check #table > 0, not just truthy.
    if not mp.is_host and type(welcome.item_list) == "table" and #welcome.item_list > 0 then
        mp.pending_item_list = welcome.item_list
        logf("welcome: stashed pending_item_list n=%d", #welcome.item_list)
    end
    logf("connected my_id=%d seed=%s host_id=%s is_host=%s initial_players=%d item_list=%d",
        welcome.id, tostring(welcome.seed), tostring(welcome.host_id), tostring(mp.is_host),
        #(welcome.players or {}), #(welcome.item_list or {}))
    return true, welcome.seed
end

local function disconnect_only()
    if mp.sock then pcall(function() mp.sock:close() end); mp.sock = nil end
    mp.rx_buf = ""
    for _, entry in pairs(mp.puppets) do
        if entry.obj then pcall(function() entry.obj:Delete() end) end
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
    while true do
        -- Install TakeDamage hook as soon as a player exists.
        if _G.MP_INSTALL_TAKEDMG_DEFERRED and _G.MP_NATIVE then
            local pl = player.GetPlayer()
            if not _G.MP_TICK_LOGGED then
                _G.MP_TICK_LOGGED = true
                if _G.MP_NATIVE.log then
                    _G.MP_NATIVE.log(string.format(
                        "deferred installer tick: pl=%s pl.pointer=%s ptype=%s",
                        tostring(pl), tostring(pl and pl.pointer), type(pl and pl.pointer)))
                end
            end
            if pl and pl.pointer then
                local ok = _G.MP_NATIVE.install_takedamage_hook(pl.pointer)
                if _G.MP_NATIVE.log then _G.MP_NATIVE.log("install_takedamage_hook -> " .. tostring(ok)) end
                _G.MP_INSTALL_TAKEDMG_DEFERRED = nil
            end
        end
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
            local now = socket.gettime()
            if mp.sock and now - mp.last_send >= send_interval then
                local pl = player.GetPlayer()
                if pl then
                    local x, y = pl:GetPosition()
                    local a = pl:GetAngle()
                    local hp = pl:GetHealth()
                    send_msg({ type = "state", x = x, y = y, angle = a, hp = hp })
                end
                mp.last_send = now
            end
            if mp.is_host and mp.sock and now - mp.last_mob_send >= 0.1 then
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
    local deleted, batch = 0, 0
    for _, obj in ipairs(objs) do
        if type(obj) == "table" and obj.Alert and obj.Delete and tostring(obj.pointer) ~= my_ptr then
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

-- ============ DEV MENU (host-only item spawner) ============
-- Numpad +/- cycle item, Numpad Enter spawn at player pos, Numpad * toggle visibility.
local DEV_ITEMS = {
    "pystol", "pump", "agl", "revolver",
    "pyammo", "ppammo", "auammo", "pexpammo",
    "smtimebomb", "nailbomb", "rocketitem",
    "cmeat", "medkit", "smmedkit",
    "armor", "smarmor",
    "emptycan", "tube", "metalplate", "hardware", "nailbox",
}
dev_menu = { visible = false, index = 1 }  -- fills the forward-declared local

local function dev_menu_render()
    if not (level and level.IsLoaded and level.IsLoaded()) then return end
    if not dev_menu.visible then return end
    local item = DEV_ITEMS[dev_menu.index] or "?"
    local txt = string.format("[DEV %d/%d] <%s>  KP+/- cycle, KPEnter spawn, KP* close",
        dev_menu.index, #DEV_ITEMS, item)
    pcall(function() level.SetObjectiveString(txt) end)
end

local dev_spawn_counter = 0
local function dev_menu_spawn_current()
    local pl = player.GetPlayer()
    if not pl then return end
    local px, py = pl:GetPosition()
    local name = DEV_ITEMS[dev_menu.index]
    if not name then return end
    -- Stagger positions in a circle around the player so items don't stack.
    dev_spawn_counter = dev_spawn_counter + 1
    local angle = (dev_spawn_counter * 0.7)  -- ~40deg per spawn
    local radius = 1.2 + (dev_spawn_counter % 4) * 0.4
    local ix = px + math.cos(angle) * radius
    local iy = py + math.sin(angle) * radius
    mp.spawn_test_scene = true
    local ok, err = pcall(function() Create{ type = name, x = ix, y = iy, angle = 0 } end)
    mp.spawn_test_scene = false
    logf("dev_menu: spawn %s at (%.2f,%.2f) ok=%s err=%s",
        name, ix, iy, tostring(ok), tostring(err))
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
    if entry.obj and type(entry.obj.Delete) == "function" then
        pcall(function() entry.obj:Delete() end)
    end
    if mp.sock then
        send_msg({ type = "item_picked", id = best_id, picker_id = mp.my_id })
        logf("manual_pickup: id=%d type=%s d=%.2f BROADCAST",
            best_id, tostring(entry.type), math.sqrt(best_d2))
    end
end

-- Key names from lua/keys.lua — keypad +, arrow up/down, return/kp_enter.
local function dev_menu_tick()
    -- Install TakeDamage hook on player + every visible mob. The native
    -- side dedups by function address, so calling for many mobs that share
    -- a vtable[24] does nothing extra. Limited to once every ~2 seconds.
    if _G.MP_NATIVE and _G.MP_NATIVE.install_takedamage_hook then
        local now = socket.gettime()
        if not _G.MP_TAKEDMG_LAST_SCAN or (now - _G.MP_TAKEDMG_LAST_SCAN) > 2.0 then
            _G.MP_TAKEDMG_LAST_SCAN = now
            local pl = player.GetPlayer()
            if pl and pl.pointer then
                _G.MP_NATIVE.install_takedamage_hook(pl.pointer)
            end
            -- Scan nearby mobs and try to hook each. Native side dedups.
            local px, py = 0, 0
            if pl then pcall(function() px, py = pl:GetPosition() end) end
            local objs = GetObjectsInCircle(px, py, 200)
            if type(objs) == "table" then
                local tried = 0
                for _, o in ipairs(objs) do
                    if type(o) == "table" and o.pointer and o.Alert then  -- soldat-like
                        pcall(function() _G.MP_NATIVE.install_takedamage_hook(o.pointer) end)
                        tried = tried + 1
                        if tried > 12 then break end  -- cap per scan
                    end
                end
            end
        end
    end
    -- Manual pickup key works on BOTH sides (host AND joiner).
    if kp("kp_minus") then
        logf("manual pickup key pressed")
        manual_pickup_nearest()
    end
    -- TEXTOBJ PROBE: Numpad / spawns a CreateTextObj near the player and logs
    -- everything we can learn about the returned handle.
    if kp("kp_1") then
        local pl = player.GetPlayer()
        local px, py = 0, 0
        if pl then pcall(function() px, py = pl:GetPosition() end) end
        local ok, res = pcall(function() return CreateTextObj(px, py + 1.5, "HELLO MP") end)
        logf("TEXTOBJ probe: ok=%s type=%s value=%s", tostring(ok), type(res), tostring(res))
        if ok and type(res) == "table" then
            local methods = {}
            for k, v in pairs(res) do methods[#methods+1] = string.format("%s=%s", tostring(k), type(v)) end
            logf("TEXTOBJ fields: %s", table.concat(methods, ", "))
            local mt = getmetatable(res)
            if mt then
                local mtm = {}
                for k, v in pairs(mt) do mtm[#mtm+1] = string.format("%s=%s", tostring(k), type(v)) end
                logf("TEXTOBJ metatable: %s", table.concat(mtm, ", "))
                if type(mt.__index) == "table" then
                    local idxm = {}
                    for k, v in pairs(mt.__index) do idxm[#idxm+1] = string.format("%s=%s", tostring(k), type(v)) end
                    logf("TEXTOBJ __index: %s", table.concat(idxm, ", "))
                end
            end
            mp._probe_textobj = res  -- keep ref so engine doesn't GC it
        end
    end
    -- TEXTOBJ FOLLOW: Numpad * moves the probe text to follow the player so
    -- we can tell if coords are world-space (follows) or screen-space (fixed).
    if kp("kp_2") and mp._probe_textobj then
        local pl = player.GetPlayer()
        if pl then
            local px, py = pl:GetPosition()
            local ok1 = pcall(function() mp._probe_textobj:SetPosition(px, py + 1.5) end)
            local ok2 = pcall(function() mp._probe_textobj:SetStartPos(px, py + 1.5) end)
            local cpx, cpy
            pcall(function() cpx, cpy = mp._probe_textobj:GetPosition() end)
            local spx, spy
            pcall(function() spx, spy = mp._probe_textobj:GetStartPos() end)
            logf("TEXTOBJ follow SetPos=%s SetStartPos=%s player=(%.2f,%.2f) GetPos=(%s,%s) GetStartPos=(%s,%s)",
                tostring(ok1), tostring(ok2), px, py,
                tostring(cpx), tostring(cpy), tostring(spx), tostring(spy))
        end
    end
    -- Numpad 3: spawn another text far away in world coords (50, 50) — if
    -- text is world-space we'll see it disappear off the screen.
    if kp("kp_3") then
        local ok, res = pcall(function() return CreateTextObj(50, 50, "FAR AWAY") end)
        logf("TEXTOBJ far probe: ok=%s value=%s", tostring(ok), tostring(res))
        if ok then mp._probe_textobj_far = res end
    end
    -- Keep dev menu text on screen against any other writers (handle_join,
    -- handle_leave, etc. all call refresh_objective_string).
    if dev_menu.visible then dev_menu_render() end
    if not mp.is_host then return end
    if kp("kp_plus") then
        dev_menu.visible = not dev_menu.visible
        logf("dev_menu: toggle visible=%s", tostring(dev_menu.visible))
        if not dev_menu.visible then
            pcall(function() level.SetObjectiveString("") end)
        else
            dev_menu_render()
        end
    end
    if not dev_menu.visible then return end
    if kp("down") then
        dev_menu.index = (dev_menu.index % #DEV_ITEMS) + 1
        logf("dev_menu: down -> %d (%s)", dev_menu.index, DEV_ITEMS[dev_menu.index])
        dev_menu_render()
    elseif kp("up") then
        dev_menu.index = ((dev_menu.index - 2) % #DEV_ITEMS) + 1
        logf("dev_menu: up -> %d (%s)", dev_menu.index, DEV_ITEMS[dev_menu.index])
        dev_menu_render()
    end
    if kp("return") or kp("kp_enter") then
        logf("dev_menu: ENTER, spawning")
        dev_menu_spawn_current()
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

-- ============ MENU INTEGRATION ============
pcall(function()
    if not (menu and menu.GetPage) then return end
    local page = menu.GetPage("mainmenu")
    if not page then return end

    if page.AddButton then
        pcall(function() page:AddButton(21, 82, "- MP MOD -", "by OriginUnknowns", function() end) end)
        local function enter_mp(is_host, test_mode)
            -- Hardcoded seed for repeatable testing. Set to nil to use os.time().
            local FIXED_SEED = 1779843477
            local proposed_seed = is_host and (FIXED_SEED or os.time()) or nil
            local ok, seed = connect_and_handshake(proposed_seed)
            if not ok then return end
            mp.test_mode = test_mode and true or false
            logf("enter_mp: test_mode=%s step=randomseed seed=%s", tostring(mp.test_mode), tostring(seed))
            math.randomseed(seed)
            logf("enter_mp: step=StartFrom level1")
            local lok, lerr = pcall(function() level.StartFrom("level1", 0) end)
            if not lok then logf("enter_mp: StartFrom CRASH: %s", tostring(lerr)) end
            logf("enter_mp: step=SetState game")
            pcall(function() menu.SetState("game", true) end)
            for _, p in ipairs(mp.pending_initial_players or {}) do
                if p.id ~= mp.my_id then handle_join(p) end
            end
            mp.pending_initial_players = nil
            pcall(refresh_objective_string)
            mp.pickup_scan_start_after = socket.gettime() + 2.5
            start_net_coro()
            start_dev_menu_coro()  -- both sides — manual pickup key works for everyone
            if mp.test_mode then
                -- Test mode: skip normal joiner-mob-cleanup + host-snapshot coros.
                -- setup_test_room handles both sides' cleanup + host's item spawn/send.
                local co = coroutine.create(function()
                    local sok, serr = pcall(setup_test_room)
                    if not sok then logf("test_room CRASH: %s", tostring(serr)) end
                end)
                coroutine.resume(co)
            else
                start_joiner_cleanup_coro()
                if mp.is_host then
                    local co = coroutine.create(function()
                        pcall(function()
                            Wait(1.5)
                            host_send_item_list()
                        end)
                    end)
                    coroutine.resume(co)
                end
            end
            logf("enter_mp: DONE")
        end
        local host_btn = page:AddButton(144, 104, "Host MP",
            "Start hosting on " .. config.host .. ":" .. config.port,
            function() enter_mp(true, false) end)
        local join_btn = page:AddButton(144, 126, "Join MP",
            "Join " .. config.host .. ":" .. config.port,
            function() enter_mp(false, false) end)
        local thost_btn = page:AddButton(144, 148, "Test Host",
            "Host test room: 2 items + 1 mob, known positions",
            function() enter_mp(true, true) end)
        local tjoin_btn = page:AddButton(144, 170, "Test Join",
            "Join the test room",
            function() enter_mp(false, true) end)
        pcall(function()
            local continue_btn = page:GetButton("Continue")
            local newgame_btn  = page:GetButton("New Game")
            if continue_btn and host_btn then
                continue_btn:SetNext("right", host_btn)
                host_btn:SetNext("left", continue_btn)
                host_btn:SetNext("down", join_btn)
                join_btn:SetNext("up", host_btn)
                join_btn:SetNext("down", thost_btn)
                thost_btn:SetNext("up", join_btn)
                thost_btn:SetNext("down", tjoin_btn)
                tjoin_btn:SetNext("up", thost_btn)
                if newgame_btn then join_btn:SetNext("left", newgame_btn) end
            end
        end)
    end
end)

logf("mp_client.lua init done")
