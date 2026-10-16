-- hud_stall_probe.lua - the display pass stops advancing partway through
-- character select.  Find out WHERE: watch geo_ran (incremented once per
-- display pass) and, the moment it stops moving, sample the CPU PC every
-- frame so the hang can be resolved to a symbol.
--
-- The prime suspect is hud_pass's drain spin: it waits with interrupts ON for
-- dma_interupt to clear its own enable bit, and if that condition can ever be
-- false forever the machine wedges with interrupts on and no watchdog.
local LOGP = "C:/Users/you/Workplace/mk2-main/tools/hud_stall_probe.log"
local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = string.format(fmt, ...)
    print("[stall] " .. line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local function sym(n) return symbols[n] or 0 end

-- nearest symbol at or below a PC, so a raw address becomes "routine+delta"
local sorted = {}
for n, a in pairs(symbols) do
    if a >= 0xff800000 then sorted[#sorted+1] = { a = a, n = n } end
end
table.sort(sorted, function(x, y) return x.a < y.a end)
local function nearest(pc)
    local lo, hi, best = 1, #sorted, nil
    while lo <= hi do
        local mid = (lo + hi) // 2
        if sorted[mid].a <= pc then best = sorted[mid]; lo = mid + 1 else hi = mid - 1 end
    end
    if not best then return "?" end
    return string.format("%s+0x%x", best.n, pc - best.a)
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    geo_ran = sym("geo_ran"), hud_ran = sym("hud_ran"), hud_drew = sym("hud_drew"),
    hud_count = sym("hud_count"), geo_count = sym("geo_count"),
    f_doscore = sym("f_doscore"),
}

local frame, space, cpu = 0, nil, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local last_ran, last_move, samples, dumped = -1, 0, {}, false
local fields = {}

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 60
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        local want = { ["Coin 1"]=true, ["2 Players Start"]=true, ["P1 High Punch"]=true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if want[f.name] then fields[f.name] = f end
            end
        end
        log("watching geo_ran=%08x", A.geo_ran)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = space:read_u16(A.gstate)
    if gs == 4 and charsel_frame == 0 then charsel_frame = frame; log("charsel at frame %d", frame) end
    if charsel_frame > 0 and fighting_frame == 0 then
        space:write_u16(A.p1_state, 1); space:write_u16(A.p2_state, 1)
        space:write_u16(A.p1_char, 1);  space:write_u16(A.p2_char, 1)
        space:write_u16(A.curback, 0)
        if A.map_position ~= 0 then space:write_u16(A.map_position, 0) end
        if A.battle_num ~= 0 then space:write_u16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == 2 and fighting_frame == 0 then fighting_frame = frame; log("fighting at frame %d", frame) end

    local ran = space:read_u16(A.geo_ran)
    if ran ~= last_ran then
        last_ran = ran
        last_move = frame
    elseif frame - last_move == 60 and not dumped then
        log("STALL: geo_ran stuck at %d since frame %d (now %d)", ran, last_move, frame)
        log("  gstate=%d f_doscore=%d hud_count=%d geo_count=%d hud_ran=%d hud_drew=%d",
            gs, space:read_u16(A.f_doscore), space:read_u16(A.hud_count),
            space:read_u16(A.geo_count), space:read_u16(A.hud_ran),
            space:read_u16(A.hud_drew))
    elseif frame - last_move > 60 and frame - last_move <= 260 and not dumped then
        local pc = cpu.state["PC"].value
        samples[#samples+1] = pc
        if frame - last_move == 260 then
            dumped = true
            local hist = {}
            for _, p in ipairs(samples) do
                local k = nearest(p)
                hist[k] = (hist[k] or 0) + 1
            end
            log("  PC histogram over %d samples:", #samples)
            for k, v in pairs(hist) do log("    %-40s %d", k, v) end
            manager.machine:exit()
        end
    end

    if frame > 8000 then log("no stall seen"); manager.machine:exit() end
end)
