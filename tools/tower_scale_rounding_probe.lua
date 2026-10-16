-- tower_scale_rounding_probe.lua
-- How many rows does the T-Unit DMA actually draw for a given ystep?
--
-- The note in memory says "drawn = source * 0100h / step" and that only 1x
-- and 2x tile without seams, but not whether a reduction FLOORS or CEILS.
-- THE TOWER's wall reflection stacks 4-5 blocks per column at a 1/6 squash
-- and gives each block its own ystep so they tile exactly - which only works
-- if the row count is known to the row. So measure it rather than assume.
--
-- Target: the LOWER tile of a live pillar on baklst4 (48x103, stock flags
-- e082 - no flip of its own). For each step in STEPS it is squashed for
-- HOLD_STEP frames and snapshotted; then the pillar is moved far off the
-- screen and a BARE frame is taken, so the wall behind it is known. Offline,
-- the drawn rows are exactly the rows where the step frame differs from the
-- bare frame down the pillar's centre column - no colour guessing.
--
-- It also counts the free-object list, so the wall reflection's ~83 objects
-- can be priced against what this stage actually leaves free.
--
-- env: MK2_SCALEP_TAG (default "round")

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("MK2_SCALEP_TAG") or "round"
local LOG_PATH = ROOT .. "/tools/tower_scale_rounding_probe_" .. TAG .. ".log"
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
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(n) local v = symbols[n]; if not v then print("[round] FATAL missing " .. n) end; return v end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    baklst4 = sym("baklst4"), worldtlx4 = sym("worldtlx4"), ofree = sym("ofree"),
}
local O = { next = 0x000, oxval = 0x080, oxpos = 0x090, oypos = 0x0b0,
            oflags = 0x0f0, osag = 0x100, osize = 0x120, oscale = 0x180 }
local GS_PSEL, GS_FIGHTING = 4, 2
local TOWER = 3

-- steps chosen so floor and ceil give DIFFERENT answers for a 103-row tile
local STEPS = { 0x100, 0x200, 0x300, 0x4F0, 0x600, 0x700 }
local HOLD, HOLD_STEP = 320, 24

local fields, cpu, space = {}, nil, nil
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, p2_confirm = 0, 0
local target, target_y = nil, nil
local done_frame = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local function cache_fields()
    local want = { ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
        ["1 Player Start"]=true, ["2 Players Start"]=true,
        ["P1 High Punch"]=true, ["P2 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end
local function screen1()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end
local function snap(label)
    local s = screen1(); if s then pcall(function() s:snapshot() end) end
    print(string.format("[round] SNAP %s frame=%d", label, frame))
end

local function pressed(name)
    if fighting_frame > 0 then return false end
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
    if name == "P1 High Punch" and p1_confirm > 0 then return frame >= p1_confirm and frame < p1_confirm + 45 end
    if name == "P2 High Punch" and p2_confirm > 0 then return frame >= p2_confirm and frame < p2_confirm + 45 end
    return false
end

local function free_objects()
    local n, p = 0, r32(A.ofree)
    while p ~= 0 and n < 400 do n = n + 1; p = r32(p + O.next) end
    return n
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[round] loaded, THE TOWER, tag=" .. TAG)
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_char, 1); w16(A.p2_char, 2); w16(A.curback, TOWER)
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_PSEL and p2_confirm == 0 and frame - charsel_frame > 150 then p2_confirm = frame end
    end
    if fighting_frame == 0 then w16(A.curback, TOWER) end

    if fighting_frame > 0 then
        local rel = frame - fighting_frame
        -- park both fighters at the LEFT limit: the left pillar is then
        -- clear of both of them (they stand at x 40, it is at plane 370)
        if rel < HOLD then
            for _, h in ipairs({A.p1_obj, A.p2_obj}) do
                local o = r32(h)
                if o ~= 0 then w32(o + O.oxval, (40 & 0xffff) << 16) end
            end
        end
        if rel == HOLD then
            print(string.format("[round] free objects at fight start + %d: %d", HOLD, free_objects()))
            -- the lower tile of the left pillar: flags e082, the one without
            -- a stock flip
            local p = r32(A.baklst4)
            while p ~= 0 do
                if r16(p + O.oflags) & 0x20 == 0 and s16(r16(p + O.oypos)) > 0 then target = p end
                p = r32(p + O.next)
            end
            if target then
                target_y = r16(target + O.oypos)
                print(string.format("[round] target pillar tile plane(%d,%d) size=%08x worldtlx4=%d",
                    s16(r16(target + O.oxpos)), s16(target_y), r32(target + O.osize),
                    s16(r32(A.worldtlx4) >> 16)))
            else
                print("[round] FATAL no unflipped pillar tile on baklst4")
            end
        end
        if target and rel > HOLD then
            local k = rel - HOLD - 1
            local idx = (k // HOLD_STEP) + 1
            if idx <= #STEPS then
                w32(target + O.oscale, (STEPS[idx] << 16) | 0x0100)
                if k % HOLD_STEP == HOLD_STEP - 1 then
                    snap(string.format("step_%03X", STEPS[idx]))
                end
            elseif idx == #STEPS + 1 then
                w32(target + O.oscale, 0x01000100)
                w16(target + O.oypos, (target_y + 600) & 0xffff)   -- off screen
                if k % HOLD_STEP == HOLD_STEP - 1 then
                    snap("bare")
                    print(string.format("[round] free objects now: %d", free_objects()))
                    done_frame = frame
                    print("[round] finished")
                end
            end
        end
    end

    if done_frame > 0 and frame - done_frame > 10 then manager.machine:exit(); return end
    if frame > 3600 then print("[round] TIMEOUT"); manager.machine:exit(); return end
    for name, f in pairs(fields) do
        if pressed(name) then f:set_value(1) else f:clear_value() end
    end
end)
