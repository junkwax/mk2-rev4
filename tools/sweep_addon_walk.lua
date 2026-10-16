-- sweep_addon_walk.lua - measure a fighter's real walk speed, in px/tick.
--
-- Verifies the `secretwalk` fix on the branch it actually adds. Smoke cannot
-- be forced onto P1 (a secret character has no select-grid slot - the harness
-- reports never_reached_fight), and with -P2Human the select never confirms
-- either. So neither obvious route gets a HUMAN Smoke into a fight.
--
-- What does work: the fix reads p2_state on EVERY walk query, so toggling that
-- flag mid-fight switches the branch live. One battle, drone Smoke as P2:
--
--   first half   p2_state left alone (PS_INACTIVE) -> the CPU keeps boss speed
--   second half  p2_state forced to PS_ACTIVE      -> he should walk like a ninja
--
-- P1 is held far away so the drone has to close the distance, because a drone
-- at point blank attacks and never walks at all - the first version of this rig
-- recorded 900 frames of stance and zero walking.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT = ROOT .. "/tools/walk_speed.txt"
local TAG = os.getenv("WALK_TAG") or "run"

local sym = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                sym[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local S = function(n) return sym[n] end
local gstate = S("gstate")
local p1_obj, p2_obj = S("p1_obj"), S("p2_obj")
local p2_proc, p2_state = S("p2_proc"), S("p2_state")
local worldtlx = S("worldtlx")
if not (gstate and p2_obj and p2_state) then print("[walk] symbols missing"); return end

local P_ACTION, OXPOS, OXVAL = 0x1f0, 0x090, 0x080
local ACT_WALKF, ACT_WALKB = 0x0305, 0x0307
local SWITCH_AT = 450          -- frames into the fight

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[walk] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0, vx0 = nil, 0, 0, nil
local prev = nil
local cpu, human, seen, fields = {}, {}, {}, {}
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
    end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2, r2 = space:read_u32(p1_obj), space:read_u32(p2_obj),
                       space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r2 == 0 then return end
    if fight0 == 0 then fight0 = frame; log("=== walk speed (%s) ===", TAG) end
    local rel = frame - fight0
    if rel < 60 then return end

    -- hold P1 far to the left so the drone has to walk to him
    if vx0 == nil then vx0 = s16(space:read_u16(worldtlx + 16)) + 60 end
    space:write_u32(o1 + OXVAL, (vx0 << 16) & 0xffffffff)
    space:write_u16(o1 + OXPOS, vx0)

    -- p2_state = ps_active for the whole fight. Two separate reasons this has
    -- to be forced rather than observed: the drone at any range we can arrange
    -- picks attacks over walking (900 frames of 0303h stance), and in non-
    -- P2Human mode the harness zeroes P2's inputs every frame, so the stick has
    -- to be re-pressed AFTER it - our callback registers last, so it wins.
    if fields.walk == nil and not fields.searched then
        fields.searched = true
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if fd.name == "P2 Left" then fields.walk = fd end
            end
        end
        log("P2 stick field %s", fields.walk and "found" or "NOT FOUND")
    end

    local phase = "human"
    space:write_u16(p2_state, 1)
    if fields.walk then fields.walk:set_value(1) end

    local a = space:read_u16(r2 + P_ACTION)
    seen[a] = (seen[a] or 0) + 1
    local x = s16(space:read_u16(o2 + OXPOS))
    if prev and (a == ACT_WALKF or a == ACT_WALKB) then
        local d = math.abs(x - prev)
        if d > 0 and d < 20 then
            local t = (phase == "human") and human or cpu
            t[#t + 1] = d
        end
    end
    prev = x
end)

emu.register_stop(function()
    local function stat(t, name)
        if #t == 0 then log("%-8s %-6s no samples", TAG, name); return end
        table.sort(t)
        local sum = 0
        for _, v in ipairs(t) do sum = sum + v end
        log("%-8s %-6s n=%-4d mean=%.2f median=%d max=%d px/tick",
            TAG, name, #t, sum / #t, t[math.floor(#t / 2) + 1], t[#t])
    end
    stat(cpu, "CPU")
    stat(human, "HUMAN")
    local l = {}
    for k, v in pairs(seen) do l[#l + 1] = { a = k, n = v } end
    table.sort(l, function(x, y) return x.n > y.n end)
    local parts = {}
    for i = 1, math.min(#l, 6) do
        parts[#parts + 1] = string.format("%04xh:%d", l[i].a, l[i].n)
    end
    log("%-8s actions: %s", TAG, table.concat(parts, " "))
end)
