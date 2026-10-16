-- reptile_uninviso_test.lua
--
-- Reptile's invisibility: what is he STANDING IN when he comes back?
--
-- do_un_inviso (MOVES.ASM) poses a frame and then clears b_inviso.  The
-- leaked snapshot fetched that frame from TABLE2 row 0 - a_slide - so the
-- pose it landed on was NJSLIDE2 and Reptile reappeared crouched in a slide,
-- in place.  The fix reads row 7 (a_inviso) and plays its two frames
-- BACKWARDS: NJINVISO2, then NJINVISO1.
--
-- The rig does not look at pixels.  ani2 writes the frame-header-list
-- pointer into oshape, and rp_anitab2 is a global, so the exact identity of
-- the pose is readable:
--
--   rp_anitab2[0] -> a_slide   -> {NJSLIDE1, NJSLIDE2, NJSLIDE3}
--   rp_anitab2[7] -> a_inviso  -> {NJINVISO1, NJINVISO2}
--
-- PASS = on the frame b_inviso goes 1->0 he is on NJINVISO2, NJINVISO1
-- follows, and no NJSLIDE* is posed anywhere in the move.
--
-- MK2_UI_LOG / MK2_UI_ROOT / MK2_UI_SNAP

local frame = 0
local ROOT = os.getenv("MK2_UI_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("MK2_UI_LOG") or (ROOT .. "/tools/reptile_uninviso.log")
local SNAP_ON = os.getenv("MK2_UI_SNAP") ~= "0"

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n") logfh:flush() end
end

-- ---------------------------------------------------------------- symbols
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
    p1_proc = sym("p1_proc"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    map_position = sym("map_position"), battle_num = sym("battle_num"),
    tick = sym("tick"), f_freeze_timer = sym("f_freeze_timer"),
    rp_anitab2 = sym("rp_anitab2"),
}

local O = { oxval=0x080, oxpos=0x090, oypos=0x0b0, oflags=0x0f0,
            oflags2=0x160, oshape=0x1d0, oimg=0x1a0, ochar=0x1f0 }
local P = { link=0x000, procid=0x020, pa8=0x0c0, action=0x1f0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_REPTILE, FT_JAX = 9, 11
local PS_ACTIVE, PS_INACTIVE = 1, 0
local M_INVISO = 0x0020                 -- DISPEQU b_inviso = 5

local space, fields = nil, {}
local charsel_frame, fighting_frame, did_select = 0, 0, false
local p1_confirm_start = 0
local done_frame, verdict = 0, nil
local pin_x = nil

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function w32(a,v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff if v >= 0x8000 then return v-0x10000 end return v end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end
local snaps = 0
local function snap()
    if not SNAP_ON or snaps >= 20 then return end
    local s = main_screen()
    if s then snaps = snaps + 1 pcall(function() s:snapshot() end) end
end

local function cache_fields()
    local want = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
                   ["P1 High Punch"]=true, ["P1 Up"]=true, ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

-- ------------------------------------------------------- pose vocabulary
-- Built once, from the live tables, so a table edit can never desync it.
local POSE = {}
local function build_poses()
    local function row(n) return r32(A.rp_anitab2 + n*32) end
    local a_slide, a_inviso = row(0), row(7)
    local names = {
        { a_slide,  { "NJSLIDE1", "NJSLIDE2", "NJSLIDE3" } },
        { a_inviso, { "NJINVISO1", "NJINVISO2" } },
    }
    for _, e in ipairs(names) do
        local base, list = e[1], e[2]
        for i, nm in ipairs(list) do
            local p = r32(base + (i-1)*32)
            if p ~= 0 then POSE[p] = nm end
        end
    end
    print(string.format("[ui] a_slide=%08x a_inviso=%08x", a_slide, a_inviso))
    for p, nm in pairs(POSE) do print(string.format("[ui]   %-10s = %08x", nm, p)) end
end
local function pose_name(v)
    if v == 0 then return "-" end
    return POSE[v] or string.format("other:%08x", v)
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
        print(string.format("[ui] direct_select frame=%d", frame))
    end
end

-- ------------------------------------------------------------ input plan
-- scom_inviso is Up, Up, Down inside 56 ticks, then HP - and restricted_xfer
-- refuses an airborne caller, so the first Up's jump has to be over before
-- the punch.  The rig taps the three directions as tight as the queue will
-- take them and then PULSES HP for the rest of the window, so one press
-- lands on the first grounded frame instead of guessing which one that is.
local CYCLE = 150
local arm_frame = 0
local UP1, UP2, DN = 0, 4, 8
local TAP = 2
local HP_FROM, HP_TO = 12, 54

local function phase()
    if arm_frame == 0 or frame < arm_frame then return "idle" end
    local t = (frame - arm_frame) % CYCLE
    if t >= UP1 and t < UP1+TAP then return "up" end
    if t >= UP2 and t < UP2+TAP then return "up" end
    if t >= DN  and t < DN +TAP then return "down" end
    if t >= HP_FROM and t < HP_TO then
        if ((t - HP_FROM) % 4) < 2 then return "hp" end
    end
    return "idle"
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
    local ph = phase()
    if name == "P1 Up" then return ph == "up" end
    if name == "P1 Down" then return ph == "down" end
    if name == "P1 High Punch" then return ph == "hp" end
    return false
end

-- ------------------------------------------------------------- the record
local last_pose, last_inviso = nil, nil
local vanish_frame, reappear_frame = 0, 0
local pose_at_reappear = nil
local after_reappear = {}      -- poses seen in the 20 ticks after he is back
local slide_seen = {}
local trace = {}

local function finish(msg, ok)
    if done_frame > 0 then return end
    done_frame = frame
    verdict = ok
    print("[ui] " .. msg)
    print("[ui] " .. (ok and "PASS" or "FAIL"))
    print("[ui] finished")
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        print("[ui] reptile_uninviso_test")
        print("[ui] log=" .. LOG_PATH)
        if #missing > 0 then print("[ui] MISSING SYMBOLS: " .. table.concat(missing, ",")) end
    end
    if done_frame > 0 then
        if frame > done_frame + 60 then manager.machine:exit() end
        return
    end
    if frame > 9000 then
        finish(string.format("timed out (vanish=%d reappear=%d)", vanish_frame, reappear_frame), false)
        return
    end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame print("[ui] charsel frame="..frame) end
        force_ladder()
        if p1_confirm_start == 0 then p1_confirm_start = frame + 20 end
    elseif gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        arm_frame = frame + 90
        build_poses()
        print(string.format("[ui] fight_start frame=%d p1char=%d p2char=%d",
            frame, r16(A.p1_char), r16(A.p2_char)))
    end

    for name, f in pairs(fields) do
        f:set_value(pressed(name) and 1 or 0)
    end

    if fighting_frame == 0 then return end

    w16(A.f_freeze_timer, 1)
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 then return end
    if p2o ~= 0 then w16(A.p2_bar, 0x0a1) end
    w16(A.p1_bar, 0x0a1)

    -- Keep the drone off him: a reaction mid-move would end the lane early
    -- and the pose being read would be r_* and not do_un_inviso's.
    if p2o ~= 0 and frame > fighting_frame + 30 then
        if pin_x == nil then
            pin_x = s16(r16(p2o + O.oxpos))
            print(string.format("[ui] pin p2_x=%d", pin_x))
        end
        w32(p2o + O.oxval, pin_x << 16)
        w16(p2o + O.oxpos, pin_x)
    end

    local shape = r32(p1o + O.oshape)
    local inviso = (r16(p1o + O.oflags2) & M_INVISO) ~= 0

    if last_pose ~= shape then
        local nm = pose_name(shape)
        if #trace < 400 then
            trace[#trace+1] = string.format("f=%d pose=%s inviso=%s", frame, nm, tostring(inviso))
        end
        if nm:find("^NJSLIDE") and vanish_frame > 0 then
            slide_seen[#slide_seen+1] = string.format("f=%d %s", frame, nm)
            print(string.format("[ui] !! %s posed at frame %d (inviso=%s)", nm, frame, tostring(inviso)))
        end
        last_pose = shape
    end

    if last_inviso == nil then last_inviso = inviso end
    if inviso and not last_inviso then
        vanish_frame = frame
        print(string.format("[ui] VANISH frame=%d pose=%s", frame, pose_name(shape)))
        snap()
    elseif (not inviso) and last_inviso and vanish_frame > 0 then
        reappear_frame = frame
        pose_at_reappear = pose_name(shape)
        print(string.format("[ui] REAPPEAR frame=%d pose=%s", frame, pose_at_reappear))
        snap()
    end
    last_inviso = inviso

    if reappear_frame > 0 and frame > reappear_frame and frame <= reappear_frame + 20 then
        local nm = pose_name(shape)
        if after_reappear[#after_reappear] ~= nm then
            after_reappear[#after_reappear+1] = nm
            if nm == "NJINVISO1" then snap() end
        end
    end

    if frame % 120 == 0 and reappear_frame == 0 then
        local p1p = r32(A.p1_proc)
        print(string.format("[hb] f=%d pose=%s inviso=%s act=%04x ph=%s",
            frame, pose_name(shape), tostring(inviso),
            p1p ~= 0 and r16(p1p + P.action) or 0xffff, phase()))
    end

    if reappear_frame > 0 and frame > reappear_frame + 25 then
        print("[ui] --- pose trace ---")
        for _, l in ipairs(trace) do print("[ui]   " .. l) end
        print("[ui] pose at reappear      = " .. tostring(pose_at_reappear))
        print("[ui] poses after reappear  = " .. table.concat(after_reappear, " -> "))
        print("[ui] slide poses in move   = " .. (#slide_seen == 0 and "none" or table.concat(slide_seen, ", ")))
        local saw_inviso1 = false
        for _, nm in ipairs(after_reappear) do if nm == "NJINVISO1" then saw_inviso1 = true end end
        local ok = (pose_at_reappear == "NJINVISO2") and saw_inviso1 and (#slide_seen == 0)
        finish(string.format("reappear pose=%s, follow-up NJINVISO1=%s, slide poses=%d",
            tostring(pose_at_reappear), tostring(saw_inviso1), #slide_seen), ok)
    end
end)
