-- sz_floorice_pit_test.lua
-- Repro/fuzz harness for: "Sub-Zero ground freeze on the Pit Bottom stage
-- leaves the opponent stuck in a motion that slides off the screen and freezes
-- input on both controllers" (reported in a Sub-Zero vs Reptile match).
--
-- Forces the matchup + stage, freezes the round clock and both health bars so
-- the round never ends, then drives P1 through a repeating script of
--   ground freeze (D,B+LK) -> rush in -> attacks -> ice ball -> sweep
-- while the victim reacts, and watches for the lock-up signatures:
--   HARD_HANG       - PC unchanged for HANG_FRAMES (that is `ermac` = `jauc $`)
--   SLIP_STUCK      - act_slipping held far past its 0x40/0x50-tick budget
--   ICE_STUCK       - floor-ice proc alive long after the slip ended
--   OFFSCREEN       - victim's on-screen x far outside the visible window
--   SCOPE           - worldtlx escaping [left_edge, right_edge]
--   P1_UNRESPONSIVE - P1's p_action frozen while inputs are being driven
--
-- Env: FI_STAGE FI_P1 FI_P2 FI_P2HUMAN FI_OBSERVE FI_LABEL FI_LOG

local ROOT    = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local STAGE   = tonumber(os.getenv("FI_STAGE") or "10")   -- 10 = mk1pit_mod (Pit Bottom)
local P1CH    = tonumber(os.getenv("FI_P1") or "8")       -- ft_subzero
local P2CH    = tonumber(os.getenv("FI_P2") or "9")       -- ft_reptile
local P2HUMAN = (os.getenv("FI_P2HUMAN") or "0") ~= "0"
local OBSERVE = tonumber(os.getenv("FI_OBSERVE") or "9000")
local LABEL   = os.getenv("FI_LABEL") or string.format("floorice_stage%d", STAGE)
local LOG     = os.getenv("FI_LOG") or (ROOT .. "/tools/sz_floorice_pit_test.log")

local FREEZE_CLOCK = (os.getenv("FI_FREEZE_CLOCK") or "1") ~= "0"
-- FI_NOPOKE=1 : drive inputs only, never write game RAM. Control run to tell a
-- real game bug apart from something the harness's own pokes caused.
local NOPOKE = (os.getenv("FI_NOPOKE") or "0") ~= "0"
local HANG_FRAMES = 150     -- PC frozen this long = jauc $ (ermac)
local SLIP_BUDGET = 260     -- 0x50 ticks of slip + slack

local logfh = io.open(LOG, "a")
local frame = 0
local raw = print
print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    local l = table.concat(t, "\t")
    raw(l); if logfh then logfh:write(l, "\n"); logfh:flush() end
end
local function log(f, ...)
    print("[fice] " .. (select("#", ...) > 0 and string.format(f, ...) or tostring(f)))
end

-- ---------------------------------------------------------------- symbols
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
local function sym(n, fb)
    local v = symbols[n]; if v then return v end
    if fb == nil then log("WARN missing symbol %s", n) end
    return fb
end

local A = {
    active = sym("active"), gstate = sym("gstate"), curback = sym("curback"),
    map_position = sym("map_position", 0), battle_num = sym("battle_num", 0),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    worldtlx = sym("worldtlx"), left_edge = sym("left_edge"), right_edge = sym("right_edge"),
    winner_status = sym("winner_status", 0),
    f_freeze_timer = sym("f_freeze_timer", 0),
}

-- struct field offsets are TMS34010 bit offsets, added to pointers as-is
local O_OXPOS, O_OYPOS = 0x090, 0x0b0
local P_LINK, P_PROCID = 0x000, 0x020
local PA11, PA10       = 0x060, 0x080
local P_ACTION         = 0x1f0     -- pdata+0f0h
local P_STORE8         = 0x310     -- pdata+210h

local ACT_SLIPPING = 0x060e
local PID_FICE1, PID_FICE2 = 0x13, 0x14
local GS_PSEL, GS_FIGHTING = 4, 2
local PS_ACTIVE, PS_INACTIVE = 1, 0
local MAX_HP, SCRRGT = 0xA1, 400

-- ---------------------------------------------------------------- helpers
local cpu, space, fields = nil, nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end; return v end

local function cpu_pc()
    for _, n in ipairs({ "PC", "CURPC", "GENPC" }) do
        local ok, it = pcall(function() return cpu.state[n] end)
        if ok and it then
            local okv, v = pcall(function() return it.value end)
            if okv then return v end
        end
    end
    return nil
end

local function find_proc(pid)
    local p, n = r32(A.active), 0
    while p ~= 0 and n < 400 do
        if r16(p + P_PROCID) == pid then return p end
        p = r32(p + P_LINK); n = n + 1
    end
    return nil
end
local function ice_proc() return find_proc(PID_FICE1) or find_proc(PID_FICE2) end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end
local function snap(tag)
    local s = main_screen(); if not s then return end
    pcall(function() s:snapshot() end)
    log("SNAP %s frame=%d", tag, frame)
end

-- rolling history so a hang can be attributed to the move that was in flight
local hist, HIST_N = {}, 240
local function hist_push(s) hist[#hist + 1] = s; if #hist > HIST_N then table.remove(hist, 1) end end
local function hist_dump()
    log("---- last %d frames before the hang ----", #hist)
    for _, s in ipairs(hist) do print("[fice]   " .. s) end
    log("---- end history ----")
end

-- With -debug, pull the CPU's recent instruction history out of the debugger
-- console log: that names the routine that jumped into garbage.
local TRACE = (os.getenv("FI_TRACE") or "0") ~= "0"
local dbg_started = false
local function dbg()
    local ok, d = pcall(function() return manager.machine.debugger end)
    return ok and d or nil
end
local function dbg_run()
    local d = dbg(); if not d or dbg_started then return end
    dbg_started = true
    pcall(function() d.execution_state = "run" end)
    log("debugger attached; execution_state=run")
end
local function dbg_history(tag)
    local d = dbg(); if not d then log("no debugger (run with -debug for history)"); return end
    local before = 0
    pcall(function() before = #d.consolelog end)
    local ok = pcall(function() d:command("history ,120") end)
    if not ok then pcall(function() d:command("history") end) end
    local lines = {}
    pcall(function()
        local cl = d.consolelog
        for i = before + 1, #cl do lines[#lines + 1] = cl[i] end
    end)
    log("---- debugger history (%s), %d lines ----", tag, #lines)
    for _, l in ipairs(lines) do print("[fice] H| " .. tostring(l)) end
    log("---- end history ----")
end

local function dump_regs(tag)
    local names = { "PC", "SP", "ST" }
    for i = 0, 14 do names[#names + 1] = "A" .. i end
    for i = 0, 14 do names[#names + 1] = "B" .. i end
    local parts = {}
    for _, n in ipairs(names) do
        local ok, it = pcall(function() return cpu.state[n] end)
        if ok and it then
            local okv, v = pcall(function() return it.value end)
            if okv then parts[#parts + 1] = string.format("%s=%08x", n, v & 0xffffffff) end
        end
    end
    log("REGS(%s) %s", tag, table.concat(parts, " "))
    -- walk the system stack: return addresses point just past the caller
    local ok, sp = pcall(function() return cpu.state["SP"].value end)
    if ok and sp and sp ~= 0 then
        local words = {}
        for i = 0, 15 do
            local okv, v = pcall(function() return r32(sp + i * 32) end)
            words[#words + 1] = okv and string.format("%08x", v) or "????"
        end
        log("STACK@%08x %s", sp, table.concat(words, " "))
    end
end

local anomalies = {}
local function record(kind, detail)
    if not anomalies[kind] then
        anomalies[kind] = detail
        log("ANOMALY %s: %s", kind, detail)
        if kind == "HARD_HANG" then hist_dump() end
        snap("anomaly_" .. kind)
    end
end

-- ---------------------------------------------------------------- state
local last_gs = -1
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local finished = false
local casts, slips = 0, 0
local ice_live_since = 0
local slip_start, slip_logged = 0, 0
local last_pc, pc_same = nil, 0
local p1_act_last, p1_act_changed = -1, 0
local stage_ok = true

local function cache_fields()
    local want = {
        ["UI Select"] = 1, ["Coin 1"] = 1, ["1 Player Start"] = 1, ["2 Players Start"] = 1,
        ["P1 High Punch"] = 1, ["P1 Low Punch"] = 1, ["P1 High Kick"] = 1, ["P1 Low Kick"] = 1,
        ["P1 Left"] = 1, ["P1 Right"] = 1, ["P1 Down"] = 1, ["P1 Up"] = 1, ["P1 Block"] = 1,
        ["P2 High Punch"] = 1,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    local got = {}
    for k in pairs(fields) do got[#got + 1] = k end
    table.sort(got)
    log("fields: %s", table.concat(got, ", "))
end

local function force_matchup()
    if NOPOKE then return end
    w16(A.p1_state, PS_ACTIVE)
    w16(A.p2_state, P2HUMAN and PS_ACTIVE or PS_INACTIVE)
    w16(A.p1_char, P1CH); w16(A.p2_char, P2CH)
    w16(A.curback, STAGE)
    if A.map_position ~= 0 then w16(A.map_position, STAGE) end
    if A.battle_num ~= 0 then w16(A.battle_num, 1) end
end

-- P1 combat script, one 300-frame cycle. Sub-Zero starts on the left facing
-- right, so "back" is Left and "forward" is Right.
-- FI_SCRIPT selects which phases run, so a hang can be attributed:
--   full     - everything
--   ice      - ground freeze only (plus walking, to reach the puddle)
--   nofreeze - everything except the ground freeze
--   melee    - ground freeze + walk in + normals (no ice ball, no jump kick)
--   airball  - ground freeze + walk + ice ball only
--   jump     - ground freeze + walk + jump kick only
local SCRIPT = (os.getenv("FI_SCRIPT") or "full"):lower()
local function phase_on(p)
    if SCRIPT == "idle" or SCRIPT == "fwdonly" or SCRIPT == "backonly" then return false end
    if SCRIPT == "full" then return true end
    if SCRIPT == "ice" then return p == "freeze" or p == "walk" end
    if SCRIPT == "nofreeze" then return p ~= "freeze" end
    if SCRIPT == "melee" then return p == "freeze" or p == "walk" or p == "normals" or p == "back" end
    if SCRIPT == "airball" then return p == "freeze" or p == "walk" or p == "iceball" or p == "back" end
    if SCRIPT == "jump" then return p == "freeze" or p == "walk" or p == "jumpkick" or p == "back" end
    return true
end

local function script(r, name)
    if SCRIPT == "idle" then return false end
    if SCRIPT == "fwdonly" then return name == "P1 Right" and r >= 40 and r < 110 end
    if SCRIPT == "backonly" then return name == "P1 Left" and r >= 40 and r < 110 end
    -- 0..22    : ground freeze  D,B+LK
    if phase_on("freeze") then
        if r < 7 then return name == "P1 Down" end
        if r < 22 then return name == "P1 Left" or (r >= 13 and name == "P1 Low Kick") end
    end
    -- 40..110  : walk in
    if phase_on("walk") and r >= 40 and r < 110 then return name == "P1 Right" end
    -- 110..185 : normals - high punch, low kick, sweep, uppercut
    if phase_on("normals") then
        if r >= 110 and r < 122 then return name == "P1 High Punch" end
        if r >= 126 and r < 138 then return name == "P1 Low Kick" end
        if r >= 145 and r < 160 then return name == "P1 Down" or name == "P1 Low Kick" end
        if r >= 170 and r < 185 then return name == "P1 Down" or name == "P1 High Punch" end
    end
    -- 195..216 : ice ball  D,F+LP
    if phase_on("iceball") then
        if r >= 195 and r < 202 then return name == "P1 Down" end
        if r >= 202 and r < 216 then return name == "P1 Right" or (r >= 208 and name == "P1 Low Punch") end
    end
    -- 225..245 : jump kick
    if phase_on("jumpkick") then
        if r >= 225 and r < 235 then return name == "P1 Up" or name == "P1 Right" end
        if r >= 235 and r < 245 then return name == "P1 High Kick" end
    end
    -- 255..285 : back off
    if phase_on("back") and r >= 255 and r < 285 then return name == "P1 Left" end
    return false
end

local function pressed(name)
    if fighting_frame == 0 then
        if name == "UI Select" then return frame >= 5 and frame < 35 end
        if charsel_frame == 0 then
            if name == "Coin 1" then return frame >= 200 and frame < 980 and (frame % 80) < 20 end
            if name == "1 Player Start" then return (not P2HUMAN) and frame >= 1000 and frame < 1080 end
            if name == "2 Players Start" then return P2HUMAN and frame >= 1000 and frame < 1080 end
            return false
        end
        if p1_confirm > 0 then
            if name == "P1 High Punch" then return frame >= p1_confirm and frame < p1_confirm + 45 end
            if name == "P2 High Punch" then return P2HUMAN and frame >= p1_confirm and frame < p1_confirm + 45 end
        end
        return false
    end
    local rel = frame - fighting_frame
    if rel < 120 then return false end
    return script((rel - 120) % 300, name)
end

-- ---------------------------------------------------------------- main
emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("=== %s === p1=%d p2=%d stage=%d p2human=%s script=%s observe=%d",
            LABEL, P1CH, P2CH, STAGE, tostring(P2HUMAN), SCRIPT, OBSERVE)
        if TRACE then dbg_run() end
    end
    if TRACE and not dbg_started then dbg_run() end
    if not space then return end

    -- hard-hang detector: a wedged game parks the PC (ermac's `jauc $`, or the
    -- illegal-opcode trap spin) at one address forever.
    local pc = cpu_pc()
    if pc then
        if pc == last_pc then
            pc_same = pc_same + 1
            if pc_same == 2 and fighting_frame > 0 then
                dump_regs(string.format("pc_frozen@%08x", pc))
                if TRACE then dbg_history(string.format("pc_frozen@%08x", pc)) end
            end
            if pc_same == HANG_FRAMES then
                record("HARD_HANG", string.format("pc=0x%08x stuck %d frames", pc, pc_same))
            end
        else last_pc, pc_same = pc, 0 end
    end

    -- rolling per-frame trace for hang attribution (stop once wedged)
    if fighting_frame > 0 and pc_same < 3 then
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        local p1p, p2p = r32(A.p1_proc), r32(A.p2_proc)
        if p1o ~= 0 and p2o ~= 0 and p1p ~= 0 and p2p ~= 0 then
            hist_push(string.format(
                "f=%d cyc=%3d pc=0x%08x p1act=0x%04x p2act=0x%04x x1=%d x2=%d y1=%d y2=%d wx=%d",
                frame, (frame - fighting_frame - 120) % 300, pc or 0,
                r16(p1p + P_ACTION), r16(p2p + P_ACTION),
                s16(r16(p1o + O_OXPOS)), s16(r16(p2o + O_OXPOS)),
                s16(r16(p1o + O_OYPOS)), s16(r16(p2o + O_OYPOS)),
                s16(r32(A.worldtlx) >> 16)))
        end
    end

    local gs = r16(A.gstate)
    if gs ~= last_gs then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame; log("fight_start frame=%d", frame); snap("fight_start")
        end
        last_gs = gs
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        force_matchup()
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        -- hold the round open: full bars, no winner, frozen clock
        if not NOPOKE then
            w16(A.p1_bar, MAX_HP); w16(A.p2_bar, MAX_HP)
            if A.winner_status ~= 0 then w16(A.winner_status, 0) end
            if FREEZE_CLOCK and A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
        end

        local cb = r16(A.curback)
        if not NOPOKE and cb ~= STAGE and stage_ok then
            stage_ok = false
            log("NOTE: curback drifted to %d at rel=%d - detectors now off", cb, rel)
        end

        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        local p1p, p2p = r32(A.p1_proc), r32(A.p2_proc)
        local live = stage_ok and gs == GS_FIGHTING and p1o ~= 0 and p2o ~= 0 and p2p ~= 0

        if live then
            local x1 = s16(r16(p1o + O_OXPOS))
            local x2 = s16(r16(p2o + O_OXPOS))
            local wx = s16(r32(A.worldtlx) >> 16)
            local le, re = s16(r16(A.left_edge)), s16(r16(A.right_edge))
            local ip = ice_proc()

            if ip and ice_live_since == 0 then
                ice_live_since = frame; casts = casts + 1
                if casts <= 6 or casts % 10 == 0 then
                    log("cast #%d frame=%d x1=%d x2=%d wx=%d", casts, frame, x1, x2, wx)
                end
            elseif not ip and ice_live_since ~= 0 then
                ice_live_since = 0
            end

            -- P1 responsiveness (inputs are driven every frame from rel>=120)
            if p1p ~= 0 then
                local a = r16(p1p + P_ACTION)
                if a ~= p1_act_last then p1_act_last, p1_act_changed = a, frame end
                if rel > 300 and frame - p1_act_changed > 500 then
                    record("P1_UNRESPONSIVE", string.format(
                        "p1 p_action stuck at 0x%04x for %d frames", a, frame - p1_act_changed))
                end
            end

            local act = r16(p2p + P_ACTION)
            if act == ACT_SLIPPING then
                if slip_start == 0 then
                    slip_start = frame; slips = slips + 1
                    log("SLIP #%d start frame=%d x2=%d wx=%d screen_x=%d pa10=%d pa11=%d store8=%d",
                        slips, frame, x2, wx, x2 - wx,
                        s16(r32(p2p + PA10) & 0xffff), s16(r32(p2p + PA11) & 0xffff),
                        r16(p2p + P_STORE8))
                end
                local t = frame - slip_start
                if frame - slip_logged >= 40 then
                    slip_logged = frame
                    log("  slip t=%3d x2=%4d wx=%4d screen_x=%4d store8=%3d pa10=%d pa11=%d",
                        t, x2, wx, x2 - wx, r16(p2p + P_STORE8),
                        s16(r32(p2p + PA10) & 0xffff), s16(r32(p2p + PA11) & 0xffff))
                end
                if t > SLIP_BUDGET then
                    record("SLIP_STUCK", string.format(
                        "act_slipping held %d frames (budget %d) x2=%d wx=%d screen_x=%d",
                        t, SLIP_BUDGET, x2, wx, x2 - wx))
                end
                local sx = x2 - wx
                if sx < -60 or sx > SCRRGT + 60 then
                    record("OFFSCREEN", string.format(
                        "victim screen_x=%d (world %d, camera %d)", sx, x2, wx))
                end
            elseif slip_start > 0 then
                log("SLIP #%d end frame=%d after %d frames (act 0x%04x)",
                    slips, frame, frame - slip_start, act)
                slip_start = 0
            end

            if ice_live_since ~= 0 and frame - ice_live_since > 900 then
                record("ICE_STUCK", string.format("floor-ice proc alive %d frames", frame - ice_live_since))
            end
            if wx < le - 12 or wx > re + 12 then
                record("SCOPE", string.format("worldtlx=%d bounds=[%d,%d]", wx, le, re))
            end
            if rel % 600 == 0 then
                log("  rel=%d x1=%d x2=%d wx=%d bounds=[%d,%d] casts=%d slips=%d p2act=0x%04x",
                    rel, x1, x2, wx, le, re, casts, slips, act)
            end
        end

        if rel >= OBSERVE and not finished then
            finished = true
            local n = 0; for _ in pairs(anomalies) do n = n + 1 end
            if casts == 0 then
                log("INCONCLUSIVE: floor ice never spawned")
            elseif n == 0 then
                log("PASS: %d frames, %d casts, %d slips, no lock-up", OBSERVE, casts, slips)
            else
                local list = {}; for k in pairs(anomalies) do list[#list + 1] = k end
                table.sort(list)
                log("FAIL: %d anomalies [%s] (casts=%d slips=%d)", n, table.concat(list, ","), casts, slips)
            end
            snap("end"); log("test_done"); manager.machine:exit()
        end
    end

    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end

    if fighting_frame == 0 and frame > 6000 then
        log("FAIL: never_reached_fight"); log("test_done"); manager.machine:exit()
    end
    if frame > 40000 then log("FAIL: global_timeout"); log("test_done"); manager.machine:exit() end
end)

emu.register_stop(function() if logfh then logfh:flush(); logfh:close() end end)
