-- drone_jab_whiff_test.lua
--
-- "The CPU keeps throwing a low punch that cannot reach me."
--
-- drone_rfp bails out of a jab string on the first strike that does not
-- land, and until drone_jab_whiff existed nothing looked at WHY: a drone
-- parked a few pixels outside its own jab range threw the same whiffed jab
-- every time it re-decided.  The fix counts consecutive whiffed strings in
-- c_drone_jabwhiff and answers the second one with a SWEEP, which reaches
-- further and knocks down.  This measures that.
--
-- HOW IT MEASURES.  Both fighters are pinned at a fixed gap for a phase and
-- the phases walk outwards through the range band, so the run covers "jab
-- lands", "jab whiffs but sweep reaches", and "both are short".
--
-- WHAT IT WATCHES, and why it is not all visible state:
--
--   the STRING'S OUTCOME comes from c_drone_jabwhiff.  A drone jab is
--   invisible from the outside - drone_rfp calls init_special, not
--   init_special_act, so p_action never becomes act_lopunch and nothing in
--   the object or process says "that was a jab".  Measured the naive way
--   first: watching p_action counted 0 jabs across five gaps while the
--   drone was plainly throwing them all run.
--
--   the RESPONSE is read from p_action == act_sweep, which is visible.
--
--   ATTRIBUTION between them is the whole point.  The drone already had
--   several ways to sweep (duck_sweep_try, sweep_if_u_can, the reaction
--   handlers), so "a sweep happened" proves nothing on its own - the first
--   version of this rig counted 2 and 4 sweeps at gaps where the feature
--   cannot have fired.  A sweep only counts here if it starts inside the
--   window that opens when the counter resets, which is the only moment
--   drone_jab_whiff can have branched.
--
-- The counter goes 0 -> 1 on the first whiffed string and 1 -> 0 on the
-- second, because drone_jab_whiff clears it on the way to the sweep.  A
-- 1 -> 0 that no sweep follows is a jab that CONNECTED (drl_landed clears
-- it too), which is the other thing worth telling apart.
--
-- RIG TRAP, deliberately avoided: the drone judges "did my string land" by
-- watching the opponent's LIFE BAR (combo_connected).  A rig that tops the
-- bars up every frame therefore erases the evidence and every landed jab
-- reads as a whiff - the drone would sweep constantly and the test would
-- "pass" for entirely the wrong reason.  So the human's bar is topped up
-- only when it has actually dropped some way, never every frame.
--
-- Env: WHIFF_CHAR (ft index for the P2 drone), WHIFF_LABEL, WHIFF_LOG,
--      WHIFF_DIFF, WHIFF_GAPS (comma separated pixel gaps)
--
-- Usage: tools\run_drone_jab_whiff_test.ps1

local CHAR  = tonumber(os.getenv("WHIFF_CHAR") or "1")
local LABEL = os.getenv("WHIFF_LABEL") or "liukang"
local DIFF  = tonumber(os.getenv("WHIFF_DIFF") or "9")
local LOGP  = os.getenv("WHIFF_LOG")
    or "C:/Users/you/Workplace/mk2-main/tools/drone_jab_whiff_test.log"

local GAPS = {}
for g in (os.getenv("WHIFF_GAPS") or "55,68,74,80,86"):gmatch("[^,]+") do
    GAPS[#GAPS+1] = tonumber(g)
end

local PHASE_FRAMES = 1200      -- ~22s of game time per gap: many decisions
local SETTLE       = 60        -- ignore the first moments of a new gap
-- How long a counter reset stays owed a sweep.  drone_jab_sweep either
-- sweeps on the spot or walks in for at most 020h ticks before giving up, so
-- anything past ~45 frames cannot be that branch and must not be credited to
-- it -- the drone has several other ways to sweep and a loose window quietly
-- hands their work to this feature.
local ANSWER_WIN   = 45

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[whiff] " .. string.format(fmt, ...)
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

-- Action ids come from the source, never hardcoded: they have moved before.
local acts = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n, v = line:match("^(act_[%w_]+)%s+%.set%s+([0-9a-fA-F]+)h")
            if n and v then acts[n] = tonumber(v, 16) end
        end
        fh:close()
    end
end
local ACT_SWEEP = acts["act_sweep"] or -1

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
    jabwhiff = sym("c_drone_jabwhiff"),   -- p1 half; P2's is +16 bits
}
local WC = A.jabwhiff + 16     -- the drone is P2

local OXVAL, OXPOS = 0x080, 0x090
local PROC_ACTION = 0x1f0
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local REFILL_BELOW = MAX_HP - 32   -- top up after a couple of hits, not every frame

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local last_gstate = -1
local fields = {}
local done = false

local phase_i, phase_start = 0, 0
local anchor_x, drone_right = nil, true
local prev_act, prev_wc = 0xffff, 0
local answer_until = 0
local refills, round_restarts = 0, 0
local stats = {}

local function new_stats()
    return { whiffs = 0, connects = 0, answered = 0, sweeps = 0 }
end

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
local function drone_action()
    local p = r32(A.p2_proc); if p == 0 then return 0xffff end
    return r16(p + PROC_ACTION)
end

local function finish()
    if done then return end
    done = true
    log("---- %s RESULT (diff=%d, %d refills, %d round restarts) ----",
        LABEL, DIFF, refills, round_restarts)
    if A.jabwhiff == 0 then
        log("INVALID %s: c_drone_jabwhiff is not in MK2.MAP - stale build ?", LABEL)
        manager.machine:exit(); return
    end
    local notes = {}
    local tot_whiff, tot_answered, tot_sweeps = 0, 0, 0
    for i, g in ipairs(GAPS) do
        local st = stats[i]
        if not st then break end
        tot_whiff = tot_whiff + st.whiffs
        tot_answered = tot_answered + st.answered
        tot_sweeps = tot_sweeps + st.sweeps
        log("gap=%-4d whiffed strings=%-3d resets not swept=%-3d   sweeps=%-3d (off a whiff: %d)",
            g, st.whiffs, st.connects, st.sweeps, st.answered)
    end
    log("totals: %d whiffed strings, %d sweeps, %d of them fired off a whiff",
        tot_whiff, tot_sweeps, tot_answered)
    for _, n in ipairs(notes) do log("  %s", n) end
    -- The counter only moves when a jab string touched nothing, and the
    -- attribution window only opens when it resets, so an attributed sweep
    -- cannot come from duck_sweep_try or any of the reaction handlers.
    if tot_whiff < 4 then
        log("INVALID %s: only %d whiffed jab strings in the whole run - the rig never reproduced the complaint",
            LABEL, tot_whiff)
    elseif tot_answered == 0 then
        log("FAIL %s: %d whiffed jab strings and not one produced a sweep",
            LABEL, tot_whiff)
    else
        log("PASS %s: whiffed jab strings are answered with a sweep (%d of %d strings)",
            LABEL, tot_answered, tot_whiff)
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true,
                   ["P1 High Punch"]=true, ["UI Select"]=true }
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
    if name == "P1 High Punch" and p1_confirm > 0 and fighting_frame == 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false            -- the human does NOTHING once the fight starts
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        if ACT_SWEEP < 0 then log("FATAL: act_sweep not found in MAINEQU.ASM") end
        if A.jabwhiff == 0 then log("FATAL: c_drone_jabwhiff not found in MK2.MAP") end
        log("---- %s: drone char=%d  gaps=%s  counter@%08x ----", LABEL, CHAR,
            table.concat(GAPS, ","), WC)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("%s frame=%d gstate %d -> %d", LABEL, frame, last_gstate, gs)
        if fighting_frame > 0 and gs == GS_FIGHTING then
            -- a round ended under us: re-anchor on the new positions, or the
            -- pin drags both fighters to wherever the old round left them
            round_restarts = round_restarts + 1
            local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
            anchor_x = x1 or anchor_x
            drone_right = (x2 or 0) >= (x1 or 0)
            log("%s round restart #%d - re-anchored at %d", LABEL, round_restarts, anchor_x)
        end
        last_gstate = gs
    end
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)      -- P2 = the drone
        w16(A.p1_char, 1)                 -- P1 = Liu Kang, an idle human
        w16(A.p2_char, CHAR)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
        anchor_x = x1 or 0
        drone_right = (x2 or 0) >= (x1 or 0)
        phase_i, phase_start = 1, frame
        stats[1] = new_stats()
        prev_wc = r16(WC)
        log("%s fight start frame=%d  p1_x=%d p2_x=%d  phase 1 gap=%d",
            LABEL, frame, x1 or 0, x2 or 0, GAPS[1])
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("%s ERROR never reached fight", LABEL); finish() end
        return
    end

    if r16(A.diff) ~= DIFF then w16(A.diff, DIFF) end
    if r16(A.winner_status) ~= 0 then w16(A.winner_status, 0) end

    -- ---- hold the gap open ----
    local gap = GAPS[phase_i]
    pin(A.p1_obj, anchor_x)
    pin(A.p2_obj, drone_right and (anchor_x + gap) or (anchor_x - gap))

    -- ---- keep the fight alive without erasing the drone's own evidence ----
    if r16(A.p1_bar) < REFILL_BELOW then
        refills = refills + 1
        w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    end
    if r16(A.p2_bar) < MAX_HP then
        w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    end

    local st = stats[phase_i]
    local settled = (frame - phase_start) > SETTLE

    -- ---- the string's outcome, off the counter ----
    local wc = r16(WC)
    if wc ~= prev_wc then
        if wc > prev_wc then
            if settled then st.whiffs = st.whiffs + 1 end
        else
            -- back to zero: either the second whiff (about to sweep) or a
            -- string that connected.  Which one is decided by what follows.
            answer_until = frame + ANSWER_WIN
        end
        prev_wc = wc
    end

    -- ---- the response, off the visible action ----
    local act = drone_action()
    if act ~= prev_act then
        if act == ACT_SWEEP and settled then
            st.sweeps = st.sweeps + 1
            if frame <= answer_until then
                st.answered = st.answered + 1
                st.whiffs = st.whiffs + 1     -- the second whiff, now proven
                answer_until = 0
            end
        end
        prev_act = act
    end
    -- a window that closed with no sweep was a jab that landed
    if answer_until ~= 0 and frame > answer_until then
        if settled then st.connects = st.connects + 1 end
        answer_until = 0
    end

    if frame - phase_start > PHASE_FRAMES then
        log("%s phase gap=%d done: whiffs=%d connects=%d sweeps=%d answered=%d",
            LABEL, gap, st.whiffs, st.connects, st.sweeps, st.answered)
        phase_i = phase_i + 1
        if phase_i > #GAPS then finish(); return end
        phase_start = frame
        stats[phase_i] = new_stats()
        log("%s phase %d gap=%d", LABEL, phase_i, GAPS[phase_i])
    end

    if frame > 40000 then log("%s ERROR global timeout", LABEL); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
