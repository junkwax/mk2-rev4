-- baraka_spark_round2_test.lua
-- Selects P1 Baraka vs P2 Jax, makes Baraka win by landing real attacks,
-- then watches Baraka's round-win/victory cleanup and the transition to round 2.

local frame = 0
local log_path = "C:/Users/you/Workplace/mk2-main/tools/baraka_spark_round2_test.log"
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
local fight_count = 0
local fighting_frame = 0
local p1_confirm_start = 0
local last_gstate = -1
local did_select_log = false
local did_spark_seen = false
local did_prime_victim = false
local did_attack_ko = false
local did_roundover_log = false
local did_round2_log = false
local did_error = false
local last_slave = 0
local last_p2_bar = -1
local last_master_sig = ""
local last_master_dump_frame = 0
local ONE_PLAYER_TEST = true
local FORCE_NON_FLAWLESS = true
local DIRECT_CHARACTER_SELECT = true
local did_force_non_flawless = false
local did_direct_select = false

local ACTIVE   = 0x010dc6d0
local GSTATE   = 0x01129d90
local P1_CHAR  = 0x01129e40
local P2_CHAR  = 0x0112aa10
local P1_OBJ   = 0x01129de0
local P2_OBJ   = 0x0112a9b0
local P1_PROC  = 0x01129e20
local P2_PROC  = 0x0112a9f0
local P1_BAR   = 0x01129eb0
local P2_BAR   = 0x0112aa80
local P1_MATCHW = 0x01129ed0
local P2_MATCHW = 0x0112aaa0
local WINNER_STATUS = 0x0112b6d0
local F_THATSALL = 0x0112b660
local PF_RAM   = 0x0112b660
local F_DEATH  = 0x0112b580
local ROUND_NUM = 0x0112b6c0
local P1_RWON  = 0x0112b740
local P2_RWON  = 0x0112b750
local OBJLST   = 0x01127030
local OBJLST2  = 0x01127050
local OBJLST3  = 0x01127070
local OFREE    = 0x01129cf0
local TIMER    = 0x010dc710
local TICK     = 0x01126c40
local DISPLAYON = 0x01126c60
local INTENB   = 0x0c0000110
local INTPEND  = 0x0c0000120

local PROC_NEXT   = 0x000
local PROC_ID     = 0x020
local PROC_TIME   = 0x030
local PROC_STACK  = 0x040
local PROC_WAKE   = 0x0e0
local PROC_ANICOUNT = 0x1e0
local PROC_SLAVE  = 0x190
local PROC_ACTION = 0x1f0
local PROC_STORE1 = 0x230
local PROC_STORE2 = 0x250
local PROC_STORE3 = 0x270
local PROC_STORE4 = 0x290
local PROC_STORE5 = 0x2b0
local PROC_STORE6 = 0x2d0
local PROC_STORE7 = 0x2f0
local PROC_STORE8 = 0x310
local PROC_PA8    = 0x0c0

local OBJ_NEXT    = 0x000
local OBJ_OSLINK  = 0x020
local OBJ_OXVEL   = 0x040
local OBJ_OYVEL   = 0x060
local OBJ_OXPOS   = 0x090
local OBJ_OYPOS   = 0x0b0
local OBJ_OSIZEX  = 0x120
local OBJ_OIMG    = 0x1a0
local OBJ_OID     = 0x1c0
local OBJ_OCHAR   = 0x1f0

local PID_MASTER  = 0x0003
local GS_PSEL     = 4
local GS_POST     = 0x0d
local GS_FIGHTING = 2
local FT_BARAKA   = 3
local FT_JAX      = 11
local PID_PROJ1   = 0x0700
local ACT_SPARK   = 0x0007
local MKBUG_START = 0xffa30000
local MKBUG_END   = 0xffa3ffff
local BONUS_EXIT_RETP = 0xff81f140
local master_stuck_start = 0
local master_stuck_sig = ""

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
        ["P1 Low Kick"] = true,
        ["P2 Down"] = true,
        ["P2 High Punch"] = true,
        ["P2 Block"] = true,
        ["P2 Block 2"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then
                fields[field.name] = field
            end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[spark2] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
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
        print(string.format("[spark2] SNAP frame=%d label=%s ok=%s %s",
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
    return string.format("0x%08x", value & 0xffffffff)
end

local function s16(value)
    value = value & 0xffff
    if value >= 0x8000 then return value - 0x10000 end
    return value
end

local function list_contains(head_addr, target)
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

local function count_list(head_addr)
    if not space then return 0 end
    local p = space:read_u32(head_addr)
    local count = 0
    while p ~= 0 and count < 256 do
        count = count + 1
        p = space:read_u32(p + OBJ_NEXT)
    end
    return count
end

local function list_name_for(target)
    if target == 0 then return "none" end
    local names = {
        { "obj1", OBJLST },
        { "obj2", OBJLST2 },
        { "obj3", OBJLST3 },
        { "free", OFREE },
    }
    local hits = {}
    for _, entry in ipairs(names) do
        if list_contains(entry[2], target) then
            hits[#hits + 1] = entry[1]
        end
    end
    if #hits == 0 then return "none" end
    return table.concat(hits, "+")
end

local function dump_obj_list(label, head_name, head_addr, limit)
    if not space then return end
    limit = limit or 80
    print(string.format("[spark2] dump %s %s head=%s",
        label, head_name, hx(space:read_u32(head_addr))))
    local p = space:read_u32(head_addr)
    local seen = {}
    local guard = 0
    while p ~= 0 and guard < limit do
        if seen[p] then
            print(string.format("[spark2] %s[%02d] addr=%s CYCLE",
                head_name, guard, hx(p)))
            return
        end
        seen[p] = true
        print(string.format(
            "[spark2] %s[%02d] addr=%s next=%s oslink=%s oid=0x%04x ochar=0x%04x xy=%d,%d z=%d sx=%d img=%s list=%s",
            head_name, guard, hx(p), hx(space:read_u32(p + OBJ_NEXT)),
            hx(space:read_u32(p + OBJ_OSLINK)), space:read_u16(p + OBJ_OID),
            space:read_u16(p + OBJ_OCHAR), space:read_u16(p + OBJ_OXPOS),
            s16(space:read_u16(p + OBJ_OYPOS)), s16(space:read_u16(p + 0x0d0)),
            space:read_u16(p + OBJ_OSIZEX), hx(space:read_u32(p + OBJ_OIMG)),
            list_name_for(p)))
        p = space:read_u32(p + OBJ_NEXT)
        guard = guard + 1
    end
    if p ~= 0 then
        print(string.format("[spark2] %s truncated after %d nodes next=%s",
            head_name, guard, hx(p)))
    end
end

local function dump_all_obj_lists(label)
    dump_obj_list(label, "objlst", OBJLST, 100)
    dump_obj_list(label, "objlst2", OBJLST2, 140)
    dump_obj_list(label, "objlst3", OBJLST3, 80)
    dump_obj_list(label, "ofree", OFREE, 24)
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

local function dump_proc_list(label)
    if not space then return end
    print(string.format("[spark2] dump %s active list", label))
    local p = space:read_u32(ACTIVE)
    local guard = 0
    while p ~= 0 and guard < 80 do
        print(string.format(
            "[spark2] proc[%02d] addr=%s pid=0x%04x time=%d wake=%s action=0x%04x pa8=%s store1=%s store2=%s slave=%s stack=%s",
            guard, hx(p), space:read_u16(p + PROC_ID), s16(space:read_u16(p + PROC_TIME)),
            hx(space:read_u32(p + PROC_WAKE)), space:read_u16(p + PROC_ACTION),
            hx(space:read_u32(p + PROC_PA8)), hx(space:read_u32(p + PROC_STORE1)),
            hx(space:read_u32(p + PROC_STORE2)), hx(space:read_u32(p + PROC_SLAVE)),
            hx(space:read_u32(p + PROC_STACK))))
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
end

local function dump_oslink_chain(label, head)
    if not space or head == 0 then return end
    print(string.format("[spark2] dump %s oslink chain head=%s", label, hx(head)))
    local p = head
    local seen = {}
    local guard = 0
    while p ~= 0 and guard < 32 do
        if seen[p] then
            print(string.format("[spark2] chain[%02d] addr=%s CYCLE", guard, hx(p)))
            return
        end
        seen[p] = true
        print(string.format(
            "[spark2] chain[%02d] addr=%s next=%s oid=0x%04x ochar=0x%04x xy=%d,%d sx=%d img=%s live=%s free=%s",
            guard, hx(p), hx(space:read_u32(p + OBJ_OSLINK)),
            space:read_u16(p + OBJ_OID), space:read_u16(p + OBJ_OCHAR),
            space:read_u16(p + OBJ_OXPOS), s16(space:read_u16(p + OBJ_OYPOS)),
            space:read_u16(p + OBJ_OSIZEX), hx(space:read_u32(p + OBJ_OIMG)),
            tostring(list_contains(OBJLST, p)), tostring(list_contains(OFREE, p))))
        print(string.format("[spark2] chain[%02d] list=%s", guard, list_name_for(p)))
        p = space:read_u32(p + OBJ_OSLINK)
        guard = guard + 1
    end
end

local function dump_master(label)
    if not space then return end
    local p = find_process(PID_MASTER)
    if p == 0 then
        print(string.format("[spark2] master %s missing", label))
        return
    end
    local s7 = space:read_u32(p + PROC_STORE7)
    print(string.format(
        "[spark2] master %s frame=%d addr=%s time=%d wake=%s anicount=%d action=0x%04x pa8=%s slave=%s s1=%s s2=%s s3=%s s4=%s s5=%s s6=%s s7=%s s8=%s round=%d p1mw=%d p2mw=%d p1rw=%d p2rw=%d death=%d timer=%d tick=%d intpend=0x%04x intenb=0x%04x displayon=%d",
        label, frame, hx(p), s16(space:read_u16(p + PROC_TIME)),
        hx(space:read_u32(p + PROC_WAKE)), s16(space:read_u16(p + PROC_ANICOUNT)),
        space:read_u16(p + PROC_ACTION), hx(space:read_u32(p + PROC_PA8)),
        hx(space:read_u32(p + PROC_SLAVE)), hx(space:read_u32(p + PROC_STORE1)),
        hx(space:read_u32(p + PROC_STORE2)), hx(space:read_u32(p + PROC_STORE3)),
        hx(space:read_u32(p + PROC_STORE4)), hx(space:read_u32(p + PROC_STORE5)),
        hx(space:read_u32(p + PROC_STORE6)), hx(s7), hx(space:read_u32(p + PROC_STORE8)),
        space:read_u16(ROUND_NUM), space:read_u16(P1_MATCHW), space:read_u16(P2_MATCHW),
        space:read_u16(P1_RWON), space:read_u16(P2_RWON), space:read_u16(F_DEATH),
        space:read_u16(TIMER), space:read_u16(TICK), space:read_u16(INTPEND),
        space:read_u16(INTENB), space:read_u16(DISPLAYON)))
    if s7 ~= 0 then
        dump_oslink_chain(label, s7)
    end
end

local function log_master_when_changed()
    if not space then return end
    if space:read_u16(GSTATE) ~= 5 then return end
    local p = find_process(PID_MASTER)
    if p == 0 then return end
    local sig = table.concat({
        hx(space:read_u32(p + PROC_WAKE)),
        tostring(s16(space:read_u16(p + PROC_TIME))),
        hx(space:read_u32(p + PROC_STORE4)),
        hx(space:read_u32(p + PROC_STORE5)),
        hx(space:read_u32(p + PROC_STORE7)),
        hx(space:read_u32(p + PROC_STORE8)),
    }, ":")
    if sig ~= last_master_sig or frame - last_master_dump_frame >= 240 then
        last_master_sig = sig
        last_master_dump_frame = frame
        dump_master("bonus_watch")
    end
end

local function check_master_stall()
    if did_error or not space then return false end
    if space:read_u16(GSTATE) ~= 5 then return false end
    local p = find_process(PID_MASTER)
    if p == 0 then return false end

    local wake = space:read_u32(p + PROC_WAKE)
    local time = s16(space:read_u16(p + PROC_TIME))
    local sig = table.concat({
        hx(wake),
        tostring(time),
        tostring(space:read_u16(TICK)),
    }, ":")
    if wake == BONUS_EXIT_RETP and sig == master_stuck_sig then
        if master_stuck_start == 0 then
            master_stuck_start = frame
            print(string.format("[spark2] master_stuck_start frame=%d sig=%s", frame, sig))
        elseif frame - master_stuck_start > 240 then
            did_error = true
            dump_master("master_timer_stalled")
            dump_all_obj_lists("master_timer_stalled")
            dump_proc_list("master_timer_stalled")
            print("[spark2] ERROR master timer stalled at bonus_exit retp")
            manager.machine:exit()
            return true
        end
    else
        master_stuck_start = 0
        master_stuck_sig = sig
    end
    return false
end

local function spark_proc_info()
    local p = find_process(PID_PROJ1)
    if p == 0 then return nil end
    local obj = space:read_u32(p + PROC_PA8)
    if obj == 0 then obj = space:read_u32(p + PROC_STORE1) end
    return {
        proc = p,
        obj = obj,
        owner = space:read_u32(p + PROC_STORE2),
        action = space:read_u16(p + PROC_ACTION),
    }
end

local function log_state(force)
    if not space then return end
    if not force and frame % 20 ~= 0 then return end

    local p1proc = space:read_u32(P1_PROC)
    local p2proc = space:read_u32(P2_PROC)
    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    local p1slave = p1proc ~= 0 and space:read_u32(p1proc + PROC_SLAVE) or 0
    local p1act = p1proc ~= 0 and space:read_u16(p1proc + PROC_ACTION) or 0xffff
    local spark = spark_proc_info()
    local spark_proc = spark and spark.proc or 0
    local spark_obj = spark and spark.obj or 0
    local spark_owner = spark and spark.owner or 0
    local p1x, p1y, p2x, p2y = 0, 0, 0, 0
    if p1obj ~= 0 then
        p1x = space:read_u16(p1obj + OBJ_OXPOS)
        p1y = s16(space:read_u16(p1obj + OBJ_OYPOS))
    end
    if p2obj ~= 0 then
        p2x = space:read_u16(p2obj + OBJ_OXPOS)
        p2y = s16(space:read_u16(p2obj + OBJ_OYPOS))
    end
    local slave_live = list_contains(OBJLST, p1slave)
    local slave_free = list_contains(OFREE, p1slave)
    print(string.format(
        "[spark2] frame=%d g=%d fight=%d ws=%d all=%d p1act=0x%04x p1bar=%d p2bar=%d p1xy=%d,%d p2xy=%d,%d p1proc=%s p2proc=%s p1slave=%s live=%s free=%s slist=%s spark_proc=%s spark_obj=%s owner=%s obj1=%d obj2=%d obj3=%d free=%d timer=%d tick=%d intpend=0x%04x intenb=0x%04x displayon=%d pc=%s",
        frame, space:read_u16(GSTATE), fight_count, space:read_u16(WINNER_STATUS), space:read_u32(F_THATSALL),
        p1act, space:read_u16(P1_BAR), space:read_u16(P2_BAR), p1x, p1y, p2x, p2y,
        hx(p1proc), hx(p2proc), hx(p1slave), tostring(slave_live), tostring(slave_free),
        list_name_for(p1slave), hx(spark_proc), hx(spark_obj), hx(spark_owner),
        count_list(OBJLST), count_list(OBJLST2), count_list(OBJLST3), count_list(OFREE),
        space:read_u16(TIMER), space:read_u16(TICK), space:read_u16(INTPEND),
        space:read_u16(INTENB), space:read_u16(DISPLAYON),
        hx(cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC"))))
end

local function keep_victim_in_range()
    if not space then return end
    if fight_count ~= 1 then return end
    if space:read_u16(GSTATE) ~= GS_FIGHTING then return end
    if space:read_u16(WINNER_STATUS) ~= 0 then return end

    local p1obj = space:read_u32(P1_OBJ)
    local p2obj = space:read_u32(P2_OBJ)
    if p1obj == 0 or p2obj == 0 then return end

    local p1x = space:read_u16(p1obj + OBJ_OXPOS)
    local p1y = space:read_u16(p1obj + OBJ_OYPOS)
    space:write_u16(p2obj + OBJ_OXPOS, p1x + 52)
    space:write_u16(p2obj + OBJ_OYPOS, p1y)
end

local function check_cpu_lockup()
    if did_error or not space then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local pf = space:read_u32(PF_RAM)
    if pf == 0xffffffff or (pc and pc >= MKBUG_START and pc <= MKBUG_END) then
        did_error = true
        log_state(true)
        dump_proc_list("lockup")
        snap("spark_round2_lockup")
        print(string.format("[spark2] ERROR lockup pc=%s pf=%s", hx(pc), hx(pf)))
        manager.machine:exit()
        return true
    end
    return false
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end

    if name == "Coin 1" or (name == "Coin 2" and not ONE_PLAYER_TEST) then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return (not ONE_PLAYER_TEST) and frame >= 1040 and frame < 1140 end

    if charsel_frame > 0 and fighting_frame == 0 then
        local r = frame - charsel_frame
        if not DIRECT_CHARACTER_SELECT then
            -- P1: Liu Kang -> Sub-Zero -> Mileena -> Baraka.
            if name == "P1 Down" then
                return (r >= 80 and r < 88) or (r >= 135 and r < 143)
            end
            if name == "P1 Right" then
                return r >= 190 and r < 198
            end
        end
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        -- P2: Reptile -> Jax.
        if name == "P2 Down" and not ONE_PLAYER_TEST and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 45 and frame < p1_confirm_start + 53
        end
        if name == "P2 High Punch" and not ONE_PLAYER_TEST and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 90 and frame < p1_confirm_start + 130
        end
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 305
        end
    end

    if fighting_frame > 0 and fight_count == 1 then
        local r = frame - fighting_frame
        local cycle = r % 90
        if r > 100 and r < 1600 then
            if name == "P1 High Punch" then return cycle >= 10 and cycle < 26 end
            if name == "P1 Low Kick" then return cycle >= 50 and cycle < 66 end
        end
    end

    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[spark2] loaded: P1 Baraka vs P2 Jax, Baraka attacks to round 2 transition")
    end

    if space then
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[spark2] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
                fight_count = fight_count + 1
                fighting_frame = frame
                log_state(true)
                snap("fight_" .. tostring(fight_count) .. "_start")
            end
            last_gstate = gs
        end

        if DIRECT_CHARACTER_SELECT and charsel_frame > 0 and gs == GS_PSEL and frame - charsel_frame > 30 then
            space:write_u16(P1_CHAR, FT_BARAKA)
            space:write_u16(P2_CHAR, FT_JAX)
            if not did_direct_select then
                did_direct_select = true
                print(string.format("[spark2] direct_select frame=%d p1_char=%d p2_char=%d",
                    frame, space:read_u16(P1_CHAR), space:read_u16(P2_CHAR)))
            end
        end

        if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0
           and frame - charsel_frame > 80
           and (DIRECT_CHARACTER_SELECT or space:read_u16(P1_CHAR) == FT_BARAKA) then
            p1_confirm_start = frame
            print(string.format("[spark2] p1 Baraka reached at frame=%d; confirming", frame))
        end

        if charsel_frame > 0 and not did_select_log and frame - charsel_frame >= 320 then
            did_select_log = true
            print(string.format("[spark2] pre-confirm p1_char=%d want=%d p2_char=%d want=%d",
                space:read_u16(P1_CHAR), FT_BARAKA, space:read_u16(P2_CHAR), FT_JAX))
        end

        local p1proc = space:read_u32(P1_PROC)
        local p1slave = p1proc ~= 0 and space:read_u32(p1proc + PROC_SLAVE) or 0
        if p1slave ~= last_slave then
            last_slave = p1slave
            print(string.format("[spark2] p1slave_change frame=%d p1slave=%s live=%s free=%s",
                frame, hx(p1slave), tostring(list_contains(OBJLST, p1slave)), tostring(list_contains(OFREE, p1slave))))
            log_state(true)
        end

        local p2bar = space:read_u16(P2_BAR)
        if last_p2_bar ~= -1 and p2bar ~= last_p2_bar then
            print(string.format("[spark2] p2bar_change frame=%d %d -> %d",
                frame, last_p2_bar, p2bar))
            log_state(true)
        end
        last_p2_bar = p2bar

        local spark = spark_proc_info()
        if spark and not did_spark_seen then
            did_spark_seen = true
            print(string.format("[spark2] spark_seen frame=%d proc=%s obj=%s owner=%s",
                frame, hx(spark.proc), hx(spark.obj), hx(spark.owner)))
            log_state(true)
            snap("spark_live")
        end

        if fight_count == 1 and gs == GS_FIGHTING and space:read_u16(WINNER_STATUS) == 0 then
            keep_victim_in_range()
            if not did_prime_victim and frame - fighting_frame > 70 then
                did_prime_victim = true
                space:write_u16(P2_BAR, 18)
                if FORCE_NON_FLAWLESS then
                    did_force_non_flawless = true
                    space:write_u16(P1_BAR, 150)
                end
                print(string.format("[spark2] primed_p2_low frame=%d p2bar=18", frame))
                if did_force_non_flawless then
                    print(string.format("[spark2] forced_non_flawless frame=%d p1bar=%d",
                        frame, space:read_u16(P1_BAR)))
                end
                log_state(true)
            end
        end

        if did_prime_victim and not did_attack_ko and space:read_u16(P2_BAR) == 0 then
            did_attack_ko = true
            print(string.format("[spark2] attack_ko frame=%d winner_status=%d",
                frame, space:read_u16(WINNER_STATUS)))
            log_state(true)
        end

        if did_attack_ko and not did_roundover_log and space:read_u16(WINNER_STATUS) ~= 0 then
            did_roundover_log = true
            print(string.format("[spark2] roundover frame=%d winner_status=%d", frame, space:read_u16(WINNER_STATUS)))
            log_state(true)
            dump_master("roundover")
            dump_all_obj_lists("roundover")
            dump_proc_list("roundover")
        end

        if fight_count >= 2 and not did_round2_log then
            did_round2_log = true
            print("[spark2] round2 reached")
        log_state(true)
        dump_proc_list("round2")
        dump_all_obj_lists("round2")
        end

        if check_cpu_lockup() then return end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    log_state(false)
    log_master_when_changed()
    if check_master_stall() then return end

    if did_round2_log and frame - fighting_frame > 240 then
        log_state(true)
        print("[spark2] finished")
        manager.machine:exit()
    end

    if fighting_frame > 0 and fight_count == 1 and frame - fighting_frame > 9000 then
        log_state(true)
        dump_master("timeout_round1")
        dump_all_obj_lists("timeout_round1")
        dump_proc_list("timeout_round1")
        print("[spark2] ERROR timeout waiting for round2")
        manager.machine:exit()
    end

    if frame > 10000 then
        log_state(true)
        dump_all_obj_lists("timeout_global")
        dump_proc_list("timeout_global")
        print("[spark2] ERROR timeout")
        manager.machine:exit()
    end
end)
