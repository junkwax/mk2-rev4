-- pit2_victim_palette_test.lua
--
-- THE PIT II (curback 6): does the victim keep his palette at the pit bottom?
--
-- switch_camera_angle (BGND.ASM) cuts to falling_down_the_pit (MKFALL.ASM),
-- which REBUILDS the victim with make_player_obj - as player 1, clean.  So a
-- player 2 in a mirror match (Start+HP lane), a costume pick or a bloodied
-- body all landed in player 1's default colours.  The fix carries the live
-- palette id (palram[map]) across the cut in p_store6 and swpal's it back.
--
-- Liu Kang vs Liu Kang: player 2 wears the mirror's lane, which is NOT the
-- palette a player-1 rebuild gives - so the old code fails this and the fixed
-- code passes.  The rig refuses a trial where the two would be the same.
--
-- Env: PP_TEST_LOG, PP_VX (400), PP_GAP (55), PP_SIDE (left|right).

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local function getenv_int(n, d) local r = os.getenv(n); return (r and r ~= "" and tonumber(r)) or d end

local LOG_PATH = os.getenv("PP_TEST_LOG") or (ROOT .. "/tools/pit2_victim_palette_test.log")
local VICTIM_X = getenv_int("PP_VX", 400)
local GAP = getenv_int("PP_GAP", 55)
local SIDE = (os.getenv("PP_SIDE") or "left"):lower()
local MAP = (os.getenv("PP_MAP") or (ROOT .. "/src/mk2.map")):gsub("\\", "/")

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local function log(fmt, ...)
    local line = "[pit2pal] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

local symbols = {}
do
    local fh = io.open(MAP, "r")
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
local function sym(name)
    local v = symbols[name]
    if v == nil then missing[#missing + 1] = name; return 0 end
    return v
end

local A = {
    gstate = sym("gstate"), p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    curback = sym("curback"), winner_status = sym("winner_status"),
    f_death = sym("f_death"), dizzy_dude = sym("dizzy_dude"), dizzy = sym("dizzy"),
    objlst = sym("objlst"), palram = sym("palram"), p2_ram = sym("p2_ram"),
    pals1 = sym("character_palettes_1"), alt_pal_owner = sym("alt_pal_owner"),
}
local O = { next = 0x000, oxval = 0x080, oxpos = 0x090, opal = 0x140, oimg = 0x1a0, ochar = 0x1f0 }
local P = { wake = 0x0e0, action = 0x1f0, flags = 0x210 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KANG = 1
local STAGE = 6
local ACT_PIT_FALL, ACT_STUNNED = 0x0506, 0x0400
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010

local space, fields = nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame, p1_confirm_start = 0, 0, 0
local finish_forced_frame, victim_dizzy_forced = 0, false
local attempt_start, attempt_n = 0, 0
local fall_start_frame = 0
local fall_pal, bottom_pal, bottom_seen = nil, nil, 0
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function snap(label)
    pcall(function() manager.machine.screens[":screen"]:snapshot() end)
    log("SNAP frame=%d label=%s", frame, label)
end

local function pal_id(obj)
    local map = r16(obj + O.opal) & 0xff
    return r32(A.palram + map * 0x40)
end

local function victim() return r32(A.p2_obj) end
local function attacker() return r32(A.p1_obj) end
local function p2_action()
    local p = r32(A.p2_proc); if p == 0 then return 0xffff end
    return r16(p + P.action)
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    snap(ok and "final_pass" or "final_fail")
    log("RESULT %s reason=%s fall_pal=%s bottom_pal=%s default_pal=%08x",
        ok and "PASS" or "FAIL", reason,
        fall_pal and string.format("%08x", fall_pal) or "nil",
        bottom_pal and string.format("%08x", bottom_pal) or "nil",
        r32(A.pals1 + FT_KANG * 32))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function force_select()
    w16(A.p1_char, FT_KANG)
    w16(A.p2_char, FT_KANG)
    w16(A.curback, STAGE)
    w16(A.p1_state, 1)
    w16(A.p2_state, 1)
end

local function fighters_ok()
    local a, v = attacker(), victim()
    return a ~= 0 and v ~= 0 and r16(a + O.ochar) == FT_KANG and r16(v + O.ochar) == FT_KANG
end

local function force_finish_him()
    if fall_start_frame ~= 0 or not fighters_ok() then return end
    local rel = frame - fighting_frame
    if rel < 400 or rel > 2400 then return end
    w16(A.winner_status, 3)
    w16(A.f_death, 0)
    local p1p = r32(A.p1_proc)
    if p1p ~= 0 then w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL)) end
    local p2p = r32(A.p2_proc)
    if p2p ~= 0 and not victim_dizzy_forced then
        w32(p2p + P.wake, A.dizzy_dude)
        victim_dizzy_forced = true
    end
    if finish_forced_frame == 0 then
        finish_forced_frame = frame
        log("finish_him frame=%d", frame)
    end
end

local function victim_ready()
    local p = r32(A.p2_proc)
    if p == 0 then return false end
    local wake = r32(p + P.wake)
    return wake >= A.dizzy and wake < (A.dizzy + 0x120) and r16(p + P.action) == ACT_STUNNED
end

local function pin()
    local a, v = attacker(), victim()
    if a == 0 or v == 0 then return end
    local ax = SIDE == "left" and (VICTIM_X - GAP) or (VICTIM_X + GAP)
    w16(v + O.oxpos, VICTIM_X); w32(v + O.oxval, (VICTIM_X << 16) & 0xffffffff)
    w16(a + O.oxpos, ax);       w32(a + O.oxval, (ax << 16) & 0xffffffff)
end

-- Liu Kang's pit: Back, Forward, Forward + Low Kick (scom_lk_dtp)
local ATTEMPT_LEN = 80
local BACK = SIDE == "left" and "P1 Left" or "P1 Right"
local FWD = SIDE == "left" and "P1 Right" or "P1 Left"
local function press_for(name, rel)
    if name == BACK then return rel >= 0 and rel < 5 end
    if name == FWD then return (rel >= 9 and rel < 14) or (rel >= 18 and rel < 23) end
    if name == "P1 Low Kick" then return rel >= 26 and rel < 32 end
    return false
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
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start > 0 then
        if name == "P1 High Punch" then return frame >= p1_confirm_start and frame < p1_confirm_start + 40 end
        if name == "P2 High Punch" then return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120 end
    end
    if attempt_start > 0 and fall_start_frame == 0 and fighting_frame > 0 then
        return press_for(name, (frame - attempt_start) % ATTEMPT_LEN)
    end
    return false
end

-- the rebuilt body at the pit bottom: on objlst, Liu Kang, oimg = the ram
-- block falling_down_the_pit picked for the victim's oid (p2_ram here)
local function find_bottom_body()
    local o, n = r32(A.objlst), 0
    while o ~= 0 and n < 200 do
        if r16(o + O.ochar) == FT_KANG and r32(o + O.oimg) == A.p2_ram then return o end
        o = r32(o + O.next); n = n + 1
    end
    return nil
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        if #missing > 0 then finish(false, "missing_symbols_" .. table.concat(missing, ",")); return end
        local wanted = { "Coin 1", "Coin 2", "2 Players Start", "P1 High Punch", "P2 High Punch",
                         "P1 Low Kick", "P1 Left", "P1 Right" }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do fields[f.name] = fields[f.name] or f end
        end
        for _, n in ipairs(wanted) do if not fields[n] then finish(false, "input_missing_" .. n); return end end
        local keep = {}
        for _, n in ipairs(wanted) do keep[n] = fields[n] end
        fields = keep
        log("trial vx=%d side=%s gap=%d map=%s", VICTIM_X, SIDE, GAP, MAP)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight_start frame=%d", frame)
        end
        log("gstate frame=%d %d->%d", frame, last_gstate, gs)
        last_gstate = gs
    end

    if fighting_frame == 0 then force_select() end
    if charsel_frame > 0 and fighting_frame == 0 and p1_confirm_start == 0 and frame > charsel_frame + 90 then
        p1_confirm_start = frame + 25
    end

    if fighting_frame > 0 and fall_start_frame == 0 then
        if r16(A.curback) ~= STAGE then finish(false, "wrong_stage"); return end
        force_finish_him()
        if finish_forced_frame > 0 then pin() end
        if attempt_start == 0 and finish_forced_frame > 0 and victim_ready()
            and frame >= finish_forced_frame + 120 then
            attempt_start = frame + 10
            local v = victim()
            log("victim_ready frame=%d victim_pal=%08x attacker_pal=%08x alt_pal_owner=%04x",
                frame, pal_id(v), pal_id(attacker()), r16(A.alt_pal_owner))
            snap("before_fatality")
        end
        if attempt_start > 0 and frame >= attempt_start and (frame - attempt_start) % ATTEMPT_LEN == 0 then
            attempt_n = attempt_n + 1
            if attempt_n > 8 then finish(false, "fatality_never_fired"); return end
        end
        if p2_action() == ACT_PIT_FALL then
            fall_start_frame = frame
            log("PIT_FALL frame=%d", frame)
        end
    end

    if fall_start_frame > 0 then
        local rel = frame - fall_start_frame
        -- the cut comes 070h ticks into pit_scroll; read him well before it
        if rel == 40 then
            local v = victim()
            if v ~= 0 then fall_pal = pal_id(v) end
            log("FALL_PAL rel=40 pal=%s", fall_pal and string.format("%08x", fall_pal) or "nil")
            snap("falling_top")
        end
        if rel > 160 then
            local b = find_bottom_body()
            if b then
                bottom_seen = bottom_seen + 1
                bottom_pal = pal_id(b)
                if bottom_seen == 1 then log("BOTTOM frame=%d rel=%d body=%08x pal=%08x", frame, rel, b, bottom_pal) end
                if bottom_seen == 30 then snap("pit_bottom_falling") end
                if bottom_seen >= 60 then
                    local default = r32(A.pals1 + FT_KANG * 32)
                    if not fall_pal then finish(false, "no_fall_palette"); return end
                    if fall_pal == default then finish(false, "no_verdict_victim_on_p1_default"); return end
                    if bottom_pal == fall_pal then finish(true, "palette_kept")
                    else finish(false, "palette_changed") end
                    return
                end
            end
        end
        if rel > 900 then finish(false, "never_saw_pit_bottom"); return end
    end

    for name, field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end

    if fighting_frame == 0 and frame > 9000 then finish(false, "never_reached_fight")
    elseif frame > 20000 then finish(false, "global_timeout") end
end)

emu.register_stop(function()
    if logfh then logfh:flush(); logfh:close(); logfh = nil end
end)
