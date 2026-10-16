-- wolf_sindel_view.lua - UMK3 SINDEL (Wolf, ochar 21) on screen.
--
-- 2-player game with P1 forced to ochar 21 at the select screen (she has no
-- select entry yet) against an idle Jax.  In the fight P1 runs a schedule of
-- her basics - stance, walk, duck, block, the four normals, jump, flip,
-- sweep, roundhouse, uppercut - with a snapshot in the middle of each, and
-- the run FAILS if illop_count moves (a reboot) or P1 stops being ochar 21.
-- Env: WB_LOG, WS_MAP (tmp/wolf/src/MK2.MAP), SV_CHAR (default 21).
local LOG = os.getenv("WB_LOG")
local CHAR = tonumber(os.getenv("SV_CHAR") or "21")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "curback",
                    "illop_count", "p1_bar", "p2_bar"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Low Punch",
               "P1 Block", "P1 Down", "P1 Left", "P1 Right", "P1 Up", "P1 High Kick", "P1 Low Kick"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
-- name, frames, held inputs, tapped inputs (pressed for the first 5 frames)
local STEPS = {
    {"stance", 60, {}, {}},
    {"walkf", 50, {"P1 Right"}, {}},
    {"walkb", 50, {"P1 Left"}, {}},
    {"duck", 40, {"P1 Down"}, {}},
    {"block", 40, {"P1 Block"}, {}},
    {"hipunch", 40, {}, {"P1 High Punch"}},
    {"lopunch", 40, {}, {"P1 Low Punch"}},
    {"hikick", 50, {}, {"P1 High Kick"}},
    {"lokick", 50, {}, {"P1 Low Kick"}},
    {"jump", 70, {}, {"P1 Up"}},
    {"flip", 80, {"P1 Right"}, {"P1 Up"}},
    {"sweep", 60, {"P1 Left"}, {"P1 Low Kick"}},
    {"roundh", 70, {"P1 Left"}, {"P1 High Kick"}},
    {"uppercut", 70, {"P1 Down"}, {"P1 High Punch"}},
    {"duckkick", 50, {"P1 Down"}, {"P1 Low Kick"}},
    {"stance2", 40, {}, {}},
}
local frame, started, sel, fight, confirm, ill0 = 0, false, nil, nil, nil, nil
local step, t0, bad = 1, 0, 0
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    local gs = r16(A.gstate)
    if gs == 4 and not sel then sel = frame end
    if not sel and frame >= 1500 then
        local k = (frame - 1500) % 200
        F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
        F["2 Players Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
    end
    if not fight then
        if sel then
            w16(A.p1_char, CHAR); w16(A.p2_char, 11); w16(A.curback, 0)
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
            if gs == 0x0d and frame % 40 == 0 then manager.machine.video:snapshot() end   -- the VS screen
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count); t0 = frame + 120; log("fight at %d", frame) end
        if frame > 12000 then log("no fight - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    if r16(A.illop_count) ~= ill0 then
        log("FAIL illop_count moved (a reboot) in step %s, illop_pc %08X", STEPS[step] and STEPS[step][1] or "?",
            S.illop_pc and r32(S.illop_pc) or 0)
        f:close(); manager.machine:exit(); return
    end
    w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
    local p1o = r32(A.p1_obj)
    if p1o == 0 or frame < t0 then return end
    local st = STEPS[step]
    if not st then
        log(bad == 0 and "PASS all %d steps as ochar %d" or "FAIL %d steps, ochar %d", bad == 0 and #STEPS or bad, CHAR)
        f:close(); manager.machine:exit(); return
    end
    local rel = frame - t0
    for _, n in ipairs(st[3]) do F[n]:set_value(1) end
    if rel >= 6 and rel < 11 then for _, n in ipairs(st[4]) do F[n]:set_value(1) end end
    if rel == 6 + math.floor((st[2] - 6) / 3) then
        manager.machine.video:snapshot()
        local och = r16(p1o + 0x1f0)
        log("%-9s frame %d ochar %d act %04X", st[1], frame, och, r16(r32(A.p1_proc) + 0x1f0))
        if och ~= CHAR then bad = bad + 1 end
    end
    if rel >= st[2] then step = step + 1; t0 = frame + 20 end
end)
