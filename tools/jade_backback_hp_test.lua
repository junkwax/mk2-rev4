-- jade_backback_hp_test.lua
-- Repro for user report: playing as Jade, Back,Back+HP crashes the game.
-- Boot/select mirrors smoke_cheat_test.lua (proven on the CURRENT ROM):
-- pulsed coin/start, force p1_char=Kitana@PSEL, then overwrite FT_JADE@POST.
-- In-fight, repeatedly input Back,Back+HP (Back=Left, P1 faces right) and
-- trap the crash PC.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("JADE_BB_LOG") or (ROOT .. "/tools/jade_backback_hp_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[jade-bb] " .. string.format(fmt, ...)
    raw_print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r") or io.open(ROOT .. "/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(name, fallback) return symbols[name] or fallback end

local A = {
    gstate        = sym("gstate", 0x0112a830),
    p1_obj        = sym("p1_obj", 0x0112a880),
    p1_proc       = sym("p1_proc", 0x0112a8c0),
    p1_char       = sym("p1_char", 0x0112a8e0),
    p2_obj        = sym("p2_obj", 0x0112b450),
    p2_char       = sym("p2_char", 0x0112b4b0),
    p1_bar        = sym("p1_bar", 0x0112a910),
    p2_bar        = sym("p2_bar", 0x0112aa70),
    c_jade_cheat1 = sym("c_jade_cheat1", nil),
    f_jade_cheat1 = sym("f_jade_cheat1", nil),
    system_lockup = sym("system_lockup", 0xffa85db0),
    tvbp          = sym("TVBP", 0xffa85fc0),
}
-- JADE_SELECT: "debug" (Kitana@PSEL -> Jade@POST) or "secret" (the REAL unlock:
-- hover Mileena, Low-Kick x6 - the 6th confirms and applies Jade).
local SELECT = (os.getenv("JADE_SELECT") or "debug"):lower()
local FT_MILEENA = 5
local P_ACTION = 0x1f0
local OXVAL, OXPOS, OFLAGS = 0x80, 0x90, 0xf0
local B_FLIPH = 0x10   -- oflags bit 4 set = facing left
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_REPTILE, FT_JADE = 4, 9, 16

-- JADE_INPUT selects the in-fight motion (Back=Left, Forward=Right, P1 faces right):
--   bb = Back,Back + HP (normal HP)    bf = Back,Forward + HP (boomerang)
--   fb = Forward,Back + HP             ff = Forward,Forward + HP
local INPUT = (os.getenv("JADE_INPUT") or "bf"):lower()
local BTN = (os.getenv("JADE_BTN") == "HK") and "P1 High Kick" or "P1 High Punch"
local D1 = (INPUT:sub(1,1) == "f") and "P1 Right" or "P1 Left"
local D2 = (INPUT:sub(2,2) == "f") and "P1 Right" or "P1 Left"

local frame, cpu, space, finished = 0, nil, nil, false
local fields = {}
local psel, fight = 0, 0
local last_gs = -1
local last_pc, stuck = nil, 0
local attempt, last_logged = 0, -1
local last_act, snap_seq = 0xffff, nil
local last_status_act, fires = -1, 0

local function r16(a) return space and space:read_u16(a) or 0 end
local function r32(a) return space and space:read_u32(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end
local function reg(n)
    if not cpu then return nil end
    local ok, v = pcall(function() return cpu.state[n].value end)
    return ok and v or nil
end
local function pc() return reg("PC") or reg("CURPC") or reg("GENPC") or 0 end
local function p1_action()
    local p = r32(A.p1_proc); if p == 0 then return 0xffff end
    return r16(p + P_ACTION)
end
local function obj_x(a) local o = r32(a); if o == 0 then return 0 end; return r16(o + OXPOS) end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("%s reason=%s (attempts=%d)", ok and "PASS" or "CRASH/FAIL", reason, attempt)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

local snap_n = 0
local function snap(label)
    local ok, screen = pcall(function() return manager.machine.screens[":screen"] end)
    if not (ok and screen) then ok, screen = pcall(function() return manager.machine.screens:at(1) end) end
    if ok and screen then pcall(function() screen:snapshot() end); snap_n = snap_n + 1; log("SNAP %s frame=%d", label, frame) end
end

local held = {}
local function hold(name, on) held[name] = on and true or false end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
        ["P1 Right"] = true, ["P1 Left"] = true, ["P1 High Punch"] = true,
        ["P1 High Kick"] = true, ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do log("input %-16s %s", name, fields[name] and "ok" or "MISSING") end
end

local ATTEMPT = 18

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("loaded. input=%s (D1=%s D2=%s) lockup=[%08x,%08x)", INPUT, D1, D2, A.system_lockup, A.tvbp)
    end
    if not space then return end
    if finished then
        for name, field in pairs(fields) do field:set_value(held[name] and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    if gs ~= last_gs then
        log("gstate %d -> %d (frame=%d)", last_gs, gs, frame)
        if gs == GS_PSEL and psel == 0 then psel = frame; log("select reached frame=%d", frame) end
        if gs == GS_FIGHTING and fight == 0 then
            fight = frame
            log("fight started p1=%d p2=%d p1hp=%d p2hp=%d", r16(A.p1_char), r16(A.p2_char), r16(A.p1_bar), r16(A.p2_bar))
        end
        last_gs = gs
    end

    -- reset all holds each frame
    for k in pairs(held) do held[k] = false end

    if psel == 0 then
        -- boot: pulsed coin + 1P start (smoke_cheat_test pattern)
        hold("Coin 1", frame >= 200 and frame < 3000 and (frame % 80) < 20)
        hold("1 Player Start", frame >= 300 and frame < 3000 and (frame % 80) >= 45 and (frame % 80) < 70)
        hold("UI Select", frame >= 5 and frame < 35)
    elseif gs == GS_PSEL then
        local rel = frame - psel
        if SELECT == "secret" then
            -- REAL unlock: hover Mileena, 6 Low-Kick press/release cycles.
            -- 1-5 are swallowed (count only); the 6th sets f_jade_cheat1 AND
            -- confirms.  Do NOT overwrite p1_char at POST - the cheat applies it.
            w16(A.p1_char, FT_MILEENA)
            if rel > 40 then
                local ph = (rel - 40) % 12
                local k  = (rel - 40) // 12
                if k < 7 then hold("P1 Low Kick", ph < 6) end
            end
            if rel % 30 == 0 and A.c_jade_cheat1 then
                log("  psel rel=%d c_jade=%d f_jade=%d p1_char=%d", rel,
                    r16(A.c_jade_cheat1), A.f_jade_cheat1 and r16(A.f_jade_cheat1) or -1, r16(A.p1_char))
            end
        else
            -- debug: force Kitana, pulse HP to confirm
            w16(A.p1_char, FT_KITANA)
            if rel > 40 then hold("P1 High Punch", (rel % 12) < 6) end
        end
    elseif gs == GS_POST then
        if SELECT ~= "secret" then w16(A.p1_char, FT_JADE) end
    elseif gs == GS_FIGHTING and fight > 0 then
        local r = frame - fight
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        -- Park P2 far right + top up HP so the round stays alive and the AI
        -- doesn't interfere.  Do NOT pin Jade - let her throw/animate naturally.
        w16(A.p1_bar, 0xA1); w16(A.p2_bar, 0xA1)
        -- JADE_RIGHT=1 pins Jade on the RIGHT (facing left), P2 left - matches the
        -- crash screenshot.  JADE_SPAM pins Jade left.  Else only park P2 right.
        local rightside = os.getenv("JADE_RIGHT") == "1"
        local spam = os.getenv("JADE_SPAM") == "1"
        local function pin(o, x) if o ~= 0 then w16(o + OXPOS, x); space:write_u32(o + OXVAL, (x << 16) & 0xffffffff) end end
        if rightside then pin(p1o, 540); pin(p2o, 120)
        elseif spam then  pin(p1o, 120); pin(p2o, 660)
        else              pin(p2o, 660) end
        if r >= 50 then
            local facingL = p1o ~= 0 and (r16(p1o + OFLAGS) & B_FLIPH) ~= 0
            local BACK = facingL and "P1 Right" or "P1 Left"
            local FWD  = facingL and "P1 Left"  or "P1 Right"
            -- INPUT chars pick each tap (facing-aware): bb/bf/fb/ff.
            -- fb = Forward,Back + HP (the user's repro).
            local dir1 = (INPUT:sub(1,1) == "f") and FWD or BACK
            local dir2 = (INPUT:sub(2,2) == "f") and FWD or BACK
            if os.getenv("JADE_SPAM") == "1" then
                local c = (r - 50) % 20
                hold(dir1, c >= 0 and c < 3)
                hold(dir2, c >= 5 and c < 8)
                hold(BTN, c >= 10 and c < 14)
            else
                for _, base in ipairs({80, 220, 360, 500, 640}) do
                    local d = r - base
                    hold(dir1, d >= 0 and d < 4)
                    hold(dir2, d >= 6 and d < 10)
                    hold(BTN, d >= 12 and d < 16)
                end
            end
            -- count actual boomerang launches (act 0x0112 rising edges)
            local a = p1_action()
            if a == 0x0112 and last_act ~= 0x0112 then fires = (fires or 0) + 1 end
            -- track distinct p1 actions so we can prove the input registered
            if a ~= last_status_act then
                log("  r=%d p1act=0x%04x pc=%08x p1x=%d p2x=%d", r, a, pc(), obj_x(A.p1_obj), p2o ~= 0 and r16(p2o + OXPOS) or 0)
                last_status_act = a
            end
        end

        -- idle-shadow reference snapshot before any throw
        if r == 60 then snap("idle_before_throw") end

        -- snapshot the throw + aftermath to SEE what is garbled and whether
        -- it follows Jade, follows the boomerang, or persists on the ground.
        local act = p1_action()
        if os.getenv("JADE_SPAM") ~= "1" and act == 0x0112 and last_act ~= 0x0112 and snap_n < 20 then
            snap_seq = { frame + 3, frame + 8, frame + 16, frame + 30, frame + 55 }
        end
        last_act = act
        if snap_seq then
            for i, f in ipairs(snap_seq) do
                if f == frame then snap(string.format("throw%d_r%d", i, r)) end
            end
            if snap_seq[#snap_seq] < frame then snap_seq = nil end
        end

        -- crash detectors
        local cur = pc()
        if cur >= A.system_lockup and cur < A.tvbp then
            log("LOCKUP pc=%08x r=%d attempt=%d p1act=0x%04x", cur, r, attempt, p1_action())
            log("  A7=%08x A8=%08x A9=%08x A10=%08x A11=%08x A13=%08x A14=%08x SP=%08x",
                reg("A7") or 0, reg("A8") or 0, reg("A9") or 0, reg("A10") or 0,
                reg("A11") or 0, reg("A13") or 0, reg("A14") or 0, reg("SP") or 0)
            finish(false, string.format("lockup_pc=%08x", cur)); return
        end
        if gs == 0xffff or gs > 0x40 then
            log("BAD_GSTATE gs=0x%04x r=%d pc=%08x", gs, r, cur)
            finish(false, string.format("bad_gstate=0x%04x pc=%08x", gs, cur)); return
        end
        if cur == last_pc then stuck = stuck + 1 else stuck = 0; last_pc = cur end
        if stuck >= 90 then
            log("CPU_STUCK pc=%08x r=%d attempt=%d p1act=0x%04x", cur, r, attempt, p1_action())
            finish(false, string.format("cpu_stuck pc=%08x", cur)); return
        end

        local spam = os.getenv("JADE_SPAM") == "1"
        if r % 300 == 0 and spam then log("r=%d fires=%d p1act=0x%04x p2hp=%d", r, fires or 0, p1_action(), r16(A.p2_bar)) end
        if not spam and r > 820 then finish(true, "no_crash"); return end
        if spam and r > 1500 then finish(true, string.format("spam_done fires=%d (no crash)", fires or 0)); return end
    end

    if psel == 0 and frame > 4000 then finish(false, "never_reached_select"); return end
    if psel > 0 and fight == 0 and frame - psel > 1500 then finish(false, "never_reached_fighting"); return end

    for name, field in pairs(fields) do field:set_value(held[name] and 1 or 0) end
end)
