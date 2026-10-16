-- sweep_addon_bigpow.lua - guard Shao Kahn's Big Power grab.
--
-- The grab was reworked twice (victim posed in STUMBLE rather than hit-high,
-- and the hit now lands unconditionally through damage_to_him instead of a
-- strike check) and nothing in the build would notice if either regressed:
-- behaviour.lock's ten cases do not include it.
--
-- It cannot be driven like the other cases. Big Power has no button - it is
-- dispatched by Kahn's own AI from `kcb_low_close`, chosen against `@rand`
-- when the player is close. So the rig sets up the CONDITION - pin the player
-- inside Kahn's close band and keep him alive - and records what happens when
-- the boss decides to use it.
--
-- What it records, and why each is the right signal:
--
--   damage   kbigp_damage is 40h = 64, matching stk_sk_bigpow's damage_hit.
--            A change to the damage constant, or to whether ochar_xlate_damage
--            still runs on this path, moves this number.
--   victim   the action the caught man is left in. The pose rework is exactly
--            this value; hit-high and stumble are different lanes.
--
-- @rand reseeds identically every round, so a fixed setup replays the same
-- roll - the run is checked for that by running it twice before trusting it.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/bigpow.txt"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_obj, p2_obj = sym.gstate, sym.p1_obj, sym.p2_obj
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p1_bar, p2_bar, right_edge = sym.p1_bar, sym.p2_bar, sym.right_edge
local OXPOS, OXVAL, P_ACTION, MAX_HP = 0x090, 0x080, 0x1f0, 0xA1
local DIST = tonumber(os.getenv("BIGPOW_DIST") or "48")

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[bigp] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0 = nil, 0, 0
local lasthp, hits, seen = nil, {}, {}
local kacts, hpmin = {}, 999
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        log("=== big power === player pinned %d px from Kahn", DIST)
    end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r1 == 0 or r2 == 0 then return end
    if fight0 == 0 then fight0 = frame end
    if frame - fight0 < 60 then return end

    -- hold the player inside Kahn's close band and keep him alive, so the
    -- boss keeps choosing from the same branch instead of ending the round
    -- DO NOT PIN THE BOSS. Writing his oxpos every frame froze him solid:
    -- 2331 frames of stance and not one attack. His moves carry him, so a
    -- rig that holds him in place holds him out of the fight entirely.
    --
    -- Move the PLAYER to him instead. Big Power is chosen in kcb_low_close,
    -- so the close band has to be held for the branch to be reachable at all
    -- - but the boss stays free to act.
    space:write_u16(p2_bar, MAX_HP)
    local kx = s16(space:read_u16(o2 + OXPOS))
    local px = kx - DIST
    space:write_u16(o1 + OXPOS, px)
    space:write_u32(o1 + OXVAL, (px << 16) & 0xffffffff)

    -- what is the boss actually doing? a silent zero must say why
    local ka0 = space:read_u16(r2 + P_ACTION)
    kacts[ka0] = (kacts[ka0] or 0) + 1
    local hp = space:read_u16(p1_bar)
    if hp < hpmin then hpmin = hp end
    -- start tracking from the first frame we see, so a hit that lands
    -- during the intro cannot be missed the way the first run missed one
    if lasthp and hp < lasthp then
        local lost = lasthp - hp
        local va = space:read_u16(r1 + P_ACTION)
        local ka = space:read_u16(r2 + P_ACTION)
        hits[#hits + 1] = { d = lost, v = va, k = ka }
        seen[lost] = (seen[lost] or 0) + 1
    end
    if hp < 40 then space:write_u16(p1_bar, MAX_HP) end
    lasthp = space:read_u16(p1_bar)
end)

emu.register_stop(function()
    local l = {}
    for d, n in pairs(seen) do l[#l + 1] = { d = d, n = n } end
    table.sort(l, function(a, b) return a.n > b.n end)
    local parts = {}
    for i = 1, math.min(#l, 6) do
        parts[#parts + 1] = string.format("%d dmg x%d", l[i].d, l[i].n)
    end
    log("hits=%d  damage seen: %s", #hits, table.concat(parts, ", "))
    -- the 64-damage ones are Big Power; report the pose they leave
    local poses = {}
    for _, h in ipairs(hits) do
        if h.d == 64 then
            poses[h.v] = (poses[h.v] or 0) + 1
        end
    end
    local pp = {}
    for a, n in pairs(poses) do
        pp[#pp + 1] = string.format("%04xh x%d", a, n)
    end
    log("big power (64 dmg) victim poses: %s",
        (#pp > 0) and table.concat(pp, " ") or "none seen")
    local l2 = {}
    for a, n in pairs(kacts) do l2[#l2 + 1] = { a = a, n = n } end
    table.sort(l2, function(x, y) return x.n > y.n end)
    local kp = {}
    for i = 1, math.min(#l2, 8) do
        kp[#kp + 1] = string.format("%04xh:%d", l2[i].a, l2[i].n)
    end
    log("kahn actions: %s", table.concat(kp, " "))
    log("player hp low-water: %d of %d", hpmin, MAX_HP)
    log("run_end")
end)
