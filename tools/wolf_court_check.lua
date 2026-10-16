-- wolf_court_check.lua - THE COURTYARD (MK1, Wolf only, curback 01Dh): does
-- it load, and do the monks animate the way MK1's do?  Plays a 1P game on the
-- Wolf build (rom/wolf/umk3.zip) with curback held at 01Dh through the select
-- and VS screens, then for 600 fight frames reads every monk object's image
-- pointer (mk1c_mk_obj, MK1CRT.ASM) and checks MK1's rule: all fifteen show
-- the SAME frame, it steps every 8 ticks, through all six MK1CYMONK records,
-- in order.  Snapshots at fight +30/+300.  Driven by run_wolf_boot_probe.ps1:
--   -Script wolf_court_check.lua -Env WC_OBJ=<mk1c_mk_obj> WC_CURBACK=<curback>
--   "WC_RECS=1=<sag>,2=<sag>,..." (the SAGs out of src/MK1CYM.TBL)
-- Env WC_NEG=1 expects the monks NOT to move (a control run on a build whose
-- process is disabled) - unused unless you build one.
local LOG = os.getenv("WB_LOG")
local GSTATE = tonumber(os.getenv("WB_GSTATE"), 16)
local OBJ = tonumber(os.getenv("WC_OBJ"), 16)
local CURBACK = tonumber(os.getenv("WC_CURBACK"), 16)
local NOBJ = 15
local OIMG, OXPOS, OYPOS = 0x1a0, 0x090, 0x0b0
local REC = {}                                   -- record's SAG -> frame number (the
                                                 -- MK1CYMONKn labels are not global)
for k, a in string.gmatch(os.getenv("WC_RECS") or "", "(%d+)=(%x+)") do REC[tonumber(a, 16)] = tonumber(k) end

local f = nil
local function log(s)
    if not f then f = io.open(LOG, "w"); f:write("wolf_court_check start\n") end
    f:write(s .. "\n"); f:flush()
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function field(name)
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[name] then return q.fields[name] end end
end
local F = { coin = field("Coin 1"), start = field("1 Player Start"), hp = field("P1 High Punch") }

local frame, started, fight, sel = 0, false, nil, nil
local last, lastchange, steps, seq, bad = nil, nil, {}, {}, 0
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
    local gs = space:read_u16(GSTATE)
    if gs == 4 and not sel then sel = frame; log(("select at %d"):format(frame)) end
    -- two coins + start at 1500, then High Punch to confirm on the select screen
    local k = frame - 1500
    F.coin:set_value(((k >= 0 and k < 6) or (k >= 30 and k < 36)) and 1 or 0)
    F.start:set_value((k >= 120 and k < 126) and 1 or 0)
    F.hp:set_value((sel and frame >= sel + 300 and frame < sel + 306) and 1 or 0)
    if sel and gs ~= 2 and not fight then space:write_u16(CURBACK, 0x1D) end
    if gs == 2 and not fight then
        fight = frame
        log(("fight at %d, curback %02X"):format(frame, space:read_u16(CURBACK)))
    end
    if fight then
        local rel = frame - fight
        if rel == 30 or rel == 300 then manager.machine.video:snapshot() end
        if rel >= 20 and rel <= 620 then
            local imgs, cnt = {}, 0
            for i = 0, NOBJ - 1 do
                local o = space:read_u32(OBJ + 32 * i)
                if o ~= 0 then cnt = cnt + 1; imgs[#imgs + 1] = space:read_u32(space:read_u32(o + OIMG) + 0x40) end
            end
            if rel == 20 then
                for i = 0, NOBJ - 1 do
                    local o = space:read_u32(OBJ + 32 * i)
                    if o ~= 0 then
                        log(("monk %2d obj %08X x %d y %d img %08X"):format(i, o,
                            space:read_u16(o + OXPOS), space:read_u16(o + OYPOS), space:read_u32(o + OIMG)))
                    end
                end
            end
            local same = true
            for j = 2, #imgs do if imgs[j] ~= imgs[1] then same = false end end
            if cnt ~= NOBJ or not same then bad = bad + 1 end
            local cur = imgs[1]
            if cur ~= last then
                -- the first sample is not a change, so it starts no interval
                if last and lastchange then steps[#steps + 1] = frame - lastchange end
                seq[#seq + 1] = REC[cur] or -1
                lastchange = last and frame or nil
                last = cur
            end
        end
        if rel == 621 then
            local tally = {}
            for _, s in ipairs(steps) do tally[s] = (tally[s] or 0) + 1 end
            local t = {}
            for s, n in pairs(tally) do t[#t + 1] = ("%d:%d"):format(s, n) end
            log("steps (frames:count) " .. table.concat(t, " "))
            log("frame sequence " .. table.concat(seq, ",", 1, math.min(#seq, 40)))
            local order = true
            for j = 2, #seq do
                if seq[j] ~= (seq[j - 1] % 6) + 1 then order = false end
            end
            local seen = {}
            for _, v in ipairs(seq) do seen[v] = true end
            local all6 = true
            for v = 1, 6 do if not seen[v] then all6 = false end end
            local only8 = true
            for s in pairs(tally) do if s ~= 8 then only8 = false end end
            log(("objects-out-of-step frames %d, in order %s, all six %s, every 8 %s"):format(
                bad, tostring(order), tostring(all6), tostring(only8)))
            log((bad == 0 and order and all6 and only8 and #steps > 20) and "PASS" or "FAIL")
            f:close(); manager.machine:exit()
        end
    end
    if frame > 9000 then log(("no fight by frame 9000 (gstate %d) - NO VERDICT"):format(gs)); f:close(); manager.machine:exit() end
end)
