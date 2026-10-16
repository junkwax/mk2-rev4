-- kintaro_getup_kick_test.lua
--
-- Kintaro's GET-UP KICK (goro_getup_kick / goro_getup_kick_check, MKBOSS.ASM).
--
-- The move is the GETUPKIK sequence authored in TIGER3.IMG and never coded:
-- TIGERGETUP1..4 straight into TIGERKICK1..4.  It is offered from boss_getup,
-- so the only way to exercise it is to knock Kintaro down over and over and
-- stand on him.  The rig does exactly that: P1 is pinned next to him holding
-- Down and tapping High Punch, which is Liu Kang's uppercut - a knockdown.
--
-- ATTRIBUTION.  a_goro_kick has one other caller (rt_goro_close), so "the
-- kick animation played" is not by itself evidence.  Every branch of the
-- gate writes its own breadcrumb to @debug4 instead:
--
--   7100  refused - opponent out of reach            (boss_getup ran)
--   7101  in range, ask_mr_diff said no              (boss_getup ran)
--   7102  TAKEN - jumping to goro_getup_kick         (boss_getup ran)
--   7103  the kick half is swinging (striker armed)
--
-- so knockdowns, offers, takes and swings are all counted separately, and a
-- run that never sees 7100/7101/7102 means the hook never ran at all rather
-- than that the move is merely rare.
--
-- Env: KGK_LOG, KGK_FRAMES, KGK_DIFF
-- Usage: tools\run_kintaro_getup_kick_test.ps1

local LOGP   = os.getenv("KGK_LOG") or "C:/Users/you/Workplace/mk2-main/tools/kintaro_getup_kick_test.log"
local FRAMES = tonumber(os.getenv("KGK_FRAMES") or "5400")
local DIFF   = tonumber(os.getenv("KGK_DIFF") or "9")

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[kgk] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), diff = sym("diff"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    debug4 = sym("debug4"), f_freeze_timer = sym("f_freeze_timer"),
    c_kahn_rg_n = sym("c_kahn_rg_n"),
}

local OXVAL, OXPOS = 0x080, 0x090
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_GORO = 1, 12
local ARENA = 5                 -- THE ARMORY; any legal arena would do

local BC_FAR, BC_ROLL, BC_TAKE, BC_SWING = 0x7100, 0x7101, 0x7102, 0x7103

local frame, space = 0, nil
local last_gstate = -1
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local n_far, n_roll, n_take, n_swing = 0, 0, 0, 0
local n_p2_hits, n_getup_seen = 0, 0
local last_p2hp = MAX_HP
local kick_damage, kick_hits = 0, 0
local last_bc, last_p1hp = 0, MAX_HP
local swing_frame = -999
-- Set when the gate takes the move: P1 stops ducking and stands there so the
-- kick has something at standing height to hit.  Holding Down through it is a
-- legitimate way to duck a high box, but it measures the duck, not the move.
local stand_until = -999
local snap_at = -999
local fields = {}
local done = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function pin(objptr, x)
    local o = r32(objptr); if o == 0 then return end
    space:write_u32(o + OXVAL, (x & 0xffff) << 16)
    w16(o + OXPOS, x & 0xffff)
end

local function finish(reason)
    if done then return end
    done = true
    local offers = n_far + n_roll + n_take
    log("RESULT %s: p1_hits_landed=%d boss_getup_calls=%d gate_ran=%d out_of_range=%d roll_declined=%d taken=%d swings=%d hits=%d damage=%d",
        reason, n_p2_hits, n_getup_seen, offers, n_far, n_roll, n_take, n_swing, kick_hits, kick_damage)
    if offers == 0 then
        log("FAIL: goro_getup_kick_check never ran - Kintaro was never knocked down, or the hook is dead")
    elseif n_take == 0 then
        log("FAIL: the gate ran %d times and never took the move", offers)
    elseif n_swing < n_take then
        log("FAIL: taken %d times but only %d swings reached striker", n_take, n_swing)
    elseif kick_hits == 0 then
        log("PARTIAL: the get-up kick ran %d times but never connected", n_swing)
    else
        log("PASS: get-up kick fired %d times, connected %d, %d damage total", n_swing, kick_hits, kick_damage)
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true,
                   ["P1 Down"]=true, ["UI Select"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        if name == "UI Select" then return frame >= 5 and frame < 35 end
        return false
    end
    if fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm > 0 then
            return frame >= p1_confirm and frame < p1_confirm + 45
        end
        return false
    end
    -- In the fight: hold Down, tap High Punch = Liu Kang's uppercut, on a
    -- 40-frame cycle so he recovers between attempts.
    if frame < stand_until then return false end
    local t = (frame - fighting_frame) % 40
    if name == "P1 Down" then return t < 24 end
    if name == "P1 High Punch" then return t >= 8 and t < 14 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- kintaro get-up kick: debug4=%08x diff=%d frames=%d ----", A.debug4, DIFF, FRAMES)
        if A.debug4 == 0 then log("ERROR debug4 not in MK2.MAP - rebuild first") end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("frame=%d gstate %d -> %d", frame, last_gstate, gs)
        last_gstate = gs
    end
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, FT_GORO)
        w16(A.curback, ARENA)
        w16(A.map_position, 13)      -- Kintaro's rung
        w16(A.battle_num, 14)
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight_start frame=%d p1=%d p2=%d curback=%d", frame,
            r16(A.p1_char), r16(A.p2_char), r16(A.curback))
        last_p1hp = MAX_HP
    end

    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish("no_fight") end
        return
    end

    if r16(A.p2_char) ~= FT_GORO then
        log("ERROR p2 is not Kintaro (p2_char=%d) frame=%d", r16(A.p2_char), frame)
        finish("wrong_opponent"); return
    end

    w16(A.diff, DIFF)
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    -- Damage taken since the last frame, read BEFORE health is restored.
    local hp = r16(A.p1_bar)
    if hp < last_p1hp and frame - swing_frame <= 12 then
        kick_damage = kick_damage + (last_p1hp - hp)
        kick_hits = kick_hits + 1
        log("HIT: get-up kick took %d off P1 (rel=%d) hits=%d", last_p1hp - hp,
            frame - swing_frame, kick_hits)
    end

    -- Did P1's uppercut actually land?  Without this a quiet run cannot be
    -- told apart from "he was never knocked down in the first place".
    local hp2 = r16(A.p2_bar)
    if hp2 < last_p2hp then
        n_p2_hits = n_p2_hits + 1
        if n_p2_hits <= 8 then
            log("p1 landed %d on Kintaro (hit #%d, frame=%d)", last_p2hp - hp2, n_p2_hits, frame)
        end
    end

    -- Keep the round alive so he can be knocked down again and again.
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    last_p1hp = MAX_HP; last_p2hp = MAX_HP
    if r16(A.winner_status) ~= 0 then w16(A.winner_status, 0) end

    -- Stand on him.  Uppercuts only knock down from point blank, and the
    -- get-up kick's own range gate is 060h, so both halves need him close.
    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    if x1 and x2 and math.abs(x2 - x1) > 56 then
        if x2 > x1 then pin(A.p1_obj, x2 - 48) else pin(A.p1_obj, x2 + 48) end
    end

    -- kahn_reground_check bumps c_kahn_rg_n once per boss_getup, which is the
    -- OTHER get-up site.  Counting it separately keeps the two apart: a boss
    -- uppercut knockdown goes through goro_fall_on_back (MKREACT.ASM), not
    -- through boss_getup, and reading one as the other is how the first run
    -- of this rig read "never knocked down" when he was knocked down 20 times.
    if A.c_kahn_rg_n ~= 0 then
        local rg = r16(A.c_kahn_rg_n)
        if rg ~= n_getup_seen then n_getup_seen = rg end
    end

    local bc = r16(A.debug4)
    if bc ~= last_bc then
        if bc == BC_FAR then
            n_far = n_far + 1
        elseif bc == BC_ROLL then
            n_roll = n_roll + 1
        elseif bc == BC_TAKE then
            n_take = n_take + 1
            stand_until = frame + 45
            log("TAKE #%d at frame=%d gap=%d (P1 stands until %d)", n_take, frame,
                math.abs((x2 or 0) - (x1 or 0)), stand_until)
        elseif bc == BC_SWING then
            n_swing = n_swing + 1
            swing_frame = frame
            log("SWING #%d at frame=%d gap=%d", n_swing, frame, math.abs((x2 or 0) - (x1 or 0)))
            if n_swing <= 3 then
                manager.machine.video:snapshot()
                -- and again when the box is actually live.  striker plays
                -- a_goro_kick's 4 rows at sleep 3 before it opens, so the
                -- extended pose is ~12 ticks after the swing crumb - a snap
                -- on the crumb alone only ever catches TIGERKICK1.
                snap_at = frame + 13
            end
        end
        last_bc = bc
    end

    if frame == snap_at then manager.machine.video:snapshot() end

    if frame - fighting_frame > FRAMES then finish("window_elapsed") end
    if frame > 40000 then finish("global_timeout") end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
