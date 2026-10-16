-- hud_perf_probe.lua - what does the CPU text pass cost?
--
-- doc/UNUSED_GRAPHICS_PRIMITIVES.md says to watch `peak_overload` (audit page
-- 3, PEAK FRAME LOAD) before and after anything that spends CPU inside the
-- tick.  It is a high-water mark latched by prcdsp (MPROC.ASM): 2 means every
-- process pass finished inside its tick, and the f_colbox per-piece layer is
-- known to take it from 4 to 35.
--
-- Run this against a build with hudtest=1 and again with hudtest=0 (hud_pass
-- still linked, just never given anything to draw) to separate the cost of
-- the drawing from the cost of merely having the pass in the loop.
--
-- peak_overload is a HIGH-WATER MARK, so it is reset here at the start of the
-- measurement window - otherwise it reports whatever boot or character select
-- happened to peak at and the fight's number never shows.

local LOGP = os.getenv("HUD_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/hud_perf_probe.log"
local TAG = os.getenv("HUD_TAG") or "run"
local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = string.format("[perf %s] ", TAG) .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), f_freeze_timer = sym("f_freeze_timer"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    peak_overload = sym("peak_overload"), qdma_drops = sym("qdma_drops"),
    hud_ran = sym("hud_ran"), hud_drew = sym("hud_drew"),
}

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local MEASURE = tonumber(os.getenv("HUD_MEASURE") or "") or 900  -- ~16 s at 54.7 Hz
local fields, done = {}, false

-- The warning-screen dismisser needs a "we are past the red screen" signal,
-- and it cannot be this script's log: that is opened at script LOAD, before a
-- single frame runs.  Written from the frame callback instead.
local READY_PATH = os.getenv("HUD_READY")
local ready_written = false

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v) end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 60
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"]=true, ["2 Players Start"]=true, ["P1 High Punch"]=true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if want[f.name] then fields[f.name] = f end
            end
        end
        log("peak_overload=%08x qdma_drops=%08x", A.peak_overload, A.qdma_drops)
    end
    if READY_PATH and not ready_written and frame >= 120 then
        local fh = io.open(READY_PATH, "w")
        if fh then fh:write("running"); fh:close(); ready_written = true end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == 4 and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, 1);  w16(A.p2_char, 1)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == 2 and fighting_frame == 0 then
        fighting_frame = frame
        w16(A.peak_overload, 0)         -- reset the high-water mark
        if A.qdma_drops ~= 0 then w16(A.qdma_drops, 0) end
        log("fight at frame %d - high-water marks reset", frame)
    end
    if fighting_frame == 0 then
        if frame > 8000 then log("ERROR never reached fight"); manager.machine:exit() end
        return
    end

    -- keep the round alive so the whole window is real fight time
    w16(A.p1_bar, 161); w16(A.p1_bar_view, 161)
    w16(A.p2_bar, 161); w16(A.p2_bar_view, 161)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end

    local rel = frame - fighting_frame
    if rel % 300 == 0 and rel > 0 and rel <= MEASURE then
        log("  t+%4d  peak_overload=%d qdma_drops=%d hud_ran=%d hud_drew=%d",
            rel, r16(A.peak_overload), r16(A.qdma_drops),
            r16(A.hud_ran), r16(A.hud_drew))
    end
    if rel >= MEASURE and not done then
        done = true
        log("RESULT peak_overload=%d qdma_drops=%d over %d fight frames (hud_drew=%d)",
            r16(A.peak_overload), r16(A.qdma_drops), MEASURE, r16(A.hud_drew))
        manager.machine:exit()
    end
    if frame > 30000 then manager.machine:exit() end
end)
