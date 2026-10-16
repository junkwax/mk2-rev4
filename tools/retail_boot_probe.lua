-- retail_boot_probe.lua
-- Short boot sanity check: retail should not drop straight into Reptile vs Reptile.

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/retail_boot_probe.log", "w")

local function log(line)
    print(line)
    if logfh then
        logfh:write(line, "\n")
        logfh:flush()
    end
end

local space = manager.machine.devices[":maincpu"].spaces["program"]
local ui_select = nil

local A = {
    gstate = 0x01129dc0,
    p1_state = 0x01129de0,
    p1_char = 0x01129e70,
    p2_state = 0x0112a9b0,
    p2_char = 0x0112aa40,
    curback = 0x0112b6c0,
    winner_status = 0x0112b700,
}

local GS_FIGHTING = 2
local FT_REPTILE = 9

local function r16(addr)
    return space:read_u16(addr)
end

local function cache_ui_select()
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if field.name == "UI Select" then
                ui_select = field
                return
            end
        end
    end
end

local function dump(tag)
    local gs = r16(A.gstate)
    local p1c = r16(A.p1_char)
    local p2c = r16(A.p2_char)
    local line = string.format(
        "[retail_boot] %s frame=%d g=%04x p1s=%04x p2s=%04x p1c=%04x p2c=%04x cur=%04x win=%04x",
        tag, frame, gs, r16(A.p1_state), r16(A.p2_state), p1c, p2c,
        r16(A.curback), r16(A.winner_status))
    log(line)

    if gs == GS_FIGHTING and p1c == FT_REPTILE and p2c == FT_REPTILE then
        log("[retail_boot] FAIL immediate Reptile vs Reptile fight detected")
        manager.machine:exit()
    end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cache_ui_select()
        log("[retail_boot] probe started")
    end

    if ui_select ~= nil then
        if frame >= 5 and frame < 35 then
            ui_select:set_value(1)
        else
            ui_select:clear_value()
        end
    end

    if frame == 60 or frame == 180 or frame == 360 or frame == 600 or frame == 900 or frame == 1200 then
        dump("sample")
    end

    if frame >= 1200 then
        log("[retail_boot] PASS no immediate Reptile vs Reptile boot")
        manager.machine:exit()
    end
end)
