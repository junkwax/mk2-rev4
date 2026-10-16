-- jc_air_shadow_test.lua
--
-- Johnny Cage's AIR SHADOW KICK - Back, Down, Back + LK, from the ground.
-- The kick carries him up into the air; the rise is in the art and the lane,
-- so oypos never leaves the floor and "airborne" is not a test of anything.
--
-- The shipped shadow kick (B,F + LK) ALSO sets act_shadk, so the action code
-- cannot tell the two apart.  What can: the input the phase drove, the kick's
-- length (the stock kick stops within ~20 ticks, this one walks a 36-tick
-- lane), and the damage (30 vs 28).
--
-- Phases (P1 = Cage, P2 = Liu Kang, both human so no AI interferes):
--   shadow  - B,F + LK.   The stock kick must still come out and connect.
--   airkick - B,D,B + LK. The new move: a trail, the 043h shadow-kick sound,
--             damage on P2, and an end (he must leave act_shadk).  P2 is
--             pinned at a rotating gap so the log shows WHERE it connects.
--   jumping - Up, then B,D,B + LK.  Must NOT fire: it is a ground special and
--             restricted_xfer refuses an airborne caller.
--
-- The hitbox overlay (f_colbox = 5: strike box red, hurt box white) is on for
-- the whole run, so the snapshots show the box against the foot.
--
-- Every attempt refills P2 so the NEXT one is measurable; HP is sampled
-- before the refill so the damage per connect is honest.
--
-- Usage: tools\run_jc_air_shadow_test.ps1

local LOGP = os.getenv("JCAS_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/jc_air_shadow_test.log"

local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[jcas] " .. string.format(fmt, ...)
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
    active = sym("active"), f_colbox = sym("f_colbox"),
    chan1pri = sym("chan1pri"), chan1dur = sym("chan1dur"),
    chan2pri = sym("chan2pri"), chan2dur = sym("chan2dur"),
    chan3pri = sym("chan3pri"), chan3dur = sym("chan3dur"),
}

local OXVAL, OXPOS, OYPOS = 0x080, 0x090, 0x0b0
local PROC_ACTION = 0x1f0
local PROCID = 0x20
local PS_ACTIVE = 1
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1

local FT_CAGE = 2
local ACT_SHADK = 0x0205
local PID_SHADOW1 = 0x0106

-- triple_sndtab 043h = sp_effect|67: priority 050h, duration 67 ticks.
local SND_PRI, SND_DUR_MIN = 0x50, 60

-- A jump clears the floor by ~100px at apex; 25 is well past any settling
-- wobble, so a kick that starts above it was cast from a jump.
local AIRBORNE_MIN = 25

-- The stock kick ends inside ~20 ticks; this one walks nine rows at sleep 4.
local LONG_KICK = 30

local SHOTS_WANTED = 8
local SHOT_GAP = tonumber(os.getenv("JCAS_SHOT_GAP") or "90")
local GAPS = { 70, 90, 110, 130 }
local CYCLE = 150

local PHASE_FRAMES = 1500
local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local phase_idx, phase_start = 1, 0
local phases = { "shadow", "airkick", "jumping" }
local fields = {}
local done = false

local ground_y = nil            -- P1's oypos while standing idle
local shots = 0

local function newstat()
    return { kicks = 0, long = 0, peak_shadows = 0, sounds = 0, hits = 0,
             dmg = 0, max_height = 0, ended = 0, hit_gaps = {}, air_casts = 0 }
end
local stat = { shadow = newstat(), airkick = newstat(), jumping = newstat() }

local in_kick, kick_peak, kick_sound = false, 0, false
local kick_h0, kick_hp0, kick_frames, kick_gap = 0, 0, 0, 0
local pressed_prev = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function objxy(p)
    local o = r32(p); if o == 0 then return nil end
    return s16(r16(o + OXPOS)), s16(r16(o + OYPOS))
end
local function pin(objptr, x)
    local o = r32(objptr); if o == 0 then return end
    space:write_u32(o + OXVAL, (x & 0xffff) << 16)
    w16(o + OXPOS, x & 0xffff)
end

local function count_pid(pid)
    local n, p, guard = 0, r32(A.active), 0
    while p ~= 0 and guard < 400 do
        if r16(p + PROCID) == pid then n = n + 1 end
        p = r32(p); guard = guard + 1
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

local function snap()
    if shots >= SHOTS_WANTED then return end
    local ok = pcall(function() manager.machine.video:snapshot() end)
    if ok then shots = shots + 1 end
end

local function finish()
    if done then return end
    done = true
    for _, ph in ipairs(phases) do
        local S = stat[ph]
        local gaps = {}
        for g, n in pairs(S.hit_gaps) do gaps[#gaps+1] = string.format("%d:%d", g, n) end
        table.sort(gaps)
        log("RESULT %-7s kicks=%d long=%d shadows=%d sounds=%d hits=%d dmg=%d ended=%d start_h=%d air_lk=%d hits@gap=[%s]",
            ph, S.kicks, S.long, S.peak_shadows, S.sounds, S.hits, S.dmg, S.ended,
            S.max_height, S.air_casts, table.concat(gaps, " "))
    end
    local g, a, j = stat.shadow, stat.airkick, stat.jumping
    local fails = {}
    if g.kicks == 0 then fails[#fails+1] = "stock shadow kick (B,F+LK) never came out" end
    if g.kicks > 0 and g.hits == 0 then fails[#fails+1] = "stock shadow kick stopped connecting" end
    if g.long > 0 then
        fails[#fails+1] = "B,F + LK played the LONG lane - it is reaching the new move"
    end
    if a.kicks == 0 then
        fails[#fails+1] = "B,D,B + LK never fired"
    else
        if a.long == 0 then fails[#fails+1] = "B,D,B + LK fired the SHORT kick, not the new lane" end
        if a.max_height > AIRBORNE_MIN then fails[#fails+1] = "new move started off the floor" end
        if a.peak_shadows < 3 then
            fails[#fails+1] = string.format("trail only reached %d shadows", a.peak_shadows)
        end
        if a.sounds == 0 then fails[#fails+1] = "no shadow-kick sound" end
        if a.hits == 0 then fails[#fails+1] = "never connected at any gap" end
        if a.dmg > 0 and a.dmg ~= 28 then
            fails[#fails+1] = string.format("damage %d, stk_jcairshadow says 28", a.dmg)
        end
        if a.ended < a.kicks - 1 then fails[#fails+1] = "a kick never ended" end
    end
    if j.long > 0 and j.max_height > AIRBORNE_MIN then
        fails[#fails+1] = "B,D,B + LK fired from a JUMP - it is a ground special"
    end
    if j.air_casts == 0 then
        fails[#fails+1] = "jumping phase never had him in the air when LK went in - the control proves nothing"
    end
    if #fails == 0 then log("PASS jc_air_shadow")
    else log("FAIL jc_air_shadow: %s", table.concat(fails, "; ")) end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["2 Players Start"]=true,
                   ["P1 High Punch"]=true, ["P1 Low Kick"]=true,
                   ["P1 Left"]=true, ["P1 Right"]=true, ["P1 Up"]=true, ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

-- P1 is pinned LEFT of P2, so BACK = Left, FORWARD = Right.
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
    if rel < 60 then return false end          -- let him settle, sample ground_y
    local t = (rel - 60) % CYCLE
    if ph == "shadow" then                     -- Back, Forward + LK
        if name == "P1 Left"     then return t >= 10 and t < 18 end
        if name == "P1 Right"    then return t >= 22 and t < 30 end
        if name == "P1 Low Kick" then return t >= 30 and t < 36 end
        return false
    end
    if ph == "jumping" then
        -- Jump first, then the whole motion INSIDE the jump.  A neutral jump
        -- is ~40 ticks in the air, so the button has to land by ~tick 30 or
        -- he is back on the floor and the move fires as a legal ground one.
        if name == "P1 Up"       then return t >= 0  and t < 6 end
        if name == "P1 Left"     then return (t >= 8 and t < 12) or (t >= 20 and t < 24) end
        if name == "P1 Down"     then return t >= 14 and t < 18 end
        if name == "P1 Low Kick" then return t >= 24 and t < 28 end
        return false
    end
    local off = 0
    -- Back, Down, Back + LK
    if name == "P1 Left" then
        return (t >= off+10 and t < off+18) or (t >= off+34 and t < off+42)
    end
    if name == "P1 Down"     then return t >= off+22 and t < off+30 end
    if name == "P1 Low Kick" then return t >= off+42 and t < off+48 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- cage AIR shadow kick (B,D,B + LK) ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, PS_ACTIVE)
        w16(A.p1_char, FT_CAGE); w16(A.p2_char, 1)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; phase_start = frame
        log("fight start frame=%d phase=%s", frame, phases[1])
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    if A.f_colbox ~= 0 then w16(A.f_colbox, 5) end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    local ph = phases[phase_idx]
    local rel = frame - phase_start
    local x1, y1 = objxy(A.p1_obj)
    -- the gap is chosen per CYCLE and held for the whole attempt
    local cyc = (rel >= 60) and ((rel - 60) // CYCLE) or 0
    local gap = (ph == "airkick") and GAPS[(cyc % #GAPS) + 1] or 90
    -- Pin right up until the kick starts - the Backs in the motion walk him
    -- away, so a pin that stops early measures a different gap than it logs.
    -- Once the kick is out, let him travel.
    if x1 and not in_kick and rel >= 60 then pin(A.p2_obj, x1 + gap) end

    if ground_y == nil and y1 and rel > 40 then
        ground_y = y1
        log("grounded oypos = %d", ground_y)
    end
    local height = (ground_y and y1) and (ground_y - y1) or 0

    local p = r32(A.p1_proc)
    local act = (p ~= 0) and r16(p + PROC_ACTION) or 0xffff
    local hp2 = r16(A.p2_bar)

    local S = stat[ph]
    if ph == "jumping" and fields["P1 Low Kick"] and pressed("P1 Low Kick")
       and not pressed_prev and height > AIRBORNE_MIN then
        S.air_casts = S.air_casts + 1
    end
    pressed_prev = pressed("P1 Low Kick")
    if act == ACT_SHADK then
        if not in_kick then
            in_kick, kick_peak, kick_sound = true, 0, false
            kick_h0, kick_hp0, kick_frames, kick_gap = height, hp2, 0, gap
            S.kicks = S.kicks + 1
            if height > S.max_height then S.max_height = height end
        end
        kick_frames = kick_frames + 1
        local n = count_pid(PID_SHADOW1)
        if n > kick_peak then kick_peak = n end
        if shadow_sound_now() then kick_sound = true end
        if ph == "airkick" and gap == SHOT_GAP and kick_frames >= 4 and kick_frames <= 18
           and (kick_frames % 2) == 0 then snap() end
    elseif in_kick then
        in_kick = false
        if kick_peak > S.peak_shadows then S.peak_shadows = kick_peak end
        if kick_sound then S.sounds = S.sounds + 1 end
        if kick_frames >= LONG_KICK then S.long = S.long + 1 end
        S.ended = S.ended + 1
        local dmg = kick_hp0 - hp2
        if dmg > 0 then
            S.hits = S.hits + 1
            if dmg > S.dmg then S.dmg = dmg end
            S.hit_gaps[kick_gap] = (S.hit_gaps[kick_gap] or 0) + 1
        end
        log("%s kick #%d: gap=%d start_h=%d ticks=%d shadows=%d sound=%s dmg=%d",
            ph, S.kicks, kick_gap, kick_h0, kick_frames, kick_peak, tostring(kick_sound), dmg)
        w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    else
        if hp2 < MAX_HP - 60 then
            w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
        end
    end

    if rel > PHASE_FRAMES and not in_kick then
        phase_idx = phase_idx + 1
        if phase_idx > #phases then finish(); return end
        phase_start = frame
        log("---- phase -> %s ----", phases[phase_idx])
    end
    if frame > 30000 then log("ERROR global timeout"); finish() end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
