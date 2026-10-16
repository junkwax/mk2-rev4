-- VS-screen portrait check for the hidden fighters.
--
-- Forces P1 to the fighter id in $VS_TEST_CHAR, lets the game reach the VS
-- screen, snapshots it and exits.  Used to prove vs_sanitize_char_a8's
-- portrait substitutions (MKSEL.ASM):
--
--   ft_noob  15 -> his own portrait, zipped_pics 28h
--   ft_jade  16 -> Mileena's  (unlocked off Mileena + LK x6)
--   ft_smoke 14 -> Scorpion's (unlocked off Scorpion + Block x5)
--
-- Anything else with no portrait clamps to 0 (Kung Lao), which is what these
-- three used to do.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local CHAR = tonumber(os.getenv("VS_TEST_CHAR") or "16")
local LOG  = os.getenv("VS_TEST_LOG") or (ROOT .. "/tools/vs_portrait_test.log")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[vs] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
        end
        fh:close()
    end
end
local A = { gstate = symbols.gstate, p1_char = symbols.p1_char, p2_char = symbols.p2_char }
local GS_PSEL, GS_POST = 4, 0x0d
local FT_SCORPION, FT_JAX = 10, 11

local frame, space, done = 0, nil, false
local fields, charsel, confirm, vs = {}, 0, 0, 0
local last_gs = -1

local function r16(a) return space and space:read_u16(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("testing fighter id %d", CHAR)
    end
    if space and not done then
        local gs = r16(A.gstate)
        if gs ~= last_gs then log("frame=%d gstate %d -> %d", frame, last_gs, gs); last_gs = gs end
        if gs == GS_PSEL then
            if charsel == 0 then charsel = frame end
            w16(A.p1_char, FT_SCORPION); w16(A.p2_char, FT_JAX)
            if confirm == 0 and frame - charsel > 90 then confirm = frame end
        elseif gs == GS_POST then
            if vs == 0 then vs = frame end
            w16(A.p1_char, CHAR); w16(A.p2_char, FT_JAX)
            if frame - vs == 120 then
                local ok, scr = pcall(function() return manager.machine.screens[":screen"] end)
                if ok and scr then pcall(function() scr:snapshot() end) end
                log("VS snapshot taken with p1_char=%d", r16(A.p1_char))
                done = true
                logfh:close(); manager.machine:exit()
            end
        end
    end
    for name, f in pairs(fields) do
        local on = false
        if name == "Coin 1" then on = frame >= 700 and frame < 980 and frame % 80 < 20
        elseif name == "1 Player Start" then on = frame >= 1000 and frame < 1080
        elseif name == "P1 High Punch" then on = confirm > 0 and frame >= confirm and frame < confirm + 45 end
        f:set_value(on and 1 or 0)
    end
    if not done and frame > 4000 then log("TIMEOUT"); logfh:close(); manager.machine:exit() end
end)
