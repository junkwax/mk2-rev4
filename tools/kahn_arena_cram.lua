-- kahn_arena_load_test.lua
-- Force a normal match onto Kahn's Arena and verify the background actor
-- list stays alive long enough for the arena Goro animation to render.

local frame = 0
local ROOT = os.getenv("KAHN_ARENA_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("KAHN_ARENA_LOG") or (ROOT .. "/tools/kahn_arena_load_test.log")
local DUMP_PATH = os.getenv("KAHN_ARENA_DUMP") or LOG_PATH:gsub("%.log$", "_failure_dump.txt")
local EDGE_PROBE = (os.getenv("KAHN_ARENA_EDGE_PROBE") or "") ~= ""
local WALK_PROBE = (os.getenv("KAHN_ARENA_WALK_PROBE") or "") ~= ""
local POWER_PROBE = (os.getenv("KAHN_ARENA_POWER_PROBE") or "") ~= ""
local NO_SKEW_FLOOR = (os.getenv("KAHN_ARENA_NO_SKEW_FLOOR") or "") ~= ""
local DUMP_CRAM = (os.getenv("KAHN_ARENA_DUMP_CRAM") or "") ~= ""
local HIDE_PLAYERS = (os.getenv("KAHN_ARENA_HIDE_PLAYERS") or "") ~= ""
local CAMERA_PROBE = EDGE_PROBE
local COLOR_RAM = 0x01800000
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
    print(string.format("[kahn-arena] WARN missing map symbol %s; using fallback 0x%08x", name, fallback))
    return fallback
end

local A = {
    active        = symaddr("active", 0x010dc6d0),
    free          = symaddr("free", 0x010dc6f0),
    prcstr        = symaddr("prcstr", 0x010dc750),
    ofree         = symaddr("ofree", 0x01129d30),
    baklst3       = symaddr("baklst3", 0x01127010),
    baklst4       = symaddr("baklst4", 0x01126ff0),
    baklst5       = symaddr("baklst5", 0x01126fd0),
    baklst6       = symaddr("baklst6", 0x01126fb0),
    baklst7       = symaddr("baklst7", 0x01126f90),
    baklst2       = symaddr("baklst2", 0x01127030),
    baklst1       = symaddr("baklst1", 0x01127050),
    baklst8       = symaddr("baklst8", 0x01126f70),
    objlst        = symaddr("objlst", 0x01127070),
    objlst2       = symaddr("objlst2", 0x01127090),
    gstate        = symaddr("gstate", 0x01129dd0),
    curback       = symaddr("curback", 0x0112b6d0),
    p1_state      = symaddr("p1_state", 0x01129df0),
    p2_state      = symaddr("p2_state", 0x0112a9c0),
    p1_char       = symaddr("p1_char", 0x01129e80),
    p2_char       = symaddr("p2_char", 0x0112aa50),
    p1_obj        = symaddr("p1_obj", 0x01129e20),
    p2_obj        = symaddr("p2_obj", 0x0112a9f0),
    p1_proc       = symaddr("p1_proc", 0x01129e60),
    p2_proc       = symaddr("p2_proc", 0x0112aa30),
    p1_bar        = symaddr("p1_bar", 0x01129ef0),
    p2_bar        = symaddr("p2_bar", 0x0112aac0),
    worldtlx2     = symaddr("worldtlx2", 0x01126f10),
    map_position  = symaddr("map_position", 0x0112b740),
    battle_num    = symaddr("battle_num", 0x0112b760),
    f_skew        = symaddr("f_skew", 0x011287d0),
    skew_height   = symaddr("skew_height", 0x01128830),
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

local P = {
    next   = 0x000,
    id     = 0x020,
    time   = 0x030,
    pa8    = 0x0c0,
    wake   = 0x0e0,
    action = 0x1f0,
    store1 = 0x230,
}

local GS_PSEL = 4
local GS_FIGHTING = 2
local GS_ROUND_INTRO = 7
local FT_KANG = 1
local FT_CAGE = 2
local FT_GORO = 12
local FT_FINAL_BOSS = 13
local KAHN_ARENA = 8
local function getenv_int(name, default)
    local raw = os.getenv(name)
    if not raw or raw == "" then return default end
    return tonumber(raw) or default
end
local P1_CHAR = getenv_int("KAHN_ARENA_P1", FT_KANG)
local P2_CHAR = getenv_int("KAHN_ARENA_P2", FT_CAGE)
local STAGE_ID = getenv_int("KAHN_ARENA_STAGE", KAHN_ARENA)
local STAGE_NAME = os.getenv("KAHN_ARENA_STAGE_NAME") or (STAGE_ID == KAHN_ARENA and "Kahn's Arena" or ("stage " .. tostring(STAGE_ID)))
local WATCH_ARENA_GORO = STAGE_ID == KAHN_ARENA
local PS_ACTIVE = 1
local PS_INACTIVE = 0
local PRCSIZ = 0x6f0
local NPROC = 168

local fields = {}
local cpu = nil
local space = nil
local last_gstate = -1
local charsel_frame = 0
local round_intro_frame = 0
local fighting_frame = 0
local p1_confirm_start = 0
local p2_confirm_start = 0
local did_direct_select = false
local done_frame = 0
local did_error = false
local last_free_head = nil
local intro_snaps = {}
local last_goro_shape = nil
local last_goro_pal = nil
local last_goro_sx = nil

local function hx(value)
    if not value then return "na" end
    return string.format("0x%08x", value)
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

local function r16(addr) return space:read_u16(addr) end
local function r32(addr) return space:read_u32(addr) end
local function w16(addr, value) space:write_u16(addr, value & 0xffff) end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 Left"] = true,
        ["P1 Right"] = true,
        ["P1 High Punch"] = true,
        ["P2 High Punch"] = true,
        ["P2 Left"] = true,
        ["P2 Right"] = true,
        ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[kahn-arena] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
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
    print(string.format("[kahn-arena] SNAP frame=%d label=%s ok=%s %s",
        frame, label, tostring(ok), ok and "" or tostring(err)))
end

local function pressed(name)
    if fighting_frame > 0 then
        if POWER_PROBE then
            local r = frame - fighting_frame
            if r >= 80 and r < 170 then
                return name == "P1 Left" or name == "P1 High Punch"
            end
        end
        if WALK_PROBE then
            local r = frame - fighting_frame
            if r >= 20 and r < 300 then
                return name == "P1 Left" or name == "P2 Left"
            end
            if r >= 360 and r < 980 then
                return name == "P1 Right" or name == "P2 Right"
            end
        end
        return false
    end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" or name == "Coin 2" then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1_confirm_start > 0 then
        return frame >= p1_confirm_start and frame < p1_confirm_start + 45
    end
    if name == "P2 High Punch" and p2_confirm_start > 0 then
        return frame >= p2_confirm_start and frame < p2_confirm_start + 45
    end
    if name == "P1 Low Kick" and charsel_frame > 0 then
        local r = frame - charsel_frame
        return r >= 620 and r < 670
    end
    return false
end

local function count_list(head_addr, limit)
    local p = r32(head_addr)
    local count = 0
    while p ~= 0 and count < (limit or 128) do
        count = count + 1
        p = r32(p + O.next)
    end
    return count
end

local function obj_detail(p)
    if p == 0 then return "none" end
    return string.format(
        "%s oid=%04x ch=%d xy=(%d,%d) z=%s img=%s sag=%s size=%s shape=%s pal=%04x fl=%04x fl2=%04x next=%s",
        hx(p), r16(p + O.oid), r16(p + O.ochar),
        r16(p + O.oxpos), s16(r16(p + O.oypos)), hx(r32(p + O.ozval)),
        hx(r32(p + O.oimg)), hx(r32(p + O.osag)), hx(r32(p + O.osize)),
        hx(r32(p + O.oshape)), r16(p + O.opal), r16(p + O.oflags),
        r16(p + O.oflags2), hx(r32(p + O.next)))
end

local function list_summary(head_addr, limit)
    local p = r32(head_addr)
    local parts = {}
    local count = 0
    while p ~= 0 and count < (limit or 10) do
        parts[#parts + 1] = string.format("%d:%s", count + 1, obj_detail(p))
        p = r32(p + O.next)
        count = count + 1
    end
    return "[" .. table.concat(parts, " ; ") .. "]"
end

local function dump_palette_slot(label, slot, count)
    if not DUMP_CRAM then return end
    local words = {}
    local base = COLOR_RAM + (slot * 0x1000)
    for i = 0, (count or 64) - 1 do
        words[#words + 1] = string.format("%04x", r16(base + (i * 0x10)))
    end
    print(string.format("[kahn-arena] %s cram_slot_%02x=%s", label, slot, table.concat(words, ",")))
end

local function proc_summary(limit)
    local p = r32(A.active)
    local parts = {}
    local count = 0
    while p ~= 0 and count < (limit or 18) do
        parts[#parts + 1] = string.format(
            "%d:%s id=%04x t=%d wake=%s pa8=%s action=%04x s1=%s",
            count + 1, hx(p), r16(p + P.id), r16(p + P.time),
            hx(r32(p + P.wake)), hx(r32(p + P.pa8)),
            r16(p + P.action), hx(r32(p + P.store1)))
        p = r32(p + P.next)
        count = count + 1
    end
    return "[" .. table.concat(parts, " ; ") .. "]"
end

local function proc_obj_summary(limit)
    local p = r32(A.active)
    local parts = {}
    local count = 0
    while p ~= 0 and count < (limit or 24) do
        local pa8 = r32(p + P.pa8)
        if pa8 >= 0x010a0000 and pa8 < 0x01130000 then
            parts[#parts + 1] = string.format(
                "%d:%s id=%04x wake=%s pa8=%s obj={%s}",
                count + 1, hx(p), r16(p + P.id), hx(r32(p + P.wake)),
                hx(pa8), obj_detail(pa8))
        end
        p = r32(p + P.next)
        count = count + 1
    end
    return "[" .. table.concat(parts, " ; ") .. "]"
end

local function in_proc_pool(p)
    local first = A.prcstr
    local last = A.prcstr + (NPROC * PRCSIZ)
    return p >= first and p < last
end

local function free_summary(limit)
    local p = r32(A.free)
    local parts = {}
    local count = 0
    while p ~= 0 and count < (limit or 20) do
        if not in_proc_pool(p) then
            parts[#parts + 1] = string.format("%d:%s OUT_OF_POOL", count + 1, hx(p))
            break
        end
        parts[#parts + 1] = string.format(
            "%d:%s next=%s id=%04x t=%d wake=%s pa8=%s action=%04x",
            count + 1, hx(p), hx(r32(p + P.next)), r16(p + P.id), r16(p + P.time),
            hx(r32(p + P.wake)), hx(r32(p + P.pa8)), r16(p + P.action))
        p = r32(p + P.next)
        count = count + 1
    end
    return "[" .. table.concat(parts, " ; ") .. "]"
end

local function player_summary()
    local p1o = r32(A.p1_obj)
    local p2o = r32(A.p2_obj)
    return string.format(
        "p1s=%d p2s=%d p1c=%d p2c=%d hp=(%d,%d) p1=%s p2=%s bak8=%d bak7=%d bak6=%d bak5=%d bak4=%d bak3=%d bak2=%d bak1=%d obj=%d obj2=%d freeproc=%d freeobj=%d freehead=%s",
        r16(A.p1_state), r16(A.p2_state), r16(A.p1_char), r16(A.p2_char),
        r16(A.p1_bar), r16(A.p2_bar), obj_detail(p1o), obj_detail(p2o),
        count_list(A.baklst8, 128), count_list(A.baklst7, 128), count_list(A.baklst6, 128),
        count_list(A.baklst5, 128), count_list(A.baklst4, 128),
        count_list(A.baklst3, 128), count_list(A.baklst2, 128), count_list(A.baklst1, 128), count_list(A.objlst, 128), count_list(A.objlst2, 128),
        count_list(A.free, 256), count_list(A.ofree, 256), hx(r32(A.free)))
end

local function arena_goro_obj()
    return r32(A.baklst8)
end

local function arena_goro_screen_x(p)
    if p == 0 then return 0 end
    return s16((r16(p + O.oxpos) - r16(A.worldtlx2 + 16)) & 0xffff)
end

local function log_arena_goro(label)
    local p = arena_goro_obj()
    print(string.format(
        "[kahn-arena] %s worldtlx2=%d goro_screen_x=%d goro=%s",
        label, r16(A.worldtlx2 + 16), arena_goro_screen_x(p), obj_detail(p)))
end

local function trace_arena_goro(label, rel)
    local p = arena_goro_obj()
    if p == 0 then return end
    local shape = r32(p + O.oshape)
    local pal = r16(p + O.opal)
    local sx = arena_goro_screen_x(p)
    if shape ~= last_goro_shape or pal ~= last_goro_pal then
        print(string.format(
            "[kahn-arena] %s goro_frame frame=%d rel=%d sx=%d shape=%s pal=%04x dx=%s",
            label, frame, rel or -1, sx, hx(shape), pal,
            last_goro_sx and tostring(sx - last_goro_sx) or "na"))
        last_goro_shape = shape
        last_goro_pal = pal
        last_goro_sx = sx
    end
end

local function dump_arena(label)
    print(string.format(
        "[kahn-arena] %s cpu pc=%s sp=%s a0=%s a1=%s a2=%s a7=%s a8=%s a9=%s a10=%s a11=%s a12=%s a13=%s b14=%s",
        label,
        hx(cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")),
        hx(cpu_reg("SP")),
        hx(cpu_reg("A0") or cpu_reg("a0")),
        hx(cpu_reg("A1") or cpu_reg("a1")),
        hx(cpu_reg("A2") or cpu_reg("a2")),
        hx(cpu_reg("A7") or cpu_reg("a7")),
        hx(cpu_reg("A8") or cpu_reg("a8")),
        hx(cpu_reg("A9") or cpu_reg("a9")),
        hx(cpu_reg("A10") or cpu_reg("a10")),
        hx(cpu_reg("A11") or cpu_reg("a11")),
        hx(cpu_reg("A12") or cpu_reg("a12")),
        hx(cpu_reg("A13") or cpu_reg("a13")),
        hx(cpu_reg("B14") or cpu_reg("b14"))))
    print(string.format("[kahn-arena] %s %s", label, player_summary()))
    print(string.format("[kahn-arena] %s baklst8=%s", label, list_summary(A.baklst8, 16)))
    print(string.format("[kahn-arena] %s baklst7=%s", label, list_summary(A.baklst7, 40)))
    print(string.format("[kahn-arena] %s baklst6=%s", label, list_summary(A.baklst6, 80)))
    print(string.format("[kahn-arena] %s baklst5=%s", label, list_summary(A.baklst5, 80)))
    print(string.format("[kahn-arena] %s baklst4=%s", label, list_summary(A.baklst4, 40)))
    print(string.format("[kahn-arena] %s baklst3=%s", label, list_summary(A.baklst3, 40)))
    print(string.format("[kahn-arena] %s baklst2=%s", label, list_summary(A.baklst2, 40)))
    print(string.format("[kahn-arena] %s baklst1=%s", label, list_summary(A.baklst1, 16)))
    print(string.format("[kahn-arena] %s objlst=%s", label, list_summary(A.objlst, 6)))
    print(string.format("[kahn-arena] %s procs=%s", label, proc_summary(20)))
    print(string.format("[kahn-arena] %s procobjs=%s", label, proc_obj_summary(24)))
    print(string.format("[kahn-arena] %s free=%s", label, free_summary(20)))
end

local function write_failure_dump(label)
    local fh = io.open(DUMP_PATH, "w")
    if not fh then
        print("[kahn-arena] WARN could not open failure dump: " .. DUMP_PATH)
        return
    end
    local function line(s) fh:write(s, "\n") end
    line(string.format("label=%s frame=%d", label, frame))
    line(string.format("pc=%s sp=%s a0=%s a1=%s a2=%s a7=%s a8=%s a9=%s a10=%s a11=%s a12=%s a13=%s b14=%s",
        hx(cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")),
        hx(cpu_reg("SP")),
        hx(cpu_reg("A0") or cpu_reg("a0")),
        hx(cpu_reg("A1") or cpu_reg("a1")),
        hx(cpu_reg("A2") or cpu_reg("a2")),
        hx(cpu_reg("A7") or cpu_reg("a7")),
        hx(cpu_reg("A8") or cpu_reg("a8")),
        hx(cpu_reg("A9") or cpu_reg("a9")),
        hx(cpu_reg("A10") or cpu_reg("a10")),
        hx(cpu_reg("A11") or cpu_reg("a11")),
        hx(cpu_reg("A12") or cpu_reg("a12")),
        hx(cpu_reg("A13") or cpu_reg("a13")),
        hx(cpu_reg("B14") or cpu_reg("b14"))))
    line(string.format("process_pool=%s..%s prcsiz=%s nproc=%d",
        hx(A.prcstr), hx(A.prcstr + (NPROC * PRCSIZ)), hx(PRCSIZ), NPROC))
    line("summary=" .. player_summary())
    line("baklst8=" .. list_summary(A.baklst8, 24))
    line("baklst7=" .. list_summary(A.baklst7, 40))
    line("baklst6=" .. list_summary(A.baklst6, 80))
    line("baklst5=" .. list_summary(A.baklst5, 80))
    line("baklst4=" .. list_summary(A.baklst4, 40))
    line("baklst3=" .. list_summary(A.baklst3, 24))
    line("baklst2=" .. list_summary(A.baklst2, 24))
    line("baklst1=" .. list_summary(A.baklst1, 24))
    line("objlst=" .. list_summary(A.objlst, 24))
    line("objlst2=" .. list_summary(A.objlst2, 24))
    line("active=" .. proc_summary(64))
    line("free=" .. free_summary(64))
    fh:close()
    print("[kahn-arena] failure_dump=" .. DUMP_PATH)
end

local function force_arena_match()
    w16(A.p1_char, P1_CHAR)
    w16(A.p2_char, P2_CHAR)
    w16(A.curback, STAGE_ID)
    if not did_direct_select then
        did_direct_select = true
        print(string.format("[kahn-arena] direct_select frame=%d p1=%d p2=%d curback=%d map_position=%d battle=%d",
            frame, r16(A.p1_char), r16(A.p2_char), r16(A.curback), r16(A.map_position), r16(A.battle_num)))
    end
end

local function expects_arena_goro()
    if not WATCH_ARENA_GORO then return false end
    if P1_CHAR == FT_GORO or P2_CHAR == FT_GORO then return false end
    if P1_CHAR == FT_FINAL_BOSS or P2_CHAR == FT_FINAL_BOSS then return false end
    return true
end

local function fail(label)
    if did_error then return end
    did_error = true
    print("[kahn-arena] ERROR " .. label)
    dump_arena(label)
    write_failure_dump(label)
    snap(label)
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print(string.format("[kahn-arena] loaded: forcing normal 2P %d vs %d on %s (%d)", P1_CHAR, P2_CHAR, STAGE_NAME, STAGE_ID))
        if EDGE_PROBE then
            print("[kahn-arena] edge probe enabled: forcing worldtlx2+16 briefly to exercise Goro walk")
        end
        if WALK_PROBE then
            print("[kahn-arena] walk probe enabled: walking both players left, then right, through normal inputs")
        end
        if POWER_PROBE then
            print("[kahn-arena] power probe enabled: holding P1 back+HP to trigger Jax power punch")
        end
        if NO_SKEW_FLOOR then
            print("[kahn-arena] no-skew-floor probe enabled: clearing f_skew/skew_height during fight")
        end
        if DUMP_CRAM then
            print("[kahn-arena] color-RAM dump enabled")
        end
        if HIDE_PLAYERS then
            print("[kahn-arena] hide-player probe enabled: marking player objects invisible")
        end
        print("[kahn-arena] log_path=" .. LOG_PATH)
        print("[kahn-arena] dump_path=" .. DUMP_PATH)
        print(string.format("[kahn-arena] symbols curback=%s gstate=%s baklst1=%s active=%s",
            hx(A.curback), hx(A.gstate), hx(A.baklst1), hx(A.active)))
        print(string.format("[kahn-arena] process_pool %s..%s",
            hx(A.prcstr), hx(A.prcstr + (NPROC * PRCSIZ))))
    end

    if space then
        local gs = r16(A.gstate)
        local free_head = r32(A.free)
        if free_head ~= last_free_head then
            print(string.format("[kahn-arena] frame=%d freehead %s -> %s",
                frame, hx(last_free_head), hx(free_head)))
            last_free_head = free_head
        end
        if free_head ~= 0 and not in_proc_pool(free_head) then
            fail(string.format("free_list_corrupt_%s", hx(free_head)))
            return
        end
        if gs ~= last_gstate then
            print(string.format("[kahn-arena] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_ROUND_INTRO and round_intro_frame == 0 then round_intro_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                dump_arena("fight_start")
                snap("fight_start")
            end
            last_gstate = gs
        end

        if gs == 0xffff or gs > 0x40 then
            fail(string.format("bad_gstate_%04x", gs))
            return
        end

        if charsel_frame > 0 and fighting_frame == 0 then
            force_arena_match()
        end

        if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0 and frame - charsel_frame > 90 then
            p1_confirm_start = frame
            print(string.format("[kahn-arena] confirming p1 at frame=%d", frame))
        end

        if charsel_frame > 0 and gs == GS_PSEL and p2_confirm_start == 0 and frame - charsel_frame > 150 then
            p2_confirm_start = frame
            print(string.format("[kahn-arena] confirming p2 at frame=%d", frame))
        end

        if round_intro_frame > 0 and fighting_frame == 0 and gs == GS_ROUND_INTRO and r16(A.curback) == STAGE_ID then
            local rel_intro = frame - round_intro_frame
            if (rel_intro == 1 or rel_intro == 40 or rel_intro == 80 or rel_intro == 120 or rel_intro == 160 or rel_intro == 220 or rel_intro == 280) and not intro_snaps[rel_intro] then
                intro_snaps[rel_intro] = true
                dump_arena("intro_" .. tostring(rel_intro))
                snap("intro_" .. tostring(rel_intro))
            end
        end

        if fighting_frame > 0 and not did_error then
            local rel = frame - fighting_frame
            if NO_SKEW_FLOOR then
                w16(A.f_skew, 0)
                w16(A.skew_height, 0)
            end
            if HIDE_PLAYERS then
                local p1o = r32(A.p1_obj)
                local p2o = r32(A.p2_obj)
                if p1o ~= 0 then
                    w16(p1o + O.oflags2, r16(p1o + O.oflags2) | 0x20)
                end
                if p2o ~= 0 then
                    w16(p2o + O.oflags2, r16(p2o + O.oflags2) | 0x20)
                end
            end
            if WATCH_ARENA_GORO then
                trace_arena_goro("fight_trace", rel)
            end
            if CAMERA_PROBE and rel >= 20 and rel <= 220 then
                w16(A.worldtlx2 + 16, 0)
                if rel == 20 or rel == 40 or rel == 80 or rel == 120 or rel == 180 or rel == 220 then
                    log_arena_goro("edge_probe_" .. tostring(rel))
                    snap("edge_probe_" .. tostring(rel))
                end
            elseif CAMERA_PROBE and rel == 260 then
                log_arena_goro("edge_probe_after")
                snap("edge_probe_after")
            elseif WALK_PROBE and (rel == 20 or rel == 60 or rel == 120 or rel == 200 or rel == 300 or rel == 420 or rel == 560 or rel == 680 or rel == 820 or rel == 980 or rel == 1100) then
                log_arena_goro("walk_input_probe_" .. tostring(rel))
                snap("walk_input_probe_" .. tostring(rel))
            elseif POWER_PROBE and (rel == 70 or rel == 90 or rel == 120 or rel == 150 or rel == 190 or rel == 240) then
                print(string.format("[kahn-arena] power_probe_%d %s", rel, player_summary()))
                snap("power_probe_" .. tostring(rel))
            end
            if rel == 1 or (rel <= 160 and (rel % 10) == 0) or rel == 240 or rel == 480 or rel == 720 or (WALK_PROBE and (rel == 900 or rel == 1080)) then
                dump_arena("fight_" .. tostring(rel))
                if rel == 1 or rel == 60 or rel == 120 or rel == 720 then
                    for sl = 0, 31 do
                        dump_palette_slot("fight_" .. tostring(rel), sl, 32)
                    end
                end
                snap("fight_" .. tostring(rel))
            end
            if rel == 120 and WATCH_ARENA_GORO and count_list(A.baklst1, 128) < 3 then
                fail("arena_bg_actor_list_too_small")
                return
            end
            if rel == 120 and WATCH_ARENA_GORO then
                local goro_present = arena_goro_obj() ~= 0
                if expects_arena_goro() and not goro_present then
                    fail("arena_goro_missing")
                    return
                end
                if (not expects_arena_goro()) and goro_present then
                    fail("arena_goro_unexpected")
                    return
                end
            end
            local done_rel = WALK_PROBE and 1120 or 720
            if rel > done_rel and done_frame == 0 then
                done_frame = frame
                print("[kahn-arena] stage load and background watch passed")
                print("[kahn-arena] finished")
            end
        end

        if done_frame > 0 and frame - done_frame > 30 then
            manager.machine:exit()
            return
        end

        if frame > 5000 then
            fail("timeout")
            return
        end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end
end)

emu.register_stop(function()
    if space then
        local ok, summary = pcall(function()
            return string.format("[kahn-arena] stopped frame=%d gstate=%d curback=%d %s",
                frame, r16(A.gstate), r16(A.curback), player_summary())
        end)
        print(ok and summary or string.format("[kahn-arena] stopped frame=%d summary_error=%s", frame, tostring(summary)))
    else
        print(string.format("[kahn-arena] stopped frame=%d no_program_space", frame))
    end
    if logfh then
        logfh:flush()
        logfh:close()
        logfh = nil
    end
end)
