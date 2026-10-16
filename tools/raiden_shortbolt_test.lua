-- raiden_shortbolt_test.lua
-- Drives a 2P match, selects P1 Raiden vs P2 Jax, performs Back+HP, and
-- watches for RNSHORTBOLT multipart art.  Intended to catch bad SAG/palette
-- crashes fast.

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/raiden_shortbolt_test.log", "w")
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
local space = nil
local cpu = nil
local charsel_frame = 0
local fighting_frame = 0
local vs_frame = 0
local p1_confirm_start = 0
local last_gstate = -1
local did_select_log = false
local did_bolt_snap = false
local did_jax_select_snap = false
local did_error = false
local did_force_win = false
local did_winner_snap = false
local force_win = os.getenv("RAIDEN_FORCE_WIN") == "1"

local ACTIVE   = 0x010dc6d0
local GSTATE   = 0x01129d90
local P1_CHAR  = 0x01129e40
local P2_CHAR  = 0x0112aa10
local P1_OBJ   = 0x01129de0
local P2_OBJ   = 0x0112a9b0
local P1_PROC  = 0x01129e20
local P1_BUTTON= 0x01129e00
local P2_BAR   = 0x0112aa80
local WINNER_STATUS = 0x0112b6c0
local PF_RAM   = 0x0112b660
local OBJLST   = 0x01127030
local TICK     = 0x01126c40
local WORLDTLX = 0x01126ef0
local WORLDTLY = 0x01126cd0
local P1_BCQ   = 0x01129f00
local P1_JCQ   = 0x0112a1a0
local P2_BCQ   = 0x0112aad0
local P2_JCQ   = 0x0112ad70

local PROC_NEXT = 0x000
local PROC_ID   = 0x020
local PROC_WAKE = 0x0e0

local OBJ_NEXT  = 0x000
local OBJ_OXPOS = 0x090
local OBJ_OYPOS = 0x0b0
local OBJ_OZVAL = 0x0c0
local OBJ_OPAL  = 0x140
local OBJ_OFLAGS= 0x0f0
local OBJ_OFLAGS2= 0x160
local OBJ_OIMG  = 0x1a0
local OBJ_OSAG  = 0x100
local OBJ_OFSET = 0x0e0
local OBJ_OCHAR = 0x1f0
local PROC_ACTION = 0x1f0

local GS_PSEL     = 4
local GS_FIGHTING = 2
local PID_PROJ1   = 0x0700
local FT_RAIDEN   = 7
local FT_JAX      = 11
local SW_HP        = 0
local SW_DOWN      = 6
local SW_LEFT      = 7
local SW_RIGHT     = 8
local MKBUG_START  = 0xffa31a00
local MKBUG_END    = 0xffa31d00

local SQS = 20

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 Right"] = true,
        ["P1 Left"] = true,
        ["P1 Down"] = true,
        ["P1 High Punch"] = true,
        ["P2 Down"] = true,
        ["P1 Low Kick"] = true,
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
        print(string.format("[shortbolt] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
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
        print(string.format("[shortbolt] SNAP frame=%d label=%s ok=%s %s",
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

local function find_process(pid)
    if not space then return 0 end
    local p = space:read_u32(ACTIVE)
    local guard = 0
    while p ~= 0 and guard < 256 do
        if space:read_u16(p + PROC_ID) == pid then return p end
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
    return 0
end

local function find_shortbolt_obj()
    if not space then return 0, 0 end
    local p = space:read_u32(OBJLST)
    local guard = 0
    while p ~= 0 and guard < 256 do
        local oimg = space:read_u32(p + OBJ_OIMG)
        if oimg ~= 0 then
            local sag = space:read_u32(oimg)
            if (sag >= 0x03f00000 and sag <= 0x03f40000)
               or (sag >= 0x0548b000 and sag <= 0x05493000) then
                return p, sag
            end
        end
        p = space:read_u32(p + OBJ_NEXT)
        guard = guard + 1
    end
    return 0, 0
end

local function queue_prev(base, n)
    local nextp = space:read_u32(base)
    local p = nextp - (0x20 * n)
    while p <= base do
        p = p + (0x20 * SQS)
    end
    return p, space:read_u32(p)
end

local function queue_word(entry)
    local sw = math.floor(entry / 0x10000) & 0xffff
    local tick = entry & 0xffff
    return sw, tick
end

local function queue_summary(label, base)
    local parts = {}
    for i = 1, 4 do
        local _, entry = queue_prev(base, i)
        local sw, tick = queue_word(entry)
        parts[#parts + 1] = string.format("%d:%d", sw, tick)
    end
    return label .. "{" .. table.concat(parts, ",") .. "}"
end

local function obj_list_membership(target)
    if not space or target == 0 then return "none", 0 end
    local lists = { { "objlst", OBJLST } }
    local hits = {}
    local total = 0
    for _, spec in ipairs(lists) do
        local name, head = spec[1], spec[2]
        local p = space:read_u32(head)
        local guard = 0
        while p ~= 0 and guard < 256 do
            total = total + 1
            if p == target then hits[#hits + 1] = name .. "#" .. tostring(guard) end
            p = space:read_u32(p + OBJ_NEXT)
            guard = guard + 1
        end
    end
    if #hits == 0 then return "not-linked", total end
    return table.concat(hits, ","), total
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
        if vs_frame > 0 and frame >= vs_frame + 260 and frame < vs_frame + 320 then
            return name == "P1 High Punch" or name == "P2 High Punch" or name == "P1 Low Kick"
        end
        if name == "P1 Right" then
            return (r >= 80 and r < 94) or (r >= 125 and r < 139) or (r >= 170 and r < 184)
        end
        if name == "P1 Down" then
            return (r >= 220 and r < 234) or (r >= 265 and r < 279)
        end
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 Down" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 42 and frame < p1_confirm_start + 48
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 300
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        local cycle = r % 120
        if r > 60 and r < 900 then
            if name == "P1 Left" then return cycle >= 16 and cycle < 40 end
            if name == "P1 High Punch" then return cycle >= 22 and cycle < 40 end
        end
    end

    return false
end

local function log_state(force)
    if not space then return end
    if not force and (frame % 30) ~= 0 then return end

    local gstate = space:read_u16(GSTATE)
    local p1c = space:read_u16(P1_CHAR)
    local p2c = space:read_u16(P2_CHAR)
    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    local p1proc = space:read_u32(P1_PROC)
    local p1ochar = p1obj ~= 0 and space:read_u16(p1obj + OBJ_OCHAR) or 0xffff
    local p2ochar = p2obj ~= 0 and space:read_u16(p2obj + OBJ_OCHAR) or 0xffff
    local p1x, p1y, p1opal, p1flags, p1flags2 = 0, 0, 0, 0, 0
    local p2x, p2y, p2opal, p2flags, p2flags2 = 0, 0, 0, 0, 0
    local p1sag, p1osag, p1ofset = 0, 0, 0
    local p2sag, p2osag, p2ofset = 0, 0, 0
    if p1obj ~= 0 then
        p1x = space:read_u16(p1obj + OBJ_OXPOS)
        p1y = space:read_u16(p1obj + OBJ_OYPOS)
        p1opal = space:read_u16(p1obj + OBJ_OPAL)
        p1flags = space:read_u16(p1obj + OBJ_OFLAGS)
        p1flags2 = space:read_u16(p1obj + OBJ_OFLAGS2)
        p1osag = space:read_u32(p1obj + OBJ_OSAG)
        p1ofset = space:read_u16(p1obj + OBJ_OFSET)
        local p1img = space:read_u32(p1obj + OBJ_OIMG)
        if p1img ~= 0 then p1sag = space:read_u32(p1img) end
    end
    if p2obj ~= 0 then
        p2x = space:read_u16(p2obj + OBJ_OXPOS)
        p2y = space:read_u16(p2obj + OBJ_OYPOS)
        p2opal = space:read_u16(p2obj + OBJ_OPAL)
        p2flags = space:read_u16(p2obj + OBJ_OFLAGS)
        p2flags2 = space:read_u16(p2obj + OBJ_OFLAGS2)
        p2osag = space:read_u32(p2obj + OBJ_OSAG)
        p2ofset = space:read_u16(p2obj + OBJ_OFSET)
        local p2img = space:read_u32(p2obj + OBJ_OIMG)
        if p2img ~= 0 then p2sag = space:read_u32(p2img) end
    end
    local p1act = p1proc ~= 0 and space:read_u16(p1proc + PROC_ACTION) or 0xffff
    local p1button = space:read_u32(P1_BUTTON)
    local proj = find_process(PID_PROJ1)
    local obj, sag = find_shortbolt_obj()
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local sp = cpu_reg("SP")
    local b14 = cpu_reg("B14") or cpu_reg("b14")
    local pf = space:read_u32(PF_RAM)
    local tick = space:read_u16(TICK)
    local wx = space:read_u16(WORLDTLX + 0x10)
    local wy = space:read_u16(WORLDTLY + 0x10)
    local qinfo = ""
    if fighting_frame > 0 then
        qinfo = " " .. queue_summary("p1j", P1_JCQ)
             .. " " .. queue_summary("p1b", P1_BCQ)
             .. " tick=" .. tostring(tick)
    end

    local objinfo = "shortobj=none"
    if obj ~= 0 then
        objinfo = string.format("shortobj=0x%08x sag=0x%08x xy=%d,%d oz=0x%08x opal=0x%x",
            obj, sag, space:read_u16(obj + OBJ_OXPOS), space:read_u16(obj + OBJ_OYPOS),
            space:read_u32(obj + OBJ_OZVAL), space:read_u16(obj + OBJ_OPAL))
        if not did_bolt_snap then
            did_bolt_snap = true
            snap("shortbolt_visible")
        end
    end

    print(string.format(
        "[shortbolt] frame=%d gs=%d wx=%d wy=%d p1=%d p2=%d p1objchar=%d p1act=0x%04x p1btn=%s proj=0x%08x wake=%s %s pc=%s sp=%s b14=%s pf=%s",
        frame, gstate, wx, wy, p1c, p2c, p1ochar, p1act, hx(p1button), proj,
        proj ~= 0 and hx(space:read_u32(proj + PROC_WAKE)) or "na",
        objinfo, hx(pc), hx(sp), hx(b14), hx(pf)))
    if force or fighting_frame > 0 or p2c == FT_JAX then
        local p1list, p1listcount = obj_list_membership(p1obj)
        local p2list, p2listcount = obj_list_membership(p2obj)
        print(string.format("[shortbolt] p1obj=0x%08x char=%d xy=%d,%d opal=0x%x oflags=0x%04x oflags2=0x%04x img_sag=0x%08x osag=0x%08x ofset=0x%04x link=%s listn=%d",
            p1obj, p1ochar, p1x, p1y, p1opal, p1flags, p1flags2, p1sag, p1osag, p1ofset, p1list, p1listcount))
        print(string.format("[shortbolt] p2obj=0x%08x char=%d xy=%d,%d opal=0x%x oflags=0x%04x oflags2=0x%04x img_sag=0x%08x osag=0x%08x ofset=0x%04x link=%s listn=%d",
            p2obj, p2ochar, p2x, p2y, p2opal, p2flags, p2flags2, p2sag, p2osag, p2ofset, p2list, p2listcount))
    end
    if qinfo ~= "" and (force or (frame - fighting_frame) < 260 or obj ~= 0 or proj ~= 0) then
        print("[shortbolt] queues " .. qinfo)
    end
end

local function check_cpu_lockup()
    if did_error or not space or fighting_frame == 0 then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local pf = space:read_u32(PF_RAM)
    if pf == 0xffffffff or (pc and pc >= MKBUG_START and pc <= MKBUG_END) then
        did_error = true
        log_state(true)
        snap("mkbug_lockup")
        print(string.format("[shortbolt] ERROR mkbug_lockup pc=%s pf=%s", hx(pc), hx(pf)))
        manager.machine:exit()
        return true
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1

    if frame == 1 then
        cache_fields()
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        print("[shortbolt] loaded: selecting P1 Raiden vs P2 Jax, then firing Back+HP")
        if force_win then print("[shortbolt] force-win mode: will zero P2 bar to test Raiden victory") end
    end

    if space then
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[shortbolt] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == 13 and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                snap("fight_start")
            end
            if fighting_frame > 0 and gs == 0xffff then
                log_state(true)
                snap("gstate_corrupt")
                print("[shortbolt] ERROR gstate_corrupt")
                manager.machine:exit()
                return
            end
            last_gstate = gs
        end

        if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0
           and frame - charsel_frame > 250 and space:read_u16(P1_CHAR) == FT_RAIDEN then
            p1_confirm_start = frame
            print(string.format("[shortbolt] p1 Raiden reached at frame=%d; confirming", frame))
        end

        if charsel_frame > 0 and not did_select_log and frame - charsel_frame >= 270 then
            did_select_log = true
            print(string.format("[shortbolt] pre-confirm p1_char=%d want=%d p2_char=%d want=%d",
                space:read_u16(P1_CHAR), FT_RAIDEN, space:read_u16(P2_CHAR), FT_JAX))
        end

        if gs == GS_PSEL and not did_jax_select_snap and space:read_u16(P2_CHAR) == FT_JAX then
            local p2obj = space:read_u32(P2_OBJ)
            if obj_list_membership(p2obj) ~= "not-linked" then
                did_jax_select_snap = true
                snap("jax_select")
            end
        end

        if check_cpu_lockup() then return end

        if force_win and fighting_frame > 0 then
            local r = frame - fighting_frame
            if r > 180 and r < 240 then
                space:write_u16(P2_BAR, 0)
                if not did_force_win then
                    did_force_win = true
                    print(string.format("[shortbolt] force_win zeroed p2_bar frame=%d", frame))
                end
            end
            local ws = space:read_u16(WINNER_STATUS)
            if ws ~= 0 and not did_winner_snap then
                did_winner_snap = true
                log_state(true)
                snap("winner_status_" .. tostring(ws))
                print(string.format("[shortbolt] winner_status=%d frame=%d", ws, frame))
            end
        end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    log_state(false)

    if fighting_frame > 0 and frame - fighting_frame > 1050 then
        log_state(true)
        snap("final")
        print("[shortbolt] finished")
        manager.machine:exit()
    end

    if frame > 9000 then
        log_state(true)
        snap("timeout")
        print("[shortbolt] timeout")
        manager.machine:exit()
    end
end)
