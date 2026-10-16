-- attract_drift_probe.lua
--
-- READ ONLY.  Watches attract-mode demo fights for the "fighters drift off
-- into the abyss" report and writes NOTHING to the machine, so whatever it
-- sees is the ROM's own behaviour rather than a harness artifact.  That
-- distinction is the whole point: kahn_spar.lua force-writes curback /
-- map_position / p2_char, and the first question about any attract bug is
-- whether those writes caused it.
--
-- Reports a fighter whose world x leaves [left_edge, right_edge], and the
-- camera leaving its own bounds, once per episode rather than per frame.

local frame, cpu, space = 0, nil, nil
local ROOT = (os.getenv("KAHN_SPAR_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local out = io.open(ROOT .. "/tools/kahn_spar_logs/attract_drift.log", "w")
local function ev(fmt, ...)
    local s = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    print("[attract] " .. s)
    if out then out:write(s, "\n"); out:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    left_edge = sym("left_edge"), right_edge = sym("right_edge"),
    worldtlx = sym("worldtlx"), worldtly = sym("worldtly"),
}
local OXVAL = 0x080
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function s16(a) local v = r16(a); if v >= 0x8000 then v = v - 0x10000 end return v end
local function wx(o) if o == 0 then return -1 end return r32(o + OXVAL) >> 16 end

local last_gs, drift_open, reported = -1, false, 0

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        local miss = {}
        for k, v in pairs(A) do if v == 0 then miss[#miss+1] = k end end
        if #miss > 0 then ev("FATAL missing symbols: %s", table.concat(miss, ",")) end
        ev("read-only attract probe: NOTHING is written to the machine")
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gs then
        ev("%7d  gstate %d -> %d   back=%d  chars=%d/%d", frame, last_gs, gs,
            r16(A.curback), r16(A.p1_char), r16(A.p2_char))
        last_gs = gs
        drift_open = false
    end

    if frame % 4 ~= 0 then return end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 then return end
    local lo, hi = s16(A.left_edge), s16(A.right_edge)
    if hi <= lo then return end
    local x1, x2 = wx(p1o), wx(p2o)
    local off1 = (x1 < lo - 8) or (x1 > hi + 8)
    local off2 = (x2 < lo - 8) or (x2 > hi + 8)
    if (off1 or off2) and not drift_open and reported < 12 then
        drift_open, reported = true, reported + 1
        ev("%7d  !! OFF SCREEN  gstate=%d back=%d  p1x=%d p2x=%d  edges=%d..%d  cam_x=%d cam_y=%d",
            frame, gs, r16(A.curback), x1, x2, lo, hi,
            A.worldtlx ~= 0 and s16(A.worldtlx + 16) or -1,
            A.worldtly ~= 0 and s16(A.worldtly + 16) or -1)
    elseif not (off1 or off2) then
        drift_open = false
    end
end)

emu.register_stop(function()
    ev("probe end at frame %d, %d drift episodes seen", frame, reported)
end)
