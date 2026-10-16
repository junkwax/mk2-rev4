-- sz_freeze_thaw_test.lua
--
-- A victim in Sub-Zero's deep freeze (r_super_freeze -> super_frozen, MKDEATH)
-- wears FREEZE_P.  The shatter is meant to keep it; ANY OTHER fatality that
-- lands on him must put him back on his own palette.  Reported case: Shang
-- freezes as Sub-Zero, becomes Kitana, fan-decaps - and the palette is still
-- the freeze's.  Both fighters' palettes are watched.
--
-- Modes (SZFT_MODE):
--   shang_revert    the path a HUMAN Shang takes: morph to Sub-Zero, freeze,
--                   back_to_shang_form (Block+Up+HK / the timer), morph to
--                   Kitana, do_fan_decap.  The st_* morph inputs only run while
--                   he is Shang, so a player cannot go form -> form directly.
--   shang           form -> form: Sub-Zero straight to Kitana.  Only the CPU
--                   Shang does this (shang_morph accepts any pick).
--   decap           P1 Kitana.  Victim frozen (his wake -> r_super_freeze),
--                   then do_fan_decap.
--   decap_nofreeze  control: the same decap on a plain dizzy victim.
--   shatter         P1 Sub-Zero: do_super_freeze, then do_shatter_punch.  The
--                   shatter must still take a frozen victim, IN FREEZE_P.
--
-- Local labels (do_fan_decap, do_st_2_sz, do_st_2_fn1) come in as env vars;
-- the launcher finds them in the built ROM.  Scripted buttons do not reach the
-- move dispatch in this MAME build, so moves are entered the way airborn_xfer
-- (MOVES.ASM) does it: fastxfer (ptime=1, stack reset, wake) plus
-- reaction_exit pushed as the return address - shang_morph ends in retp.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local function envint(n, d) local v = os.getenv(n); return (v and v ~= "") and (tonumber(v) or d) or d end
local function envhex(n) return tonumber(os.getenv(n) or "", 16) end

local LOG_PATH = os.getenv("SZFT_LOG") or (ROOT .. "/tools/sz_freeze_thaw_test.log")
local MODE = (os.getenv("SZFT_MODE") or "shang_revert"):lower()
local VICTIM = envint("SZFT_VICTIM", 11)      -- ochar; 11 = Jax
local STAGE_ID = envint("SZFT_STAGE", 5)
local FAN_DECAP, ST_2_SZ, ST_2_FN1 = envhex("SZFT_FAN_DECAP"), envhex("SZFT_ST_2_SZ"), envhex("SZFT_ST_2_FN1")
local FT_KITANA, FT_ST, FT_SUBZERO = 4, 6, 8
local SHANG = (MODE == "shang" or MODE == "shang_revert")
local P1_CHAR = SHANG and FT_ST or (MODE == "shatter" and FT_SUBZERO or FT_KITANA)
local FREEZE_RANGE, DECAP_RANGE = 144, 70

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local function log(fmt, ...)
    local msg = "[szft] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt))
    print(msg)
    if logfh then logfh:write(msg, "\n"); logfh:flush() end
end
local function hx(v) return v and string.format("0x%08x", v & 0xffffffff) or "na" end

local symbols, names = {}, {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                local v = tonumber(addr, 16)
                symbols[name] = v
                if name:match("_P$") or name:match("_p$") then names[v] = name end
            end
        end
        fh:close()
    end
end
local function pname(v) return v and (names[v] or hx(v)) or "na" end
local missing = {}
local function sym(n) local v = symbols[n]; if not v then missing[#missing + 1] = n end; return v or 0 end

local A = {
    gstate = sym("gstate"), p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    curback = sym("curback"), winner_status = sym("winner_status"), f_death = sym("f_death"),
    palram = sym("palram"), FREEZE_P = sym("FREEZE_P"), KATBLU_P = sym("KATBLU_P"),
    do_super_freeze = sym("do_super_freeze"), do_shatter_punch = sym("do_shatter_punch"),
    r_super_freeze = sym("r_super_freeze"), reaction_exit = sym("reaction_exit"),
    back_to_shang_form = sym("back_to_shang_form"),
    super_frozen = sym("super_frozen"), dizzy_dude = sym("dizzy_dude"), dizzy = sym("dizzy"),
    system_lockup = sym("system_lockup"), tvbp = sym("TVBP"),
}

local O = { oxval = 0x080, oxpos = 0x090, opal = 0x140, ochar = 0x1f0 }
local P = { ptime = 0x030, psptr = 0x040, wake = 0x0e0, action = 0x1f0, flags = 0x210, prcsiz = 0x6f0 }
local PALRSIZ, PALCNT, NMFPAL = 0x40, 0x20, 35
local PM_REACTING, PM_SITDUCK, PM_SPECIAL = 0x0004, 0x0008, 0x0010
local ACT_STUNNED = 0x0400
local GS_PSEL, GS_FIGHTING, PS_ACTIVE = 4, 2, 1

local cpu, space
local fields = {}
local charsel_frame, fighting_frame, fight_count, last_gstate = 0, 0, 0, -1
local p1_confirm_start = 0
local dizzy_forced = false
local step, step_frame = "wait_dizzy", 0
local frozen_pal, p1_fatal_pal = nil, nil
local fatal_frame, fdeath_seen = 0, false
local last_pal, last_p1_pal, pal_changes = nil, nil, {}
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end

local function pal_of(objsym)
    local obj = r32(objsym)
    if obj == 0 then return nil, nil end
    local slot = r16(obj + O.opal) & 0xff
    return r32(A.palram + slot * PALRSIZ), slot
end
local function free_fg_slots()
    local n = 0
    for s = 1, NMFPAL - 1 do
        if r16(A.palram + s * PALRSIZ + PALCNT) == 0 then n = n + 1 end
    end
    return n
end
local function wake_of(procsym) local p = r32(procsym); return p ~= 0 and r32(p + P.wake) or 0 end
local function p1_ochar() local o = r32(A.p1_obj); return o ~= 0 and r16(o + O.ochar) or -1 end

-- fastxfer + airborn_xfer's "return address = reaction_exit".
local function xfer_p1(target, label)
    local p = r32(A.p1_proc)
    w16(p + P.flags, r16(p + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
    w16(p + P.ptime, 1)
    local sp = p + P.prcsiz - 32
    w32(sp, A.reaction_exit)
    w32(p + P.psptr, sp)
    w32(p + P.wake, target)
    log("P1 -> %s frame=%d p1_ochar=%d p1_pal=%s victim_pal=%s free_fg=%d",
        label, frame, p1_ochar(), pname(pal_of(A.p1_obj)), pname(pal_of(A.p2_obj)), free_fg_slots())
end

local function snap_x(dist)
    local p1, p2 = r32(A.p1_obj), r32(A.p2_obj)
    if p1 == 0 or p2 == 0 then return end
    local x = r16(p2 + O.oxpos) - dist
    w16(p1 + O.oxpos, x); w32(p1 + O.oxval, (x << 16) & 0xffffffff)
end

local function snapshot(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot() end) end
    log("SNAP frame=%d %s", frame, label)
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    local id, slot = pal_of(A.p2_obj)
    log("%s mode=%s reason=%s victim: frozen=%s now=%s@%s | shang at decap=%s | free_fg=%d | changes=%s",
        ok and "PASS" or "FAIL", MODE, reason, pname(frozen_pal), pname(id), tostring(slot),
        pname(p1_fatal_pal), free_fg_slots(), table.concat(pal_changes, " "))
    snapshot(ok and "pass_final" or "fail_final")
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function go(next_step) step, step_frame = next_step, frame end

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
    return false
end

local function cpu_pc()
    for _, n in ipairs({ "PC", "CURPC" }) do
        local ok, item = pcall(function() return cpu.state[n] end)
        if ok and item then return item.value end
    end
end

local function start_fatal(target, label)
    fatal_frame = frame
    p1_fatal_pal = pal_of(A.p1_obj)
    snap_x(MODE == "shatter" and FREEZE_RANGE or DECAP_RANGE)
    xfer_p1(target, label)
    go("fatal")
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do fields[f.name] = f end
        end
        if #missing > 0 then finish(false, "unresolved_symbols_" .. table.concat(missing, ",")); return end
        if MODE ~= "shatter" and not FAN_DECAP then finish(false, "SZFT_FAN_DECAP_not_set"); return end
        if SHANG and not (ST_2_SZ and ST_2_FN1) then finish(false, "SZFT_ST_2_not_set"); return end
        log("mode=%s p1=%d victim=%d stage=%d", MODE, P1_CHAR, VICTIM, STAGE_ID)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING then
            fight_count = fight_count + 1; fighting_frame = frame
            log("fight_start frame=%d", frame)
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then
        w16(A.p1_char, P1_CHAR); w16(A.p2_char, VICTIM); w16(A.curback, STAGE_ID)
        w16(A.p1_state, PS_ACTIVE); w16(A.p2_state, PS_ACTIVE)
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90 then
            p1_confirm_start = frame + 25
        end
    end

    -- FINISH HIM on a dizzy victim.
    if fight_count == 1 and not dizzy_forced and frame - fighting_frame >= 120 then
        local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
        if p1o ~= 0 and p2o ~= 0 and r16(p1o + O.ochar) == P1_CHAR and r16(p2o + O.ochar) == VICTIM then
            w16(A.winner_status, 3); w16(A.f_death, 0)
            local p1p = r32(A.p1_proc)
            w16(p1p + P.flags, r16(p1p + P.flags) & ~(PM_REACTING | PM_SITDUCK | PM_SPECIAL))
            snap_x(FREEZE_RANGE)
            w32(r32(A.p2_proc) + P.wake, A.dizzy_dude)
            dizzy_forced = true
            log("finish_him_forced frame=%d", frame)
        end
    end

    local victim_wake = wake_of(A.p2_proc)
    local since = frame - step_frame

    -- Shang's palette, every time it moves.
    if SHANG then
        local p1pal = pal_of(A.p1_obj)
        if p1pal ~= last_p1_pal then
            log("shang pal %s ochar=%d frame=%d step=%s", pname(p1pal), p1_ochar(), frame, step)
            last_p1_pal = p1pal
        end
    end

    if step == "wait_dizzy" and dizzy_forced then
        local p2p = r32(A.p2_proc)
        if victim_wake >= A.dizzy and victim_wake < A.dizzy + 0x120 and r16(p2p + P.action) == ACT_STUNNED then
            log("victim_dizzy frame=%d pal=%s", frame, pname(pal_of(A.p2_obj)))
            go("dizzy")
        end

    elseif step == "dizzy" and since >= 30 then
        if SHANG then
            xfer_p1(ST_2_SZ, "do_st_2_sz"); go("morph_sz")
        elseif MODE == "shatter" then
            snap_x(FREEZE_RANGE); xfer_p1(A.do_super_freeze, "do_super_freeze"); go("freezing")
        elseif MODE == "decap" then
            w32(r32(A.p2_proc) + P.wake, A.r_super_freeze)
            log("victim -> r_super_freeze frame=%d", frame); go("freezing")
        else
            log("control: no freeze"); go("frozen")
        end

    elseif step == "morph_sz" then
        if p1_ochar() == FT_SUBZERO and since >= 90 then
            snap_x(FREEZE_RANGE); xfer_p1(A.do_super_freeze, "do_super_freeze"); go("freezing")
        elseif since > 400 then finish(false, "morph_to_subzero_failed_ochar_" .. p1_ochar()); return end

    elseif step == "freezing" then
        if victim_wake == A.super_frozen then
            frozen_pal = pal_of(A.p2_obj)
            log("victim super_frozen frame=%d pal=%s", frame, pname(frozen_pal))
            snapshot("frozen")
            if frozen_pal ~= A.FREEZE_P then finish(false, "not_in_FREEZE_P_when_frozen"); return end
            go("frozen")
        elseif since > 400 then finish(false, "freeze_never_landed"); return end

    elseif step == "frozen" and since >= 40 then
        if MODE == "shang_revert" then
            xfer_p1(A.back_to_shang_form, "back_to_shang_form"); go("revert")
        elseif MODE == "shang" then
            xfer_p1(ST_2_FN1, "do_st_2_fn1"); go("morph_fn1")
        elseif MODE == "shatter" then
            start_fatal(A.do_shatter_punch, "do_shatter_punch")
        else
            start_fatal(FAN_DECAP, "do_fan_decap")
        end

    elseif step == "revert" then
        if p1_ochar() == FT_ST and since >= 60 then
            xfer_p1(ST_2_FN1, "do_st_2_fn1"); go("morph_fn1")
        elseif since > 400 then finish(false, "revert_to_shang_failed_ochar_" .. p1_ochar()); return end

    elseif step == "morph_fn1" then
        if victim_wake ~= A.super_frozen then
            finish(false, "victim_left_super_frozen_during_morph"); return
        end
        if p1_ochar() == FT_KITANA and since >= 90 then
            snapshot("shang_as_kitana")
            start_fatal(FAN_DECAP, "do_fan_decap")
        elseif since > 400 then finish(false, "morph_to_kitana_failed_ochar_" .. p1_ochar()); return end

    elseif step == "fatal" then
        local rel = frame - fatal_frame
        local id, slot = pal_of(A.p2_obj)
        if id ~= last_pal then
            pal_changes[#pal_changes + 1] = string.format("rel%d:%s", rel, pname(id))
            log("victim pal rel=%d %s slot=%s wake=%s free_fg=%d", rel, pname(id), tostring(slot),
                hx(victim_wake), free_fg_slots())
            last_pal = id
        end
        local fd = r16(A.f_death)
        if fd ~= 0 and fd ~= 0xffff then fdeath_seen = true end
        if rel == 10 or rel == 40 or rel == 70 or rel == 90 or rel == 150 then
            snapshot(string.format("rel_%03d", rel))
        end
        if rel >= 220 then
            if not fdeath_seen then finish(false, "death_blow_never_started")
            elseif MODE == "shatter" then
                if victim_wake == A.super_frozen then finish(false, "uppercut_never_took_him")
                elseif id ~= A.FREEZE_P then finish(false, "shatter_not_in_FREEZE_P")
                else finish(true, "shattered_in_FREEZE_P") end
            elseif id == A.FREEZE_P then finish(false, "victim_still_in_FREEZE_P")
            elseif SHANG and p1_fatal_pal ~= A.KATBLU_P then
                finish(false, "shang_as_kitana_wore_" .. pname(p1_fatal_pal))
            else finish(true, "palettes_correct") end
            return
        end
    end

    local pc = cpu_pc()
    if pc and A.system_lockup ~= 0 and pc >= A.system_lockup and pc < A.tvbp then
        finish(false, "lockup_pc_" .. hx(pc)); return
    end

    for name, f in pairs(fields) do
        if name == "Coin 1" or name == "Coin 2" or name == "2 Players Start"
            or name == "P1 High Punch" or name == "P2 High Punch" then
            f:set_value(pressed(name) and 1 or 0)
        end
    end

    if fighting_frame == 0 and frame > 8000 then finish(false, "never_reached_fight")
    elseif frame > 14000 then finish(false, "global_timeout") end
end)
