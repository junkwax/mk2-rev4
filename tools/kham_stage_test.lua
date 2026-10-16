-- kham_stage_test.lua
--
-- The KHAMELEON encounter must be fought on YOTEIGAI TOR (curback 018h).
--
-- boss_minumum_diff (MAIN.ASM) forces the arena and difficulty 8 for a
-- hidden fighter, but ONLY when the CPU is playing them - secret_is_cpu
-- gates it, because forcing the stage on a human pick was the Jade bug that
-- dragged a player who unlocked her to Goro's Lair for the whole ladder.
-- So there are two things to check and they are opposites:
--
--   KHAM_STAGE_MODE=cpu    P2 is a drone Khameleon -> curback MUST be 018h
--   KHAM_STAGE_MODE=human  P1 is Khameleon         -> curback must NOT be
--                          forced; the selected stage stands
--
-- Reaching her uses the jade_boomerang_test trick: hover Kitana at the
-- select screen and overwrite the char at GS_POST, since forcing a hidden
-- id at GS_PSEL never confirms.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("KHAM_STAGE_MODE") or "cpu"
local LOG = os.getenv("KHAM_STAGE_LOG") or (ROOT .. "/tools/kham_stage_test.log")
local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local s = "[kham-stage] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(s); logfh:write(s, "\n"); logfh:flush()
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
local function sym(n) return symbols[n] end

local A = {
    gstate = sym("gstate"), curback = sym("curback"), diff = sym("diff"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
}
for k, v in pairs(A) do if not v then log("FATAL: symbol '%s' not in mk2.map", k) end end

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_JAX, FT_KHAM = 4, 11, 18
local YOTEIGAI_TOR = 0x18
-- KHAM_STAGE_HIDDEN / KHAM_STAGE_WANT let this run as a CONTROL against a
-- fighter whose stage forcing already shipped (Jade=16 -> curback 9), so a
-- failure can be attributed to the wiring rather than to the probe.
local HIDDEN = tonumber(os.getenv("KHAM_STAGE_HIDDEN") or tostring(FT_KHAM))
local WANT   = tonumber(os.getenv("KHAM_STAGE_WANT") or tostring(YOTEIGAI_TOR))

local frame, space, finished = 0, nil, false
local fields = {}
local charsel_frame, confirm_frame = 0, 0
local tr_key = nil
local fight_frame = 0

local function r16(a) return space and space:read_u16(a) or 0 end
local function w16(a, v) if space then space:write_u16(a, v & 0xffff) end end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("%s mode=%s reason=%s", ok and "PASS" or "FAIL", MODE, reason)
    logfh:flush(); logfh:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = { ["UI Select"] = true, ["Coin 1"] = true, ["1 Player Start"] = true,
                     ["P1 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("mode=%s (cpu: P2 drone Khameleon; human: P1 Khameleon)", MODE)
    end
    if not space or finished then
        for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
        return
    end

    local gs = r16(A.gstate)
    do
        local cb, df = r16(A.curback), r16(A.diff)
        local key = string.format("%02x|%02x|%d|%d|%d|%d|%d", gs, cb, df,
            r16(A.p1_char), r16(A.p2_char), r16(A.p1_state), r16(A.p2_state))
        if key ~= tr_key then
            log("  f=%5d gstate=0x%02x curback=0x%02x diff=%d p1=%d p2=%d p1st=%d p2st=%d",
                frame, gs, cb, df, r16(A.p1_char), r16(A.p2_char),
                r16(A.p1_state), r16(A.p2_state))
            tr_key = key
        end
    end
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        -- ONLY P1.  Writing p2_char here brings P2's select proc to life and
        -- the match becomes two-player: p2_state goes ps_active, which makes
        -- secret_is_cpu answer "a human has her" and count_active_players
        -- return 2 - and boss_minumum_diff then deliberately leaves both the
        -- arena and the difficulty alone.  The probe was manufacturing the
        -- exact condition the feature is designed to skip.
        w16(A.p1_char, FT_KITANA)
        if confirm_frame == 0 and frame - charsel_frame > 90 then
            confirm_frame = frame; log("confirming at frame %d", frame)
        end
    elseif gs ~= GS_FIGHTING and confirm_frame > 0 then
        -- Stamp the pair on EVERY post-select state, not just GS_POST.
        -- boss_minumum_diff runs from round_init, which is somewhere between
        -- the select screen and the fight; a probe that only writes during
        -- GS_POST lets round_init read the pre-override pair and then reports
        -- "the stage was not forced" when in fact it was never asked.
        if MODE == "cpu" then
            w16(A.p1_char, FT_JAX); w16(A.p2_char, HIDDEN)
        else
            w16(A.p1_char, HIDDEN); w16(A.p2_char, FT_JAX)
        end
    elseif gs == GS_FIGHTING then
        -- Judge LATE.  round_init (which is where boss_minumum_diff lives)
        -- does not necessarily land before the first GS_FIGHTING frame, and
        -- reading curback there reported 0x00 / diff 0 even for Jade, whose
        -- forcing has shipped for months.  That was the probe, not the ROM.
        if fight_frame == 0 then fight_frame = frame end
        if frame - fight_frame < 150 then
            for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
            return
        end
        local cb = r16(A.curback)
        log("fight started p1=%d p2=%d curback=0x%02x diff=%d",
            r16(A.p1_char), r16(A.p2_char), cb, r16(A.diff))
        for _, scr in pairs(manager.machine.screens) do pcall(function() scr:snapshot() end) end
        if MODE == "cpu" then
            if cb == WANT then
                finish(true, string.format("curback=0x%02x as wanted", cb))
            else
                finish(false, string.format("curback=0x%02x, wanted 0x%02x", cb, WANT))
            end
        else
            -- A human Khameleon must NOT be dragged to her arena.
            if cb ~= WANT then
                finish(true, string.format("curback=0x%02x - not forced, as intended", cb))
            else
                finish(false, "a HUMAN Khameleon was forced onto YOTEIGAI TOR")
            end
        end
        return
    end

    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if frame > 4000 then finish(false, "timeout") end
end)
emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
