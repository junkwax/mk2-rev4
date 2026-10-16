-- drone_throw_gate_test.lua
--
-- Verifies the drone throw discipline gate (drone_body_slam, MKDRONE.ASM +
-- the universal gate at do_body_slam, MKSLAM.ASM).
--
-- The complaint: "kitana still throws if you hold back, or can throw if
-- you are in motion to projectile".  Three phases, all against a CPU
-- Kitana nudged to stay inside slam range at diff 9:
--
--   BACK    - P1 holds AWAY the whole phase.  A throw here is a violation.
--   NEUTRAL - P1 stands still.  A throw here is REQUIRED: it proves the
--             gate tightened the rules instead of deleting the throw.
--   PROJ    - P1 repeats Liu Kang's F,F+HP fireball.  A throw landed while
--             P1's action is a projectile act (0x001-0x016) is a violation.
--             (Stick is FORWARD during F,F, so this is not just the back
--             rule firing again - it is the recovery/startup read.)
--
-- Every throw is logged with the victim's action id, so a pass is evidence
-- and not just an absence.
--
-- Env: THROW_LOG
-- Usage: tools\run_drone_throw_gate_test.ps1

local LOGP = os.getenv("THROW_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/drone_throw_gate_test.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[throw] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

-- MK2.MAP holds TMS34010 BIT addresses, which is exactly what MAME's
-- tms34010 program space takes, so map values and struct bit offsets are
-- both used as-is (same convention as drone_opener_gate_test.lua).
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
    -- switch is an EQUATE (SYSEQU.ASM: 01600000h jamma i/o), not a .bss
    -- symbol, so it never appears in MK2.MAP - sym() would silently give 0.
    switch = 0x01600000,
}

local OXVAL, OXPOS = 0x080, 0x090
local PROC_ACTION = 0x1f0
local PS_ACTIVE, PS_INACTIVE = 1, 0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1

local ACT_BODYSLAM = 0x0507
local FT_KANG, FT_KITANA = 1, 4

local PHASE_FRAMES = 2200
-- frames after a phase switch during which a throw is attributed to the
-- PREVIOUS phase (see the note at the throw-detection site)
local PHASE_WARMUP = 30

local frame, space = 0, nil
local last_gstate = -1
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local phase_idx, phase_start = 1, 0
local phases = { "back", "neutral", "proj" }
local hits = { back = 0, neutral = 0, proj = 0, warmup = 0 }
local throws_total = 0
local was_slamming = false
local fields = {}
local done = false
-- body_slam_init calls takeover_him_sr BEFORE stamping act_bodyslam, so by
-- the time the drone's action reads 0x0507 the victim's action has already
-- been wiped to 0.  Keep a short history and judge the throw by what the
-- victim was doing on the run-up, which is what the gate itself sampled.
local vhist = {}
local VHIST = 12
local away_frames, proj_frames = 0, 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function action(procptr)
    local p = r32(procptr); if p == 0 then return 0xffff end
    return r16(p + PROC_ACTION)
end
local function pin(objptr, x)
    local o = r32(objptr); if o == 0 then return end
    space:write_u32(o + OXVAL, (x & 0xffff) << 16)
    w16(o + OXPOS, x & 0xffff)
end

local function is_projectile_act(a)
    return a >= 0x0001 and a <= 0x0016
end

-- most recent action the victim actually had (0 = "taken over"/between acts)
local function victim_recent_act()
    for i = #vhist, 1, -1 do
        if vhist[i] ~= 0 and vhist[i] ~= 0xffff then return vhist[i] end
    end
    return 0
end
local function victim_was_projectile()
    for i = 1, #vhist do
        if is_projectile_act(vhist[i]) then return true end
    end
    return false
end
-- p1 joy bits: switch is active low, low 4 = up/down/left/right (m_jleft=4)
local function p1_joy()
    if A.switch == 0 then return 0 end
    return (~r32(A.switch)) & 0x0f
end

local function finish()
    if done then return end
    done = true
    log("RESULT throws=%d  back=%d neutral=%d proj=%d (away_frames=%d proj_frames=%d)",
        throws_total, hits.back, hits.neutral, hits.proj, away_frames, proj_frames)
    if hits.warmup > 0 then
        log("  (%d throw(s) ignored as phase warm-up)", hits.warmup)
    end
    local fails = {}
    -- Guard against a vacuous pass: the drone has to have been standing in
    -- throw range with the stick held away, or "no throws" proves nothing.
    -- (Do NOT check for act_walkb here - nothing in MK2 ever sets it; a
    -- retreating human's action is plain 0.)
    if away_frames < 300 then
        fails[#fails+1] = string.format(
            "back phase: only %d frames of held-away-inside-throw-range - test invalid",
            away_frames)
    end
    if proj_frames < 20 then
        fails[#fails+1] = string.format(
            "proj phase never registered a fireball (proj_frames=%d) - test invalid", proj_frames)
    end
    if hits.back > 0 then
        fails[#fails+1] = string.format("%d throw(s) while holding back", hits.back)
    end
    if hits.proj > 0 then
        fails[#fails+1] = string.format("%d throw(s) during a projectile action", hits.proj)
    end
    if hits.neutral == 0 then
        fails[#fails+1] = "never threw a neutral standing player (throw may be dead)"
    end
    if #fails == 0 then
        log("PASS throw_gate: back/projectile immune, neutral still throwable")
    else
        log("FAIL throw_gate: %s", table.concat(fails, "; "))
    end
    manager.machine:exit()
end

local function cache_fields()
    -- no "UI Select" here: mk2 has no such field (the ROM warning screen
    -- ages out on its own), and a name that can never bind would make the
    -- missing-field alarm useless.
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true,
                   ["P1 Left"]=true, ["P1 Right"]=true }
    local all = {}
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            all[#all+1] = f.name
            if want[f.name] then fields[f.name] = f end
        end
    end
    -- A silently unmatched name would make a phase vacuously "pass", so say
    -- out loud what we bound and dump the roster when something is missing.
    local missing = {}
    for n in pairs(want) do if not fields[n] then missing[#missing+1] = n end end
    if #missing > 0 then
        table.sort(all)
        log("MISSING input fields: %s", table.concat(missing, ", "))
        log("available: %s", table.concat(all, " | "))
    else
        log("all input fields bound")
    end
end

-- P1 always ends up on the LEFT of the drone (we nudge the drone to our
-- right), so AWAY = Left and FORWARD = Right.
local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        if name == "UI Select" then return frame >= 5 and frame < 35 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 45
    end

    local ph = phases[phase_idx]
    if ph == "back" then
        return name == "P1 Left"
    elseif ph == "proj" then
        -- F, F + HP on a 48 frame cycle: tap, gap, tap, then punch.
        local t = (frame - phase_start) % 48
        if name == "P1 Right" then return t < 4 or (t >= 8 and t < 12) end
        if name == "P1 High Punch" then return t >= 12 and t < 16 end
        return false
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- throw gate: P1=LiuKang(human) vs P2=Kitana(drone) diff=9 ----")
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
        w16(A.p2_char, FT_KITANA)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        phase_start = frame
        log("fight start frame=%d phase=%s", frame, phases[phase_idx])
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

    -- Nudge only, never pin: hard-pinning the drone every frame overrides
    -- its own walk and it stops entering cmf_close at all.
    local x1, x2 = objx(A.p1_obj), objx(A.p2_obj)
    if x1 and x2 then
        if x2 < x1 then pin(A.p2_obj, x1 + 50)       -- keep P1 on the left
        elseif (x2 - x1) > 70 then pin(A.p2_obj, x1 + 50) end
    end

    local vact_now = action(A.p1_proc)
    local ph = phases[phase_idx]
    local gap_now = (x1 and x2) and math.abs(x2 - x1) or 9999
    -- "the throw was available and refused": away held (m_jleft=4, drone is
    -- always to our right) while inside the diff-9 slam distance (050h).
    if ph == "back" and (p1_joy() & 0x04) ~= 0 and gap_now <= 0x50 then
        away_frames = away_frames + 1
    end
    if ph == "proj" and is_projectile_act(vact_now) then proj_frames = proj_frames + 1 end

    local dact = action(A.p2_proc)
    local slamming = (dact == ACT_BODYSLAM)
    if slamming and not was_slamming then
        local vact = victim_recent_act()
        local gap = (x1 and x2) and math.abs(x2 - x1) or -1
        local rel = frame - phase_start
        throws_total = throws_total + 1
        local verdict = "ok"
        -- A throw landing in the first few frames of a phase was decided
        -- BEFORE that phase began: the drone commits, then body_slam_init runs
        -- takeover_him_sr, all before the harness has held the new stick
        -- direction long enough for the game to sample it. Seen for real -- a
        -- build once reported a single "thrown while holding back" at rel=2,
        -- and shifting the RNG stream by one roll (with every line of game
        -- logic identical) moved it away entirely. That is a coincidence at a
        -- phase boundary, not a hole in the gate, and counting it as a
        -- violation makes this test fail innocent builds at random.
        if rel < PHASE_WARMUP then
            verdict = string.format("ignored (rel=%d < %d-frame phase warm-up)", rel, PHASE_WARMUP)
            hits.warmup = hits.warmup + 1
        elseif ph == "back" then
            verdict = "VIOLATION (holding back)"
            hits.back = hits.back + 1
        elseif ph == "proj" and victim_was_projectile() then
            verdict = "VIOLATION (mid projectile)"
            hits.proj = hits.proj + 1
        elseif ph == "neutral" then
            hits.neutral = hits.neutral + 1
        end
        log("THROW #%d phase=%s rel=%d gap=%d victim_act=0x%04x joy=%x %s",
            throws_total, ph, frame - phase_start, gap, vact, p1_joy(), verdict)
    end
    was_slamming = slamming

    vhist[#vhist + 1] = vact_now
    if #vhist > VHIST then table.remove(vhist, 1) end

    -- Sanity trace: prove P1 really is retreating / really is firing.
    if (frame % 300) == 0 then
        log("  .. phase=%s rel=%d gap=%d p1_act=0x%04x p2_act=0x%04x joy=%x away=%d proj=%d",
            ph, frame - phase_start,
            (x1 and x2) and math.abs(x2 - x1) or -1,
            vact_now, dact, p1_joy(), away_frames, proj_frames)
    end

    if frame - phase_start > PHASE_FRAMES then
        phase_idx = phase_idx + 1
        if phase_idx > #phases then finish(); return end
        phase_start = frame
        log("---- phase -> %s ----", phases[phase_idx])
    end
    if frame > 30000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
