-- outer_haven_bg_probe.lua
-- Force a normal match onto Outer Haven and dump every background actor's
-- osag/oimg/opos so a garbled/garbage-SAG asset can be spotted from the log,
-- plus take a screen snapshot once the fight is settled.

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOG_PATH = ROOT .. "/tools/_port_stock_probe.log"
local logfh = io.open(LOG_PATH, "w")
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

local function symaddr(name, fallback)
    local value = symbols[name]
    if value then return value end
    print(string.format("[port-probe] WARN missing map symbol %s; using fallback 0x%08x", name, fallback))
    return fallback
end

local A = {
    baklst1  = symaddr("baklst1", 0x01127050),
    baklst2  = symaddr("baklst2", 0x01127030),
    baklst3  = symaddr("baklst3", 0x01127010),
    baklst4  = symaddr("baklst4", 0x01126ff0),
    baklst5  = symaddr("baklst5", 0x01126fd0),
    baklst6  = symaddr("baklst6", 0x01126fb0),
    baklst7  = symaddr("baklst7", 0x01126f90),
    baklst8  = symaddr("baklst8", 0x01126f70),
    objlst   = symaddr("objlst", 0x01127070),
    gstate   = symaddr("gstate", 0x01129dd0),
    curback  = symaddr("curback", 0x0112b6d0),
    p1_char  = symaddr("p1_char", 0x01129e80),
    p2_char  = symaddr("p2_char", 0x0112aa50),
    map_position = symaddr("map_position", 0x0112b740),
    battle_num   = symaddr("battle_num", 0x0112b760),
}

local O = {
    next    = 0x000,
    oxpos   = 0x090,
    oypos   = 0x0b0,
    ozval   = 0x0c0,
    oflags  = 0x0f0,
    osag    = 0x100,
    osize   = 0x120,
    opal    = 0x140,
    oflags2 = 0x160,
    oimg    = 0x1a0,
    oid     = 0x1c0,
    oshape  = 0x1d0,
    ochar   = 0x1f0,
}

local GS_PSEL = 4
local GS_FIGHTING = 2
local FT_KANG = 1
local FT_CAGE = 2
local OUTER_HAVEN = 0x07	-- stock Portal, for comparison

local fields = {}
local cpu, space = nil, nil
local last_gstate = -1
local charsel_frame = 0
local fighting_frame = 0
local p1_confirm_start = 0
local p2_confirm_start = 0
local did_direct_select = false
local dumped = {}
local done_frame = 0

local function hx(value)
    if not value then return "na" end
    return string.format("0x%08x", value)
end
local function s16(value)
    value = value & 0xffff
    if value >= 0x8000 then return value - 0x10000 end
    return value
end
local function r16(addr) return space:read_u16(addr) end
local function r32(addr) return space:read_u32(addr) end
local function w16(addr, value) space:write_u16(addr, value & 0xffff) end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["Coin 2"] = true,
        ["1 Player Start"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
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
    if not s then return end
    local ok, err = pcall(function() s:snapshot() end)
    print(string.format("[port-probe] SNAP frame=%d label=%s ok=%s %s", frame, label, tostring(ok), ok and "" or tostring(err)))
end

local function obj_detail(p)
    if p == 0 then return "none" end
    return string.format(
        "%s ch=%d xy=(%d,%d) z=%s img=%s sag=%s size=%s shape=%s pal=%04x fl=%04x",
        hx(p), r16(p + O.ochar),
        s16(r16(p + O.oxpos)), s16(r16(p + O.oypos)), hx(r32(p + O.ozval)),
        hx(r32(p + O.oimg)), hx(r32(p + O.osag)), hx(r32(p + O.osize)),
        hx(r32(p + O.oshape)), r16(p + O.opal), r16(p + O.oflags))
end

local function dump_list(label, head_addr, limit)
    local p = r32(head_addr)
    local count = 0
    while p ~= 0 and count < (limit or 60) do
        print(string.format("[port-probe] %s[%d]=%s", label, count, obj_detail(p)))
        p = r32(p + O.next)
        count = count + 1
    end
    print(string.format("[port-probe] %s total=%d", label, count))
end

local function dump_all_bg(label)
    print("[port-probe] ==== " .. label .. " ====")
    dump_list("baklst1", A.baklst1, 40)
    dump_list("baklst2", A.baklst2, 40)
    dump_list("baklst3", A.baklst3, 40)
    dump_list("baklst4", A.baklst4, 40)
    dump_list("baklst5", A.baklst5, 40)
    dump_list("baklst6", A.baklst6, 40)
    dump_list("baklst7", A.baklst7, 40)
    dump_list("baklst8", A.baklst8, 40)
end

local function force_match()
    w16(A.p1_char, FT_KANG)
    w16(A.p2_char, FT_CAGE)
    w16(A.curback, OUTER_HAVEN)
    if not did_direct_select then
        did_direct_select = true
        print(string.format("[port-probe] direct_select frame=%d p1=%d p2=%d curback=%d",
            frame, r16(A.p1_char), r16(A.p2_char), r16(A.curback)))
    end
end

local function pressed(name)
    if fighting_frame > 0 then return false end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1_confirm_start > 0 then
        return frame >= p1_confirm_start and frame < p1_confirm_start + 45
    end
    if name == "P2 High Punch" and p2_confirm_start > 0 then
        return frame >= p2_confirm_start and frame < p2_confirm_start + 45
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[port-probe] loaded, forcing Outer Haven (stage " .. OUTER_HAVEN .. ")")
    end

    if space then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            print(string.format("[port-probe] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
            end
            last_gstate = gs
        end

        if charsel_frame > 0 and fighting_frame == 0 then
            force_match()
        end
        if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0 and frame - charsel_frame > 90 then
            p1_confirm_start = frame
        end
        if charsel_frame > 0 and gs == GS_PSEL and p2_confirm_start == 0 and frame - charsel_frame > 150 then
            p2_confirm_start = frame
        end

        if fighting_frame > 0 then
            local rel = frame - fighting_frame
            if (rel == 60 or rel == 200) and not dumped[rel] then
                dumped[rel] = true
                dump_all_bg("fight_rel_" .. rel)
                snap("fight_rel_" .. rel)
            end
            if rel > 220 and done_frame == 0 then
                done_frame = frame
                print("[port-probe] finished")
            end
        end

        if done_frame > 0 and frame - done_frame > 20 then
            manager.machine:exit()
            return
        end
        if frame > 3000 then
            print("[port-probe] TIMEOUT")
            manager.machine:exit()
            return
        end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end
end)

emu.register_stop(function()
    if logfh then logfh:flush(); logfh:close(); logfh = nil end
end)
