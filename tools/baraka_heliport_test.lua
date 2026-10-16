-- baraka_heliport_test.lua
--
-- Drives a 2P match, picks P1 Baraka vs P2 Jax, fires Up,Up + LK
-- (do_sa_helitest - the heliport) on a loop and logs enough per-frame state to
-- VALIDATE THE ANIMATION, not just "did it not crash":
--
--   * the SAG (image-data pointer) of P1's object every tick of the move, so
--     tools/heli_check.py can collapse it to (pose, ticks) runs and diff those
--     against what src/MKSA.ASM actually holds.  A lane that assembles fine and
--     plays the wrong holds is invisible to every other check here.
--   * the climb (oypos leaving the top), the far-side teleport (oxpos crossing
--     the opponent), and the seat oypos the descent starts from.
--   * m_shadow: OFF for the whole descent, back ON after.  The descent draws
--     bank-1 sidecar strips and shadow_p1p2 has no bank select, so a shadow
--     left on there shreds them.
--   * the victim handover - the path that used to scribble on gstate/p1_obj.
--
-- THE INPUT IS THE HARD PART and it is swept, not guessed.  sa_lo_kick wants
-- two sw_up closes and then LK, and do_sa_helitest's SAHT_GROUND_BAND rejects
-- the move once he is more than 40px off the floor - about four ticks of jump.
-- So the whole Up,Up,LK has to land inside ~4 ticks, and a single hardcoded
-- pattern that misses by one tick looks exactly like a broken move.  PATTERNS
-- below is rotated one per cycle and the summary says which ones fired.
--
-- Env:
--   HELI_COLBOX=1     green collision-box overlay on
--   HELI_CYCLES=n     how many input cycles to run (default 8)
--   HELI_TURN_AWAY=1  at the descent, turn the victim's back to Baraka, to
--                     check he is turned round when the blades hit (p2fh=)

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/baraka_heliport_test.log", "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local fields = {}
local cpu, space = nil, nil
local charsel_frame, vs_frame, fighting_frame = 0, 0, 0
local p1_confirm_start, p2_confirm_start = 0, 0
local p1_char_now, p2_char_now = -1, -1
local dx_now = 0
local last_gstate = -1
local did_error = false
local last_p1act, last_p2act = 0xffff, 0xffff
local snapped = {}

-- src/mk2.map bit addresses, GENERATED, never hardcoded here.
--
-- These move on every relink.  Deleting the dive's blood shifted all of them
-- by +020h, and nothing complained: gstate read 400, every pointer read null,
-- and the run reported "starts=0" - identical to a ROM that never booted.  An
-- hour can go into debugging a working ROM that way.
--
-- tools/heli_expect.py --lua-addrs writes heli_addrs.lua straight out of
-- mk2.map, so it is right by construction for whatever was last linked.  Run
-- it after every build, before this.
local A = dofile("C:/Users/you/Workplace/mk2-main/tools/heli_addrs.lua")
local GSTATE   = A.gstate
local P1_CHAR  = A.p1_char
local P2_CHAR  = A.p2_char
local P1_OBJ   = A.p1_obj
local P2_OBJ   = A.p2_obj
local P1_PROC  = A.p1_proc
local P2_PROC  = A.p2_proc
local P2_BAR   = A.p2_bar
local F_COLBOX = A.f_colbox
local PF_RAM   = A.pf_ram
local OBJLST   = A.objlst
local OBJLST2  = A.objlst2

-- Live object count.  The dive's slice blood (sahb_slice, blood_procs 17)
-- spawns four drips per blade pass and nothing else in the checker can see
-- them, so this is how "the blood actually came out" gets measured rather
-- than assumed.
local function count_objs()
    if not space then return 0 end
    local n = 0
    for _, head in ipairs({OBJLST, OBJLST2}) do
        local p = space:read_u32(head)
        while p ~= 0 and n < 400 do n = n + 1; p = space:read_u32(p + 0x000) end
    end
    return n
end

-- pdata = 0x100 (MAINEQU.ASM), so p_action = pdata+0f0h, p_ganiy = pdata+100h
local PROC_ACTION, PROC_GANIY = 0x1f0, 0x200
local OBJ_OYVEL, OBJ_OXPOS, OBJ_OYPOS = 0x060, 0x090, 0x0b0
local OBJ_OFLAGS, OBJ_OFLAGS2, OBJ_OIMG, OBJ_OSHAPE = 0x0f0, 0x160, 0x1a0, 0x1d0
local M_FLIPH = 0x0010          -- DISPEQU.ASM: facing.  1 = mirrored = facing
                                -- LEFT.  Logged because the descent's flip
                                -- sense is this bit XOR the lane's ani_flip,
                                -- and "he mirrors the wrong way" is a question
                                -- about which side of the opponent he landed.
-- EVERY pose in both lanes is a multipart wrapper, and for those oimg is NOT
-- an image header - get_multi_obj puts the multipart RAM block there
-- (MKUTIL.ASM:983) and ani2 writes piece #1's SAG as its first long
-- (MKUTIL.ASM:154, `move *a5(isag),*a1+,l').  So the SAG is at oimg+0, not at
-- the isag=40h a plain image header would use; reading +64 lands on the
-- control/anioffset words and yields a ROM pointer that changes per pose and
-- looks plausible, which is exactly how this was wrong the first time.
-- oshape carries the wrapper address itself and is logged as a cross-check.
local IMG_SAG = 0
local M_SHADOW = 0x0010

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_BARAKA, FT_JAX = 3, 11
local ACT_SA_SPIN = 0x0121          -- do_sa_helitest runs under act_sa_spin
local MKBUG_START, MKBUG_END = 0xffa30000, 0xffa36000

-- {up1 width, gap, up2 width, LK delay from the FIRST up}, in ticks.
local PATTERNS = {
    {1, 1, 1, 3}, {1, 1, 1, 2}, {2, 1, 1, 4}, {1, 1, 2, 3},
    {1, 2, 1, 4}, {2, 1, 2, 4}, {1, 1, 1, 4}, {2, 2, 2, 5},
}
local CYCLE = 260
local want_cycles = tonumber(os.getenv("HELI_CYCLES") or "8")

-- P2 GUARDS ON ODD CYCLES.  sahv_he_blocked is a whole branch - chip damage,
-- the lane bail, and a Scorpion-teleport-style flight out - and none of it was
-- ever exercised, because the harness only ever stood there.  Holding block
-- through the dive on alternating attempts covers both paths in one run.
local function p2_guarding()
    if fighting_frame == 0 then return false end
    local n = math.floor((frame - fighting_frame) / CYCLE)
    return (n % 2) == 1
end

local starts, lands, pattern_hit = 0, 0, {}
local move_start, move_pat = 0, 0
local climb_min_y, seat_y, teleport_dx = nil, nil, nil
local descent_start = 0
local shadow_off_seen, shadow_back_seen = false, false
local takeover_seen = false
local p2_bar_at_start = nil
-- THE VICTIM OUTLIVES THE MOVE.  a_sa_helivictim is 59 ticks from the entry-5
-- hook, i.e. dive tick ~10+59 = 69, while do_sa_helitest ends around 90 - but
-- the hook fires late enough that his knockdown is still running when Baraka
-- is back in his stance.  Tracing only while p1act == act_sa_spin cut the last
-- 8 ticks off and read as a lane mismatch when the lane was perfect.
local tail_ticks = 0
local TAIL = 40
-- log_state() runs BEFORE the tail block and still emits a T row on the very
-- frame the move ends, so without this the end frame is logged twice and the
-- pose it lands on reads one tick long - which looks exactly like the lane
-- holding a frame too many.
local last_logged_frame = -1

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["Coin 2"] = true,
        ["1 Player Start"] = true, ["2 Players Start"] = true,
        ["P1 Up"] = true, ["P1 Down"] = true, ["P1 Left"] = true, ["P1 Right"] = true,
        ["P1 High Punch"] = true, ["P1 Low Kick"] = true,
        ["P2 Up"] = true, ["P2 Down"] = true, ["P2 Left"] = true, ["P2 Right"] = true,
        ["P2 High Punch"] = true,
        ["P2 Block"] = true, ["P2 Block 2"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[heli] input %-18s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    if ok and s then return s end
    return nil
end

local function snap(label)
    if snapped[label] then return end
    snapped[label] = true
    local s = main_screen()
    if s then pcall(function() s:snapshot() end) end
end

local function cpu_reg(name)
    if not cpu then return nil end
    local ok, item = pcall(function() return cpu.state[name] end)
    if not ok or not item then return nil end
    local okv, v = pcall(function() return item.value end)
    if okv then return v end
    return nil
end

local function hx(v) if v == nil then return "na" end return string.format("0x%08x", v) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function s32(v) v = v & 0xffffffff; if v >= 0x80000000 then return v - 0x100000000 end return v end

local function cur_pattern()
    if fighting_frame == 0 then return PATTERNS[1], 1 end
    local n = math.floor((frame - fighting_frame) / CYCLE) % #PATTERNS + 1
    return PATTERNS[n], n
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end

    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame > 400 and (frame % 90) < 22
        end
        if name == "1 Player Start" then
            return frame > 560 and (frame % 180) >= 90 and (frame % 180) < 130
        end
        if name == "2 Players Start" then
            return frame > 560 and (frame % 180) >= 130
        end
    end
    if name == "2 Players Start" and charsel_frame > 0 and p2_char_now == 0xffff then
        return (frame % 40) < 12
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        local r = frame - charsel_frame
        if r > 40 then
            local q = r % 32
            if name == "P1 Right" and p1_confirm_start == 0 then return q < 6 end
            if name == "P1 Down"  and p1_confirm_start == 0 then return q >= 16 and q < 22 end
            if name == "P1 High Punch" and p1_confirm_start > 0 then
                return frame >= p1_confirm_start and frame < p1_confirm_start + 40
            end
            if name == "P2 Right" and p2_confirm_start == 0 then return q >= 8 and q < 14 end
            if name == "P2 Down"  and p2_confirm_start == 0 then return q >= 24 and q < 30 end
            if name == "P2 High Punch" and p2_confirm_start > 0 then
                return frame >= p2_confirm_start and frame < p2_confirm_start + 40
            end
        end
        return false
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        if r < 60 then return false end
        local c = r % CYCLE
        local p = cur_pattern()
        local up1_w, gap, up2_w, lk_d = p[1], p[2], p[3], p[4]
        local up2_at = up1_w + gap
        -- The input burst.  Everything else in the cycle is recovery time.
        if name == "P1 Up" then
            return (c < up1_w) or (c >= up2_at and c < up2_at + up2_w)
        end
        if name == "P1 Low Kick" then
            return c >= lk_d and c < lk_d + 2
        end
        -- Walk back into range between attempts; he lands on the FAR side
        -- every time, so the correction has to work from either direction.
        if (name == "P2 Block" or name == "P2 Block 2") and p2_guarding() then
            return c < 150          -- up before the dive lands, down after
        end
        if name == "P1 Right" then return dx_now > 130 and c > 150 and c < 230 end
        if name == "P1 Left"  then return dx_now < -130 and c > 150 and c < 230 end
    end
    return false
end

local function proc_action(p)
    if p == 0 then return 0xffff end
    return space:read_u16(p + PROC_ACTION)
end

local function check_cpu_lockup()
    if did_error or not space or fighting_frame == 0 then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local pf = space:read_u32(PF_RAM)
    if pf == 0xffffffff or (pc and pc >= MKBUG_START and pc <= MKBUG_END) then
        did_error = true
        snap("mkbug_lockup")
        print(string.format("[heli] ERROR mkbug_lockup frame=%d pc=%s pf=%s", frame, hx(pc), hx(pf)))
        manager.machine:exit()
        return true
    end
    return false
end

local function log_state()
    if not space then return end
    local gs = space:read_u16(GSTATE)
    local p1obj, p2obj = space:read_u32(P1_OBJ), space:read_u32(P2_OBJ)
    local p1proc = space:read_u32(P1_PROC)
    local p1act, p2act = proc_action(p1proc), proc_action(space:read_u32(P2_PROC))
    local p1x, p1y, p1sag, p1fl2, p1yv, p1shape, p1fl = 0, 0, 0, 0, 0, 0, 0
    local p2x, p2y, p2sag = 0, 0, 0
    local ganiy = 0
    if p1obj ~= 0 then
        p1x   = space:read_u16(p1obj + OBJ_OXPOS)
        p1y   = s16(space:read_u16(p1obj + OBJ_OYPOS))
        p1fl2 = space:read_u32(p1obj + OBJ_OFLAGS2)
        p1fl  = space:read_u16(p1obj + OBJ_OFLAGS)
        p1yv  = s32(space:read_u32(p1obj + OBJ_OYVEL))
        local img = space:read_u32(p1obj + OBJ_OIMG)
        if img ~= 0 then p1sag = space:read_u32(img + IMG_SAG) end
        p1shape = space:read_u32(p1obj + OBJ_OSHAPE)
    end
    if p2obj ~= 0 then
        p2x = space:read_u16(p2obj + OBJ_OXPOS)
        p2y = s16(space:read_u16(p2obj + OBJ_OYPOS))
        -- the VICTIM's pose, same multipart rule as P1: oimg is the multipart
        -- RAM block and its first long is piece #1's SAG
        local i2 = space:read_u32(p2obj + OBJ_OIMG)
        if i2 ~= 0 then p2sag = space:read_u32(i2 + IMG_SAG) end
    end
    if p1proc ~= 0 then ganiy = s16(space:read_u16(p1proc + PROC_GANIY)) end
    local p2bar = space:read_u16(P2_BAR)

    if gs == GS_PSEL and frame % 20 == 0 then
        print(string.format("[heli] select f=%d p1char=%d (want %d) p2char=%d (want %d)",
            frame, space:read_u16(P1_CHAR), FT_BARAKA, space:read_u16(P2_CHAR), FT_JAX))
    end

    -- ---- move start -----------------------------------------------------
    if p1act == ACT_SA_SPIN and last_p1act ~= ACT_SA_SPIN then
        local _, n = cur_pattern()
        starts = starts + 1
        move_start, move_pat = frame, n
        climb_min_y, seat_y, teleport_dx, descent_start = p1y, nil, nil, 0
        shadow_off_seen, shadow_back_seen, takeover_seen = false, false, false
        p2_bar_at_start = p2bar
        pattern_hit[n] = (pattern_hit[n] or 0) + 1
        print(string.format("[heli] GUARD %s", tostring(p2_guarding())))
        print(string.format("[heli] START #%d frame=%d pattern=%d {%d,%d,%d,%d} p1=%d,%d dx=%d ganiy=%d",
            starts, frame, n, PATTERNS[n][1], PATTERNS[n][2], PATTERNS[n][3], PATTERNS[n][4],
            p1x, p1y, p2x - p1x, ganiy))
        snap("heli_start")
    end

    -- ---- during the move ------------------------------------------------
    if move_start > 0 then
        local t = frame - move_start
        if climb_min_y == nil or p1y < climb_min_y then climb_min_y = p1y end
        if (p1fl2 & M_SHADOW) == 0 then shadow_off_seen = true end
        if shadow_off_seen and descent_start > 0 and (p1fl2 & M_SHADOW) ~= 0 then
            shadow_back_seen = true
        end
        -- the seat: oypos snaps from off the top back to the ground line, once
        if descent_start == 0 and climb_min_y and climb_min_y < -100 and p1y > 100 then
            descent_start = frame
            seat_y = p1y
            teleport_dx = p2x - p1x
            print(string.format("[heli] DESCENT frame=%d t=%d seat_y=%d ganiy=%d (want ganiy+1) dx=%d",
                frame, t, p1y, ganiy, p2x - p1x))
            snap("heli_descent")
            if os.getenv("HELI_TURN_AWAY") == "1" then
                local o2 = space:read_u32(P2_OBJ)
                local f = space:read_u16(o2 + OBJ_OFLAGS)
                -- unflipped faces +x, so a man to Baraka's RIGHT has his back to him unflipped
                local away = (p2x > p1x) and 0 or M_FLIPH
                space:write_u16(o2 + OBJ_OFLAGS, (f & ~M_FLIPH) | away)
                print(string.format("[heli] TURNED victim away fh=%d", away ~= 0 and 1 or 0))
            end
        end
        if p2act == 0 and last_p2act ~= 0 and not takeover_seen then
            takeover_seen = true
            print(string.format("[heli] TAKEOVER frame=%d t=%d p2bar=%d", frame, t, p2bar))
        end
        -- the per-tick trace heli_check.py reads
        last_logged_frame = frame
        print(string.format("[heli] T f=%d t=%d act=0x%04x sag=0x%08x y=%d x=%d yv=%d sh=%d ganiy=%d shape=0x%08x v=0x%08x vx=%d vy=%d fh=%d obj=%d",
            frame, t, p1act, p1sag, p1y, p1x, p1yv,
            (p1fl2 & M_SHADOW) ~= 0 and 1 or 0, ganiy, p1shape,
            p2sag, p2x, p2y, (p1fl & M_FLIPH) ~= 0 and 1 or 0, count_objs()))
        if p2obj ~= 0 then print(string.format("[heli] P2F t=%d p2fh=%d", t, (space:read_u16(p2obj + OBJ_OFLAGS) & M_FLIPH) ~= 0 and 1 or 0)) end
        if p1act ~= ACT_SA_SPIN and last_p1act == ACT_SA_SPIN then
            tail_ticks = TAIL
            lands = lands + 1
            print(string.format(
                "[heli] END frame=%d dur=%d climb_min_y=%d seat_y=%s descent_ticks=%s shadow_off=%s shadow_back=%s takeover=%s p2bar %s->%d",
                frame, t, climb_min_y, tostring(seat_y),
                descent_start > 0 and tostring(frame - descent_start) or "na",
                tostring(shadow_off_seen), tostring(shadow_back_seen), tostring(takeover_seen),
                tostring(p2_bar_at_start), p2bar))
            snap("heli_end")
            move_start = 0
        elseif t > 220 then
            print(string.format("[heli] STUCK frame=%d - act still 0x%04x after %d ticks", frame, p1act, t))
            move_start = 0
        end
    end

    -- keep tracing past the end of the move so the victim's tail is captured
    if move_start == 0 and tail_ticks > 0 and frame ~= last_logged_frame then
        tail_ticks = tail_ticks - 1
        last_logged_frame = frame
        print(string.format("[heli] T f=%d t=-1 act=0x%04x sag=0x%08x y=%d x=%d"
            .. " yv=%d sh=%d ganiy=%d shape=0x%08x v=0x%08x vx=%d vy=%d fh=%d",
            frame, p1act, p1sag, p1y, p1x, p1yv,
            (p1fl2 & M_SHADOW) ~= 0 and 1 or 0, ganiy, p1shape, p2sag, p2x, p2y,
            (p1fl & M_FLIPH) ~= 0 and 1 or 0))
    end

    if frame % 60 == 0 and fighting_frame > 0 and move_start == 0 and tail_ticks == 0 then
        print(string.format("[heli] idle f=%d gs=%d p1act=0x%04x p1=%d,%d dx=%d",
            frame, gs, p1act, p1x, p1y, p2x - p1x))
    end
    last_p1act, last_p2act = p1act, p2act
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[heli] loaded: P1 Baraka vs P2 Jax, Up,Up + LK, sweeping "
              .. #PATTERNS .. " input patterns")
    end

    if space then
        if os.getenv("HELI_COLBOX") == "1" then space:write_u16(F_COLBOX, 1) end
        local gs = space:read_u16(GSTATE)
        -- Every real gstate is small (gs_amode/gs_psel/gs_fighting/gs_post are
        -- all under 0x20).  A big one means GSTATE is not gstate - i.e. the
        -- generated address table is from a different link than the ROM in
        -- MAME.  Say so loudly instead of reporting "starts=0" for ten minutes.
        if gs > 0x100 and frame > 30 and not did_error then
            did_error = true
            print(string.format(
                "[heli] ERROR gstate reads %d at 0x%08x - that is not gstate. "
                .. "heli_addrs.lua is stale: re-run "
                .. "`python tools/heli_expect.py --lua-addrs tools/heli_addrs.lua` "
                .. "AFTER the build that produced the installed ROM.", gs, GSTATE))
            manager.machine:exit()
            return
        end
        if gs ~= last_gstate then
            print(string.format("[heli] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                snap("fight_start")
            end
            last_gstate = gs
        end
        local o1, o2 = space:read_u32(P1_OBJ), space:read_u32(P2_OBJ)
        if o1 ~= 0 and o2 ~= 0 then
            dx_now = space:read_u16(o2 + OBJ_OXPOS) - space:read_u16(o1 + OBJ_OXPOS)
        end
        p1_char_now = space:read_u16(P1_CHAR)
        p2_char_now = space:read_u16(P2_CHAR)
        if charsel_frame > 0 and gs == GS_PSEL then
            if p1_confirm_start == 0 and p1_char_now == FT_BARAKA then
                p1_confirm_start = frame
                print(string.format("[heli] p1 Baraka reached at frame=%d; confirming", frame))
            end
            if p2_confirm_start == 0 and p2_char_now == FT_JAX then
                p2_confirm_start = frame
                print(string.format("[heli] p2 Jax reached at frame=%d; confirming", frame))
            end
        end
        if check_cpu_lockup() then return end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    log_state()

    local done = fighting_frame > 0 and (frame - fighting_frame) > CYCLE * want_cycles + 120
    if done or frame > 12000 then
        local hits = {}
        for i = 1, #PATTERNS do
            hits[#hits + 1] = string.format("%d:%d", i, pattern_hit[i] or 0)
        end
        print(string.format("[heli] finished starts=%d lands=%d patterns %s%s",
            starts, lands, table.concat(hits, " "), done and "" or " (TIMEOUT)"))
        snap("final")
        manager.machine:exit()
    end
end)
