-- sweep_addon_procorder.lua - which fighter's process runs first?
--
-- The P2 side advantage is measured (trades 8-0, throws 88-0, side-swap
-- controlled) but its mechanism was never confirmed. Reading getprc says:
--
--     move *a13,*a0,l   ; link into active list after current process
--     move a0,*a13,l    ; crproc>>new proc
--
-- so a new process is inserted immediately AFTER its creator. setup_players
-- makes P1 first and P2 second, from the same parent - which puts P2 in front
-- of P1 and runs him first every tick.
--
-- This walks the `active` list and reports the order, so the mechanism is
-- observed rather than inferred. Position 1 = runs first.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/procorder.txt"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, active = sym.gstate, sym.active
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[ord] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, done = nil, 0, false

emu.register_frame(function()
    frame = frame + 1
    if done then return end
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        if not active then log("no `active` symbol in mk2.map"); done = true end
        return
    end
    if space:read_u16(gstate) ~= 2 then return end
    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if r1 == 0 or r2 == 0 then return end
    if frame % 120 ~= 0 then return end

    -- walk the active list; the first long of a process is its next pointer
    local node, pos, p1pos, p2pos = space:read_u32(active), 0, nil, nil
    while node ~= 0 and pos < 300 do
        pos = pos + 1
        if node == r1 then p1pos = pos end
        if node == r2 then p2pos = pos end
        node = space:read_u32(node)
    end
    log("active list: %d procs   P1 at #%s   P2 at #%s   -> %s runs first",
        pos, tostring(p1pos), tostring(p2pos),
        (p1pos and p2pos and p1pos < p2pos) and "P1"
        or (p1pos and p2pos) and "P2" or "?")
    done = true
end)

emu.register_stop(function() log("run_end") end)
