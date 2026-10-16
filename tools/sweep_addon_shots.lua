-- sweep_addon_shots.lua - paired before/after screenshots with the box overlay.
--
-- For showing the collision work rather than describing it.  Same pinned
-- distance, same move, same tick, only the build differs - so a pair of images
-- differs ONLY by the change under discussion.
--
-- SHOTS_MODE=swipe   Baraka's Back+HP.  The headline: on the BEFORE build the
--                    strike box is live while the blade is already back, so
--                    the red rectangle floats in empty air in front of him.
--                    On AFTER it sits on the blade.
-- SHOTS_MODE=drift   The hurt column on a victim with a limb extended.  BEFORE
--                    centres it on the SILHOUETTE, so an extended leg drags it
--                    off the torso; AFTER anchors it on the anipoint.
--
-- SHOTS_MASK   f_colbox value, default 7 = hitbox(red) + silhouette(green)
--              + hurtbox(white).  Never 18 here: bit 4 costs enough frame time
--              to change the fight, which would make the pair incomparable.
--
-- MAME numbers snapshots in the order they are taken, and the sweep harness
-- takes one of its own at fight_start, so this logs every shot it fires with
-- the tick and the geometry.  Match images to captions by that log, not by
-- guessing.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MODE = (os.getenv("SHOTS_MODE") or "swipe"):lower()
local MASK = tonumber(os.getenv("SHOTS_MASK") or "7")
local TAG = os.getenv("SHOTS_TAG") or "run"
local OUT = ROOT .. "/tools/shots_" .. TAG .. ".txt"

local sym = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                sym[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local S = function(n) return sym[n] end
local gstate = S("gstate")
local p1_obj, p2_obj = S("p1_obj"), S("p2_obj")
local p1_proc, p2_proc = S("p1_proc"), S("p2_proc")
local p1_bar, p2_bar = S("p1_bar"), S("p2_bar")
local right_edge, f_colbox = S("right_edge"), S("f_colbox")
local worldtlx = S("worldtlx")
if not (gstate and p1_proc and right_edge and f_colbox) then
    print("[shots] symbols missing - addon disabled"); return
end

local P = { action = 0x1f0 }
local O = { oxval = 0x080, oxpos = 0x090, oimg = 0x1a0 }
local MP = { sag = 0, xsize = 32, dx = 80, stride = 112, max = 13 }
local MAX_HP = 0xa1

local acts = {}
do
    local fh = io.open(ROOT .. "/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n, v = line:match("^(act_[%w_]+)%s+%.set%s+(%x+)h")
            if n and v then acts[n] = tonumber(v, 16) end
        end
        fh:close()
    end
end
local ACT_SWIPE, ACT_RHOUSE = acts.act_swipe, acts.act_rhouse
local ACT_HIKICK, ACT_STANCE = acts.act_hikick, acts.act_stance

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[shots] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0 = nil, 0, 0
local vx0 = nil
local fields = {}
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local function span(obj)
    local img = space:read_u32(obj + O.oimg)
    if img == 0 or img < 0x01000000 or img >= 0x01400000 then return nil end
    local ox = s16(space:read_u16(obj + O.oxpos))
    local l, r, n = 30000, -30000, 0
    for i = 0, MP.max - 1 do
        local rec = img + i * MP.stride
        if space:read_u32(rec + MP.sag) == 0 then break end
        local xs = s16(space:read_u16(rec + MP.xsize))
        local dx = s16(space:read_u16(rec + MP.dx))
        local pl = ox - dx
        if pl < l then l = pl end
        if pl + xs > r then r = pl + xs end
        n = n + 1
    end
    if n == 0 then return nil end
    return l - ox, r - ox, n
end

local function screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    for _, s2 in pairs(manager.machine.screens) do return s2 end
end

local shot_n = 0
local function shoot(note)
    local s = screen()
    if not s then return end
    pcall(function() s:snapshot() end)
    shot_n = shot_n + 1
    log("shot %02d  %s", shot_n, note)
end

-- The frame buffer is double buffered, so what a snapshot captures is the
-- page that finished LAST tick.  Everything below is therefore queued one
-- frame and fired on the next - a capture taken on the frame the state is
-- read is a picture of the previous pose.
local pending = nil

local DIST = (MODE == "drift") and 96 or 70
local CYCLE = 46

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if next(fields) == nil then
        local want = { ["P1 High Punch"] = true, ["P1 High Kick"] = true,
                       ["P1 Left"] = true, ["P2 Right"] = true,
                       ["P2 High Kick"] = true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fields[fd.name] = fd end
            end
        end
    end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r1 == 0 or r2 == 0 then return end
    if fight0 == 0 then
        fight0 = frame
        log("=== shots tag=%s mode=%s mask=%d dist=%d ===", TAG, MODE, MASK, DIST)
    end
    if pending then
        shoot(pending)
        pending = nil
    end
    local rel = frame - fight0
    if rel < 60 then return end
    space:write_u16(f_colbox, MASK)
    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)

    -- PIN WHERE THE CAMERA CAN SEE THEM.  right_edge + 300 is a legal world
    -- position but well outside the scroll clamp, so the fighters sat off
    -- screen and every screenshot came back as an empty stage (the sweep
    -- harness flagged it as level_out_of_scope and I read past it).  Take the
    -- position from worldtlx ONCE and then hold it, so the camera settles on
    -- them instead of chasing a target that moves with it.
    if vx0 == nil then
        vx0 = s16(space:read_u16(worldtlx + 16)) + 250
    end
    local vx = vx0
    space:write_u32(o2 + O.oxval, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + O.oxpos, vx)
    local ax = vx - DIST
    space:write_u32(o1 + O.oxval, (ax << 16) & 0xffffffff)
    space:write_u16(o1 + O.oxpos, ax)

    local ph = rel % CYCLE
    local a1 = space:read_u16(r1 + P.action)
    local a2 = space:read_u16(r2 + P.action)

    if MODE == "drift" then
        -- victim throws a roundhouse (he is on the right, so away = Right);
        -- attacker jabs continuously so a strike check - and therefore a hurt
        -- box - exists while the victim's leg is out
        for n, fd in pairs(fields) do
            local on = (n == "P2 Right" and ph >= 2 and ph < 12)
                    or (n == "P2 High Kick" and ph >= 6 and ph < 9)
                    or (n == "P1 High Kick" and (ph % 12) >= 2 and (ph % 12) < 5)
            fd:set_value(on and 1 or 0)
        end
        if a2 == ACT_RHOUSE and a1 == ACT_HIKICK and shot_n < 10 then
            local l, r = span(o2)
            pending = string.format("drift  victim act_rhouse span %+d..%+d  p1 hikick",
                                    l or 0, r or 0)
        end
    else
        for n, fd in pairs(fields) do
            local on = (n == "P1 Left" and ph >= 5 and ph < 14)
                    or (n == "P1 High Punch" and ph >= 8 and ph < 11)
            fd:set_value(on and 1 or 0)
        end
        -- one shot per tick of the swipe, so the pair can be matched tick for
        -- tick between the two builds
        if a1 == ACT_SWIPE and shot_n < 22 then
            local l, r, n = span(o1)
            if l then
                pending = string.format(
                    "swipe  ph=%02d  attacker span %+4d..%+4d (%d pieces)",
                    ph, l, r, n)
            end
        end
    end
end)

emu.register_stop(function()
    log("%d shots taken (MAME numbers them in this order, after the harness's "
        .. "own fight_start snapshot)", shot_n)
end)
