-- fatal_lock_test.lua
--
-- One finisher per round (f_fatal_lock, RAM.ASM).
--
-- The bug: Liu Kang's cartwheel (do_wheel_kick) ended in reaction_exit, which
-- handed the stick back with winner_status still 3.  Holding LP+LK into an
-- uppercut then ran do_uppercut's Dead Pool branch (ucut2), which never looked
-- at f_death, and dropped the already-dead victim into the acid - a second
-- finisher on top of the first.
--
-- This rig reproduces the state the cartwheel leaves behind rather than the
-- cartwheel itself: FINISH HIM, victim dizzy, f_death = -1 and (MODE=locked)
-- f_fatal_lock = 1 - then fires the stage-fatality uppercut over and over.
--
--   FL_MODE=locked   lock + f_death set  -> PASS if the victim is NEVER slimed
--   FL_MODE=control  both clear          -> PASS if the victim IS slimed
--                                           (proves the rig can see one)
--
-- Env: FL_MODE, FL_TEST_LOG

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("FL_TEST_LOG") or (ROOT .. "/tools/fatal_lock_test.log")
local MODE = (os.getenv("FL_MODE") or "locked"):lower()

local VICTIM_X, GAP = 560, 55
local ATTEMPTS = 6

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local function log(fmt, ...)
    local line = "[fatlock] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(name)
    local v = symbols[name]
    if v == nil then log("WARN missing symbol %s", name); return 0 end
    return v
end

local A = {
    gstate = sym("gstate"), p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    curback = sym("curback"), winner_status = sym("winner_status"),
    f_death = sym("f_death"), f_fatal_lock = sym("f_fatal_lock"),
    dizzy_dude = sym("dizzy_dude"), dizzy = sym("dizzy"),
}
local O = { oxval = 0x080, oxpos = 0x090, ochar = 0x1f0 }
local P = { wake = 0x0e0, action = 0x1f0, flags = 0x210 }
local GS_PSEL, GS_FIGHTING, PS_ACTIVE = 4, 2, 1
local FT_KANG, FT_JAX = 1, 11
local ACT_SLIME_FALL, ACT_STUNNED = 0x050a, 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010

local space, fields = nil, {}
local last_gstate, charsel_frame, fighting_frame, p1_confirm_start = -1, 0, 0, 0
local finish_frame, dizzy_forced, attempt_start, attempt_n = 0, false, 0, 0
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function snap()
    pcall(function() manager.machine.screens[":screen"]:snapshot() end)
end

local function p2_action()
    local p = r32(A.p2_proc); if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function state()
    return string.format("gs=%d ws=%d f_death=%d lock=%d p2act=0x%04x",
        r16(A.gstate), r16(A.winner_status), s16(r16(A.f_death)),
        r16(A.f_fatal_lock), p2_action())
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    snap()
    log("RESULT %s mode=%s reason=%s attempts=%d | %s", ok and "PASS" or "FAIL",
        MODE, reason, attempt_n, state())
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["Coin 1"] = 1, ["Coin 2"] = 1, ["2 Players Start"] = 1,
        ["P1 High Punch"] = 1, ["P2 High Punch"] = 1, ["P1 Low Punch"] = 1,
        ["P1 Low Kick"] = 1, ["P1 Down"] = 1 }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        if not fields[name] then log("input %s MISSING", name); return false end
    end
    return true
end

local function fighters_ok()
    local a, v = r32(A.p1_obj), r32(A.p2_obj)
    return a ~= 0 and v ~= 0 and r16(a + O.ochar) == FT_KANG and r16(v + O.ochar) == FT_JAX
end

-- Re-asserted every frame: the state the cartwheel's reaction_exit used to
-- leave behind.  (control mode keeps both flags clear instead.)
local function force_state()
    w16(A.winner_status, 3)
    w16(A.curback, 0)
    if MODE == "locked" then
        w16(A.f_death, 0xffff)
        w16(A.f_fatal_lock, 1)
    else
        w16(A.f_death, 0)
        w16(A.f_fatal_lock, 0)
    end
    local p1p = r32(A.p1_proc)
    if p1p ~= 0 then
        w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    end
    local p2p = r32(A.p2_proc)
    if p2p ~= 0 and not dizzy_forced then
        w32(p2p + P.wake, A.dizzy_dude)
        dizzy_forced = true
    end
    local a, v = r32(A.p1_obj), r32(A.p2_obj)
    w16(v + O.oxpos, VICTIM_X); w32(v + O.oxval, VICTIM_X << 16)
    w16(a + O.oxpos, VICTIM_X + GAP); w32(a + O.oxval, (VICTIM_X + GAP) << 16)
end

local function victim_ready()
    local p = r32(A.p2_proc)
    if p == 0 then return false end
    local wake = r32(p + P.wake)
    return wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(p + P.action) == ACT_STUNNED
end

-- LP+LK held throughout (the Dead Pool modifier), Down, then HP = uppercut.
local ATTEMPT_LEN = 70
local function press_for(name, rel)
    if name == "P1 Low Punch" or name == "P1 Low Kick" then return true end
    if name == "P1 Down" then return rel >= 20 end
    if name == "P1 High Punch" then return rel >= 34 and rel < 42 end
    return false
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start > 0 then
        if name == "P1 High Punch" then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    if attempt_start > 0 and frame >= attempt_start then
        return press_for(name, (frame - attempt_start) % ATTEMPT_LEN)
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        if A.f_fatal_lock == 0 then finish(false, "no_f_fatal_lock_symbol"); return end
        if not cache_fields() then finish(false, "input_missing"); return end
        log("mode=%s", MODE)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end

    if fighting_frame == 0 then
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_JAX); w16(A.curback, 0)
        w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, PS_ACTIVE)
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90 then
            p1_confirm_start = frame + 25
        end
    elseif fighters_ok() and frame - fighting_frame >= 90 then
        force_state()
        if finish_frame == 0 then finish_frame = frame; log("finish_him frame=%d | %s", frame, state()) end
        if attempt_start == 0 and victim_ready() then
            attempt_start = frame + 10
            log("victim dizzy frame=%d | %s", frame, state())
        end
        if attempt_start > 0 and frame >= attempt_start and (frame - attempt_start) % ATTEMPT_LEN == 0 then
            attempt_n = attempt_n + 1
            log("uppercut attempt %d frame=%d | %s", attempt_n, frame, state())
            if attempt_n == 3 then snap() end
        end
        if p2_action() == ACT_SLIME_FALL then
            if MODE == "locked" then finish(false, "second_finisher_slimed_the_victim")
            else finish(true, "control_slimed_as_expected") end
            return
        end
        if attempt_n > ATTEMPTS then
            if MODE == "locked" then finish(true, "no_second_finisher")
            else finish(false, "control_never_slimed_rig_is_blind") end
            return
        end
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if fighting_frame == 0 and frame > 9000 then finish(false, "never_reached_fight")
    elseif frame > 20000 then finish(false, "global_timeout") end
end)

emu.register_stop(function()
    if logfh then logfh:close(); logfh = nil end
end)
