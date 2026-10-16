-- drone_juggle_test.lua
--
-- Proves the drone's JUGGLE COMBOS (MKDRONE.ASM, drone_juggle_*) actually run
-- and actually convert -- not just "the tables assemble".
--
--   Kung Lao  aaHP,HP -> jump punch -> jump kick -> dive kick
--   Mileena   aaLP -> roll -> straight-up jump kick -> air sai
--
-- SETUP.  P2 is the drone, P1 is a passive human punching bag.  Each trial
-- makes P1 really jump (holding P1 Up -- never pin oypos, that fights the
-- game's own ground/airborne bookkeeping and measures the rig instead of the
-- game) and, while he is off the floor, pulses his p_action to act_kano_sd:
-- the "his roll was blocked, he is bouncing in front of me" opening that
-- c_kano_sd answers.  That is the exact scenario the combo exists for.
--
-- MEASUREMENT.  Two independent things, because either alone lies:
--   * the ORDERED action ids the drone goes through   (did the script run)
--   * how much of P1's bar it took in that window     (did it convert)
-- p_juggle_step is watched too, so an armed-but-dropped combo is visible as
-- itself rather than as silence.
--
-- Env: JUGGLE_LOG, JUGGLE_CASE (hh|fn2), JUGGLE_DIFF (default 9)
-- Usage: tools\run_drone_juggle_test.ps1

local LOGP = os.getenv("JUGGLE_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_juggle_test.log"
local CASE = os.getenv("JUGGLE_CASE") or "hh"
local DIFF = tonumber(os.getenv("JUGGLE_DIFF") or "9")

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[juggle] " .. string.format(fmt, ...)
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
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), diff = sym("diff"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"),
    debug2 = sym("debug2"), debug3 = sym("debug3"), debug4 = sym("debug4"),
    rand = sym("rand"), debug1 = sym("debug1"),
}

local OXVAL, OXPOS, OYPOS = 0x080, 0x090, 0x0b0
local OYVEL, OGRAV = 0x060, 0x020   -- ograv aliases oslink (DISPEQU.ASM)
local PROC_ACTION   = 0x1f0        -- p_action     = pdata+0f0h
local PROC_GANIY    = 0x200        -- p_ganiy      = pdata+100h
local PROC_JUGGLE   = 0x3b0        -- p_juggle_step= pdata+2b0h
local PROC_JUGGLE_HP= 0x3c0        -- p_juggle_hp  = pdata+2c0h
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1

local FT_HATHEAD, FT_KANG, FT_FN2 = 0, 1, 5
local FT_RAIDEN, FT_SUBZERO, FT_JAX = 7, 8, 11
local ACT_KANO_SD = 0x0619

-- the ordered links each script is supposed to produce
local CASES = {
    -- Kung Lao's links 3 and 4 used to be a second jump-in and a dive kick.
    -- The flip punch throws the victim 202px away (measured, every trial), so
    -- neither could ever connect; the script now finishes with the hat, which
    -- is the link that range actually allows.  See hhj_hat in MKDRONE.ASM.
    hh = { char = FT_HATHEAD, name = "kung lao",
        links = {
            { act = 0x0101, name = "aaHP" },
            { act = 0x0201, name = "jump punch" },
            { act = 0x0001, name = "hat" },
        } },
    -- Mileena's roll carries her 113px PAST him, so her old links 3 and 4
    -- (straight-up jump kick, air sai) were aimed at a man who was no longer
    -- above her.  She finishes with the ground sai for the same reason Kung
    -- Lao finishes with the hat.
    fn2 = { char = FT_FN2, name = "mileena",
        links = {
            { act = 0x0102, name = "aaLP" },
            { act = 0x020e, name = "roll" },
            { act = 0x000a, name = "sai" },
        } },
    -- The other fourteen run generic_juggle_script: anti-air punch, then the
    -- character's own projectile. Three samples with deliberately different
    -- projectiles -- an instant bolt, a slow ice blast, a travelling wave --
    -- because "it works for Raiden" is not evidence that it works at all.
    raiden  = { char = FT_RAIDEN,  name = "raiden",
        links = { { act = 0x0101, name = "aaHP" }, { act = 0x000f, name = "bolt" } } },
    subzero = { char = FT_SUBZERO, name = "sub-zero",
        links = { { act = 0x0101, name = "aaHP" }, { act = 0x0010, name = "ice" } } },
    jax     = { char = FT_JAX,     name = "jax",
        links = { { act = 0x0101, name = "aaHP" }, { act = 0x0014, name = "wave" } } },
}
local C = CASES[CASE] or CASES.hh

local TRIALS      = 10
-- Each trial is a run of OFFERS, not one.  An offer only turns into a combo
-- if the drone happens to be in a beware loop when it lands, so one offer
-- per trial makes the whole run hinge on a coin flip that is not the thing
-- being measured.  Trial length is jittered for the same reason.
local SUB         = 70            -- frames per offer
local function trial_len(i) return 350 + ((i * 37) % 53) end
local JUMP_AT     = 12            -- hold Up this far into an offer
local JUMP_HOLD   = 10
local PULSE_LEN   = 8
-- Two kinds of offer, alternating, because there are two hooks and they
-- want opposite geometry:
--
--   JUMP-IN (even offers, far): P1 really jumps at the drone.  The drone's
--     own angle-jump reaction works out where he will land and, if that is
--     close, lands in flip_towards_land_close -- the anti-air hook.  Nothing
--     is faked here at all.  It needs to start beyond 080h or the drone
--     answers with a jump-up kick before that code is reached.
--   ROLL BOUNCE (odd offers, near): P1's action is pulsed to act_kano_sd
--     while he is off the floor -- "his roll was blocked and he is bouncing"
--     -- which is the c_kano_sd hook.  Near, because c_kano_sd walks in to
--     046h first and a long walk outlives the bounce.
--
-- Start OUTSIDE the close game either way: at 3ch the drone is already in
-- cmf_close swinging every tick, never sits in a beware loop, and never sees
-- the opening at all.
local GAP_JUMPIN  = 0x94
local GAP_BOUNCE  = 0x54
local TRACE_TRIALS = 4            -- dump the drone's action stream for these

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local trial_idx, trial_start = 1, 0
local pulsed, pulse_left = false, 0
local seen, seen_names = {}, {}
local bar_at_start, bar_min = MAX_HP, MAX_HP
local gate_max, step_max = 0, 0
local combo_frame, combo_bar, combo_min, last_step_frame = 0, MAX_HP, MAX_HP, 0
local armed_seen = false
local prev_h = 0
local lua_rand = 0x2545f491
local last_drone_act = -1
local results = {}
local fields = {}
local done = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objw(p, off)
    local o = r32(p); if o == 0 then return nil end
    return s16(r16(o + off))
end
local function procw(p, off)
    local q = r32(p); if q == 0 then return nil end
    return r16(q + off)
end
local function set_act(p, v)
    local q = r32(p); if q == 0 then return end
    w16(q + PROC_ACTION, v)
end
local function pin(objptr, x)
    local o = r32(objptr); if o == 0 then return end
    space:write_u32(o + OXVAL, (x & 0xffff) << 16)
    w16(o + OXPOS, x & 0xffff)
end

-- how far P1 is off his own grounded anchor: positive = airborne
local function p1_height()
    local g = procw(A.p1_proc, PROC_GANIY)
    local y = objw(A.p1_obj, OYPOS)
    if not g or not y then return 0 end
    return s16(g) - y
end

-- even offers are the jump-in, odd offers the roll bounce
function jumpin_offer(rel) return (math.floor(rel / SUB) % 2) == 0 end

local function finish()
    if done then return end
    done = true
    local converted, best, started, ran = 0, 0, 0, 0
    for _, r in ipairs(results) do
        log("trial %-2d gate=%d step=%d links=%-34s combo_dmg=%3d (%2d%%) trial_dmg=%3d armed=%s",
            r.idx, r.gate, r.step, table.concat(r.links, ">"), r.cdmg,
            math.floor(r.cdmg * 100 / MAX_HP), r.dmg, r.armed and "yes" or "no")
        if r.step >= 1 then ran = ran + 1 end
        if r.step >= 2 then started = started + 1 end
        if r.cdmg > best then best = r.cdmg end
        if r.cdmg >= 0x20 then converted = converted + 1 end
    end
    log("---- %s (diff %d): %d/%d started, %d chained 2+ links, %d converted 20%%+, best %d (%d%%) ----",
        C.name, DIFF, ran, #results, started, converted, best,
        math.floor(best * 100 / MAX_HP))
    if DIFF == 0 then
        -- honesty control: rpt_juggle is 0 below diff 4, so an easy CPU must
        -- never produce a combo at all.
        if ran == 0 then
            log("PASS juggle-control: no combo at diff 0, as the table says")
        else
            log("FAIL juggle-control: %d combos fired at diff 0", ran)
        end
    elseif started >= 2 and best >= 0x20 then
        log("PASS juggle: %s chains its combo and converts", C.name)
    elseif ran >= 1 then
        log("FAIL juggle: %s starts the script but drops it (2+ links %d, best dmg %d)",
            C.name, started, best)
    else
        log("FAIL juggle: %s never started a combo", C.name)
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true,
                   ["P1 High Punch"]=true, ["P1 Up"]=true, ["P1 Right"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm > 0 then
            return frame >= p1_confirm and frame < p1_confirm + 45
        end
        return false
    end
    if name == "P1 Up" or name == "P1 Right" then
        if combo_frame > 0 then return false end   -- combo running: hands off
        local rel = frame - trial_start
        local sub = rel % SUB
        if name == "P1 Right" and not jumpin_offer(rel) then return false end
        return sub >= JUMP_AT and sub < JUMP_AT + JUMP_HOLD
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- juggle combo: P1=LiuKang(human bag) P2=%s(drone) diff=%d ----",
            C.name, DIFF)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, C.char)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        trial_start = frame
        log("fight start frame=%d", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    -- KEEP THE RNG ALIVE.  @rand is re-seeded at every round start
    -- (MAIN.ASM, "Reseed RNGs at round start") from battle_num and the win
    -- counters -- all constant in a rig -- so a scripted setup replays the
    -- SAME stream after every restart and ONE probability roll decides every
    -- trial identically. That is how a 60% gate scored 0/14 and read as a
    -- broken gate. Stir it every frame instead.
    if A.rand ~= 0 then
        lua_rand = (lua_rand * 1103515245 + 12345) & 0xffffffff
        space:write_u32(A.rand, lua_rand)
    end
    w16(A.diff, DIFF)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    local rel = frame - trial_start
    local x1 = objw(A.p1_obj, OXPOS)

    local sub = rel % SUB
    -- Between offers (and only while no combo is running) put the pair back
    -- where the offer starts and heal the bag, so every offer is the same
    -- proposition and the damage figure belongs to one combo.
    if combo_frame == 0 and sub < 6 then
        w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
        local gap = jumpin_offer(rel) and GAP_JUMPIN or GAP_BOUNCE
        if x1 then pin(A.p2_obj, x1 + gap) end
        bar_at_start, bar_min = MAX_HP, MAX_HP
        pulsed = false
    end

    if rel < 20 then
        if rel == 0 then
            seen, seen_names, pulsed, armed_seen = {}, {}, false, false
            last_drone_act = -1
            gate_max, step_max = 0, 0
            combo_frame, combo_bar, combo_min, last_step_frame = 0, MAX_HP, MAX_HP, 0
            if A.debug3 ~= 0 then space:write_u32(A.debug3, 0) end
            if A.debug4 ~= 0 then space:write_u32(A.debug4, 0) end
        end
    end

    do
        local bar = r16(A.p1_bar)
        if bar < bar_min and bar > 0 then bar_min = bar end
        -- The combo window closes a fixed distance after the LAST link, not
        -- at a fixed 3s: a wide window just re-measures the drone's normal
        -- pressure afterwards and inflates the number.
        -- 20 was too tight once the finisher became a PROJECTILE: the hat is
        -- thrown at 200px and takes real time to arrive, so a window that
        -- closes on the throw frame scores a connecting hat as a miss.
        if combo_frame > 0 and frame - last_step_frame <= 45 then
            if bar < combo_min and bar > 0 then combo_min = bar end
        end
        -- Only ever heal him BETWEEN offers.  Healing mid-combo puts his bar
        -- back up under the drone's own "did that link connect" test and
        -- kills the chain the rig is supposed to be measuring.
        if bar < 0x18 and combo_frame == 0 then
            w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
        end
    end

    -- ASM breadcrumbs: how far the gate chain got, and how deep the script ran
    if A.debug3 ~= 0 then
        local g = r32(A.debug3) & 0xff
        if g > gate_max then gate_max = g end
    end
    if A.debug4 ~= 0 then
        local s = r32(A.debug4) & 0xff
        if s > step_max then
            step_max = s
            last_step_frame = frame
        end
        if s >= 1 and combo_frame == 0 then
            combo_frame = frame
            last_step_frame = frame
            combo_bar = r16(A.p1_bar)
            combo_min = combo_bar
        end
    end

    -- Offer the opening when he is off the ground but COMING DOWN and still
    -- low: that is what an anti-air is.  Offering it at the apex only proves
    -- a standing punch cannot reach 120px up.
    local h = p1_height()
    if not pulsed and combo_frame == 0 and sub > JUMP_AT
       and not jumpin_offer(rel) and h > 0x10 then
        pulsed, pulse_left = true, PULSE_LEN
    end
    prev_h = h
    if pulse_left > 0 then
        set_act(A.p1_proc, ACT_KANO_SD)
        if pulse_left == PULSE_LEN then
            -- Give him the LAUNCH, not just the label.  kano_blocked (MKPROP)
            -- answers a blocked roll with oyvel -0a0000h under 06000h gravity
            -- -- a long float, which is the whole reason the combo exists.
            -- A plain jump is not a stand-in for it: he is back on the floor
            -- two frames after the drone finishes thinking, so the launcher
            -- lands on a grounded man and there is nothing to juggle.
            local o = r32(A.p1_obj)
            if o ~= 0 then
                space:write_u32(o + OYVEL, 0x100000000 - 0xa0000)
                space:write_u32(o + OGRAV, 0x6000)
            end
        end
        pulse_left = pulse_left - 1
    end

    -- watch the drone
    local dact = procw(A.p2_proc, PROC_ACTION)
    if dact and dact ~= last_drone_act then
        if trial_idx <= TRACE_TRIALS then
            log("  t%d rel=%-3d drone act=0x%04x  his act=0x%04x h=%d gap=%s",
                trial_idx, rel, dact, procw(A.p1_proc, PROC_ACTION) or 0,
                p1_height(), tostring(x1 and (objw(A.p2_obj, OXPOS) - x1)))
        end
        last_drone_act = dact
        for i, l in ipairs(C.links) do
            if l.act == dact then
                local n = #seen
                -- record links in script order, no repeats of the same step
                if n == 0 or seen[n] < i then
                    seen[#seen+1] = i
                    seen_names[#seen_names+1] = l.name
                end
            end
        end
    end
    local jstep = procw(A.p2_proc, PROC_JUGGLE)
    if jstep and jstep ~= 0 and jstep <= 8 then armed_seen = true end
    if combo_frame > 0 and trial_idx <= TRACE_TRIALS
       and frame - combo_frame <= 90 and (frame % 3) == 0 then
        log("    t%d +%-3d bar=%3d marked=%3d step=%d hisact=0x%04x h=%3d droneact=0x%04x dh=%d",
            trial_idx, frame - combo_frame, r16(A.p1_bar),
            procw(A.p2_proc, PROC_JUGGLE_HP) or -1, jstep or -1,
            procw(A.p1_proc, PROC_ACTION) or 0, p1_height(),
            procw(A.p2_proc, PROC_ACTION) or 0,
            (procw(A.p2_proc, PROC_GANIY) or 0) - (objw(A.p2_obj, OYPOS) or 0))
    end

    if rel >= trial_len(trial_idx) then
        if A.debug1 ~= 0 then
            local why = { [1]="round over", [2]="link did not connect",
                          [3]="he landed", [4]="knocked out of reach",
                          [5]="ok" }
            log("  t%d chain ended: %s", trial_idx,
                why[r16(A.debug1)] or ("?" .. r16(A.debug1)))
        end
        results[#results+1] = { idx = trial_idx, links = seen_names,
                                dmg = bar_at_start - bar_min, armed = armed_seen,
                                gate = gate_max, step = step_max,
                                cdmg = (combo_frame > 0) and (combo_bar - combo_min) or 0 }
        trial_idx = trial_idx + 1
        if trial_idx > TRIALS then finish(); return end
        trial_start = frame
    end
    if frame > 30000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
