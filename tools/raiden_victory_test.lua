--- raiden_victory_test.lua - do Raiden's victory bolts leave dots behind?
---
--- The complaint: "a few dot artifacts, I believe from his bolt, around his
--- body" during Raiden's victory pose.  Two candidate causes, and they are
--- distinguishable by WHEN the dots are on screen:
---
---   art  - RNVICBOLT frames carry 62 stray 1-2px clusters in the stock art
---          (identical in mk2-readonly), so specks flash during the bolt
---          animation and vanish with it.
---   code - a bolt OBJECT outlives the animation, leaving its final sparse
---          frame (RNVICBOLT8 is only 234 lit pixels in 16 blobs - a spray of
---          dots) parked on screen for the whole pose.  victory_lighting used
---          to do exactly this via kmo_proc; it now uses safe_delobj.
---
--- So this harness watches the object list for objects whose SAG belongs to
--- the RNVICBOLT art, and reports how long any of them survive after the bolt
--- animation has finished.  Surviving bolt objects = the code cause.
---
--- Env: RAIDEN_VIC_LOG, RAIDEN_VIC_OBSERVE (frames after the win, default 420)

local ROOT = "C:/Users/you/Workplace/mk2-main"

local LOG_PATH = os.getenv("RAIDEN_VIC_LOG") or (ROOT .. "/tools/raiden_victory_test.log")
local OBSERVE = tonumber(os.getenv("RAIDEN_VIC_OBSERVE") or "") or 420

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end
local function log(fmt, ...)
    print("[rdvic] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
end
local function hx(v) return v == nil and "na" or string.format("0x%08x", v & 0xffffffff) end

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
local function sym(n)
    if symbols[n] == nil then log("WARN missing symbol %s", n) end
    return symbols[n] or 0
end

local A = {
    gstate = sym("gstate"), winner_status = sym("winner_status"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    curback = sym("curback"), f_death = sym("f_death"),
    objlst = sym("objlst"), objlst2 = sym("objlst2"), objlst3 = sym("objlst3"),
}
local O = { next = 0x000, oxpos = 0x090, oypos = 0x0b0, osag = 0x100, oimg = 0x1a0, ochar = 0x1f0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_RAIDEN, FT_JAX = 7, 11
local STAGE_ID = 5

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame = 0, 0
local p1_confirm_start = 0
local killed_frame, win_frame = 0, 0
local finished = false
local snap_index = 0
local bolt_last_seen, bolt_first_seen = 0, 0
local bolt_frames_after_anim = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

-- Every RNVICBOLT chunk SAG from the hand-maintained table, so a bolt object
-- can be recognised in the object list by the art it is pointing at.
local bolt_sags = {}
do
    local fh = io.open(ROOT .. "/src/MKBOLTS.TBL", "r")
    local current = nil
    if fh then
        for line in fh:lines() do
            local label = line:match("^(RNVICBOLT[%w]+):")
            if label then current = label end
            if current then
                local raw = line:match("%.long%s+0?([%x]+)[Hh]")
                if raw then
                    bolt_sags[tonumber(raw, 16) & 0x00ffffff] = current
                    current = nil
                end
            end
        end
        fh:close()
    end
    local n = 0
    for _ in pairs(bolt_sags) do n = n + 1 end
    log("loaded %d RNVICBOLT SAGs", n)
end

local function cache_fields()
    local wanted = { ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
                     ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        if not fields[name] then log("input %s MISSING", name); return false end
    end
    return true
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local function snap(label)
    local s = main_screen()
    local ok = false
    if s then ok = pcall(function() s:snapshot() end) end
    log("SNAP idx=%04d frame=%d label=%s ok=%s", snap_index, frame, label, tostring(ok))
    snap_index = snap_index + 1
end

local function walk(fn)
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        if list ~= 0 then
            local obj, guard, seen = r32(list), 0, {}
            while obj ~= 0 and guard < 400 do
                if seen[obj] then break end
                seen[obj] = true
                fn(obj)
                obj = r32(obj + O.next)
                guard = guard + 1
            end
        end
    end
end

-- Bolt objects currently on the display list, by art label.
local function bolt_objects()
    local found = {}
    walk(function(obj)
        local sag1 = r32(obj + O.osag) & 0x00ffffff
        local img = r32(obj + O.oimg)
        local sag2 = img ~= 0 and (r32(img) & 0x00ffffff) or 0
        local label = bolt_sags[sag1] or bolt_sags[sag2]
        if label then
            found[#found + 1] = string.format("%s@(%d,%d)", label,
                r16(obj + O.oxpos), r16(obj + O.oypos))
        end
    end)
    table.sort(found)
    return found
end

local function object_count()
    local n = 0
    walk(function() n = n + 1 end)
    return n
end

local function state_line(tag)
    local b = bolt_objects()
    return string.format("%s gs=%d ws=%d p1hp=%d p2hp=%d objs=%d bolts=%d[%s]",
        tag, r16(A.gstate), r16(A.winner_status), r16(A.p1_bar), r16(A.p2_bar),
        object_count(), #b, table.concat(b, " "))
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    snap(ok and "final_ok" or ("final_" .. reason))
    log("%s reason=%s | %s", ok and "PASS" or "FAIL", reason, state_line("end"))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "input_missing"); return end
        log("raiden victory bolt-persistence probe; observe=%d", OBSERVE)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight_start frame=%d | %s", frame, state_line("fs"))
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then
        w16(A.p1_char, FT_RAIDEN)
        w16(A.p2_char, FT_JAX)
        w16(A.curback, STAGE_ID)
        if A.p1_state ~= 0 then w16(A.p1_state, 1) end
        if A.p2_state ~= 0 then w16(A.p2_state, 1) end
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_RAIDEN and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
        end
    end

    -- Win the round outright: no fatality, just the plain victory path.
    if fighting_frame > 0 and killed_frame == 0 and frame > fighting_frame + 120 then
        w16(A.p2_bar, 0)
        killed_frame = frame
        log("killed_p2 frame=%d | %s", frame, state_line("kill"))
    end

    if killed_frame > 0 then
        local ws = r16(A.winner_status)
        if win_frame == 0 and ws == 1 then
            win_frame = frame
            log("winner_declared frame=%d | %s", frame, state_line("win"))
        end
    end

    if win_frame > 0 then
        local rel = frame - win_frame
        local b = bolt_objects()
        if #b > 0 then
            if bolt_first_seen == 0 then
                bolt_first_seen = rel
                log("bolts_appear rel=%d | %s", rel, state_line("bolt"))
            end
            bolt_last_seen = rel
        elseif bolt_last_seen > 0 then
            -- bolts already gone; nothing to do
        end
        if rel % 20 == 0 then log("rel=%d | %s", rel, state_line("obs")) end
        if rel % 30 == 0 and rel <= 300 then snap(string.format("vic_%03d", rel)) end
        if rel >= OBSERVE then
            log("bolt_first_seen=%d bolt_last_seen=%d (rel frames after the win)",
                bolt_first_seen, bolt_last_seen)
            -- The bolt animation is 8 authored frames at 4 ticks = ~32 ticks.
            -- Anything still present a long time after that is parked art.
            if bolt_last_seen > 120 then
                finish(false, "bolt_object_persists_to_rel_" .. bolt_last_seen)
            else
                finish(true, "bolts_cleaned_up_by_rel_" .. bolt_last_seen)
            end
            return
        end
    end

    if frame > 5400 and win_frame == 0 then finish(false, "never_reached_victory"); return end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)
