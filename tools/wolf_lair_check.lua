-- wolf_lair_check.lua - SCORPION'S LAIR (UMK3, Wolf only, curback 01Fh): the
-- stage, its flames and its stage fatality, on the Wolf build in MAME's umk3.
--
-- A 2-player Liu Kang v Jax on curback 1Fh.  It checks the two lava flames
-- step through HELLFLAME1..6 every 4 ticks, then forces FINISH HIM with Jax
-- dizzy (the YOTEIGAI TOR rig's method, tools/peak_stage_fatality_test.lua),
-- pins them close and drives Liu Kang's pit code - Back, Forward, Forward + Low
-- Kick - and watches the lava fall (lair_fall_in_lava, UMK3LAIR.ASM):
--   * Jax is handed act_mk1pit_fall and leaves the top of the screen;
--   * he comes back SHRUNK (oscale 01C001C0h) and falls to the lava line;
--   * the splash plays HELLHIT1..8 in order;
--   * f_death goes to -1 (death_blow_complete).
-- Env (run_wolf_boot_probe.ps1 -Script wolf_lair_check.lua):
--   WL_MAP  tmp/wolf/src/MK2.MAP     WL_TBL  src/UMK3LRM.TBL
--   WL_ROX  src/LAIRRX.TBL   (optional: the ceiling's falling rocks - then the
--           rig also requires every rock lane drawn, all 22 rocks gone by the
--           end, and UMK3's lava hiss (wsnd_lair_hiss, WL_HISS = its track,
--           hex) on the sound latch at the splash)
local LOG = os.getenv("WB_LOG")
local f = nil
local function log(fmt, ...)
    if not f then f = io.open(LOG, "w"); f:write("wolf_lair_check start\n") end
    f:write(string.format(fmt, ...) .. "\n"); f:flush()
end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local S = {}
for line in io.lines(os.getenv("WL_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
-- the record SAGs, to tell the flame and splash frames apart
local SAG = {}
do
    local lines = {}
    for l in io.lines(os.getenv("WL_TBL")) do lines[#lines + 1] = l end
    for i, l in ipairs(lines) do
        local nm = l:match("^(HELL%w+):")
        if nm then SAG[tonumber(lines[i + 2]:match("(%x+)[hH]"), 16)] = nm end
    end
end
local ROX = os.getenv("WL_ROX")
if ROX then
    local lines = {}
    for l in io.lines(ROX) do lines[#lines + 1] = l end
    for i, l in ipairs(lines) do
        local nm = l:match("^(LRK%w+):")
        if nm then SAG[tonumber(lines[i + 2]:match("(%x+)[hH]"), 16)] = nm end
    end
end
local HISS = tonumber(os.getenv("WL_HISS") or "0", 16)
local A = {}
for _, n in ipairs({"gstate", "p1_state", "p2_state", "p1_char", "p2_char", "p1_obj", "p2_obj",
                    "p1_proc", "p2_proc", "curback", "winner_status", "f_death", "dizzy_dude",
                    "objlst", "lair_flm_obj", "worldtlx"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { oxval = 0x080, oxpos = 0x090, oyval = 0x0a0, oypos = 0x0b0, oscale = 0x180, oimg = 0x1a0,
            ochar = 0x1f0 }
local P = { wake = 0x0e0, action = 0x1f0, flags = 0x210 }
local ACT_MK1PIT_FALL, PM_REACT = 0x050d, 0x001c

local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local F = {}
for _, n in ipairs({"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Low Kick",
                    "P1 Left", "P1 Right"}) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
local function sagof(o) return r32(r32(o + O.oimg) + 0x40) end

local frame, started = 0, false
local rox_max, rox_live, rox_lanes, hiss_f, boom_f = 0, 0, {}, nil, nil
local top_min = 9999
local prevb
_G.wl_snd_tap = space:install_write_tap(0x01680000, 0x0168001f, "wlsnd", function(o, d, m)
    local v = d & 0xff
    local c = ((prevb or 0) << 8) | v
    prevb = v
    if HISS > 0 and c >= HISS and c <= HISS + 2 and not hiss_f then hiss_f = frame end
    if c >= 0x040b and c <= 0x040d and not boom_f then boom_f = frame end
    return d
end)
local sel, fight, confirm, finish_f, attempt, fall_f = nil, nil, nil, nil, nil, nil
local flm_seq, flm_last, flm_since, flm_steps = {}, nil, nil, {}
local up_seen, small_seen, low_y, hits, hit_last, dead_f = false, false, -9999, {}, nil, nil
local cam_lo, cam_hi, hit_live = 99999, -99999, false  -- camera drift during the fall; splash left on objlst
local shots = {}
local function snap(tag) if not shots[tag] then shots[tag] = true; manager.machine.video:snapshot(); log("snap %s frame %d", tag, frame) end end

emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
    local gs = r16(A.gstate)
    if gs == 4 and not sel then sel = frame; log("select at %d", frame) end
    -- coins + 2P start, then both confirm
    for _, n in ipairs({"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Low Kick", "P1 Left", "P1 Right"}) do F[n]:set_value(0) end
    if not sel and frame >= 1500 then
        local k = (frame - 1500) % 200
        F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
        F["2 Players Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
    end
    if not fight then
        if sel then
            w16(A.p1_char, 1); w16(A.p2_char, 11); w16(A.curback, 0x1F)   -- Liu Kang v Jax
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; log("fight at %d, curback %02X", frame, r16(A.curback)); end
        if frame > 12000 then log("no fight - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    local rel = frame - fight
    if r16(A.curback) ~= 0x1F then log("FAIL wrong stage %02X", r16(A.curback)); f:close(); manager.machine:exit(); return end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)

    -- the flames, for 200 frames
    if rel >= 20 and rel < 220 then
        local o = r32(A.lair_flm_obj)
        local nm = SAG[sagof(o)]
        if nm ~= flm_last then
            if flm_last and flm_since then flm_steps[frame - flm_since] = (flm_steps[frame - flm_since] or 0) + 1 end
            flm_seq[#flm_seq + 1] = nm or "?"
            flm_since = flm_last and frame or nil
            flm_last = nm
        end
        if rel == 60 then snap("stage") end
    end
    if rel == 220 then
        local t = {}
        for s, c in pairs(flm_steps) do t[#t + 1] = s .. ":" .. c end
        log("flames: %s ... steps %s", table.concat(flm_seq, ",", 1, math.min(#flm_seq, 14)), table.concat(t, " "))
    end

    -- FINISH HIM, Jax dizzy, the two pinned close, then Liu Kang's pit code
    if rel >= 240 and not fall_f then
        w16(A.winner_status, 3); w16(A.f_death, 0)
        local p2p = r32(A.p2_proc)
        if not finish_f then
            finish_f = frame
            w32(p2p + P.wake, A.dizzy_dude)
            log("finish him at %d", frame)
        end
        local cam = s16(r16(A.worldtlx + 16))
        local vx = cam + 230
        w16(p2o + O.oxpos, vx); w32(p2o + O.oxval, (vx << 16) & 0xffffffff)
        w16(p1o + O.oxpos, vx - 55); w32(p1o + O.oxval, ((vx - 55) << 16) & 0xffffffff)
        if not attempt and frame > finish_f + 60 then attempt = frame end
        if attempt then
            local k = (frame - attempt) % 80
            F["P1 Left"]:set_value((k < 5) and 1 or 0)
            F["P1 Right"]:set_value(((k >= 9 and k < 14) or (k >= 18 and k < 23)) and 1 or 0)
            F["P1 Low Kick"]:set_value((k >= 26 and k < 32) and 1 or 0)
            if frame - attempt > 800 then log("FAIL the pit code never took"); f:close(); manager.machine:exit(); return end
        end
        if r16(r32(A.p2_proc) + P.action) == ACT_MK1PIT_FALL then fall_f = frame; log("act_mk1pit_fall at %d", frame) end
        return
    end

    if fall_f then
        local t = frame - fall_f
        local y = s16(r16(p2o + O.oypos))
        local cx = s16(r16(A.worldtlx + 16))
        if cx < cam_lo then cam_lo = cx end
        if cx > cam_hi then cam_hi = cx end
        if not small_seen then
            if y < top_min then top_min = y end
            if t == 50 then snap("wait") end
        end
        -- gone: his top far enough above the screen that nothing of him shows
        -- (a body that stopped at 100h off the ground hung its legs in view)
        if y < -100 and not small_seen then up_seen = true end
        if r32(p2o + O.oscale) == 0x01C001C0 then
            if not small_seen then small_seen = true; log("small at +%d, x %d y %d", t, s16(r16(p2o + O.oxpos)), y) end
            if y > low_y then low_y = y end
            if t % 6 == 0 then snap("fall" .. (t // 6 % 3)) end
        end
        -- the splash: any HELLHIT SAG on objlst
        local o, n = r32(A.objlst), 0
        hit_live = false
        rox_live = 0
        while o ~= 0 and n < 120 do
            local nm = SAG[sagof(o)]
            if nm and nm:match("^HELLHIT") then hit_live = true end
            if nm and nm:match("^LRK") then rox_live = rox_live + 1; rox_lanes[nm:sub(1, 4)] = true end
            if nm and nm:match("^HELLHIT") and nm ~= hit_last then
                hits[#hits + 1] = nm; hit_last = nm
                log("splash %s top-left x %d y %d", nm, s16(r16(o + O.oxpos)), s16(r16(o + O.oypos)))
                if nm == "HELLHIT4" then snap("splash") end
            end
            o = r32(o); n = n + 1
        end
        if rox_live > rox_max then rox_max = rox_live end
        if rox_live > 0 and t % 8 == 0 then snap("rox" .. (t // 8 % 4)) end
        if not dead_f and s16(r16(A.f_death)) == -1 then dead_f = frame; log("f_death -1 at +%d", t) end
        if t > 700 or (dead_f and frame > dead_f + 60) then
            log("highest top y during the wait %d (must be < -100)", top_min)
            log("up %s, small %s, lowest y %d, splash %s, f_death %s",
                tostring(up_seen), tostring(small_seen), low_y, table.concat(hits, ","), tostring(dead_f ~= nil))
            local seq_ok = #hits == 8
            for i = 1, #hits do if hits[i] ~= "HELLHIT" .. i then seq_ok = false end end
            local fl_ok = (flm_steps[4] or 0) > 20
            for s in pairs(flm_steps) do if s ~= 4 then fl_ok = false end end
            local cam_ok = (cam_hi - cam_lo) <= 12
            log("camera during the fall %d..%d (drift %d, must be <= 12); splash still on objlst at the end: %s",
                cam_lo, cam_hi, cam_hi - cam_lo, tostring(hit_live))
            local rox_ok = true
            if ROX then
                local lanes = {}
                for k in pairs(rox_lanes) do lanes[#lanes + 1] = k end
                table.sort(lanes)
                rox_ok = rox_max >= 22 and #lanes == 4 and rox_live == 0 and hiss_f ~= nil
                log("rocks: most at once %d (22 dropped), lanes drawn %s, left at the end %d; BOOM %s, hiss %s",
                    rox_max, table.concat(lanes, ","), rox_live,
                    boom_f and ("+" .. (boom_f - fall_f)) or "never", hiss_f and ("+" .. (hiss_f - fall_f)) or "never")
            end
            log((up_seen and small_seen and seq_ok and dead_f and fl_ok and cam_ok and not hit_live and rox_ok)
                and "PASS" or "FAIL")
            f:close(); manager.machine:exit()
        end
    end
end)
