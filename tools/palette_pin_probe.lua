-- palette_pin_probe.lua
--
-- Boot smoke test + proof that foreground colour map #0 stays pinned to
-- boonpal.  The strength bars (bpal_bar_color) and the player shadows
-- (bpal_black, shadow_p1p2) are drawn out of palette #0 by NUMBER, so if
-- fpalram slot 0 ever stops being boonpal the bars and shadows go the wrong
-- colour.
--
-- Dumps the first few foreground palette allocation records once a second
-- and flags any frame where slot 0's id is not boonpal.
--
-- NOTE on addressing: MAME's TMS34010 program space is bit-addressed, so
-- the raw mk2.map values and the raw MAINEQU bit offsets (palrsiz 040h,
-- palcnt 020h) go straight into space:read_*, exactly like
-- kahn_boss_moves_test.lua does.  Do NOT divide by 8 here.

local ROOT = os.getenv("PAL_PROBE_ROOT") or "C:/Users/you/Workplace/mk2-main"
local LOG = io.open(ROOT .. "/tools/palette_pin_probe.log", "w")
local RUN_FRAMES = tonumber(os.getenv("PAL_PROBE_FRAMES") or "1800") or 1800

local function log(s) LOG:write(s .. "\n"); LOG:flush() end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(name, fallback)
    if symbols[name] then return symbols[name] end
    log(string.format("[pal-probe] WARN missing map symbol %s; using 0x%08x", name, fallback))
    return fallback
end

local FPALRAM = sym("fpalram", 0x010e8770)
local BOONPAL = sym("boonpal", 0xffbd7bd0)
local PALRSIZ = 0x40                       -- MAINEQU palrsiz
local PALCNT  = 0x20                       -- MAINEQU palcnt
local SLOTS   = 8

local space
local frame, bad_frames, first_bad, claimed_frame = 0, 0, nil, nil

log(string.format("[pal-probe] started fpalram=0x%08x boonpal=0x%08x", FPALRAM, BOONPAL))

emu.register_frame(function()
    if not space then
        local cpu = manager.machine.devices[":maincpu"]
        if not cpu then return end
        space = cpu.spaces["program"]
        if not space then return end
        log("[pal-probe] attached to maincpu")
    end

    frame = frame + 1

    local id0 = space:read_u32(FPALRAM)
    if id0 == BOONPAL then
        if not claimed_frame then
            claimed_frame = frame
            log(string.format("[pal-probe] slot 0 claimed by boonpal at frame=%d", frame))
        end
    elseif claimed_frame then
        -- only a problem once the pin has been established
        bad_frames = bad_frames + 1
        if not first_bad then
            first_bad = frame
            log(string.format("[pal-probe] SLOT0 STOLEN frame=%d id=0x%08x (want boonpal 0x%08x)",
                frame, id0, BOONPAL))
        end
    end

    if frame % 120 == 0 then
        local parts = {}
        for i = 0, SLOTS - 1 do
            local base = FPALRAM + i * PALRSIZ
            parts[#parts + 1] = string.format("%d:%08x/%d",
                i, space:read_u32(base), space:read_u16(base + PALCNT))
        end
        log(string.format("[pal-probe] frame=%d %s", frame, table.concat(parts, " ")))
    end

    if frame >= RUN_FRAMES then
        if not claimed_frame then
            log("[pal-probe] FAIL - boonpal never took colour map 0")
        elseif bad_frames == 0 then
            log(string.format("[pal-probe] PASS - slot 0 held boonpal from frame %d to %d",
                claimed_frame, frame))
        else
            log(string.format("[pal-probe] FAIL - slot 0 lost boonpal on %d frames (first at %d)",
                bad_frames, first_bad))
        end
        log("[pal-probe] finished")
        LOG:close()
        manager.machine:exit()
    end
end)
