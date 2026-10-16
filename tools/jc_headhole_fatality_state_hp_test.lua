-- jc_headhole_fatality_state_hp_test.lua
--
-- Save-state driven Johnny Cage headhole fatality test. Launch MAME with a
-- round-2 Finish Him save state, then this script treats P1 HP as the test-only
-- trigger. A guarded source hook in MOVES.ASM routes that HP through the normal
-- fatality transfer path to do_jc_headhole.

local ROOT = os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")

local LOG_PATH = os.getenv("JC_HEADHOLE_FATALITY_LOG") or (ROOT .. "/tools/jc_headhole_fatality_test.log")
local logfh = io.open(LOG_PATH, "w")

local frame = 0
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

local function log(fmt, ...)
    local msg = (select("#", ...) > 0) and string.format(fmt, ...) or tostring(fmt)
    print("[jcheadhole] " .. msg)
end

local function hx(value)
    if value == nil then return "na" end
    return string.format("0x%08x", value & 0xffffffff)
end

local symbols = {}
do
    local map_path = ROOT .. "/src/mk2.map"
    local fh = io.open(map_path, "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
        log("loaded symbols from %s", map_path)
    else
        log("ERROR could not open %s", map_path)
    end
end

local function sym(name, fallback)
    local v = symbols[name]
    if v ~= nil then return v end
    log("WARN missing symbol %s, using fallback %s", name, hx(fallback or 0))
    return fallback or 0
end

local A = {
    gstate         = sym("gstate", 0x01129d90),
    p1_char        = sym("p1_char", 0x0112a880),
    p2_char        = sym("p2_char", 0x0112b450),
    p1_obj         = sym("p1_obj", 0x0112a820),
    p2_obj         = sym("p2_obj", 0x0112b3f0),
    p1_proc        = sym("p1_proc", 0x0112a860),
    p2_proc        = sym("p2_proc", 0x0112b430),
    p1_bar         = sym("p1_bar", 0x0112a8f0),
    p2_bar         = sym("p2_bar", 0x0112b4c0),
    p1_bar_view    = sym("p1_bar_view", 0x011285f0),
    p2_bar_view    = sym("p2_bar_view", 0x01128530),
    curback        = sym("curback", 0x0112c0d0),
    round_num      = sym("round_num", 0x0112c0f0),
    p1_matchw      = sym("p1_matchw", 0x0112a8c0),
    p2_matchw      = sym("p2_matchw", 0x0112b490),
    winner_status  = sym("winner_status", 0x0112c110),
    f_death        = sym("f_death", 0x0112bfc0),
    f_no_blood     = sym("f_no_blood", 0x0112c070),
    f_no_violence  = sym("f_no_violence", 0x0112c050),
    pf_ram         = sym("pf_ram", 0x0112c0b0),
    worldtlx       = sym("worldtlx", 0x01127430),
    objlst         = sym("objlst", 0x01127570),
    objlst2        = sym("objlst2", 0x01127590),
    objlst3        = sym("objlst3", 0x011275b0),
    do_jc_headhole = sym("do_jc_headhole", 0xff9ed2d0),
    dizzy          = sym("dizzy", 0xffa27e40),
    CAGE_P         = sym("CAGE_P", 0xffbadf70),
    JC2DEATHBLO1A  = sym("JC2DEATHBLO1A", 0),
}

local O = {
    next   = 0x000,
    oxvel  = 0x040,
    oyvel  = 0x060,
    oxval  = 0x080,
    oxpos  = 0x090,
    oyval  = 0x0a0,
    oypos  = 0x0b0,
    oflags = 0x0f0,
    osag   = 0x100,
    osize  = 0x120,
    opal   = 0x140,
    oflags2 = 0x160,
    oimg   = 0x1a0,
    oshape = 0x1d0,
    ochar  = 0x1f0,
}

local P = {
    next      = 0x000,
    id        = 0x020,
    time      = 0x030,
    psptr     = 0x040,
    pa9       = 0x0a0,
    wake      = 0x0e0,
    pa8       = 0x0c0,
    otherguy  = 0x140,
    otherproc = 0x170,
    action    = 0x1f0,
    flags     = 0x210,
    store4    = 0x290,
}

local PRCSIZ = 0x6f0
local FT_CAGE = 2
local FT_KANG = 1
local MAX_HP = 0x00a1
local ACT_STANCE = 0x0303
local PM_REACTING = 0x0004
local PM_SITDUCK = 0x0008
local PM_SPECIAL = 0x0010
local MKBUG_START = 0xffa30000
local MKBUG_END = 0xffa3ffff
local MP_SAG = 0x000
local MP_SIZE = 0x020
local MP_CTRL = 0x040
local MP_ANIX = 0x050
local MP_ANIY = 0x060
local MP_LEN = 0x070

local cpu = nil
local space = nil
local fields = {}
local last_gstate = -1
local ready_frame = 0
local hp_start = 0
local trigger_frame = 0
local fatality_frame = 0
local did_mid_snap = false
local did_final_snap = false
local did_complete = false
local finished = false
local did_error = false

local function r16(addr)
    if not space or addr == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u16(addr) end)
    return ok and v or 0
end

local function r32(addr)
    if not space or addr == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u32(addr) end)
    return ok and v or 0
end

local function w16(addr, value)
    if space and addr ~= 0 then pcall(function() space:write_u16(addr, value & 0xffff) end) end
end

local function w32(addr, value)
    if space and addr ~= 0 then pcall(function() space:write_u32(addr, value & 0xffffffff) end) end
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
    if not s then
        log("SNAP frame=%d label=%s no_screen", frame, label)
        return
    end
    local ok, err = pcall(function() s:snapshot() end)
    log("SNAP frame=%d label=%s ok=%s %s", frame, label, tostring(ok), ok and "" or tostring(err))
end

local function cache_fields()
    local wanted = {
        ["P1 High Punch"] = true,
        ["UI Select"] = true,
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

local function count_list(head_addr)
    local p = r32(head_addr)
    local count = 0
    local seen = {}
    while p ~= 0 and count < 256 and not seen[p] do
        seen[p] = true
        count = count + 1
        p = r32(p + O.next)
    end
    return count
end

local function position_for_fatality()
    local p1obj = r32(A.p1_obj)
    local p2obj = r32(A.p2_obj)
    if p1obj == 0 or p2obj == 0 then return false end

    local world_left = r16(A.worldtlx + 16)
    if world_left == 0xffff then world_left = 0 end
    local p1x = world_left + 136
    local p2x = p1x + 0x38
    local y = r16(p2obj + O.oypos)
    if y == 0 then y = r16(p1obj + O.oypos) end

    w16(p1obj + O.oxpos, p1x)
    w32(p1obj + O.oxval, p1x << 16)
    w32(p1obj + O.oxvel, 0)
    w32(p1obj + O.oyvel, 0)
    w16(p2obj + O.oxpos, p2x)
    w32(p2obj + O.oxval, p2x << 16)
    w32(p2obj + O.oxvel, 0)
    w32(p2obj + O.oyvel, 0)
    if y ~= 0 then
        w16(p1obj + O.oypos, y)
        w32(p1obj + O.oyval, y << 16)
        w16(p2obj + O.oypos, y)
        w32(p2obj + O.oyval, y << 16)
    end
    return true
end

local function normalize_player_links()
    local p1obj = r32(A.p1_obj)
    local p2obj = r32(A.p2_obj)
    local p1proc = r32(A.p1_proc)
    local p2proc = r32(A.p2_proc)
    if p1proc == 0 or p2proc == 0 or p1obj == 0 or p2obj == 0 then return false end

    w32(p1proc + P.otherguy, p2obj)
    w32(p1proc + P.otherproc, p2proc)
    w32(p1proc + P.store4, p1proc)
    w32(p2proc + P.otherguy, p1obj)
    w32(p2proc + P.otherproc, p1proc)
    w32(p2proc + P.store4, p2proc)
    return true
end

local function clear_blocking_flags(proc)
    local flags = r16(proc + P.flags)
    flags = flags & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL)
    w16(proc + P.flags, flags)
end

local function state_ready()
    return r32(A.p1_obj) ~= 0
       and r32(A.p2_obj) ~= 0
       and r32(A.p1_proc) ~= 0
       and r32(A.p2_proc) ~= 0
       and r16(A.p1_char) == FT_CAGE
end

local function pstate_summary()
    local p1obj = r32(A.p1_obj)
    local p2obj = r32(A.p2_obj)
    local p1proc = r32(A.p1_proc)
    local p2proc = r32(A.p2_proc)
    local p1act = p1proc ~= 0 and r16(p1proc + P.action) or 0xffff
    local p1flags = p1proc ~= 0 and r16(p1proc + P.flags) or 0xffff
    local p2flags = p2proc ~= 0 and r16(p2proc + P.flags) or 0xffff
    local p1time = p1proc ~= 0 and r16(p1proc + P.time) or 0xffff
    local p1wake = p1proc ~= 0 and r32(p1proc + P.wake) or 0
    local p1pa9 = p1proc ~= 0 and r32(p1proc + P.pa9) or 0
    local p2wake = p2proc ~= 0 and r32(p2proc + P.wake) or 0
    local p1x, p1y, p2x, p2y, p1sag, p2sag = 0, 0, 0, 0, 0, 0
    if p1obj ~= 0 then
        p1x = r16(p1obj + O.oxpos)
        p1y = r16(p1obj + O.oypos)
        local img = r32(p1obj + O.oimg)
        if img ~= 0 then p1sag = r32(img) end
    end
    if p2obj ~= 0 then
        p2x = r16(p2obj + O.oxpos)
        p2y = r16(p2obj + O.oypos)
        local img = r32(p2obj + O.oimg)
        if img ~= 0 then p2sag = r32(img) end
    end
    return string.format(
        "gs=%d stage=%d round=%d mw=%d/%d ws=%d fd=0x%04x p1=%d p2=%d act=0x%04x flags=0x%04x/0x%04x p1twake=%d/%s pa9=%s xy=%d,%d/%d,%d sag=%s/%s p2wake=%s obj=%d/%d/%d pc=%s pf=%s",
        r16(A.gstate), r16(A.curback), r16(A.round_num), r16(A.p1_matchw), r16(A.p2_matchw),
        r16(A.winner_status), r16(A.f_death), r16(A.p1_char), r16(A.p2_char), p1act,
        p1flags, p2flags, p1time, hx(p1wake), hx(p1pa9), p1x, p1y, p2x, p2y, hx(p1sag), hx(p2sag), hx(p2wake),
        count_list(A.objlst), count_list(A.objlst2), count_list(A.objlst3),
        hx(cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")), hx(r32(A.pf_ram)))
end

local function log_multipart(label)
    local obj = r32(A.p1_obj)
    if obj == 0 then
        log("mp %s no_p1_obj", label)
        return
    end

    local img = r32(obj + O.oimg)
    local shape = r32(obj + O.oshape)
    local first_header = shape ~= 0 and r32(shape) or 0
    local first_icmap = first_header ~= 0 and r32(first_header + 0x70) or 0
    log("mp %s obj=%s img=%s shape=%s first_hdr=%s hdr_icmap=%s cage_p=%s opal=0x%04x flags=0x%04x flags2=0x%04x osag=%s osize=%s",
        label, hx(obj), hx(img), hx(shape), hx(first_header), hx(first_icmap), hx(A.CAGE_P),
        r16(obj + O.opal), r16(obj + O.oflags), r16(obj + O.oflags2),
        hx(r32(obj + O.osag)), hx(r32(obj + O.osize)))

    if img == 0 then return end
    for i = 0, 3 do
        local node = img + (i * MP_LEN)
        local sag = r32(node + MP_SAG)
        if sag == 0 then
            log("mp %s node%d end", label, i)
            break
        end
        log("mp %s node%d sag=%s size=%s ctrl=0x%04x anix=%d aniy=%d",
            label, i, hx(sag), hx(r32(node + MP_SIZE)),
            r16(node + MP_CTRL), r16(node + MP_ANIX), r16(node + MP_ANIY))
    end
end

local function force_finish_context()
    position_for_fatality()
    normalize_player_links()

    w16(A.f_no_blood, 0)
    w16(A.f_no_violence, 0)
    w16(A.winner_status, 3)
    w16(A.f_death, 0)
    w16(A.p1_bar, MAX_HP)
    w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, 0)
    w16(A.p2_bar_view, 0)

    local p1proc = r32(A.p1_proc)
    local p2proc = r32(A.p2_proc)
    if p1proc ~= 0 then
        clear_blocking_flags(p1proc)
        w16(p1proc + P.action, ACT_STANCE)
    end
    if p2proc ~= 0 then
        clear_blocking_flags(p2proc)
        w32(p2proc + P.wake, A.dizzy)
    end
end

local function trigger_headhole()
    if trigger_frame ~= 0 then return end
    if not state_ready() then
        log("ERROR hp_trigger_not_ready %s", pstate_summary())
        did_error = true
        snap("hp_trigger_not_ready")
        manager.machine:exit()
        return
    end

    force_finish_context()
    trigger_frame = frame
    log("hp_trigger_input frame=%d %s", frame, pstate_summary())
    snap("hp_trigger_input")
end

local function log_state(force)
    if not space then return end
    if not force and frame % 30 ~= 0 then return end
    log("state frame=%d %s", frame, pstate_summary())
end

local function check_lockup()
    if did_error or not space then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local pf = r32(A.pf_ram)
    if pc and pc >= MKBUG_START and pc <= MKBUG_END then
        did_error = true
        log("ERROR system_lockup pc=%s pf=%s %s", hx(pc), hx(pf), pstate_summary())
        snap("system_lockup")
        manager.machine:exit()
        return true
    end
    if pf == 0xffffffff then
        did_error = true
        log("ERROR pf_ram_all_ones pc=%s %s", hx(pc), pstate_summary())
        snap("pf_ram_all_ones")
        manager.machine:exit()
        return true
    end
    return false
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log_state(true)
    snap(ok and "pass_final" or ("error_" .. reason))
    if ok then
        log("PASS reason=%s fatality_frame=%d complete=%s", reason, fatality_frame, tostring(did_complete))
    else
        log("ERROR reason=%s fatality_frame=%d complete=%s", reason, fatality_frame, tostring(did_complete))
    end
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function pressed(name)
    if name == "P1 High Punch" and hp_start > 0 then
        return frame >= hp_start and frame < hp_start + 24
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1

    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("loaded: save-state HP trigger harness for do_jc_headhole")
    end

    if space then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            log("frame=%d gstate %d -> %d", frame, last_gstate, gs)
            last_gstate = gs
        end

        if ready_frame == 0 and state_ready() and frame > 20 then
            ready_frame = frame
            hp_start = frame + 30
            log("state_ready frame=%d hp_start=%d %s", frame, hp_start, pstate_summary())
            snap("state_ready")
        end

        if hp_start > 0 and frame == hp_start then
            log("hp_press frame=%d", frame)
            trigger_headhole()
        end

        local fdeath = r16(A.f_death)
        if fdeath == 2 and fatality_frame == 0 then
            fatality_frame = frame
            log("fatality_started frame=%d %s", frame, pstate_summary())
            log_multipart("fatality_start")
            snap("fatality_start")
        end

        if fatality_frame > 0 then
            local rel = frame - fatality_frame
            if rel >= 70 and not did_mid_snap then
                did_mid_snap = true
                log("fatality_mid frame=%d rel=%d %s", frame, rel, pstate_summary())
                log_multipart("fatality_mid")
                snap("fatality_mid")
            end
            if rel >= 190 and not did_final_snap then
                did_final_snap = true
                log("fatality_final_anim frame=%d rel=%d %s", frame, rel, pstate_summary())
                log_multipart("fatality_final_anim")
                snap("fatality_final_anim")
            end
            if fdeath == 0xffff then
                did_complete = true
            end
            if rel >= 760 then
                if did_mid_snap and did_final_snap and did_complete and not did_error then
                    finish(true, "fatality_completed_no_crash")
                elseif not did_complete then
                    finish(false, "fatality_never_completed")
                else
                    finish(false, "missing_snap_or_error")
                end
                return
            end
        end

        if trigger_frame > 0 and fatality_frame == 0 and frame - trigger_frame > 180 then
            finish(false, "fatality_never_started")
            return
        end

        if ready_frame == 0 and frame > 1200 then
            finish(false, "state_never_ready")
            return
        end

        log_state(false)
        if check_lockup() then return end
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    if frame > 9000 then
        finish(false, "global_timeout")
    end
end)

emu.register_stop(function()
    log("stopped frame=%d finished=%s error=%s fatality_frame=%d complete=%s",
        frame, tostring(finished), tostring(did_error), fatality_frame, tostring(did_complete))
    if logfh then
        logfh:flush()
        logfh:close()
    end
end)
