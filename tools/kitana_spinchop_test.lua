-- kitana_spinchop_test.lua
-- Drives a 2P match, selects P1 Kitana, performs hold-Block + Forward, Forward, and
-- verifies the KITSPIN overhead spin chop: act_fnspinchop fires, the
-- KTSPINCHOP frames render from the 0x3D00000 sidecar, and P2 takes damage.

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/kitana_spinchop_test.log", "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then
        logfh:write(line, "\n")
        logfh:flush()
    end
end

local fields = {}
local cpu = nil
local space = nil
local charsel_frame = 0
local vs_frame = 0
local fighting_frame = 0
local p1_confirm_start = 0
local last_gstate = -1
local did_move_snap = false
local did_hit_snap = false
local did_error = false
local move_fired = false
local chop_sag_frames = 0
local p2_bar_start = nil
local p2_bar_low = nil

-- Addresses out of src/MK2.MAP.  .bss SHIFTS ON EVERY BUILD that changes the
-- size of anything ahead of it, so these go stale silently: a dead GSTATE
-- reads a constant 0 and the rig logs gs=0 / p1objchar=65535 for its whole
-- backstop, which looks exactly like the move failing.  Re-resolve with
--   python sym_resolve.py --dump | grep -iwE 'gstate|p1_obj|objlst'
-- Refreshed 2026-10-04.
local GSTATE   = 0x0110a520
local P1_CHAR  = 0x0110a5d0
local P2_CHAR  = 0x0110b1a0
local P1_OBJ   = 0x0110a570
local P2_OBJ   = 0x0110b140
local P1_PROC  = 0x0110a5b0
local P2_BAR   = 0x0110b210
local OBJLST   = 0x011042f0
local OBJLST2  = 0x01104310

local PROC_ACTION = 0x1f0

local OBJ_NEXT    = 0x000
local OBJ_OXPOS   = 0x090
local OBJ_OYPOS   = 0x0b0
local OBJ_OFLAGS  = 0x0f0
local OBJ_OFLAGS2 = 0x160
local OBJ_OIMG    = 0x1a0
local OBJ_OCHAR   = 0x1f0

local GS_PSEL     = 4
local GS_POST     = 0x0d
local GS_FIGHTING = 2
local FT_FN1      = 4        -- Kitana
local ACT_FNSPINCHOP = 0x0111
-- KITSPIN.IRW sidecar SAG window (flat 0x7A0000..0x7B0000 * 8)
-- The sidecar's SAGs MOVE on every build that repacks KITSPIN, so this window
-- is handed in by run_kitana_spinchop_test.ps1, which reads it out of
-- src/KITSPIN.TBL each run.  Hardcoded it went stale and reported
-- sag_frames=0 while the move was firing perfectly - a frame check that can
-- only ever say "no" is worse than none, because it reads as the art missing.
local KITSPIN_SAG_LO = tonumber(os.getenv("KITSPIN_SAG_LO") or "") or 0x03af0000
local KITSPIN_SAG_HI = tonumber(os.getenv("KITSPIN_SAG_HI") or "") or 0x03b30000
print(string.format("[kitspin] KITSPIN SAG window 0x%08x..0x%08x", KITSPIN_SAG_LO, KITSPIN_SAG_HI))
local MKBUG_START = 0xffa30000
local MKBUG_END   = 0xffa36000

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 Down"] = true,
        ["P1 Right"] = true,
        ["P1 Up"] = true,
        ["P1 Block"] = true,
        ["P1 High Punch"] = true,
        ["P1 Low Kick"] = true,
        ["P2 High Punch"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then
                fields[field.name] = field
            end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[kitspin] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
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
    local s = main_screen()
    if s then
        local ok, err = pcall(function() s:snapshot() end)
        print(string.format("[kitspin] SNAP frame=%d label=%s ok=%s %s",
            frame, label, tostring(ok), ok and "" or tostring(err)))
    end
end

local function cpu_reg(name)
    if not cpu then return nil end
    local ok, item = pcall(function() return cpu.state[name] end)
    if not ok or not item then return nil end
    local okv, value = pcall(function() return item.value end)
    if okv then return value end
    okv, value = pcall(function() return item() end)
    if okv then return value end
    return nil
end

local function hx(value)
    if value == nil then return "na" end
    return string.format("0x%08x", value)
end

local function count_list(addr)
    if not space then return 0 end
    local p = space:read_u32(addr)
    local count = 0
    while p ~= 0 and count < 256 do
        count = count + 1
        p = space:read_u32(p + OBJ_NEXT)
    end
    return count
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end

    -- Coin-mode path only; a free-play build opens the select screen on its
    -- own (charsel_frame set) and these must then stay quiet.
    if name == "Coin 1" or name == "Coin 2" then
        return charsel_frame == 0 and frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then
        return charsel_frame == 0 and frame >= 1000 and frame < 1080
    end
    if name == "2 Players Start" then
        -- Free play: join P2 as soon as the select screen opens, so the
        -- opponent is an idle human instead of an attacking drone.
        if charsel_frame > 0 and fighting_frame == 0 then
            local r = frame - charsel_frame
            return r >= 5 and r < 45
        end
        return charsel_frame == 0 and frame >= 1040 and frame < 1140
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        local r = frame - charsel_frame

        -- P1: Liu Kang -> Kitana on the 4x3 grid: Down, Right, Right.
        if name == "P1 Down" then
            return r >= 80 and r < 88
        end
        if name == "P1 Right" then
            return (r >= 100 and r < 108) or (r >= 120 and r < 128)
        end
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end

        -- P2 confirms default Reptile.
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end

        -- Stage select confirm.
        if name == "P1 Low Kick" and vs_frame > 0 then
            return frame >= vs_frame + 260 and frame < vs_frame + 305
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        local cycle = r % 130
        if r > 80 and r < 800 then
            -- Walk in first, then hold Block and double-tap Forward.
            -- P1 starts on the left, so Forward = Right here.
            if name == "P1 Right" then
                return (cycle >= 0 and cycle < 30)
                    or (cycle >= 44 and cycle < 48)
                    or (cycle >= 58 and cycle < 62)
            end
            if name == "P1 Block" then
                return cycle >= 36 and cycle < 92
            end
        end
    end

    return false
end

local function log_state(force)
    if not space then return end

    local gs = space:read_u16(GSTATE)
    local p1proc = space:read_u32(P1_PROC)
    local p1act = p1proc ~= 0 and space:read_u16(p1proc + PROC_ACTION) or 0xffff
    local p1obj = space:read_u32(P1_OBJ)
    local p1sag = 0
    if p1obj ~= 0 then
        local p1img = space:read_u32(p1obj + OBJ_OIMG)
        if p1img ~= 0 then p1sag = space:read_u32(p1img) end
    end
    local p2bar = space:read_u16(P2_BAR)

    -- Per-frame checks (log is throttled below).
    if p1act == ACT_FNSPINCHOP then
        if not move_fired then
            move_fired = true
            print(string.format("[kitspin] frame=%d act_fnspinchop ACTIVE", frame))
        end
        if p1sag >= KITSPIN_SAG_LO and p1sag < KITSPIN_SAG_HI then
            chop_sag_frames = chop_sag_frames + 1
            if not did_move_snap then
                did_move_snap = true
                snap("spinchop_action")
            end
        end
    end
    if p2_bar_start and p2bar < p2_bar_start and not did_hit_snap then
        did_hit_snap = true
        p2_bar_low = p2bar
        snap("spinchop_hit")
        print(string.format("[kitspin] hit detected p2bar %d -> %d", p2_bar_start, p2bar))
    end

    if not force and frame % 20 ~= 0 then return end

    local p1c = space:read_u16(P1_CHAR)
    local p2c = space:read_u16(P2_CHAR)
    local p2obj = space:read_u32(P2_OBJ)
    local p1x, p1y, p1flags, p1flags2, p1ochar = 0, 0, 0, 0, 0xffff
    local p2x, p2y, p2ochar = 0, 0, 0xffff
    if p1obj ~= 0 then
        p1x = space:read_u16(p1obj + OBJ_OXPOS)
        p1y = space:read_u16(p1obj + OBJ_OYPOS)
        p1flags = space:read_u16(p1obj + OBJ_OFLAGS)
        p1flags2 = space:read_u16(p1obj + OBJ_OFLAGS2)
        p1ochar = space:read_u16(p1obj + OBJ_OCHAR)
    end
    if p2obj ~= 0 then
        p2x = space:read_u16(p2obj + OBJ_OXPOS)
        p2y = space:read_u16(p2obj + OBJ_OYPOS)
        p2ochar = space:read_u16(p2obj + OBJ_OCHAR)
    end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")

    print(string.format(
        "[kitspin] frame=%d gs=%d p1=%d p2=%d p1objchar=%d p2objchar=%d act=0x%04x p1xy=%d,%d p2xy=%d,%d flags=0x%04x flags2=0x%04x sag=0x%08x p2bar=%d obj=%d obj2=%d pc=%s",
        frame, gs, p1c, p2c, p1ochar, p2ochar, p1act, p1x, p1y, p2x, p2y,
        p1flags, p1flags2, p1sag, p2bar, count_list(OBJLST), count_list(OBJLST2),
        hx(pc)))
end

local function check_cpu_lockup()
    if did_error or not space or fighting_frame == 0 then return false end
    local pc = cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
    if pc and pc >= MKBUG_START and pc <= MKBUG_END then
        did_error = true
        log_state(true)
        snap("mkbug_lockup")
        print(string.format("[kitspin] ERROR mkbug_lockup pc=%s", hx(pc)))
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
        print("[kitspin] loaded: selecting P1 Kitana, then hold Block + Forward, Forward")
    end

    if space then
        local gs = space:read_u16(GSTATE)
        if gs ~= last_gstate then
            print(string.format("[kitspin] frame=%d gstate %d -> %d", frame, last_gstate, gs))
            if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
            if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
            if gs == GS_FIGHTING and fighting_frame == 0 then
                fighting_frame = frame
                p2_bar_start = space:read_u16(P2_BAR)
                snap("fight_start")
            end
            last_gstate = gs
        end

        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 150 then
            local p1c = space:read_u16(P1_CHAR)
            if p1c == FT_FN1 then
                p1_confirm_start = frame + 35
                print(string.format("[kitspin] P1 Kitana selected; confirm starts at %d", p1_confirm_start))
            end
        end

        log_state(false)
        if check_cpu_lockup() then return end
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    if fighting_frame > 0 and frame > fighting_frame + 900 then
        log_state(true)
        snap("final")
        if move_fired and chop_sag_frames > 0 and did_hit_snap then
            print(string.format("[kitspin] PASS move_fired=%s sag_frames=%d p2bar %d -> %d",
                tostring(move_fired), chop_sag_frames, p2_bar_start or -1, p2_bar_low or -1))
        else
            print(string.format("[kitspin] ERROR move_fired=%s sag_frames=%d hit=%s",
                tostring(move_fired), chop_sag_frames, tostring(did_hit_snap)))
        end
        print("[kitspin] finished")
        manager.machine:exit()
    end
end)
