-- kahn_playable_jump_test.lua
-- Forces a 1P match with player 2 as active Shao Kahn, then drives real jump inputs.

local frame = 0
local ROOT = os.getenv("KAHN_PLAYABLE_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("KAHN_PLAYABLE_LOG") or (ROOT .. "/tools/kahn_playable_jump_test.log")
local TEST_LIST = os.getenv("KAHN_PLAYABLE_TESTS") or "up,forward,back"
local Y_LIMIT = tonumber(os.getenv("KAHN_PLAYABLE_Y_LIMIT") or "360") or 360
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
    print(string.format("[kahn-play] WARN missing map symbol %s; fallback=0x%08x", name, fallback))
    return fallback
end

local A = {
    active        = symaddr("active", 0x010dc6d0),
    objlst        = symaddr("objlst", 0x01127060),
    gstate        = symaddr("gstate", 0x01129dd0),
    curback       = symaddr("curback", 0x0112b6d0),
    p1_state      = symaddr("p1_state", 0x01129df0),
    p1_obj        = symaddr("p1_obj", 0x01129e20),
    p1_proc       = symaddr("p1_proc", 0x01129e60),
    p1_char       = symaddr("p1_char", 0x01129e80),
    p1_bar_view   = symaddr("p1_bar_view", 0x011280f0),
    p1_bar        = symaddr("p1_bar", 0x01129ef0),
    p2_state      = symaddr("p2_state", 0x0112a9c0),
    p2_obj        = symaddr("p2_obj", 0x0112a9f0),
    p2_proc       = symaddr("p2_proc", 0x0112aa30),
    p2_char       = symaddr("p2_char", 0x0112aa50),
    p2_bar_view   = symaddr("p2_bar_view", 0x01128030),
    p2_bar        = symaddr("p2_bar", 0x0112aac0),
    map_position  = symaddr("map_position", 0x0112b750),
    battle_num    = symaddr("battle_num", 0x0112b760),
    winner_status = symaddr("winner_status", 0x0112b710),
}

local O = {
    next    = 0x000,
    ograv   = 0x020,
    oxvel   = 0x040,
    oyvel   = 0x060,
    oxval   = 0x080,
    oxpos   = 0x090,
    oyval   = 0x0a0,
    oypos   = 0x0b0,
    ozval   = 0x0c0,
    oflags  = 0x0f0,
    osag    = 0x100,
    osizex  = 0x120,
    osizey  = 0x130,
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
    sp     = 0x040,
    pa11   = 0x060,
    pa10   = 0x080,
    pa9    = 0x0a0,
    pa8    = 0x0c0,
    wake   = 0x0e0,
    anitab = 0x1b0,
    anirate = 0x1d0,
    anicount = 0x1e0,
    action = 0x1f0,
    ganiy  = 0x200,
    store1 = 0x230,
    store4 = 0x290,
}

local GS_PSEL = 4
local GS_FIGHTING = 2
local FT_KANG = 1
local FT_CAGE = 2
local FT_KAHN = 13
local KAHN_ARENA = 8
local MAX_HP = 0x0a1
local PS_ACTIVE = 1
local ACT_LAND = 0x0304
local ACT_ANGLE_JUMP = 0x0308
local ACT_JUMPUP = 0x030b

local fields = {}
local cpu, space = nil, nil
local last_gstate = -1
local charsel_frame = 0
local fighting_frame = 0
local p1_confirm_start = 0
local did_direct_select = false
local did_position_players = false
local did_error = false
local done_frame = 0

local tests = {}
for token in TEST_LIST:gmatch("[^,%s]+") do
    local name = token:lower()
    if name == "up" or name == "forward" or name == "back" then
        tests[#tests + 1] = {
            name = name,
            start = 90 + (#tests * 360),
            hold = 22,
            seen = false,
            done = false,
            action_start = 0,
        }
    else
        print("[kahn-play] WARN ignoring unknown test token " .. token)
    end
end
if #tests == 0 then
    tests[1] = { name = "up", start = 90, hold = 22, seen = false, done = false, action_start = 0 }
end

local function hx(value)
    if not value then return "na" end
    return string.format("0x%08x", value)
end

local function s16(value)
    value = value & 0xffff
    if value >= 0x8000 then return value - 0x10000 end
    return value
end

local function s32(value)
    value = value & 0xffffffff
    if value >= 0x80000000 then return value - 0x100000000 end
    return value
end

local function r16(addr) return space:read_u16(addr) end
local function r32(addr) return space:read_u32(addr) end
local function w16(addr, value) space:write_u16(addr, value & 0xffff) end
local function w32(addr, value) space:write_u32(addr, value & 0xffffffff) end

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

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["1 Player Start"] = true,
        ["P1 High Punch"] = true,
        ["P2 Up"] = true,
        ["P2 Left"] = true,
        ["P2 Right"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[kahn-play] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
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
    print(string.format("[kahn-play] SNAP frame=%d label=%s ok=%s %s",
        frame, label, tostring(ok), ok and "" or tostring(err)))
end

local function obj_detail(p)
    if p == 0 then return "none" end
    return string.format(
        "%s oid=%04x ch=%d xy=(%d,%d) val=(%s,%s) vel=(%d,%d) grav=%d size=(%d,%d) img=%s sag=%s shape=%s pal=%04x fl=%04x fl2=%04x",
        hx(p), r16(p + O.oid), r16(p + O.ochar),
        s16(r16(p + O.oxpos)), s16(r16(p + O.oypos)),
        hx(r32(p + O.oxval)), hx(r32(p + O.oyval)),
        s32(r32(p + O.oxvel)), s32(r32(p + O.oyvel)), s32(r32(p + O.ograv)),
        r16(p + O.osizex), r16(p + O.osizey),
        hx(r32(p + O.oimg)), hx(r32(p + O.osag)), hx(r32(p + O.oshape)),
        r16(p + O.opal), r16(p + O.oflags), r16(p + O.oflags2))
end

local function proc_detail(p)
    if p == 0 then return "none" end
    return string.format(
        "%s id=%04x t=%d sp=%s wake=%s pa8=%s pa9=%s pa10=%s pa11=%s anitab=%s rate=%d count=%d action=%04x ganiy=%d s1=%s s4=%s",
        hx(p), r16(p + P.id), r16(p + P.time), hx(r32(p + P.sp)), hx(r32(p + P.wake)),
        hx(r32(p + P.pa8)), hx(r32(p + P.pa9)), hx(r32(p + P.pa10)), hx(r32(p + P.pa11)),
        hx(r32(p + P.anitab)), s16(r16(p + P.anirate)), s16(r16(p + P.anicount)),
        r16(p + P.action), s16(r16(p + P.ganiy)), hx(r32(p + P.store1)), hx(r32(p + P.store4)))
end

local function active_info(target)
    local p = r32(A.active)
    local count = 0
    local found = false
    while p ~= 0 and count < 256 do
        count = count + 1
        if p == target then found = true end
        p = r32(p + P.next)
    end
    return count, found
end

local function summary()
    local p1p = r32(A.p1_proc)
    local p2p = r32(A.p2_proc)
    local active_count, p2_active = active_info(p2p)
    return string.format(
        "gs=%d curback=%d winner=%d active=(%d,p2=%s) p1s=%d p2s=%d p1c=%d p2c=%d hp=(%d,%d) p1proc={%s} p1={%s} p2proc={%s} p2={%s}",
        r16(A.gstate), r16(A.curback), r16(A.winner_status),
        active_count, tostring(p2_active),
        r16(A.p1_state), r16(A.p2_state), r16(A.p1_char), r16(A.p2_char),
        r16(A.p1_bar), r16(A.p2_bar),
        proc_detail(p1p), obj_detail(r32(A.p1_obj)),
        proc_detail(p2p), obj_detail(r32(A.p2_obj)))
end

local function force_match()
    w16(A.p1_char, FT_KANG)
    w16(A.p2_char, FT_KAHN)
    w16(A.p1_state, PS_ACTIVE)
    w16(A.p2_state, PS_ACTIVE)
    w16(A.curback, KAHN_ARENA)
    w16(A.map_position, 14)
    w16(A.battle_num, 15)
    if not did_direct_select then
        did_direct_select = true
        print(string.format("[kahn-play] direct_select frame=%d p1=%d p2=%d curback=%d map=%d battle=%d",
            frame, r16(A.p1_char), r16(A.p2_char), r16(A.curback), r16(A.map_position), r16(A.battle_num)))
    end
end

local function keep_alive()
    w16(A.p1_bar, MAX_HP)
    w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP)
    w16(A.p2_bar_view, MAX_HP)
end

local function position_players_once()
    if did_position_players then return end
    local p1o = r32(A.p1_obj)
    local p2o = r32(A.p2_obj)
    local p1p = r32(A.p1_proc)
    local p2p = r32(A.p2_proc)
    if p1o == 0 or p2o == 0 or p1p == 0 or p2p == 0 then return end
    did_position_players = true
    w32(p1o + O.oxval, 110 << 16)
    w16(p1o + O.oxpos, 110)
    w32(p2o + O.oxval, 282 << 16)
    w16(p2o + O.oxpos, 282)
    print("[kahn-play] positioned " .. summary())
    snap("positioned")
end

local function is_jump_action(action)
    return action == ACT_JUMPUP or action == ACT_ANGLE_JUMP
end

local function active_test_for_input()
    if fighting_frame == 0 then return nil, 0 end
    local rel = frame - fighting_frame
    for _, test in ipairs(tests) do
        if rel >= test.start and rel < test.start + test.hold then
            return test, rel - test.start
        end
    end
    return nil, 0
end

local function pressed(name)
    if fighting_frame > 0 then
        local test = active_test_for_input()
        if not test then return false end
        if test.name == "up" then
            return name == "P2 Up"
        elseif test.name == "forward" then
            return name == "P2 Up" or name == "P2 Left"
        elseif test.name == "back" then
            return name == "P2 Up" or name == "P2 Right"
        end
        return false
    end

    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1_confirm_start > 0 then
        return frame >= p1_confirm_start and frame < p1_confirm_start + 45
    end
    return false
end

local function fail(label)
    if did_error then return end
    did_error = true
    print("[kahn-play] ERROR " .. label)
    print(string.format("[kahn-play] cpu pc=%s sp=%s a8=%s a9=%s a10=%s a13=%s",
        hx(cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")),
        hx(cpu_reg("SP")),
        hx(cpu_reg("A8") or cpu_reg("a8")),
        hx(cpu_reg("A9") or cpu_reg("a9")),
        hx(cpu_reg("A10") or cpu_reg("a10")),
        hx(cpu_reg("A13") or cpu_reg("a13"))))
    print("[kahn-play] " .. summary())
    snap(label)
    manager.machine:exit()
end

local function watch_tests()
    local rel = frame - fighting_frame
    local p2p = r32(A.p2_proc)
    local p2o = r32(A.p2_obj)
    if p2p == 0 or p2o == 0 then
        fail("missing_p2_proc_or_obj")
        return
    end

    local action = r16(p2p + P.action)
    local y = s16(r16(p2o + O.oypos))
    if y < -160 or y > Y_LIMIT then
        fail(string.format("p2_offscreen_y_%d", y))
        return
    end

    for _, test in ipairs(tests) do
        local tr = rel - test.start
        if tr == 0 then
            print(string.format("[kahn-play] request test=%s rel=%d %s", test.name, rel, summary()))
            snap("request_" .. test.name)
        end
        if tr == 1 or tr == 5 or tr == 10 or tr == 20 or tr == 40 or tr == 60
           or tr == 90 or tr == 120 or tr == 180 or tr == 240 then
            print(string.format("[kahn-play] trace test=%s t=%d action=0x%04x %s",
                test.name, tr, action, summary()))
        end
        if tr >= 0 and tr <= 300 and is_jump_action(action) and not test.seen then
            test.seen = true
            test.action_start = rel
            print(string.format("[kahn-play] jump_seen test=%s t=%d action=0x%04x %s",
                test.name, tr, action, summary()))
            snap("seen_" .. test.name)
        end
        if test.seen and not test.done and tr > 20 and not is_jump_action(action) and action ~= ACT_LAND then
            test.done = true
            print(string.format("[kahn-play] complete test=%s t=%d action=0x%04x %s",
                test.name, tr, action, summary()))
            snap("complete_" .. test.name)
        end
        if tr > 90 and not test.seen then
            fail("jump_not_triggered_" .. test.name)
            return
        end
        if test.seen and not test.done and tr > 260 and is_jump_action(action) then
            fail("jump_stuck_" .. test.name)
            return
        end
    end

    local last = tests[#tests]
    if last and last.done and done_frame == 0 then
        done_frame = frame
        print("[kahn-play] all playable Kahn jump tests passed")
        print("[kahn-play] finished")
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[kahn-play] loaded: active-P2 Shao Kahn jump input probe")
        print("[kahn-play] log_path=" .. LOG_PATH)
        print("[kahn-play] tests=" .. TEST_LIST)
        print("[kahn-play] y_limit=" .. tostring(Y_LIMIT))
        print(string.format("[kahn-play] symbols gstate=%s p1_proc=%s p1_obj=%s",
            hx(A.gstate), hx(A.p1_proc), hx(A.p1_obj)))
    end

    if space then
        local gs = r16(A.gstate)
        if gs ~= last_gstate then
            print(string.format("[kahn-play] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                keep_alive()
                print("[kahn-play] fight_start " .. summary())
                snap("fight_start")
            end
            last_gstate = gs
        end

        if gs == 0xffff or gs > 0x40 then
            fail(string.format("bad_gstate_%04x", gs))
            return
        end

        if charsel_frame > 0 and fighting_frame == 0 then
            force_match()
        end

        if charsel_frame > 0 and gs == GS_PSEL and p1_confirm_start == 0 and frame - charsel_frame > 90 then
            p1_confirm_start = frame
            print(string.format("[kahn-play] confirming p1 at frame=%d", frame))
        end
        if fighting_frame > 0 and not did_error then
            keep_alive()
            if frame - fighting_frame > 15 then position_players_once() end
            if r16(A.p2_char) ~= FT_KAHN then
                fail("p2_not_kahn")
                return
            end
            watch_tests()
        end

        if done_frame > 0 and frame - done_frame > 45 then
            manager.machine:exit()
        end

        if frame > 5200 and not did_error then
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
        local ok, text = pcall(function()
            return "[kahn-play] stopped frame=" .. tostring(frame) .. " " .. summary()
        end)
        print(ok and text or string.format("[kahn-play] stopped frame=%d summary_error=%s", frame, tostring(text)))
    else
        print(string.format("[kahn-play] stopped frame=%d no_program_space", frame))
    end
    if logfh then
        logfh:flush()
        logfh:close()
        logfh = nil
    end
end)
