-- arena_goro_observe.lua
-- Observation harness for the Kintaro/Goro background arena prop
-- (arena_goro_proc in BGND.ASM). Boots into a Kahn's Arena fight with two
-- NON-boss characters (arena_goro_boss_check excludes the prop when either
-- fighter is ft_final_boss/ft_goro - confirmed correct, not a bug), then
-- forces P1's x position back and forth to drag the camera scroll and
-- trigger the prop's walk-to-center behavior on both sides, logging its
-- own object (found directly via baklst8, the "clear-lane arena prop"
-- list - nothing else uses that list on this stage) each beat.

local LOG_PATH = "C:/Users/you/Workplace/mk2-main/tools/arena_goro_observe.log"
local MAP_PATH = "C:/Users/you/Workplace/mk2-main/src/mk2.map"

local A = {
    gstate = 0x0112a7d0,
    p1_obj = 0x0112a820,
    p2_obj = 0x0112b3f0,
    worldtlx2 = 0x01127410,
    baklst8 = 0x01127470,
    baklst1 = 0x01127460,
    left_edge = 0x01128df0,
    right_edge = 0x01128e00,
}

do
    local wanted = {}
    for name in pairs(A) do wanted[name] = true end
    local fh = io.open(MAP_PATH, "r")
    if fh then
        local found = 0
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x+)%s+([%w_]+)") do
                if wanted[name] then
                    A[name] = tonumber(addr, 16)
                    wanted[name] = nil
                    found = found + 1
                end
            end
        end
        fh:close()
        print(string.format("[ag] mk2.map: resolved %d symbols", found))
        for name in pairs(wanted) do
            print(string.format("[ag] WARNING: %s not in map, using fallback", name))
        end
    end
end

local OBJ = { oxpos = 0x90, oypos = 0xb0, oxval = 0x80, oflags = 0xf0 }

local frame = 0
local logfh = io.open(LOG_PATH, "w")
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, " ")
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local cpu, space
local function rw(a) return space:read_u16(a) end
local function rl(a) return space:read_u32(a) end
local function ww(a, v) space:write_u16(a, v & 0xffff) end
local function wl(a, v) space:write_u32(a, v & 0xffffffff) end
local function i16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function obj_base(ptr_addr)
    local bits = rl(ptr_addr)
    if bits == 0 or bits == 0xffffffff then return nil end
    return bits
end

local function set_p1_x(x)
    local b = obj_base(A.p1_obj)
    if not b then return end
    ww(b + OBJ.oxpos, x & 0xffff)
    wl(b + OBJ.oxval, (x << 16) & 0xffffffff)
end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if not ok or not s then
        ok, s = pcall(function() return manager.machine.screens:at(1) end)
    end
    if s then
        pcall(function() s:snapshot() end)
        log(string.format("[ag] SNAP frame=%d label=%s", frame, label))
    end
end

local last_gorox = nil
local swing_target = nil

local function on_frame()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        log("[ag] harness up")
    end
    if not space then return end

    -- Let the fight settle in, then start swinging P1 between the scroll
    -- limits every ~3 seconds to drag the camera (and thus the prop's
    -- screen-relative position) hard left and hard right repeatedly.
    if frame == 180 then
        log("[ag] beginning camera swing")
    end
    if frame >= 180 and (frame - 180) % 180 == 0 then
        local le = i16(rw(A.left_edge))
        local re = i16(rw(A.right_edge))
        if swing_target == "right" or swing_target == nil then
            set_p1_x(le + 20)
            swing_target = "left"
            log(string.format("[ag] frame=%d swing P1 -> left_edge (%d)", frame, le + 20))
        else
            set_p1_x(re - 20)
            swing_target = "right"
            log(string.format("[ag] frame=%d swing P1 -> right_edge (%d)", frame, re - 20))
        end
        snap(string.format("swing_f%d", frame))
    end

    if frame % 15 == 0 then
        local gorop = obj_base(A.baklst8)
        local wtlx2 = i16(rw(A.worldtlx2 + 16))
        local goro_screen_x = nil
        if gorop then
            local gx = i16(rw(gorop + OBJ.oxpos))
            local gy = i16(rw(gorop + OBJ.oypos))
            local gflags = rw(gorop + OBJ.oflags) & 0xffff
            local screen_x = gx - wtlx2
            goro_screen_x = screen_x
            local delta = last_gorox and (gx - last_gorox) or 0
            log(string.format("[ag] frame=%d goro oxpos=%d screen_x=%d oypos=%d flags=0x%04x delta=%d wtlx2=%d",
                frame, gx, screen_x, gy, gflags, delta, wtlx2))
            last_gorox = gx
        else
            log(string.format("[ag] frame=%d goro object not found in baklst8", frame))
        end

        -- walk baklst1 (Kahn's chair / Kano / Sonya - all inserted via
        -- insobj_v, next-pointer at object offset 0) and log each one's
        -- screen position relative to the same worldtlx2 reference used to
        -- render baklst1 in dlists_arena, so we can see if any of them
        -- visually coincide with Kintaro's current screen_x.
        local ptr = rl(A.baklst1)
        local n = 0
        while ptr ~= 0 and ptr ~= 0xffffffff and n < 8 do
            local ox = i16(rw(ptr + OBJ.oxpos))
            local oy = i16(rw(ptr + OBJ.oypos))
            local sx = ox - wtlx2
            local overlap = ""
            if goro_screen_x and math.abs(sx - goro_screen_x) < 40 then
                overlap = " OVERLAP-WITH-GORO"
            end
            log(string.format("[ag] frame=%d baklst1[%d]=0x%x oxpos=%d screen_x=%d oypos=%d%s",
                frame, n, ptr, ox, sx, oy, overlap))
            ptr = rl(ptr)
            n = n + 1
        end
    end

    if frame > 2200 then
        log("[ag] done")
        if logfh then logfh:close(); logfh = nil end
        manager.machine:exit()
    end
end

emu.register_frame_done(function()
    local ok, err = pcall(on_frame)
    if not ok then
        log("[ag] LUA ERROR: " .. tostring(err))
        if logfh then logfh:flush() end
    end
end)
