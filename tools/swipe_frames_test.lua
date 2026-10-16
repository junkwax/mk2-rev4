-- swipe_frames_test.lua - Baraka's blade swipe (Back+HP), tick by tick.
--
-- The question this answers is NOT "does it hit" - that was fixed a while
-- back by moving the strike window onto UGSWIPE3.  It is "which sprite is on
-- screen for which tick", because that is what two previous attempts at this
-- move got wrong and both were only caught by someone playing it:
--
--   attempt 1  dropped UGSWIPE4    -> "no longer animates all the way through"
--   attempt 2  held UGSWIPE3 4+4   -> "blade stays out there longer than it
--                                      should", follow-through invisible
--
-- Both had a total of 27 ticks and both looked correct on paper.  So this
-- rig reports the RUN LENGTH of every distinct frame, which is the thing the
-- eye is actually reacting to, plus whether the swipe still connects.
--
-- A frame is identified by the SAG of its first multipart piece: distinct
-- art = distinct SAG, and a repeated listing of one frame shows up as a
-- single long run, which is exactly what is being measured.

local REPO = "C:/Users/you/Workplace/mk2-main"
local LOG  = REPO .. "/tools/swipe_frames_test.log"
local logfh = io.open(LOG, "w")
local raw_print = print
print = function(...)
    local p = {}
    for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end
    local line = table.concat(p, "\t")
    raw_print(line); if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local SYM = {}
do
    local fh = io.open(REPO .. "/src/mk2.map", "r")
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_]+)") do
            if SYM[n] == nil then SYM[n] = tonumber(a, 16) end
        end
    end
    fh:close()
end
local function sym(n) local v = SYM[n]; if not v then error("no symbol "..n) end; return v end

local GSTATE = sym("gstate")
local P1_OBJ, P2_OBJ   = sym("p1_obj"), sym("p2_obj")
local P1_PROC          = sym("p1_proc")
local P1_BAR, P2_BAR   = sym("p1_bar"), sym("p2_bar")

local O_OXVAL, O_OXPOS, O_OIMG = 0x080, 0x090, 0x1a0
local P_ACTION = 0x1f0
local ACT_SWIPE = 0x011e

local frame, space = 0, nil
local fields = {}
local fight0, fire_at, done = 0, 0, false
local runs, last_sag, run_len = {}, nil, 0
local bar_before, bar_after = nil, nil
local in_move, idle_after, captured = false, 0, 0

local function cache_fields()
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if f.name == "P1 Left"       then fields.p1left = f end
            if f.name == "P1 Right"      then fields.p1right = f end
            if f.name == "P1 High Punch" then fields.p1hp = f end
        end
    end
    for _, k in ipairs({"p1left","p1right","p1hp"}) do
        print(string.format("[rig] field %-8s %s", k, fields[k] and "ok" or "MISSING"))
    end
end

local function report(why)
    if done then return end
    done = true
    if last_sag and run_len > 0 then runs[#runs+1] = {last_sag, run_len} end
    print("")
    print("[rig] ===== RESULT =====")
    print("[rig] " .. why)
    local total = 0
    for i, r in ipairs(runs) do
        total = total + r[2]
        print(string.format("[rig]   pose %d  sag=0x%08x  %2d ticks", i, r[1], r[2]))
    end
    print(string.format("[rig] total %d ticks", total))
    if bar_before and bar_after then
        print(string.format("[rig] P2 bar %d -> %d  (damage %d)",
            bar_before, bar_after, bar_before - bar_after))
    end
    print("[rig] ==================")
    manager.machine:exit()
end

local function tick()
    frame = frame + 1
    if not space then
        local cpu = manager.machine.devices[":maincpu"]
        if not cpu then return end
        space = cpu.spaces["program"]; cache_fields(); return
    end

    local gs = space:read_u16(GSTATE)
    local o1, o2 = space:read_u32(P1_OBJ), space:read_u32(P2_OBJ)

    if fight0 == 0 then
        if gs ~= 2 or o1 == 0 or o2 == 0 then
            if frame > 2400 then report("never reached a fight") end
            return
        end
        fight0 = frame
        fire_at = frame + 90
        print(string.format("[rig] f=%d FIGHT LIVE", frame))
        return
    end

    -- Walk P1 into range, then swing.  Back+HP: "back" is away from P2, and
    -- P1 starts on the left, so back = P1 Left.
    if frame < fire_at then
        if fields.p1right then fields.p1right:set_value(1) end
        return
    end
    if frame == fire_at then
        if fields.p1right then fields.p1right:clear_value() end
        bar_before = space:read_u16(P2_BAR)
        print(string.format("[rig] f=%d swinging from gap %d", frame,
            space:read_u16(o2 + O_OXPOS) - space:read_u16(o1 + O_OXPOS)))
    end
    -- hold Back for the whole input window, tap HP
    if frame >= fire_at and frame < fire_at + 10 and fields.p1left then
        fields.p1left:set_value(1)
    elseif fields.p1left then fields.p1left:clear_value() end
    if frame == fire_at + 3 and fields.p1hp then fields.p1hp:set_value(1) end
    if frame == fire_at + 6 and fields.p1hp then fields.p1hp:clear_value() end

    local proc = space:read_u32(P1_PROC)
    if proc == 0 then return end
    local act = space:read_u16(proc + P_ACTION)

    -- CAPTURE PAST THE END OF act_swipe.  retract_strike calls act_mframew
    -- with a1 = 0, which parks p_action at 0 for the whole retract - so a
    -- rig that only counts act_swipe ticks measures the WIND-UP and stops
    -- exactly where the follow-through this move is about is supposed to
    -- start.  Capture from act_swipe until he is back in his stance.
    if act == ACT_SWIPE then in_move = true end
    if in_move then captured = captured + 1 end
    if in_move and captured > 40 then report("swipe window captured") end
    if in_move then
        -- oimg is the multipart CHAIN pointer and it is a fixed scratch
        -- buffer, so it never changes.  The frame identity is the first
        -- piece's SAG, one deref in.
        local chain = space:read_u32(o1 + O_OIMG)
        local sag = (chain ~= 0) and space:read_u32(chain) or 0
        print(string.format("[tick] f=%d  act=0x%04x  sag=0x%08x  p2bar=%d",
            frame, act, sag, space:read_u16(P2_BAR)))
        if sag == last_sag then run_len = run_len + 1
        else
            if last_sag then runs[#runs+1] = {last_sag, run_len} end
            last_sag = sag; run_len = 1
        end
        if bar_after == nil then
            local b = space:read_u16(P2_BAR)
            if b ~= bar_before then bar_after = b end
        end
    end

    if frame > fire_at + 400 then report("timed out waiting for the swipe") end
end

emu.register_frame_done(tick)
print("[rig] loaded")
