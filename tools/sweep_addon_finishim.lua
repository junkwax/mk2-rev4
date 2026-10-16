-- sweep_addon_finishim.lua - does the combo string END when the round does?
--
-- MK3's dizzy_dude opens with disable_all_buttons / face_opponent /
-- zero_my_p_hit. MK2's is the same routine without that third line, so the
-- loser walked into FINISH HIM still carrying the hit count from the combo
-- that beat him - and the first hit of the fatality was tallied onto the end
-- of it instead of starting a new string.
--
-- p_hit is the signal the readout uses to tell a new string from a continuing
-- one, so that is what this watches: at the moment the loser enters
-- act_stunned (0400, which dizzy_dude sets), his p_hit must be back to zero.
--
-- Env: FINISHIM_LOG.  Driven by run_finishim_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("FINISHIM_LOG") or (ROOT .. "/tools/finishim.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 High Punch","P1 Low Punch",
    "P1 High Kick","P1 Low Kick","P1 Block",
}) do ADDON_OWNS[n] = true end

local space, fields = nil, {}
local logf = io.open(OUT, "w")
local function log(fmt, ...)
    local s = "[finishim] " .. string.format(fmt, ...)
    print(s)
    if logf then logf:write(s .. "\n"); logf:flush() end
end
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

local P_ACTION, P_HIT = 0x1f0, 0x370
local OXPOS, OXVAL = 0x90, 0x80
local GS_FIGHTING, ACT_STUNNED, MAXHP = 0x02, 0x400, 0xa1
-- Enough that a 2-3 hit string is what finishes him. At 12 a single hit did
-- it, p_hit was already back to 0 by the dizzy, and the check proved nothing.
local KEEP = 46

local t, prev_act, dizzy_t = 0, 0, nil
local peak_hit, hit_at_dizzy, cleared_at = 0, nil, nil
local cases, bad = 0, 0

emu.register_frame(function()
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== FINISH HIM === is the combo string ended, as MK3 ends it?")
    end
    t = t + 1
    if (space:read_u16(sym.gstate) & 0xffff) ~= GS_FIGHTING then return end
    space:write_u16(sym.p1_bar, MAXHP)

    local p2p = space:read_u32(sym.p2_proc)
    if p2p == 0 then return end
    local act = space:read_u16(p2p + P_ACTION) & 0xffff
    local ph  = space:read_u8(p2p + P_HIT) & 0xff
    if ph > peak_hit then peak_hit = ph end

    -- Hold p2 low so a short string finishes the round, and keep p1 in range.
    if not dizzy_t and (space:read_u16(sym.p2_bar) & 0xffff) > KEEP then
        space:write_u16(sym.p2_bar, KEEP)
    end
    local o1, o2 = space:read_u32(sym.p1_obj), space:read_u32(sym.p2_obj)
    if o1 ~= 0 and o2 ~= 0 and not dizzy_t and t % 11 == 0 then
        local x2 = s16(space:read_u16(o2 + OXPOS))
        local x1 = s16(space:read_u16(o1 + OXPOS))
        local tx = (x2 < x1) and (x2 + 44) or (x2 - 44)
        space:write_u32(o1 + OXVAL, (tx & 0xffff) << 16)
    end

    -- NOTE: an attempt to force p_hit non-zero right up to the dizzy - to
    -- exercise the new line under a live string - crashed MAME at the moment
    -- FINISH HIM starts, every time. Writing p_hit continuously through the
    -- round-end sequence is not something the ROM expects, so that is most
    -- likely the rig's fault rather than the ROM's, but it is UNRESOLVED and
    -- worth another look before trusting this rig to prove the fix.
    if act == ACT_STUNNED and prev_act ~= ACT_STUNNED then
        dizzy_t, hit_at_dizzy, cleared_at = t, ph, nil
        cases = cases + 1
        log("case %d: p2 entered act_stunned at frame %d with p_hit=%d"
            .. " (peak this string was %d)", cases, t, ph, peak_hit)
    elseif dizzy_t and not cleared_at then
        if ph == 0 then
            cleared_at = t
            log("   p_hit cleared %d frame(s) into the dizzy", t - dizzy_t)
        elseif t - dizzy_t > 30 then
            cleared_at = -1
            bad = bad + 1
            log("   FAIL: p_hit still %d after 30 frames - the string never"
                .. " ended, so the next hit continues the combo", ph)
        end
    end
    if dizzy_t and t - dizzy_t > 240 then
        dizzy_t, peak_hit = nil, 0        -- rearm for the next round
    end
    prev_act = act

    if t % 240 == 0 then
        log("  t=%d p2act=%04x p2bar=%d p2hit=%d winner=%d dx=%d", t, act,
            space:read_u16(sym.p2_bar) & 0xffff, ph,
            sym.winner_status and (space:read_u16(sym.winner_status) & 0xffff) or -1,
            (o1 ~= 0 and o2 ~= 0)
              and math.abs(s16(space:read_u16(o1 + OXPOS))
                         - s16(space:read_u16(o2 + OXPOS))) or -1)
    end

    -- Three attacks inside 22 ticks, 7 apart: that gap is inside hitstun,
    -- which is what makes a string rather than three separate hits.
    local c = t % 22
    press("P1 High Punch", c == 0 or c == 1)
    press("P1 High Kick",  c == 7 or c == 8)
    press("P1 Low Kick",   c == 14 or c == 15)
end)

emu.register_stop(function()
    log("")
    if cases == 0 then
        log("VERDICT NO-CASE - never reached a FINISH HIM")
    elseif bad > 0 then
        log("VERDICT FAIL - the string survived into FINISH HIM in %d of %d",
            bad, cases)
    else
        log("VERDICT PASS - the string ended at the dizzy in all %d case(s)",
            cases)
    end
    if logf then logf:close() end
end)
