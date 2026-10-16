-- armory_stockcopy_direct_load_20260708.lua
--
-- Fresh direct-load Armory stock-copy test. Forces curback=5 before the match
-- is built, then verifies active Armory SAGs and runtime background objects live
-- in the retired COMESOON bank-1 window instead of the old ARMORY1 range.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local LOG_PATH = os.getenv("ARMORY_DIRECT_LOG") or (ROOT .. "/tools/armory_stockcopy_direct_load_20260708.log")
local logfh = io.open(LOG_PATH, "w")

local function log(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
    local line = string.format("[armory-stockcopy-20260708] %s", msg)
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

local GS_FIGHTING = 2
local GS_SELECT = 4
local ARMORY_STAGE = 5
local FT_KANG = 1
local FT_CAGE = 2

local COMESOON_START = 0x05e43418
local COMESOON_END = 0x05f50574
local OLD_ARMORY_START = 0x0597aa01
local OLD_ARMORY_END = 0x059f3bd7
local BANK1_START = 0x04000000
local BANK1_END = 0x06000000

local fields = {}
local cpu = nil
local space = nil
local frame = 0
local charsel_frame = 0
local fighting_frame = 0
local last_gstate = -1
local did_direct_select = false
local did_dump = {}
local final_status = "UNKNOWN"
local failed = false

local function r16(addr)
    if not space or not addr or addr == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u16(addr) end)
    return ok and v or 0
end

local function r32(addr)
    if not space or not addr or addr == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u32(addr) end)
    return ok and v or 0
end

local function w16(addr, value)
    if not space or not addr or addr == 0 then return end
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
        log("SNAP frame=%d label=%s no_screen", frame, label)
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
        ["2 Players Start"] = true,
        ["P1 High Punch"] = true,
        ["P2 High Punch"] = true,
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
        local rel = frame - charsel_frame
        if name == "P1 High Punch" then return rel >= 90 and rel < 130 end
        if name == "P2 High Punch" then return rel >= 150 and rel < 190 end
    end
    return false
end

local function force_armory_match()
    w16(A.p1_char, FT_KANG)
    w16(A.p2_char, FT_CAGE)
    w16(A.curback, ARMORY_STAGE)
    if not did_direct_select then
        did_direct_select = true
        log("direct_select frame=%d p1=%d p2=%d curback=%d", frame, r16(A.p1_char), r16(A.p2_char), r16(A.curback))
    end
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
    for _ = 0, bmod.blocks - 1 do
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
    return headers, bmods
end

local function analyze_headers(headers)
    local counts = { COMESOON = 0, OLD_ARMORY = 0, BANK1_OTHER = 0, OUTSIDE_BANK1 = 0 }
    local min_sag = nil
    local max_sag = nil
    for _, h in ipairs(headers) do
        counts[classify_sag(h.sag)] = counts[classify_sag(h.sag)] + 1
        if not min_sag or h.sag < min_sag then min_sag = h.sag end
        if not max_sag or h.sag > max_sag then max_sag = h.sag end
    end
    local status = "FAIL"
    if #headers > 0 and counts.COMESOON == #headers and counts.OLD_ARMORY == 0 then
        status = "PASS_RELOCATED"
    end
    return status, counts, min_sag or 0, max_sag or 0
end

local function dump_armory_headers(label, verbose)
    local headers, bmods = collect_armory_headers()
    for _, bmod in ipairs(bmods) do
        log("%s %s size=%dx%d blocks=%d blks=%s hdrs=%s pals=%s",
            label, bmod.label, bmod.width, bmod.height, bmod.blocks,
            hx(bmod.blks), hx(bmod.hdrs), hx(bmod.pals))
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
            local cls = classify_sag(osag)
            if cls == "COMESOON" then comesoon = comesoon + 1
            elseif cls == "OLD_ARMORY" then old = old + 1
            elseif cls == "BANK1_OTHER" then other = other + 1
            else outside = outside + 1 end
            if #examples < 4 then
                local oimg = r32(p + O.oimg)
                local img_sag0 = (oimg ~= 0) and r32(oimg) or 0
                examples[#examples + 1] = string.format(
                    "obj=%s oid=%04x xy=(%d,%d) osag=%s/%s oimg=%s img0=%s",
                    hx(p), r16(p + O.oid), s16(r16(p + O.oxpos)), s16(r16(p + O.oypos)),
                    hx(osag), cls, hx(oimg), hx(img_sag0))
            end
            p = r32(p + O.next)
        end
        log("%s baklst%d count=%d osag_counts comesoon=%d old=%d other=%d outside=%d",
            label, list_no, count, comesoon, old, other, outside)
        for _, e in ipairs(examples) do log("%s baklst%d example %s", label, list_no, e) end
    end
end

local function finish(reason)
    log("DONE reason=%s final_status=%s frame=%d gstate=%d curback=%d",
        reason, final_status, frame, r16(A.gstate), r16(A.curback))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function fail(reason)
    if failed then return end
    failed = true
    log("ERROR %s", reason)
    dump_armory_headers("failure", true)
    dump_list_summary("failure")
    snap("failure")
    finish(reason)
end

emu.register_frame(function()
    frame = frame + 1

    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("log_path=%s", LOG_PATH)
        log("symbols gstate=%s curback=%s arm1=%s arm2=%s arm3=%s",
            hx(A.gstate), hx(A.curback), hx(A.arm1), hx(A.arm2), hx(A.arm3))
        log("target COMESOON window %s..%s old ARMORY window %s..%s",
            hx(COMESOON_START), hx(COMESOON_END), hx(OLD_ARMORY_START), hx(OLD_ARMORY_END))
        dump_armory_headers("boot", true)
    end

    if space and fighting_frame == 0 then
        w16(A.curback, ARMORY_STAGE)
    end

    local g = r16(A.gstate)
    if g ~= last_gstate then
        log("frame=%d gstate %d -> %d curback=%d", frame, last_gstate, g, r16(A.curback))
        last_gstate = g
        if g == GS_SELECT and charsel_frame == 0 then
            charsel_frame = frame
            log("char select begins frame=%d", frame)
        end
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        force_armory_match()
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    if fighting_frame == 0 and g == GS_FIGHTING then
        fighting_frame = frame
        log("FIGHT frame=%d curback=%d p1=%d p2=%d winner=%d",
            frame, r16(A.curback), r16(A.p1_char), r16(A.p2_char), r16(A.winner_status))
        if r16(A.curback) ~= ARMORY_STAGE then
            fail("fight_started_on_wrong_stage")
            return
        end
    end

    if fighting_frame > 0 and not failed then
        local rel = frame - fighting_frame
        if (rel == 30 or rel == 180 or rel == 420 or rel == 720) and not did_dump[rel] then
            did_dump[rel] = true
            local label = "fight+" .. tostring(rel)
            local status = dump_armory_headers(label, rel == 30)
            dump_list_summary(label)
            snap(label)
            if status ~= "PASS_RELOCATED" then
                fail("armory_headers_not_relocated_" .. tostring(rel))
                return
            end
        end
        if rel >= 780 then
            finish("direct-load-sample-complete")
            return
        end
    end

    if frame % 300 == 0 then
        log("heartbeat frame=%d gstate=%d curback=%d", frame, r16(A.gstate), r16(A.curback))
    end

    if frame >= 8000 then
        fail("timeout_before_armory_fight")
        return
    end
end)

emu.register_stop(function()
    if space then
        log("stopped frame=%d gstate=%d curback=%d final_status=%s",
            frame, r16(A.gstate), r16(A.curback), final_status)
    else
        log("stopped frame=%d no_program_space final_status=%s", frame, final_status)
    end
    if logfh then
        logfh:flush()
        logfh:close()
        logfh = nil
    end
end)
