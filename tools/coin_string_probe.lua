-- coin_string_probe.lua - dump the credit string the ROM builds (get_cstr)
-- so we can see "FREE PLAY" vs "CREDITS n" without hunting for the frame
-- the attract mode happens to draw it on.  Env: COIN_MODE, COIN_LOG.
local MODE = (os.getenv("COIN_MODE") or "coin"):lower()
local LOGP = os.getenv("COIN_LOG") or "C:/tmp/coin_string.log"
local fh = io.open(LOGP, "a")
local function log(s) print("[str] "..s); if fh then fh:write("[str] "..s.."\n"); fh:flush() end end

local symbols = {}
do
    local f = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    for line in f:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a,16) end
    end
    f:close()
end

local space, frame, poked, last = nil, 0, nil, nil
local coin_field, seen = nil, 0

-- strings live packed 8 bits per char at a raw bit address
local function str_at(bitaddr, n)
    local out = {}
    for i = 0, n - 1 do
        local c = space:read_u8(bitaddr + i * 8)
        if c == 0 then break end
        out[#out+1] = (c >= 32 and c < 127) and string.char(c) or string.format("<%02x>", c)
    end
    return table.concat(out)
end

emu.register_frame_done(function()
    frame = frame + 1
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        for _, p in pairs(manager.machine.ioport.ports) do
            for _, f2 in pairs(p.fields) do if f2.name == "Coin 1" then coin_field = f2 end end
        end
    end
    local gs = space:read_u16(symbols["gstate"])
    if gs == 1 and not poked then
        if MODE == "netplay" then space:write_u16(symbols["f_netplay"], 1) end
        poked = frame
        log(string.format("mode=%s attract at frame %d", MODE, frame))
    end
    if not poked then return end
    -- drop two coins in coin mode so get_cstr is definitely re-run
    if coin_field then
        local t = frame - poked
        coin_field:set_value(((t > 60 and t < 66) or (t > 120 and t < 126)) and 1 or 0)
    end
    if frame % 20 == 0 then
        local s = str_at(symbols["stringf_ram"], 24)
        if s ~= last and #s > 0 then
            last = s
            log(string.format("frame %d stringf_ram = %q", frame, s))
            seen = seen + 1
        end
    end
    local t = frame - poked
    if t > 100 and t % 40 == 0 then manager.machine.video:snapshot() end
    if t > 700 then manager.machine:exit() end
end)
