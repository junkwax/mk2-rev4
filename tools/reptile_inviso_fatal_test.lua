-- reptile_inviso_fatal_test.lua
--
-- REPTILE'S INVISIBLE FATALITY (db2_table row 9, do_inviso_kill, MKDEATH.ASM).
-- In FINISH HIM, while INVISIBLE, close (fatality_xfer_close 045h):
-- Forward, Forward, Down + High Kick (scom_rp_db2, rp_hi_kick, MOVES.ASM).
--
-- 2-player game, P1 Reptile on the left, P2 Jax.  FINISH HIM is forced by
-- emptying P2's bar with P1 on match point.  Then Up, Up, Down + HP turns him
-- invisible, the pair is snapped inside range and the fatality input is played.
-- Every try logs the gates rp_hi_kick / fatality_xfer test, so a refusal says
-- WHICH gate refused.
--
--   RIF_LOG   log path
--   RIF_HOLD  1 = keep Down held through the HK press (default: release first)

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG  = os.getenv("RIF_LOG") or (ROOT .. "/tools/reptile_inviso_fatal.log")
local HOLD_DOWN = os.getenv("RIF_HOLD") == "1"
local EARLY = os.getenv("RIF_EARLY") == "1"   -- turn invisible BEFORE the KO
local WALK  = os.getenv("RIF_WALK") == "1"
local RIGHT = os.getenv("RIF_RIGHT") == "1"   -- Reptile on the RIGHT, facing left
local FWD = RIGHT and "P1 Left" or "P1 Right"    -- no snapping for the fatality: walk in

local logfh = assert(io.open(LOG, "w"))
local raw = print
local function log(fmt, ...)
    local line = "[rif] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    raw(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(ROOT .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
    end
    fh:close()
end
local WANT = { "gstate", "p1_char", "p2_char", "p1_bar", "p2_bar", "p1_matchw",
               "winner_status", "p1_obj", "p2_obj", "p1_proc", "p2_proc", "f_death",
               "f_fatal_lock", "f_no_violence", "f_no_blood", "f_thatsall" }
local CHEATS = { "f_rain_cheat1", "f_rain_cheat2", "f_ermac_cheat1",
                 "f_ermac_cheat2", "f_jade_cheat1", "f_jade_cheat2" }
local A = {}
for _, n in ipairs(WANT) do
    A[n] = symbols[n]
    if not A[n] then log("FATAL: '%s' not in mk2.map", n) end
end

local O_OXPOS, O_OXVAL, O_OYPOS, O_OFLAGS2 = 0x090, 0x080, 0x0b0, 0x160
local P_ACTION, P_PWAKE = 0x1f0, nil
local M_INVISO = 0x0020

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_REPTILE, FT_JAX = 9, 11

local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local held = {}
local function hold(n, on) held[n] = on and true or false end

local function cache_inputs()
    local want = { ["Coin 1"]=1, ["Coin 2"]=1, ["2 Players Start"]=1, ["UI Select"]=1,
                   ["P1 High Punch"]=1, ["P1 Low Punch"]=1, ["P1 Block"]=1,
                   ["P1 High Kick"]=1, ["P2 Low Punch"]=1, ["P1 Up"]=1, ["P1 Down"]=1,
                   ["P1 Right"]=1, ["P1 Left"]=1 }
    for _, p in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("input MISSING: %s", n) end end
end

local function place(obj, x) w16(obj + O_OXPOS, x); w32(obj + O_OXVAL, (x << 16) & 0xffffffff) end
local function snap_to(dist)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local x1, x2 = s16(r16(p1o + O_OXPOS)), s16(r16(p2o + O_OXPOS))
    local mid = (x1 + x2) // 2
    local s = RIGHT and -1 or 1
    place(p1o, mid - s * (dist // 2))
    place(p2o, mid + s * (dist - dist // 2))
end
local snaps = 0
local function snap() snaps = snaps + 1; manager.machine.video:snapshot() end

local function inviso()
    local o = r32(A.p1_obj); if o == 0 then return false end
    return (r16(o + O_OFLAGS2) & M_INVISO) ~= 0
end
local function dist()
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return -1 end
    return math.abs(s16(r16(p1o + O_OXPOS)) - s16(r16(p2o + O_OXPOS)))
end
local function act(p) local q = r32(p); return q ~= 0 and r16(q + P_ACTION) or 0xffff end
local function gates()
    return string.format("inviso=%s dist=%d ws=%d f_death=%04x lock=%04x thatsall=%d p1act=%04x p2act=%04x p1y=%d",
        tostring(inviso()), dist(), r16(A.winner_status), r16(A.f_death), r16(A.f_fatal_lock),
        r16(A.f_thatsall), act(A.p1_proc), act(A.p2_proc),
        r32(A.p1_obj) ~= 0 and s16(r16(r32(A.p1_obj) + O_OYPOS)) or -1)
end

local frame, psel, confirm, fight_at, armed_at = 0, 0, 0, 0, 0
local ko_at, finish_at, done = 0, 0, false
local phase = "boot"
local inv_at, inv_try, inv_on_at = 0, 0, 0
local fat_at, fat_try, fatal_at = 0, 0, 0
local last_inv = nil
local result = nil

local function finish(ok, msg)
    if done then return end
    done = true
    log("%s  %s", ok and "PASS" or "FAIL", msg)
    log("%d snapshot(s)", snaps)
    manager.machine:exit()
end

-- Up, Up, Down then pulse HP (scom_inviso; restricted_xfer refuses an airborne
-- caller, so HP is pulsed past the jump).
local function inviso_input(c)
    local w = {}
    if c < 2 or (c >= 4 and c < 6) then w["P1 Up"] = true end
    if c >= 8 and c < 10 then w["P1 Down"] = true end
    if c >= 12 and c < 60 and ((c - 12) % 4) < 2 then w["P1 High Punch"] = true end
    return w
end
-- Forward, Forward, Down + HK inside scom_rp_db2's 038h.  P1 is on the left.
local function fatal_input(c)
    local w = {}
    if c < 3 or (c >= 6 and c < 9) then w[FWD] = true end
    if c >= 12 and c < (HOLD_DOWN and 24 or 15) then w["P1 Down"] = true end
    if c >= 18 and c < 22 then w["P1 High Kick"] = true end
    return w
end
local DRIVE = { "P1 Up", "P1 Down", "P1 Right", "P1 Left", "P1 High Punch", "P1 High Kick" }
local function drive(w) for _, n in ipairs(DRIVE) do hold(n, w[n] == true) end end

emu.register_frame_done(function()
    if done then return end
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_inputs()
        log("reptile invisible fatality rig  hold_down=%s", tostring(HOLD_DOWN))
    end
    frame = frame + 1
    local gs = r16(A.gstate)

    if psel == 0 and gs == GS_PSEL then
        psel = frame
        log("select screen at frame %d", frame)
        for _, n in ipairs({ "Coin 1", "Coin 2", "2 Players Start", "UI Select" }) do hold(n, false) end
    end

    if psel == 0 then
        hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
        hold("Coin 2", frame >= 240 and frame < 3000 and (frame % 80) >= 20 and (frame % 80) < 40)
        hold("2 Players Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
        hold("UI Select", frame >= 5 and frame < 35)
    elseif confirm == 0 then
        local rel = frame - psel
        if gs == GS_PSEL then
            w16(A.p1_char, FT_REPTILE)
            w16(A.p2_char, FT_JAX)
            for _, n in ipairs(CHEATS) do if symbols[n] then w16(symbols[n], 0) end end
            hold("2 Players Start", rel < 60 and (frame % 20) < 8)
        end
        if rel == 60 and phase == "boot" then phase = "post" end
        if phase == "post" and rel > 130 then
            hold("P1 Low Punch", (frame % 20) < 8)
            hold("P2 Low Punch", (frame % 20) < 8)
        end
        if gs ~= GS_PSEL and phase == "post" then
            confirm = frame
            log("select done at %d: p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
            for n in pairs(fields) do hold(n, false) end
        end
    else
        if gs == GS_FIGHTING and fight_at == 0 then
            fight_at = frame
            log("fight live at %d: p1_char=%d p2_char=%d", frame, r16(A.p1_char), r16(A.p2_char))
        end
        if EARLY and fight_at > 0 and armed_at == 0 then
            local c = frame - fight_at - 60
            if c >= 0 then
                snap_to(0x60)
                drive(inviso_input(c % 100))
                if inviso() and c > 30 then
                    drive({}); armed_at = -1
                    log("EARLY: invisible in the fight at %d  %s", frame, gates())
                end
                if c > 400 then finish(false, "never went invisible in the fight") return end
            end
        end
        if armed_at == -1 then
            armed_at = frame
            w16(A.p1_matchw, 1); w16(A.p2_bar, 1)
            log("armed (while invisible): p1_matchw=1 p2_bar=1")
        end
        if not EARLY and fight_at > 0 and armed_at == 0 and frame - fight_at == 60 then
            armed_at = frame
            w16(A.p1_matchw, 1); w16(A.p2_bar, 1)
            log("armed: p1_matchw=1 p2_bar=1")
        end
        if armed_at > 0 and ko_at == 0 then
            snap_to(60)
            hold("P1 High Punch", (frame % 12) < 5)
            if r16(A.p2_bar) == 0 then ko_at = frame; hold("P1 High Punch", false); log("KO at %d", frame) end
        end
        if ko_at > 0 and finish_at == 0 and r16(A.winner_status) == 3 then
            finish_at = frame
            log("FINISH HIM at %d  %s", frame, gates())
        end

        -- invisibility transitions, logged whenever they happen
        local iv = inviso()
        if finish_at > 0 and last_inv ~= nil and iv ~= last_inv then
            log("  inviso %s -> %s at %d  %s", tostring(last_inv), tostring(iv), frame, gates())
        end
        last_inv = iv

        if finish_at > 0 and fatal_at == 0 then
            -- 1) go invisible
            if EARLY and inv_on_at == 0 and iv and frame - finish_at >= 60 then
                inv_on_at = frame - 20
                log("still invisible at FINISH HIM  %s", gates())
            end
            if EARLY and inv_on_at == 0 and iv then
                drive({})                -- waiting for him to be dizzy
            elseif inv_on_at == 0 then
                snap_to(0x60)
                if inv_at == 0 and frame - finish_at >= 20 then
                    inv_at = frame; inv_try = inv_try + 1
                    log("Up,Up,Down+HP (try %d)  %s", inv_try, gates())
                end
                if inv_at > 0 then
                    local c = frame - inv_at
                    drive(inviso_input(c))
                    if iv and c > 30 then
                        inv_on_at = frame; drive({})
                        log("INVISIBLE at %d  %s", frame, gates()); snap()
                    elseif c > 90 then
                        log("  no inviso after try %d  %s", inv_try, gates())
                        if inv_try >= 4 then finish(false, "Reptile never turned invisible in FINISH HIM") return end
                        inv_at = 0
                    end
                end
            -- 2) fatality input
            elseif frame - inv_on_at >= 20 then
                if not WALK then snap_to(0x38) end
                if WALK and fat_at == 0 and dist() > 0x48 then
                    drive({ [FWD] = true })    -- walk in under his own legs
                elseif fat_at == 0 then
                    fat_at = frame; fat_try = fat_try + 1
                    log("F,F,D+HK (try %d)  %s", fat_try, gates())
                end
                local c = fat_at > 0 and frame - fat_at or -1
                if c >= 0 then drive(fatal_input(c)) end
                if c == 18 then log("  at HK press      %s", gates()) end
                if c == 24 then log("  after HK press   %s", gates()) end
                if c > 60 or (WALK and fat_at == 0 and frame - inv_on_at > 600) then
                    log("  no fatality after try %d  %s", fat_try, gates())
                    if fat_try >= 4 then finish(false, "fatality never started; " .. gates()) return end
                    fat_at = 0
                    if not iv then inv_on_at = 0; inv_at = 0; log("  he is VISIBLE again - re-doing inviso") end
                end
            else
                drive({})
            end
            local fd = r16(A.f_death)
            if fd ~= 0 and fd ~= 0xffff then
                fatal_at = frame; drive({})
                log("FATALITY STARTED at %d (f_death=%04x)  %s", frame, fd, gates()); snap()
            end
        end

        if fatal_at > 0 then
            local rel = frame - fatal_at
            if rel % 20 == 0 then log("  +%3d %s", rel, gates()); snap() end
            if rel == 200 then finish(true, "invisible fatality started and ran 200 frames") return end
        end

        if fight_at > 0 and ko_at == 0 and frame - fight_at > 2400 then finish(false, "never landed a KO") return end
        if finish_at > 0 and frame - finish_at > 2400 and fatal_at == 0 then finish(false, "timeout; " .. gates()) return end
    end

    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if frame > 14000 then finish(false, string.format("timeout psel=%d confirm=%d fight=%d ko=%d finish=%d",
        psel, confirm, fight_at, ko_at, finish_at)) end
end)
