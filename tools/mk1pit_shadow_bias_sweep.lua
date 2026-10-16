-- mk1pit_shadow_bias_sweep.lua
--
-- THE PIT (MK1): where does a fighter's shadow meet his feet?  @shad_bias is
-- plain RAM, so this sweeps it live instead of rebuilding per value.  Two idle
-- fighters on curback 01Ah; for every bias in SB_LIST it takes a snapshot
-- with shadows ON and one straight after with f_shadows = 0, and names them
-- so tools/mk1pit_shadow_measure.py can diff the pair: the pixels that went
-- black are the shadow, the dark pixels left in the OFF frame are the boots.
--
-- Env: SB_LIST (comma list, default -8,-4,0,4,8,12,16,20,24), SB_LOG.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("SB_LOG") or (ROOT .. "/tools/mk1pit_shadow_bias_sweep.log")
local LIST = {}
for v in (os.getenv("SB_LIST") or "-8,-4,0,4,8,12,16,20,24"):gmatch("[-%d]+") do LIST[#LIST + 1] = tonumber(v) end

local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local s = "[sbias] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[name] = tonumber(addr, 16) end
end
local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state", "p1_obj", "p2_obj",
                     "p1_bar", "p2_bar", "f_shadows", "shad_bias", "worldtlx", "worldtly", "ground_y" }) do
    A[n] = symbols[n] or 0
end

local space, fields, frame, fight, charsel, step = nil, {}, 0, 0, 0, 0
local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function snap(name)
    manager.machine.screens[":screen"]:snapshot(name)
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if f.name == "Coin 1" or f.name == "Coin 2" or f.name == "2 Players Start"
                    or f.name == "1 Player Start" or f.name == "UI Select"
                    or f.name == "P1 High Punch" or f.name == "P2 High Punch" then fields[f.name] = f end
            end
        end
    end
    local gs = r16(A.gstate)
    if frame % 300 == 0 then log("frame=%d gstate=%d charsel=%d fight=%d", frame, gs, charsel, fight) end
    if gs == 4 and charsel == 0 then charsel = frame end
    if gs == 2 and fight == 0 then fight = frame; log("fight frame=%d ground_y=%d wty=%d", frame, r16(A.ground_y), r16(A.worldtly + 16)) end
    if fight == 0 then
        w16(A.curback, 0x1a)          -- the stage only; select runs as a player would
    end
    -- UI Select dismisses MAME's ROM warning; BOTH starts, into the first 100
    -- frames of select, or it is a one-player game (cave_stage_probe.lua)
    local early = charsel == 0 or frame - charsel < 100
    local press = {
        ["UI Select"] = frame >= 5 and frame < 35,
        ["Coin 1"] = early and frame >= 200 and (frame % 80) < 20,
        ["Coin 2"] = early and frame >= 200 and (frame % 80) < 20,
        ["1 Player Start"] = early and frame >= 220 and (frame % 80) >= 30 and (frame % 80) < 40,
        ["2 Players Start"] = early and frame >= 220 and (frame % 80) >= 50 and (frame % 80) < 60,
        ["P1 High Punch"] = charsel > 0 and fight == 0 and ((frame - charsel >= 130 and frame - charsel < 170)
                              or (frame - charsel >= 300 and (frame % 80) < 10)),
        ["P2 High Punch"] = charsel > 0 and fight == 0 and frame - charsel >= 190 and frame - charsel < 230,
    }
    for n, f in pairs(fields) do f:set_value(press[n] and 1 or 0) end

    if fight > 0 then
        w16(A.p1_bar, 0xa1); w16(A.p2_bar, 0xa1)
        local a, v = space:read_u32(A.p1_obj), space:read_u32(A.p2_obj)
        local cx = r16(A.worldtlx + 16)
        if a ~= 0 and v ~= 0 then
            space:write_u16(a + 0x090, cx + 110); space:write_u32(a + 0x080, (cx + 110) << 16)
            space:write_u16(v + 0x090, cx + 290); space:write_u32(v + 0x080, (cx + 290) << 16)
        end
        local rel = frame - fight - 300
        if rel >= 0 then
            local i = rel // 12 + 1
            local phase = rel % 12
            if i > #LIST then log("done"); logfh:close(); manager.machine:exit(); return end
            local b = LIST[i]
            if phase == 0 then w16(A.shad_bias, b); w16(A.f_shadows, 1) end
            if phase == 5 then snap(string.format("sb_%+03d_on.png", b)) end
            if phase == 6 then w16(A.f_shadows, 0) end
            if phase == 9 then snap(string.format("sb_%+03d_off.png", b)); w16(A.f_shadows, 1)
                log("bias %d captured wtly=%d", b, r16(A.worldtly + 16)) end
        end
    end
    if frame > 12000 then log("timeout"); manager.machine:exit() end
end)
