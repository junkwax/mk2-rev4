-- kahn_scroll_test.lua
-- Verifies Kahn's Arena background props stay world-fixed while the
-- camera scrolls: holds P1+P2 Right so both fighters walk and drag the
-- camera, snapshots the scrolled arena, then forces winner_status=3
-- (FINISH HIM) to check the stand-up composite while scrolled.

local MAP_PATH = "C:/Users/you/Workplace/mk2-main/src/mk2.map"

local A = { winner_status = 0, p1_bar = 0, p1_char = 0, curback = 0 }

do
    local wanted = {}
    for name in pairs(A) do wanted[name] = true end
    local fh = io.open(MAP_PATH, "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x+)%s+([%w_]+)") do
                if wanted[name] then
                    A[name] = tonumber(addr, 16)
                    wanted[name] = nil
                end
            end
        end
        fh:close()
    end
    for name in pairs(wanted) do
        print(string.format("[kscroll] WARNING: %s not in map", name))
    end
end

local frame = 0
local cpu, space
local right_fields = {}
local left_fields = {}

local function ww(a, v) space:write_u16(a, v & 0xffff) end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if not ok or not s then
        ok, s = pcall(function() return manager.machine.screens:at(1) end)
    end
    if s then
        pcall(function() s:snapshot() end)
        print(string.format("[kscroll] SNAP frame=%d label=%s", frame, label))
    end
end

local function find_fields()
    for tag, port in pairs(manager.machine.ioport.ports) do
        for fname, field in pairs(port.fields) do
            if fname:match("Right") then
                right_fields[#right_fields + 1] = field
                print(string.format("[kscroll] right field: %s / %s", tag, fname))
            elseif fname:match("Left") then
                left_fields[#left_fields + 1] = field
            end
        end
    end
end

local function hold(fields, on)
    for _, f in ipairs(fields) do
        pcall(function() f:set_value(on and 1 or 0) end)
    end
end

local t0 = nil   -- frame the fight came up (P1 HP bar initialized)

local function on_frame()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        find_fields()
        print("[kscroll] harness up")
    end
    if not space then return end

    -- anchor the schedule to the actual test_fight_proc fight (P1=kang,
    -- stage=8/Kahn's Arena), not any earlier attract-mode demo fight that
    -- also passes through p1_bar==0xA1
    if not t0 then
        local ok, hp = pcall(function() return space:read_u16(A.p1_bar) end)
        local ok2, ch = pcall(function() return space:read_u16(A.p1_char) end)
        local ok3, bg = pcall(function() return space:read_u16(A.curback) end)
        if frame % 120 == 0 then
            print(string.format("[kscroll] poll frame=%d hp=%s char=%s stage=%s",
                frame, tostring(ok and hp), tostring(ok2 and ch), tostring(ok3 and bg)))
        end
        if ok and ok2 and ok3 and hp == 0xA1 and ch == 1 and bg == 8 then
            t0 = frame
            print(string.format("[kscroll] fight up at frame %d (char=%d stage=%d)", frame, ch, bg))
        end
        if frame > 3000 then
            print("[kscroll] TIMEOUT waiting for fight")
            manager.machine:exit()
        end
        return
    end
    local t = frame - t0

    if t == 60 then snap("start") end

    -- walk both fighters right to scroll the camera
    if t == 70 then hold(right_fields, true) end
    if t == 260 then snap("goro_walk1") end
    if t == 280 then snap("goro_walk2") end
    if t == 300 then snap("goro_walk3") end
    if t == 320 then hold(right_fields, false) end
    if t == 335 then snap("scrolled") end

    if t == 350 then
        print("[kscroll] forcing winner_status=3")
        ww(A.winner_status, 3)
    end
    if t == 390 then snap("stand_scrolled") end

    -- walk back left to scroll the other way with Kahn standing
    if t == 400 then hold(left_fields, true) end
    if t == 550 then hold(left_fields, false) end
    if t == 565 then snap("stand_back") end

    if t > 590 then
        print("[kscroll] done")
        manager.machine:exit()
    end
end

emu.register_frame_done(function()
    local ok, err = pcall(on_frame)
    if not ok then print("[kscroll] LUA ERROR: " .. tostring(err)) end
end)
