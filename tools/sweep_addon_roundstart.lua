-- sweep_addon_roundstart.lua - does one side become actionable first?
--
-- Section 5.3 of doc/TOURNAMENT_READINESS.md. The trade case is already
-- measured (P2 wins simultaneous exchanges, and identically on retail, so it
-- is not ours). Round start is the other half: if one player's input is
-- accepted a tick before the other's, every round opens with a free advantage
-- and no amount of practice closes it.
--
-- Method: hold BOTH sticks toward each other from before the round begins and
-- record the first frame each fighter's oxpos actually moves. Movement is the
-- honest signal - p_action can change while the fighter is still parked, and
-- "the game read my stick" is only real when the character does something.
--
-- Both directions are driven every frame because the harness owns P1's stick
-- during a fight (it walks him to stress the camera) and zeroes P2's unless
-- SWEEP_P2_HUMAN is set; this addon registers last, so its writes win.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = ROOT .. "/tools/roundstart.txt"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_obj, p2_obj = sym.gstate, sym.p1_obj, sym.p2_obj
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local P_ACTION, OXPOS = 0x1f0, 0x090

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[rs] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

local space, frame, fight0 = nil, 0, 0
local f = {}
local base1, base2, mv1, mv2, act1, act2 = nil, nil, nil, nil, nil, nil
local rounds = {}
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
                if fd.name == "P1 Right" then f.p1 = fd end
                if fd.name == "P2 Left"  then f.p2 = fd end
            end
        end
        log("=== round start === P1 %s  P2 %s",
            f.p1 and "ok" or "MISSING", f.p2 and "ok" or "MISSING")
    end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r1 == 0 or r2 == 0 then return end
    if fight0 == 0 then
        fight0 = frame
        base1, base2 = s16(space:read_u16(o1 + OXPOS)),
                       s16(space:read_u16(o2 + OXPOS))
        act1, act2 = space:read_u16(r1 + P_ACTION),
                     space:read_u16(r2 + P_ACTION)
        log("fight starts at frame %d  (p1 act %04xh, p2 act %04xh)",
            frame, act1, act2)
    end
    local rel = frame - fight0

    -- both sticks held toward the opponent, from the very first fight frame
    if f.p1 then f.p1:set_value(1) end
    if f.p2 then f.p2:set_value(1) end

    local x1, x2 = s16(space:read_u16(o1 + OXPOS)), s16(space:read_u16(o2 + OXPOS))
    if mv1 == nil and x1 ~= base1 then mv1 = rel end
    if mv2 == nil and x2 ~= base2 then mv2 = rel end
    if mv1 and mv2 and #rounds == 0 then
        rounds[1] = true
        log("first movement: P1 at rel=%d, P2 at rel=%d  -> %s",
            mv1, mv2,
            (mv1 == mv2) and "SYMMETRIC"
            or string.format("%s moves %d tick(s) first",
                             (mv1 < mv2) and "P1" or "P2", math.abs(mv1 - mv2)))
    end
end)

emu.register_stop(function()
    if mv1 == nil or mv2 == nil then
        log("incomplete: P1 %s  P2 %s",
            mv1 and tostring(mv1) or "never moved",
            mv2 and tostring(mv2) or "never moved")
        return
    end
    log("RESULT p1_first_move=%d p2_first_move=%d delta=%d",
        mv1, mv2, mv1 - mv2)
end)
