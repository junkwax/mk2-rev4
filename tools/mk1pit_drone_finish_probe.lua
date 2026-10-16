-- mk1pit_drone_finish_probe.lua
--
-- THE PIT (MK1): does the CPU use the pit?  A one-player game on curback 01Ah;
-- which side the human is on is read from pm_joy, not assumed from the button.
-- The human is held at 1 HP and never presses anything, so the drone wins two
-- rounds and reaches drone_finish_him (MKDRONE.ASM).  On a fresh CMOS its
-- audit sends it to uppercut_finish, which on this stage takes
-- do_down_the_mk1pit when @rand is negative - this rig pins @rand negative for
-- the FINISH HIM window so the trial is the pit branch every time.
--
-- PASS: the human gets act_mk1pit_fall, the camera reaches mk1p_fall_cam
-- and f_death goes to -1.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("MD_TEST_LOG") or (ROOT .. "/tools/mk1pit_drone_finish_probe.log")

local EQ = {}
do
    local fh = io.open(ROOT .. "/src/MK1PTOPB.ASM", "r")
    for line in fh:lines() do
        local name, val = line:match("^(mk1p_[%w_]+)%s+%.set%s+(%-?%w+)")
        if name then
            local hex = val:match("^0?(%x+)[hH]$")
            EQ[name] = hex and tonumber(hex, 16) or tonumber(val)
        end
    end
    fh:close()
end

local logfh = io.open(LOG_PATH, "w")
local function log(fmt, ...)
    local line = "[dronepit] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[name] = tonumber(addr, 16) end
    end
    fh:close()
end
local A = {}
for _, n in ipairs({ "gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "p2_proc", "curback",
                     "p1_bar", "p2_bar", "winner_status", "f_death", "worldtly", "rand" }) do
    A[n] = symbols[n] or 0
    if A[n] == 0 then log("WARN missing symbol %s", n) end
end

local GS_PSEL, GS_FIGHTING = 4, 2
local STAGE, FT_JAX, FT_KANG = 0x1a, 11, 1
local ACT_FALL = 0x050d
local space, fields = nil, {}
local frame, last_gstate = 0, -1
local charsel_frame, fought, fall_frame, cam_max = 0, false, 0, -32768
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end

local function finish(ok, why)
    if finished then return end
    finished = true
    log("RESULT %s reason=%s cam_max=%d cam_target=%s f_death=%d", ok and "PASS" or "FAIL", why, cam_max,
        tostring(EQ.mk1p_fall_cam), s16(r16(A.f_death)))
    pcall(function() manager.machine.screens[":screen"]:snapshot() end)
    if logfh then logfh:close(); logfh = nil end
    manager.machine:exit()
end

local function action(proc_sym)
    local p = r32(proc_sym)
    return p ~= 0 and r16(p + 0x1f0) or 0xffff
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if f.name == "Coin 2" or f.name == "2 Players Start" or f.name == "P2 High Punch" then fields[f.name] = f end
            end
        end
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("frame=%d gstate %d -> %d ws=%d curback=%02x", frame, last_gstate, gs, r16(A.winner_status), r16(A.curback))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING then fought = true end
        last_gstate = gs
    end
    if not fought or gs ~= GS_FIGHTING then
        w16(A.p1_char, FT_JAX); w16(A.p2_char, FT_KANG); w16(A.curback, STAGE)
    end

    local press = {
        ["Coin 2"] = charsel_frame == 0 and frame >= 220 and (frame % 80) < 20,
        ["2 Players Start"] = charsel_frame == 0 and frame >= 260 and (frame % 80) >= 30 and (frame % 80) < 55,
        ["P2 High Punch"] = charsel_frame > 0 and not fought and frame >= charsel_frame + 120 and frame < charsel_frame + 160,
    }
    for name, f in pairs(fields) do f:set_value(press[name] and 1 or 0) end

    -- which side is the human?  pm_joy (bit 0 of p_flags, pdata+110h) on his
    -- process.  The start button alone does not decide it reliably.
    local p1p, p2p = r32(A.p1_proc), r32(A.p2_proc)
    local human_is_p1 = p1p ~= 0 and (r16(p1p + 0x210) & 1) == 1
    local human_bar = human_is_p1 and A.p1_bar or A.p2_bar
    local drone_bar = human_is_p1 and A.p2_bar or A.p1_bar
    local human_proc = human_is_p1 and A.p1_proc or A.p2_proc
    if gs == GS_FIGHTING then
        if r16(A.curback) ~= STAGE then finish(false, "wrong_stage"); return end
        w16(drone_bar, 0xa1)
        if r16(human_bar) > 1 then w16(human_bar, 1) end
    end
    local ws = r16(A.winner_status)
    if ws == 3 and fall_frame == 0 then
        w32(A.rand, r32(A.rand) | 0x80000000)   -- the pit branch, not the plain uppercut
    end
    if fall_frame == 0 and action(human_proc) == ACT_FALL then
        fall_frame = frame
        log("frame=%d HUMAN (%s) GETS act_mk1pit_fall", frame, human_is_p1 and "P1" or "P2")
    end
    if fall_frame > 0 then
        local y = s16(r16(A.worldtly + 16))
        if y > cam_max then cam_max = y end
        if frame - fall_frame == 60 then pcall(function() manager.machine.screens[":screen"]:snapshot() end) end
        if frame - fall_frame >= 240 then
            local ok = cam_max == EQ.mk1p_fall_cam and s16(r16(A.f_death)) == -1
            finish(ok, ok and "drone_used_the_pit" or "fall_incomplete")
            return
        end
    end
    if frame % 600 == 0 then
        log("status frame=%d gs=%d ws=%d human=%s p1act=%04x p2act=%04x bars=%d/%d", frame, gs, ws,
            human_is_p1 and "P1" or "P2", action(A.p1_proc), action(A.p2_proc), r16(A.p1_bar), r16(A.p2_bar))
    end
    if frame > 36000 then finish(false, "timeout") end
end)
