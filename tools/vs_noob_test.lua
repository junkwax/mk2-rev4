-- vs_noob_test.lua
--
-- Proof shot for Noob Saibot's VS-screen portrait.
--
-- Noob's portrait is NOT a movie frame like everyone else's - the stock ones
-- are PKZIP-imploded payloads in the REVX pool and no compressor exists to
-- make another (see data/VSNOOB.LOD).  His is an ordinary 6bpp sprite in the
-- VSNOOB sidecar, blitted by vs_noob_portrait in MKSEL.ASM.
--
-- P1 is forced to Noob and P2 to Scorpion on purpose: that puts our sprite
-- and a stock movie portrait side by side in one frame, so placement and
-- palette can be judged against the real thing rather than from memory.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("VSNOOB_LOG") or (ROOT .. "/tools/vs_noob_test.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local raw_print = print
local function log(fmt, ...)
    local line = "[vs-noob] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
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
        log("loaded symbols from src/mk2.map")
    else
        log("WARN no linker map; using fallbacks")
    end
end
local function sym(n, fb) return symbols[n] or fb end

local A = {
    gstate   = sym("gstate", 0x0112a7f0),
    p1_char  = sym("p1_char", 0x0112a8a0),
    p2_char  = sym("p2_char", 0x0112b470),
    p1_state = sym("p1_state", 0x0112a810),
    p2_state = sym("p2_state", 0x0112b3e0),
    curback  = sym("curback", 0x0112c0f0),
}

local FT_NOOB, FT_SCORPION = 15, 10
-- VSNOOB_P1 lets a run swap P1 off Noob to isolate "is this my VS code, or is
-- it forcing a hidden fighter into the select screen from outside?"
local P1_PICK = tonumber(os.getenv("VSNOOB_P1") or tostring(FT_NOOB))
local PS_ACTIVE = 1
local GS_PSEL, GS_VS = 4, 0x0d
local STAGE = tonumber(os.getenv("VSNOOB_STAGE") or "5")

local frame, space, fields = 0, nil, {}
local charsel_frame, vs_frame, last_gstate = 0, 0, -1
local snaps, finished = 0, false
local stall_samples = 0

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["Coin 2"]=true, ["2 Players Start"]=true,
                   ["P1 High Punch"]=true, ["P2 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n, _ in pairs(want) do log("input %-16s %s", n, fields[n] and "ok" or "MISSING") end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
        return false
    end
    -- Forcing p1_char/p2_char is not enough: the picks still have to be
    -- CONFIRMED or the select screen never advances (the first run sat on
    -- gstate 4 forever).  Stagger the two so they register separately.
    if vs_frame == 0 then
        local rel = frame - charsel_frame
        if name == "P1 High Punch" then return rel >= 90 and rel < 130 end
        if name == "P2 High Punch" then return rel >= 170 and rel < 210 end
    end
    return false
end

local function snap(label)
    local ok, scr = pcall(function() return manager.machine.screens:at(1) end)
    if ok and scr then pcall(function() scr:snapshot() end) end
    snaps = snaps + 1
    log("SNAP %d %s (frame=%d)", snaps, label, frame)
end

local function finish(ok, why)
    if finished then return end
    finished = true
    log("%s reason=%s", ok and "PASS" or "ERROR", why)
    logfh:close()
    manager.machine:exit()
end

local function tick()
    frame = frame + 1
    if not space then
        local cpu = manager.machine.devices[":maincpu"]
        if not cpu then return end
        space = cpu.spaces["program"]
        cache_fields()
    end
    for name, f in pairs(fields) do f:set_value(pressed(name) and 1 or 0) end

    local g = r16(A.gstate)
    if g ~= last_gstate then
        log("gstate %d -> %d (frame=%d)", last_gstate, g, frame)
        last_gstate = g
    end
    if g == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        -- hold the picks every frame; the select screen writes them back
        w16(A.p1_char, P1_PICK)
        w16(A.p2_char, FT_SCORPION)
        w16(A.curback, STAGE)
        if A.p1_state ~= 0 then w16(A.p1_state, PS_ACTIVE) end
        if A.p2_state ~= 0 then w16(A.p2_state, PS_ACTIVE) end
    end
    if g == GS_VS and vs_frame == 0 then
        vs_frame = frame
        log("VS screen reached; p1_char=%d p2_char=%d", r16(A.p1_char), r16(A.p2_char))
    end
    -- let the page compose, then grab a few frames of it
    if vs_frame > 0 then
        local rel = frame - vs_frame
        if rel == 30 or rel == 60 or rel == 120 then snap(string.format("vs_rel_%03d", rel)) end
        if rel > 150 then finish(true, "vs_screen_captured") end
    end
    -- Lockup probe.  If the state machine stops advancing after the picks are
    -- confirmed, the game has wedged (this is what "it crashed" looks like from
    -- out here).  Sample the PC a few times so the hang can be resolved back to
    -- a symbol with sym_resolve.py instead of guessing.
    if charsel_frame > 0 and vs_frame == 0 and (frame - charsel_frame) > 300 then
        if (frame % 60) == 0 and stall_samples < 8 then
            stall_samples = stall_samples + 1
            local cpu = manager.machine.devices[":maincpu"]
            local pc = cpu.state["PC"].value
            log("STALL sample=%d gstate=%d PC=%08X  (byte %X)", stall_samples, r16(A.gstate), pc, pc // 8)
        end
        if stall_samples >= 8 then finish(false, "wedged_in_charsel_or_vs") end
    end
    if frame > 5400 then finish(false, "never_reached_vs_screen") end
end

emu.register_frame(tick)
log("loaded: P1=%d vs P2 Scorpion(%d), stage=%d", P1_PICK, FT_SCORPION, STAGE)
