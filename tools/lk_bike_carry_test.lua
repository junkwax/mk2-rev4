-- lk_bike_carry_test.lua
-- Liu Kang bicycle kick: does the kick CARRY the victim?
--
-- Retail behaviour: on contact, do_bicycle (MKPROP.ASM) takes the victim over
-- into biked_suspend and asks for away_x_vel_him 050000h, so Kang plows the
-- victim backwards for the whole 48-tick punching-bag loop.
--
-- Failure mode this rig exists for: with deferhit on, react_xfer_him only
-- RECORDS the reaction and apply_pending_hits applies it at the end of the
-- tick, yanking the victim out of the takeover into r_lk_bike -> reaction_exit
-- -> stop_me, so the victim stands still.
--
-- PASS = the victim's x travel over the loop is large (retail is tens of px).

local OUT = "C:/Users/you/Workplace/mk2-main/tools/lk_bike_carry_test.log"
local logfh = io.open(OUT, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts+1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local GSTATE  = 0x010f2c70
local P1_CHAR = 0x010f2d20
local P1_OBJ  = 0x010f2cc0
local P2_OBJ  = 0x010f3890
local P1_PROC = 0x010f2d00
local P2_PROC = 0x010f38d0
local P2_BAR  = 0x010f3960
local P2_XVEL = 0x010f3940
local P2_PEND = 0x010f5590

local OBJ_OXVEL = 0x040
local OBJ_OXPOS = 0x090

local P_ACTION = 0x1f0
local P_HITBY  = 0x360

local GS_PSEL     = 4
local GS_POST     = 0x0d
local GS_FIGHTING = 2
local FT_LIUKANG  = 1
local ACT_BIKE    = 0x0204

local frame = 0
local fields = {}
local cpu, space
local charsel_frame, vs_frame, fighting_frame = 0, 0, 0
local p1_confirm_start = 0
local last_gstate = -1

local hit_frame = nil
local p2x_at_hit = nil
local p2x_min, p2x_max = nil, nil
local saw_bike = false
local broke_takeover = nil
local pend_seen = 0
local p2_bar_start = nil
local done = false

local function cache_fields()
    local wanted = {
        ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
        ["1 Player Start"]=true, ["2 Players Start"]=true,
        ["P1 High Punch"]=true, ["P1 Low Kick"]=true, ["P2 High Punch"]=true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        print(string.format("[bike] input %-18s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot() end) end
    print(string.format("[bike] SNAP frame=%d label=%s", frame, label))
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" or name == "Coin 2" then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end

    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        -- Hold LK from r=90 to r=280 (well past the 0x80-tick charge), release.
        if name == "P1 Low Kick" then return r >= 90 and r < 280 end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print("[bike] loaded: P1 Liu Kang, charge LK, release -> bicycle kick")
    end
    if not space then return end

    local gs = space:read_u16(GSTATE)
    if gs ~= last_gstate then
        print(string.format("[bike] frame=%d gstate %d -> %d", frame, last_gstate, gs))
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_POST and vs_frame == 0 then vs_frame = frame end
        if gs == GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            p2_bar_start = space:read_u16(P2_BAR)
            print(string.format("[bike] fight start frame=%d p2bar=%d", frame, p2_bar_start))
        end
        last_gstate = gs
    end

    if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 70 then
        if space:read_u16(P1_CHAR) == FT_LIUKANG then
            p1_confirm_start = frame + 25
            print(string.format("[bike] P1 Liu Kang selected; confirm at %d", p1_confirm_start))
        end
    end

    if fighting_frame > 0 then
        local p1proc = space:read_u32(P1_PROC)
        local p2proc = space:read_u32(P2_PROC)
        local p1obj  = space:read_u32(P1_OBJ)
        local p2obj  = space:read_u32(P2_OBJ)
        local p1act  = p1proc ~= 0 and space:read_u16(p1proc + P_ACTION) or 0xffff
        local p2act  = p2proc ~= 0 and space:read_u16(p2proc + P_ACTION) or 0xffff
        local p2hitby= p2proc ~= 0 and space:read_u16(p2proc + P_HITBY) or 0xffff
        local p1x    = p1obj ~= 0 and space:read_u16(p1obj + OBJ_OXPOS) or 0
        local p2x    = p2obj ~= 0 and space:read_u16(p2obj + OBJ_OXPOS) or 0
        local p2xv   = p2obj ~= 0 and space:read_u32(p2obj + OBJ_OXVEL) or 0
        local p2req  = space:read_u32(P2_XVEL)
        local pend   = space:read_u32(P2_PEND)
        local p2bar  = space:read_u16(P2_BAR)

        if pend ~= 0 then pend_seen = pend_seen + 1 end

        if p1act == ACT_BIKE and not saw_bike then
            saw_bike = true
            print(string.format("[bike] act_bike engaged frame=%d p1x=%d p2x=%d", frame, p1x, p2x))
        end

        -- Contact = P2's health first drops while Kang is in act_bike.
        if hit_frame == nil and p2_bar_start and p2bar < p2_bar_start and p1act == ACT_BIKE then
            hit_frame = frame
            p2x_at_hit = p2x
            p2x_min, p2x_max = p2x, p2x
            print(string.format("[bike] CONTACT frame=%d p2x=%d p2bar=%d", frame, p2x, p2bar))
            snap("bike_contact")
        end

        -- takeover_him clears the victim's p_action; anything else means he
        -- was pulled back out of biked_suspend while Kang is still kicking.
        if hit_frame and broke_takeover == nil and p1act == ACT_BIKE and p2act ~= 0 then
            broke_takeover = frame - hit_frame
        end

        if hit_frame then
            if p2x < p2x_min then p2x_min = p2x end
            if p2x > p2x_max then p2x_max = p2x end
            local r = frame - hit_frame
            if r <= 60 then
                print(string.format(
                    "[bike] +%02d p1act=0x%04x p2act=0x%04x p2hitby=0x%04x p1x=%d p2x=%d dx=%d p2oxvel=0x%08x p2req=0x%08x pend=0x%08x bar=%d",
                    r, p1act, p2act, p2hitby, p1x, p2x, p2x - p2x_at_hit, p2xv, p2req, pend, p2bar))
            end
            if r == 60 and not done then
                done = true
                local travel = p2x_max - p2x_min
                print(string.format("[bike] RESULT victim travel=%d px (from %d, min %d max %d) pend_frames=%d",
                    travel, p2x_at_hit, p2x_min, p2x_max, pend_seen))
                if broke_takeover then
                    print(string.format(
                        "[bike] FAIL - victim left biked_suspend at +%d (p_action went non-zero mid-kick)",
                        broke_takeover))
                elseif travel < 120 then
                    print(string.format("[bike] FAIL - victim only travelled %d px", travel))
                else
                    print("[bike] PASS - the kick carries the victim")
                end
                snap("bike_end")
                manager.machine:exit()
            end
        elseif frame % 30 == 0 then
            print(string.format("[bike] frame=%d r=%d p1act=0x%04x p1x=%d p2x=%d bar=%d",
                frame, frame - fighting_frame, p1act, p1x, p2x, p2bar))
        end
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    if fighting_frame > 0 and frame > fighting_frame + 600 and not done then
        print(string.format("[bike] TIMEOUT saw_bike=%s hit=%s", tostring(saw_bike), tostring(hit_frame)))
        snap("timeout")
        manager.machine:exit()
    end
end)
