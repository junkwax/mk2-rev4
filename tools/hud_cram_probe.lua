-- hud_cram_probe.lua - dump colour map #0 (boonpal's pinned slot) during a
-- fight, so the HUD text demo can pick two indices that are actually
-- distinguishable on screen.  MAINEQU's bpal_* names describe the boonpal
-- SOURCE table; what CRAM holds mid-fight is what the player sees.
local LOGP = "C:/Users/you/Workplace/mk2-main/tools/hud_cram_probe.log"
local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = string.format(fmt, ...)
    print("[cram] " .. line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
}
local CRAM = 0x01800000

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local fields = {}

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 60
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"]=true, ["2 Players Start"]=true, ["P1 High Punch"]=true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if want[f.name] then fields[f.name] = f end
            end
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = space:read_u16(A.gstate)
    if gs == 4 and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        space:write_u16(A.p1_state, 1); space:write_u16(A.p2_state, 1)
        space:write_u16(A.p1_char, 1);  space:write_u16(A.p2_char, 1)
        space:write_u16(A.curback, 0)
        if A.map_position ~= 0 then space:write_u16(A.map_position, 0) end
        if A.battle_num ~= 0 then space:write_u16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == 2 and fighting_frame == 0 then fighting_frame = frame end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); manager.machine:exit() end
        return
    end

    if frame - fighting_frame == 200 then
        log("colour map #0 (boonpal) during a fight:")
        for i = 0, 31 do
            local v = space:read_u16(CRAM + i * 16)
            -- T-unit CRAM is xRRRRRGGGGGBBBBB at 5 bits each
            local r = (v >> 10) & 0x1f
            local g = (v >> 5) & 0x1f
            local b = v & 0x1f
            log("  %2d (%02xh) = %04x  rgb5 %2d,%2d,%2d  -> %3d,%3d,%3d",
                i, i, v, r, g, b, r * 8, g * 8, b * 8)
        end
        manager.machine:exit()
    end
    if frame > 20000 then manager.machine:exit() end
end)
