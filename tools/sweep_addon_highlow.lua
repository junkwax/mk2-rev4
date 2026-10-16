-- sweep_addon_highlow.lua - does ducking actually clear a high attack?
--
-- Section 3.1 of doc/TOURNAMENT_READINESS.md claims the mixup game is not
-- real: the hurt box is the victim's bounding box squeezed horizontally to a
-- quarter and NOT squeezed vertically at all, so ducking only works where the
-- bounding-box top happens to fall below the strike box.
--
-- That is a geometric argument, and it is worth testing rather than repeating.
-- Hit or miss is the ground truth and needs no box reading: park the victim at
-- a distance the attack certainly reaches, then run the same attack against
-- him STANDING and DUCKING and compare.
--
--   standing hits, ducking misses  -> high/low works for this move
--   both hit                       -> ducking does not clear it, 3.1 confirmed
--   neither hits                   -> the rig is out of range, result void
--
-- HIGHLOW_ATTACK=hikick|roundhouse   which high attack P1 throws
-- HIGHLOW_TAG=...                    output tag

local ROOT = "C:/Users/you/Workplace/mk2-main"
local ATTACK = (os.getenv("HIGHLOW_ATTACK") or "hikick"):lower()
local TAG = os.getenv("HIGHLOW_TAG") or "run"
local OUT = ROOT .. "/tools/highlow.txt"

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
local worldtlx = S("worldtlx")
if not (gstate and p1_proc and worldtlx) then
    print("[highlow] symbols missing - addon disabled"); return
end

local P = { action = 0x1f0 }
local O = { oxval = 0x080, oxpos = 0x090, oypos = 0x0b0 }
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
local WANT = (ATTACK == "roundhouse") and acts.act_rhouse or acts.act_hikick
local ACT_DUCK = acts.act_duck

-- Distances chosen inside the high kick's measured band (16..90 for Baraka),
-- well clear of both edges so a miss means the DUCK cleared it and not that
-- the rig stood in the wrong place.
local DISTS = { 40, 50, 60, 70, 80 }
local TRIAL = 100

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[highlow] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0, vx0 = nil, 0, 0, nil
local fields = {}
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

-- trial order: every distance standing, then every distance ducking
local trials = {}
for _, d in ipairs(DISTS) do trials[#trials + 1] = { d = d, duck = false } end
for _, d in ipairs(DISTS) do trials[#trials + 1] = { d = d, duck = true } end

local ti, t0, cur = 1, nil, nil
local rows = {}

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if next(fields) == nil then
        local want = { ["P1 High Kick"] = true, ["P1 Left"] = true,
                       ["P2 Down"] = true }
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
        log("=== high/low: %s vs a standing and a ducking victim ===", ATTACK)
    end
    if frame - fight0 < 60 then return end
    if ti > #trials then return end
    local tr = trials[ti]

    if vx0 == nil then vx0 = s16(space:read_u16(worldtlx + 16)) + 250 end
    space:write_u32(o2 + O.oxval, (vx0 << 16) & 0xffffffff)
    space:write_u16(o2 + O.oxpos, vx0)
    local ax = vx0 - tr.d
    space:write_u32(o1 + O.oxval, (ax << 16) & 0xffffffff)
    space:write_u16(o1 + O.oxpos, ax)

    if t0 == nil then
        t0 = frame
        cur = { fired = false, hit = false, ducked = 0, ytop = nil }
        space:write_u16(p1_bar, MAX_HP)
        space:write_u16(p2_bar, MAX_HP)
    end
    local t = frame - t0

    -- victim holds Down for the whole trial in duck mode; attacker throws the
    -- attack once, late enough that the crouch is fully established
    local away = (ATTACK == "roundhouse") and (t >= 26 and t < 36) or false
    for n, fd in pairs(fields) do
        local on = (n == "P2 Down" and tr.duck)
                or (n == "P1 Left" and away)
                or (n == "P1 High Kick" and t >= 30 and t < 33)
        fd:set_value(on and 1 or 0)
    end

    if space:read_u16(r1 + P.action) == WANT then cur.fired = true end
    if ACT_DUCK and space:read_u16(r2 + P.action) == ACT_DUCK then
        cur.ducked = cur.ducked + 1
    end
    if space:read_u16(p2_bar) < MAX_HP then cur.hit = true end
    local y = s16(space:read_u16(o2 + O.oypos))
    if cur.ytop == nil or y > cur.ytop then cur.ytop = y end

    if t >= TRIAL then
        rows[#rows + 1] = { d = tr.d, duck = tr.duck, fired = cur.fired,
                            hit = cur.hit, ducked = cur.ducked, y = cur.ytop }
        ti = ti + 1
        t0 = nil
    end
end)

emu.register_stop(function()
    if #rows == 0 then log("no trials ran"); return end
    local function show(duck)
        local line, mis, hits = {}, 0, 0
        for _, r in ipairs(rows) do
            if r.duck == duck then
                if not r.fired then mis = mis + 1 end
                if r.hit then hits = hits + 1 end
                line[#line + 1] = string.format("%d:%s", r.d,
                    (not r.fired) and "?" or (r.hit and "H" or "."))
            end
        end
        return table.concat(line, " "), mis, hits, #line
    end
    local sl, sm, sh, sn = show(false)
    local dl, dm, dh, dn = show(true)
    local ducked = 0
    for _, r in ipairs(rows) do if r.duck then ducked = ducked + r.ducked end end
    log("%-10s standing  %s   (%d/%d connected, %d never fired)", TAG, sl, sh, sn, sm)
    log("%-10s ducking   %s   (%d/%d connected, %d never fired)", TAG, dl, dh, dn, dm)
    log("%-10s victim spent %d frames in act_duck across the ducking trials",
        TAG, ducked)
    if ducked < 100 then
        log("%-10s VERDICT: he never actually crouched - result void", TAG)
    elseif sm + dm > (sn + dn) / 4 then
        log("%-10s VERDICT: the attack often did not fire - result void", TAG)
    elseif sh > 0 and dh == 0 then
        log("%-10s VERDICT: ducking CLEARS the %s - high/low works here",
            TAG, ATTACK)
    elseif sh > 0 and dh == sh then
        log("%-10s VERDICT: ducking does NOT clear it - 3.1 confirmed for %s",
            TAG, ATTACK)
    else
        log("%-10s VERDICT: partial - standing %d, ducking %d of %d",
            TAG, sh, dh, sn)
    end
end)
