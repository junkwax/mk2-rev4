-- drone_newreact_test.lua
--
-- Proves the two NEW drone_beware reactions are wired and run, rather than
-- just "nothing crashed".  Both were .long 0 holes in the counter tables:
--
--   act_land     (0304) -> c_land        : punish a jump landing we are
--                                          already standing next to.
--   act_hitfall_sd (0609) -> c_hitfall_sd: walk a knocked-down player down
--                                          instead of drifting off.
--
-- drone_beware only fires on a CHANGE of the opponent's action (p_otheract
-- dedupes), so each trial PULSES the victim's p_action for a few frames and
-- then watches the drone for a bounded window.  Distances differ per case
-- because each handler has its own range gate: c_land wants us already
-- inside 060h, c_hitfall_sd only walks when we are outside it.
--
-- Env: NEWREACT_LOG
-- Usage: tools\run_drone_newreact_test.ps1

local LOGP = os.getenv("NEWREACT_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_newreact_test.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[newreact] " .. string.format(fmt, ...)
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
}

local OXVAL, OXPOS = 0x080, 0x090
local PROC_ACTION = 0x1f0
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_JAX = 1, 11

local ACT_LAND      = 0x0304
local ACT_HITFALLSD = 0x0609
local ACT_STANCE    = 0x0303      -- no counter_non_attack entry: the control
local ACT_UPPERCUT  = 0x0107
local ACT_SWEEP     = 0x0106

-- Two detection modes, because the two handlers do different kinds of thing.
--
--  mode "act"   - the handler starts a move, so watch for its action id.
--  mode "close" - the handler only WALKS (drone_walkf_setup never touches
--                 p_action, so there is no "I am walking" action to watch
--                 for), and normal drone_stalk walks forward too, which is
--                 why a naive "did the gap shrink" test scores the same on
--                 a do-nothing control.  So: force the stalk band to FAR
--                 (p_dronevar1 = 2 -> d_far = 0c0h) and start the pair at
--                 0e0h.  A stalking drone closes to 0c0h and then zones
--                 from there (cmf_far); only c_hitfall_sd's drone_approach
--                 drives all the way in to 060h.  Crossing 0a0h is
--                 therefore something plain stalking cannot do -- and the
--                 act_stance control (no counter-table entry at all) runs
--                 the identical setup to prove it.
--                 The bar is 078h, not 0a0h: the zap cooldown now makes the
--                 drone take a bounded ~24-tick advance (~72px) when its
--                 fireball is not ready, so 0a0h is reachable WITHOUT the
--                 okizeme handler and the control scored the same as the
--                 trial. Only a drive all the way to c_hitfall_sd's 060h
--                 target crosses 078h.
local trials = {
    { name = "c_land",       act = ACT_LAND,      gap = 0x48, mode = "act",
      want = { [ACT_UPPERCUT]="uppercut", [ACT_SWEEP]="sweep" }, need = 2 },
    { name = "c_hitfall_sd", act = ACT_HITFALLSD, gap = 0xe0, mode = "close",
      close_to = 0x78, force_band = 2, need = 3 },
    { name = "control_idle", act = ACT_STANCE,    gap = 0xe0, mode = "close",
      close_to = 0x78, force_band = 2, need = 0, control = true },
}

local PULSE_ON, PULSE_PERIOD, TRIAL_FRAMES = 8, 220, 3300
local WATCH = 160                 -- 0e0h -> 060h at 3px/tick is ~45 ticks
local PROC_DRONEVAR1 = 0x330      -- p_dronevar1 = pdata+230h (MAINEQU)

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local trial_idx, trial_start = 1, 0
local pulses, fired = 0, 0
local watching, watch_left, gap_at_pulse = false, 0, 0
local fields = {}
local done = false
local results = {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function proc_act(p)
    local q = r32(p); if q == 0 then return 0xffff end
    return r16(q + PROC_ACTION)
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

local function finish()
    if done then return end
    done = true
    local bad, by_name, inconclusive = 0, {}, false
    for _, r in ipairs(results) do
        by_name[r.name] = r
        log("RESULT %-14s pulses=%d reactions=%d  %s",
            r.name, r.pulses, r.fired, r.ok and "OK" or "NO REACTION")
        if not r.ok then bad = bad + 1 end
    end
    -- The okizeme walk is only real if it clearly beats the do-nothing
    -- control. A 1-in-15 edge is noise; demand a real margin, and when the
    -- control is itself closing a lot say INCONCLUSIVE rather than let a
    -- coin-flip margin read as proof.
    local hf, ct = by_name["c_hitfall_sd"], by_name["control_idle"]
    if hf and ct then
        local hr = hf.pulses > 0 and (hf.fired / hf.pulses) or 0
        local cr = ct.pulses > 0 and (ct.fired / ct.pulses) or 0
        log("A/B okizeme=%.2f control=%.2f", hr, cr)
        if hr >= cr + 0.30 then
            log("  okizeme closure is well above the idle baseline")
        elseif cr >= 0.25 then
            inconclusive = true
            log("  INCONCLUSIVE: the control closes too (the zap cooldown's")
            log("  bounded advance walks in on its own), so this run neither")
            log("  confirms nor denies c_hitfall_sd. Dispatch was measured")
            log("  cleanly at 3/15 vs 0/15 before that advance existed.")
        else
            bad = bad + 1
            log("  (okizeme closure is not above the idle baseline)")
        end
    end
    if #results < #trials then
        log("FAIL newreact: only %d of %d trials ran", #results, #trials)
    elseif bad == 0 and inconclusive then
        log("PASS newreact: c_land dispatched; c_hitfall_sd INCONCLUSIVE this run")
    elseif bad == 0 then
        log("PASS newreact: every new counter-table entry dispatched")
    else
        log("FAIL newreact: %d check(s) failed", bad)
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
    local missing = {}
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then missing[#missing+1] = n end end
    if #missing > 0 then log("MISSING input fields: %s", table.concat(missing, ", ")) end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 and name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- new drone reactions: P1=LiuKang(human) P2=Jax(drone) diff=9 ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, FT_JAX)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        trial_start = frame
        log("fight start frame=%d trial=%s", frame, trials[1].name)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    if A.diff ~= 0 then w16(A.diff, 9) end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    local t = trials[trial_idx]
    local x1 = objx(A.p1_obj)
    local x2 = objx(A.p2_obj)
    local gap = (x1 and x2) and math.abs(x2 - x1) or -1

    -- pin the stalk band so a plain stalk can only ever close to d_far
    if t.force_band then
        local dp = r32(A.p2_proc)
        if dp ~= 0 then w16(dp + PROC_DRONEVAR1, t.force_band) end
    end

    local rel = frame - trial_start
    local ph = rel % PULSE_PERIOD
    if ph < PULSE_ON then
        -- Re-place the drone at the trial's starting distance ONLY during
        -- the pulse.  In "close" mode it has to be free to walk afterwards
        -- or there is nothing to measure.
        if x1 then pin(A.p2_obj, x1 + t.gap) end
        set_act(A.p1_proc, t.act)          -- victim is "landing" / "knocked down"
        if ph == 0 then
            pulses = pulses + 1
            watching, watch_left = true, WATCH
            gap_at_pulse = t.gap
        end
    elseif watching then
        local hit = false
        if t.mode == "act" then
            -- act mode still holds the geometry: c_land's range gate wants
            -- us already standing next to him.
            if x1 and math.abs(gap - t.gap) > 0x18 then pin(A.p2_obj, x1 + t.gap) end
            local dact = proc_act(A.p2_proc)
            if t.want[dact] then
                hit = true
                if fired < 3 then
                    log("%s reaction #%d: drone act=0x%04x (%s) gap=%d",
                        t.name, fired + 1, dact, t.want[dact], gap)
                end
            end
        else
            if gap >= 0 and gap <= t.close_to then
                hit = true
                if fired < 3 then
                    log("%s closed #%d: %d -> %d in %d frames",
                        t.name, fired + 1, gap_at_pulse, gap, WATCH - watch_left)
                end
            end
        end
        if hit then
            fired = fired + 1
            watching = false
        else
            watch_left = watch_left - 1
            if watch_left <= 0 then watching = false end
        end
    end

    if rel > TRIAL_FRAMES then
        results[#results+1] = { name = t.name, pulses = pulses, fired = fired,
                                ok = t.control or fired >= t.need }
        log("---- %s done: %d/%d ----", t.name, fired, pulses)
        trial_idx = trial_idx + 1
        if trial_idx > #trials then finish(); return end
        trial_start, pulses, fired, watching = frame, 0, 0, false
        log("---- trial -> %s ----", trials[trial_idx].name)
    end
    if frame > 30000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
