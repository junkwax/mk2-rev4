-- wolf_sindel_victim.lua - things done TO UMK3 SINDEL (Wolf, ochar 21), filmed.
--
-- 2-player game, P1 = SV_P1 (default Jax 11), P2 forced to Sindel and idle.
-- SV_MODE:
--   SWEEPKO  her bar at 1, P1 sweeps (Back + Low Kick): she must end the
--            round LYING DOWN (MK3's sweep fall ends sitting up) - filmed
--   THROW    P1 throws her (close Low Punch); filmed, and she must be back
--            on her feet in her stance inside 300 frames
-- A snapshot every 4 frames for 200 frames from the input.  illop_count must
-- not move.  Env: WB_LOG, WS_MAP.
local LOG = os.getenv("WB_LOG")
local MODE = os.getenv("SV_MODE") or "SWEEPKO"
local P1C = tonumber(os.getenv("SV_P1") or "11")
local P2C = tonumber(os.getenv("SV_P2") or "21")   -- SV_P1=21 SV_P2=11: HER throw
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "p2_proc", "curback",
                    "illop_count", "p1_bar", "p2_bar", "worldtlx", "winner_status"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Low Punch", "P1 Left",
               "P1 Right", "P1 Low Kick"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end
local function done(fmt, ...) log(fmt, ...); f:close(); manager.machine:exit() end
local frame, started, sel, fight, confirm, ill0 = 0, false, nil, nil, nil, nil
local phase, t0 = "set", 0
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start %s", MODE)
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
            w16(A.p1_char, P1C); w16(A.p2_char, P2C); w16(A.curback, tonumber(os.getenv("SV_STAGE") or "0"))
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count); t0 = frame + 110; log("fight at %d", frame) end
        if frame > 12000 then done("no fight - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then done("FAIL illop_count moved (a reboot)") return end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if frame < t0 then return end
    local rel = frame - t0
    if phase == "set" then
        if p1o == 0 or p2o == 0 then return end
        local cam = s16(r16(A.worldtlx + 16))
        local gap = (MODE == "THROW") and 45 or ((MODE == "RDZAP") and 110 or 75)
        local x1 = cam + 150
        if os.getenv("SV_X") then x1 = tonumber(os.getenv("SV_X")) end   -- park the pair at a world x
        w16(p1o + 0x090, x1); w32(p1o + 0x080, (x1 << 16) & 0xffffffff)
        w16(p2o + 0x090, x1 + gap); w32(p2o + 0x080, ((x1 + gap) << 16) & 0xffffffff)
        w16(A.p1_bar, 0xa1)
        w16(A.p2_bar, MODE == "SWEEPKO" and 1 or 0xa1)
        if rel >= (os.getenv("SV_X") and 200 or 40) then phase = "go"; t0 = frame end
        return
    end
    if phase == "go" then
        if MODE == "RDZAP" then
            -- P1 Raiden: Back + High Punch, the short zap.  Log every change of
            -- his drawing and action, and P2's bar, frame by frame.
            if rel < 6 then F["P1 Left"]:set_value(1); F["P1 High Punch"]:set_value(rel >= 2 and 1 or 0) end
            local sh, ac = r32(p1o + 0x1d0), r16(r32(A.p1_proc) + 0x1f0)
            if sh ~= last_sh or ac ~= last_ac then
                log("  +%d shape %08X act %04X p2act %04X p2bar %d", rel, sh, ac, r16(r32(A.p2_proc) + 0x1f0), r16(A.p2_bar))
                last_sh, last_ac = sh, ac
            end
            if rel % 2 == 0 and rel <= 90 then manager.machine.video:snapshot() end
            if rel == 140 then done("LOGGED") end
            return
        end
        if MODE == "BATS" then
            -- the Tomb's two flyers (baklst4): screen x of each, every 20 frames,
            -- with the pair parked at SV_X
            w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
            if S.f_freeze_timer then w16(S.f_freeze_timer, 1) end
            if os.getenv("SV_X") then
                local x1 = tonumber(os.getenv("SV_X"))
                w16(p1o + 0x090, x1); w32(p1o + 0x080, (x1 << 16) & 0xffffffff)
                w16(p2o + 0x090, x1 + 60); w32(p2o + 0x080, ((x1 + 60) << 16) & 0xffffffff)
            end
            if rel % 20 == 0 then
                local cam4 = s16(r16(S.worldtlx4 + 16))
                local q, t, n = r32(S.baklst4), {}, 0
                while q ~= 0 and n < 8 do
                    t[#t + 1] = string.format("x %d y %d xvel %.1f", s16(r16(q + 0x090)) - cam4, s16(r16(q + 0x0b0)),
                        ((r32(q + 0x040) + 0x80000000) % 0x100000000 - 0x80000000) / 65536)
                    q = r32(q); n = n + 1
                end
                log("  +%d cam1 %d cam4 %d | %s", rel, s16(r16(A.worldtlx + 16)), cam4, table.concat(t, " | "))
            end
            if rel == 1500 then done("LOGGED") end
            return
        end
        if MODE == "RDGETUP" then
            -- P1 sweeps P2 (Raiden, SV_P2=7): log every change of the drawing
            -- (oshape) and the palette (opal) he is wearing, frame by frame
            if rel < 8 then F["P1 Left"]:set_value(1); F["P1 Low Kick"]:set_value(rel >= 2 and 1 or 0) end
            w16(A.p2_bar, 0xa1)
            local sh, pl = r32(p2o + 0x1d0), r16(p2o + 0x140)
            if sh ~= last_sh or pl ~= last_pl then
                log("  +%d shape %08X pal %04X act %04X", rel, sh, pl, r16(r32(A.p2_proc) + 0x1f0))
                last_sh, last_pl = sh, pl
            end
            if rel == 260 then done("LOGGED") end
            return
        end
        if MODE == "SCREAMKO" then
            -- she screams (F,F,F + HP) and the round ends under it: the clock
            -- loop sees an empty bar.  No wave may be left frozen on screen.
            local R = "P1 Right"
            if (rel < 4) or (rel >= 7 and rel < 11) or (rel >= 14 and rel < 18) then F[R]:set_value(1) end
            if rel >= 18 and rel < 23 then F["P1 High Punch"]:set_value(1) end
            if rel >= 60 then w16(A.p2_bar, 0) end
            if rel % 10 == 0 and rel <= 400 then manager.machine.video:snapshot() end
            if rel == 400 then done("FILMED - look for a frozen wave in snap/") end
            return
        end
        if MODE == "SWEEPKO" then
            if rel < 8 then F["P1 Left"]:set_value(1); F["P1 Low Kick"]:set_value(rel >= 2 and 1 or 0) end
        else
            if rel < 6 then F["P1 Low Punch"]:set_value(1) end
        end
        if rel % (MODE == "THROW" and 2 or 4) == 0 and rel <= 200 then manager.machine.video:snapshot() end
        if rel % 20 == 0 and S.skr_ran then
            log("  skr ran %d plain %d lines %d", r16(S.skr_ran), r16(S.skr_plain), r16(S.skr_lines))
        end
        if p2o ~= 0 and rel % 20 == 0 then
            log("  +%d p1act %04X p2act %04X ws %d gs %02X", rel, r16(r32(A.p1_proc) + 0x1f0),
                r16(r32(A.p2_proc) + 0x1f0), r16(A.winner_status), gs)
        end
        if MODE == "SWEEPKO" and rel == 200 then
            -- judged on the FILM (snap/): she must be flat on her back, not
            -- sitting up - the piece-RAM height this used to compute read the
            -- wrong offsets and is gone
            if r16(A.winner_status) == 0 then done("NO VERDICT - the sweep did not end the round") return end
            done("FILMED - the round ended on the sweep; look at snap/ for her pose")
        end
        if MODE == "THROW" and rel == 300 then
            done(r16(r32(A.p2_proc) + 0x1f0) == 0x0303 and "PASS back in her stance" or "FAIL not back in her stance")
        end
    end
end)
