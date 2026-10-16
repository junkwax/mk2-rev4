-- sz_juggle_freeze_test.lua
--
-- Guards the Sub-Zero freeze changes:
--   * ice_proc's five `is_he_helpless` gates were removed, so the STANDING ice
--     blast (D,F+LP) can now connect on an airborne, hit-stunned victim at all.
--   * both freezes (ground + air) now share an l_freeze cooldown, and a victim
--     can only be frozen once per airborne state (freeze_juggle_ok).
--
-- Trials:
--   grounded  control -- a plain standing freeze must still work, or nothing
--                        else measured here means anything.
--   cooldown  two freeze attempts back to back. The second must NOT come out:
--             that is the l_freeze gate in sz_lo_punch doing its job.
--
-- NOT covered here, deliberately: an airborne freeze actually landing. Measured
-- on this rig, a flip kick leaves the victim airborne for only ~9 ticks after
-- Sub-Zero recovers, while do_throw_ice needs ~13 ticks of throw animation
-- before the projectile exists -- so the ground blast cannot reach a
-- flip-kicked opponent no matter what the gates say, and the decision was to
-- leave the move's speed alone. The helpless-gate removal still matters for
-- setups with a wider window and for the air freeze.
--
-- Judged on P2 entering act_frozen (0401h) and on P1 reaching act_throw_ice.
--
-- Env: JFREEZE_LOG
-- Usage: tools/run_sz_juggle_freeze_test.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("JFREEZE_LOG") or (ROOT .. "/tools/sz_juggle_freeze_test.log")
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[jfreeze] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
local map = assert(io.open(ROOT .. "/src/mk2.map", "r"))
for line in map:lines() do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[name] = tonumber(addr, 16)
    end
end
map:close()
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate=sym("gstate"), curback=sym("curback"),
    p1_char=sym("p1_char"), p2_char=sym("p2_char"),
    p1_state=sym("p1_state"), p2_state=sym("p2_state"),
    p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"),
    p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
    p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
    p1_bar_view=sym("p1_bar_view"), p2_bar_view=sym("p2_bar_view"),
    winner_status=sym("winner_status"), battle_num=sym("battle_num"),
    map_position=sym("map_position"), f_freeze_timer=sym("f_freeze_timer"),
}

local OXVAL, OYPOS = 0x080, 0x0b0
local P_ACTION, P_FLAGS = 0x1f0, 0x210
local PB_REACTING = 2                   -- MAINEQU: pb_reacting .set 2 (was guessed as 1)
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_REPTILE = 8, 9
local ACT_THROW_ICE, ACT_FROZEN = 0x0010, 0x0401

local SZ_X, GAP = 260, 0x40
local TRIALS = { "grounded", "cooldown" }
local TRIAL_FRAMES = 340
local FLOOR_Y = 0

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local trial, trial_start = 1, 0
local cast_seen, froze_seen, cast_frame = false, false, 0
local fields, results, done = {}, {}, false
local cur = nil
local last_a1, last_a2 = -1, -1
local casts, was_casting = 0, false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function pact(p) local q=r32(p); if q==0 then return 0xffff end return r16(q+P_ACTION) end
local function pflags(p) local q=r32(p); if q==0 then return 0 end return r16(q+P_FLAGS) end
local function setx(p,x) local o=r32(p); if o~=0 then space:write_u32(o+OXVAL,(x & 0xffff)<<16) end end
local function gety(p) local o=r32(p); if o==0 then return nil end return s16(r16(o+OYPOS)) end

local function finish()
    if done then return end
    done = true
    log("")
    local g, a = results["grounded"], results["cooldown"]
    for _, k in ipairs(TRIALS) do
        local r = results[k]
        if r then
            log("RESULT %-9s cast=%s froze=%s  victim height at cast %d px, reacting=%s",
                k, r.cast and "yes" or "NO", r.froze and "YES" or "no",
                r.h_at_cast or -1, tostring(r.reacting_at_cast))
        end
    end
    if not g or not g.cast or not g.froze then
        log("FAIL jfreeze: the GROUNDED control did not freeze - rig is wrong or the "
            .. "move is broken; ignore everything else")
    elseif not a or (a.casts or 0) == 0 then
        log("FAIL jfreeze: the cooldown trial never threw any ice - it proves nothing")
    elseif (a.casts or 0) > 1 then
        log("FAIL jfreeze: %d freezes came out inside the %d-tick cooldown - the "
            .. "l_freeze gate in sz_lo_punch is not holding", a.casts, 0x60)
    else
        log("PASS jfreeze: standing freeze works, and a second freeze inside the "
            .. "cooldown was refused (%d cast, not 2)", a.casts)
    end
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["Coin 2"]=true, ["1 Player Start"]=true,
                   ["2 Players Start"]=true, ["P1 High Punch"]=true,
                   ["P1 Low Punch"]=true, ["P1 High Kick"]=true,
                   ["P1 Right"]=true, ["P1 Down"]=true, ["P1 Up"]=true,
                   ["P2 High Punch"]=true }
    local missing = {}
    for _,port in pairs(manager.machine.ioport.ports) do
        for _,f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then missing[#missing+1] = n end end
    if #missing > 0 then log("MISSING input field(s): %s", table.concat(missing, ", ")) end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 200 and frame < 1000 and (frame % 80) < 20
        end
        if name == "1 Player Start"  then return frame >= 1000 and frame < 1080 end
        if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
        return false
    end
    if fighting_frame == 0 then
        if p1_confirm > 0 then
            if name == "P1 High Punch" then return frame >= p1_confirm and frame < p1_confirm+45 end
            if name == "P2 High Punch" then return frame >= p1_confirm+70 and frame < p1_confirm+115 end
        end
        return false
    end

    local r = frame - trial_start
    if TRIALS[trial] == "cooldown" then
        -- two D,F+LP attempts about 30 ticks apart. freeze_cooldown is 060h
        -- (96 ticks), so the second one must be refused by sz_lo_punch.
        if name == "P1 Down" then
            return (r >= 40 and r < 48) or (r >= 78 and r < 86)
        end
        if name == "P1 Right" then
            return (r >= 48 and r < 56) or (r >= 86 and r < 94)
        end
        if name == "P1 Low Punch" then
            return (r >= 54 and r < 60) or (r >= 92 and r < 98)
        end
    else
        if name == "P1 Down"      then return r >= 40 and r < 48 end
        if name == "P1 Right"     then return r >= 48 and r < 56 end
        if name == "P1 Low Punch" then return r >= 54 and r < 60 end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- SZ standing ice blast vs a JUGGLED opponent ----")
    end
    for n,f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state,1); w16(A.p2_state,1)
        w16(A.p1_char,FT_SUBZERO); w16(A.p2_char,FT_REPTILE); w16(A.curback,0)
        if A.map_position ~= 0 then w16(A.map_position,0) end
        if A.battle_num ~= 0 then w16(A.battle_num,1) end
        if p1_confirm == 0 and frame-charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING then w16(A.p2_state,1) end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; trial_start = frame
        FLOOR_Y = gety(A.p2_obj) or 0
        log("fight start frame=%d, victim grounded oypos=%d", frame, FLOOR_Y)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar,MAX_HP); w16(A.p1_bar_view,MAX_HP)
    w16(A.p2_bar,MAX_HP); w16(A.p2_bar_view,MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status,0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer,1) end

    local mode = TRIALS[trial]
    local a1, a2 = pact(A.p1_proc), pact(A.p2_proc)

    -- Diagnostics: what is Sub-Zero actually doing? A trial that never casts
    -- is otherwise a black box, and guessing at input timing is how the last
    -- three runs were wasted.
    if a1 ~= last_a1 or a2 ~= last_a2 then
        local y = gety(A.p2_obj)
        log("  %s r=%3d p1act=%04x p2act=%04x victim %d px up reacting=%s",
            mode, frame - trial_start, a1, a2,
            y and (FLOOR_Y - y) or -1,
            tostring((pflags(A.p2_proc) & (1 << PB_REACTING)) ~= 0))
        last_a1, last_a2 = a1, a2
    end

    -- x only; y is entirely the game's business
    if not cast_seen then setx(A.p1_obj, SZ_X) end
    if not froze_seen then setx(A.p2_obj, SZ_X + GAP) end

    if a1 == ACT_THROW_ICE and not was_casting then
        casts = casts + 1
        log("%s: ice thrown (#%d) at r=%d", mode, casts, frame - trial_start)
    end
    was_casting = (a1 == ACT_THROW_ICE)

    if not cast_seen and a1 == ACT_THROW_ICE then
        cast_seen, cast_frame = true, frame
        local y = gety(A.p2_obj)
        cur = {
            cast = true,
            h_at_cast = y and (FLOOR_Y - y) or 0,
            reacting_at_cast = (pflags(A.p2_proc) & (1 << PB_REACTING)) ~= 0,
        }
        log("%s: ice thrown at frame %d; victim %d px up, reacting=%s",
            mode, frame, cur.h_at_cast, tostring(cur.reacting_at_cast))
    end

    if cast_seen and cur and not froze_seen and a2 == ACT_FROZEN then
        froze_seen = true; cur.froze = true
        log("%s: FROZE %d frames after the throw", mode, frame - cast_frame)
    end

    if frame - trial_start > TRIAL_FRAMES then
        cur = cur or { cast = false }
        cur.casts = casts
        results[mode] = cur
        log("---- %s done: cast=%s froze=%s ----", mode,
            cast_seen and "yes" or "no", froze_seen and "yes" or "no")
        trial = trial + 1
        if trial > #TRIALS then finish(); return end
        trial_start = frame
        cast_seen, froze_seen, cast_frame, cur = false, false, 0, nil
        last_a1, last_a2 = -1, -1
        casts, was_casting = 0, false
    end

    if frame > 40000 then log("ERROR backstop"); finish() end
end)
