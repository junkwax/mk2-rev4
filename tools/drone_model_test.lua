-- drone_model_test.lua
--
-- Proves the opponent model (doc/AI_DRONE.md) actually learns, actually
-- predicts, and actually pays off -- and, just as importantly, that it stays
-- QUIET when the player is unpredictable.
--
-- The drone watches p_action changes.  So the stimulus is P1's p_action,
-- pulsed directly: drone_beware only reaches the learn path when the action
-- CHANGES, so an idle opponent teaches it nothing and a buggy build would
-- measure identical to a fixed one (that mistake cost a whole run in pass 7).
--
-- Two phases in ONE run, deliberately in this order:
--
--   NOISE    P1 cycles through eight unrelated classes.  The model must NOT
--            form an opinion: p1_predcls should read dc_none nearly always.
--            This is the control, and it runs FIRST so the pattern phase has
--            to overcome real noise rather than starting from a clean table.
--   PATTERN  P1 does jump-in then sweep, over and over.  The model must learn
--            bigram[dc_air][dc_low], start answering dc_low, and the drone's
--            own p_predhit must light up when the sweep arrives.
--
-- Env: MODEL_LOG
-- Usage: tools\run_drone_model_test.ps1

local LOGP = os.getenv("MODEL_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_model_test.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[model] " .. string.format(fmt, ...)
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
    f_freeze_timer = sym("f_freeze_timer"), tick = sym("tick"),
    p1_hab = sym("p1_hab"), p1_bigram = sym("p1_bigram"),
    p1_lastcls = sym("p1_lastcls"), p1_predcls = sym("p1_predcls"),
    p1_predrun = sym("p1_predrun"),
}

-- process-data offsets, straight out of MAINEQU.ASM (same convention the
-- other drone harnesses use)
local PROC_ACTION  = 0x1f0      -- p_action    = pdata+0f0h
local PROC_PREDHIT = 0x3a0      -- p_predhit   = pdata+2a0h

local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_RAIDEN = 1, 7

-- move classes, from the dc_* .set block at the top of MKDRONE.ASM
local DC_PROJ, DC_AIR, DC_LOW, DC_HIGH = 0, 1, 2, 3
local DC_UPCUT, DC_SPEC, DC_TURTLE, DC_NEUTRAL = 4, 5, 6, 7
local DC_NONE, DC_CLASSES = 8, 8
local CLSNAME = { [0]="proj", "air", "low", "high", "upcut", "spec", "turtle", "neutral", "none" }

local ACT_ANGLE_JUMP = 0x308    -- -> dc_air
local ACT_SWEEP      = 0x106    -- -> dc_low

-- one action per class, for the noise phase
local NOISE_ACTS = { 0x001, 0x308, 0x106, 0x101, 0x107, 0x200, 0x700, 0x303 }

local NOISE_FRAMES   = 2600
local PATTERN_FRAMES = 4200
local HOLD           = 7        -- frames to hold each pulsed action

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local run_start = 0
local fields = {}
local done = false

local phase = "noise"
local pulse_i = 0
local noise_seed = 12345

-- measurements
-- Pattern-phase sightings are split early/late on purpose.  A first cut of
-- this harness scored the whole phase together and reported 48%, which read
-- as "wrong half the time" when the model was in fact never wrong once
-- (pred_other was 0) -- it was simply still climbing out of the noise the
-- control phase deliberately planted.  "Has not formed an opinion yet" and
-- "formed the wrong opinion" are completely different failures and the
-- harness has to keep them apart.
local m = {
    noise_air_samples = 0, noise_air_predicted = 0,
    patt_air_samples = 0,  patt_air_pred_low = 0, patt_air_pred_other = 0,
    late_air_samples = 0,  late_air_pred_low = 0,
    predhit = 0, predhit_max = 0, predhit_chain = 0, predrun_max = 0,
    last_seen_cls = -1,
}
local late_starts_at = 0        -- filled in when the pattern phase begins
local prev_predhit = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end

local function proc_field(p, off)
    local q = r32(p); if q == 0 then return nil end
    return r16(q + off)
end
local function set_p1_action(v)
    local q = r32(A.p1_proc); if q == 0 then return end
    w16(q + PROC_ACTION, v)
end

local function bigram(last, cls)
    if A.p1_bigram == 0 then return 0 end
    return r16(A.p1_bigram + (last * DC_CLASSES + cls) * 16)
end
local function hab(cls, band)
    if A.p1_hab == 0 then return 0 end
    return r16(A.p1_hab + (cls * 3 + band) * 16)
end

local function row_dump(last)
    local parts = {}
    for c = 0, DC_CLASSES - 1 do
        parts[#parts+1] = string.format("%s=%d", CLSNAME[c], bigram(last, c))
    end
    return table.concat(parts, " ")
end

local function hab_nonzero()
    local n = 0
    for c = 0, DC_CLASSES - 1 do
        for b = 0, 2 do if hab(c, b) > 0 then n = n + 1 end end
    end
    return n
end

local function bigram_nonzero()
    local n = 0
    for l = 0, DC_CLASSES - 1 do
        for c = 0, DC_CLASSES - 1 do if bigram(l, c) > 0 then n = n + 1 end end
    end
    return n
end

local function row_argmax(last)
    local best, bestc, total = -1, DC_NONE, 0
    for c = 0, DC_CLASSES - 1 do
        local v = bigram(last, c)
        total = total + v
        if v > best then best, bestc = v, c end
    end
    return bestc, best, total
end

local function finish()
    if done then return end
    done = true

    local hz, bz = hab_nonzero(), bigram_nonzero()
    local dom, domv, tot = row_argmax(DC_AIR)

    local noise_rate = (m.noise_air_samples > 0)
        and (m.noise_air_predicted / m.noise_air_samples) or 0
    local patt_rate = (m.patt_air_samples > 0)
        and (m.patt_air_pred_low / m.patt_air_samples) or 0
    local late_rate = (m.late_air_samples > 0)
        and (m.late_air_pred_low / m.late_air_samples) or 0

    log("")
    log("RESULT habit cells populated : %d / 24", hz)
    log("RESULT bigram cells populated: %d / 64", bz)
    log("RESULT bigram row 'air'      : %s", row_dump(DC_AIR))
    log("RESULT   dominant successor  : %s (%d of %d in row)", CLSNAME[dom], domv, tot)
    log("RESULT noise phase   : %d/%d air-sightings produced ANY prediction (%.0f%%)",
        m.noise_air_predicted, m.noise_air_samples, noise_rate * 100)
    log("RESULT pattern phase : %d/%d air-sightings predicted 'low' (%.0f%%)  [%d predicted something else]",
        m.patt_air_pred_low, m.patt_air_samples, patt_rate * 100, m.patt_air_pred_other)
    log("RESULT pattern, LATE half: %d/%d predicted 'low' (%.0f%%)  <-- after it has had time to learn",
        m.late_air_pred_low, m.late_air_samples, late_rate * 100)
    log("RESULT p_predhit fired on the drone: %d time(s)", m.predhit)
    log("RESULT prediction streak: p_predhit peaked at %d, p1_predrun peaked at %d,"
        .. " %d frame(s) held a streak > 1", m.predhit_max, m.predrun_max, m.predhit_chain)

    local fails = {}
    if hz == 0 then
        fails[#fails+1] = "habit profile never populated - drone_learn is not being reached"
    end
    if bz == 0 then
        fails[#fails+1] = "bigram never populated - no transitions recorded"
    end
    if m.patt_air_samples < 10 then
        fails[#fails+1] = string.format(
            "only %d air-sightings in the pattern phase - stimulus never landed",
            m.patt_air_samples)
    else
        if dom ~= DC_LOW then
            fails[#fails+1] = string.format(
                "after 'jump then sweep' x N the model's answer to 'air' is '%s', not 'low'",
                CLSNAME[dom])
        end
        -- A confident WRONG answer is the real failure mode: it means the
        -- drone reacts faster to a move the player was never going to make.
        if m.patt_air_pred_other > 0 then
            fails[#fails+1] = string.format(
                "model was confidently WRONG %d time(s) - it named a successor that was not 'low'",
                m.patt_air_pred_other)
        end
        if late_rate < 0.80 then
            fails[#fails+1] = string.format(
                "late in the pattern phase it still only predicted 'low' %.0f%% of the time",
                late_rate * 100)
        end
        if patt_rate <= noise_rate then
            fails[#fails+1] = string.format(
                "pattern phase (%.0f%%) is no more predictable than the noise control (%.0f%%)",
                patt_rate * 100, noise_rate * 100)
        end
    end
    if noise_rate > 0.50 then
        fails[#fails+1] = string.format(
            "model formed an opinion on %.0f%% of RANDOM input - the confidence gate is not working",
            noise_rate * 100)
    end
    if m.predhit == 0 then
        fails[#fails+1] = "p_predhit never set - the read never reaches the drone's decisions"
    end

    if #fails == 0 then
        log("PASS model: learns the pattern, stays quiet on noise, and the read reaches the drone")
    else
        log("FAIL model: %s", table.concat(fails, "; "))
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
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
        log("---- model test: P1=LiuKang(scripted) P2=Raiden(drone) diff=9 ----")
        for _, n in ipairs({"p1_hab","p1_bigram","p1_lastcls","p1_predcls"}) do
            if sym(n) == 0 then log("ERROR symbol %s missing from MK2.MAP", n) end
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, FT_RAIDEN)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        run_start = frame
        log("fight start frame=%d  -- NOISE phase (control) for %d frames",
            frame, NOISE_FRAMES)
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

    local rel = frame - run_start
    if phase == "noise" and rel > NOISE_FRAMES then
        phase = "pattern"
        late_starts_at = rel + PATTERN_FRAMES // 2
        log("phase -> PATTERN (jump-in then sweep, repeatedly) at rel=%d, 'late' from rel=%d",
            rel, late_starts_at)
        log("  noise-phase bigram row 'air': %s", row_dump(DC_AIR))
    end

    -- ---- stimulus: pulse P1's action ------------------------------------
    -- drone_beware learns on a CHANGE, so every pulse has to be a different
    -- value than the one before it, and has to be held long enough for the
    -- drone to be inside one of its animation loops at least once.
    if (rel % HOLD) == 0 then
        pulse_i = pulse_i + 1
        if phase == "noise" then
            noise_seed = (noise_seed * 1103515245 + 12345) & 0x7fffffff
            set_p1_action(NOISE_ACTS[(noise_seed >> 16) % #NOISE_ACTS + 1])
        else
            if (pulse_i % 2) == 0 then
                set_p1_action(ACT_ANGLE_JUMP)
            else
                set_p1_action(ACT_SWEEP)
            end
        end
    end

    -- ---- measurement ----------------------------------------------------
    -- Sample the prediction at the moment the model records an 'air', which
    -- is the transition the pattern phase is teaching it.
    local lastcls = (A.p1_lastcls ~= 0) and r16(A.p1_lastcls) or DC_NONE
    if lastcls ~= m.last_seen_cls then
        if lastcls == DC_AIR then
            local pred = (A.p1_predcls ~= 0) and r16(A.p1_predcls) or DC_NONE
            if phase == "noise" then
                m.noise_air_samples = m.noise_air_samples + 1
                if pred ~= DC_NONE then m.noise_air_predicted = m.noise_air_predicted + 1 end
            else
                m.patt_air_samples = m.patt_air_samples + 1
                if pred == DC_LOW then m.patt_air_pred_low = m.patt_air_pred_low + 1
                elseif pred ~= DC_NONE then m.patt_air_pred_other = m.patt_air_pred_other + 1 end
                if rel >= late_starts_at then
                    m.late_air_samples = m.late_air_samples + 1
                    if pred == DC_LOW then m.late_air_pred_low = m.late_air_pred_low + 1 end
                end
            end
        end
        m.last_seen_cls = lastcls
    end

    -- Did the read actually reach the drone's own decision state?
    --
    -- p_predhit is no longer a 0/1 flag: it carries the STREAK, i.e. how many
    -- predictions in a row have now come true, and that is what drone_beware
    -- subtracts from its think timer and what react_jump_table scales its
    -- counter roll by.  Count a rising edge out of zero as one read, and keep
    -- the high-water mark separately -- a model that only ever reaches 1 is
    -- working but is never buying the graded reaction the streak exists for.
    local ph = proc_field(A.p2_proc, PROC_PREDHIT) or 0
    if ph ~= 0 and prev_predhit == 0 then m.predhit = m.predhit + 1 end
    if ph > m.predhit_max then m.predhit_max = ph end
    if ph > 1 then m.predhit_chain = m.predhit_chain + 1 end
    prev_predhit = ph

    local pr = (A.p1_predrun ~= 0) and r16(A.p1_predrun) or 0
    if pr > m.predrun_max then m.predrun_max = pr end

    if (rel % 600) == 0 and rel > 0 then
        log("  .. %s rel=%d lastcls=%s predcls=%s predhit=%d bigram_cells=%d",
            phase, rel, CLSNAME[lastcls] or "?",
            CLSNAME[(A.p1_predcls ~= 0) and r16(A.p1_predcls) or DC_NONE] or "?",
            m.predhit, bigram_nonzero())
    end

    if rel > NOISE_FRAMES + PATTERN_FRAMES then finish(); return end
    if frame > 30000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
