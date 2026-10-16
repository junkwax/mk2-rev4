-- wolf_pit3_comment_check.lua - THE PIT III (curback 22h, Wolf): an uppercut
-- draws SHAO KAHN's comment (UMK3's comment_table_pit, upcut_comment in
-- MKREACT.ASM): superb / well done / one of his three laughs, never MK2's
-- excellent / outstanding / crowd "ooo" - and a laugh makes the seated Kahn
-- throw his arm out (up3k_cue -> up3k_cackle).
--
-- 2-player fight, Shang Tsung vs Jax on the stage, bars pinned.  Every CYCLE
-- frames the pair is parked close and P1 throws Down+High Punch.  The sound
-- latch is tapped and paired ROLLING into tracks (the latch carries the DCS
-- track, not the table index).  Verdict after TRIALS uppercuts:
--   at least MIN_COMMENTS comment lines heard, all of them Pit lines
--   at least one laugh, and the seated Kahn's torso changed frame within
--   CUE_WIN frames of every laugh that came while he was resting
-- P3C_STAGE=0 runs the same thing on THE DEAD POOL as the control: it must
-- hear MK2's ordinary lines (excellent/outstanding/ooo can appear) and never
-- move a throne Kahn (there is none).
-- Env: WS_MAP (abs path to the Wolf MK2.MAP).  Driven by run_wolf_boot_probe.ps1.
local LOG = os.getenv("WB_LOG")
local f = nil
local function log(fmt, ...)
    if not f then f = io.open(LOG, "w"); f:write("wolf_pit3_comment_check start\n") end
    f:write(string.format(fmt, ...) .. "\n"); f:flush()
end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "curback", "p1_bar", "p2_bar",
                    "up3k_torso", "up3k_cue"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { oxval = 0x080, oxpos = 0x090, oimg = 0x1a0 }
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Down"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
local STAGE = tonumber(os.getenv("P3C_STAGE") or "22", 16)
local PIT = STAGE == 0x22
local TRIALS = tonumber(os.getenv("P3C_TRIALS") or "24")
local MIN_COMMENTS = tonumber(os.getenv("P3C_MIN") or "8")
local CYCLE, CUE_WIN = 150, 6
-- comment tracks: each triple_sndtab2 row's base track and its two neighbours
local LINES = {
    {0x03c6, "superb", true}, {0x03c3, "well done", true},
    {0x049a, "laugh1", true}, {0x049d, "laugh2", true}, {0x04a0, "laugh3", true},
    {0x03ba, "excellent", false}, {0x03c0, "outstanding", false}, {0x024b, "crowd ooo", false},
}
local function line_of(t)
    for _, L in ipairs(LINES) do if t >= L[1] and t <= L[1] + 2 then return L end end
end
local frame, started, sel, fight, confirm = 0, false, nil, nil, nil
local prevb, armed = nil, false
local heard = {}          -- {frame, line}
_G.p3c_snd = space:install_write_tap(0x01680000, 0x0168001f, "p3csnd", function(o, d, m)
    local v = d & 0xff
    if armed and prevb then
        local L = line_of((prevb << 8) | v)
        if L and (#heard == 0 or frame - heard[#heard][1] > 30) then heard[#heard + 1] = {frame, L} end
    end
    prevb = v
    return d
end)
local imgchg = {}         -- frames the seated Kahn's torso changed art
local lastimg = nil
local function finish(ok, why)
    log("%s: %s", ok and "PASS" or "FAIL", why); f:close(); manager.machine:exit()
end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start stage %02X", STAGE)
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
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, STAGE)
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; armed = true; log("fight at %d, curback %02X", frame, r16(A.curback)) end
        if frame > 12000 then finish(false, "no fight - NO VERDICT") end
        return
    end
    w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
    local torso = PIT and r32(A.up3k_torso) or 0
    if torso ~= 0 then
        local img = r32(torso + O.oimg)
        if lastimg and img ~= lastimg then imgchg[#imgchg + 1] = frame end
        lastimg = img
    end
    local rel = frame - fight
    if rel < 60 then return end
    local k = (rel - 60) // CYCLE
    local c = (rel - 60) % CYCLE
    if k >= TRIALS then
        local pit, other, laughs, cued = 0, 0, 0, 0
        for _, h in ipairs(heard) do
            if h[2][3] then pit = pit + 1 else other = other + 1 end
            log("  %d: %s", h[1] - fight, h[2][2])
            if h[2][2]:sub(1, 5) == "laugh" then
                laughs = laughs + 1
                for _, cf in ipairs(imgchg) do
                    if cf >= h[1] - 1 and cf <= h[1] + CUE_WIN then cued = cued + 1; break end
                end
            end
        end
        log("heard %d comments: %d Pit lines, %d MK2-only; %d laughs, %d answered by the throne",
            #heard, pit, other, laughs, cued)
        if not PIT then
            return finish(other > 0 and #imgchg == 0,
                string.format("control: %d MK2-only lines, %d throne frame changes", other, #imgchg))
        end
        if #heard < MIN_COMMENTS then return finish(false, string.format("only %d comments - NO VERDICT", #heard)) end
        if other > 0 then return finish(false, string.format("%d MK2-only lines at the Pit", other)) end
        if laughs == 0 then return finish(false, "no laugh in the sample - NO VERDICT") end
        if cued == 0 then return finish(false, string.format("%d laughs, the throne never answered", laughs)) end
        return finish(true, string.format("%d comments, all Pit lines; %d of %d laughs answered on the throne",
            #heard, cued, laughs))
    end
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    if p1 == 0 or p2 == 0 then return end
    if c < 40 then
        for i, o in ipairs({p1, p2}) do
            local px = (i == 1) and 560 or 610
            w16(o + O.oxpos, px); w32(o + O.oxval, (px & 0xffff) << 16)
        end
    elseif c < 60 then
        F["P1 Down"]:set_value(1)
        if c >= 48 and c < 52 then F["P1 High Punch"]:set_value(1) end
    end
end)
