-- sweep_addon_chip.lua - can blocked damage take the last point of health?
--
-- The corner rig could not answer this: it reports total HP lost, which mixes
-- chip with clean hits, so `chipfloor` on and off produced identical numbers
-- and told me nothing. This asks the question directly.
--
-- Hold the victim on a SMALL amount of health and make him block. Then the
-- only thing that matters is the minimum his bar ever reaches:
--
--   chipfloor 0 (retail)  -> chip takes the last point, bar reaches 0
--   chipfloor 1           -> chip stops at 1, bar never reaches 0
--
-- The victim is topped back up to CHIP_HP every time he is on his feet and not
-- currently being hit, so the test repeats for the whole window instead of
-- ending at the first death.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT = ROOT .. "/tools/chip_floor.txt"
local TAG = os.getenv("CHIP_TAG") or "run"
local CHIP_HP = tonumber(os.getenv("CHIP_HP") or "6")

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
local worldtlx, winner_status = S("worldtlx"), S("winner_status")
if not (gstate and p1_proc and worldtlx) then
    print("[chip] symbols missing - addon disabled"); return
end

local P = { action = 0x1f0 }
local O = { oxval = 0x080, oxpos = 0x090 }
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
local ACT_BLOCKHI, ACT_BLOCKLO = acts.act_blockhi, acts.act_blocklo

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[chip] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0, vx0 = nil, 0, 0, nil
local fields = {}
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local minhp, blocked_frames, topups, zero_frames = 999, 0, 0, 0

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
                       ["P2 Block"] = true }
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
        log("=== chip floor test, tag=%s, victim held on %d HP ===", TAG, CHIP_HP)
    end
    local rel = frame - fight0
    if rel < 45 then return end
    if winner_status then space:write_u16(winner_status, 0) end
    space:write_u16(p1_bar, MAX_HP)

    if vx0 == nil then vx0 = s16(space:read_u16(worldtlx + 16)) + 250 end
    space:write_u32(o2 + O.oxval, (vx0 << 16) & 0xffffffff)
    space:write_u16(o2 + O.oxpos, vx0)
    local ax = vx0 - 70
    space:write_u32(o1 + O.oxval, (ax << 16) & 0xffffffff)
    space:write_u16(o1 + O.oxpos, ax)

    local hp = space:read_u16(p2_bar)
    if hp < minhp then minhp = hp end
    if hp == 0 then zero_frames = zero_frames + 1 end

    local a2 = space:read_u16(r2 + P.action)
    if a2 == ACT_BLOCKHI or a2 == ACT_BLOCKLO then
        blocked_frames = blocked_frames + 1
    end

    -- top him back up whenever he is at or below the floor, so the question is
    -- asked many times rather than once
    if hp <= 1 then
        space:write_u16(p2_bar, CHIP_HP)
        topups = topups + 1
    end

    -- attacker roundhouses on a loop; victim holds block
    local ph = rel % 22
    for n, fd in pairs(fields) do
        local on = (n == "P1 Left" and ph >= 16)
                or (n == "P1 High Kick" and ph >= 18 and ph <= 20)
                or (n == "P2 Block")
        fd:set_value(on and 1 or 0)
    end
end)

emu.register_stop(function()
    log("%-10s victim blocked %d frames, topped up %d times", TAG,
        blocked_frames, topups)
    log("%-10s MINIMUM HP reached = %d   (frames spent on zero = %d)",
        TAG, minhp, zero_frames)
    if blocked_frames < 100 then
        log("%-10s VERDICT: he barely blocked - the test did not run", TAG)
    elseif minhp == 0 then
        log("%-10s VERDICT: chip took the last point - chip CAN kill", TAG)
    else
        log("%-10s VERDICT: chip stopped at %d - chip cannot kill", TAG, minhp)
    end
end)
