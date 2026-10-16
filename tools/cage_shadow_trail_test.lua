-- cage_shadow_trail_test.lua
--
-- Cage's back+HP power punch is a shadow move now:
--   * trail_proc is asked for 5 afterimages, one every 2 ticks, and is
--     bounded by that count instead of by the lunge going still (the punch
--     lunges for a quarter as long as the shadow kick, so the stock
--     7-shadows-every-3-ticks trail only ever placed TWO images);
--   * it plays the shadow-kick sound - triple_sndtab 043h, priority
--     sp_effect (050h) / duration 67 - or the 1% red variant, 0c7h.
--
-- And his HIGH force ball is retired: the ball steers off the stick in
-- flight, so B,D,F+HP must produce nothing, while the LOW ball (D,F+LP)
-- must still come out.
--
-- Phases (P1 = Cage, P2 = Liu Kang, both human so no AI interferes):
--   trail  - hold Away, tap HP.  Count live pid_jc_shadow1 procs per punch
--            and watch the sound channels for the shadow-kick entry.
--   zaphi  - drive B,D,F + HP.  act_jcsnot_hi must NEVER appear.
--   zaplo  - drive D,F + LP.    act_jcsnot_lo MUST appear.
--   skick  - drive B,F + LK.    the STOCK trail must be unchanged: the
--            shadow kick shares trail_proc, and it must still get its own
--            7 shadows now that the count is caller-settable.
--
-- Usage: tools\run_cage_shadow_trail_test.ps1

local LOGP = os.getenv("CST_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/cage_shadow_trail_test.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[cst] " .. string.format(fmt, ...)
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
    p1_proc = sym("p1_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"),
    active = sym("active"), f_nosound = sym("f_nosound"),
    chan1pri = sym("chan1pri"), chan1dur = sym("chan1dur"),
    chan2pri = sym("chan2pri"), chan2dur = sym("chan2dur"),
    chan3pri = sym("chan3pri"), chan3dur = sym("chan3dur"),
}

local OXVAL, OXPOS = 0x080, 0x090
local PROC_ACTION = 0x1f0
local PROCID = 0x20
local PS_ACTIVE = 1
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1

local FT_CAGE = 2
local ACT_PPUNCH   = 0x010d
local ACT_SNOT_LO  = 0x0005
local ACT_SNOT_HI  = 0x0006
local ACT_SHADK    = 0x0205
local PID_SHADOW1  = 0x0106

-- triple_sndtab 043h = sp_effect|67: priority 050h, duration 67 ticks.  The
-- duration is a countdown and Lua samples once a frame, so the first sample
-- after the call already reads 66 - match the top of the countdown, not 67
-- exactly.  Nothing else on an effect channel in this window runs that long
-- (the punch's own contact sound is priority 075h, the crowd 034h).
local SND_PRI = 0x50
local SND_DUR_MIN = 60

local DEBUG_SND = (os.getenv("CST_DEBUG_SND") or "") ~= ""
local PHASE_FRAMES = 900
local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local phase_idx, phase_start = 1, 0
local phases = { "trail", "zaphi", "zaplo", "skick" }
local fields = {}
local done = false

local punches, peak_shadows, shadow_sounds = 0, 0, 0
local saw_snot_hi, saw_snot_lo = 0, 0
local in_punch, this_peak, this_sound = false, 0, false
local punch_x0, best_travel = nil, 0
local kicks, peak_kick_shadows = 0, 0
local in_kick, kick_peak = false, 0
local last_act = -1

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

-- walk the active process list counting one pid
local function count_pid(pid)
    local n, p, guard = 0, r32(A.active), 0
    while p ~= 0 and guard < 400 do
        if r16(p + PROCID) == pid then n = n + 1 end
        p = r32(p)
        guard = guard + 1
    end
    return n
end

local function shadow_sound_now()
    local ch = { {A.chan1pri, A.chan1dur}, {A.chan2pri, A.chan2dur},
                 {A.chan3pri, A.chan3dur} }
    for _, c in ipairs(ch) do
        if r16(c[1]) == SND_PRI and r16(c[2]) >= SND_DUR_MIN then return true end
    end
    return false
end

local function finish()
    if done then return end
    done = true
    log("RESULT punches=%d peak_shadows=%d shadow_sounds=%d travel=%dpx snot_hi=%d snot_lo=%d kicks=%d kick_shadows=%d",
        punches, peak_shadows, shadow_sounds, best_travel, saw_snot_hi, saw_snot_lo,
        kicks, peak_kick_shadows)
    local fails = {}
    if punches == 0 then fails[#fails+1] = "back+HP never came out" end
    if peak_shadows < 5 then
        fails[#fails+1] = string.format("only %d live shadow procs at peak, wanted 5", peak_shadows)
    end
    if shadow_sounds == 0 then
        fails[#fails+1] = "shadow-kick sound never landed on a channel during a punch"
    end
    if saw_snot_hi > 0 then
        fails[#fails+1] = string.format("high force ball still fires (%d times)", saw_snot_hi)
    end
    if saw_snot_lo == 0 then
        fails[#fails+1] = "low force ball never came out - the surviving ball is broken"
    end
    if kicks == 0 then fails[#fails+1] = "shadow kick never came out" end
    if kicks > 0 and peak_kick_shadows < 7 then
        fails[#fails+1] = string.format(
            "shadow kick trail dropped to %d shadows - the shared trail_proc regressed",
            peak_kick_shadows)
    end
    if #fails == 0 then log("PASS cage_shadow_trail")
    else log("FAIL cage_shadow_trail: %s", table.concat(fails, "; ")) end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["2 Players Start"]=true,
                   ["P1 High Punch"]=true, ["P1 Low Punch"]=true,
                   ["P1 Low Kick"]=true,
                   ["P1 Left"]=true, ["P1 Right"]=true, ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

-- P1 is pinned LEFT of P2, so AWAY = Left, TOWARD = Right.
local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 60
    end
    local ph = phases[phase_idx]
    local rel = frame - phase_start
    if ph == "trail" then
        if name == "P1 Left" then return true end
        if name == "P1 High Punch" then
            if rel < 30 then return false end
            return (rel % 60) < 7
        end
        return false
    end
    -- motion phases: replay one stick sequence per cycle, then the button
    local CYCLE = 90
    local t = rel % CYCLE
    if ph == "zaphi" then                       -- Back, Down, Forward + HP
        if name == "P1 Left"  then return t >= 10 and t < 18 end
        if name == "P1 Down"  then return t >= 20 and t < 28 end
        if name == "P1 Right" then return t >= 30 and t < 38 end
        if name == "P1 High Punch" then return t >= 38 and t < 44 end
        return false
    end
    if ph == "skick" then                       -- Back, Forward + LK
        if name == "P1 Left"  then return t >= 10 and t < 18 end
        if name == "P1 Right" then return t >= 22 and t < 30 end
        if name == "P1 Low Kick" then return t >= 30 and t < 36 end
        return false
    end
    if ph == "zaplo" then                       -- Down, Forward + LP
        if name == "P1 Down"  then return t >= 10 and t < 18 end
        if name == "P1 Right" then return t >= 20 and t < 28 end
        if name == "P1 Low Punch" then return t >= 28 and t < 34 end
        return false
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- cage shadow trail / retired high ball ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_ACTIVE)
        w16(A.p1_char, FT_CAGE)
        w16(A.p2_char, 1)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        phase_start = frame
        log("fight start frame=%d phase=%s", frame, phases[1])
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    local x1 = objx(A.p1_obj)
    -- The shadow kick calls stop_me the moment it CONNECTS, and a stopped
    -- fighter is exactly how the stock trail learns its move ended - a kick
    -- that hits leaves a short trail by design.  Park P2 out of reach in the
    -- skick phase so the kick whiffs and the trail runs its full count; that
    -- is the number this regression is actually about.
    local gap = (phases[phase_idx] == "skick") and 0x100 or 0x50
    if x1 then pin(A.p2_obj, x1 + gap) end

    local p = r32(A.p1_proc)
    local act = (p ~= 0) and r16(p + PROC_ACTION) or 0xffff

    if act ~= last_act then
        if act == ACT_SNOT_HI then
            saw_snot_hi = saw_snot_hi + 1
            log("%s: HIGH force ball fired (#%d)", phases[phase_idx], saw_snot_hi)
        elseif act == ACT_SNOT_LO then
            saw_snot_lo = saw_snot_lo + 1
            log("%s: low force ball (#%d)", phases[phase_idx], saw_snot_lo)
        end
        last_act = act
    end

    -- back+HP window: count shadows and listen for the shadow sound
    if act == ACT_PPUNCH then
        if not in_punch then
            in_punch, this_peak, this_sound = true, 0, false
            punches = punches + 1
            punch_x0 = x1
        end
        local n = count_pid(PID_SHADOW1)
        if n > this_peak then this_peak = n end
        if shadow_sound_now() then this_sound = true end
        if DEBUG_SND and punches <= 3 then
            log("  snd f=%d shadows=%d ch=[%02x/%d %02x/%d %02x/%d] nosnd=%d",
                frame, n, r16(A.chan1pri), r16(A.chan1dur),
                r16(A.chan2pri), r16(A.chan2dur), r16(A.chan3pri), r16(A.chan3dur),
                A.f_nosound ~= 0 and r16(A.f_nosound) or -1)
        end
    elseif in_punch then
        in_punch = false
        if this_peak > peak_shadows then peak_shadows = this_peak end
        if this_sound then shadow_sounds = shadow_sounds + 1 end
        local travel = (punch_x0 and x1) and math.abs(x1 - punch_x0) or 0
        if travel > best_travel and travel < 200 then best_travel = travel end
        log("punch #%d: shadows=%d sound=%s travel=%dpx",
            punches, this_peak, tostring(this_sound), travel)
    end

    -- shadow kick: the stock trail, on the same shared proc
    if act == ACT_SHADK then
        if not in_kick then in_kick, kick_peak = true, 0; kicks = kicks + 1 end
        local n = count_pid(PID_SHADOW1)
        if n > kick_peak then kick_peak = n end
    elseif in_kick then
        in_kick = false
        if kick_peak > peak_kick_shadows then peak_kick_shadows = kick_peak end
        log("shadow kick #%d: shadows=%d", kicks, kick_peak)
    end

    if frame - phase_start > PHASE_FRAMES then
        phase_idx = phase_idx + 1
        if phase_idx > #phases then finish(); return end
        phase_start = frame
        last_act = -1
        log("---- phase -> %s ----", phases[phase_idx])
    end
    if frame > 30000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
