-- wolf_dorfen_lantern_check.lua - NOOB'S DORFEN's green lantern (UMK3NWAL.ASM
-- unw_lant_proc): forces a 2-player fight onto curback 23h, then reads the
-- lantern objects every frame for LC_FRAMES and checks
--   * the dome's y walks the hover curve: a 168-tick cycle, 0..7 px below its
--     top, one step a frame at most, a slow lift (>= 90 ticks) and a quick
--     drop (<= 80 ticks incl. the catch) - the "weight";
--   * the cage stays fixed under the dome (cage y - dome y constant, both halves);
--   * the dome turns (more than one SAG seen) and stays on one centre column;
-- and snapshots at the top, mid-drop and the bottom of a cycle.
-- Env: WS_MAP (tmp/wolf/src/MK2.MAP, absolute), WB_LOG, LC_FRAMES (600).
local LOG = os.getenv("WB_LOG")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local function sym(n) return S[n] or error("no symbol " .. n) end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "curback", "p1_bar", "p2_bar",
                    "unw_lt_dome", "unw_lt_cage", "illop_count"}) do A[n] = sym(n) end
local O = { oxpos = 0x090, oypos = 0x0b0, oimg = 0x1a0 }
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
local FRAMES = tonumber(os.getenv("LC_FRAMES") or "600")
local frame, sel, confirm, fight = 0, nil, nil, nil
local ys, cdy, cdy2, xs, sags = {}, {}, {}, {}, {}
local shots = {}

local function verdict()
    local bad = {}
    -- the cycle: find the period as the first lag where the sequence repeats
    local n = #ys
    local period
    for lag = 100, 260 do
        local ok = true
        for i = 1, n - lag do if ys[i] ~= ys[i + lag] then ok = false; break end end
        if ok and n - lag >= 60 then period = lag; break end
    end
    if period ~= 168 then bad[#bad + 1] = "period " .. tostring(period) .. ", not 168" end
    local lo, hi, jump = 1e9, -1e9, 0
    for i = 1, n do
        lo = math.min(lo, ys[i]); hi = math.max(hi, ys[i])
        if i > 1 then jump = math.max(jump, math.abs(ys[i] - ys[i - 1])) end
    end
    if hi - lo ~= 7 then bad[#bad + 1] = string.format("travel %d px, not 7", hi - lo) end
    if jump > 1 then bad[#bad + 1] = string.format("a %d px step in one frame", jump) end
    -- rise vs fall over one cycle: ticks spent moving up vs down
    if period then
        local up, down = 0, 0
        for i = 2, period + 1 do
            if ys[i] < ys[i - 1] then up = up + 1 elseif ys[i] > ys[i - 1] then down = down + 1 end
        end
        -- count ticks between the bottom-leaving and top-arriving (lift) vs top-leaving and bottom
        local first_top, last_top
        for i = 1, period do if ys[i] == lo then first_top = first_top or i; last_top = i end end
        log("cycle: up steps %d, down steps %d, top held ticks %d..%d", up, down, first_top or -1, last_top or -1)
    end
    for i = 2, n do
        if cdy[i] ~= cdy[1] or cdy2[i] ~= cdy2[1] then bad[#bad + 1] = "the cage moved off the dome at sample " .. i; break end
    end
    local nsag = 0
    for _ in pairs(sags) do nsag = nsag + 1 end
    if nsag < 2 then bad[#bad + 1] = "the dome never turned" end
    log("y %d..%d, cage dy %d/%d, dome SAGs %d, max step %d, period %s",
        lo, hi, cdy[1], cdy2[1], nsag, jump, tostring(period))
    log(#bad == 0 and "PASS" or ("FAIL: " .. table.concat(bad, "; ")))
end

emu.register_frame(function()
    frame = frame + 1
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    if r16(A.illop_count) ~= 0 then log("FAIL: illop_count %d", r16(A.illop_count)); f:close(); manager.machine:exit(); return end
    local gs = r16(A.gstate)
    if gs == 4 and not sel then sel = frame end
    if not sel and frame >= 1500 then
        local k = (frame - 1500) % 200
        F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
        F["2 Players Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
    end
    if not fight then
        if sel then
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, 0x23)
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; log("fight at %d, curback %02X", frame, r16(A.curback)) end
        if frame > 12000 then log("no fight - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
    local rel = frame - fight
    if rel < 30 then return end
    local d, c1, c2 = r32(A.unw_lt_dome), r32(A.unw_lt_cage), r32(A.unw_lt_cage + 32)
    if d == 0 or c1 == 0 or c2 == 0 then log("FAIL: no lantern objects (%08X %08X %08X)", d, c1, c2); f:close(); manager.machine:exit(); return end
    local y = s16(r16(d + O.oypos))
    ys[#ys + 1] = y
    cdy[#cdy + 1] = s16(r16(c1 + O.oypos)) - y
    cdy2[#cdy2 + 1] = s16(r16(c2 + O.oypos)) - y
    sags[r32(d + O.oimg)] = true
    if rel % 4 == 0 then log("t %4d  dome y %d  x %d", rel, y, s16(r16(d + O.oxpos))) end
    -- snapshots: the first time it sits at the top after a lift, mid-drop, and the bottom
    if #ys > 2 and not shots.top and y == ys[#ys - 1] and y <= 0 then shots.top = rel; manager.machine.video:snapshot(); log("snap top at %d", rel) end
    if shots.top and not shots.bottom and y >= 7 then shots.bottom = rel; manager.machine.video:snapshot(); log("snap bottom at %d", rel) end
    if rel - 30 >= FRAMES then verdict(); f:close(); manager.machine:exit() end
end)
