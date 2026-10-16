-- walk_testrom.lua - measure a HUMAN secret fighter's walk speed.
--
-- The five earlier attempts all died on the same thing: a secret character has
-- no character-select slot, so the sweep harness reports never_reached_fight,
-- and in a drone battle the harness owns P2's input ports and the drone picks
-- attacks over walking anyway.  The test ROM (test_mode=1) skips select
-- entirely and boots into a fight, so P1 can BE Smoke and is ps_active by
-- definition - which is exactly the branch `secretwalk` adds.
--
-- Holds forward, then back, and reports px/tick from real oxpos deltas.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/walk_speed.txt"
local TAG  = os.getenv("WALK_TAG") or "run"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_obj, p1_proc, p1_state =
    sym.gstate, sym.p1_obj, sym.p1_proc, sym.p1_state
local P_ACTION, OXPOS = 0x1f0, 0x090
local ACT_WALKF, ACT_WALKB = 0x0305, 0x0307

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[walk] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0, prev = nil, 0, 0, nil
local fwd, bwd, seen, want = {}, {}, {}, {}
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if fd.name == "P1 Right" then want.f = fd end
                if fd.name == "P1 Left"  then want.b = fd end
                if fd.name == "UI Select" then want.ui = fd end
                if fd.name == "Coin 1" then want.coin = fd end
                if fd.name == "1 Player Start" then want.start = fd end
            end
        end
        log("=== %s === fields %s/%s", TAG,
            want.f and "R" or "-", want.b and "L" or "-")
    end
    -- Boot sequence, lifted from battle_stability_sweep.lua: MAME's red
    -- "wrong checksums" warning eats every frame until a UI key arrives, which
    -- is why the first run of this rig sat at 29 emulated seconds with gstate
    -- never leaving 0.  Coin+start are harmless in test_mode.
    if want.ui then
        want.ui:set_value((frame >= 5 and frame < 35) and 1 or 0) end
    local gs = space:read_u16(gstate)
    if gs ~= 2 then
        if want.coin then want.coin:set_value(
            (frame >= 200 and frame < 1000 and (frame % 80) < 20) and 1 or 0) end
        if want.start then want.start:set_value(
            (frame >= 1000 and frame < 1080) and 1 or 0) end
        if frame % 600 == 0 then log("%s waiting: gstate=%d frame=%d",
            TAG, gs, frame) end
        return
    end
    local o1, r1 = space:read_u32(p1_obj), space:read_u32(p1_proc)
    if o1 == 0 or r1 == 0 then return end
    if fight0 == 0 then
        fight0 = frame
        log("%s p1_state=%d (1 = ps_active = a human has him)",
            TAG, space:read_u16(p1_state))
    end
    local rel = frame - fight0
    if rel < 90 then return end

    if rel < 500 then
        if want.f then want.f:set_value(1) end
    else
        if want.b then want.b:set_value(1) end
    end

    local a = space:read_u16(r1 + P_ACTION)
    seen[a] = (seen[a] or 0) + 1
    local x = s16(space:read_u16(o1 + OXPOS))
    if prev then
        local d = math.abs(x - prev)
        if d > 0 and d < 20 then
            if a == ACT_WALKF then fwd[#fwd + 1] = d
            elseif a == ACT_WALKB then bwd[#bwd + 1] = d end
        end
    end
    prev = x
end)

emu.register_stop(function()
    local function stat(t, name)
        if #t == 0 then log("%-8s %-9s no samples", TAG, name); return end
        table.sort(t); local s = 0
        for _, v in ipairs(t) do s = s + v end
        log("%-8s %-9s n=%-4d mean=%.3f median=%d px/tick",
            TAG, name, #t, s / #t, t[math.floor(#t / 2) + 1])
    end
    stat(fwd, "forward"); stat(bwd, "backward")
    local l = {}
    for k, v in pairs(seen) do l[#l + 1] = { a = k, n = v } end
    table.sort(l, function(x, y) return x.n > y.n end)
    local p = {}
    for i = 1, math.min(#l, 6) do
        p[#p + 1] = string.format("%04xh:%d", l[i].a, l[i].n) end
    log("%-8s actions: %s", TAG, table.concat(p, " "))
end)
