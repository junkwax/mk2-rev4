-- kahn_standup_test.lua
-- Forces @winner_status=3 (the same value MAIN.ASM's finish_him_sequence
-- sets right when "FINISH HIM" begins) to test the new sitting_kahn
-- stand-up transition (bosssit1 -> bosssit2 -> bosssit3) in BGND.ASM
-- without needing to actually play out a full match to that state.

local MAP_PATH = "C:/Users/you/Workplace/mk2-main/src/mk2.map"

local A = { winner_status = 0 }

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
        print(string.format("[ks] WARNING: %s not in map", name))
    end
end

local frame = 0
local cpu, space

local function ww(a, v) space:write_u16(a, v & 0xffff) end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if not ok or not s then
        ok, s = pcall(function() return manager.machine.screens:at(1) end)
    end
    if s then
        pcall(function() s:snapshot() end)
        print(string.format("[ks] SNAP frame=%d label=%s", frame, label))
    end
end

local function on_frame()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        print("[ks] harness up")
    end
    if not space then return end

    if frame == 120 then
        snap("before")
    end
    if frame == 150 then
        print("[ks] forcing winner_status=3")
        ww(A.winner_status, 3)
    end
    if frame == 160 then snap("t8") end
    if frame == 170 then snap("t20") end
    if frame == 200 then snap("t50") end
    if frame == 300 then snap("t150") end

    if frame > 320 then
        print("[ks] done")
        manager.machine:exit()
    end
end

emu.register_frame_done(function()
    local ok, err = pcall(on_frame)
    if not ok then print("[ks] LUA ERROR: " .. tostring(err)) end
end)
