-- hidden_earn_test.lua - EARNING a hidden fighter, end to end (hidearn, MAINEQU.ASM).
--
--   1P game, P1 Liu Kang, the CPU forced to HE_TARGET at the select screen;
--   P1's bar pinned full, the CPU's held at 1, P1 walks in punching and wins 2-0
--   -> results_of_round (MAIN.ASM) -> hidden_earn_check / hidden_earn (MKINIT.ASM)
--   -> hid_earned in RAM + adj_hidearn in cmos
--   -> soft reset (a warmset: .bss is cleared) -> dipinit reloads hid_earned
--      out of cmos, which is the proof the unlock outlasts the reset.
--
-- Run on a FRESH private nvram directory: the "before" read must be 0.
--
--   HE_TARGET  ochar the CPU plays (16 Jade, 13 Shao Kahn, 14 Smoke; anything
--              else is the control - nothing may be earned)
--   HE_EXPECT  the hid_earned value the win must produce (0 for the control)
--   HE_LOSE    1 = the HUMAN loses instead (P1 held at 1, CPU full): a control
--              that must earn nothing whoever the CPU is
--   HE_LOG     log path;  MK2_ROOT  tree whose src/mk2.map matches the ROM
--
-- MAME re-runs an autoboot script on soft_reset: guard, or the second copy
-- truncates the log.
if _G.HE_LOADED then return end
_G.HE_LOADED = true
local ROOT = (os.getenv("MK2_ROOT") or "."):gsub("\\", "/")
local TARGET = tonumber(os.getenv("HE_TARGET") or "16")
local EXPECT = tonumber(os.getenv("HE_EXPECT") or "1")
local LOSE = os.getenv("HE_LOSE") == "1"
local logfh = assert(io.open(assert(os.getenv("HE_LOG"), "HE_LOG"), "w"))
local function log(fmt, ...)
    local line = "[he] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end
local function finish(verdict, fmt, ...)
    log("%s " .. fmt, verdict, ...); logfh:close(); manager.machine:exit()
end

local S = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[n] = tonumber(a, 16) end
end
local function sym(n) return assert(S[n], "missing map symbol " .. n) end
local A = {
    gstate = sym("gstate"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p2_state = sym("p2_state"), p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    winner_status = sym("winner_status"), earned = sym("hid_earned"),
    p1_matchw = sym("p1_matchw"), p2_matchw = sym("p2_matchw"),
}
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP, FT_KANG = 0xa1, 1

local frame, space, fields = 0, nil, {}
local charsel, confirm, fight, matchend, reset_at = 0, 0, 0, 0, 0
local before, last_earned, last_gs = nil, nil, nil

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function pressed(name)
    if reset_at > 0 then return false end
    if charsel == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fight == 0 then
        return name == "P1 High Punch" and confirm > 0 and frame >= confirm and frame < confirm + 30
    end
    if LOSE or r16(A.gstate) ~= GS_FIGHTING then return false end
    local t = frame % 16
    if name == "P1 Right" then return true end
    if name == "P1 High Punch" then return t < 3 end
    if name == "P1 Low Punch" then return t >= 8 and t < 11 end
    return false
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"] = 1, ["1 Player Start"] = 1, ["P1 High Punch"] = 1, ["P1 Low Punch"] = 1,
                       ["P1 Right"] = 1 }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("START target=%d expect=%d lose=%s", TARGET, EXPECT, tostring(LOSE))
        if os.getenv("HE_TAP") == "1" then
            local cpu = manager.machine.devices[":maincpu"]
            _G.HE_TAPH = space:install_write_tap(A.earned, A.earned + 15, "he", function(off, data, mask)
                log("TAP write %04x pc=%08x frame=%d", data, cpu.state["PC"].value, frame)
            end)
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end
    local gs = r16(A.gstate)
    local earned = r16(A.earned)
    if earned ~= last_earned then
        log("hid_earned %s -> %d frame=%d gstate=%d winner_status=%d p1_matchw=%d p2_matchw=%d",
            tostring(last_earned), earned, frame, gs, r16(A.winner_status), r16(A.p1_matchw), r16(A.p2_matchw))
        last_earned = earned
    end

    -- after the reset: dipinit has run by the time the attract loop is up
    if reset_at > 0 then
        if frame - reset_at == 900 then
            log("AFTER_RESET hid_earned=%d", earned)
            if earned == EXPECT then finish("PASS", "earned=%d survived the reset", earned)
            else finish("FAIL", "after reset hid_earned=%d, want %d", earned, EXPECT) end
        end
        return
    end

    if gs == GS_PSEL and charsel == 0 then
        charsel = frame; before = earned
        log("select frame=%d BEFORE hid_earned=%d", frame, earned)
        if earned ~= 0 then finish("NOVERDICT", "nvram not fresh: hid_earned=%d before any match", earned) return end
    end
    if charsel > 0 and fight == 0 then
        w16(A.p1_char, FT_KANG); w16(A.p2_char, TARGET); w16(A.p2_state, 0)
        if confirm == 0 and frame - charsel > 90 then confirm = frame end
        if gs == GS_FIGHTING then
            fight = frame
            log("FIGHT frame=%d p1=%d p2=%d", frame, r16(A.p1_char), r16(A.p2_char))
        end
        if frame > 9000 then finish("NOVERDICT", "never reached the fight") end
        return
    end

    if gs ~= last_gs then
        log("gstate %d -> %d frame=%d winner_status=%d matchw=%d/%d", last_gs or -1, gs, frame,
            r16(A.winner_status), r16(A.p1_matchw), r16(A.p2_matchw))
        last_gs = gs
    end
    if matchend == 0 then
        if gs == GS_FIGHTING then
            if LOSE then
                w16(A.p2_bar, MAX_HP)
                if r16(A.p1_bar) > 1 then w16(A.p1_bar, 1) end
            else
                w16(A.p1_bar, MAX_HP)
                if r16(A.p2_bar) > 1 then w16(A.p2_bar, 1) end
            end
        end
        if r16(A.p1_matchw) >= 2 or r16(A.p2_matchw) >= 2 then
            matchend = frame
            log("MATCH_DECIDED frame=%d matchw=%d/%d hid_earned=%d", frame, r16(A.p1_matchw), r16(A.p2_matchw), earned)
        end
        if frame - fight > 30000 then finish("NOVERDICT", "match never decided") end
        return
    end
    -- give results_of_round time to run, then check RAM and reset
    if frame - matchend == 300 then
        log("BEFORE_RESET hid_earned=%d", earned)
        if earned ~= EXPECT then finish("FAIL", "after the match hid_earned=%d, want %d", earned, EXPECT) return end
        reset_at = frame
        manager.machine:soft_reset()
    end
end)
