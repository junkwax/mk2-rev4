-- wolf_pit3_finish_check.lua - THE PIT III (curback 22h, Wolf): at FINISH HIM
-- the seated Shao Kahn RISES out of his throne (SHAGETUP1-4), throws his arm
-- out (MK2's BGTALK1-5 over BGTALKLEG1) and says FINISH HIM himself as it
-- lands (up3k_getup / up3k_voice_take, UMK3PIT3.ASM; grow_msg, MKFX.ASM).
-- 2-player fight, Shang Tsung vs Jax.  P1 is handed one round (p1_matchw 1),
-- then uppercuts Jax until the round is decided, which is the match: FINISH HIM.
-- Asserts, off the LIVE torso object (frames told apart by their record's
-- w,h - the labels are local and not in the map):
--   the torso draws SHAGETUP1,2,3,4 then BGTALK1..5 in that order;
--   the shin object is parked above the world while SHAGETUP draws, and is
--   the standing legs (BGTALKLEG1, 62x95) once he points;
--   the FINISH HIM/HER track ($03AE-$03B3) reaches the sound latch ONCE, and
--   not before BGTALK5 is drawn - i.e. grow_msg handed the line to him.
-- P3F_NEG=1 inverts the voice verdict (the line must come at the banner) -
-- run it on a ROM without the hand-off; on this one it must FAIL.
-- Snapshots of each beat go to MAME's snap dir (P3F_SNAP=0 to skip).
-- Env: WS_MAP (absolute).  Driven by run_wolf_boot_probe.ps1.
local LOG = os.getenv("WB_LOG")
local f = nil
local function log(fmt, ...)
    if not f then f = io.open(LOG, "w"); f:write("wolf_pit3_finish_check start\n") end
    f:write(string.format(fmt, ...) .. "\n"); f:flush()
end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "curback", "p1_bar", "p2_bar",
                    "winner_status", "up3k_torso", "up3k_leg", "p1_matchw", "worldtlx"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local NEG = os.getenv("P3F_NEG") == "1"
local SNAP = os.getenv("P3F_SNAP") ~= "0"
local WARM = tonumber(os.getenv("P3F_WARM") or "400")
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function s16(a) local v = r16(a); return v >= 0x8000 and v - 0x10000 or v end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Down"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
-- frames by record size
local SIZE = {
    ["68x115"] = "G1", ["60x127"] = "G2", ["49x148"] = "G3", ["61x156"] = "G4",
    ["64x69"] = "T1", ["68x68"] = "T2", ["83x67"] = "T3", ["90x67"] = "T4", ["94x67"] = "T5",
    ["62x95"] = "LEG", ["24x48"] = "SHIN",
}
local function name_of(obj)
    local img = r32(obj + 0x1a0)
    if img == 0 then return "?" end
    local k = string.format("%dx%d", r16(img), r16(img + 16))
    return SIZE[k] or k
end
local frame, started, sel, fight, confirm = 0, false, nil, nil, nil
local prevb, fh = nil, {}
_G.p3f_snd = space:install_write_tap(0x01680000, 0x0168001f, "p3fsnd", function(o, d, m)
    local v = d & 0xff
    if prevb then
        local t = (prevb << 8) | v
        if t >= 0x03ae and t <= 0x03b3 and (#fh == 0 or frame - fh[#fh] > 30) then fh[#fh + 1] = frame end
    end
    prevb = v
    return d
end)
local fin, seq, lastn, t5, parked, legok = nil, {}, nil, nil, false, false
local function snap(tag)
    if SNAP then manager.machine.video:snapshot(); log("  snap %s at frame %d", tag, frame) end
end
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
        if gs == 2 then fight = frame; log("fight at %d, curback %02X", frame, r16(A.curback)) end
        if frame > 12000 then finish(false, "no fight - NO VERDICT") end
        return
    end
    local rel = frame - fight
    local ws = r16(A.winner_status)
    local torso, leg = r32(A.up3k_torso), r32(A.up3k_leg)
    if not fin then
        w16(A.p1_matchw, 1)            -- P1 already has a round
        w16(A.p1_bar, 0xa1)
        local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
        if rel < WARM then                                  -- walk the camera to the throne first
            w16(A.p2_bar, 0xa1)
            if p1 ~= 0 and p2 ~= 0 then
                for i, o in ipairs({p1, p2}) do
                    local px = (i == 1) and 990 or 1030
                    w16(o + 0x090, px); w32(o + 0x080, (px & 0xffff) << 16)
                end
            end
            if rel == WARM - 1 then log("camera worldtlx %d before the finish", r32(A.worldtlx) >> 16) end
            return
        end
        if r16(A.p2_bar) > 30 then w16(A.p2_bar, 30) end
        if ws == 3 then fin = frame; log("FINISH HIM at rel %d", rel); snap("finish"); return end
        local c = rel % 150
        if p1 ~= 0 and p2 ~= 0 and c < 40 then
            for i, o in ipairs({p1, p2}) do
                local px = (i == 1) and 960 or 1010     -- near the throne, so the camera shows him
                w16(o + 0x090, px); w32(o + 0x080, (px & 0xffff) << 16)
            end
        elseif c < 60 then
            F["P1 Down"]:set_value(1)
            if c >= 48 and c < 52 then F["P1 High Punch"]:set_value(1) end
        end
        if rel > 5000 then finish(false, "no FINISH HIM - NO VERDICT") end
        return
    end
    if torso == 0 or leg == 0 then return finish(false, "no throne Kahn objects") end
    local n = name_of(torso)
    if n ~= lastn then
        seq[#seq + 1] = n
        log("  rel-fin %3d: torso %s  shin %s y=%d", frame - fin, n, name_of(leg), s16(leg + 0xb0))
        if n == "G1" or n == "G4" or n == "T5" then snap(n) end
        lastn = n
    end
    if n:sub(1, 1) == "G" and s16(leg + 0xb0) < -100 then parked = true end
    if n == "T5" and not t5 then t5 = frame end
    if n:sub(1, 1) == "T" and name_of(leg) == "LEG" and s16(leg + 0xb0) > 0 then legok = true end
    if frame - fin < 260 then return end
    local s = table.concat(seq, ",")
    log("torso: %s", s)
    log("FINISH line at rel-fin: %s; BGTALK5 at %s", table.concat((function()
        local o = {}; for _, x in ipairs(fh) do o[#o + 1] = tostring(x - fin) end; return o end)(), ","),
        t5 and tostring(t5 - fin) or "never")
    if not s:find("G1,G2,G3,G4,T1,T2,T3,T4,T5", 1, true) then return finish(false, "rise/point order wrong: " .. s) end
    if not parked then return finish(false, "shin was not parked while SHAGETUP drew") end
    if not legok then return finish(false, "no standing legs under BGTALK") end
    local voice_ok = (#fh == 1) and t5 and fh[1] >= t5
    if NEG then voice_ok = not voice_ok end
    if not voice_ok then
        return finish(false, string.format("FINISH line %d time(s), first at rel-fin %s, arm out at %d",
            #fh, fh[1] and tostring(fh[1] - fin) or "-", t5 and t5 - fin or -1))
    end
    finish(true, string.format("rose and pointed (%s); line said once at rel-fin %d, arm out at %d",
        s, fh[1] - fin, t5 - fin))
end)
