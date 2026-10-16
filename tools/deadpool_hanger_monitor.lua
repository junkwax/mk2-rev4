-- deadpool_hanger_monitor.lua
--
-- Live monitor for the fixed Dead Pool hanging bodies and their metal art.
-- This is for the stage hangers in MKHANG.ASM, not the retired player-chain
-- experiment. It tracks:
--   hp_body_ptr[slot] body/skeleton object
--   nearest longchain, TINCHAIN4, and TINHOOK objects from objlst/objlst2/objlst3
--
-- Usage:
--   C:\MAME\mame.exe mk2 -debug -debugscript C:\Users\you\Workplace\mk2-main\mame_autoresume.ds -autoboot_script C:\Users\you\Workplace\mk2-main\tools\deadpool_hanger_monitor.lua
--
-- Output:
--   C:/Users/you/Workplace/mk2-main/tmp/dp/hanger_monitor.log

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MAP_PATH = ROOT .. "/src/mk2.map"
local LOG_PATH = ROOT .. "/tmp/dp/hanger_monitor.log"

local NHANGERS = 9
local LOG_EVERY_FRAMES = 30
local DRAW_OVERLAY = true
local OVERLAY_LINES = 12

local logf = io.open(LOG_PATH, "w")
local function log(s)
    print(s)
    if logf then
        logf:write(s .. "\n")
        logf:flush()
    end
end

local function hx(v)
    if v == nil then return "nil" end
    return string.format("0x%08X", v & 0xffffffff)
end

local function i16(v)
    return v >= 0x8000 and v - 0x10000 or v
end

local function map_symbol(name, fallback)
    local f = io.open(MAP_PATH, "r")
    if not f then return fallback end
    for line in f:lines() do
        for addr, sym in line:gmatch("([0-9A-Fa-f]+)%s+([_%w]+)") do
            if sym == name then
                f:close()
                return tonumber(addr, 16)
            end
        end
    end
    f:close()
    return fallback
end

local space
pcall(function()
    space = manager.machine.devices[":maincpu"].spaces["program"]
end)

local function r16(a)
    if not space or not a or a == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u16(a) end)
    return ok and v or 0
end

local function r32(a)
    if not space or not a or a == 0 then return 0 end
    local ok, v = pcall(function() return space:read_u32(a) end)
    return ok and v or 0
end

local A = {
    gstate = map_symbol("gstate", 0x01129DC0),
    curback = map_symbol("curback", 0x0112B6C0),
    winner_status = map_symbol("winner_status", 0x0112B700),
    worldtlx4 = map_symbol("worldtlx4", 0x01126EC0),
    hanger_coords = map_symbol("hanger_coords", 0x01131E10),
    objlst = map_symbol("objlst", 0x01127060),
    objlst2 = map_symbol("objlst2", 0x01127080),
    objlst3 = map_symbol("objlst3", 0x011270A0),
    longchain = map_symbol("longchain", 0xFFC09360),
    TINCHAIN4 = map_symbol("TINCHAIN4", 0xFFC09240),
    TINHOOK = map_symbol("TINHOOK", 0xFFC092D0),
}

-- These labels are local .bss symbols, so only hanger_coords is visible in
-- the map. Offsets are raw TMS bit counts from MKHANG.ASM.
A.hp_body_ptr = A.hanger_coords + (NHANGERS * 32)
A.hp_splash_x = A.hp_body_ptr + (NHANGERS * 32)
A.hp_origin_y = A.hp_splash_x + (NHANGERS * 16)
A.hp_rise_y = A.hp_origin_y + (NHANGERS * 16)
A.hp_lift_fx_ctr = A.hp_rise_y + (NHANGERS * 16)
A.hp_hook_hold = A.hp_lift_fx_ctr + (NHANGERS * 16)
A.hp_skel_visible = A.hp_hook_hold + (NHANGERS * 32)
A.hp_autodrop_ctr = A.hp_skel_visible + (NHANGERS * 16)
A.hp_dropped = A.hp_autodrop_ctr + (NHANGERS * 16)
A.hp_dropped_init = A.hp_dropped + (NHANGERS * 16)
A.hp_drop_busy = A.hp_dropped_init + 16
A.hp_lower_strips = A.hp_drop_busy + 16

local O = {
    next = 0x000,
    oxpos = 0x090,
    oypos = 0x0B0,
    ozpos = 0x0D0,
    oflags = 0x0F0,
    osag = 0x100,
    osizex = 0x120,
    osizey = 0x130,
    opal = 0x140,
    oflags2 = 0x160,
    oimg = 0x1A0,
    oid = 0x1C0,
    oshape = 0x1D0,
}

local M_INVIS = 0x0020
local CHAIN_HEIGHT = 211
local TIN_HEIGHT = 70
local HOOK_HEIGHT = 21
local MPART_ENTRY_BITS = 0x70
local MPART_SCAN_MAX = 40

local names = {
    "ED", "MARK", "TONY", "JOHN", "GEO", "JEFF", "SAL", "STEVE", "ERIC"
}

local function multipart_count(img)
    if img == 0 then return 0 end
    local n = 0
    while n < MPART_SCAN_MAX do
        if r32(img + (n * MPART_ENTRY_BITS)) == 0 then
            return n
        end
        n = n + 1
    end
    return n
end

local function obj_info(ptr, list_name, list_index, kind)
    if ptr == 0 then return nil end
    local img = r32(ptr + O.oimg)
    local w = img ~= 0 and r16(img + 0x00) or 0
    local h = img ~= 0 and r16(img + 0x10) or 0
    return {
        ptr = ptr,
        list = list_name,
        list_index = list_index,
        kind = kind,
        x = i16(r16(ptr + O.oxpos)),
        y = i16(r16(ptr + O.oypos)),
        z = i16(r16(ptr + O.ozpos)),
        flags = r16(ptr + O.oflags),
        flags2 = r16(ptr + O.oflags2),
        oid = r16(ptr + O.oid),
        img = img,
        osag = r32(ptr + O.osag),
        w = w,
        h = h,
        mp_count = kind == "body" and multipart_count(img) or nil,
    }
end

local function img_kind(img)
    if img == A.longchain then return "long" end
    if img == A.TINCHAIN4 then return "tin" end
    if img == A.TINHOOK then return "hook" end
    if img == 0 then return nil end

    local w = r16(img + 0x00)
    local h = r16(img + 0x10)
    if w == 5 and h == CHAIN_HEIGHT then return "long" end
    if w == 4 and h == TIN_HEIGHT then return "tin" end
    if w == 8 and h == HOOK_HEIGHT then return "hook" end
    return nil
end

local function collect_metal()
    local out = { long = {}, tin = {}, hook = {} }
    local lists = {
        { "objlst", A.objlst },
        { "objlst2", A.objlst2 },
        { "objlst3", A.objlst3 },
    }
    for _, item in ipairs(lists) do
        local list_name = item[1]
        local head_addr = item[2]
        local p = r32(head_addr)
        local guard = 0
        while p ~= 0 and guard < 260 do
            local img = r32(p + O.oimg)
            local kind = img_kind(img)
            if kind then
                table.insert(out[kind], obj_info(p, list_name, guard, kind))
            end
            p = r32(p + O.next)
            guard = guard + 1
        end
    end
    return out
end

local function nearest(items, body, used, max_dx)
    if not body then return nil end
    local best = nil
    local best_score = 999999
    for _, it in ipairs(items) do
        if it and not used[it.ptr] then
            local dx = math.abs(it.x - body.x)
            local score = dx
            if dx <= max_dx and score < best_score then
                best = it
                best_score = score
            end
        end
    end
    if best then used[best.ptr] = true end
    return best
end

local function slot_state(slot)
    local ptr = r32(A.hp_body_ptr + (slot * 32))
    local body = nil
    if ptr ~= 0 then
        body = obj_info(ptr, "hp_body_ptr", slot, "body")
    end
    return {
        slot = slot,
        name = names[slot + 1] or tostring(slot),
        body = body,
        ctr = r16(A.hp_autodrop_ctr + (slot * 16)),
        dropped = r16(A.hp_dropped + (slot * 16)),
        skel_visible = r16(A.hp_skel_visible + (slot * 16)),
        lower_strips = r16(A.hp_lower_strips + (slot * 16)),
        origin_y = i16(r16(A.hp_origin_y + (slot * 16))),
        rise_y = i16(r16(A.hp_rise_y + (slot * 16))),
        splash_x = i16(r16(A.hp_splash_x + (slot * 16))),
    }
end

local function body_label(body)
    if not body then return "body=null" end
    local inv = (body.flags2 & M_INVIS) ~= 0 and "I" or "V"
    return string.format(
        "body=%s xy=%d,%d z=%d img=%s mp=%d fl2=%04X/%s",
        hx(body.ptr), body.x, body.y, body.z, hx(body.img), body.mp_count or -1,
        body.flags2, inv)
end

local function metal_label(prefix, it, body)
    if not it then return prefix .. "=none" end
    local dx = body and (it.x - body.x) or 0
    local dy = body and (it.y - body.y) or 0
    local inv = (it.flags2 & M_INVIS) ~= 0 and "I" or "V"
    return string.format(
        "%s=%s xy=%d,%d d=%+d,%+d z=%d img=%s %dx%d %s",
        prefix, hx(it.ptr), it.x, it.y, dx, dy, it.z, hx(it.img), it.w, it.h, inv)
end

local function slot_line(st)
    local b = st.body
    local long = st.long
    local tin = st.tin
    local hook = st.hook
    local hook_dy = (b and hook) and (hook.y - b.y) or 0
    local long_bottom = long and (long.y + CHAIN_HEIGHT) or 0
    local tin_bottom = tin and (tin.y + TIN_HEIGHT) or 0
    local hook_bottom = hook and (hook.y + HOOK_HEIGHT) or 0
    return string.format(
        "s%d %-5s ctr=%04X drop=%d sk=%d low=%d org=%d rise=%d splash=%d hook_dy=%+d bottoms L/T/H=%d/%d/%d | %s | %s | %s | %s",
        st.slot, st.name, st.ctr, st.dropped, st.skel_visible, st.lower_strips,
        st.origin_y, st.rise_y, st.splash_x, hook_dy, long_bottom, tin_bottom, hook_bottom,
        body_label(b),
        metal_label("long", long, b),
        metal_label("tin", tin, b),
        metal_label("hook", hook, b))
end

local function scan_state()
    local metal = collect_metal()
    local used_long, used_tin, used_hook = {}, {}, {}
    local states = {}

    for slot = 0, NHANGERS - 1 do
        local st = slot_state(slot)
        if st.body then
            st.long = nearest(metal.long, st.body, used_long, 80)
            st.tin = nearest(metal.tin, st.body, used_tin, 80)
            st.hook = nearest(metal.hook, st.body, used_hook, 80)
        end
        states[#states + 1] = st
    end

    return states, metal
end

local function draw_overlay(lines)
    if not DRAW_OVERLAY then return end
    local screen = nil
    pcall(function() screen = manager.machine.screens[":screen"] end)
    if not screen then return end
    for i = 1, math.min(#lines, OVERLAY_LINES) do
        pcall(function()
            screen:draw_text(4, 4 + ((i - 1) * 10), lines[i], 0xffffffff, 0x80000000)
        end)
    end
end

local frame = 0
local last_counts = ""

local function on_frame()
    frame = frame + 1
    if not space then return end

    local states, metal = scan_state()
    local counts = string.format(
        "chains long=%d tin=%d hook=%d",
        #metal.long, #metal.tin, #metal.hook)
    local header = string.format(
        "DP hanger monitor f=%04d gs=%d cb=%d win=%d drop_busy=%d worldtlx4=%d %s",
        frame, r16(A.gstate), r16(A.curback), r16(A.winner_status),
        r16(A.hp_drop_busy), i16(r16(A.worldtlx4)), counts)

    local overlay = { header }
    for _, st in ipairs(states) do
        if st.body then
            local hook_dy = st.hook and (st.hook.y - st.body.y) or 0
            local short = string.format(
                "s%d %-5s b=%d,%d mp=%d low=%d hdy=%+d ctr=%04X drop=%d sk=%d L/T/H=%s/%s/%s",
                st.slot, st.name, st.body.x, st.body.y, st.body.mp_count or -1,
                st.lower_strips, hook_dy, st.ctr, st.dropped, st.skel_visible,
                st.long and "Y" or "n",
                st.tin and "Y" or "n",
                st.hook and "Y" or "n")
            overlay[#overlay + 1] = short
        end
    end
    draw_overlay(overlay)

    if frame % LOG_EVERY_FRAMES ~= 0 and counts == last_counts then
        return
    end
    last_counts = counts

    log(header)
    for _, st in ipairs(states) do
        if st.body then
            log("  " .. slot_line(st))
        end
    end
end

log("deadpool_hanger_monitor.lua loaded")
log("log=" .. LOG_PATH)
log(string.format(
    "symbols hanger_coords=%s hp_body_ptr=%s objlst=%s objlst2=%s objlst3=%s",
    hx(A.hanger_coords), hx(A.hp_body_ptr), hx(A.objlst), hx(A.objlst2), hx(A.objlst3)))
log(string.format(
    "art longchain=%s TINCHAIN4=%s TINHOOK=%s",
    hx(A.longchain), hx(A.TINCHAIN4), hx(A.TINHOOK)))

if not space then
    log("ERROR: no :maincpu program space")
else
    emu.register_frame_done(on_frame)
end
