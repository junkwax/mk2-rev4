-- sweep_addon_stress.lua - frame time under LOAD, per stage.
--
-- The existing perf probe measured two fighters trading punches and reported
-- overload = 2 on essentially every frame.  That is a real result but it is
-- the easy case: no projectiles, no blood volume, a quiet stage.  "We cannot
-- lose any ticks or frames" has to be tested where ticks would actually be
-- lost.
--
-- So: P1 spams Liu Kang's high fireball (scom_lk_zaphi, Forward Forward + HP)
-- on a tight cycle while the P2 drone fights back, both bars refilled every
-- frame so the round never ends and the pressure never lets up.  Projectiles,
-- their impacts, the blood they cause and the drone's own answers all stack
-- on top of whatever the stage costs.
--
-- What is read:
--   overload      - prcdsp smooths (overload + 2*timer)/2.  2 = the process
--                   pass finished inside its tick.  ANY sample above 2 is a
--                   lost tick, so the histogram matters more than the mean.
--   peak_overload - the ROM's own high-water mark, zeroed here at fight start
--                   so each battle reports its own number, not the boot's.
--   qdma_drops    - sprites SILENTLY discarded because the DMA queue was
--                   full.  A non-zero value is dropped picture, not just
--                   dropped time, and nothing on screen says it happened.
--   object count  - how close the object list gets to its limit.
--
-- STRESS_COLBOX sets f_colbox for the run.  0 (default) measures the game;
-- 5 measures the game with the hitbox overlay on, which is the only honest
-- way to say what the overlay costs.  Never measure with bit 4 (per-piece):
-- it is known to take peak_overload from 4 to 35 and it changes the fight.
--
-- Run: rename to sweep_addon.lua and run the whole sweep - one line per stage.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT = ROOT .. "/tools/stress_load.txt"
local LABEL = os.getenv("SWEEP_LABEL") or "battle"
local COLBOX = tonumber(os.getenv("STRESS_COLBOX") or "0")

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
local overload, peak, qdma = S("overload"), S("peak_overload"), S("qdma_drops")
local p1_obj, p2_obj = S("p1_obj"), S("p2_obj")
local p1_proc = S("p1_proc")
local p1_bar, p2_bar = S("p1_bar"), S("p2_bar")
local objlst = S("objlst")
local f_colbox = S("f_colbox")
local winner_status = S("winner_status")
if not (gstate and overload and p1_obj) then
    print("[stress] symbols missing - addon disabled"); return
end

local O = { next = 0, oxval = 0x080, oxpos = 0x090 }
local MAX_HP = 0xa1
local OBSERVE = tonumber(os.getenv("SWEEP_OBSERVE") or "900")

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[stress] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0 = nil, 0, 0
local fields = {}
local hist, samples, worst = {}, 0, 0
local over2 = 0
local objmax, objbase, objbursts = 0, nil, 0
local done = false
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

-- Bounded, like every other list walk in this project: an object list caught
-- mid-edit by a probe that loops until it sees zero hangs MAME instead of
-- reporting a number.
local function count_objs()
    if not objlst then return 0 end
    local n, p = 0, space:read_u32(objlst)
    while p ~= 0 and n < 300 do
        n = n + 1
        p = space:read_u32(p + O.next)
    end
    return n
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if next(fields) == nil then
        local want = { ["P1 High Punch"] = true, ["P1 Right"] = true,
                       ["P1 Left"] = true, ["P1 High Kick"] = true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fields[fd.name] = fd end
            end
        end
    end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 == 0 or o2 == 0 then return end
    if fight0 == 0 then
        fight0 = frame
        if f_colbox then space:write_u16(f_colbox, COLBOX) end
        -- zero the ROM's own high-water marks so this battle reports itself
        if peak then space:write_u16(peak, 0) end
        if qdma then space:write_u16(qdma, 0) end
        log("=== %s === colbox=%d", LABEL, COLBOX)
    end
    local rel = frame - fight0
    if done then return end

    -- nobody is allowed to die: the pressure has to run the whole window
    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)
    if winner_status then space:write_u16(winner_status, 0) end

    if rel < 45 then return end
    if objbase == nil then objbase = count_objs() end

    -- Forward, Forward + HP.  The taps have to be separated by a release or
    -- the queue sees one long hold and the combo never matches.
    local ph = rel % 46
    local right = (ph < 4) or (ph >= 7 and ph < 11)
    local hp    = (ph >= 12 and ph < 15)
    local hk    = (ph >= 26 and ph < 31)      -- something landing, for blood
    for n, fd in pairs(fields) do
        local on = (n == "P1 Right" and right)
                or (n == "P1 High Punch" and hp)
                or (n == "P1 High Kick" and hk)
        fd:set_value(on and 1 or 0)
    end

    local ov = space:read_u16(overload)
    hist[ov] = (hist[ov] or 0) + 1
    samples = samples + 1
    if ov > worst then worst = ov end
    if ov > 2 then over2 = over2 + 1 end

    local no = count_objs()
    if no > objmax then objmax = no end
    if objbase and no > objbase + 1 then objbursts = objbursts + 1 end

    if rel >= OBSERVE then
        done = true
        local keys = {}
        for k in pairs(hist) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = string.format("%d:%.1f%%", k,
                                              100 * hist[k] / samples)
        end
        log("%-22s colbox=%d  overload %s", LABEL, COLBOX,
            table.concat(parts, " "))
        log("%-22s worst=%d peak_overload=%s lost_ticks=%d/%d (%.2f%%) qdma_drops=%s",
            LABEL, worst, peak and space:read_u16(peak) or "?",
            over2, samples, 100 * over2 / samples,
            qdma and space:read_u16(qdma) or "?")
        log("%-22s objects base=%s max=%d  frames above base+1=%d %s",
            LABEL, tostring(objbase), objmax, objbursts,
            objbursts < samples / 20
                and "<-- LOAD GENERATOR BARELY FIRED, result is weak"
                or "")
    end
end)
