-- reptile_airspit_regression_test.lua
-- Selects P1 Reptile vs P2 Jax, performs repeated jump air-spits, and
-- watches for orphaned face/projectile objects or world-scroll corruption.

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/reptile_airspit_regression_test.log", "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local fields = {}
local cpu, space = nil, nil
local charsel_frame, vs_frame, fighting_frame = 0, 0, 0
local p1_confirm_start = 0
local last_gstate = -1
local did_select_log = false
local did_error = false
local did_airspit_snap = false
local did_force_win = false
local did_winner_snap = false
local did_lockup_snap = false
local did_lowproc_dump = false
local did_midproc_dump = false
local force_win = os.getenv("AIRSPIT_FORCE_WIN") == "1"
local jump_back = os.getenv("AIRSPIT_JUMP_BACK") == "1"
local hold_up = os.getenv("AIRSPIT_HOLD_UP") == "1"
local fight_frames = tonumber(os.getenv("AIRSPIT_FIGHT_FRAMES") or "1250") or 1250
local p2_target = string.lower(os.getenv("AIRSPIT_P2") or "jax")

local ACTIVE   = 0x010dc6d0
local FREE     = 0x010dc6f0
local GSTATE   = 0x01129d90
local P1_CHAR  = 0x01129e40
local P2_CHAR  = 0x0112aa10
local P1_OBJ   = 0x01129de0
local P2_OBJ   = 0x0112a9b0
local P1_PROC  = 0x01129e20
local P1_BAR   = 0x01129eb0
local P2_BAR   = 0x0112aa80
local WINNER_STATUS = 0x0112b6c0
local WORLDTLX = 0x01126ef0
local WORLDTLY = 0x01126cd0
local OBJLST   = 0x01127030
local OBJLST2  = 0x01127050

local PROC_NEXT   = 0x000
local PROC_ID     = 0x020
local PROC_TIME   = 0x030
local PROC_WAKE   = 0x0e0
local PROC_ACTION = 0x1f0
local PROC_PA8    = 0x0c0
local PROC_PA10   = 0x080
local OBJ_NEXT    = 0x000
local OBJ_OSLINK  = 0x020
local OBJ_OXPOS   = 0x090
local OBJ_OYPOS   = 0x0b0
local OBJ_OIMG    = 0x1a0
local OBJ_OCHAR   = 0x1f0

local PROC_MIN = 0x010dc740
local PROC_MAX = 0x01150000

local GS_PSEL     = 4
local GS_POST     = 0x0d
local GS_FIGHTING = 2
local FT_REPTILE  = 9
local FT_JAX      = 11
local FT_BARAKA   = 3
local ACT_AIR_SPIT = 0x0016
local PC_RECOVERIES = {
    [0xff8314f0] = true,
    [0xffa3dea0] = true,
    [0xffa3dec0] = true,
    [0xffa3def0] = true,
    [0xffa3df10] = true,
    [0xffa3df20] = true,
    [0xffa3df40] = true,
    [0xffa3dfa0] = true,
    [0xffa3dfc0] = true,
    [0xffa3e2a0] = true,
    [0xffa3e2c0] = true,
    [0xffa3dd10] = true,
    [0xffa3dd20] = true,
    [0xffa3dd50] = true,
    [0xffa3f320] = true,
    [0xffa3f420] = true,
    [0xffa3c2e0] = true,
    [0xffa3c460] = true,
    [0xffa3c430] = true,
}

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 Up"] = true,
        ["P1 Left"] = true,
        ["P1 Right"] = true,
        ["P1 High Punch"] = true,
        ["P1 Low Kick"] = true,
        ["P2 Left"] = true,
        ["P2 Down"] = true,
        ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[airspit] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
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
        print(string.format("[airspit] SNAP frame=%d label=%s ok=%s %s", frame, label, tostring(ok), ok and "" or tostring(err)))
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
    local p = space:read_u32(addr)
    local count = 0
    while p ~= 0 and count < 256 do
        count = count + 1
        p = space:read_u32(p + OBJ_NEXT)
    end
    return count
end

local function count_procs(addr)
    local p = space:read_u32(addr)
    local count = 0
    local seen = {}
    while p ~= 0 and p >= PROC_MIN and p < PROC_MAX and not seen[p] and count < 256 do
        seen[p] = true
        count = count + 1
        p = space:read_u32(p + PROC_NEXT)
    end
    return count
end

local function dump_proc_list(addr, label)
    local p = space:read_u32(addr)
    local count = 0
    local seen = {}
    local hist = {}
    local samples = {}
    while p ~= 0 and p >= PROC_MIN and p < PROC_MAX and not seen[p] and count < 256 do
        seen[p] = true
        count = count + 1
        local pid = space:read_u16(p + PROC_ID)
        hist[pid] = (hist[pid] or 0) + 1
        if #samples < 28 then
            samples[#samples + 1] = string.format("%s:pid=%04x t=%04x wake=%s pa8=%s pa10=%s",
                hx(p), pid, space:read_u16(p + PROC_TIME), hx(space:read_u32(p + PROC_WAKE)),
                hx(space:read_u32(p + PROC_PA8)), hx(space:read_u32(p + PROC_PA10)))
        end
        p = space:read_u32(p + PROC_NEXT)
    end
    local keys = {}
    for pid, _ in pairs(hist) do keys[#keys + 1] = pid end
    table.sort(keys)
    local parts = {}
    for _, pid in ipairs(keys) do parts[#parts + 1] = string.format("%04x:%d", pid, hist[pid]) end
    print(string.format("[airspit] %s count=%d head=%s tail_next=%s hist=%s",
        label, count, hx(space:read_u32(addr)), hx(p), table.concat(parts, ",")))
    for _, line in ipairs(samples) do print(string.format("[airspit] %s sample %s", label, line)) end
end

local function dump_obj_list(addr, label)
    local p = space:read_u32(addr)
    local count = 0
    local seen = {}
    while p ~= 0 and p >= 0x01000000 and p < 0x01200000 and not seen[p] and count < 40 do
        seen[p] = true
        count = count + 1
        print(string.format("[airspit] %s obj%d=%s next=%s img=%s oslink=%s char=%d xy=%d,%d",
            label, count, hx(p), hx(space:read_u32(p + OBJ_NEXT)),
            hx(space:read_u32(p + OBJ_OIMG)), hx(space:read_u32(p + OBJ_OSLINK)),
            space:read_u16(p + OBJ_OCHAR), space:read_u16(p + OBJ_OXPOS), space:read_u16(p + OBJ_OYPOS)))
        p = space:read_u32(p + OBJ_NEXT)
    end
    print(string.format("[airspit] %s dumped=%d next=%s", label, count, hx(p)))
end

local function count_reptile_loose_objects()
    local loose = 0
    local p = space:read_u32(OBJLST)
    local guard = 0
    while p ~= 0 and guard < 256 do
        local oc = space:read_u16(p + OBJ_OCHAR)
        local x = space:read_u16(p + OBJ_OXPOS)
        local y = space:read_u16(p + OBJ_OYPOS)
        local img = space:read_u32(p + OBJ_OIMG)
        if oc == FT_REPTILE and img ~= 0 and y < 220 and x > 20 and x < 390 then
            loose = loose + 1
        end
        p = space:read_u32(p + OBJ_NEXT)
        guard = guard + 1
    end
    return loose
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" or name == "Coin 2" then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end

    if charsel_frame > 0 and fighting_frame == 0 then
        local r = frame - charsel_frame
        if name == "P1 Right" then
            return (r >= 80 and r < 88) or (r >= 135 and r < 143) or (r >= 190 and r < 198)
        end
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if p2_target == "baraka" and p1_confirm_start > 0 then
            if name == "P2 Left" then
                return (frame >= p1_confirm_start + 45 and frame < p1_confirm_start + 53) or
                    (frame >= p1_confirm_start + 95 and frame < p1_confirm_start + 103)
            end
            if name == "P2 Down" then
                return (frame >= p1_confirm_start + 145 and frame < p1_confirm_start + 153) or
                    (frame >= p1_confirm_start + 195 and frame < p1_confirm_start + 203)
            end
            if name == "P2 High Punch" then
                return frame >= p1_confirm_start + 245 and frame < p1_confirm_start + 285
            end
        end
        if name == "P2 Down" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 45 and frame < p1_confirm_start + 53
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 90 and frame < p1_confirm_start + 130
        end
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 305
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        local cycle = r % 96
        if r > 55 and r < fight_frames then
            if name == "P1 Up" then
                if hold_up then return cycle >= 4 and cycle < 46 end
                return cycle >= 4 and cycle < 14
            end
            if name == "P1 Left" and jump_back then return cycle >= 4 and cycle < 14 end
            if name == "P1 Right" then
                return (cycle >= 16 and cycle < 22) or (cycle >= 26 and cycle < 32)
            end
            if name == "P1 High Punch" then return cycle >= 36 and cycle < 58 end
        end
    end
    return false
end

local function log_state(force)
    if not space or (not force and frame % 30 ~= 0) then return end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    local p1proc = space:read_u32(P1_PROC)
    local p1act = p1proc ~= 0 and space:read_u16(p1proc + PROC_ACTION) or 0xffff
    local p1x, p1y, p2x, p2y = 0, 0, 0, 0
    if p1obj ~= 0 then p1x = space:read_u16(p1obj + OBJ_OXPOS); p1y = space:read_u16(p1obj + OBJ_OYPOS) end
    if p2obj ~= 0 then p2x = space:read_u16(p2obj + OBJ_OXPOS); p2y = space:read_u16(p2obj + OBJ_OYPOS) end
    print(string.format(
        "[airspit] frame=%d gs=%d p1=%d p2=%d act=0x%04x p1xy=%d,%d p2xy=%d,%d hp=%d/%d world=%d,%d obj=%d obj2=%d procs=%d/%d loose_rp=%d pc=%s",
        frame, space:read_u16(GSTATE), space:read_u16(P1_CHAR), space:read_u16(P2_CHAR),
        p1act, p1x, p1y, p2x, p2y, space:read_u16(P1_BAR), space:read_u16(P2_BAR),
        space:read_u16(WORLDTLX), space:read_u16(WORLDTLY), count_list(OBJLST), count_list(OBJLST2),
        count_procs(ACTIVE), count_procs(FREE), count_reptile_loose_objects(), hx(pc)))
end

local function check_bad_state()
    if did_error or not space or fighting_frame == 0 then return false end
    if space:read_u16(GSTATE) ~= GS_FIGHTING then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    if PC_RECOVERIES[pc] and not did_lockup_snap then
        did_lockup_snap = true
        did_error = true
        log_state(true)
        dump_proc_list(ACTIVE, "active")
        dump_proc_list(FREE, "free")
        dump_obj_list(OBJLST, "objlst")
        local function in_list(list, obj)
            local p = space:read_u32(list)
            local guard = 0
            while p ~= 0 and guard < 256 do
                if p == obj then return true end
                p = space:read_u32(p + OBJ_NEXT)
                guard = guard + 1
            end
            return false
        end
        local function dump_obj(label, obj)
            if not obj or obj == 0 then
                print(string.format("[airspit] %s=nil", label))
                return
            end
            print(string.format(
                "[airspit] %s=%s next=%s img=%s char=%d xy=%d,%d in1=%s in2=%s",
                label, hx(obj), hx(space:read_u32(obj + OBJ_NEXT)),
                hx(space:read_u32(obj + OBJ_OIMG)), space:read_u16(obj + OBJ_OCHAR),
                space:read_u16(obj + OBJ_OXPOS), space:read_u16(obj + OBJ_OYPOS),
                tostring(in_list(OBJLST, obj)), tostring(in_list(OBJLST2, obj))))
        end
        dump_obj("reg_a0", cpu_reg("A0"))
        dump_obj("reg_a8", cpu_reg("A8"))
        dump_obj("reg_a10", cpu_reg("A10"))
        local sp = cpu_reg("SP") or 0
        for i = 0, 7 do
            local addr = sp + (i * 0x10)
            print(string.format("[airspit] stack[%d] @%s = %s", i, hx(addr), hx(space:read_u32(addr))))
        end
        for i = 0, 15 do
            local addr = sp + (i * 0x10)
            print(string.format("[airspit] stack16[%d] @%s = 0x%04x", i, hx(addr), space:read_u16(addr)))
        end
        print(string.format(
            "[airspit] regs a0=%s a1=%s a2=%s a3=%s a4=%s a5=%s a6=%s a7=%s a8=%s a9=%s a10=%s a11=%s a12=%s a13=%s",
            hx(cpu_reg("A0")), hx(cpu_reg("A1")), hx(cpu_reg("A2")), hx(cpu_reg("A3")),
            hx(cpu_reg("A4")), hx(cpu_reg("A5")), hx(cpu_reg("A6")), hx(cpu_reg("A7")),
            hx(cpu_reg("A8")), hx(cpu_reg("A9")), hx(cpu_reg("A10")), hx(cpu_reg("A11")),
            hx(cpu_reg("A12")), hx(cpu_reg("A13"))))
        print(string.format("[airspit] ERROR lockup pc=%s b14=%s sp=%s a8=%s a10=%s",
            hx(pc), hx(cpu_reg("B14")), hx(cpu_reg("SP")), hx(cpu_reg("A8")), hx(cpu_reg("A10"))))
        snap("lockup")
        manager.machine:exit()
        return true
    end
    local obj_count = count_list(OBJLST)
    if obj_count > 128 then
        did_error = true
        log_state(true)
        snap("bad_object_count")
        print(string.format("[airspit] ERROR obj_count=%d", obj_count))
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
        print(string.format("[airspit] loaded: selecting P1 Reptile vs P2 %s, then repeating jump FF+HP", p2_target))
        if force_win then print("[airspit] force-win mode: will zero P2 bar after air spit starts") end
    end

    if space then
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[airspit] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                did_winner_snap = false
                snap("fight_start")
            end
            last_gstate = gs
        end
        local p1proc = space:read_u32(P1_PROC)
        local p1act = p1proc ~= 0 and space:read_u16(p1proc + PROC_ACTION) or 0xffff
        if p1act == ACT_AIR_SPIT and not did_airspit_snap then
            did_airspit_snap = true
            log_state(true)
            snap("air_spit_action")
        end
        if force_win and did_airspit_snap and not did_force_win and space:read_u16(GSTATE) == GS_FIGHTING then
            space:write_u16(P2_BAR, 0)
            did_force_win = true
            print(string.format("[airspit] force_win zeroed p2_bar frame=%d", frame))
        end
        local ws = space:read_u16(WINNER_STATUS)
        if force_win and fighting_frame > 0 and did_force_win and ws ~= 0 and not did_winner_snap then
            did_winner_snap = true
            log_state(true)
            snap("winner_status_" .. tostring(ws))
            print(string.format("[airspit] winner_status=%d frame=%d loose_rp=%d", ws, frame, count_reptile_loose_objects()))
        end
        if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0
           and frame - charsel_frame > 225 and space:read_u16(P1_CHAR) == FT_REPTILE then
            p1_confirm_start = frame
            print(string.format("[airspit] p1 Reptile reached at frame=%d; confirming", frame))
        end
        if charsel_frame > 0 and not did_select_log and frame - charsel_frame >= 320 then
            did_select_log = true
            local expected_p2 = (p2_target == "baraka") and FT_BARAKA or FT_JAX
            print(string.format("[airspit] pre-confirm p1_char=%d want=%d p2_char=%d want=%d",
                space:read_u16(P1_CHAR), FT_REPTILE, space:read_u16(P2_CHAR), expected_p2))
        end
        if check_bad_state() then return end
        if fighting_frame > 0 and not did_lowproc_dump and count_procs(FREE) <= 6 then
            did_lowproc_dump = true
            log_state(true)
            print("[airspit] LOWPROC dump before recovery")
            dump_proc_list(ACTIVE, "active_low")
            dump_proc_list(FREE, "free_low")
            dump_obj_list(OBJLST, "objlst_low")
        end
        if fighting_frame > 0 and not did_midproc_dump and count_procs(ACTIVE) >= 50 then
            did_midproc_dump = true
            log_state(true)
            print("[airspit] MIDPROC dump before recovery")
            dump_proc_list(ACTIVE, "active_mid")
            dump_proc_list(FREE, "free_mid")
            dump_obj_list(OBJLST, "objlst_mid")
        end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    log_state(false)

    if fighting_frame > 0 and frame - fighting_frame > fight_frames + 250 then
        log_state(true)
        snap("final")
        print("[airspit] finished")
        manager.machine:exit()
    end
    if frame > 9000 then
        log_state(true)
        snap("timeout")
        print("[airspit] timeout")
        manager.machine:exit()
    end
end)
