-- armory_comesoon_location_probe.lua
--
-- Fresh Armory relocation harness for the COMESOON retired MK7 bank-1 window.
-- Drives a normal 2P game to Armory, then verifies the built Armory BMOD/HDRS
-- data points into the COMESOON range instead of the old ARMORY1 range.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local LOG_PATH = os.getenv("ARMORY_COMESOON_LOG") or (ROOT .. "/tools/armory_comesoon_location_probe.log")
local logfh = io.open(LOG_PATH, "w")

local function log(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
    local line = string.format("[armory-comesoon] %s", msg)
    print(line)
    if logfh then
        logfh:write(line, "\n")
        logfh:flush()
    end
end

local function hx(v)
    if v == nil then return "nil" end
    return string.format("0x%08x", v & 0xffffffff)
end

local symbols = {}
do
    local map_path = ROOT .. "/src/MK2.MAP"
    local fh = io.open(map_path, "r")
    if not fh then
        map_path = ROOT .. "/src/mk2.map"
        fh = io.open(map_path, "r")
    end
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
        log("loaded symbols from %s", map_path)
    else
        log("FATAL: could not open MK2.MAP")
    end
end

local function sym(name, fallback)
    local v = symbols[name]
    if v ~= nil then return v end
    log("WARN missing symbol %s, using fallback %s", name, hx(fallback or 0))
    return fallback or 0
end

local A = {
    gstate = sym("gstate", 0x0112a7d0),
    curback = sym("curback", 0x0112c0d0),
    winner_status = sym("winner_status", 0x0112c110),
    p1_char = sym("p1_char", 0x0112a880),
    p2_char = sym("p2_char", 0x0112b450),
    arm1 = sym("ARM1BMOD", 0),
    arm2 = sym("ARM2BMOD", 0),
    arm3 = sym("ARM3BMOD", 0),
    baklst1 = sym("baklst1", 0),
    baklst2 = sym("baklst2", 0),
    baklst3 = sym("baklst3", 0),
    baklst4 = sym("baklst4", 0),
    baklst5 = sym("baklst5", 0),
    baklst6 = sym("baklst6", 0),
    baklst7 = sym("baklst7", 0),
    baklst8 = sym("baklst8", 0),
}

local ARMORY_STAGE = 5
local GS_FIGHTING = 2
local GS_SELECT = 4
local FORCE_ARMORY_STAGE = os.getenv("ARMORY_COMESOON_FORCE_STAGE") ~= "0"
local FORCE_STAGE_UNTIL_FRAME = tonumber(os.getenv("ARMORY_COMESOON_FORCE_UNTIL") or "2200")

-- From regenerated doc/RETIRED_RANGES.md.
local COMESOON_START = 0x05e43418
local COMESOON_END   = 0x05f50574 -- exclusive

-- Current old/live Armory range before relocation.
local OLD_ARMORY_START = 0x0597aa01
local OLD_ARMORY_END   = 0x059f3bd7 -- exclusive

local BANK1_START = 0x04000000
local BANK1_END   = 0x06000000

local O = {
    next = 0x000,
    oxpos = 0x090,
    oypos = 0x0b0,
    osag = 0x100,
    opal = 0x140,
    oflags = 0x0f0,
    oflags2 = 0x160,
    oimg = 0x1a0,
    oid = 0x1c0,
}

local fields = {}
local cpu = nil
local space = nil
local frame = 0
local charsel_frame = 0
local stage_select_active = false
local stage_confirmed = false
local fighting_frame = 0
local last_gstate = -1
local last_curback = -1
local dumped_headers = false
local final_status = "UNKNOWN"

local function r16(addr)
    if not space or addr == nil or addr == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u16(addr) end)
    return ok and v or 0
end

local function r32(addr)
    if not space or addr == nil or addr == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u32(addr) end)
    return ok and v or 0
end

local function w16(addr, value)
    if not space or addr == nil or addr == 0 then return end
    pcall(function() space:write_u16(addr, value & 0xffff) end)
end

local function s16(v)
    v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end
    return v
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(0) end)
    if ok and s then return s end
    return nil
end

local function snap(label)
    local s = main_screen()
    if not s then
        log("SNAP frame=%d label=%s no screen", frame, label)
        return
    end
    local ok, err = pcall(function() s:snapshot() end)
    log("SNAP frame=%d label=%s ok=%s %s", frame, label, tostring(ok), ok and "" or tostring(err))
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 High Punch"] = true,
        ["P2 High Punch"] = true,
        ["P1 Right"] = true,
        ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        log("input %-16s %s", name, fields[name] and "ok" or "MISSING")
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end

    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 200 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 220 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 50
        end
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        local r = frame - charsel_frame
        if name == "P1 High Punch" and not stage_select_active then return r >= 130 and r < 170 end
        if name == "P2 High Punch" and not stage_select_active then return r >= 190 and r < 230 end
    end

    if stage_select_active and not stage_confirmed then
        local cb = r16(A.curback)
        if name == "P1 Right" then return cb ~= ARMORY_STAGE and (frame % 6) < 3 end
        if name == "P1 High Punch" then return cb == ARMORY_STAGE end
        if name == "P1 Low Kick" then return cb == ARMORY_STAGE end
    end

    return false
end

local function classify_sag(sag)
    if sag >= COMESOON_START and sag < COMESOON_END then return "COMESOON" end
    if sag >= OLD_ARMORY_START and sag < OLD_ARMORY_END then return "OLD_ARMORY" end
    if sag >= BANK1_START and sag < BANK1_END then return "BANK1_OTHER" end
    return "OUTSIDE_BANK1"
end

local function read_bmod(label, addr)
    return {
        label = label,
        addr = addr,
        width = r16(addr + 0x00),
        height = r16(addr + 0x10),
        blocks = r16(addr + 0x20),
        blks = r32(addr + 0x30),
        hdrs = r32(addr + 0x50),
        pals = r32(addr + 0x70),
    }
end

local function block_max_header_index(bmod)
    local max_idx = -1
    local p = bmod.blks
    for i = 0, bmod.blocks - 1 do
        local flags = r16(p)
        if flags == 0xffff then break end
        local idx = r16(p + 0x30)
        if idx > max_idx then max_idx = idx end
        p = p + 0x40
    end
    return max_idx
end

local function collect_armory_headers()
    local bmods = {
        read_bmod("ARM1BMOD", A.arm1),
        read_bmod("ARM2BMOD", A.arm2),
        read_bmod("ARM3BMOD", A.arm3),
    }

    local hdrs = bmods[1].hdrs
    local max_idx = -1
    for _, bmod in ipairs(bmods) do
        local bmax = block_max_header_index(bmod)
        if bmax > max_idx then max_idx = bmax end
    end

    local headers = {}
    for i = 0, max_idx do
        local base = hdrs + (i * 0x50)
        headers[#headers + 1] = {
            index = i,
            width = r16(base + 0x00),
            height = r16(base + 0x10),
            sag = r32(base + 0x20),
            ctrl = r16(base + 0x40),
        }
    end
    return bmods, headers
end

local function analyze_headers(headers)
    local counts = { COMESOON = 0, OLD_ARMORY = 0, BANK1_OTHER = 0, OUTSIDE_BANK1 = 0 }
    local min_sag = nil
    local max_sag = nil
    for _, h in ipairs(headers) do
        local cls = classify_sag(h.sag)
        counts[cls] = counts[cls] + 1
        if min_sag == nil or h.sag < min_sag then min_sag = h.sag end
        if max_sag == nil or h.sag > max_sag then max_sag = h.sag end
    end
    local status = "FAIL"
    if #headers > 0 and counts.COMESOON == #headers then
        status = "PASS_RELOCATED"
    elseif #headers > 0 and counts.OLD_ARMORY == #headers then
        status = "OLD_LOCATION"
    elseif counts.OUTSIDE_BANK1 > 0 then
        status = "BAD_SAG"
    else
        status = "MIXED"
    end
    return status, counts, min_sag or 0, max_sag or 0
end

local function dump_armory_headers(label, verbose)
    local bmods, headers = collect_armory_headers()
    for _, bmod in ipairs(bmods) do
        log("%s %s addr=%s size=%dx%d blocks=%d blks=%s hdrs=%s pals=%s max_hdr=%d",
            label, bmod.label, hx(bmod.addr), bmod.width, bmod.height, bmod.blocks,
            hx(bmod.blks), hx(bmod.hdrs), hx(bmod.pals), block_max_header_index(bmod))
    end
    local status, counts, min_sag, max_sag = analyze_headers(headers)
    log("%s ARMORY_HDR status=%s count=%d min=%s max=%s counts comesoon=%d old=%d other=%d outside=%d",
        label, status, #headers, hx(min_sag), hx(max_sag),
        counts.COMESOON, counts.OLD_ARMORY, counts.BANK1_OTHER, counts.OUTSIDE_BANK1)
    if verbose then
        for _, h in ipairs(headers) do
            log("%s HDR[%02d] size=%dx%d sag=%s ctrl=%04x class=%s",
                label, h.index, h.width, h.height, hx(h.sag), h.ctrl, classify_sag(h.sag))
        end
    end
    final_status = status
    return status
end

local function dump_list_summary(label)
    for list_no = 1, 8 do
        local head_addr = A["baklst" .. list_no]
        local p = r32(head_addr)
        local count = 0
        local comesoon = 0
        local old = 0
        local other = 0
        local outside = 0
        local examples = {}
        while p ~= 0 and count < 160 do
            count = count + 1
            local osag = r32(p + O.osag)
            local oimg = r32(p + O.oimg)
            local img_sag0 = (oimg ~= 0) and r32(oimg) or 0
            local img_sag_bg = (oimg ~= 0) and r32(oimg + 0x20) or 0
            local cls = classify_sag(osag)
            if cls == "COMESOON" then comesoon = comesoon + 1
            elseif cls == "OLD_ARMORY" then old = old + 1
            elseif cls == "BANK1_OTHER" then other = other + 1
            else outside = outside + 1 end
            if #examples < 5 then
                examples[#examples + 1] = string.format(
                    "obj=%s oid=%04x xy=(%d,%d) osag=%s/%s oimg=%s img0=%s imgbg=%s",
                    hx(p), r16(p + O.oid), s16(r16(p + O.oxpos)), s16(r16(p + O.oypos)),
                    hx(osag), cls, hx(oimg), hx(img_sag0), hx(img_sag_bg))
            end
            p = r32(p + O.next)
        end
        log("%s baklst%d count=%d osag_counts comesoon=%d old=%d other=%d outside=%d",
            label, list_no, count, comesoon, old, other, outside)
        for _, e in ipairs(examples) do log("%s baklst%d example %s", label, list_no, e) end
    end
end

local function finish(reason)
    log("DONE reason=%s final_status=%s frame=%d", reason, final_status, frame)
    if logfh then logfh:flush() end
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1

    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("symbols gstate=%s curback=%s arm1=%s arm2=%s arm3=%s",
            hx(A.gstate), hx(A.curback), hx(A.arm1), hx(A.arm2), hx(A.arm3))
        log("target COMESOON window %s..%s old ARMORY window %s..%s",
            hx(COMESOON_START), hx(COMESOON_END), hx(OLD_ARMORY_START), hx(OLD_ARMORY_END))
        dump_armory_headers("boot", true)
        if FORCE_ARMORY_STAGE then
            log("pre-fight curback force enabled target=%d until frame=%d", ARMORY_STAGE, FORCE_STAGE_UNTIL_FRAME)
        end
    end

    if FORCE_ARMORY_STAGE and fighting_frame == 0 and frame <= FORCE_STAGE_UNTIL_FRAME then
        w16(A.curback, ARMORY_STAGE)
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    local g = r16(A.gstate)
    if g ~= last_gstate then
        log("frame=%d gstate %d -> %d curback=%d", frame, last_gstate, g, r16(A.curback))
        last_gstate = g
    end

    if charsel_frame == 0 and g == GS_SELECT then
        charsel_frame = frame
        log("char select begins frame=%d", frame)
    end

    if not stage_select_active and charsel_frame > 0 and frame - charsel_frame > 250 then
        stage_select_active = true
        log("stage select begins frame=%d curback=%d", frame, r16(A.curback))
    end

    if stage_select_active and not stage_confirmed then
        local cb = r16(A.curback)
        if cb ~= last_curback then
            log("stage select curback=%d target=%d", cb, ARMORY_STAGE)
            last_curback = cb
        end
        if cb == ARMORY_STAGE and frame - charsel_frame > 280 then
            stage_confirmed = true
            log("confirming Armory frame=%d", frame)
        end
    end

    if fighting_frame == 0 and g == GS_FIGHTING and r16(A.curback) == ARMORY_STAGE then
        fighting_frame = frame
        log("FIGHT Armory frame=%d p1=%d p2=%d winner=%d", frame, r16(A.p1_char), r16(A.p2_char), r16(A.winner_status))
    end

    if fighting_frame > 0 then
        local t = frame - fighting_frame
        if not dumped_headers and t >= 30 then
            dumped_headers = true
            dump_armory_headers("fight+30", true)
            dump_list_summary("fight+30")
            snap("armory-comesoon-fight+30")
        end
        if t == 180 then
            dump_armory_headers("fight+180", false)
            dump_list_summary("fight+180")
            snap("armory-comesoon-fight+180")
        end
        if t == 420 then
            dump_armory_headers("fight+420", false)
            dump_list_summary("fight+420")
            snap("armory-comesoon-fight+420")
        end
        if t >= 600 then
            finish("sample-complete")
        end
    end

    if frame >= 12000 then
        dump_armory_headers("timeout", true)
        finish("timeout-before-armory-fight")
    end
end)
