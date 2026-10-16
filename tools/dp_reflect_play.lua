-- dp_reflect_play.lua - drop straight into a Dead Pool fight to look at the
-- acid reflections, then hand control back.
--
--   tools\run_dp_reflect.ps1
--
-- Forces stage 0 through character select (curback is read at MAIN.ASM:636,
-- so it has to be set BEFORE the fight starts or calla_dedpool never runs and
-- there are no hanging bodies at all), parks the fighters either side of Ed so
-- he is on screen, then releases everything and leaves the game to you.
--
-- Numpad 1 re-frames Ed if you have wandered off.  Numpad 2 toggles a readout.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    hp_body_ptr = sym("hp_body_ptr"),
    ground_y = sym("ground_y"), worldtlx = sym("worldtlx"),
}
local OXPOS, OXVAL, OYPOS = 0x90, 0x80, 0xb0
local DEADPOOL, GS_PSEL, GS_FIGHT = 0, 4, 2

local frame, space, fields = 0, nil, {}
local psel, fighting, p1c, p2c = 0, 0, 0, 0
local framed, hud = false, true
local input_sys, debounce = nil, {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end

-- Only used to get INTO the fight; everything is released afterwards so the
-- player is never fighting the script for the controls.
local function pressed(name)
    if fighting > 0 then return false end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1c > 0 then return frame >= p1c and frame < p1c + 45 end
    if name == "P2 High Punch" and p2c > 0 then return frame >= p2c and frame < p2c + 45 end
    return false
end

local function frame_ed()
    local ed = r32(A.hp_body_ptr)
    if ed == 0 then return false end
    local ex = s16(r16(ed + OXPOS))
    for i, o in ipairs({ r32(A.p1_obj), r32(A.p2_obj) }) do
        if o ~= 0 then
            local tx = ex + (i == 1 and -40 or 40)
            w16(o + OXPOS, tx)
            space:write_u32(o + OXVAL, (tx << 16) & 0xffffffff)
        end
    end
    return true
end

local function draw_hud()
    if not hud then return end
    local scr
    for _, s in pairs(manager.machine.screens) do scr = s break end
    if not scr then return end
    local ed = r32(A.hp_body_ptr)
    local lines = {
        "DEAD POOL ACID REFLECTIONS",
        "fighters = green   Ed (hanger 0) = bright green",
        string.format("look in the acid strip just above the walkway%s",
            ed == 0 and "   [no hanger built]" or ""),
        "numpad 1 = re-frame Ed    numpad 2 = hide this",
    }
    local h = 254
    local ok, sh = pcall(function() return scr.height end)
    if ok and sh and sh > 0 then h = sh end
    local y = h - (#lines * 9) - 3
    for i = 1, #lines do
        scr:draw_text(2, y, lines[i], 0xffffff00, 0xc0000000)
        y = y + 9
    end
end

local HOTKEYS = {
    { "KEYCODE_1_PAD", function() framed = frame_ed() end },
    { "KEYCODE_2_PAD", function() hud = not hud end },
}

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        input_sys = manager.machine.input
        local want = { ["Coin 1"]=1, ["1 Player Start"]=1, ["2 Players Start"]=1,
                       ["P1 High Punch"]=1, ["P2 High Punch"]=1 }
        for _, p in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(p.fields) do if want[f.name] then fields[f.name] = f end end
        end
        print("[dp] booting into the Dead Pool, ~25s")
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and psel == 0 then psel = frame end
    if psel > 0 and p1c == 0 and frame - psel > 90 then p1c = frame end
    if psel > 0 and p2c == 0 and frame - psel > 150 then p2c = frame end
    if psel > 0 and fighting == 0 then
        w16(A.p1_char, 1)          -- Liu Kang
        w16(A.p2_char, 8)          -- Sub-Zero
        w16(A.curback, DEADPOOL)   -- must land before MAIN.ASM:636 reads it
    end
    if gs == GS_FIGHT and fighting == 0 then
        fighting = frame
        print("[dp] fight up - framing Ed, then the controls are yours")
    end

    -- one-shot framing, ~1s in, then hands off for good
    if fighting > 0 and not framed and frame - fighting > 60 then
        framed = frame_ed()
        if framed then
            for _, f in pairs(fields) do f:clear_value() end
        end
    end

    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end

    for _, hk in ipairs(HOTKEYS) do
        local ok, code = pcall(function() return input_sys:code_from_token(hk[1]) end)
        if ok and code then
            local ok2, down = pcall(function() return input_sys:code_pressed(code) end)
            if ok2 then
                if down and not debounce[hk[1]] then hk[2]() end
                debounce[hk[1]] = down
            end
        end
    end

    pcall(draw_hud)
end)
