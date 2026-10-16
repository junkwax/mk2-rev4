-- oldshang_raiden_alt_regression_test.lua
--
-- MAME Lua regression harness for the recent Shang/Old Shang and Raiden alt
-- palette changes.
--
-- Usage from repo root:
--   .\mame.exe mk2 -autoboot_script tools\oldshang_raiden_alt_regression_test.lua
--
-- Optional cases:
--   set MK2_TEST_CASE=oldshang
--   set MK2_TEST_CASE=raiden_alt
--
-- The default case is oldshang. Logs are written beside this script.

local TEST_CASE = os.getenv("MK2_TEST_CASE") or "oldshang"
local frame = 0
local log_case = TEST_CASE:gsub("[^%w_%-]", "_")
local log_path = "C:/Users/you/Workplace/mk2-main/tools/oldshang_raiden_alt_regression_test_" .. log_case .. ".log"
local logfh = io.open(log_path, "w")
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
local charsel_frame = 0
local vs_frame = 0
local fighting_frame = 0
local fight_count = 0
local p1_confirm_start = 0
local last_gstate = -1
local did_direct_select = false
local did_select_log = false
local did_error = false
local finished = false

local old_active_frame = 0
local old_clear_frame = 0
local old_active_logged = false
local aged_morph_timer = false
local x_forward_start = nil
local x_forward_end = nil
local x_back_start = nil
local x_back_end = nil
local last_oldskull_count = 0
local oldskull_spawn_frames = {}
local oldskull_spawns_after_clear = 0
local stale_zero_logged = false

local raiden_alt_logged = false

local ACTIVE   = 0x010dc6d0
local GSTATE   = 0x01129d90
local P1_CHAR  = 0x01129e40
local P2_CHAR  = 0x0112aa10
local P1_OBJ   = 0x01129de0
local P2_OBJ   = 0x0112a9b0
local P1_PROC  = 0x01129e20
local P2_PROC  = 0x0112a9f0
local PF_RAM   = 0x0112b660
local OBJLST   = 0x01127030
local OBJLST2  = 0x01127050
local OBJLST3  = 0x01127070
local OFREE    = 0x01129cf0
local TICK     = 0x01126c40
local L_MORPH  = 0x0112b990
local ALT_PAL_OWNER = 0x0112bcd0

local PROC_NEXT   = 0x000
local PROC_ID     = 0x020
local PROC_TIME   = 0x030
local PROC_STACK  = 0x040
local PROC_WAKE   = 0x0e0
local PROC_PA8    = 0x0c0
local PROC_SLAVE  = 0x190
local PROC_ACTION = 0x1f0
local PROC_FLAGS  = 0x210
local PROC_STORE2 = 0x250
local PROC_STORE4 = 0x290

local OBJ_NEXT    = 0x000
local OBJ_OSLINK  = 0x020
local OBJ_OXVEL   = 0x040
local OBJ_OYVEL   = 0x060
local OBJ_OXPOS   = 0x090
local OBJ_OYPOS   = 0x0b0
local OBJ_OSAG    = 0x100
local OBJ_OPAL    = 0x140
local OBJ_OFLAGS2 = 0x160
local OBJ_OIMG    = 0x1a0
local OBJ_OCHAR   = 0x1f0

local GS_PSEL     = 4
local GS_POST     = 0x0d
local GS_FIGHTING = 2
local FT_SHANG    = 6
local FT_RAIDEN   = 7
local FT_JAX      = 11
local PID_PROJ1   = 0x0700
local PID_P1      = 0x0001
local PM_JOY      = 0x0001
local PM_OLDSHANG = 0x0200
local RAIDEN_ALT_OWNER_P1 = 0x0004
local MKBUG_START = 0xffa30000
local MKBUG_END   = 0xffa3ffff

local function hx(value)
    if value == nil then return "na" end
    return string.format("0x%08x", value & 0xffffffff)
end

local function s16(value)
    value = value & 0xffff
    if value >= 0x8000 then return value - 0x10000 end
    return value
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
        print(string.format("[mk2reg] SNAP frame=%d label=%s ok=%s %s",
            frame, label, tostring(ok), ok and "" or tostring(err)))
    end
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 Left"] = true,
        ["P1 Right"] = true,
        ["P1 Down"] = true,
        ["P1 High Punch"] = true,
        ["P1 High Kick"] = true,
        ["P1 High Kick 2"] = true,
        ["P1 Low Kick"] = true,
        ["P1 Block"] = true,
        ["P1 Block 2"] = true,
        ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then
                fields[field.name] = field
            end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[mk2reg] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function obj_in_list(head_addr, target)
    if not space or target == 0 then return false end
    local p = space:read_u32(head_addr)
    local guard = 0
    while p ~= 0 and guard < 256 do
        if p == target then return true end
        p = space:read_u32(p + OBJ_NEXT)
        guard = guard + 1
    end
    return false
end

local function proc_is_projectile(pid)
    return pid == PID_PROJ1 or (pid & 0xff00) == PID_PROJ1
end

local function p1_forward_field()
    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    if p1obj == 0 or p2obj == 0 then return "P1 Right" end
    local p1x = space:read_u16(p1obj + OBJ_OXPOS)
    local p2x = space:read_u16(p2obj + OBJ_OXPOS)
    if p1x <= p2x then return "P1 Right" end
    return "P1 Left"
end

local function p1_back_field()
    if p1_forward_field() == "P1 Right" then return "P1 Left" end
    return "P1 Right"
end

local function dump_proc_list(tag)
    if not space then return end
    print(string.format("[mk2reg] proc_list tag=%s", tag))
    local p = space:read_u32(ACTIVE)
    local guard = 0
    while p ~= 0 and guard < 48 do
        local pid = space:read_u16(p + PROC_ID)
        local ptime = space:read_u16(p + PROC_TIME)
        local psptr = space:read_u32(p + PROC_STACK)
        local pwake = space:read_u32(p + PROC_WAKE)
        local action = space:read_u16(p + PROC_ACTION)
        local flags = space:read_u16(p + PROC_FLAGS)
        local pa8 = space:read_u32(p + PROC_PA8)
        print(string.format(
            "[mk2reg] proc[%02d] p=%s pid=%04x time=%04x sp=%s wake=%s action=%04x flags=%04x pa8=%s",
            guard, hx(p), pid, ptime, hx(psptr), hx(pwake), action, flags, hx(pa8)))
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
end

local function oldskull_count_and_dump(tag, force)
    if not space then return 0 end
    local count = 0
    local p = space:read_u32(ACTIVE)
    local guard = 0
    while p ~= 0 and guard < 256 do
        local pid = space:read_u16(p + PROC_ID)
        local flags = space:read_u16(p + PROC_FLAGS)
        if proc_is_projectile(pid) and (flags & PM_OLDSHANG) ~= 0 then
            count = count + 1
            if force then
                local obj = space:read_u32(p + PROC_PA8)
                local owner = space:read_u32(p + PROC_STORE2)
                local stamp = space:read_u16(p + PROC_STORE4)
                local obj_live = obj_in_list(OBJLST, obj) or obj_in_list(OBJLST2, obj) or obj_in_list(OBJLST3, obj)
                local img = (obj ~= 0 and obj_live) and space:read_u32(obj + OBJ_OIMG) or 0
                local sag = img ~= 0 and space:read_u32(img) or 0
                print(string.format(
                    "[mk2reg] oldskull tag=%s proc=%s pid=%04x flags=%04x obj=%s live=%s owner=%s stamp=%04x sag=%s",
                    tag, hx(p), pid, flags, hx(obj), tostring(obj_live), hx(owner), stamp, hx(sag)))
            end
        end
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
    return count
end

local function dead_zero_process()
    if not space then return 0 end
    local p = space:read_u32(ACTIVE)
    local guard = 0
    while p ~= 0 and guard < 256 do
        local pid = space:read_u16(p + PROC_ID)
        local psptr = space:read_u32(p + PROC_STACK)
        local pwake = space:read_u32(p + PROC_WAKE)
        if pid == 0 and psptr == 0 and pwake == 0 then return p end
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
    return 0
end

local function log_state(tag)
    if not space then return end
    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    local p1proc = space:read_u32(P1_PROC)
    local p2proc = space:read_u32(P2_PROC)
    local p1flags = p1proc ~= 0 and space:read_u16(p1proc + PROC_FLAGS) or 0
    local p1action = p1proc ~= 0 and space:read_u16(p1proc + PROC_ACTION) or 0
    local p1slave = p1proc ~= 0 and space:read_u32(p1proc + PROC_SLAVE) or 0
    local p1x = p1obj ~= 0 and space:read_u16(p1obj + OBJ_OXPOS) or 0
    local p1y = p1obj ~= 0 and space:read_u16(p1obj + OBJ_OYPOS) or 0
    local p1char = p1obj ~= 0 and space:read_u16(p1obj + OBJ_OCHAR) or 0
    local p1pal = p1obj ~= 0 and space:read_u16(p1obj + OBJ_OPAL) or 0
    local p1of2 = p1obj ~= 0 and space:read_u16(p1obj + OBJ_OFLAGS2) or 0
    local p2x = p2obj ~= 0 and space:read_u16(p2obj + OBJ_OXPOS) or 0
    local p2y = p2obj ~= 0 and space:read_u16(p2obj + OBJ_OYPOS) or 0
    print(string.format(
        "[mk2reg] state tag=%s frame=%d gs=%d p1c=%d p2c=%d p1obj=%s p1proc=%s p2proc=%s p1xy=(%d,%d) p2xy=(%d,%d) ochar=%d flags=%04x joy=%s old=%s action=%04x slave=%s opal=%04x of2=%04x alt_owner=%04x skulls=%d pc=%s",
        tag, frame, space:read_u16(GSTATE), space:read_u16(P1_CHAR), space:read_u16(P2_CHAR),
        hx(p1obj), hx(p1proc), hx(p2proc), p1x, p1y, p2x, p2y, p1char, p1flags,
        tostring((p1flags & PM_JOY) ~= 0), tostring((p1flags & PM_OLDSHANG) ~= 0),
        p1action, hx(p1slave), p1pal, p1of2, space:read_u16(ALT_PAL_OWNER),
        oldskull_count_and_dump(tag, false), hx(cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC"))))
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log_state("finish_" .. reason)
    oldskull_count_and_dump("finish_" .. reason, true)

    if TEST_CASE == "oldshang" then
        local fwd = x_forward_start and x_forward_end and math.abs(s16(x_forward_end - x_forward_start)) or 0
        local back = x_back_start and x_back_end and math.abs(s16(x_back_end - x_back_start)) or 0
        local min_gap = nil
        for i = 2, #oldskull_spawn_frames do
            local gap = oldskull_spawn_frames[i] - oldskull_spawn_frames[i - 1]
            if not min_gap or gap < min_gap then min_gap = gap end
        end
        print(string.format("[mk2reg] result oldshang ok=%s reason=%s fwd_delta=%d back_delta=%d old_clear_frame=%d skull_spawns=%d skull_min_gap=%s oldskulls_after_clear=%d",
            tostring(ok), reason, fwd, back, old_clear_frame, #oldskull_spawn_frames, tostring(min_gap or "na"), oldskull_spawns_after_clear))
        print(string.format("[mk2reg] check movement_after_morph=%s", tostring(fwd >= 8 or back >= 8)))
        print(string.format("[mk2reg] check unmorph_cleared_old_flag=%s", tostring(old_clear_frame ~= 0)))
        print(string.format("[mk2reg] check stale_oldskulls_after_unmorph=%s", tostring(oldskull_count_and_dump("post_finish", false) == 0)))
        print(string.format("[mk2reg] check normal_skull_after_unmorph_not_old=%s", tostring(oldskull_spawns_after_clear == 0)))
        if min_gap then
            print(string.format("[mk2reg] check skull_spawn_gap_at_least_18=%s", tostring(min_gap >= 18)))
        else
            print("[mk2reg] check skull_spawn_gap_at_least_18=NO_SKULLS_SEEN")
        end
    else
        local alt = space and ((space:read_u16(ALT_PAL_OWNER) & RAIDEN_ALT_OWNER_P1) ~= 0) or false
        print(string.format("[mk2reg] result raiden_alt ok=%s reason=%s alt_owner=%04x has_p1_start_hp=%s",
            tostring(ok), reason, space and space:read_u16(ALT_PAL_OWNER) or 0, tostring(alt)))
    end

    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function check_lockup()
    if did_error or not space then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local pf = space:read_u32(PF_RAM)
    if pc and pc >= MKBUG_START and pc <= MKBUG_END then
        did_error = true
        print(string.format("[mk2reg] ERROR system_lockup pc=%s pf=%s", hx(pc), hx(pf)))
        dump_proc_list("lockup")
        snap("system_lockup")
        finish(false, "system_lockup")
        return true
    end
    if pf == 0xffffffff then
        did_error = true
        print(string.format("[mk2reg] ERROR pf_ram_all_ones pc=%s", hx(pc)))
        dump_proc_list("pf_ram_all_ones")
        finish(false, "pf_ram_all_ones")
        return true
    end

    local dead = dead_zero_process()
    if dead ~= 0 and not stale_zero_logged then
        stale_zero_logged = true
        print(string.format("[mk2reg] WARN dead_zero_process_linked frame=%d proc=%s", frame, hx(dead)))
        dump_proc_list("dead_zero_process")
    end
    return false
end

local function direct_select_for_case()
    if not space or charsel_frame == 0 then return end
    local target = TEST_CASE == "raiden_alt" and FT_RAIDEN or FT_SHANG
    space:write_u16(P1_CHAR, target)
    space:write_u16(P2_CHAR, FT_JAX)
    if not did_direct_select then
        did_direct_select = true
        print(string.format("[mk2reg] direct_select case=%s frame=%d p1=%d p2=%d",
            TEST_CASE, frame, space:read_u16(P1_CHAR), space:read_u16(P2_CHAR)))
    end
end

local function direction_sequence_input(name, rel, seq)
    local forward = p1_forward_field()
    local back = p1_back_field()
    for i, step in ipairs(seq) do
        local start = (i - 1) * 12
        if rel >= start and rel < start + 6 then
            if step == "forward" and name == forward then return true end
            if step == "back" and name == back then return true end
        end
    end
    local hp_start = #seq * 12 + 2
    if rel >= hp_start and rel < hp_start + 28 then
        return name == "P1 High Punch"
    end
    return false
end

local function oldshang_pressed(name)
    if fighting_frame == 0 or fight_count ~= 1 then return false end
    local r = frame - fighting_frame

    if old_clear_frame ~= 0 then
        local relc = frame - old_clear_frame
        -- After morph-back, fire normal Shang's one-skull input. This should not
        -- create an Old Shang upward-skull proc.
        if relc >= 95 and relc < 160 then
            return direction_sequence_input(name, relc - 95, { "back", "back" })
        end
        return false
    end

    if old_active_frame == 0 then
        if name == "P1 Block" or name == "P1 Block 2" then return r >= 140 and r < 180 end
        if name == "P1 High Kick" or name == "P1 High Kick 2" then return r >= 162 and r < 176 end
        return false
    end

    local rel = frame - old_active_frame
    if rel >= 0 and rel < 115 and (name == "P1 Block" or name == "P1 Block 2") then return true end
    if rel >= 45 and rel < 145 and name == p1_forward_field() then return true end
    if rel >= 180 and rel < 280 and name == p1_back_field() then return true end

    -- Try the 3-skull pattern first while the normal morph timer is still active.
    if rel >= 315 and rel < 405 then
        return direction_sequence_input(name, rel - 315, { "forward", "forward", "back", "back" })
    end
    if rel >= 430 and rel < 505 then
        return direction_sequence_input(name, rel - 430, { "forward", "back", "back" })
    end
    if rel >= 515 and rel < 575 then
        return direction_sequence_input(name, rel - 515, { "back", "back" })
    end

    return false
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then
        if TEST_CASE == "raiden_alt" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 55
        end
        return frame >= 1000 and frame < 1080
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 45
        end
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 305
        end
    end

    if TEST_CASE == "oldshang" then
        return oldshang_pressed(name)
    end

    return false
end

local function monitor_raiden_alt()
    if not space then return end
    local alt_owner = space:read_u16(ALT_PAL_OWNER)
    local has_alt = (alt_owner & RAIDEN_ALT_OWNER_P1) ~= 0
    if has_alt and not raiden_alt_logged then
        raiden_alt_logged = true
        log_state("raiden_alt_owner_set")
        snap("raiden_alt_owner_set")
    end
    if fight_count == 1 and fighting_frame > 0 and frame - fighting_frame > 90 then
        finish(has_alt, has_alt and "raiden_alt_owner_set" or "raiden_alt_owner_missing")
    end
end

local function monitor_oldshang()
    if not space or fighting_frame == 0 then return end

    local p1obj = space:read_u32(P1_OBJ)
    local p1proc = space:read_u32(P1_PROC)
    if p1obj == 0 or p1proc == 0 then return end

    local flags = space:read_u16(p1proc + PROC_FLAGS)
    local is_old = (flags & PM_OLDSHANG) ~= 0
    local p1x = space:read_u16(p1obj + OBJ_OXPOS)

    if is_old and old_active_frame == 0 then
        old_active_frame = frame
        old_active_logged = true
        log_state("oldshang_active")
        snap("oldshang_active")
    end

    if old_active_frame ~= 0 and not is_old and old_clear_frame == 0 then
        old_clear_frame = frame
        log_state("oldshang_flag_cleared")
        oldskull_count_and_dump("oldshang_flag_cleared", true)
        snap("oldshang_flag_cleared")
    end

    if old_active_frame ~= 0 and old_clear_frame == 0 then
        local rel = frame - old_active_frame
        if rel == 45 then x_forward_start = p1x end
        if rel == 145 then
            x_forward_end = p1x
            print(string.format("[mk2reg] oldshang_forward_delta start=%s end=%s delta=%d",
                tostring(x_forward_start), tostring(x_forward_end), x_forward_start and s16(x_forward_end - x_forward_start) or 0))
        end
        if rel == 180 then x_back_start = p1x end
        if rel == 280 then
            x_back_end = p1x
            print(string.format("[mk2reg] oldshang_back_delta start=%s end=%s delta=%d",
                tostring(x_back_start), tostring(x_back_end), x_back_start and s16(x_back_end - x_back_start) or 0))
        end

        local skulls = oldskull_count_and_dump("active", false)
        if skulls > last_oldskull_count and frame > old_clear_frame + 60 then
            local new_skulls = skulls - last_oldskull_count
            for _ = 1, new_skulls do
                oldskull_spawn_frames[#oldskull_spawn_frames + 1] = frame
            end
            if old_clear_frame ~= 0 and frame > old_clear_frame + 60 then
                oldskull_spawns_after_clear = oldskull_spawns_after_clear + new_skulls
            end
            print(string.format("[mk2reg] oldskull_count_up frame=%d %d -> %d",
                frame, last_oldskull_count, skulls))
            oldskull_count_and_dump("oldskull_count_up", true)
        end
        last_oldskull_count = skulls

        if rel > 980 and not aged_morph_timer then
            aged_morph_timer = true
            local tick = space:read_u16(TICK)
            space:write_u16(L_MORPH, (tick - 0x0300) & 0xffff)
            print(string.format("[mk2reg] aged_l_morph frame=%d tick=%04x wrote=%04x",
                frame, tick, space:read_u16(L_MORPH)))
            log_state("aged_l_morph")
        end
    end

    if old_clear_frame ~= 0 then
        local skulls = oldskull_count_and_dump("after_clear_watch", false)
        if skulls > last_oldskull_count then
            local new_skulls = skulls - last_oldskull_count
            oldskull_spawns_after_clear = oldskull_spawns_after_clear + new_skulls
            for _ = 1, new_skulls do
                oldskull_spawn_frames[#oldskull_spawn_frames + 1] = frame
            end
            print(string.format("[mk2reg] oldskull_after_clear_count_up frame=%d %d -> %d",
                frame, last_oldskull_count, skulls))
            oldskull_count_and_dump("oldskull_after_clear_count_up", true)
        end
        last_oldskull_count = skulls
    end

    if old_clear_frame ~= 0 and frame - old_clear_frame > 320 then
        local skulls = oldskull_count_and_dump("after_unmorph", true)
        local moved = false
        if x_forward_start and x_forward_end and math.abs(s16(x_forward_end - x_forward_start)) >= 8 then moved = true end
        if x_back_start and x_back_end and math.abs(s16(x_back_end - x_back_start)) >= 8 then moved = true end
        finish(moved and skulls == 0 and oldskull_spawns_after_clear == 0,
            moved and skulls == 0 and oldskull_spawns_after_clear == 0 and "oldshang_pass" or "oldshang_failed_checks")
    end

    if old_active_frame ~= 0 and frame - old_active_frame > 1800 then
        finish(false, "oldshang_timeout_after_morph")
    end

    if not old_active_logged and frame - fighting_frame > 780 then
        finish(false, "oldshang_never_morphed")
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print(string.format("[mk2reg] loaded case=%s log=%s", TEST_CASE, log_path))
    end

    if space and not finished then
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[mk2reg] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
                fight_count = fight_count + 1
                fighting_frame = frame
                log_state("fight_start_" .. tostring(fight_count))
                snap("fight_start_" .. tostring(fight_count))
            end
            last_gstate = gs
        end

        if charsel_frame > 0 and gs == GS_PSEL and frame - charsel_frame > 30 then
            direct_select_for_case()
        end

        if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0 and frame - charsel_frame > 90 then
            p1_confirm_start = frame
            print(string.format("[mk2reg] confirm_start frame=%d case=%s p1_char=%d p2_char=%d",
                frame, TEST_CASE, space:read_u16(P1_CHAR), space:read_u16(P2_CHAR)))
        end

        if charsel_frame > 0 and not did_select_log and frame - charsel_frame >= 260 then
            did_select_log = true
            log_state("select_late")
        end

        if TEST_CASE == "raiden_alt" then monitor_raiden_alt() end
        if TEST_CASE == "oldshang" then monitor_oldshang() end
        if check_lockup() then return end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    if space and not finished and frame % 60 == 0 then
        log_state("heartbeat")
    end

    if not finished and frame > 12000 then
        dump_proc_list("global_timeout")
        finish(false, "global_timeout")
    end
end)
