-- raiden_geo_range_probe.lua - do the bolt segments leave the page?
--
-- raiden_jax_deadpool returns NO-VERDICT about 1 run in 3: it logs fight_start,
-- observes a couple of frames, then stops. Nothing else in the sweep does that.
--
-- The suspicion is not the colour map but the CLIP. geo_pass disables
-- CONTROL's window field for the draw - that is the only way a CPU pixel lands
-- at all - and that also removes the hardware's inhibit-writes-outside-window
-- protection. geo_line bounds the LENGTH of a segment (GEO_MAXLEN) but nothing
-- bounds its POSITION, so a bolt emitted while Raiden is near a screen edge
-- PIXTs straight past the end of a scan line into real memory. The box overlay
-- clips in its own producer; the bolt producer does not.
--
-- geo_lastxy is the destination the plotter actually reached on the last
-- segment of the frame, with pageaddr already added - so it is exactly the
-- number that says whether a write left the page.
--
--   page 0 origin = (56,0)    -> valid x 56..455, y 0..253
--   page 1 origin = (56,256)  -> valid x 56..455, y 256..509
--
-- It also watches for the hang itself: geo_ran advances once per display
-- interrupt, so if it stops while MAME keeps running, the machine is wedged
-- and the last state before that is what matters.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = ROOT .. "/tools/raiden_geo_range_probe.log"
local logfh = io.open(LOGP, "w")
local frame = 0
local function log(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    line = string.format("[%06d] %s", frame, line)
    print("[geo] " .. line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    for line in fh:lines() do
        for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[n] = tonumber(a, 16)
        end
    end
    fh:close()
end
local function sym(n)
    if symbols[n] == nil then log("WARN missing symbol %s", n) end
    return symbols[n] or 0
end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    worldtlx = sym("worldtlx"), worldtly = sym("worldtly"),
    pageaddr = sym("pageaddr"),
    geo_count = sym("geo_count"), geo_ran = sym("geo_ran"),
    geo_drew = sym("geo_drew"), geo_lastxy = sym("geo_lastxy"),
    bge_rx = sym("bge_rx"), bge_ry = sym("bge_ry"),
    bolt_flash = sym("bolt_flash"), bolt_tick = sym("bolt_tick"),
    peak_overload = sym("peak_overload"),
}

local FT_RAIDEN, FT_JAX = 7, 11
local frame, space, fields = 0, nil, {}
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local worst = { n = 0 }
local offpage = 0
local last_ran, stalled = -1, 0
local done = false

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1400 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 300 and frame < 1400 and (frame % 60) >= 30 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 60
    end
    return false
end

local function finish(reason)
    if done then return end
    done = true
    log("RESULT %s | offpage_hits=%d worst=%s bolt_flash=%d bolt_tick=%d peak=%d",
        reason, offpage,
        worst.n > 0 and string.format("(%d,%d) page=(%d,%d) raiden=(%d,%d)",
            worst.x, worst.y, worst.px, worst.py, worst.rx, worst.ry) or "none",
        space and space:read_u16(A.bolt_flash) or -1,
        space and space:read_u16(A.bolt_tick) or -1,
        space and space:read_u16(A.peak_overload) or -1)
    if logfh then logfh:flush() end
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if done then return end
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"]=true, ["2 Players Start"]=true, ["P1 High Punch"]=true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if want[f.name] then fields[f.name] = f end
            end
        end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = space:read_u16(A.gstate)
    if gs == 4 and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        space:write_u16(A.p1_state, 1); space:write_u16(A.p2_state, 1)
        space:write_u16(A.p1_char, FT_RAIDEN); space:write_u16(A.p2_char, FT_JAX)
        space:write_u16(A.curback, 0)
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == 2 and fighting_frame == 0 then
        fighting_frame = frame
        log("fight_start")
    end
    if fighting_frame == 0 then
        if frame > 9000 then log("ERROR never reached fight"); finish("no_fight") end
        return
    end

    -- hang detector: geo_ran advances once per display interrupt
    local ran = space:read_u16(A.geo_ran)
    if ran == last_ran then
        stalled = stalled + 1
        if stalled == 45 then
            log("STALL geo_ran frozen at %d for 45 frames - machine is wedged", ran)
            local p1 = space:read_u32(A.p1_obj)
            log("  last geo_lastxy=%08x pageaddr=%08x bge=(%d,%d) count=%d",
                space:read_u32(A.geo_lastxy), space:read_u32(A.pageaddr),
                s16(space:read_u16(A.bge_rx)), s16(space:read_u16(A.bge_ry)),
                space:read_u16(A.geo_count))
            finish("wedged")
            return
        end
    else
        stalled = 0
        last_ran = ran
    end

    local xy = space:read_u32(A.geo_lastxy)
    if xy ~= 0 then
        local x, y = xy & 0xffff, (xy >> 16) & 0xffff
        local page = space:read_u32(A.pageaddr)
        local px, py = page & 0xffff, (page >> 16) & 0xffff
        if x < px or x > px + 399 or y < py or y > py + 253 then
            offpage = offpage + 1
            if offpage <= 12 or offpage % 200 == 0 then
                local p1 = space:read_u32(A.p1_obj)
                log("OFF-PAGE #%d dest=(%d,%d) page=(%d,%d) bge=(%d,%d) raiden_world=(%d,%d) tlx=%d",
                    offpage, x, y, px, py,
                    s16(space:read_u16(A.bge_rx)), s16(space:read_u16(A.bge_ry)),
                    p1 ~= 0 and s16(space:read_u16(p1 + 0x090)) or 0,
                    p1 ~= 0 and s16(space:read_u16(p1 + 0x0b0)) or 0,
                    space:read_u32(A.worldtlx) >> 16)
            end
            if worst.n == 0 or math.abs(x - px) > math.abs(worst.x - worst.px) then
                local p1 = space:read_u32(A.p1_obj)
                worst = { n = 1, x = x, y = y, px = px, py = py,
                          rx = s16(space:read_u16(A.bge_rx)),
                          ry = s16(space:read_u16(A.bge_ry)) }
            end
        end
    end

    if frame - fighting_frame > 1800 then finish("survived") end
    if frame > 20000 then finish("timeout") end
end)
