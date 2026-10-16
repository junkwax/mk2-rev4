-- hitpop_demo.lua - the free DMA field, spent on one clean hit
--
-- UNUSED_HARDWARE_EFFECTS #3, non-square oscale, wired in at
-- block_is_useless as hit_pop_arm / hit_pop_pass: the victim of a clean hit
-- is squashed by the blow for two ticks.
--
-- The white flash that used to share those two ticks (#2, per-object constant
-- colour) was removed on 2026-08-27, and so were its assertions.
--
-- Verified against the OBJECT FIELD, not against pixels: what the hardware
-- reads is oscale, so that is what is checked - during the pop AND after it,
-- because a restore that does not happen leaves a fighter 80% tall for the
-- rest of the round.  The rendering is then checked where rendering can be
-- checked, on the SHADOW: it is one flat colour on a light floor, so it
-- segments without any argument about what is sprite and what is not.
--
-- Env: MK2_ROOT, HITPOP_LOG, HITPOP_READY

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOG_PATH = os.getenv("HITPOP_LOG") or (ROOT .. "/tools/hitpop_demo.log")
local logfh = assert(io.open(LOG_PATH, "w"))
local function log(fmt, ...)
    local line = "[pop] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
do
    local fh = assert(io.open(ROOT .. "/src/mk2.map", "r"))
    for line in fh:lines() do
        for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
            symbols[name] = tonumber(addr, 16)
        end
    end
    fh:close()
end
local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
                     "p1_bar", "p2_bar", "p1_bar_view", "p2_bar_view", "winner_status",
                     "battle_num", "map_position", "f_freeze_timer",
                     "p1_obj", "p2_obj", "pop_state" }) do
    A[n] = symbols[n]
    if not A[n] then log("MISSING SYMBOL %s", n) end
end

local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_SUBZERO = 1, 8
local TOMB = 1                    -- no fxdemo driver on this stage
local OXVAL, OXPOS, OFLAGS, OPAL, OCONST, OSCALE = 0x080, 0x090, 0x0f0, 0x140, 0x150, 0x180
local HP_SCALE, HP_NORMAL = 0x014000d0, 0x01000100
local HP_REC = 32                 -- bits per player record

local frame, space, finished = 0, nil, false
local fields, held = {}, {}
local charsel_frame, fighting_frame, confirm_frame = 0, 0, 0
local snap_index, snap_queue = 0, {}
local fails, notes = {}, {}
local pops, good_pops, bad_restores = 0, 0, 0
local was_popping, restore_check = false, 0
local READY_PATH = os.getenv("HITPOP_READY") or (ROOT .. "/tools/hitpop_ready.flag")
local ready_written = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function fail(f) fails[#fails + 1] = f; log("FAIL %s", f) end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end
local function snap_now(label)
    local s = main_screen()
    local ok = false
    if s then ok = pcall(function() s:snapshot() end) end
    log("SNAP %04d %s (ok=%s)", snap_index, label, tostring(ok))
    snap_index = snap_index + 1
end
local function snap(label, delay)
    local at = frame + (delay or 1)
    snap_queue[at] = snap_queue[at] or {}
    table.insert(snap_queue[at], label)
end
local function snap_pump()
    local due = snap_queue[frame]
    if not due then return end
    snap_queue[frame] = nil
    for _, l in ipairs(due) do snap_now(l) end
end

local function ticks(i) return r16(A.pop_state + i * HP_REC) end

-- The widest run of black pixels on the floor under P2: his shadow, which
-- shadow_p1p2 draws with bpal_black out of colour map 0.  The frame buffer
-- holds INDICES, so this looks for index 0fh rather than for a colour - and
-- reads it the way every other rig here does, through rd8, because read_u16
-- aligns DOWN and would report every other pixel twice.
local squash_shadow, normal_shadow = 0, 0
local PAGE0, PAGE1
local function rd8(a)
    local w = space:read_u16(a - (a % 16))
    if (a % 16) >= 8 then return (w >> 8) & 0xff end
    return w & 0xff
end
local function pxv(page, x, y) return rd8(page + (y * 512 + x) * 8) end
local function widest_dark_run()
    if not PAGE0 then return 0 end
    local best = 0
    for _, page in ipairs({ PAGE0, PAGE1 }) do
        for y = 200, 235 do
            local run = 0
            for x = 60, 220 do
                if pxv(page, x, y) == 0x0f then
                    run = run + 1
                    if run > best then best = run end
                else
                    run = 0
                end
            end
        end
    end
    return best
end

local function setx(pobj, x)
    local o = r32(pobj)
    if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"] = true, ["Coin 2"] = true, ["1 Player Start"] = true,
                       ["2 Players Start"] = true, ["P1 High Punch"] = true,
                       ["P2 High Punch"] = true, ["UI Select"] = true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("---- hit pop: constant colour + non-square scale ----")
    end
    if not ready_written and frame >= 120 then
        local fh = io.open(READY_PATH, "w")
        if fh then fh:write("running"); fh:close(); ready_written = true end
    end

    held = {}
    if frame >= 5 and frame < 35 then held["UI Select"] = true end
    if frame >= 700 and frame < 980 and frame % 80 < 20 then held["Coin 1"] = true end
    if frame >= 720 and frame < 980 and frame % 80 < 20 then held["Coin 2"] = true end
    if frame >= 1000 and frame < 1080 then held["1 Player Start"] = true end
    if frame >= 1040 and frame < 1140 then held["2 Players Start"] = true end

    local gs = space and r16(A.gstate) or 0
    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_KANG)
        w16(A.curback, TOMB)
        if A.map_position then w16(A.map_position, 0) end
        if A.battle_num then w16(A.battle_num, 1) end
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
        if confirm_frame > 0 then
            if frame >= confirm_frame and frame < confirm_frame + 45 then held["P1 High Punch"] = true end
            if frame >= confirm_frame + 70 and frame < confirm_frame + 115 then held["P2 High Punch"] = true end
        end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        local pa = r32(symbols["pageaddr"] or 0)
        local px, py = pa & 0xffff, (pa >> 16) & 0xffff
        PAGE0 = (py * 512 + px) * 8
        PAGE1 = (((py + 256) % 512) * 512 + px) * 8
        log("fight at frame %d, pages %08x/%08x", frame, PAGE0, PAGE1)
    end
    local rel = fighting_frame > 0 and frame - fighting_frame or -1

    -- stand P1 next to P2 and jab: the drone blocks some and eats some.
    -- Stops before the A/B below, which needs both fighters idle.
    if rel > 60 and rel < 2400 and rel % 24 < 6 then held["P1 High Punch"] = true end
    for n, f in pairs(fields) do f:set_value(held[n] and 1 or 0) end
    if not space or finished then return end
    snap_pump()
    if fighting_frame == 0 then
        if frame > 9000 then fail("never reached a fight"); finished = true; manager.machine:exit() end
        return
    end

    -- P1 is propped up; P2 is NOT, so his bar dropping is the proof that the
    -- jabs are landing at all.  Topped back up whenever he gets low.
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    if r16(A.p2_bar) < 60 then w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP) end
    if A.winner_status then w16(A.winner_status, 0) end
    if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
    if rel == 40 or (rel > 60 and rel % 180 == 0) then
        setx(A.p1_obj, 380); setx(A.p2_obj, 436)
    end
    if rel % 120 == 0 and rel > 0 then
        local o = r32(A.p2_obj)
        log("rel=%4d p2_bar=%d p1x=%d p2x=%d pop=[%d,%d] oflags=%04x oscale=%08x",
            rel, r16(A.p2_bar),
            s16(r16(r32(A.p1_obj) + OXPOS)), s16(r16(o + OXPOS)),
            ticks(0), ticks(1), r16(o + OFLAGS), r32(o + OSCALE))
    end

    -- P2 is the one being hit, so record 1 is the one that moves
    local t = ticks(1)
    local popping = t > 0
    if popping and not was_popping then
        pops = pops + 1
        local o = r32(A.p2_obj)
        if o ~= 0 then
            -- the arm only records; the pass writes the field on the NEXT frame
            if pops <= 3 then
                log("pop %d armed: ticks=%d oscale=%08x", pops, t, r32(o + OSCALE))
            end
            if pops <= 4 then
                snap("hit pop " .. pops, 2)
                snap("hit pop " .. pops .. " +1", 3)
            end
        end
        -- the hand-armed A/B below runs 40 ticks, so do not hold it to the
        -- two-tick shape
        if rel < 2590 then restore_check = frame + 6 end
    elseif popping then
        local o = r32(A.p2_obj)
        if o ~= 0 then
            local sc = r32(o + OSCALE)
            if sc == HP_SCALE then
                good_pops = good_pops + 1
                if good_pops <= 3 then log("pop %d live:  oscale=%08x", pops, sc) end
            elseif pops <= 4 then
                log("pop %d LIVE MISMATCH oscale=%08x", pops, sc)
            end
        end
    end
    was_popping = popping

    -- and it must give the object back
    if restore_check > 0 and frame == restore_check then
        restore_check = 0
        local o = r32(A.p2_obj)
        if o ~= 0 then
            local sc = r32(o + OSCALE)
            if sc ~= HP_NORMAL then
                bad_restores = bad_restores + 1
                fail(string.format("scale not restored after the pop (%08x)", sc))
            end
        end
    end

    -- ---- the SQUASH, on a fighter who is standing still ----
    --
    -- Two ticks of flash proves the constant colour by eye but says nothing
    -- about the scale, because the victim is mid-reaction and no two frames
    -- are the same pose.  So arm a LONG pop by hand - the record is ordinary
    -- ram, and filling it the way hit_pop_arm does is the same arming - and
    -- photograph an idle fighter squashed, then the same idle fighter after
    -- it expires.  A 20% height change on a 100px sprite is not a judgement
    -- call.
    if rel == 2600 then
        local o = r32(A.p2_obj)
        if o ~= 0 then
            space:write_u16(A.pop_state + HP_REC, 40)
            log("rel=%4d armed a 40-tick pop by hand for the A/B", rel)
        end
    elseif rel == 2612 then
        snap("squashed (long pop)", 1)
        squash_shadow = widest_dark_run()
    elseif rel == 2680 then
        snap("normal, same fighter", 1)
        normal_shadow = widest_dark_run()
        -- xscale 00d0h is 0.8125, so the blit comes out 1/0.8125 = 1.23x
        -- wider - and the SHADOW is the same blit, which is why it is the
        -- thing to measure: it is one flat colour on a light floor, so it
        -- segments without any argument about what is sprite and what is not
        local ratio = normal_shadow > 0 and (squash_shadow / normal_shadow) or 0
        notes[#notes + 1] = string.format(
            "shadow width: %d px squashed vs %d px normal = %.2fx (xscale asks 1.23x)",
            squash_shadow, normal_shadow, ratio)
        if ratio < 1.10 then
            fail("the non-square scale did not reach the blitter")
        end
    end

    if rel > 60 * 48 then
        notes[#notes + 1] = string.format("pops seen: %d, frames with the scale right: %d",
            pops, good_pops)
        for _, n in ipairs(notes) do log("%s", n) end
        if pops == 0 then fail("no hit ever armed the pop") end
        if good_pops == 0 then fail("the pass never wrote the scale") end
        if #fails == 0 then log("PASS") else log("FAILED: %s", table.concat(fails, "; ")) end
        finished = true
        manager.machine:exit()
    end
end)
