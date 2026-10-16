-- sweep_addon_jab.lua - validate the SIXTH dispatch shape against the machine.
--
-- joy_hi_punch never calls striker.  Each link of the jab chain is
-- act_mframew (part one, at `psleep` = 3 ticks a row) then one
-- strike_check_a0 then punch_sleep, and punch_sleep runs a strike check on
-- every one of its a10 = 5 ticks.  So the extractor says:
--
--     startup = part-one sleeping rows x 3      active = 1 + 5 = 6
--
-- Nothing writes p_action between act_mframew and the retract, so the move
-- should sit in act_hipunch for EXACTLY startup + active ticks.  For Liu Kang
-- that predicts 9 + 6 = 15.  This measures it.
--
-- The harness zeroes P1's buttons every fight frame (`pressed` only returns
-- the walk directions once fighting), so the tap has to be re-applied here -
-- this addon's callback is registered after the harness's and wins.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/jab_frames.txt"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_proc, p1_obj = sym.gstate, sym.p1_proc, sym.p1_obj
local p1_bar, p2_bar = sym.p1_bar, sym.p2_bar
local P_ACTION, MAX_HP = 0x1f0, 0xA1
local ACT_HIPUNCH, ACT_STANCE = 0x101, 0x303

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[jab] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0 = nil, 0, 0
local field, runs, cur, t0 = nil, {}, nil, nil
local hold = {}
local trace, taps = {}, 0

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if fd.name == "P1 High Punch" then field = fd end
                -- The harness walks P1 left and right all fight to drive the
                -- camera into both clamps.  With the stick away, HP is
                -- back+HP - Liu Kang's BACKFIST (act_lkbackfist, 010ch) - not
                -- the jab, and the first run of this rig measured mostly that.
                if fd.name == "P1 Left"  then hold.l = fd end
                if fd.name == "P1 Right" then hold.r = fd end
            end
        end
        log("=== jab timing === HP field %s", field and "found" or "MISSING")
    end
    if space:read_u16(gstate) ~= 2 then return end
    local r1 = space:read_u32(p1_proc)
    if r1 == 0 then return end
    if fight0 == 0 then fight0 = frame end
    if frame - fight0 < 90 then return end

    -- keep both alive so the round never ends mid-measurement
    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)

    if t0 == nil then t0 = frame; cur = nil end
    local rel = (frame - t0) % 60          -- one tap per 60 ticks
    if hold.l then hold.l:set_value(0) end
    if hold.r then hold.r:set_value(0) end
    if field then field:set_value((rel >= 4 and rel < 7) and 1 or 0) end

    local act = space:read_u16(r1 + P_ACTION)
    -- 6 ticks in act_hipunch is ambiguous: it equals active (1+5) AND it
    -- equals a two-row startup at 3 ticks a row.  Tracing every action for a
    -- whole tap cycle separates them - if startup runs under a DIFFERENT
    -- action there will be a run of it before act_hipunch appears.
    if taps < 3 and rel == 0 then taps = taps + 1 end
    if taps > 0 and taps <= 3 then
        trace[#trace + 1] = string.format("%02d:%04x", rel, act)
    end
    if act == ACT_HIPUNCH then
        cur = (cur or 0) + 1
    elseif cur then
        runs[#runs + 1] = cur
        cur = nil
    end
end)

emu.register_stop(function()
    if #runs == 0 then log("no jabs observed"); return end
    local tally = {}
    for _, v in ipairs(runs) do tally[v] = (tally[v] or 0) + 1 end
    local ks = {}
    for k in pairs(tally) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return tally[a] > tally[b] end)
    local parts = {}
    for _, k in ipairs(ks) do
        parts[#parts + 1] = string.format("%d ticks x%d", k, tally[k])
    end
    log("act_hipunch durations: %s", table.concat(parts, ", "))
    log("n=%d  most common = %d ticks", #runs, ks[1])
    local out, line = {}, {}
    for i, t in ipairs(trace) do
        line[#line + 1] = t
        if #line == 10 or i == #trace then
            out[#out + 1] = table.concat(line, " "); line = {}
        end
    end
    log("action trace (tick:action), HP tapped on ticks 4-6:")
    for _, l in ipairs(out) do log("  " .. l) end
end)
