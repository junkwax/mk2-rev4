-- sweep_addon_palpool.lua - how close does the FOREGROUND palette pool get to
-- running out, and does it ever actually run out?
--
-- Why this exists: a beta report said "sub-zero froze me and I did not turn ice
-- coloured".  The ice colour is player_froze_pal -> swpal -> getfpal, and
-- getfpal's only failure mode is "no foreground colour map free".  swpal used
-- to `ermac 8` (a hard spin) on that; it now returns quietly and KEEPS the
-- palette the object already has, which is exactly what "he never turned blue"
-- looks like.  So the question is not whether the swap is coded right, it is
-- whether the pool is empty when the freeze asks.
--
-- fpalram is nmfpal records of palrsiz bits:
--     +0x00  32  palette id (0 = slot never claimed)
--     +0x20  16  palcnt   - allocation count, 0 = free
--     +0x30  16  paltime  - @tick it was released (a slot released THIS tick
--                           is skipped by getfpal, so "free" is not the same
--                           as "available")
--
-- Passive.  Reads only.  Nothing here drives an input or writes memory, so it
-- can ride along with any other rig.
--
-- Output: tools/palpool_<tag>.txt   (PALPOOL_TAG, default "run")

local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG  = os.getenv("PALPOOL_TAG") or "run"
local OUT  = ROOT .. "/tools/palpool_" .. TAG .. ".txt"

-- ---- equates, kept in step with src/MAINEQU.ASM ------------------------
local NMFPAL  = 35      -- nmfpal
local PALRSIZ = 0x40    -- palrsiz
local PALCNT  = 0x20    -- palcnt
local PALTIME = 0x30    -- paltime

local sym = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if not fh then print("[palpool] no mk2.map"); return end
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            sym[n] = tonumber(a, 16)
        end
    end
    fh:close()
end

local fpalram, gstate, tickaddr = sym.fpalram, sym.gstate, sym.tick
if not (fpalram and gstate) then print("[palpool] symbols missing"); return end

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[palpool] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame = nil, 0
local peak_used, full_frames, samples, sum_used = 0, 0, 0, 0
local reported = false

-- A slot getfpal could actually hand out right now: palcnt 0 AND not released
-- on this very tick.  That second half is the difference between "free" and
-- "available" and it is why a swap can fail with the pool showing spare slots.
local function census()
    local used, available = 0, 0
    local tick = tickaddr and (space:read_u16(tickaddr) & 0xffff) or -1
    for i = 0, NMFPAL - 1 do
        local base = fpalram + i * PALRSIZ
        local cnt  = space:read_u16(base + PALCNT) & 0xffff
        if cnt ~= 0 then
            used = used + 1
        else
            local pt = space:read_u16(base + PALTIME) & 0xffff
            if pt == 0 or pt ~= tick then available = available + 1 end
        end
    end
    return used, available
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if space:read_u16(gstate) ~= 2 then return end   -- only during a fight

    if frame % 6 ~= 0 then return end                -- ~9 Hz is plenty
    local used, available = census()
    samples  = samples + 1
    sum_used = sum_used + used
    if used > peak_used then peak_used = used end
    if available == 0 then
        full_frames = full_frames + 1
        if not reported then
            log("POOL EXHAUSTED at frame %d - %d/%d in use, 0 available",
                frame, used, NMFPAL)
            reported = true
        end
    end
end)

emu.register_stop(function()
    if samples == 0 then log("no fight samples"); return end
    log("=== palpool === samples %d  peak_used %d/%d  mean_used %.1f  exhausted_samples %d (%.1f%%)",
        samples, peak_used, NMFPAL, sum_used / samples,
        full_frames, 100.0 * full_frames / samples)
    log("run_end")
end)
