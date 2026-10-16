-- reptile_tongue_fatality_test.lua
-- Selects P1 Reptile, forces a controlled Finish Him window, performs
-- Reptile DB1 (Back, Back, Down + LP in this source handler; MOVES.ASM stores it in reverse
-- queue-read order), and snapshots the
-- tongue/retract/chomp phase where background smear has been seen.

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/reptile_tongue_fatality_test.log", "w")
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
local fight_count = 0
local p1_confirm_start = 0
local finish_frame = 0
local fatality_frame = 0
local last_gstate = -1
local last_winner_status = -1
local did_select_log = false
local did_force_round1 = false
local did_force_finish = false
local did_input_log = false
local did_queue_pre_log = false
local did_queue_post_log = false
local did_final = false
local did_error = false
local snaps = {}

local ACTIVE   = 0x010dc6d0
local FREE     = 0x010dc6f0
local GSTATE   = 0x01129dc0
local P1_CHAR  = 0x01129e70
local P2_CHAR  = 0x0112aa40
local P1_OBJ   = 0x01129e10
local P2_OBJ   = 0x0112a9e0
local P1_PROC  = 0x01129e50
local P2_PROC  = 0x0112aa20
local P1_BAR   = 0x01129ee0
local P2_BAR   = 0x0112aab0
local P1_BCQ   = 0x01129f30
local P1_JCQ   = 0x0112a1d0
local P1_MATCHW = 0x01129f00
local P2_MATCHW = 0x0112aad0
local ROUND_NUM = 0x0112b6f0
local TICK     = 0x01126c70
local F_DEATH  = 0x0112b5b0
local WINNER_STATUS = 0x0112b700
local WORLDTLX = 0x01126f20
local WORLDTLY = 0x01126d00
local OBJLST   = 0x01127060
local OBJLST2  = 0x01127080

local PROC_NEXT   = 0x000
local PROC_ID     = 0x020
local PROC_ACTION = 0x1f0
local OBJ_NEXT    = 0x000
local OBJ_OSLINK  = 0x020
local OBJ_OXPOS   = 0x090
local OBJ_OYPOS   = 0x0b0
local OBJ_OIMG    = 0x1a0
local OBJ_OCHAR   = 0x1f0

local PROC_MIN = 0x010dc740
local PROC_MAX = 0x01150000
local PROC_WAKE = 0x0e0

local GS_PSEL     = 4
local GS_POST     = 0x0d
local GS_FIGHTING = 2
local FT_REPTILE  = 9
local FT_JAX      = 11
local DIZZY_ADDR  = 0xffa0ba50

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 Down"] = true,
        ["P1 Left"] = true,
        ["P1 Right"] = true,
        ["P1 High Punch"] = true,
        ["P1 Low Punch"] = true,
        ["P2 Down"] = true,
        ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[rp-tongue] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
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
    if snaps[label] then return end
    snaps[label] = true
    local s = main_screen()
    if s then
        local ok, err = pcall(function() s:snapshot() end)
        print(string.format("[rp-tongue] SNAP frame=%d label=%s ok=%s %s", frame, label, tostring(ok), ok and "" or tostring(err)))
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

local function rw(addr) return space:read_u16(addr) end
local function ww(addr, value) space:write_u16(addr, value % 0x10000) end
local function wl(addr, value) space:write_u32(addr, value) end

local function count_list(addr)
    local p = space:read_u32(addr)
    local count = 0
    local seen = {}
    while p ~= 0 and p >= 0x01000000 and p < 0x01200000 and not seen[p] and count < 256 do
        seen[p] = true
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

local function dump_obj_list(addr, label)
    local p = space:read_u32(addr)
    local count = 0
    local seen = {}
    while p ~= 0 and p >= 0x01000000 and p < 0x01200000 and not seen[p] and count < 50 do
        seen[p] = true
        count = count + 1
        print(string.format("[rp-tongue] %s obj%d=%s next=%s img=%s oslink=%s char=%d xy=%d,%d",
            label, count, hx(p), hx(space:read_u32(p + OBJ_NEXT)),
            hx(space:read_u32(p + OBJ_OIMG)), hx(space:read_u32(p + OBJ_OSLINK)),
            rw(p + OBJ_OCHAR), rw(p + OBJ_OXPOS), rw(p + OBJ_OYPOS)))
        p = space:read_u32(p + OBJ_NEXT)
    end
    print(string.format("[rp-tongue] %s dumped=%d next=%s", label, count, hx(p)))
end

local function dump_queue(addr, label)
    local nextp = space:read_u32(addr)
    print(string.format("[rp-tongue] %s queue=%s next=%s", label, hx(addr), hx(nextp)))
    local p = nextp
    for i = 1, 6 do
        p = p - 32
        if p <= addr then p = addr + 32 * 20 end
        local v = space:read_u32(p)
        local sw = math.floor(v / 0x10000)
        local t = v % 0x10000
        print(string.format("[rp-tongue] %s q-%d ptr=%s raw=%s sw=%d tick=%d age=%d",
            label, i, hx(p), hx(v), sw, t, (rw(TICK) - t) % 0x10000))
    end
end

local function log_state(force)
    if not space or (not force and frame % 30 ~= 0) then return end
    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    local p1proc = space:read_u32(P1_PROC)
    local p2proc = space:read_u32(P2_PROC)
    local p1act = p1proc ~= 0 and rw(p1proc + PROC_ACTION) or 0xffff
    local p2act = p2proc ~= 0 and rw(p2proc + PROC_ACTION) or 0xffff
    local p2wake = p2proc ~= 0 and space:read_u32(p2proc + PROC_WAKE) or 0
    local p1x, p1y, p2x, p2y, p1sag, p2sag = 0, 0, 0, 0, 0, 0
    if p1obj ~= 0 then
        p1x = rw(p1obj + OBJ_OXPOS); p1y = rw(p1obj + OBJ_OYPOS)
        local img = space:read_u32(p1obj + OBJ_OIMG)
        if img ~= 0 then p1sag = space:read_u32(img) end
    end
    if p2obj ~= 0 then
        p2x = rw(p2obj + OBJ_OXPOS); p2y = rw(p2obj + OBJ_OYPOS)
        local img = space:read_u32(p2obj + OBJ_OIMG)
        if img ~= 0 then p2sag = space:read_u32(img) end
    end
    print(string.format(
        "[rp-tongue] frame=%d fight=%d round=%d mw=%d/%d gs=%d ws=%d fd=%d p1=%d p2=%d act=%04x/%04x xy=%d,%d/%d,%d dist=%d hp=%d/%d world=%d,%d obj=%d/%d procs=%d/%d sag=%s/%s pc=%s",
        frame, fight_count, rw(ROUND_NUM), rw(P1_MATCHW), rw(P2_MATCHW),
        rw(GSTATE), rw(WINNER_STATUS), rw(F_DEATH), rw(P1_CHAR), rw(P2_CHAR),
        p1act, p2act, p1x, p1y, p2x, p2y, math.abs(p2x - p1x), rw(P1_BAR), rw(P2_BAR),
        rw(WORLDTLX), rw(WORLDTLY), count_list(OBJLST), count_list(OBJLST2),
        count_procs(ACTIVE), count_procs(FREE), hx(p1sag), hx(p2sag), hx(cpu_reg("PC"))))
    print(string.format("[rp-tongue] frame=%d p2proc=%s p2wake=%s dizzy=%s",
        frame, hx(p2proc), hx(p2wake), hx(DIZZY_ADDR)))
end

local function force_tongue_range()
    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    if p1obj ~= 0 and p2obj ~= 0 then
        ww(p1obj + OBJ_OXPOS, 90)
        ww(p2obj + OBJ_OXPOS, 282) -- 0xc0 distance, inside 0xa0..0xe0 check
    end
end

local function force_victim_dizzy()
    local p2proc = space:read_u32(P2_PROC)
    if p2proc ~= 0 then
        wl(p2proc + PROC_WAKE, DIZZY_ADDR)
    end
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
        if name == "P2 Down" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 45 and frame < p1_confirm_start + 53
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 90 and frame < p1_confirm_start + 130
        end
    end

    if finish_frame > 0 and fatality_frame == 0 then
        local r = frame - finish_frame
        if name == "P1 Left" then return (r >= 72 and r < 77) or (r >= 84 and r < 89) end
        if name == "P1 Down" then return r >= 96 and r < 101 end
        if name == "P1 Low Punch" then return r >= 116 and r < 150 end
    end
    return false
end

local function check_bad_state()
    if did_error or not space or fighting_frame == 0 then return false end
    local obj_count = count_list(OBJLST)
    if obj_count > 140 then
        did_error = true
        log_state(true)
        dump_obj_list(OBJLST, "objlst_bad")
        snap("bad_object_count")
        print(string.format("[rp-tongue] ERROR obj_count=%d", obj_count))
        manager.machine:exit()
        return true
    end
    local pc = cpu_reg("PC")
    if pc == 0 or pc == 0xffffffff then
        did_error = true
        log_state(true)
        dump_obj_list(OBJLST, "objlst_badpc")
        snap("bad_pc")
        print(string.format("[rp-tongue] ERROR bad pc=%s", hx(pc)))
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
        print("[rp-tongue] loaded: selecting P1 Reptile vs P2 Jax, forcing round 1 win, then round 2 Finish Him + B,B,D+HP")
    end

    if space then
        local gs = rw(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[rp-tongue] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
                fight_count = fight_count + 1
                fighting_frame = frame
                print(string.format("[rp-tongue] fight %d started at frame=%d round=%d matchw=%d/%d",
                    fight_count, frame, rw(ROUND_NUM), rw(P1_MATCHW), rw(P2_MATCHW)))
                log_state(true)
                snap("fight_" .. tostring(fight_count) .. "_start")
            end
            last_gstate = gs
        end

        local ws = rw(WINNER_STATUS)
        if ws ~= last_winner_status then
            print(string.format("[rp-tongue] frame=%d winner_status %d -> %d", frame, last_winner_status, ws))
            last_winner_status = ws
        end

        if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0
           and frame - charsel_frame > 225 and rw(P1_CHAR) == FT_REPTILE then
            p1_confirm_start = frame
            print(string.format("[rp-tongue] p1 Reptile reached at frame=%d; confirming", frame))
        end
        if charsel_frame > 0 and not did_select_log and frame - charsel_frame >= 320 then
            did_select_log = true
            print(string.format("[rp-tongue] pre-confirm p1_char=%d want=%d p2_char=%d want=%d",
                rw(P1_CHAR), FT_REPTILE, rw(P2_CHAR), FT_JAX))
        end

        if fight_count == 1 and fighting_frame > 0 and not did_force_round1 and frame - fighting_frame > 120 then
            did_force_round1 = true
            force_tongue_range()
            ww(P2_BAR, 0)
            ww(WINNER_STATUS, 3)
            print(string.format("[rp-tongue] forced round 1 win at frame=%d", frame))
            log_state(true)
            snap("round1_forced")
        end

        if fight_count == 2 and fighting_frame > 0 and not did_force_finish and frame - fighting_frame > 120 then
            did_force_finish = true
            finish_frame = frame
            force_tongue_range()
            ww(P2_BAR, 0)
            ww(WINNER_STATUS, 3)
            force_victim_dizzy()
            print(string.format("[rp-tongue] forced round 2 Finish Him at frame=%d", frame))
            log_state(true)
            snap("finish_forced")
        end

        if finish_frame > 0 and fatality_frame == 0 and frame - finish_frame < 180 then
            force_tongue_range()
            ww(WINNER_STATUS, 3)
            force_victim_dizzy()
        end

        if finish_frame > 0 and not did_input_log and frame - finish_frame >= 162 then
            did_input_log = true
            print(string.format("[rp-tongue] combo input window complete at frame=%d", frame))
            log_state(true)
            dump_queue(P1_JCQ, "after_combo_jcq")
            snap("after_combo")
        end

        if finish_frame > 0 and fatality_frame == 0 and not did_queue_pre_log and frame - finish_frame >= 112 then
            did_queue_pre_log = true
            dump_queue(P1_JCQ, "before_finisher_jcq")
            dump_queue(P1_BCQ, "before_finisher_bcq")
        end

        if finish_frame > 0 and fatality_frame == 0 and not did_queue_post_log and frame - finish_frame >= 152 then
            did_queue_post_log = true
            dump_queue(P1_JCQ, "after_finisher_jcq")
            dump_queue(P1_BCQ, "after_finisher_bcq")
        end

        if fatality_frame == 0 and finish_frame > 0 and rw(F_DEATH) ~= 0 then
            fatality_frame = frame
            print(string.format("[rp-tongue] fatality started frame=%d f_death=%d", frame, rw(F_DEATH)))
            log_state(true)
            snap("fatality_start")
        end

        if fatality_frame > 0 then
            local r = frame - fatality_frame
            if r >= 70 then snap("tongue_extend") end
            if r >= 135 then snap("tongue_retract") end
            if r >= 205 then snap("head_chomp") end
            if r >= 300 then snap("yum_phase") end
            if r >= 430 and not did_final then
                did_final = true
                log_state(true)
                dump_obj_list(OBJLST, "objlst_final")
                snap("final")
                print("[rp-tongue] finished")
                manager.machine:exit()
            end
        end

        if check_bad_state() then return end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    log_state(false)

    if fight_count < 2 and fighting_frame > 0 and frame - fighting_frame > 3200 then
        log_state(true)
        snap("round2_not_reached")
        print("[rp-tongue] ERROR round 2 never reached")
        manager.machine:exit()
    end

    if did_force_finish and frame - finish_frame > 1500 and fatality_frame == 0 then
        log_state(true)
        dump_obj_list(OBJLST, "objlst_no_fatality")
        snap("fatality_not_started")
        print("[rp-tongue] ERROR fatality never started")
        manager.machine:exit()
    end

    if frame > 9000 then
        log_state(true)
        snap("timeout")
        print("[rp-tongue] ERROR timeout")
        manager.machine:exit()
    end
end)
