-- hitbox_list_probe.lua - is the deferred box list being WRITTEN, or being
-- READ wrong?
--
-- The green hurt boxes (computed inside box_pass) draw; the red strike box
-- and the white compared box (parked by strike_check via box_add) do not.
-- Those two differ only in going through bx_list, so this reads bx_list and
-- bx_wr straight out of RAM while P1 throws punches.
--
-- bx_list is file-local to MKDISP.ASM, so its address is derived from the
-- two globals that bracket it in .bss: geo_lastxy (32 bits) ends the geo
-- block and hud_count starts the hud block, with exactly
-- BX_MAX*128 + 16 + 4*16 = 1104 bits in between.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = ROOT .. "/tools/hitbox_list_probe.log"
local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print("[list] " .. line)
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
local function sym(n) return symbols[n] or 0 end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"), p1_proc = sym("p1_proc"),
    f_colbox = sym("f_colbox"), tick = sym("tick"),
    geo_lastxy = sym("geo_lastxy"), hud_count = sym("hud_count"),
    worldtlx = sym("worldtlx"), worldtly = sym("worldtly"),
}
local BX_LIST = A.geo_lastxy + 32
local BX_MAX, BX_REC = 8, 128
local BX_WR = BX_LIST + BX_MAX * BX_REC

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local fields = {}
local attack_start, dumps = 0, 0
local ever_stamped = false

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1200 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 300 and frame < 1200 and (frame % 60) >= 30 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 60
    end
    if attack_start > 0 then
        local rel = (frame - attack_start) % 40
        return name == "P1 High Punch" and rel >= 2 and rel < 10
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"]=true, ["2 Players Start"]=true, ["P1 High Punch"]=true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if want[f.name] then fields[f.name] = f end
            end
        end
        log("geo_lastxy=%08x hud_count=%08x -> bx_list=%08x bx_wr=%08x (gap=%d bits, expect 1104)",
            A.geo_lastxy, A.hud_count, BX_LIST, BX_WR, A.hud_count - (A.geo_lastxy + 32))
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = space:read_u16(A.gstate)
    if gs == 4 and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        space:write_u16(A.p1_state, 1); space:write_u16(A.p2_state, 1)
        space:write_u16(A.p1_char, 1);  space:write_u16(A.p2_char, 1)
        space:write_u16(A.curback, 5)
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == 2 and fighting_frame == 0 then fighting_frame = frame end
    if fighting_frame == 0 then
        if frame > 8000 then log("ERROR never reached fight"); manager.machine:exit() end
        return
    end

    if space:read_u16(A.f_colbox) ~= 15 then space:write_u16(A.f_colbox, 15) end

    if attack_start == 0 and frame - fighting_frame > 120 then
        -- walk into range first
        local p1o, p2o = space:read_u32(A.p1_obj), space:read_u32(A.p2_obj)
        if p1o ~= 0 and p2o ~= 0 then
            local p2x = s16(space:read_u16(p2o + 0x090))
            space:write_u32(p1o + 0x080, ((p2x - 95) << 16) & 0xffffffff)
            space:write_u16(p1o + 0x090, p2x - 95)
            attack_start = frame
            log("attacking; tick=%d", space:read_u16(A.tick))
        end
    end

    if attack_start > 0 and dumps < 40 then
        local tick = space:read_u16(A.tick)
        local parts = {}
        local any = false
        for i = 0, BX_MAX - 1 do
            local base = BX_LIST + i * BX_REC
            local st = space:read_u16(base + 80)
            if st ~= 0 then
                any = true
                ever_stamped = true
                parts[#parts+1] = string.format("s%d[%d,%d..%d,%d c=%02x st=%d age=%d]",
                    i, s16(space:read_u16(base)), s16(space:read_u16(base + 16)),
                    s16(space:read_u16(base + 32)), s16(space:read_u16(base + 48)),
                    space:read_u16(base + 64), st, (tick - st) & 0xffff)
            end
        end
        if any then
            local p = space:read_u32(A.p1_proc)
            log("tick=%d wr=%d act=%04x | %s", tick, space:read_u16(BX_WR),
                p ~= 0 and space:read_u16(p + 0x1f0) or 0xffff, table.concat(parts, " "))
            dumps = dumps + 1
        end
    end

    if attack_start > 0 and frame - attack_start > 400 then
        log("RESULT ever_stamped=%s dumps=%d bx_wr=%d",
            tostring(ever_stamped), dumps, space:read_u16(BX_WR))
        manager.machine:exit()
    end
    if frame > 20000 then manager.machine:exit() end
end)
