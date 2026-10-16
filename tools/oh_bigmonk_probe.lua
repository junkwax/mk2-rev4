-- oh_bigmonk_probe.lua
--
-- Outer Haven's two BIG floating monks (make_big_monk / monk_proc, BGND.ASM).
-- They live on baklst4, whose scroll rate is 0, so stock draws them at a
-- fixed screen x for the whole match and they slide across the pillars and
-- the house.  oh_bigmonk_publish now gives them a parallax of their own.
--
-- This parks the fighters at a series of stage positions and, at each stop,
-- reports every monk piece's SCREEN x plus the residual against each
-- background plane.  A residual that holds CONSTANT across the pan is the
-- plane the monks are standing still against; stock holds screen x constant
-- instead, which is the thing being fixed.
--
-- MK2_BIGMONK_SHIFT overrides @oh_bigmonk_shift live (0 = 1:1 .. 15 = off),
-- so one build can sweep every rate.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOG_PATH = os.getenv("BIGMONK_LOG") or (ROOT .. "/tools/oh_bigmonk_probe.log")
local OUTER_HAVEN = 22
-- control runs: 7 is the stock Portal, which shares monk_proc and must stay
-- screen-locked (spread 0) no matter what Outer Haven does.
local STAGE = tonumber(os.getenv("MK2_MONK_STAGE") or tostring(OUTER_HAVEN))
local SHIFT = tonumber(os.getenv("MK2_BIGMONK_SHIFT") or "")

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
end

local missing = {}
local function sym(n) local v = symbols[n]; if not v then missing[#missing + 1] = n end; return v end

local A = {
    baklst4 = sym("baklst4"),
    worldtlx = sym("worldtlx"), worldtlx2 = sym("worldtlx2"),
    worldtlx3 = sym("worldtlx3"), worldtlx4 = sym("worldtlx4"),
    worldtlx5 = sym("worldtlx5"),
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    oh_bigmonk_dx = sym("oh_bigmonk_dx"),
    oh_bigmonk_shift = sym("oh_bigmonk_shift"),
}

local O = { next = 0x000, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0, ozval = 0x0c0,
            osizex = 0x120, oflags2 = 0x160 }
local GS_PSEL, GS_FIGHTING, PS_ACTIVE = 4, 2, 1
local FT_KANG, FT_CAGE = 1, 2

local frame, cpu, space = 0, nil, nil
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, did_select, fields = 0, false, {}
local stop_i, stop_next, done_frame = 0, 0, 0
local rows = {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) if v >= 0x80000000 then return v - 0x100000000 end return v end

local function list_objs(head)
    local out, p, n = {}, r32(head), 0
    while p ~= 0 and n < 40 do out[#out + 1] = p; p = r32(p + O.next); n = n + 1 end
    return out
end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot() end); print("[monk] SNAP " .. label) end
end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true,
                   ["1 Player Start"] = true, ["P1 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function pressed(name)
    if fighting_frame > 0 then return false end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 300 and frame < 560 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 600 and frame < 700 end
    if name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

local function frame_body()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        if #missing > 0 then print("[monk] FAIL unresolved: " .. table.concat(missing, ",")) end
        print(string.format("[monk] loaded; shift override=%s", tostring(SHIFT)))
    end
    if not space or #missing > 0 then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, 0)
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_CAGE); w16(A.curback, STAGE)
        if not did_select then did_select = true; print("[monk] forcing stage " .. STAGE) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if fighting_frame == 0 then
        for n, f in pairs(fields) do if pressed(n) then f:set_value(1) else f:clear_value() end end
        if frame > 3000 then print("[monk] TIMEOUT before fight"); manager.machine:exit() end
        return
    end

    if SHIFT then w16(A.oh_bigmonk_shift, SHIFT) end

    local rel = frame - fighting_frame
    if rel < 80 then return end

    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    if p1 == 0 or p2 == 0 then return end
    if stop_next == 0 then stop_next = frame + 90; print("[monk] panning") end

    local x = -200 + stop_i * 190          -- 9 stops, left wall to right wall
    w32(p1 + O.oxval, (x * 65536) & 0xffffffff)
    w32(p2 + O.oxval, ((x + 60) * 65536) & 0xffffffff)
    if frame < stop_next then return end

    local cam = s32(r32(A.worldtlx)) // 65536
    local w2 = s32(r32(A.worldtlx2)) // 65536
    local w3 = s32(r32(A.worldtlx3)) // 65536
    local w4 = s32(r32(A.worldtlx4)) // 65536
    local w5 = s32(r32(A.worldtlx5)) // 65536

    local big, lil, steps = {}, {}, nil
    for _, q in ipairs(list_objs(A.baklst4)) do
        local z = r32(q + O.ozval)
        local sx = s16(r16(q + O.oxpos)) - w4          -- screen x
        if z == 0 then big[#big + 1] = sx
        elseif z == 2 then lil[#lil + 1] = sx
        else steps = sx end
    end
    table.sort(big); table.sort(lil)

    local dx = s32(r32(A.oh_bigmonk_dx))
    local m = big[1]
    print(string.format(
        "[monk] stop %d  cam=%4d drift=%+5d  dx=%+4d | big screenx %s | lil %s | steps %s",
        stop_i, cam, cam - 418, dx,
        table.concat(big, ","), table.concat(lil, ","), tostring(steps)))
    if m then
        print(string.format(
            "[monk]         residual vs plane1 %+5d  plane2 %+5d  plane3 %+5d  plane5 %+5d  screen %+5d",
            m + cam, m + w2, m + w3, m + w5, m))
        rows[#rows + 1] = { cam = cam, m = m, w2 = w2, w3 = w3, w5 = w5 }
    end
    snap("stop_" .. stop_i)

    stop_i = stop_i + 1
    stop_next = frame + 90
    if stop_i > 9 and done_frame == 0 then
        done_frame = frame
        local function spread(f)
            local lo, hi
            for _, r in ipairs(rows) do
                local v = f(r); lo = math.min(lo or v, v); hi = math.max(hi or v, v)
            end
            return (hi or 0) - (lo or 0)
        end
        print(string.format(
            "[monk] SPREAD  screen %d  vs plane1 %d  plane2 %d  plane3 %d  plane5 %d",
            spread(function(r) return r.m end),
            spread(function(r) return r.m + r.cam end),
            spread(function(r) return r.m + r.w2 end),
            spread(function(r) return r.m + r.w3 end),
            spread(function(r) return r.m + r.w5 end)))
        print("[monk] done")
    end
    if done_frame > 0 and frame - done_frame > 20 then manager.machine:exit() end
end

emu.register_frame_done(function()
    local ok, err = pcall(frame_body)
    if not ok then print("[monk] LUA ERROR " .. tostring(err)) end
end)
