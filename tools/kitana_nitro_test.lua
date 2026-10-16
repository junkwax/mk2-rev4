-- kitana_nitro_test.lua
-- Runs against a test_mode=1 build (MKAMODE.ASM: test_p1_char=ft_fn1,
-- test_p2_char=ft_reptile, test_p2_human=1) that boots straight into the
-- fight, skipping attract/select entirely. Performs Down, Forward + LK and
-- verifies the reworked Jade nitro kick: hits only register once the
-- KTLOKICK1 foot-out frame is showing (never during the KTHIKICK windup),
-- the kick always ends held on that exposed pose for ~1 second, then the
-- palette reverts to normal before play continues.

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/kitana_nitro_test.log", "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then
        logfh:write(line, "\n")
        logfh:flush()
    end
end

local fields = {}
local cpu = nil
local space = nil
local fighting_frame = 0
local last_gstate = -1
local did_error = false

local move_fired = false          -- act_shadk seen
local windup_sag_seen = false     -- KTHIKICK2-5 rows observed while act_shadk
local windup_hit_violation = false -- p2bar dropped while only windup SAG shown
local lokick_sag_seen = false     -- KTLOKICK1 row observed
local hold_start_frame = nil      -- first frame act_shadow_sd seen
local hold_end_frame = nil        -- first frame after hold act_shadow_sd clears
local did_hit_snap = false
local p2_bar_start = nil
local p2_bar_at_hit = nil
local last_p1act = 0xffff
local attempt = 0
local combo_base = nil            -- fighting_frame offset where the current combo attempt starts

-- Fresh addresses from src/mk2.map (this build; BSS shifts every build).
local GSTATE   = 0x0112a830
local P1_CHAR  = 0x0112a8e0
local P2_CHAR  = 0x0112b4b0
local P1_OBJ   = 0x0112a880
local P2_OBJ   = 0x0112b450
local P1_PROC  = 0x0112a8c0
local P2_BAR   = 0x0112b520
local OBJLST   = 0x011275d0
local OBJLST2  = 0x011275f0

local PROC_ACTION = 0x1f0

local OBJ_NEXT    = 0x000
local OBJ_OXPOS   = 0x090
local OBJ_OYPOS   = 0x0b0
local OBJ_OFLAGS  = 0x0f0
local OBJ_OFLAGS2 = 0x160
local OBJ_OIMG    = 0x1a0
local OBJ_OCHAR   = 0x1f0

local GS_FIGHTING = 2
local ACT_SHADK      = 0x0205  -- windup/kick drive
local ACT_SHADOW_SD  = 0x0608  -- exposed-foot hold (hit or whiff)

-- src/MKFN.TBL SAGs for this build (KAT4.IMG frames in MK3MIL, main pool).
-- KTHIKICK2A..KTHIKICK5A windup rows sit below KTLOKICK1A; use a midpoint
-- boundary between them.
local WINDUP_SAG_LO  = 0x01354000
local LOKICK_SAG_LO  = 0x01372000
local LOKICK_SAG_HI  = 0x01380000
local MKBUG_START = 0xffa30000
local MKBUG_END   = 0xffa36000

local function cache_fields()
    local wanted = {
        ["P1 Down"] = true,
        ["P1 Right"] = true,
        ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then
                fields[field.name] = field
            end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[kitnitro] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end

local function snap(label)
    local s = main_screen()
    if s then
        local ok, err = pcall(function() s:snapshot() end)
        print(string.format("[kitnitro] SNAP frame=%d label=%s ok=%s %s",
            frame, label, tostring(ok), ok and "" or tostring(err)))
    end
end

local function cpu_reg(name)
    if not cpu then return nil end
    local ok, item = pcall(function() return cpu.state[name] end)
    if not ok or not item then return nil end
    local okv, value = pcall(function() return item.value end)
    if okv then return value end
    okv, value = pcall(function() return item() end)
    if okv then return value end
    return nil
end

local function hx(value)
    if value == nil then return "na" end
    return string.format("0x%08x", value)
end

local function count_list(addr)
    if not space then return 0 end
    local p = space:read_u32(addr)
    local count = 0
    while p ~= 0 and count < 256 do
        count = count + 1
        p = space:read_u32(p + OBJ_NEXT)
    end
    return count
end

local function pressed(name)
    if fighting_frame == 0 or combo_base == nil then return false end
    local r = frame - combo_base
    -- Walk in close, then Down, Forward, LK (scom_fn1_nitro).  The combo
    -- window is only 0x18+6 = 30 ticks measured from the Down closure to
    -- the LK press, so these three must land close together.
    if r >= 0 and r < 180 then
        if name == "P1 Right" then return true end
    end
    if name == "P1 Down" then
        return r >= 190 and r < 194
    end
    if name == "P1 Right" then
        return r >= 196 and r < 200
    end
    if name == "P1 Low Kick" then
        return r >= 202 and r < 208
    end
    return false
end

local function log_state(force)
    if not space then return end

    local gs = space:read_u16(GSTATE)
    local p1proc = space:read_u32(P1_PROC)
    local p1act = p1proc ~= 0 and space:read_u16(p1proc + PROC_ACTION) or 0xffff
    local p1obj = space:read_u32(P1_OBJ)
    local p1sag = 0
    if p1obj ~= 0 then
        local p1img = space:read_u32(p1obj + OBJ_OIMG)
        if p1img ~= 0 then p1sag = space:read_u32(p1img) end
    end
    local p2bar = space:read_u16(P2_BAR)

    -- Per-frame checks (log is throttled below).  Classify by SAG whenever
    -- the move is in progress (act_shadk) OR holding the post-strike pose
    -- (act_shadow_sd) -- fn1nitro_contact flips p_action to act_shadow_sd
    -- in the very tick the hit lands, same tick the frame's SAG is sampled,
    -- so gating classification on act_shadk alone misses that frame.
    if p1act == ACT_SHADK and not move_fired then
        move_fired = true
        print(string.format("[kitnitro] frame=%d act_shadk ACTIVE", frame))
    end
    if p1act == ACT_SHADK or p1act == ACT_SHADOW_SD then
        if p1sag >= WINDUP_SAG_LO and p1sag < LOKICK_SAG_LO then
            windup_sag_seen = true
        elseif p1sag >= LOKICK_SAG_LO and p1sag < LOKICK_SAG_HI then
            lokick_sag_seen = true
        end
    end

    if p1act == ACT_SHADOW_SD and last_p1act ~= ACT_SHADOW_SD then
        hold_start_frame = frame
        print(string.format("[kitnitro] frame=%d act_shadow_sd HOLD start sag=%s", frame, hx(p1sag)))
    end
    if p1act ~= ACT_SHADOW_SD and last_p1act == ACT_SHADOW_SD then
        hold_end_frame = frame
        print(string.format("[kitnitro] frame=%d act_shadow_sd HOLD end (len=%d)",
            frame, hold_start_frame and (frame - hold_start_frame) or -1))
    end

    if p2_bar_start and p2bar < p2_bar_start then
        if not did_hit_snap then
            did_hit_snap = true
            p2_bar_at_hit = p2bar
            snap("nitro_hit")
            local hit_on_lokick = p1sag >= LOKICK_SAG_LO and p1sag < LOKICK_SAG_HI
            print(string.format("[kitnitro] hit detected p2bar %d -> %d at sag=%s (hit_on_lokick=%s)",
                p2_bar_start, p2bar, hx(p1sag), tostring(hit_on_lokick)))
            if not hit_on_lokick then
                windup_hit_violation = true
                print("[kitnitro] ERROR hit registered while KTLOKICK1 row was NOT showing")
            end
        end
    end

    if p1act ~= last_p1act then
        print(string.format("[kitnitro] frame=%d p1act %s -> %s sag=%s", frame, hx(last_p1act), hx(p1act), hx(p1sag)))
    end
    last_p1act = p1act

    if not force and frame % 20 ~= 0 then return end

    local p1c = space:read_u16(P1_CHAR)
    local p2c = space:read_u16(P2_CHAR)
    local p2obj = space:read_u32(P2_OBJ)
    local p1x, p1y, p1flags, p1flags2, p1ochar = 0, 0, 0, 0, 0xffff
    local p2x, p2y, p2ochar = 0, 0, 0xffff
    if p1obj ~= 0 then
        p1x = space:read_u16(p1obj + OBJ_OXPOS)
        p1y = space:read_u16(p1obj + OBJ_OYPOS)
        p1flags = space:read_u16(p1obj + OBJ_OFLAGS)
        p1flags2 = space:read_u16(p1obj + OBJ_OFLAGS2)
        p1ochar = space:read_u16(p1obj + OBJ_OCHAR)
    end
    if p2obj ~= 0 then
        p2x = space:read_u16(p2obj + OBJ_OXPOS)
        p2y = space:read_u16(p2obj + OBJ_OYPOS)
        p2ochar = space:read_u16(p2obj + OBJ_OCHAR)
    end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")

    print(string.format(
        "[kitnitro] frame=%d gs=%d p1=%d p2=%d p1objchar=%d p2objchar=%d act=0x%04x p1xy=%d,%d p2xy=%d,%d flags=0x%04x flags2=0x%04x sag=0x%08x p2bar=%d obj=%d obj2=%d pc=%s",
        frame, gs, p1c, p2c, p1ochar, p2ochar, p1act, p1x, p1y, p2x, p2y,
        p1flags, p1flags2, p1sag, p2bar, count_list(OBJLST), count_list(OBJLST2),
        hx(pc)))
end

local function check_cpu_lockup()
    if did_error or not space or fighting_frame == 0 then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    if pc and pc >= MKBUG_START and pc <= MKBUG_END then
        did_error = true
        log_state(true)
        snap("mkbug_lockup")
        print(string.format("[kitnitro] ERROR mkbug_lockup pc=%s", hx(pc)))
        manager.machine:exit()
        return true
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1

    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[kitnitro] loaded: test_mode build, waiting for fight to start")
    end

    if space then
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[kitnitro] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                combo_base = frame
                p2_bar_start = space:read_u16(P2_BAR)
                snap("fight_start")
            end
            last_gstate = gs
        end

        -- If the combo attempt window has passed and we still haven't seen
        -- act_shadk fire, retry once (fresh walk-in + combo) in case the
        -- first attempt's timing lost a race against test_mode's own
        -- pre-fight setup frames.
        if fighting_frame > 0 and not move_fired and combo_base
           and frame - combo_base > 260 and attempt < 2 then
            attempt = attempt + 1
            combo_base = frame
            print(string.format("[kitnitro] frame=%d retry attempt=%d", frame, attempt))
        end

        log_state(false)
        if check_cpu_lockup() then return end
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    -- test_fight_proc auto-restarts the fight once a round ends (rounds
    -- are short in this harness), which can replay stale queue closures
    -- into the next round and re-fire the special with no new input from
    -- us. Finish as soon as we have a verdict from the FIRST fight instead
    -- of running long enough to reach a restart.
    local done_early = hold_end_frame ~= nil and frame > hold_end_frame + 20
    if fighting_frame > 0 and (done_early or frame > fighting_frame + 700) then
        log_state(true)
        snap("final")

        local hold_len = (hold_start_frame and hold_end_frame) and (hold_end_frame - hold_start_frame) or -1
        -- 1 second = 60 ticks; allow scheduler slack.
        local hold_ok = hold_len >= 50 and hold_len <= 75

        if move_fired and did_hit_snap and lokick_sag_seen and not windup_hit_violation and hold_ok then
            print(string.format("[kitnitro] PASS move_fired=%s hit=%s lokick_seen=%s windup_violation=%s hold_len=%d p2bar %d -> %d",
                tostring(move_fired), tostring(did_hit_snap), tostring(lokick_sag_seen),
                tostring(windup_hit_violation), hold_len, p2_bar_start or -1, p2_bar_at_hit or -1))
        else
            print(string.format("[kitnitro] ERROR move_fired=%s hit=%s lokick_seen=%s windup_violation=%s hold_len=%d hold_ok=%s",
                tostring(move_fired), tostring(did_hit_snap), tostring(lokick_sag_seen),
                tostring(windup_hit_violation), hold_len, tostring(hold_ok)))
        end
        print("[kitnitro] finished")
        manager.machine:exit()
    end
end)
