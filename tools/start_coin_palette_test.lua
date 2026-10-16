-- Runtime regression proof for the selectable Start+Coin palette path.
-- Selects Raiden with Start+Coin, enters a match, and verifies that both the
-- palette-owner latch and the player's persistent repalt5 object flag survive.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local logfh = assert(io.open(ROOT .. "/tools/start_coin_palette_test.log", "w"))
local function log(fmt, ...)
    local s = "[start-coin] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
local map = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
if map then
    for line in map:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    map:close()
end
local function sym(name, fallback) return symbols[name] or fallback end

local A = {
    gstate = sym("gstate", 0x0112a7d0), p1_char = sym("p1_char", 0x0112a880),
    p2_char = sym("p2_char", 0x0112b450), p1_obj = sym("p1_obj", 0x0112a820),
    alt_pal_owner = sym("alt_pal_owner", 0x0112c7d0),
}
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_RAIDEN, FT_JAX, OFLAGS2, M_REPALT5 = 7, 11, 0x160, 0x0800
local frame, space, psel_frame, choose_frame, post_frame = 0, nil, 0, 0, 0
local fields, finished = {}, false

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function finish(ok, reason)
    if finished then return end
    finished = true; log("%s reason=%s", ok and "PASS" or "ERROR", reason)
    logfh:close(); manager.machine:exit()
end
local function cache_fields()
    local wanted = { ["UI Select"]=true, ["Coin 1"]=true, ["1 Player Start"]=true,
        ["P1 Low Kick"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
end
local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then
        return (frame >= 700 and frame < 980 and frame % 80 < 20)
            or (choose_frame > 0 and frame >= choose_frame and frame < choose_frame + 45)
    end
    if name == "1 Player Start" then
        return (frame >= 1000 and frame < 1080)
            or (choose_frame > 0 and frame >= choose_frame and frame < choose_frame + 45)
    end
    if name == "P1 Low Kick" then return post_frame > 0 and frame >= post_frame + 260 and frame < post_frame + 305 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then space = manager.machine.devices[":maincpu"].spaces["program"]; cache_fields() end
    if space and not finished then
        local gs = r16(A.gstate)
        if gs == GS_PSEL then
            if psel_frame == 0 then psel_frame = frame; log("character select") end
            w16(A.p1_char, FT_RAIDEN); w16(A.p2_char, FT_JAX)
            if choose_frame == 0 and frame - psel_frame > 90 then choose_frame = frame; log("press Start+Coin") end
        elseif gs == GS_POST then
            if post_frame == 0 then post_frame = frame end
            w16(A.p1_char, FT_RAIDEN); w16(A.p2_char, FT_JAX)
        elseif gs == GS_FIGHTING then
            local obj, owner = r32(A.p1_obj), r16(A.alt_pal_owner)
            if obj ~= 0 then
                local flags2 = r16(obj + OFLAGS2)
                log("fight char=%d owner=%04x flags2=%04x", r16(A.p1_char), owner, flags2)
                if r16(A.p1_char) ~= FT_RAIDEN then finish(false, "wrong_character")
                elseif (owner & 0x0400) == 0 then finish(false, "owner_bit_missing")
                elseif (flags2 & M_REPALT5) == 0 then finish(false, "repalt5_flag_missing")
                else finish(true, "raiden_start_coin_live") end
                return
            end
        end
    end
    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
    if frame > 5000 then finish(false, "timeout") end
end)
