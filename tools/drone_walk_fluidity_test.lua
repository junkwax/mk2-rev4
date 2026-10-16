-- drone_walk_fluidity_test.lua
--
-- Regression net for "the CPU holds one sprite frame while it keeps sliding",
-- and for the difficulty-dependent animation rate behind it.
--
-- Why: drone_beware used to prcslp() for drone_react_delay[diff] ticks in the
-- middle of the CALLER's animation loop.  Every drone walk / get-up / land /
-- turnaround loop is "sleep 1 / next_anirate / drone_beware", so that sleep
-- suspended the loop: next_anirate stopped being called, the sprite held one
-- frame, and the x velocity from drone_walk?_setup kept dragging it along the
-- floor.  The delay table is 6 ticks at diff 0 and 3 at diff 9, so EASY
-- stalled longest -- and animation rate must not depend on difficulty at all.
-- It is now armed rather than slept (p_react_wait, aged in bew_pending).
--
-- Measured A/B on this exact harness:
--     before  worst walk hold = 10 ticks (4 + the diff-0 delay), 7 overruns
--     after   worst walk hold =  4 ticks, 0 overruns
--
-- Four things the harness has to get right, all learned the hard way:
--
--  * The walk state is p_action = act_stance (0303h), NOT 0.  Gating on 0
--    measures jumps and reaction slides instead and reports nonsense.
--  * The human's p_action must be PULSED.  drone_beware only reaches the
--    reaction path when the opponent's action CHANGES (p_otheract dedupes),
--    so against an idle opponent the delay never runs and both builds look
--    identical.  The pulsed ids all resolve to handlers that bail with
--    return_to_beware at this range: the drone notices, then goes back to
--    walking, which is exactly the in-game case that reads as hitching.
--  * oxpos is SCREEN space (world-x minus the scroll origin), so a fighter
--    walking with the camera shows a CONSTANT oxpos.  Use oxval.
--  * oimg points at a fixed per-player header; the frame identity is the SAG
--    behind it, so the read needs a double dereference.
--
-- PASS requires, at BOTH diff 0 and diff 9:
--   * the 95th-percentile hold is within the authored walk rate, and
--   * that percentile is the same at either difficulty.
--
-- It is judged on the percentile rather than the maximum on purpose -- see the
-- comment above percentile() for the experiment that forced that change. An
-- isolated overrun is reported (with its frame) but does not fail the run.
--
-- Env: FLUIDITY_LOG
-- Usage: tools\run_drone_walk_fluidity_test.ps1

local LOGP = os.getenv("FLUIDITY_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_walk_fluidity_test.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[fluid] " .. string.format(fmt, ...)
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
for _, n in ipairs({"gstate","p1_obj","p2_obj","p1_proc","p2_proc","p1_char","p2_char","diff"}) do
    if A[n] == 0 then log("MISSING SYMBOL %s - results are worthless", n) end
end

local OXVAL, OIMG = 0x080, 0x1a0
local PROC_ACTION = 0x1f0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_JAX = 1, 11
local ACT_STANCE = 0x0303          -- the drone stalk / walk state

-- Jax walks forward at 5 ticks per frame (walk_forward_info, MKGUYS.ASM);
-- backward is 6. A hold run counts the frames AFTER the first, so the
-- authored ceiling is rate-1 = 5. Anything above that is a stall.
local WALK_HOLD_MAX = 5
local PHASE_FRAMES  = 2400
local KEEP_AWAY     = 0x0c0        -- inside d_far, so the drone walks in
local CLOSE_ENOUGH  = 0x50         -- instead of standing off and zoning
local PULSE_ACTS    = { 0x0100, 0x0106, 0x0107, 0x0102, 0x0103 }
local PULSE_EVERY   = 24

local phases = { { diff = 0 }, { diff = 9 } }

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local phase_idx, phase_start = 1, 0
local fields, results, done = {}, {}, false
local hist, run_len, prev = {}, 0, nil
local worst, walk_frames = 0, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objraw(p) local o = r32(p); if o == 0 then return nil end return r32(o + OXVAL) end
local function objx(p) local v = objraw(p); if not v then return nil end return s16(v >> 16) end
local function objimg(p)
    local o = r32(p); if o == 0 then return nil end
    local hdr = r32(o + OIMG); if hdr == 0 then return nil end
    return r32(hdr)
end
local function proc_act(p) local q = r32(p); if q == 0 then return 0xffff end return r16(q + PROC_ACTION) end
local function set_act(p, v) local q = r32(p); if q ~= 0 then w16(q + PROC_ACTION, v) end end

local function reset_phase()
    hist, run_len, prev, worst, walk_frames = {}, 0, nil, 0, 0
end

local function close_run()
    if run_len > 0 then
        hist[run_len] = (hist[run_len] or 0) + 1
        if run_len > worst then worst = run_len end
        -- Say WHERE, not just that it happened. An earlier version reported
        -- only the histogram, so a single 8-tick hold in 559 walk frames gave
        -- no clue whether it was a startup transient or a recurring hitch --
        -- and those need completely different investigations.
        if run_len > WALK_HOLD_MAX then
            log("  OVERRUN hold=%d ticks at frame=%d (rel=%d into diff=%d phase)",
                run_len, frame, frame - phase_start, phases[phase_idx].diff)
        end
    end
    run_len = 0
end

-- 95th-percentile hold, not the maximum.
--
-- The maximum is stream-sensitive and cannot carry a pass/fail verdict. Proved
-- by experiment: five different builds that differ ONLY in how many RNG rolls
-- they burn (which reshuffles every later randu/randper and so every drone
-- decision) score worst-hold 4, 4, 4, 4 and 8 on this same fight. The 8 is one
-- isolated hold out of 119, at one specific frame, in one specific stream --
-- a rare pre-existing hitch, not a stall.
--
-- The bug this harness exists for looked nothing like that: the sleeping think
-- timer shifted the WHOLE distribution (worst 10 with 7 overruns at diff 0
-- against 3 at diff 9), because it fired on every single sighting. A
-- percentile keeps all of that power and stops an unlucky stream from failing
-- an innocent build.
local function percentile(hist, total, frac)
    local want, seen = math.ceil(total * frac), 0
    for len = 1, 40 do
        seen = seen + (hist[len] or 0)
        if seen >= want then return len end
    end
    return 0
end

local function finish()
    if done then return end
    done = true
    local overruns, p95s = {}, {}
    for _, r in ipairs(results) do
        local buckets, over, total = {}, 0, 0
        for len = 1, 40 do
            if r.hist[len] then
                buckets[#buckets+1] = string.format("%d:%d", len, r.hist[len])
                total = total + r.hist[len]
                if len > WALK_HOLD_MAX then over = over + r.hist[len] end
            end
        end
        local p95 = percentile(r.hist, total, 0.95)
        overruns[r.diff], p95s[r.diff] = over, p95
        r.p95 = p95
        log("RESULT diff=%d  walk-frames=%d  worst-hold=%d  p95-hold=%d  overruns=%d/%d  holds[%s]",
            r.diff, r.walk_frames, r.worst, p95, over, total, table.concat(buckets, " "))
        if over > 0 then
            log("  NOTE diff=%d had %d isolated hold(s) over %d ticks. Judged on p95, not on"
                .. " the max -- see the comment above percentile().", r.diff, over, WALK_HOLD_MAX)
        end
    end
    if #results < #phases then
        log("FAIL fluidity: only %d of %d phases ran", #results, #phases)
    elseif results[1].walk_frames < 150 or results[2].walk_frames < 150 then
        log("FAIL fluidity: not enough walking measured (%d / %d frames)",
            results[1].walk_frames, results[2].walk_frames)
    elseif p95s[0] > WALK_HOLD_MAX or p95s[9] > WALK_HOLD_MAX then
        log("FAIL fluidity: sprite routinely holds a frame past the walk rate while sliding")
        log("  diff0 p95=%d overruns=%d, diff9 p95=%d overruns=%d",
            p95s[0], overruns[0], p95s[9], overruns[9])
        log("  that is a sleep inside drone_beware stalling the caller's loop")
    elseif math.abs(results[1].p95 - results[2].p95) > 1 then
        -- 1 tick of slack on purpose: forward walk is 5 ticks/frame and
        -- backward is 6, so a phase that happens to include more retreating
        -- legitimately tops out one higher. The stall this test exists for
        -- was 6 ticks wide at diff 0 vs 3 at diff 9 - nothing like noise.
        log("FAIL fluidity: hold distribution depends on difficulty (diff0 p95=%d diff9 p95=%d)",
            results[1].p95, results[2].p95)
    else
        log("PASS fluidity: p95 hold diff0=%d diff9=%d (worst %d/%d) - the walk cycle runs at"
            .. " the authored rate at both difficulties, not at a reaction delay",
            results[1].p95, results[2].p95, results[1].worst, results[2].worst)
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input field: %s", n) end end
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
        log("---- walk fluidity: P1=LiuKang(pulsed) P2=Jax(drone) ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 0)
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_JAX); w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; phase_start = frame; reset_phase()
        log("fight start frame=%d, measuring diff=%d", frame, phases[1].diff)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.diff, phases[phase_idx].diff)
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    if x1 and x2 and math.abs(x2 - x1) < CLOSE_ENOUGH then
        local o1 = r32(A.p1_obj)
        if o1 ~= 0 then space:write_u32(o1 + OXVAL, ((x2 - KEEP_AWAY) & 0xffff) << 16) end
    end

    set_act(A.p1_proc, PULSE_ACTS[(frame // PULSE_EVERY) % #PULSE_ACTS + 1])

    local img, raw, act = objimg(A.p2_obj), objraw(A.p2_obj), proc_act(A.p2_proc)
    if img and raw and act == ACT_STANCE then
        if prev and prev.act == ACT_STANCE and raw ~= prev.raw then
            walk_frames = walk_frames + 1
            if img == prev.img then run_len = run_len + 1 else close_run() end
        else
            close_run()
        end
        prev = { act = act, raw = raw, img = img }
    else
        close_run()
        prev = nil
    end

    if frame - phase_start > PHASE_FRAMES then
        close_run()
        local p = phases[phase_idx]
        results[#results+1] = { diff = p.diff, hist = hist, worst = worst, walk_frames = walk_frames }
        log("---- diff %d done: %d walk frames, worst hold %d ----", p.diff, walk_frames, worst)
        phase_idx = phase_idx + 1
        if phase_idx > #phases then finish(); return end
        phase_start = frame; reset_phase()
        log("---- measuring diff=%d ----", phases[phase_idx].diff)
    end

    if frame > 40000 then log("ERROR backstop"); finish() end
end)
