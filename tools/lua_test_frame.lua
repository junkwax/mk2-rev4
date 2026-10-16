local logf = io.open("C:/Users/you/Workplace/mk2-main/lua_frame_probe.log", "w")
local function lg(s) print(s); logf:write(s.."\n"); logf:flush() end

lg("probe start")

local space
local ok, err = pcall(function()
    local cpu = manager.machine.devices[":maincpu"]
    space = cpu.spaces["program"]
    lg("space ok")
end)
if not ok then lg("space error: "..tostring(err)) end

local frame = 0
local ok2, err2 = pcall(function()
    emu.register_frame_done(function()
        frame = frame + 1
        if frame == 1 then lg("frame1 fired") end
        if frame == 60 then lg("frame60 fired") end
        if space and frame == 30 then
            local cb = space:read_u16(0x2256D2)
            lg("frame30: curback="..tostring(cb))
        end
    end)
    lg("register_frame_done ok")
end)
if not ok2 then lg("register error: "..tostring(err2)) end

lg("probe complete")
