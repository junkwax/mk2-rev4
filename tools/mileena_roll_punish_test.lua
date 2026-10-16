-- mileena_roll_punish_test.lua
--
-- "I block Mileena's roll with Cage, I uppercut, it misses."
--
-- Measures the actual geometry rather than arguing about the strike record.
-- P1 = Johnny Cage (human), P2 = Mileena (human), both scripted.  P2 fires
-- Back,Back,Down + HK (scom_kano -> do_fn2_kano); P1 crouch-blocks it, then
-- uppercuts DELAY ticks after the block lands.  DELAY is swept, so one run
-- answers both "does it ever connect" and "when".
--
-- Crouch-block on purpose: it is the BEST case for the punish.  A standing
-- blocker has to duck first, which only costs more ticks.  If the uppercut
-- whiffs from here it whiffs from everywhere.
--
-- Logged per tick from the moment she is blocked (act_kano_sd):
--   h2  = her feet above ground level (p_ganiy - oypos)
--   gap = |p2 oxpos - p1 oxpos|
-- so a whiff can be attributed to HEIGHT or to DISTANCE, not just recorded.
--
-- Env: MRP_LOG, MRP_DELAYS (comma list of ticks), MRP_GAP, MRP_BLOCK=stand|duck
-- Usage: tools\run_mileena_roll_punish_test.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("MRP_LOG") or (ROOT .. "/tools/mileena_roll_punish_test.log")
local BLOCKMODE = os.getenv("MRP_BLOCK") or "duck"
local START_GAP = tonumber(os.getenv("MRP_GAP") or "150")

-- CONTROL mode: no roll at all.  Pin the two of them at a fixed gap and
-- uppercut a standing Mileena, sweeping the gap.  Without this a whiff after
-- the roll cannot be attributed: "out of range" and "she is not hittable in
-- act_kano_sd" look identical from the punish sweep alone.
local CONTROL = os.getenv("MRP_CONTROL") == "1"
local VERBOSE = os.getenv("MRP_VERBOSE") == "1"
local GAPS = {}
for s2 in (os.getenv("MRP_GAPS") or "60,70,80,86,90,96,100,104,110"):gmatch("[^,]+") do
    GAPS[#GAPS+1] = tonumber(s2)
end

local DELAYS = {}
for s in (os.getenv("MRP_DELAYS") or "0,4,8,12,16,24,32,40,48,54,58,62,66,70"):gmatch("[^,]+") do
    DELAYS[#DELAYS+1] = tonumber(s)
end

local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = "[mrp] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

-- symbols: raw map addresses, which is what MAME's Lua space:read/write take
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
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"),
}

-- action ids are .set equates -> not in the map, read MAINEQU.ASM
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
local ACT_KANO, ACT_KANO_SD = act("act_kano"), act("act_kano_sd")
local ACT_UPPERCUT = act("act_uppercut")
local ACT_STANCE = act("act_stance")

local OXVAL, OXPOS, OYPOS = 0x080, 0x090, 0x0b0
local PROC_ACTION, PROC_GANIY = 0x1f0, 0x200
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_CAGE, FT_FN2 = 2, 5
-- P1 is swappable: the uppercut x_offset is 78 on every non-boss, but the
-- ATTACKER anchor is not, so "it reaches for Cage" is not proof for the rest.
local FT_P1 = tonumber(os.getenv("MRP_P1CHAR") or "2")
local MAX_HP = 0xa1

local space, frame = nil, 0
local fields = {}
local charsel_frame, fighting_frame = 0, 0
local confirm_frame = 0
local phase, phase_frame = "boot", 0
local trial, t0 = 1, 0
local bar_at_block, upcut_seen, hit_tick, upcut_tick = 0, false, -1, -1
local traj, results = {}, {}
local attempts = 0
local last_p1act = -1
local done = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function pact(p)
    local q = r32(p); if q == 0 then return 0xffff end
    return r16(q + PROC_ACTION)
end
local function pobjx(p) local o = r32(p); if o == 0 then return nil end; return s16(r16(o + OXPOS)) end
local function pheight(pp, op)
    local q, o = r32(pp), r32(op)
    if q == 0 or o == 0 then return -1 end
    return s16(r16(q + PROC_GANIY)) - s16(r16(o + OYPOS))
end
local function setx(op, x)
    local o = r32(op); if o == 0 then return end
    w32(o + OXVAL, (x & 0xffff) << 16)
    w16(o + OXPOS, x & 0xffff)
end

local function set_phase(p) phase = p; phase_frame = frame end

local function finish()
    if done then return end
    done = true
    log("---- trajectory of the BLOCKED roll (tick 0 = act_kano_sd) ----")
    log("  t | her feet above ground | gap px")
    for _, r in ipairs(traj) do
        log(" %2d | %21d | %6d | p1act %04x", r[1], r[2], r[3], r[4] or 0)
    end
    if CONTROL then
        log("---- CONTROL: uppercut a standing Mileena at a pinned gap ----")
        log("   gap | uppercut out | connected")
        local h = 0
        for _, r in ipairs(results) do
            if r.hit then h = h + 1 end
            log("   %3d | %12s | %9s", r.delay, r.upcut and "yes" or "NO",
                r.hit and "YES" or "no")
        end
        log("RESULT control %d/%d gaps connected", h, #results)
        manager.machine:exit()
        return
    end
    log("---- uppercut punish attempts ----")
    log(" delay | uppercut started at t | connected | her h / gap when the box goes live")
    local hits = 0
    for _, r in ipairs(results) do
        if r.hit then hits = hits + 1 end
        log("   %3d | %20s | %9s | h=%s gap=%s",
            r.delay, r.upcut and ("t=" .. tostring(r.upcut_tick)) or "NEVER CAME OUT",
            r.hit and ("YES @t" .. r.hit_tick) or "no",
            tostring(r.h_live), tostring(r.gap_live))
    end
    log("RESULT %d/%d uppercut delays connected", hits, #results)
    if #results == 0 then log("FAIL: no trial ever ran - the roll never got blocked") end
    manager.machine:exit()
end

local function cache_fields()
    local want = {
        ["Coin 1"]=1, ["Coin 2"]=1, ["1 Player Start"]=1, ["2 Players Start"]=1,
        ["P1 Down"]=1, ["P1 Left"]=1, ["P1 Right"]=1, ["P1 Block"]=1, ["P1 Block 2"]=1,
        ["P1 High Punch"]=1,
        ["P2 Down"]=1, ["P2 Left"]=1, ["P2 Right"]=1, ["P2 High Kick"]=1,
        ["P2 High Punch"]=1,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input: %s", n) end end
end

-- P2 starts on the RIGHT, so his "back" is Right.
local p2_back = "P2 Right"

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame > 300 and (frame % 90) < 22
        end
        if name == "1 Player Start" then return frame > 520 and (frame % 160) >= 80 and (frame % 160) < 120 end
        if name == "2 Players Start" then return frame > 520 and (frame % 160) >= 120 end
        return false
    end
    if fighting_frame == 0 then
        if confirm_frame > 0 and (name == "P1 High Punch" or name == "P2 High Punch") then
            return frame >= confirm_frame and frame < confirm_frame + 60
        end
        return false
    end

    local c = frame - phase_frame

    if phase == "roll" then
        -- Back, Back, Down + HK.  Taps with clean gaps: the combo scanner
        -- wants two separate BACK entries, not one held switch.
        if name == p2_back then return (c >= 4 and c < 8) or (c >= 12 and c < 16) end
        if name == "P2 Down" then return c >= 20 end
        if name == "P2 High Kick" then return c >= 24 and c < 28 end
    end

    -- P1 guards from the moment P2 commits, and through the whole roll.
    if phase == "roll" or phase == "rolling" then
        if name == "P1 Block" or name == "P1 Block 2" then return true end
        if name == "P1 Down" then return BLOCKMODE == "duck" end
    end

    if phase == "cpin" then
        return false
    end
    if phase == "cupcut" then
        local t = frame - phase_frame
        if name == "P1 Down" then return true end
        if name == "P1 High Punch" then return t >= 8 and t < 14 end
        return false
    end

    if phase == "punish" then
        local t = frame - t0
        local d = DELAYS[trial]
        -- Down must be held WELL before the punch.  Pressing them together
        -- gives a standing HP: the duck transition takes several ticks, and
        -- do_uppercut only comes out of a crouch.  The first cut of this rig
        -- pressed Down at d-1 and scored 0/7 "misses" that were really 7
        -- uppercuts that never existed.
        if name == "P1 Down" then return BLOCKMODE == "duck" or t >= d - 8 end
        -- PULSE the punch, do not hold it.  A single press that starts on the
        -- tick block stun ends is swallowed (the block exit stuffs whatever is
        -- already held), so delays 9-14 reported "uppercut never came out" and
        -- looked like misses.  Pulsing gives a clean press edge every 6 ticks
        -- until one is accepted; upcut_tick records when it actually started.
        if name == "P1 High Punch" then
            return t >= d and t < d + 24 and ((t - d) % 6) < 3
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- P1 char %d vs Mileena: block the roll, uppercut after N ticks (block=%s gap=%d) ----",
            FT_P1, BLOCKMODE, START_GAP)
        log("     act_kano=%04x act_kano_sd=%04x act_uppercut=%04x",
            ACT_KANO, ACT_KANO_SD, ACT_UPPERCUT)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_P1); w16(A.p2_char, FT_FN2)
        w16(A.curback, 0)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        set_phase("setup")
        log("fight start frame=%d", frame)
    end
    if fighting_frame == 0 then
        if frame > 7000 then log("ERROR never reached the fight"); finish() end
        return
    end

    -- never let a round end under us
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    if r16(A.winner_status) ~= 0 then w16(A.winner_status, 0) end

    local a1, a2 = pact(A.p1_proc), pact(A.p2_proc)
    local x1, x2 = pobjx(A.p1_obj), pobjx(A.p2_obj)
    local gap = (x1 and x2) and math.abs(x2 - x1) or -1
    local h2 = pheight(A.p2_proc, A.p2_obj)
    local c = frame - phase_frame

    if CONTROL then
        if phase == "setup" then set_phase("cpin") ; return end
        if phase == "cpin" then
            w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
            if trial > #GAPS then finish(); return end
            setx(A.p1_obj, 120)
            setx(A.p2_obj, 120 + GAPS[trial])
            -- She must be STANDING and idle.  The first cut fired 20 ticks
            -- after the previous trial and every second gap "missed" because
            -- she was still flat on her back from the last uppercut - which
            -- reads exactly like an out-of-range whiff.
            if c > 40 and a2 == ACT_STANCE then
                bar_at_block = r16(A.p2_bar)
                hit_tick, upcut_seen, last_p1act = -1, false, -1
                set_phase("cupcut")
            end
            return
        end
        if phase == "cupcut" then
            local t = c
            if a1 == ACT_UPPERCUT then upcut_seen = true end
            if hit_tick < 0 and r16(A.p2_bar) < bar_at_block then hit_tick = t end
            if t == 14 then
                results[#results+1] = { delay = GAPS[trial], h_live = h2, gap_live = gap }
            end
            if t > 60 then
                local r = results[#results]
                if r then r.upcut = upcut_seen; r.hit = (hit_tick >= 0); r.hit_tick = hit_tick end
                log("control gap=%d upcut=%s hit=%s", GAPS[trial], tostring(upcut_seen),
                    tostring(hit_tick >= 0))
                trial = trial + 1
                set_phase("cpin")
            end
            return
        end
        return
    end

    if phase == "setup" then
        w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
        if c < 6 then
            setx(A.p1_obj, 120)
            setx(A.p2_obj, 120 + START_GAP)
        end
        if c > 24 then
            if trial > #DELAYS then finish(); return end
            attempts = attempts + 1
            if attempts > #DELAYS * 6 + 20 then
                log("giving up: too many attempts (%d) for %d trials", attempts, #DELAYS)
                finish(); return
            end
            set_phase("roll")
        end
        return
    end

    if phase == "roll" then
        if a2 == ACT_KANO then set_phase("rolling"); return end
        if c > 120 then set_phase("setup") end
        return
    end

    if phase == "rolling" then
        if a2 == ACT_KANO_SD then
            t0 = frame
            bar_at_block = r16(A.p2_bar)
            upcut_seen, hit_tick, last_p1act, upcut_tick = false, -1, -1, -1
            set_phase("punish")
            log("trial %d: roll BLOCKED, delay=%d, gap=%d", trial, DELAYS[trial], gap)
            return
        end
        if a2 ~= ACT_KANO and c > 90 then
            -- roll ended without being blocked (whiffed or landed) - retry
            set_phase("setup")
        end
        return
    end

    if phase == "cpin" then
        return false
    end
    if phase == "cupcut" then
        local t = frame - phase_frame
        if name == "P1 Down" then return true end
        if name == "P1 High Punch" then return t >= 8 and t < 14 end
        return false
    end

    if phase == "punish" then
        local t = frame - t0
        if trial == 1 and t <= 70 then traj[#traj+1] = { t, h2, gap, a1 } end
        if a1 == ACT_UPPERCUT then
            if not upcut_seen then upcut_tick = t end
            upcut_seen = true
        end
        if a1 ~= last_p1act then
            log("  trial %d t=%2d p1 action %04x (h2=%d gap=%d)", trial, t, a1, h2, gap)
            last_p1act = a1
        end
        local bar = r16(A.p2_bar)
        if hit_tick < 0 and bar < bar_at_block then hit_tick = t end
        if #results == 0 or results[#results].delay ~= DELAYS[trial] then
            results[#results+1] = { delay = DELAYS[trial] }
        end
        if upcut_tick >= 0 and t == upcut_tick + 2 then
            results[#results].h_live = h2; results[#results].gap_live = gap
        end
        -- per-tick window around the swing: one sample cannot tell a whiff on
        -- HEIGHT from a whiff on RANGE, and the two want opposite fixes.
        if VERBOSE and upcut_tick >= 0 and t >= upcut_tick and t <= upcut_tick + 7 then
            local p1o = r32(A.p1_obj)
            local p1y = (p1o ~= 0) and s16(r16(p1o + OYPOS)) or 0
            log("    win d=%d t=%2d p1act=%04x p1y=%d h2=%d gap=%d",
                DELAYS[trial], t, a1, p1y, h2, gap)
        end
        if t > DELAYS[trial] + 80 then
            local r = results[#results]
            if r and r.delay == DELAYS[trial] then
                r.upcut = upcut_seen; r.hit = (hit_tick >= 0); r.hit_tick = hit_tick
                r.upcut_tick = upcut_tick
            end
            log("trial %d done: delay=%d upcut=%s hit=%s", trial, DELAYS[trial],
                tostring(upcut_seen), tostring(hit_tick >= 0))
            trial = trial + 1
            set_phase("setup")
        end
        return
    end
end)
