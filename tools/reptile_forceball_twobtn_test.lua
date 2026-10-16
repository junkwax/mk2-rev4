-- reptile_forceball_twobtn_test.lua
--
-- Regression test for the rp_lo_punch two-button check fix (MOVES.ASM).
--
-- rp_lo_punch used to look back through the button queue exactly ONE entry
-- to find the partner HP press ("the entry right before me"). If anything
-- else - even a single stray direction blip - landed in the queue between
-- the HP press and the LP press, that lookup missed and the whole special
-- silently fell through to a plain low punch. Kitana's fan throw and Cage's
-- ballbreaker already use the shared two_button_check, which scans up to
-- twobtn_depth (3) entries back and tolerates exactly this. rp_lo_punch now
-- calls the same routine.
--
-- This rig reproduces the failure shape directly: F,F to arm the combo look,
-- then HP, then a deliberate STRAY direction tap (an extra tap of the same
-- F/F direction - anything with no combo meaning of its own), then LP.
-- Under the old depth-1 code that stray entry sits between HP and LP in the
-- queue and the match is lost every time (0/N). Under the fix it should
-- come out reliably (N/N).
--
-- MK2_TB_MODE=slow|fast   which forceball combo to arm (default slow)
-- MK2_TB_STRAY=0|1        0 = no stray tap, for an A/B baseline (default 1)
-- MK2_TB_TRIALS=N         number of trials (default 8)

local frame = 0
local ROOT = os.getenv("MK2_TB_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("MK2_TB_LOG") or (ROOT .. "/tools/reptile_forceball_twobtn.log")
local MODE = (os.getenv("MK2_TB_MODE") or "slow"):lower()
local STRAY = (os.getenv("MK2_TB_STRAY") or "1") ~= "0"
local TRIALS = tonumber(os.getenv("MK2_TB_TRIALS") or "8") or 8

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n") logfh:flush() end
end

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
local missing = {}
local function sym(name)
    local v = symbols[name]
    if not v then missing[#missing + 1] = name return 0 end
    return v
end

local A = {
    gstate = sym("gstate"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    map_position = sym("map_position"), battle_num = sym("battle_num"),
    active = sym("active"),
    f_freeze_timer = sym("f_freeze_timer"),
}

local O = { oxvel=0x040, oxval=0x080, oxpos=0x090 }
local P = { link=0x000, procid=0x020, pa8=0x0c0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_REPTILE, FT_JAX = 9, 11
local PS_ACTIVE, PS_INACTIVE = 1, 0
local PID_ORB = { [0x0702]=true, [0x0802]=true }

local space, fields = nil, {}
local charsel_frame, fighting_frame, did_select = 0, 0, false
local p1_confirm_start = 0
local done_frame, verdict = 0, nil
local pin_x = nil
local GAP_PX = 200

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function w32(a,v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff if v >= 0x8000 then return v-0x10000 end return v end

local function cache_fields()
    local want = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
                   ["P1 High Punch"]=true, ["P1 Low Punch"]=true,
                   ["P1 Right"]=true, ["P1 Left"]=true, ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local function find_orb()
    local p, n = r32(A.active), 0
    while p ~= 0 and n < 400 do
        if PID_ORB[r16(p + P.procid)] then return true end
        p = r32(p + P.link) n = n + 1
    end
    return false
end

local function force_ladder()
    w16(A.p1_state, PS_ACTIVE)
    w16(A.p2_state, PS_INACTIVE)
    w16(A.p1_char, FT_REPTILE)
    w16(A.p2_char, FT_JAX)
    w16(A.map_position, 0)
    w16(A.battle_num, 1)
    if not did_select then
        did_select = true
        print(string.format("[tb] direct_select frame=%d p1=%d p2=%d",
            frame, r16(A.p1_char), r16(A.p2_char)))
    end
end

-- ---------------------------------------------------------- the input plan
-- Slow forceball = Left,Left + HP+LP.  Fast = Right,Right + HP+LP.
-- Each trial, relative to arm_frame:
--   dir tap 1:  [0,2)
--   gap:        [2,4)
--   dir tap 2:  [4,6)
--   gap:        [6,9)     (release back to neutral before the buttons)
--   HP:          [9,11)   closure recorded at tick 9 (leading edge)
--   stray DIR:   [10,12)  only if STRAY - closure at tick 10, the one entry
--                         that sits between HP and LP in the button queue
--   LP:          [12,14)  closure at tick 12 -> HP-to-LP elapsed = 3 ticks,
--                         inside the 4-tick (2+twobtn_slack) window
local DIR = (MODE == "fast") and "P1 Right" or "P1 Left"
local HP_AT, STRAY_AT, LP_AT = 9, 10, 12
local CYCLE = 50

local trial_no = 0
local arm_frame = 0
local results = {}
local trial_active = false
local trial_seen_orb = false
local trial_deadline = 0

local function throw_phase_flags()
    if arm_frame == 0 then return false, false, false, "idle" end
    local t = frame - arm_frame
    if t < 0 then return false, false, false, "idle" end
    t = t % CYCLE
    local dirp = (t < 2) or (t >= 4 and t < 6)
    local hp = (t >= HP_AT and t < HP_AT + 2)
    local stray = STRAY and (t >= STRAY_AT and t < STRAY_AT + 2)
    local lp = (t >= LP_AT and t < LP_AT + 2)
    local label = "idle"
    if dirp then label = "dir"
    elseif hp then label = "hp"
    elseif stray then label = "stray"
    elseif lp then label = "lp"
    elseif t < 4 or (t >= 6 and t < HP_AT) then label = "gap" end
    return dirp, hp, stray, lp, label
end
local function throw_phase()
    local _, _, _, _, label = throw_phase_flags()
    return label
end

local function pressed(name)
    if fighting_frame == 0 then
        if charsel_frame > 0 then
            if name == "P1 High Punch" and p1_confirm_start > 0 then
                return frame >= p1_confirm_start and frame < p1_confirm_start + 45
            end
            return false
        end
        if name == "UI Select" then return frame >= 5 and frame < 35 end
        if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    local dirp, hp, stray, lp = throw_phase_flags()
    if name == DIR and (dirp or stray) then return true end
    if name == "P1 High Punch" and hp then return true end
    if name == "P1 Low Punch" and lp then return true end
    return false
end

local function finish(msg, ok)
    if done_frame > 0 then return end
    done_frame = frame
    verdict = ok
    print("[tb] " .. msg)
    print("[tb] " .. (ok and "PASS" or "FAIL"))
    print("[tb] finished")
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        print(string.format("[tb] reptile_forceball_twobtn_test mode=%s stray=%s trials=%d",
            MODE, tostring(STRAY), TRIALS))
        print("[tb] log=" .. LOG_PATH)
        if #missing > 0 then print("[tb] MISSING SYMBOLS: " .. table.concat(missing, ",")) end
    end
    if frame == 2 then
        local names = {}
        for n, _ in pairs(fields) do names[#names+1] = n end
        print("[tb] cached fields: " .. table.concat(names, ","))
    end
    if done_frame > 0 then
        if frame > done_frame + 60 then manager.machine:exit() end
        return
    end
    if frame > 9000 then finish("timed out", false) return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame print("[tb] charsel frame="..frame) end
        force_ladder()
        if p1_confirm_start == 0 then p1_confirm_start = frame + 20 end
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        arm_frame = frame + 90
        print(string.format("[tb] fight_start frame=%d p1char=%d p2char=%d",
            frame, r16(A.p1_char), r16(A.p2_char)))
    end

    for name, f in pairs(fields) do
        f:set_value(pressed(name) and 1 or 0)
    end

    if fighting_frame == 0 then return end

    w16(A.f_freeze_timer, 1)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p2o ~= 0 then w16(A.p2_bar, 0x0a1) end
    if p1o ~= 0 then w16(A.p1_bar, 0x0a1) end

    if p1o ~= 0 and p2o ~= 0 and frame > fighting_frame + 30 then
        if pin_x == nil then
            pin_x = s16(r16(p2o + O.oxpos))
            print(string.format("[tb] pin p2_x=%d gap=%d", pin_x, GAP_PX))
        end
        w32(p2o + O.oxval, pin_x << 16)
        w16(p2o + O.oxpos, pin_x)
        local target = pin_x - GAP_PX
        w32(p1o + O.oxval, target << 16)
        w16(p1o + O.oxpos, target)
    end

    if arm_frame > 0 and frame >= arm_frame then
        local t = (frame - arm_frame) % CYCLE
        if t == 0 then
            if trial_active then
                trial_no = trial_no + 1
                results[trial_no] = trial_seen_orb
                print(string.format("[tb] trial #%d -> %s", trial_no, trial_seen_orb and "ORB" or "no orb"))
                if trial_no >= TRIALS then
                    local hits = 0
                    for _, v in ipairs(results) do if v then hits = hits + 1 end end
                    print(string.format("[tb] result: %d/%d forceballs came out (mode=%s stray=%s)",
                        hits, TRIALS, MODE, tostring(STRAY)))
                    finish(string.format("%d/%d", hits, TRIALS), hits == TRIALS)
                    return
                end
            end
            trial_active = true
            trial_seen_orb = false
        end
        if trial_active and find_orb() then trial_seen_orb = true end
        if trial_no == 0 and trial_active then
            local p1p = r32(sym("p1_proc"))
            print(string.format("[tb] t=%d ph=%s p1act=%04x", t, throw_phase(),
                p1p ~= 0 and r16(p1p + 0x1f0) or 0xffff))
        end
    end
end)
