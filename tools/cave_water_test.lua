-- cave_water_test.lua - THE CAVE's rippling water (mk3cave_water, MK3CAVE.ASM).
--
-- mk3cave_water redraws the cavern's water band one scanline at a time, over
-- the plain blocks, from the blocks' own ROM rows.  This rig proves it draws
-- the RIGHT rows in the right place, then measures what it costs.
--
-- FREEZE  every process frozen (tick still runs, so the rig uses the fixed
--         modes of f_cwater, which ignore the wave table):
--           off_a, off_b   f_cwater 1 - the plain water, twice (scene still)
--           rows_0         mode 2, every line at 0      (== off, exactly)
--           rows_p/_m      mode 2, every line +/-SHIFT
--           rows_alt       mode 3, even +SHIFT / odd -SHIFT
--           wave_NN        mode 0, the real ripple, tick pinned to NN*2
--         tools/cave_water_compare.py checks them.
-- LIVE    the fight runs LIVE_N frames: cw_ran / cw_short / cw_lines, the
--         process-pass overload and the DMA queue counters.  CW_OFF=1 holds
--         f_cwater = 1 for the A/B.  Snapshots every GIF_GAP frames.
--
-- env: MK2_ROOT, CW_OFF, CW_PARK (fighters' x, e.g. -200 for the skull pile),
--      CW_LOG, CW_P1, CW_P2
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local OFF = os.getenv("CW_OFF") == "1"
local PARK = tonumber(os.getenv("CW_PARK") or "")
local P1 = tonumber(os.getenv("CW_P1") or "1")
local P2 = tonumber(os.getenv("CW_P2") or "11")
local STAGE = 0x19
local LOG = os.getenv("CW_LOG") or (ROOT .. "/tools/cave_water_test.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[cwater] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local S = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[n] = tonumber(a, 16) end
end
local function sym(n) return assert(S[n], "missing map symbol " .. n) end

local A = {}
for _, n in ipairs({ "gstate", "curback", "map_position", "battle_num", "p1_char", "p2_char",
    "p1_state", "p2_state", "p1_bar", "p2_bar", "p1_bar_view", "p2_bar_view", "winner_status",
    "p1_obj", "p2_obj", "f_cwater", "cw_fixdx", "cw_ran", "cw_short", "cw_lines", "overload",
    "dmaq_late", "dmaq_lost", "dmaq_over", "deep_dmaq", "active", "tick", "worldtly",
    "worldtlx3" }) do A[n] = sym(n) end

local GS_PSEL, GS_FIGHTING, MAXBAR = 4, 2, 0xa1
local O_OXVAL = 0x080
local P_NEXT, P_TIME = 0x000, 0x030
local LIVE_AT, LIVE_N, GIF_GAP, GIF_SHOTS = 150, 360, 2, 64
local SETTLE, SHIFT = 6, 2

local frame, space, fields = 0, nil, {}
local charsel, fighting, confirm = 0, 0, 0
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["2 Players Start"] = true,
                   ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function pressed(name)
    if charsel == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting == 0 then
        return (name == "P1 High Punch" or name == "P2 High Punch") and confirm > 0
               and frame >= confirm and frame < confirm + 40
    end
    return false
end

local function finish(verdict)
    if finished then return end
    finished = true
    log("RESULT %s", verdict)
    manager.machine:exit()
end

local snaps = 0
local function snap(label)
    manager.machine.video:snapshot()
    log("SNAP %04d %s camx=%d camy=%d", snaps, label, s16(r32(A.worldtlx3) >> 16), s16(r32(A.worldtly) >> 16))
    snaps = snaps + 1
end

-- ---------------------------------------------------------------- live
local L = { frames = 0, over_max = 0, lost_max = 0, lines_min = 1e9, lines_max = 0 }
local function live_frame(rel)
    if OFF then w16(A.f_cwater, 1) end
    if rel == 0 then
        L.ran0, L.short0 = r16(A.cw_ran), r16(A.cw_short)
        L.late0, L.over0 = r16(A.dmaq_late), r16(A.dmaq_over)
        log("LIVE start off=%s", tostring(OFF))
    end
    L.frames = L.frames + 1
    local n = r16(A.cw_lines)
    if n < L.lines_min then L.lines_min = n end
    if n > L.lines_max then L.lines_max = n end
    local ov = r16(A.overload); if ov > L.over_max then L.over_max = ov end
    local lost = r16(A.dmaq_lost); if lost > L.lost_max then L.lost_max = lost end
    if rel % GIF_GAP == 0 and rel // GIF_GAP < GIF_SHOTS then snap(string.format("live rel=%d", rel)) end
end
local function live_report()
    log("LIVE frames=%d ran=+%d short=+%d blits=%d..%d overload_max=%d "
        .. "dmaq_late=+%d dmaq_over=+%d dmaq_lost_max=%d deep_dmaq=%d cells",
        L.frames, r16(A.cw_ran) - L.ran0, r16(A.cw_short) - L.short0,
        L.lines_min == 1e9 and 0 or L.lines_min, L.lines_max, L.over_max,
        r16(A.dmaq_late) - L.late0, r16(A.dmaq_over) - L.over0, L.lost_max,
        r16(A.deep_dmaq) // 6)
end

-- ---------------------------------------------------------------- freeze
local frozen = {}
local function freeze_all()
    local p, guard = r32(A.active), 0
    while p ~= 0 and guard < 256 do
        frozen[#frozen + 1] = { p = p, t = r16(p + P_TIME) }
        w16(p + P_TIME, 0x7fff)
        p = r32(p + P_NEXT); guard = guard + 1
    end
    log("FROZE %d processes", #frozen)
end
local function thaw_all() for _, f in ipairs(frozen) do w16(f.p + P_TIME, f.t) end end

local steps, T = {}, 0
local function at(t, fn) steps[#steps + 1] = { t = t, fn = fn } end
local function step(action, label)
    T = T + SETTLE
    at(T - SETTLE, action)
    at(T, function() snap(label) end)
end
local function mode(m, dx) w16(A.cw_fixdx, dx or 0); w16(A.f_cwater, m) end
local hold_tick = nil

at(0, freeze_all)
T = 2
step(function() mode(1) end, "off_a")
step(function() end, "off_b")
step(function() mode(2, 0) end, "rows_0")
step(function() mode(2, SHIFT) end, "rows_p")
step(function() mode(2, -SHIFT) end, "rows_m")
step(function() mode(3, SHIFT) end, "rows_alt")
for _, ph in ipairs({ 0, 8, 16, 24 }) do
    step(function() mode(0); hold_tick = ph * 2 end, string.format("wave_%02d", ph))
end
at(T + 2, function()
    mode(0); hold_tick = nil; thaw_all()
    finish(string.format("snaps=%d", snaps))
end)

local freeze_frame = 0

-- ---------------------------------------------------------------- main
emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("start off=%s park=%s p1=%d p2=%d", tostring(OFF), tostring(PARK), P1, P2)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space or finished then return end
    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel == 0 then charsel = frame end
    if charsel > 0 and fighting == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, P1); w16(A.p2_char, P2)
        w16(A.curback, STAGE); w16(A.map_position, 0); w16(A.battle_num, 1)
        if confirm == 0 and frame - charsel > 90 then confirm = frame end
    end
    if gs == GS_FIGHTING and fighting == 0 then
        fighting = frame
        log("FIGHT frame=%d curback=%02x", frame, r16(A.curback))
        if r16(A.curback) ~= STAGE then finish("ERROR wrong stage") return end
    end
    if fighting == 0 then
        if frame > 7000 then finish("ERROR never reached a fight") end
        return
    end
    w16(A.p1_bar, MAXBAR); w16(A.p2_bar, MAXBAR)
    w16(A.p1_bar_view, MAXBAR); w16(A.p2_bar_view, MAXBAR)
    w16(A.winner_status, 0)

    local rel = frame - fighting
    if PARK and rel >= 60 and rel < LIVE_AT then
        for i, h in ipairs({ A.p1_obj, A.p2_obj }) do
            local o = r32(h)
            if o ~= 0 then w32(o + O_OXVAL, ((PARK + (i - 1) * 60) & 0xffff) << 16) end
        end
    end
    if rel >= LIVE_AT and rel < LIVE_AT + LIVE_N then
        live_frame(rel - LIVE_AT)
    elseif rel == LIVE_AT + LIVE_N then
        live_report()
        if OFF then finish("live-off") return end
        freeze_frame = frame
    end
    if hold_tick then w16(A.tick, hold_tick) end
    if freeze_frame > 0 then
        local t = frame - freeze_frame
        for _, s in ipairs(steps) do if s.t == t then s.fn() end end
    end
end)

emu.register_stop(function() if logfh then logfh:close() end end)
