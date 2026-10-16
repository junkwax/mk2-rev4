-- mk1pit_rounds_probe.lua
--
-- THE PIT (MK1), curback 01Ah, across ROUNDS.  The fatality rig only ever sees
-- round 1; this one plays three rounds (P1, P2, P1 win them, each at 1 HP) and
-- at 90 ticks into every round counts:
--
--   sky    objects on mk1p_sky_lst, and how many are clouds (ozpos 2).  The
--          calla runs once per round and builds the sky from a zeroed head,
--          so every round must show exactly mk1p_sky_objs + the silhouette -
--          more means a second sky process survived the teardown, fewer means
--          the pool could not hold it
--   free   objects on the free list.  Equal every round, or something leaks
--
-- Launch with tools/run_mk1pit_rounds_probe.ps1.  MR_STAGE (hex curback) and
-- MR_SKY_EXPECT retarget it: THE WARRIOR SHRINE (1b) builds the moon alone
-- on the same list, so -Stage 1b -SkyExpect 1.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("MR_TEST_LOG") or (ROOT .. "/tools/mk1pit_rounds_probe.log")

local EQ = {}
do
    local fh = io.open(ROOT .. "/src/MK1PTOPB.ASM", "r")
    if fh then
        for line in fh:lines() do
            local name, val = line:match("^(mk1p_[%w_]+)%s+%.set%s+(%-?%w+)")
            if name then
                local hex = val:match("^0?(%x+)[hH]$")
                EQ[name] = hex and tonumber(hex, 16) or tonumber(val)
            end
        end
        fh:close()
    end
end

local logfh = io.open(LOG_PATH, "w")
local function log(fmt, ...)
    local line = "[rounds] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[name] = tonumber(addr, 16) end
    end
    fh:close()
end
local A = {}
for _, n in ipairs({ "gstate", "p1_state", "p2_state", "p1_char", "p2_char", "p1_obj", "p2_obj",
                     "curback", "p1_bar", "p2_bar", "ofree", "mk1p_sky_lst", "round_num", "worldtlx" }) do
    A[n] = symbols[n] or 0
    if A[n] == 0 then log("WARN missing symbol %s", n) end
end

local GS_PSEL, GS_FIGHTING = 4, 2
local STAGE = tonumber(os.getenv("MR_STAGE") or "", 16) or 0x1a
local FT_KANG, FT_JAX = 1, 11
local SKY_EXPECT = tonumber(os.getenv("MR_SKY_EXPECT") or "") or ((EQ.mk1p_sky_objs or 0) + 1)
local space, fields = nil, {}
local frame, last_gstate = 0, -1
local charsel_frame, confirm_start, round_start, rounds = 0, 0, 0, 0
local measured = {}
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function walk(head, limit)
    local n, obj = 0, r32(head)
    while obj ~= 0 and n < limit do n = n + 1; obj = r32(obj) end
    return n
end
local function clouds()
    local n, obj = 0, r32(A.mk1p_sky_lst)
    local guard = 0
    while obj ~= 0 and guard < 200 do
        if r16(obj + 0x0d0) == 2 then n = n + 1 end
        obj = r32(obj); guard = guard + 1
    end
    return n
end

local function finish(ok, why)
    if finished then return end
    finished = true
    local parts = {}
    for i, m in ipairs(measured) do parts[#parts + 1] = string.format("r%d sky=%d clouds=%d free=%d", i, m.sky, m.clouds, m.free) end
    log("RESULT %s reason=%s stage=%02x expect_sky=%d | %s", ok and "PASS" or "FAIL", why,
        STAGE, SKY_EXPECT, table.concat(parts, " ; "))
    if logfh then logfh:close(); logfh = nil end
    manager.machine:exit()
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then return frame >= 220 and (frame % 80) < 20 end
        if name == "2 Players Start" then return frame >= 260 and (frame % 80) >= 30 and (frame % 80) < 55 end
    end
    if charsel_frame > 0 and round_start == 0 and confirm_start > 0 then
        if name == "P1 High Punch" then return frame >= confirm_start and frame < confirm_start + 40 end
        if name == "P2 High Punch" then return frame >= confirm_start + 80 and frame < confirm_start + 120 end
    end
    if r16(A.gstate) == GS_FIGHTING and round_start > 0 and frame - round_start > 150 then
        local p1_wins = (rounds % 2) == 1
        local t = frame % 20
        if name == "P1 High Punch" then return p1_wins and t < 3 end
        if name == "P2 High Punch" then return (not p1_wins) and t < 3 end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if f.name == "Coin 1" or f.name == "Coin 2" or f.name == "2 Players Start"
                    or f.name == "P1 High Punch" or f.name == "P2 High Punch" then fields[f.name] = f end
            end
        end
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame; confirm_start = frame + 115 end
        if gs == GS_FIGHTING then
            rounds = rounds + 1
            round_start = frame
            log("round %d fight start frame=%d round_num=%d curback=%02x", rounds, frame, r16(A.round_num), r16(A.curback))
        end
        last_gstate = gs
    end
    if round_start == 0 then
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_JAX); w16(A.curback, STAGE)
        w16(A.p1_state, 1); w16(A.p2_state, 1)
    end

    if gs == GS_FIGHTING and round_start > 0 then
        local rel = frame - round_start
        if r16(A.curback) ~= STAGE then finish(false, "wrong_stage"); return end
        if rel == 90 and not measured[rounds] then
            measured[rounds] = { sky = walk(A.mk1p_sky_lst, 400), clouds = clouds(), free = walk(A.ofree, 2000) }
            local m = measured[rounds]
            log("round %d rel 90: sky=%d clouds=%d free=%d", rounds, m.sky, m.clouds, m.free)
            pcall(function() manager.machine.screens[":screen"]:snapshot() end)
            if rounds >= 3 then
                local want = SKY_EXPECT
                local bad = {}
                for i, mm in ipairs(measured) do
                    if mm.sky ~= want then bad[#bad + 1] = string.format("r%d_sky_%d", i, mm.sky) end
                    if mm.free ~= measured[1].free then bad[#bad + 1] = string.format("r%d_free_%d_vs_%d", i, mm.free, measured[1].free) end
                end
                if #bad == 0 then finish(true, "sky_rebuilt_every_round") else finish(false, table.concat(bad, "+")) end
                return
            end
        end
        if rel > 150 then
            -- pin both fighters close so the jabs land, and the round's loser at 1 HP
            local a, v = r32(A.p1_obj), r32(A.p2_obj)
            if a ~= 0 and v ~= 0 then
                local cx = r16(A.worldtlx + 16) + 200
                w16(a + 0x090, cx - 25); w32(a + 0x080, (cx - 25) << 16)
                w16(v + 0x090, cx + 25); w32(v + 0x080, (cx + 25) << 16)
            end
            local loser = ((rounds % 2) == 1) and A.p2_bar or A.p1_bar
            if r16(loser) > 1 then w16(loser, 1) end
            local winner = ((rounds % 2) == 1) and A.p1_bar or A.p2_bar
            w16(winner, 0xa1)
        end
    end

    for name, f in pairs(fields) do f:set_value(pressed(name) and 1 or 0) end
    if frame > 30000 then finish(false, "timeout_after_" .. rounds .. "_rounds") end
end)
