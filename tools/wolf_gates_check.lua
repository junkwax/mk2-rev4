-- wolf_gates_check.lua - PALACE GATES (MK1, Wolf only, curback 01Eh): do the
-- torch flames and the clouds behave the way MK1's do?  Plays a 1P game on the
-- Wolf build with curback held at 01Eh through select/VS, then for 400 fight
-- frames reads every piece object (mk1g_pc_obj, MK1GATE.ASM):
--   * each piece always shows one of ITS frames, at exactly the world x/y
--     tools/make_mk1gates.py worked out for that frame (MK1's anchor rule);
--   * an animated piece steps every `rate` ticks, to the NEXT frame, and
--     shows all eight;
--   * every cloud piece drifts half a pixel a tick and never sits past
--     screen x wrap+5 (MK1 checks every 8 ticks), and at least one wraps.
-- Then it walks P1 left, snaps, walks right, snaps.  Driven by
-- run_wolf_boot_probe.ps1 -Script wolf_gates_check.lua -Env WG_PC=<mk1g_pc_obj>
-- WG_CL=<mk1g_cl_obj> WG_CURBACK=<curback> WG_TLX8=<worldtlx8> WG_EXPECT=<lua>
local LOG = os.getenv("WB_LOG")
local GSTATE = tonumber(os.getenv("WB_GSTATE"), 16)
local PC = tonumber(os.getenv("WG_PC"), 16)
local CL = tonumber(os.getenv("WG_CL"), 16)
local CURBACK = tonumber(os.getenv("WG_CURBACK"), 16)
local TLX8 = tonumber(os.getenv("WG_TLX8"), 16)
local E = dofile(os.getenv("WG_EXPECT"))
local OIMG, OXPOS, OYPOS, OXVAL = 0x1a0, 0x090, 0x0b0, 0x080

local f = nil
local function log(s)
    if not f then f = io.open(LOG, "w"); f:write("wolf_gates_check start\n") end
    f:write(s .. "\n"); f:flush()
end
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function field(name)
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[name] then return q.fields[name] end end
end
local F = { coin = field("Coin 1"), start = field("1 Player Start"), hp = field("P1 High Punch"),
            left = field("P1 Left"), right = field("P1 Right") }
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local frame, started, fight, sel = 0, false, nil, nil
local bad, checked = 0, 0
local pc_last, pc_since, pc_seen, pc_steps, pc_order = {}, {}, {}, {}, {}
local cl_x0, cl_wraps, cl_over = {}, 0, 0
local function piece_frame(i, sag)
    for k, fr in ipairs(E.pieces[i].frames) do if fr[1] == sag then return k, fr end end
end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start")
    end
    frame = frame + 1
    local gs = space:read_u16(GSTATE)
    if gs == 4 and not sel then sel = frame; log(("select at %d"):format(frame)) end
    local k = frame - 1500
    F.coin:set_value(((k >= 0 and k < 6) or (k >= 30 and k < 36)) and 1 or 0)
    F.start:set_value((k >= 120 and k < 126) and 1 or 0)
    F.hp:set_value((sel and frame >= sel + 300 and frame < sel + 306) and 1 or 0)
    if sel and gs ~= 2 and not fight then space:write_u16(CURBACK, 0x1E) end
    if gs == 2 and not fight then
        fight = frame
        log(("fight at %d, curback %02X"):format(frame, space:read_u16(CURBACK)))
    end
    if not fight then
        if frame > 9000 then log("no fight by frame 9000 - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    local rel = frame - fight
    if rel >= 20 and rel <= 420 then
        for i = 1, #E.pieces do
            local o = space:read_u32(PC + 32 * (i - 1))
            local sag = space:read_u32(space:read_u32(o + OIMG) + 0x40)
            local x, y = s16(space:read_u16(o + OXPOS)), s16(space:read_u16(o + OYPOS))
            local kf, fr = piece_frame(i, sag)
            checked = checked + 1
            if not kf then
                bad = bad + 1
                if bad < 10 then log(("piece %d: SAG %08X is none of its frames"):format(i, sag)) end
            elseif fr[2] ~= x or fr[3] ~= y then
                bad = bad + 1
                if bad < 10 then log(("piece %d frame %d at (%d,%d), want (%d,%d)"):format(i, kf, x, y, fr[2], fr[3])) end
            end
            if kf and kf ~= pc_last[i] then
                pc_seen[i] = pc_seen[i] or {}
                pc_seen[i][kf] = true
                if pc_last[i] then
                    -- the first sample is not a change, so it starts no interval
                    if pc_since[i] then
                        pc_steps[i] = pc_steps[i] or {}
                        pc_steps[i][frame - pc_since[i]] = (pc_steps[i][frame - pc_since[i]] or 0) + 1
                    end
                    local n = #E.pieces[i].frames
                    if kf ~= (pc_last[i] % n) + 1 then pc_order[i] = (pc_order[i] or 0) + 1 end
                    pc_since[i] = frame
                end
                pc_last[i] = kf
            end
        end
        local tlx8 = s16(space:read_u16(TLX8 + 16))
        for j = 1, E.cld_n do
            local o = space:read_u32(CL + 32 * (j - 1))
            local x = s16(space:read_u16(o + OXPOS)) - tlx8
            if x > E.cld_wrap + 5 then cl_over = cl_over + 1 end
            if cl_x0[j] and x < cl_x0[j] - 400 then cl_wraps = cl_wraps + 1 end
            if rel == 20 then log(("cloud %d screen x %d"):format(j, x)) end
            if rel == 120 and j == 1 then log(("cloud 1 moved %d px in 100 ticks"):format(x - cl_x0.start)) end
            if rel == 20 and j == 1 then cl_x0.start = x end
            cl_x0[j] = x
        end
    end
    if rel == 421 then
        local ok = bad == 0 and checked > 0 and cl_over == 0 and cl_wraps > 0
        for i = 1, #E.pieces do
            local n = #E.pieces[i].frames
            local seen, steps = 0, {}
            for _ in pairs(pc_seen[i] or {}) do seen = seen + 1 end
            for s, c in pairs(pc_steps[i] or {}) do steps[#steps + 1] = s .. ":" .. c end
            log(("piece %d (plane %d, ID %d): %d frames seen of %d, steps %s, out of order %d"):format(
                i, E.pieces[i].plane, E.pieces[i].id, seen, n, table.concat(steps, " "), pc_order[i] or 0))
            if n > 1 then
                if seen ~= n or (pc_order[i] or 0) ~= 0 then ok = false end
                for s in pairs(pc_steps[i] or {}) do if s ~= E.rate then ok = false end end
            end
        end
        log(("samples %d, misplaced %d, cloud pieces past wrap+5 %d, cloud wraps %d"):format(
            checked, bad, cl_over, cl_wraps))
        log(ok and "PASS" or "FAIL")
    end
    -- the two ends of the stage, for the eye: walk left, snap, walk right, snap
    if rel > 430 then
        F.left:set_value((rel < 800) and 1 or 0)
        F.right:set_value((rel >= 820 and rel < 1500) and 1 or 0)
        if rel == 790 or rel == 1490 then manager.machine.video:snapshot() end
    end
    if rel == 60 then
        manager.machine.video:snapshot()
        -- WG_DUMP="name=hexaddr,...": every object on those lists, for identifying
        for nm, a in string.gmatch(os.getenv("WG_DUMP") or "", "([%w_]+)=(%x+)") do
            local o, n = space:read_u32(tonumber(a, 16)), 0
            while o ~= 0 and n < 60 do
                log(("DUMP %s obj %08X img %08X x %d y %d z %d"):format(nm, o, space:read_u32(o + OIMG),
                    s16(space:read_u16(o + OXPOS)), s16(space:read_u16(o + OYPOS)), s16(space:read_u16(o + 0x0d0))))
                o = space:read_u32(o); n = n + 1
            end
        end
    end
    if rel > 1500 then f:close(); manager.machine:exit() end
end)
