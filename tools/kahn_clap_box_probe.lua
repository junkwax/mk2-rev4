-- kahn_clap_box_probe.lua
--
-- Does the sonic clap's strike box actually sit on the wave art?
--
-- Not an opinion and not a screenshot squint: strike_check (JOY.ASM) builds a
-- real object for the box it is about to test whenever f_colbox is set - it
-- kills the previous one, sizes a new one from the stk record and puts it on
-- display list 2.  So the green rectangle on screen IS the box being tested,
-- and its oxpos/osizex are the numbers to compare against the wave's own.
--
-- The wave is a SINGLE PART object, so its oxpos/oypos are the drawn art's
-- top-left corner (MKDISP's no_multi path) and the art occupies
-- [oxpos, oxpos+osizex] x [oypos, oypos+osizey].  Per tick this logs both
-- rectangles and the margin on each edge, so "covers the art" and "does not
-- reach past it" are measurable per animation frame.
--
-- MK2_BOX_GAP=<px>  where to stand P1 (default 300 - far enough that the wave
--                   sweeps its whole life without connecting and cutting the
--                   measurement short)
-- MK2_BOX_LOG / MK2_BOX_ROOT / MK2_BOX_SNAP

local frame = 0
local ROOT = (os.getenv("MK2_BOX_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("MK2_BOX_LOG") or (ROOT .. "/tools/kahn_clap_box_probe.log")
local START_GAP = tonumber(os.getenv("MK2_BOX_GAP") or "300") or 300
local SNAP_ON = os.getenv("MK2_BOX_SNAP") ~= "0"

local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n") logfh:flush() end
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
local missing = {}
local function sym(n)
    local v = symbols[n]
    if not v then missing[#missing + 1] = n return 0 end
    return v
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    map_position = sym("map_position"), battle_num = sym("battle_num"),
    debug2 = sym("debug2"), debug3 = sym("debug3"), debug4 = sym("debug4"),
    objlst = sym("objlst"), objlst2 = sym("objlst2"),
    f_colbox = sym("f_colbox"),
}

local O = { next = 0, oxpos = 0x090, oypos = 0x0b0, osizex = 0x120,
            osizey = 0x130, oid = 0x1c0, ochar = 0x1f0 }
local OID_CBOX, PUPPET_MAGIC, CLAP_CODE = 0x0800, 0x50ad, 3
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KANG, FT_KAHN, KAHN_ARENA, MAX_HP = 1, 13, 8, 0x0a1

local space, fields = nil, {}
local last_gstate, charsel_frame, fighting_frame = -1, 0, 0
local p1_confirm, did_select, kahn_pin_x = 0, false, nil
local armed_frame, request_frame, done_frame, snaps = 0, 0, 0, 0
local rows, seen_key = {}, {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff if v >= 0x8000 then return v - 0x10000 end return v end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end
local function snap()
    if not SNAP_ON then return end
    local s = main_screen()
    if s then pcall(function() s:snapshot() end) end
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end
local function pressed(name)
    if fighting_frame > 0 then return false end
    if charsel_frame > 0 then
        if name == "P1 High Punch" and p1_confirm > 0 then
            return frame >= p1_confirm and frame < p1_confirm + 45
        end
        return false
    end
    if name == "Coin 1" then return frame >= 700 and frame < 980 and (frame % 80) < 20 end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    return false
end

-- The wave is the object carrying Kahn's ochar that is not a fighter; the box
-- is the one strike_check just built, on list 2 under oid_cbox.
local function find_objs(p1o, p2o)
    local wave, box
    for _, head in ipairs({ A.objlst, A.objlst2 }) do
        local p, n = r32(head), 0
        while p ~= 0 and n < 300 do
            local oid = r16(p + O.oid)
            if oid == OID_CBOX then box = p
            elseif p ~= p1o and p ~= p2o and r16(p + O.ochar) == FT_KAHN then wave = p end
            p = r32(p + O.next) n = n + 1
        end
    end
    return wave, box
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        print("[box] kahn_clap_box_probe - strike box vs wave art")
        print(string.format("[box] gap=%d  log=%s", START_GAP, LOG_PATH))
        if #missing > 0 then
            print("[box] ERROR unresolved symbols: " .. table.concat(missing, ","))
            manager.machine:exit() return
        end
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then fighting_frame = frame end
        last_gstate = gs
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1) w16(A.p2_state, 0)
        w16(A.p1_char, FT_KANG) w16(A.p2_char, FT_KAHN)
        w16(A.curback, KAHN_ARENA)
        w16(A.map_position, 14) w16(A.battle_num, 15)
        w16(A.debug2, PUPPET_MAGIC)
        if not did_select then did_select = true print("[box] direct_select") end
        if gs == GS_PSEL and p1_confirm == 0 and frame - charsel_frame > 90 then
            p1_confirm = frame
        end
    end

    if fighting_frame > 0 and gs == GS_FIGHTING and done_frame == 0 then
        w16(A.p1_bar, MAX_HP) w16(A.p1_bar_view, MAX_HP)
        w16(A.p2_bar, MAX_HP) w16(A.p2_bar_view, MAX_HP)
        w16(A.debug2, PUPPET_MAGIC)
        w16(A.f_colbox, 1)                     -- draw every box being tested

        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if p1o ~= 0 and p2o ~= 0 then
            if kahn_pin_x == nil and frame - fighting_frame > 30 then
                kahn_pin_x = s16(r16(p2o + O.oxpos))
                print("[box] pin_kahn x=" .. kahn_pin_x)
            end
            if kahn_pin_x then
                w32(p2o + 0x080, kahn_pin_x << 16) w16(p2o + O.oxpos, kahn_pin_x)
            end
            if armed_frame == 0 and kahn_pin_x and frame - fighting_frame > 60 then
                armed_frame = frame
                local t = kahn_pin_x - START_GAP
                w32(p1o + 0x080, t << 16) w16(p1o + O.oxpos, t)
                print(string.format("[box] armed p1_x=%d kahn_x=%d gap=%d", t, kahn_pin_x, START_GAP))
            end
            if armed_frame > 0 and request_frame == 0 and frame - armed_frame > 40 then
                request_frame = frame
                w16(A.debug4, 0) w16(A.debug3, CLAP_CODE)
                print("[box] clap requested")
            end

            if request_frame > 0 then
                local rel = frame - request_frame
                local wave, box = find_objs(p1o, p2o)
                if wave and box then
                    local wx, wy = s16(r16(wave + O.oxpos)), s16(r16(wave + O.oypos))
                    local wsx, wsy = r16(wave + O.osizex), r16(wave + O.osizey)
                    local bx, by = s16(r16(box + O.oxpos)), s16(r16(box + O.oypos))
                    local bsx, bsy = r16(box + O.osizex), r16(box + O.osizey)
                    -- one row per distinct animation frame (art size changes)
                    local key = string.format("%dx%d", wsx, wsy)
                    if not seen_key[key] then
                        seen_key[key] = true
                        -- A single-part object draws FROM oxpos, and a
                        -- flipped one walks the other way - so the art is
                        -- [oxpos-W, oxpos] when b_fliph is set.  Get this
                        -- wrong and the overhang looks like it is on the
                        -- wrong side of the bar.
                        local fl = (r16(wave + 0x0f0) & 0x10) ~= 0
                        local al = fl and (wx - wsx) or wx
                        local ar = al + wsx
                        -- lead = the edge in the direction of travel
                        local lead = fl and (al - bx) or ((bx + bsx) - ar)
                        local trail = fl and ((bx + bsx) - ar) or (al - bx)
                        rows[#rows + 1] = string.format(
                            "[box] art %2dx%-3d x=[%4d..%4d] y=[%3d..%3d] | box x=[%4d..%4d] y=[%3d..%3d] | covers=%s  lead=%+dpx trail=%+dpx  below=%+dpx",
                            wsx, wsy, al, ar, wy, wy + wsy,
                            bx, bx + bsx, by, by + bsy,
                            (bx <= al and (bx + bsx) >= ar and by <= wy
                             and (by + bsy) >= (wy + wsy)) and "YES" or "no",
                            lead, trail, (by + bsy) - (wy + wsy))
                        print(rows[#rows])
                        if snaps < 12 then snaps = snaps + 1 snap() end
                    end
                end
                if rel > 90 then
                    print(string.format("[box] %d distinct wave frames measured", #rows))
                    print("[box] margin >= 0 on every edge = the box covers the art;")
                    print("[box] a large margin = the box reaches past what you can see.")
                    print("[box] done")
                    done_frame = frame
                end
            end
        end
    end

    if done_frame > 0 and frame - done_frame > 30 then manager.machine:exit() end
    if frame > 4000 then print("[box] ERROR timeout") manager.machine:exit() end
    for n, f in pairs(fields) do if pressed(n) then f:set_value(1) else f:clear_value() end end
end)

emu.register_stop(function()
    if logfh then logfh:flush() logfh:close() logfh = nil end
end)
