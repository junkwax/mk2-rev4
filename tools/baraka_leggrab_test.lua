-- baraka_leggrab_test.lua
-- Drives a 2P match, selects P1 Baraka vs P2 Jax, fires Back,Back + LK
-- (do_sa_leggrab - the scissor leg grab) on a loop and reports what happened:
-- did the move start, did the scissor catch, did the victim get taken over
-- and flipped, did anyone end up stuck.
--
-- Env:
--   BARAKA_LEGGRAB_P2_BLOCK=1    P2 holds block (exercises salg_blocked)
--   BARAKA_LEGGRAB_FORCE_MISS=1  P2 walks away (exercises salg_miss)
--   BARAKA_LEGGRAB_COLBOX=1      green collision-box overlay on

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/baraka_leggrab_test.log", "w")
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
local p1_confirm_start = 0
local p2_confirm_start = 0
local p1_char_now, p2_char_now = -1, -1
local dx_now = 0
local last_gstate = -1
local did_error = false
local last_p1act = 0xffff
local last_p2act = 0xffff
local hop_offset = 0
local grab_start_frame = 0
local grab_count, catch_count = 0, 0
local snapped = {}
local p2_bar_at_grab = nil
local caught_airborne = false
local tail_frames = 0
local land_min_y = nil
local bounce_seen = false

-- src/mk2.map bit addresses (MAME's TMS34010 program space is bit-addressed,
-- so these go into space:read_* verbatim).
--
-- REFRESH THESE AFTER ANY RELINK THAT MOVES BSS:
--     python sym_resolve.py --dump | grep -iwE 'gstate|p1_obj|...'
-- A full build.py shifted every one of them by -040h once, and the failure
-- mode is not obvious: gstate reads 0 and every pointer reads null, so the
-- run sits at "starts=0" and looks exactly like the game never booting -
-- while the snapshot shows it happily playing an attract-mode demo.
local ACTIVE   = 0x00109f6c0
local GSTATE   = 0x0010ed820
local P1_CHAR  = 0x0010ed8d0
local P2_CHAR  = 0x0010ee4a0
local P1_OBJ   = 0x0010ed870
local P2_OBJ   = 0x0010ee440
local P1_PROC  = 0x0010ed8b0
local P2_PROC  = 0x0010ee480
local P1_BAR   = 0x0010ed940
local P2_BAR   = 0x0010ee510
local F_COLBOX = 0x0010f0710
local PF_RAM   = 0x0010ef110
local OBJLST   = 0x0010ea5a0
local OBJLST2  = 0x0010ea5c0

local PROC_NEXT, PROC_ID, PROC_ACTION = 0x000, 0x020, 0x1f0
local OBJ_NEXT, OBJ_OXPOS, OBJ_OYPOS = 0x000, 0x090, 0x0b0
local OBJ_OFLAGS, OBJ_OFLAGS2, OBJ_OIMG, OBJ_OCHAR = 0x0f0, 0x160, 0x1a0, 0x1f0

local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_BARAKA, FT_JAX = 3, 11
local ACT_SA_LEGGRAB = 0x0124
local MKBUG_START, MKBUG_END = 0xffa30000, 0xffa36000

local p2_blocks  = os.getenv("BARAKA_LEGGRAB_P2_BLOCK") == "1"
local force_miss = os.getenv("BARAKA_LEGGRAB_FORCE_MISS") == "1"
local p2_jumps   = os.getenv("BARAKA_LEGGRAB_P2_JUMP") == "1"

local function cache_fields()
    local wanted = {
        ["UI Select"] = true, ["Coin 1"] = true, ["Coin 2"] = true,
        ["1 Player Start"] = true, ["2 Players Start"] = true,
        ["P1 Up"] = true, ["P1 Down"] = true, ["P1 Left"] = true, ["P1 Right"] = true,
        ["P1 High Punch"] = true, ["P1 Low Kick"] = true,
        ["P1 Low Punch"] = true, ["P1 Block"] = true, ["P1 Block 2"] = true,
        ["P2 Up"] = true, ["P2 Down"] = true, ["P2 Left"] = true, ["P2 Right"] = true,
        ["P2 Block"] = true, ["P2 Block 2"] = true, ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[leggrab] input %-18s %s", name, fields[name] and "ok" or "MISSING"))
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
    if s then
        local ok, err = pcall(function() s:snapshot() end)
        print(string.format("[leggrab] SNAP frame=%d label=%s ok=%s %s",
            frame, label, tostring(ok), ok and "" or tostring(err)))
    end
end

local function cpu_reg(name)
    if not cpu then return nil end
    local ok, item = pcall(function() return cpu.state[name] end)
    if not ok or not item then return nil end
    local okv, value = pcall(function() return item.value end)
    if okv then return value end
    return nil
end

local function hx(v) if v == nil then return "na" end return string.format("0x%08x", v) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local function count_list(addr)
    if not space then return 0 end
    local p = space:read_u32(addr)
    local n = 0
    while p ~= 0 and n < 256 do n = n + 1; p = space:read_u32(p + OBJ_NEXT) end
    return n
end

-- Down + Low Punch + Block, all held together.  button_bit_check tests the
-- other two on the tick the Low Punch switch closes, so Down and Block have to
-- already be down when LP is tapped.
local CYCLE = 200
local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end

    -- Coin up and start KEEP RETRYING until character select is actually
    -- reached.  These used to fire in fixed frame windows, which silently
    -- fails whenever boot timing drifts - the run then sits on the title
    -- screen to the timeout and looks exactly like a broken ROM.
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
    -- P2 can still join once select is up, and often has to: the pre-select
    -- start press lands while the machine is still counting the coin.  Keep
    -- offering it until his cursor actually exists (0xffff = not joined).
    if name == "2 Players Start" and charsel_frame > 0 and p2_char_now == 0xffff then
        return (frame % 40) < 12
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        local r = frame - charsel_frame
        -- Walk each cursor with repeated taps until it is ACTUALLY on the
        -- fighter we want, then confirm.  This used to be a counted sequence
        -- of moves, which drifts the moment boot timing changes and then
        -- silently selects somebody else - several runs were quietly testing
        -- Baraka vs Jade before this was noticed.  Right wraps around the
        -- grid, so one direction reaches anybody.
        -- Alternate Right and Down: Right alone dead-ends at the edge of the
        -- select grid (it parked on Reptile and never moved again).  The two
        -- together walk every square, so this reaches anybody from anywhere.
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
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 305
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        local c = r % CYCLE
        if r > 80 then
            if p2_blocks and (name == "P2 Block" or name == "P2 Block 2") then
                return c >= 20 and c < 90
            end
            if force_miss and name == "P2 Right" then return c < 70 end
            -- jump-in: hop toward Baraka so the scissor has to catch him
            -- off the ground.  P2 starts on the right, so "toward" is Left.
            -- Neutral vertical hop, no direction: holding a direction walks
            -- him past Baraka and out of range for the rest of the run.
            -- Timed to be DESCENDING through the strike window.  The grab
            -- starts on the LP press at c~24, part ONE is 8 rows x 3 ticks, so
            -- the scissor closes around c=48..53; hopping at c~18 puts his
            -- apex at c~37 and brings him back down through thigh height right
            -- as it fires.  Hop at c=30 instead and he is at the apex, 94px
            -- clear above the box, and correctly misses.
            -- Hop 8 frames earlier than the grounded case: against an
            -- airborne opponent do_sa_leggrab skips the two wind-up rows, so
            -- part ONE is 18 ticks not 24 and the scissor closes that much
            -- sooner.
            if p2_jumps and name == "P2 Up" then
                -- Sweep: each cycle hops 3 frames later than the last, so one
                -- run samples six points across the link window instead of
                -- testing a single lucky frame.
                local hop = 2 + 3 * math.floor(r / CYCLE)
                return c >= hop and c < hop + 6
            end
            -- Walk back into range between attempts.  The MK3-strength
            -- bounce throws the victim ~70px further than before and the
            -- throw itself crosses him over, so without this only the first
            -- cycle of a run is ever in reach and the rest whiff at dx>180.
            -- Close the gap from whichever side he is on.  The default
            -- "walk right" this used to always do fought the correction
            -- whenever the throw had crossed the victim over to the left,
            -- and the run then crawled 2px a cycle and whiffed on range
            -- while looking like a timing failure.
            if name == "P1 Right" then
                return dx_now > 60 and (c < 16 or c > 70)
            end
            if name == "P1 Left" then
                return dx_now < -60 and (c < 16 or c > 70)
            end
            if name == "P1 Down" then return c >= 14 and c < 34 end
            if name == "P1 Block" or name == "P1 Block 2" then return c >= 14 and c < 34 end
            if name == "P1 Low Punch" then return c >= 22 and c < 30 end
        end
    end
    return false
end

local function proc_action(procaddr)
    if procaddr == 0 then return 0xffff end
    return space:read_u16(procaddr + PROC_ACTION)
end

local function log_state(force)
    if not space then return end
    local gs = space:read_u16(GSTATE)
    local p1obj, p2obj = space:read_u32(P1_OBJ), space:read_u32(P2_OBJ)
    local p1act = proc_action(space:read_u32(P1_PROC))
    local p2act = proc_action(space:read_u32(P2_PROC))
    local p1x, p1y, p1sag = 0, 0, 0
    local p2x, p2y, p2sag, p2flags = 0, 0, 0, 0
    if p1obj ~= 0 then
        p1x = space:read_u16(p1obj + OBJ_OXPOS)
        p1y = s16(space:read_u16(p1obj + OBJ_OYPOS))
        local img = space:read_u32(p1obj + OBJ_OIMG)
        if img ~= 0 then p1sag = space:read_u32(img) end
    end
    if p2obj ~= 0 then
        p2x = space:read_u16(p2obj + OBJ_OXPOS)
        p2y = s16(space:read_u16(p2obj + OBJ_OYPOS))
        p2flags = space:read_u16(p2obj + OBJ_OFLAGS)
        local img = space:read_u32(p2obj + OBJ_OIMG)
        if img ~= 0 then p2sag = space:read_u32(img) end
    end
    local p1bar, p2bar = space:read_u16(P1_BAR), space:read_u16(P2_BAR)
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")

    if tail_frames > 0 then tail_frames = tail_frames - 1 end
    if gs == GS_PSEL and frame % 20 == 0 then
        print(string.format("[leggrab] select f=%d p1char=%d (want %d) p2char=%d (want %d)",
            frame, space:read_u16(P1_CHAR), FT_BARAKA, space:read_u16(P2_CHAR), FT_JAX))
    end
    local interesting = (p1act == ACT_SA_LEGGRAB) or (last_p1act == ACT_SA_LEGGRAB)
                        or tail_frames > 0
    if force or interesting or frame % 30 == 0 then
        print(string.format(
            "[leggrab] f=%d gs=%d p1act=0x%04x p2act=0x%04x p1=%d,%d p2=%d,%d dx=%d p1sag=0x%08x p2sag=0x%08x p2flags=0x%04x bar=%d/%d obj=%d/%d pc=%s",
            frame, gs, p1act, p2act, p1x, p1y, p2x, p2y, p2x - p1x, p1sag, p2sag,
            p2flags, p1bar, p2bar, count_list(OBJLST), count_list(OBJLST2), hx(pc)))
    end

    if p1act == ACT_SA_LEGGRAB and grab_start_frame > 0
       and frame - grab_start_frame <= 32 and p2y < 70 then
        caught_airborne = true          -- strike window only, not the throw arc
    end
    if p1act == ACT_SA_LEGGRAB and last_p2act ~= 0 and p2act == 0
       and grab_start_frame > 0 then
        print(string.format(
            "[leggrab] TAKEOVER frame=%d t=%d victim_rel_y=%+d dx=%d hop=%d",
            frame, frame - grab_start_frame, p2y - p1y, p2x - p1x, hop_offset))
    end
    last_p2act = p2act

    if p1act == ACT_SA_LEGGRAB and last_p1act ~= ACT_SA_LEGGRAB then
        hop_offset = 2 + 3 * math.floor((frame - fighting_frame) / CYCLE)
        caught_airborne = false
        grab_count = grab_count + 1
        grab_start_frame = frame
        p2_bar_at_grab = p2bar
        print(string.format("[leggrab] START #%d frame=%d dx=%d p2bar=%d",
            grab_count, frame, p2x - p1x, p2bar))
        snap("leggrab_start")
    end

    if (p1act == ACT_SA_LEGGRAB or last_p1act == ACT_SA_LEGGRAB) and grab_start_frame > 0 then
        local t = frame - grab_start_frame
        if t == 14 then snap("leggrab_plant") end
        if t == 22 then snap("leggrab_scissor") end
        if t == 34 then snap("leggrab_slam") end
        if p2_bar_at_grab and p2bar < p2_bar_at_grab then
            catch_count = catch_count + 1
            print(string.format("[leggrab] CAUGHT frame=%d t=%d p2bar %d -> %d p2act=0x%04x airborne_at_catch=%s",
                frame, t, p2_bar_at_grab, p2bar, p2act, tostring(caught_airborne)))
            snap("leggrab_caught")
            p2_bar_at_grab = p2bar
        end
    end

    if last_p1act == ACT_SA_LEGGRAB and p1act ~= ACT_SA_LEGGRAB and grab_start_frame > 0 then
        print(string.format("[leggrab] END frame=%d duration=%d p2act=0x%04x",
            frame, frame - grab_start_frame, p2act))
        grab_start_frame = 0
        tail_frames = 90          -- keep tracing his drop / bounce / get-up
        land_min_y = nil
        bounce_seen = false
    end
    -- the bounce: he touches down, then y goes back UP (smaller) again
    if tail_frames > 0 then
        if land_min_y == nil or p2y > land_min_y then land_min_y = p2y end
        if land_min_y and p2y < land_min_y - 2 and not bounce_seen then
            bounce_seen = true
            print(string.format("[leggrab] BOUNCE frame=%d y %d -> %d sag=0x%08x",
                frame, land_min_y, p2y, p2sag))
            snap("leggrab_bounce")
        end
    end
    last_p1act = p1act
end

local function check_cpu_lockup()
    if did_error or not space or fighting_frame == 0 then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    local pf = space:read_u32(PF_RAM)
    if pf == 0xffffffff or (pc and pc >= MKBUG_START and pc <= MKBUG_END) then
        did_error = true
        log_state(true)
        snap("mkbug_lockup")
        print(string.format("[leggrab] ERROR mkbug_lockup pc=%s pf=%s", hx(pc), hx(pf)))
        manager.machine:exit()
        return true
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print(string.format("[leggrab] loaded: P1 Baraka vs P2 Jax, Back,Back+LK (p2_blocks=%s force_miss=%s)",
            tostring(p2_blocks), tostring(force_miss)))
    end

    if space then
        if os.getenv("BARAKA_LEGGRAB_COLBOX") == "1" then space:write_u16(F_COLBOX, 1) end
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[leggrab] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                snap("fight_start")
            end
            last_gstate = gs
        end
        do
            local o1, o2 = space:read_u32(P1_OBJ), space:read_u32(P2_OBJ)
            if o1 ~= 0 and o2 ~= 0 then
                dx_now = space:read_u16(o2 + OBJ_OXPOS) - space:read_u16(o1 + OBJ_OXPOS)
            end
        end
        p1_char_now = space:read_u16(P1_CHAR)
        p2_char_now = space:read_u16(P2_CHAR)
        if charsel_frame > 0 and gs == GS_PSEL then
            if p1_confirm_start == 0 and space:read_u16(P1_CHAR) == FT_BARAKA then
                p1_confirm_start = frame
                print(string.format("[leggrab] p1 Baraka reached at frame=%d; confirming", frame))
            end
            if p2_confirm_start == 0 and space:read_u16(P2_CHAR) == FT_JAX then
                p2_confirm_start = frame
                print(string.format("[leggrab] p2 Jax reached at frame=%d; confirming", frame))
            end
        end
        if check_cpu_lockup() then return end
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    log_state(false)

    if fighting_frame > 0 and frame - fighting_frame > 1300 then
        log_state(true)
        snap("final")
        print(string.format("[leggrab] finished starts=%d catches=%d", grab_count, catch_count))
        manager.machine:exit()
    end
    if frame > 9000 then
        log_state(true)
        snap("timeout")
        print(string.format("[leggrab] timeout starts=%d catches=%d", grab_count, catch_count))
        manager.machine:exit()
    end
end)
