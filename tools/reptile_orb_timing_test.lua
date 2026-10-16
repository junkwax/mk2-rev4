-- reptile_orb_timing_test.lua
--
-- Reptile's force ball, measured three ways, for BOTH variants: the slow ball
-- (Back,Back + HP+LP) and the fast one (Forward,Forward + HP+LP).
--
-- 1/2. Windup and cool-down, in TICKS.  No frame-counting or eyeballing -
--      do_slow_proj (MKZAP.ASM) marks its own boundaries:
--
--   zap_init_special_act act_slow_orb   <- p_action = act_slow_orb, tick 0
--   ... double_mframew, spawn ...
--   movi act_orb_sd -> p_action         <- the ball has LEFT: release tick
--   ... sleeps ...  retp                <- p_action leaves act_orb_sd: over
--
--      so dwell in act_slow_orb IS the windup and dwell in act_orb_sd IS the
--      post-release recovery.
--
-- 3.   Velocity, in px/tick, read off the ball itself: find the orb process
--      on the active list by procid (pid_orb1/pid_orb2) and diff its object's
--      oxpos every tick.  Deliberately NOT inferred from "when did P2's health
--      drop" - an earlier cut did that and produced impossible flight times,
--      because a health drop dates the hit, not the launch, and anything else
--      that touches the bar looks identical to it.
--
-- Expected:
--   windup 16, recovery 14, identical for both variants
--   slow 3 px/tick (030000h), fast 7 px/tick (070000h)
--
-- Recovery is 14 on PURPOSE.  UMK3's orb3 spends 24 after the ball leaves and
-- that was built, measured at 24/24, and then backed out - 24 ticks of lockout
-- made it a different move.  The velocity IS UMK3's.  So a 24 here is a
-- regression now, not a fidelity win.
--
-- Env: ROB_LOG, ROB_TRIALS
-- Usage: tools\run_reptile_orb_timing_test.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("ROB_LOG") or (ROOT .. "/tools/reptile_orb_timing_test.log")
local TRIALS = tonumber(os.getenv("ROB_TRIALS") or "3")

local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = "[orb] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/MK2.MAP", "r")
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local function sym(n)
    if not symbols[n] then log("FATAL: symbol %s missing from MK2.MAP", n) end
    return symbols[n] or 0
end

local A = {
    active = sym("active"),
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"),
}

local acts = {}
do
    local fh = io.open(ROOT .. "/src/MAINEQU.ASM", "r")
    for line in fh:lines() do
        local n, v = line:match("^(act_[%w_]+)%s+%.set%s+([0-9a-fA-F]+)h")
        if n and v then acts[n] = tonumber(v, 16) end
    end
    fh:close()
end
local function act(n)
    if not acts[n] then log("FATAL: %s not in MAINEQU.ASM", n) end
    return acts[n] or -1
end
local ACT_SLOW_ORB, ACT_ORB_SD = act("act_slow_orb"), act("act_orb_sd")
local ACT_STANCE = act("act_stance")

local OXVAL, OXPOS = 0x080, 0x090
local P = { next = 0x000, id = 0x020, pa8 = 0x0c0, action = 0x1f0 }
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_REPTILE, FT_KANG = 9, 1
local PID_ORB1, PID_ORB2 = 0x0702, 0x0802   -- MAINEQU.ASM
local MAX_HP = 0xa1
local P1X, P2X = 120, 320

local space, frame = nil, 0
local fields = {}
local charsel_frame, fighting_frame, confirm_frame = 0, 0, 0
local phase, phase_frame = "boot", 0
local trial, variant = 1, "slow"
local results, done = {}, false
local t_windup, t_release, t_end = -1, -1, -1
local last_orb_x, steps = nil, {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function pact(p)
    local q = r32(p); if q == 0 then return 0xffff end
    return r16(q + P.action)
end
local function setx(op, x)
    local o = r32(op); if o == 0 then return end
    w32(o + OXVAL, (x & 0xffff) << 16)
    w16(o + OXPOS, x & 0xffff)
end
local function set_phase(p) phase = p; phase_frame = frame end

-- the ball: walk the active process list for the orb procid, take its pa8
local function orb_x()
    local p = r32(A.active)
    local guard = 0
    while p ~= 0 and guard < 400 do
        local id = r16(p + P.id)
        if id == PID_ORB1 or id == PID_ORB2 then
            local o = r32(p + P.pa8)
            if o ~= 0 then return s16(r16(o + OXPOS)) end
            return nil
        end
        p = r32(p + P.next)
        guard = guard + 1
    end
    return nil
end

-- the ball is steered/damped by nothing while it flies level, so the per-tick
-- step should be one constant.  Report the most common step, and how solid it
-- was, rather than a mean that a spawn/despawn outlier could drag.
local function modal_step(list)
    if #list == 0 then return nil, 0, 0 end
    local count, best, bestn = {}, nil, 0
    for _, v in ipairs(list) do
        count[v] = (count[v] or 0) + 1
        if count[v] > bestn then bestn = count[v]; best = v end
    end
    return best, bestn, #list
end

local function finish()
    if done then return end
    done = true
    log("")
    log("---- Reptile force ball ----")
    log(" variant | windup | recovery | px/tick | consistency")
    local okw, okr, okv = 0, 0, 0
    for _, r in ipairs(results) do
        local want = (r.variant == "fast") and 7 or 3
        log("  %-6s | %6d | %8d | %7s | %d of %d ticks",
            r.variant, r.windup, r.recovery,
            r.px and tostring(r.px) or "-", r.pxn or 0, r.pxtot or 0)
        if r.windup == 16 then okw = okw + 1 end
        if r.recovery == 14 then okr = okr + 1 end
        if r.px == want then okv = okv + 1 end
    end
    log("")
    log("recovery target is 14 - OURS.  UMK3's orb3 spends 24 and that was")
    log("        deliberately rejected; a 24 here is a regression, not fidelity.")
    log("UMK3 velocity: slow SCX(030000h) = 3 px/tick, fast SCX(070000h) = 7 px/tick")
    log("RESULT %d/%d windups = 16, %d/%d recoveries = 14, %d/%d velocities on target",
        okw, #results, okr, #results, okv, #results)
    if #results == 0 then log("FAIL: the force ball never came out") end
    manager.machine:exit()
end

local function cache_fields()
    local want = {
        ["Coin 1"] = 1, ["1 Player Start"] = 1,
        ["P1 Left"] = 1, ["P1 Right"] = 1,
        ["P1 High Punch"] = 1, ["P1 Low Punch"] = 1,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input: %s", n) end end
end

-- P1 starts on the LEFT: his back is Left, forward is Right.
local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame > 300 and (frame % 90) < 22 end
        if name == "1 Player Start" then
            return frame > 520 and (frame % 160) >= 80 and (frame % 160) < 120
        end
        return false
    end
    if fighting_frame == 0 then
        if confirm_frame > 0 and name == "P1 High Punch" then
            return frame >= confirm_frame and frame < confirm_frame + 60
        end
        return false
    end

    if phase ~= "throw" then return false end
    local c = frame - phase_frame
    local dir = (variant == "slow") and "P1 Left" or "P1 Right"
    -- two clean taps with a gap, then BOTH punches together
    if name == dir then return (c >= 4 and c < 8) or (c >= 12 and c < 16) end
    if name == "P1 High Punch" or name == "P1 Low Punch" then
        return c >= 20 and c < 26
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("Reptile force ball: act_slow_orb=%04x act_orb_sd=%04x pid %04x/%04x",
            ACT_SLOW_ORB, ACT_ORB_SD, PID_ORB1, PID_ORB2)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_REPTILE); w16(A.p2_char, FT_KANG)
        w16(A.curback, 0)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        set_phase("settle")
        log("fight start frame=%d", frame)
    end
    if fighting_frame == 0 then
        if frame > 7000 then log("ERROR never reached the fight"); finish() end
        return
    end

    -- keep the round alive; nobody is allowed to win or die under the rig
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if r16(A.winner_status) ~= 0 then w16(A.winner_status, 0) end

    local a1 = pact(A.p1_proc)
    local c = frame - phase_frame

    if phase == "settle" then
        setx(A.p1_obj, P1X); setx(A.p2_obj, P2X)
        if c > 30 and a1 == ACT_STANCE then
            t_windup, t_release, t_end = -1, -1, -1
            last_orb_x, steps = nil, {}
            set_phase("throw")
        end
        return
    end

    if phase == "throw" then
        -- hold P2 still so the ball always has the same room to fly
        setx(A.p2_obj, P2X)

        local ox = orb_x()
        if ox then
            if last_orb_x then
                local d = math.abs(ox - last_orb_x)
                if d > 0 and d < 40 then steps[#steps + 1] = d end
            end
            last_orb_x = ox
        end

        if a1 == ACT_SLOW_ORB and t_windup < 0 then t_windup = frame end
        if a1 == ACT_ORB_SD and t_release < 0 and t_windup >= 0 then t_release = frame end
        -- the move ends before the ball does, so keep tracking until BOTH the
        -- proc has left act_orb_sd and the ball is gone
        if t_release >= 0 and a1 ~= ACT_ORB_SD and t_end < 0 then t_end = frame end
        if t_end >= 0 and (ox == nil or c > 250) then
            local px, pxn, pxtot = modal_step(steps)
            results[#results + 1] = {
                variant = variant,
                windup = t_release - t_windup,
                recovery = t_end - t_release,
                px = px, pxn = pxn, pxtot = pxtot,
            }
            log("%s trial %d: windup %d, recovery %d, px/tick %s (%d of %d ticks)",
                variant, trial, t_release - t_windup, t_end - t_release,
                px and tostring(px) or "NONE", pxn, pxtot)
            if variant == "slow" then
                if trial >= TRIALS then variant = "fast"; trial = 1
                else trial = trial + 1 end
            else
                if trial >= TRIALS then finish(); return end
                trial = trial + 1
            end
            set_phase("settle")
            return
        end
        if c > 400 then
            log("%s trial %d: TIMEOUT - never saw the move (p1 act %04x)",
                variant, trial, a1)
            if variant == "slow" then variant = "fast"; trial = 1
            elseif trial >= TRIALS then finish(); return
            else trial = trial + 1 end
            set_phase("settle")
        end
        return
    end
end)
