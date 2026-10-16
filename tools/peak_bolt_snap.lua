-- Capture YOTEIGAI TOR's big strike (thunder4) and a small bolt, on frames
-- where they are actually on screen.
--
-- peak_stage_test snapshots 3 frames after it first SEES a bolt, which is a
-- lucky-frame lottery: the strike is brief and its table starts on its
-- smallest frame, so most of those shots catch the sky and nothing else.
-- This watches baklst2 every frame and shoots on width instead - thunder4
-- reaches 47 wide at full extent and nothing else in peak_lightning_table
-- gets past 40, so width IS the slot.
--
-- Boot schedule lifted from tools/peak_stage_test.lua.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("BOLT_LOG") or (ROOT .. "/tools/peak_bolt_snap.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[bolt] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(ROOT .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
end
local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
                     "map_position", "battle_num", "worldtly", "baklst2", "rand" }) do
    A[n] = symbols[n]
    if not A[n] then log("MISSING SYMBOL %s", n) end
end

local ONEXT, OXPOS, OYPOS, OSIZEX, OSIZEY = 0x00, 0x090, 0x0b0, 0x120, 0x130
local OPAL = 0x140   -- the allocated colour map from getfpal; 0 means
                     -- object_setup's getfpal FAILED and the sprite is
                     -- drawing through map 0 (boonpal), not its own
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_SUBZERO, FT_KANG = 8, 1
local PEAK = 0x18
local PEAK_DECK_Y = 247          -- BGND.ASM, the deck's top row in world y

local READY_PATH = os.getenv("BOLT_READY") or (ROOT .. "/tools/peak_bolt_ready.flag")
local ready_written = false
local frame, space, finished = 0, nil, false
local fields, held = {}, {}
local charsel_frame, fighting_frame, confirm_frame = 0, 0, 0
local big_shots, small_shots = 0, 0

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function world(a) return s16(r32(a) >> 16) end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true, ["Coin 2"] = true,
                   ["1 Player Start"] = true, ["2 Players Start"] = true,
                   ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local function snap()
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and screen then pcall(function() screen:snapshot() end) end
end

local function finish(reason)
    if finished then return end
    finished = true
    log("big=%d small=%d  %s", big_shots, small_shots, reason)
    logfh:close(); manager.machine:exit()
end

emu.register_frame_done(function()
    if finished then return end
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
    end
    if not ready_written and frame >= 120 then
        local fh = io.open(READY_PATH, "w")
        if fh then fh:write("running"); fh:close(); ready_written = true end
    end

    held = {}
    if frame >= 5 and frame < 35 then held["UI Select"] = true end
    if frame >= 700 and frame < 980 and frame % 80 < 20 then held["Coin 1"] = true end
    if frame >= 720 and frame < 980 and frame % 80 < 20 then held["Coin 2"] = true end
    if frame >= 1000 and frame < 1080 then held["1 Player Start"] = true end
    if frame >= 1040 and frame < 1140 then held["2 Players Start"] = true end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_KANG)
        w16(A.curback, PEAK)
        if A.map_position then w16(A.map_position, 0) end
        if A.battle_num then w16(A.battle_num, 1) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        if confirm_frame > 0 then
            if frame >= confirm_frame and frame < confirm_frame + 45 then held["P1 High Punch"] = true end
            if frame >= confirm_frame + 70 and frame < confirm_frame + 115 then held["P2 High Punch"] = true end
        end
    end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if not space then return end

    if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
    if fighting_frame == 0 then
        if frame > 4000 then finish("never reached a fight") end
        return
    end
    if gs ~= GS_FIGHTING then return end

    -- @rand is reseeded identically every round start, so an unstirred rig
    -- replays one fixed sequence of slot draws and can miss slot 5 entirely.
    if (frame - fighting_frame) % 91 == 0 and A.rand then
        w16(A.rand, (frame * 2654435761) & 0xffff)
    end

    local obj, guard = r32(A.baklst2), 0
    while obj ~= 0 and guard < 60 do
        local w = r16(obj + OSIZEX)
        local h = r16(obj + OSIZEY)
        local sy = s16(r16(obj + OYPOS)) - world(A.worldtly)
        if w >= 44 and big_shots < 3 then
            big_shots = big_shots + 1
            log("STRIKE  w=%d h=%d screen_y=%d tail=%d  deck=%d  gap=%d  opal=%04x",
                w, h, sy, sy + h, PEAK_DECK_Y - world(A.worldtly),
                (PEAK_DECK_Y - world(A.worldtly)) - (sy + h), r16(obj + OPAL))
            snap()
        elseif w >= 30 and w < 44 and small_shots < 2 then
            small_shots = small_shots + 1
            log("small   w=%d h=%d screen_y=%d tail=%d  opal=%04x",
                w, h, sy, sy + h, r16(obj + OPAL))
            snap()
        end
        obj = r32(obj + ONEXT); guard = guard + 1
    end

    if big_shots >= 3 and small_shots >= 2 then finish("captured") end
    if frame - fighting_frame > 2200 then
        finish(big_shots > 0 and "captured what came up" or "no strike in the window")
    end
end)
