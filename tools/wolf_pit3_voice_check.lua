-- wolf_pit3_voice_check.lua - THE PIT III (curback 22h, Wolf): the seated
-- Shao Kahn TALKS (up3k_proc, UMK3PIT3.ASM).
--   idle: the arm-sweep gesture says MK2's "I'm Shao Kahn - bow to me"
--         (triple_sndtab2 42h, track 047Fh) about half the times he makes it
--   a decided round: one of UMK3's four winning-Kahn lines (wsnd_sk_*,
--         make_wolf_audio.py) within P3V_WIN_WIN frames of winner_status 1/2
-- 2-player fight, Shang Tsung vs Jax, no inputs for IDLE frames (bars
-- pinned), then P2's bar is let go and P1 uppercuts him until the round is
-- decided.  The latch carries the resolved DCS TRACK (any of a triple's
-- three); bytes are paired ROLLING.  Tracks of the four wsnd_sk_* rows are
-- read out of the Wolf WOLFSND.ASM (P3V_SND, absolute path).
-- STOCK MAME plays u2-u5 only, so this proves what the ROM SENDS; hearing it
-- needs mk2wolf.exe (the u6-u9 streams).
-- Env: WS_MAP, P3V_SND (both absolute).  Driven by run_wolf_boot_probe.ps1.
local LOG = os.getenv("WB_LOG")
local f = nil
local function log(fmt, ...)
    if not f then f = io.open(LOG, "w"); f:write("wolf_pit3_voice_check start\n") end
    f:write(string.format(fmt, ...) .. "\n"); f:flush()
end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "curback", "p1_bar", "p2_bar",
                    "winner_status", "up3k_torso"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local WON = {}            -- base track -> name, from WOLFSND.ASM's sk_* rows
for line in io.lines(os.getenv("P3V_SND")) do
    local trk, key = line:match("%.word%s+%x+h|%d+,0(%x+)h%s*;%s*%x+%s+(sk_%w+)")
    if trk then WON[tonumber(trk, 16)] = key end
end
local nwon = 0
for _ in pairs(WON) do nwon = nwon + 1 end
if nwon ~= 4 then error("WOLFSND.ASM: found " .. nwon .. " sk_* rows, want 4") end
local BOW = 0x047f
local function line_of(t)
    if t >= BOW and t <= BOW + 2 then return "bow" end
    for b, k in pairs(WON) do if t >= b and t <= b + 2 then return k end end
end
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
local IDLE = tonumber(os.getenv("P3V_IDLE") or "1800")
local WIN_WIN = tonumber(os.getenv("P3V_WIN_WIN") or "200")
local frame, started, sel, fight, confirm = 0, false, nil, nil, nil
local prevb, armed = nil, false
local heard = {}
_G.p3v_snd = space:install_write_tap(0x01680000, 0x0168001f, "p3vsnd", function(o, d, m)
    local v = d & 0xff
    if armed and prevb then
        local k = line_of((prevb << 8) | v)
        if k and (#heard == 0 or heard[#heard][2] ~= k or frame - heard[#heard][1] > 30) then
            heard[#heard + 1] = {frame, k}
        end
    end
    prevb = v
    return d
end)
local decided, lastimg, imgchg = nil, nil, {}
local function finish(ok, why) log("%s: %s", ok and "PASS" or "FAIL", why); f:close(); manager.machine:exit() end
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
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, 0x22)
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
    local rel = frame - fight
    local torso = r32(A.up3k_torso)
    if torso ~= 0 then
        local img = r32(torso + 0x1a0)
        if lastimg and img ~= lastimg then imgchg[#imgchg + 1] = frame end
        lastimg = img
    end
    w16(A.p1_bar, 0xa1)
    if rel < IDLE then w16(A.p2_bar, 0xa1); return end
    local ws = r16(A.winner_status)
    if (rel - IDLE) % 300 == 0 then log("rel %d: gs %d winner_status %d bars %d/%d", rel, gs, ws, r16(A.p1_bar), r16(A.p2_bar)) end
    if not decided then
        if ws == 1 or ws == 2 then decided = frame; log("round decided at rel %d (winner_status %d)", rel, ws) end
    end
    if not decided then
        if r16(A.p2_bar) > 30 then w16(A.p2_bar, 30) end     -- a few uppercuts end it
        local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
        local c = (rel - IDLE) % 150
        if p1 ~= 0 and p2 ~= 0 and c < 40 then
            for i, o in ipairs({p1, p2}) do
                local px = (i == 1) and 560 or 610
                w16(o + 0x090, px); w32(o + 0x080, (px & 0xffff) << 16)
            end
        elseif c < 60 then
            F["P1 Down"]:set_value(1)
            if c >= 48 and c < 52 then F["P1 High Punch"]:set_value(1) end
        end
        if rel > IDLE + 4000 then finish(false, "the round was never decided - NO VERDICT") end
        return
    end
    if frame - decided < WIN_WIN then return end
    local bows, won = 0, {}
    for _, h in ipairs(heard) do
        log("  rel %d: %s", h[1] - fight, h[2])
        if h[2] == "bow" and h[1] - fight < IDLE then bows = bows + 1 end
        if h[2] ~= "bow" and h[1] >= decided then won[#won + 1] = h[2] end
    end
    local cued = 0
    for _, h in ipairs(heard) do
        if h[2] == "bow" then
            for _, c in ipairs(imgchg) do if c >= h[1] - 2 and c <= h[1] + 6 then cued = cued + 1; break end end
        end
    end
    log("idle: %d bow lines (%d with the torso moving), %d torso frame changes; after the decision: %s",
        bows, cued, #imgchg, table.concat(won, ","))
    if bows == 0 then return finish(false, "no 'bow to me' in " .. IDLE .. " idle frames") end
    if cued < bows then return finish(false, string.format("%d of %d bow lines without a gesture", bows - cued, bows)) end
    if #won == 0 then return finish(false, "no UMK3 taunt after the round was decided") end
    finish(true, string.format("%d bow lines, each on a gesture; round decided -> %s", bows, won[1]))
end)
