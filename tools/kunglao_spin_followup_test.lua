-- kunglao_spin_followup_test.lua
--
-- "I jump in, spin to hit, and then I am stuck to the ground."
--
-- Measures the follow-up window off Kung Lao's spin, in TICKS, with no
-- eyeballing.  do_hh_spin (MOVES.ASM) and the victim reaction mark their own
-- boundaries:
--
--   p1 p_action = act_hhspin          <- spin begins, tick 0
--   p2 oypos starts RISING            <- the hit: r_hhspin IS r_upcutted, so
--                                        the victim is launched like an uppercut
--   p1 p_action leaves act_hhspin     <- hhspin_hit cool-down over, joy_entry
--                                        has him back
--   p1 p_action = act_jumpup          <- the follow-up jump actually left
--   p2 oypos back at its ground value <- the juggle window has closed
--
-- The rig HOLDS Up+Forward from the moment of the hit, so the jump comes out
-- on the first tick the game will accept one.  If "stuck to the ground" is
-- just the cool-down, then to_jump is that cool-down; if something is
-- REFUSING the jump, p1 sits actionable and the gap between free and jumped
-- is where it shows.  Those are different bugs and the rig separates them.
--
-- Reports, per trial:
--   startup   hit  - spin start    how long the box took to connect
--   lockout   free - hit           unactionable ticks the hit costs
--   to_jump   jump - hit           what the player actually feels
--   window    p2 land - jump       airtime left to hit them with
--
-- Env: KLS_LOG, KLS_TRIALS, KLS_TRACE
-- Usage: tools\run_kunglao_spin_followup_test.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("KLS_LOG") or (ROOT .. "/tools/kunglao_spin_followup_test.log")
local TRIALS = tonumber(os.getenv("KLS_TRIALS") or "4")
local TRACE = tonumber(os.getenv("KLS_TRACE") or "1")

local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = "[spin] " .. string.format(fmt, ...)
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
local ACT_SPIN = act("act_hhspin")
local ACT_STANCE = act("act_stance")
local ACT_JUMPUP = act("act_jumpup")
local ACT_ANGLE_JUMP = act("act_angle_jump")

local OXVAL, OXPOS, OYPOS = 0x080, 0x090, 0x0b0
local P_ACTION = 0x1f0
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_HATHEAD, FT_KANG = 0, 1
local MAX_HP = 0xa1
local P1X, P2X = 140, 210

local space, frame = nil, 0
local fields = {}
local charsel_frame, fighting_frame, confirm_frame = 0, 0, 0
local phase, phase_frame = "boot", 0
local trial, results, done = 1, {}, false
local t_spin, t_hit, t_free, t_jump, t_land = -1, -1, -1, -1, -1
local p2_ground, trace, p2_left_ground = nil, {}, false
-- CONTROL: ticks from "Up+Forward held" to airborne, from a clean stance and
-- with no spin anywhere near it.  Without this number the 10 ticks between
-- "p1 is actionable" and "p1 is airborne" after the spin look like the spin
-- leaving something behind, when a jump may simply cost that much.
local control_ticks, control_start = nil, -1

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function w32(a, v) space:write_u32(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function pact(p)
    local q = r32(p); if q == 0 then return 0xffff end
    return r16(q + P_ACTION)
end
local function oy(op)
    local o = r32(op); if o == 0 then return nil end
    return s16(r16(o + OYPOS))
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
    log("")
    log("---- Kung Lao spin: the follow-up window ----")
    log(" trial | startup | lockout | to_jump | window | verdict")
    local jumped, windowed = 0, 0
    for _, r in ipairs(results) do
        local verdict
        if r.to_jump < 0 then verdict = "NEVER JUMPED"
        elseif r.window == nil then verdict = "jumped, p2 landing not seen"
        elseif r.window > 0 then verdict = string.format("%d ticks of airtime left", r.window)
        else verdict = "TOO LATE - p2 already landed" end
        log("  %4d | %7s | %7s | %7s | %6s | %s",
            r.trial,
            tostring(r.startup), tostring(r.lockout), tostring(r.to_jump),
            r.window and tostring(r.window) or "-",
            verdict)
        if r.to_jump >= 0 then jumped = jumped + 1 end
        if r.window and r.window > 0 then windowed = windowed + 1 end
    end
    log("")
    log("startup = spin start -> the hit.  lockout = hit -> p1 actionable.")
    log("to_jump = hit -> p1 airborne, holding Up+Forward the whole time.")
    log("window  = airtime p2 has left once p1 is off the ground.")
    log("CONTROL jump from a clean stance: %s ticks - subtract it from to_jump",
        control_ticks and tostring(control_ticks) or "not measured")
    log("RESULT %d/%d jumped at all, %d/%d had any airtime left to hit",
        jumped, #results, windowed, #results)
    if #results == 0 then log("FAIL: the spin never connected") end
    manager.machine:exit()
end

local function cache_fields()
    local want = {
        ["Coin 1"] = 1, ["1 Player Start"] = 1,
        ["P1 Left"] = 1, ["P1 Right"] = 1, ["P1 Up"] = 1,
        ["P1 High Punch"] = 1, ["P1 Low Kick"] = 1,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input: %s", n) end end
end

-- P1 is on the LEFT: forward is Right.
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
    if phase == "control" then
        return (name == "P1 Up" or name == "P1 Right")
    end
    if phase ~= "spin" then return false end
    local c = frame - phase_frame

    -- after the hit: hold Up+Forward and NOTHING else, so the only thing that
    -- can come out is the jump we are timing
    if t_hit >= 0 then
        if name == "P1 Up" or name == "P1 Right" then return true end
        return false
    end

    -- Forward, Forward + LK, then keep tapping LK to sustain the tap phase
    -- (the UMK3 shape can only ever connect while the player is tapping)
    if name == "P1 Right" then return (c >= 4 and c < 8) or (c >= 12 and c < 16) end
    if name == "P1 Low Kick" then
        if c >= 17 and c < 21 then return true end
        return c >= 21 and ((c - 21) % 8) < 3
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("act_hhspin=%04x act_stance=%04x act_jumpup=%04x act_angle_jump=%04x",
            ACT_SPIN, ACT_STANCE, ACT_JUMPUP, ACT_ANGLE_JUMP)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_HATHEAD); w16(A.p2_char, FT_KANG)
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

    -- nobody wins, nobody dies, so every trial starts from the same place
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if r16(A.winner_status) ~= 0 then w16(A.winner_status, 0) end

    local a1, a2 = pact(A.p1_proc), pact(A.p2_proc)
    local y2 = oy(A.p2_obj)
    local c = frame - phase_frame

    if phase == "settle" then
        setx(A.p1_obj, P1X); setx(A.p2_obj, P2X)
        if c > 30 and a1 == ACT_STANCE then
            t_spin, t_hit, t_free, t_jump, t_land = -1, -1, -1, -1, -1
            p2_ground, trace, p2_left_ground = y2, {}, false
            if control_ticks == nil then
                control_start = frame
                set_phase("control")
            else
                set_phase("spin")
            end
        end
        return
    end

    if phase == "control" then
        setx(A.p2_obj, P2X)
        if a1 == ACT_JUMPUP or a1 == ACT_ANGLE_JUMP then
            control_ticks = frame - control_start
            log("CONTROL: jump from a clean stance took %d ticks (act %04x)",
                control_ticks, a1)
            set_phase("settle")
        elseif c > 120 then
            control_ticks = -1
            log("CONTROL: never jumped from stance (act %04x)", a1)
            set_phase("settle")
        end
        return
    end

    if phase == "spin" then
        -- hold P2 still until the hit; after it, let him fly
        if t_hit < 0 then setx(A.p2_obj, P2X) end

        if TRACE > 0 and trial == 1 and #trace < 220 then
            trace[#trace + 1] = string.format("%3d p1=%04x p2=%04x y2=%s", c, a1, a2,
                y2 and tostring(y2) or "-")
        end

        if a1 == ACT_SPIN and t_spin < 0 then t_spin = frame end
        -- the hit: the victim is launched, so his oypos climbs off the floor
        if t_spin >= 0 and t_hit < 0 and p2_ground and y2 and y2 < p2_ground - 4 then
            t_hit = frame
        end
        if t_hit >= 0 and t_free < 0 and a1 ~= ACT_SPIN then t_free = frame end
        if t_free >= 0 and t_jump < 0
           and (a1 == ACT_JUMPUP or a1 == ACT_ANGLE_JUMP) then t_jump = frame end
        -- p2 can land BEFORE p1 gets off the ground, so time the landing from
        -- the hit and let window go negative rather than starting the clock at
        -- the jump and reading a stale ground value as "landed now"
        if t_hit >= 0 and t_land < 0 and p2_left_ground
           and p2_ground and y2 and y2 >= p2_ground - 2 then
            t_land = frame
        end
        if t_hit >= 0 and not p2_left_ground and p2_ground and y2
           and y2 < p2_ground - 20 then p2_left_ground = true end

        local finished = (t_jump >= 0 and t_land >= 0)
        if finished or c > 300 then
            if t_spin < 0 then
                log("trial %d: TIMEOUT - the spin never came out (p1 act %04x)", trial, a1)
            elseif t_hit < 0 then
                log("trial %d: TIMEOUT - the spin never connected", trial)
            else
                results[#results + 1] = {
                    trial = trial,
                    startup = t_hit - t_spin,
                    lockout = (t_free >= 0) and (t_free - t_hit) or -1,
                    to_jump = (t_jump >= 0) and (t_jump - t_hit) or -1,
                    window = (t_jump >= 0 and t_land >= 0) and (t_land - t_jump) or nil,
                }
                local r = results[#results]
                log("trial %d: startup %d, lockout %s, to_jump %s, window %s",
                    trial, r.startup, tostring(r.lockout), tostring(r.to_jump),
                    tostring(r.window))
                if TRACE > 0 and trial == 1 then
                    for _, t in ipairs(trace) do log("  %s", t) end
                end
            end
            if trial >= TRIALS then finish(); return end
            trial = trial + 1
            set_phase("settle")
        end
        return
    end
end)
