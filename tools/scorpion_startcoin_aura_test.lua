-- scorpion_startcoin_aura_test.lua
-- Drives START+Coin Scorpion selection, screenshots the match, and captures
-- MKBUG trap-loop state if the new SCPALT3 aura crashes.
--
-- Usage:
--   C:\MAME\mame.exe -rompath C:\Users\you\Workplace\mk2-main\rom mk2 ^
--     -window -skip_gameinfo -script C:\Users\you\Workplace\mk2-main\tools\scorpion_startcoin_aura_test.lua

local frame = 0
local logfh = io.open("C:/Users/you/Workplace/mk2-main/tools/scorpion_startcoin_aura_test.log", "w")
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

local fields, cpu, space = {}, nil, nil
local last_gstate = -1
local charsel_frame, vs_frame, fighting_frame = 0, 0, 0
local scorpion_cursor_frame = 0
local first_aura_frame = 0
local did_select_snap = false
local did_fight_snap = false
local did_aura_snap = false
local did_aura_clear_snap = false
local did_stance_probe_snap = false
local did_walkf_probe_snap = false
local did_walkb_probe_snap = false
local did_trap = false
local disable_aura_chord = os.getenv("SCORP_AURA_DISABLE") == "1"

local MAP_PATH = "C:/Users/you/Workplace/mk2-main/src/MK2.MAP"
local symbols = {}

do
    local fh = io.open(MAP_PATH, "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    else
        print("[scorp-aura] WARN could not read " .. MAP_PATH .. "; using fallback addresses")
    end
end

local function symaddr(name, fallback)
    local value = symbols[name]
    if not value then
        print(string.format("[scorp-aura] WARN missing map symbol %s; using fallback 0x%08x", name, fallback))
        return fallback
    end
    return value
end

-- Current mk2.map bit addresses. Fallbacks keep old builds debuggable.
local ACTIVE        = symaddr("active", 0x010dc6d0)
local OBJLST        = symaddr("objlst", 0x01127060)
local OBJLST2       = symaddr("objlst2", 0x01127080)
local GSTATE        = symaddr("gstate", 0x01129dc0)
local P1_STATE      = symaddr("p1_state", 0x01129de0)
local P1_OBJ        = symaddr("p1_obj", 0x01129e10)
local P1_PROC       = symaddr("p1_proc", 0x01129e50)
local P1_CHAR       = symaddr("p1_char", 0x01129e70)
local P1_BAR        = symaddr("p1_bar", 0x01129ee0)
local P2_STATE      = symaddr("p2_state", 0x0112a9b0)
local P2_OBJ        = symaddr("p2_obj", 0x0112a9e0)
local P2_PROC       = symaddr("p2_proc", 0x0112aa20)
local P2_CHAR       = symaddr("p2_char", 0x0112aa40)
local P2_BAR        = symaddr("p2_bar", 0x0112aab0)
local PF_RAM        = symaddr("pf_ram", 0x0112b6a0)
local CURBACK       = symaddr("curback", 0x0112b6c0)
local ROUND_NUM     = symaddr("round_num", 0x0112b6f0)
local ALT_PAL_OWNER = symaddr("alt_pal_owner", 0x0112bd00)
local F_DOSCORE     = symaddr("f_doscore", 0x0112b5a0)
local SCORE_1ST     = symaddr("score_1st", 0x01128740)
local SCORE_RAM_END = 0x01128740
local SNS           = 0xc0
local PALRAM        = symaddr("palram", 0x01125710)
local PALRSIZ       = 0x40
local PALID         = 0x00
local PALCNT        = 0x20
local SCORE_P_ADDR  = symaddr("SCORE_P", 0xffbe0d30)
local HNDFIRE_P_ADDR = symaddr("HNDFIRE_P", 0xffbcb140)

-- Process field bit offsets.
local PROC_NEXT     = 0x000
local PROC_ID       = 0x020
local PROC_TIME     = 0x030
local PROC_PA8      = 0x0c0
local PROC_WAKE     = 0x0e0
local P_BUTPORT     = 0x120
local P_OTHERGUY    = 0x140
local P_OTHERPROC   = 0x170
local P_SLAVE       = 0x190
local P_ACTION      = 0x1f0
local P_FLAGS       = 0x210
local P_STORE1      = 0x230
local P_STORE2      = 0x250
local P_STORE3      = 0x270
local P_STORE4      = 0x290
local P_STORE5      = 0x2b0
local P_STORE6      = 0x2d0

-- Object field bit offsets.
local OBJ_NEXT      = 0x000
local OBJ_OSLINK    = 0x020
local OBJ_OXPOS     = 0x090
local OBJ_OYPOS     = 0x0b0
local OBJ_OZVAL     = 0x0c0
local OBJ_OFLAGS    = 0x0f0
local OBJ_OSAG      = 0x100
local OBJ_OPAL      = 0x140
local OBJ_OFLAGS2   = 0x160
local OBJ_OIMG      = 0x1a0
local OBJ_OID       = 0x1c0
local OBJ_OSHAPE    = 0x1d0
local OBJ_OCHAR     = 0x1f0

local GS_FIGHTING   = 0x02
local GS_PSEL       = 0x04
local GS_PFSETUP    = 0x06
local GS_ROUND      = 0x07
local GS_POST_PSEL  = 0x0d
local FT_SCORPION   = 10
local PID_SCORPFIRE = 0x0110
local PID_MPO       = 0x0109

local TRAP_PCS = {
    [0xffa552c0] = "system_lockup_debug_loop",
    [0xffa55340] = "illegal_opcode_recovery_loop",
    [0xffa553c0] = "errort_loop",
}

local function hx(value)
    if value == nil then return "na" end
    return string.format("0x%08x", value & 0xffffffff)
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

local function pc()
    return cpu_reg("PC") or cpu_reg("CURPC") or cpu_reg("GENPC")
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
    if not s then
        print(string.format("[scorp-aura] SNAP frame=%d label=%s no-screen", frame, label))
        return
    end
    local ok, err = pcall(function() s:snapshot() end)
    print(string.format("[scorp-aura] SNAP frame=%d label=%s ok=%s %s",
        frame, label, tostring(ok), ok and "" or tostring(err)))
end

local function count_list(addr)
    if not space then return 0 end
    local p = space:read_u32(addr)
    local count = 0
    while p ~= 0 and count < 512 do
        count = count + 1
        p = space:read_u32(p + OBJ_NEXT)
    end
    return count
end

local function find_process(pid)
    if not space then return 0 end
    local p = space:read_u32(ACTIVE)
    local guard = 0
    while p ~= 0 and guard < 256 do
        if space:read_u16(p + PROC_ID) == pid then return p end
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
    return 0
end

local function find_process_for_obj(pid, obj)
    if not space or obj == 0 then return 0 end
    local p = space:read_u32(ACTIVE)
    local guard = 0
    while p ~= 0 and guard < 256 do
        if space:read_u16(p + PROC_ID) == pid and space:read_u32(p + P_OTHERGUY) == obj then
            return p
        end
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
    return 0
end

local function count_process(pid)
    if not space then return 0 end
    local p = space:read_u32(ACTIVE)
    local count = 0
    local guard = 0
    while p ~= 0 and guard < 256 do
        if space:read_u16(p + PROC_ID) == pid then count = count + 1 end
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
    return count
end

local function pal_slot(slot)
    local base = PALRAM + slot * PALRSIZ
    return space:read_u32(base + PALID), space:read_u16(base + PALCNT)
end

local function find_pal_slot(pal_addr)
    for slot = 0, 24 do
        local id, cnt = pal_slot(slot)
        if id == pal_addr then return slot, cnt end
    end
    return -1, 0
end

local function dump_process_list()
    print("[scorp-aura] --- active process list ---")
    local p = space:read_u32(ACTIVE)
    local guard = 0
    while p ~= 0 and guard < 80 do
        print(string.format(
            "[scorp-aura] proc[%02d] addr=%s id=%04x time=%04x wake=%s pa8=%s but=%s otherguy=%s slave=%s s1=%s s2=%s s3=%s s4=%s s5=%s s6=%s",
            guard,
            hx(p),
            space:read_u16(p + PROC_ID),
            space:read_u16(p + PROC_TIME),
            hx(space:read_u32(p + PROC_WAKE)),
            hx(space:read_u32(p + PROC_PA8)),
            hx(space:read_u32(p + P_BUTPORT)),
            hx(space:read_u32(p + P_OTHERGUY)),
            hx(space:read_u32(p + P_SLAVE)),
            hx(space:read_u32(p + P_STORE1)),
            hx(space:read_u32(p + P_STORE2)),
            hx(space:read_u32(p + P_STORE3)),
            hx(space:read_u32(p + P_STORE4)),
            hx(space:read_u32(p + P_STORE5)),
            hx(space:read_u32(p + P_STORE6))))
        p = space:read_u32(p + PROC_NEXT)
        guard = guard + 1
    end
end

local function dump_object_list(addr, label)
    print(string.format("[scorp-aura] --- %s ---", label))
    local p = space:read_u32(addr)
    local guard = 0
    while p ~= 0 and guard < 40 do
        print(string.format(
            "[scorp-aura] obj[%02d] addr=%s oid=%04x ochar=%04x xy=%04x,%04x z=%s of=%04x of2=%04x opal=%04x oimg=%s osag=%s oshape=%s oslink=%s",
            guard,
            hx(p),
            space:read_u16(p + OBJ_OID),
            space:read_u16(p + OBJ_OCHAR),
            space:read_u16(p + OBJ_OXPOS),
            space:read_u16(p + OBJ_OYPOS),
            hx(space:read_u32(p + OBJ_OZVAL)),
            space:read_u16(p + OBJ_OFLAGS),
            space:read_u16(p + OBJ_OFLAGS2),
            space:read_u16(p + OBJ_OPAL),
            hx(space:read_u32(p + OBJ_OIMG)),
            hx(space:read_u32(p + OBJ_OSAG)),
            hx(space:read_u32(p + OBJ_OSHAPE)),
            hx(space:read_u32(p + OBJ_OSLINK))))
        p = space:read_u32(p + OBJ_NEXT)
        guard = guard + 1
    end
end

local function dump_score_entries()
    if not space then return end
    local first = space:read_u32(SCORE_1ST)
    print(string.format("[scorp-aura] --- score dma entries first=%s end=%s ---", hx(first), hx(SCORE_RAM_END)))
    local p = first
    local i = 0
    while p ~= 0 and p < SCORE_RAM_END and i < 24 do
        print(string.format(
            "[scorp-aura] score[%02d] addr=%s scale=%s pal=%s size=%s yx=%s sag=%s ctrl=%s",
            i, hx(p),
            hx(space:read_u32(p + 0x00)),
            hx(space:read_u32(p + 0x20)),
            hx(space:read_u32(p + 0x40)),
            hx(space:read_u32(p + 0x60)),
            hx(space:read_u32(p + 0x80)),
            hx(space:read_u32(p + 0xa0))))
        p = p + SNS
        i = i + 1
    end
end


local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["1 Player Start"] = true,
        ["P1 Left"] = true,
        ["P1 Right"] = true,
        ["P1 Down"] = true,
        ["P1 High Punch"] = true,
        ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name, _ in pairs(wanted) do
        print(string.format("[scorp-aura] input %-16s %s", name, fields[name] and "ok" or "MISSING"))
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end

    -- Boot into a one-player game.
    if name == "Coin 1" and charsel_frame == 0 then
        return frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" and charsel_frame == 0 then
        return frame >= 1000 and frame < 1080
    end

    if charsel_frame > 0 and fighting_frame == 0 then
        local r = frame - charsel_frame

        if vs_frame > 0 then
            -- Confirm stage select once the VS page has had time to render.
            if name == "P1 Low Kick" then
                return frame >= vs_frame + 260 and frame < vs_frame + 320
            end
            return false
        end

        -- Liu Kang default -> Scorpion: right, right, down, left.
        -- Keep movement pulses wider than the game's 12-frame cursor debounce,
        -- and leave a quiet gap before the Start+Coin select chord.
        if name == "P1 Right" then
            return (r >= 80 and r < 102) or (r >= 160 and r < 182)
        end
        if name == "P1 Down" then
            return r >= 240 and r < 262
        end
        if name == "P1 Left" then
            return r >= 320 and r < 328
        end

        -- New selector chord: START + Coin while cursor is on Scorpion.
        if scorpion_cursor_frame > 0 then
            if name == "Coin 1" and not disable_aura_chord then return frame >= scorpion_cursor_frame + 1 and frame < scorpion_cursor_frame + 40 end
            if name == "1 Player Start" then return frame >= scorpion_cursor_frame + 1 and frame < scorpion_cursor_frame + 40 end
        end
    end

    if fighting_frame > 0 then
        local r = frame - fighting_frame
        if name == "P1 Right" then
            return r >= 300 and r < 430
        end
        if name == "P1 Left" then
            return r >= 520 and r < 650
        end
    end

    return false
end

local function log_state(force)
    if not space then return end
    if not force and frame % 30 ~= 0 then return end

    local g = space:read_u16(GSTATE)
    local p1obj = space:read_u32(P1_OBJ)
    local p1proc = space:read_u32(P1_PROC)
    local aura = find_process_for_obj(PID_SCORPFIRE, p1obj)
    if aura == 0 then aura = find_process(PID_SCORPFIRE) end
    local flame = aura ~= 0 and space:read_u32(aura + P_SLAVE) or 0
    local p1flags2, p1opal, p1ochar = 0xffff, 0xffff, 0xffff
    local p1x, p1y = 0xffff, 0xffff
    local flame_x, flame_y, flame_flags2, flame_opal, flame_img, flame_sag, flame_shape = 0xffff, 0xffff, 0xffff, 0xffff, 0, 0, 0
    if p1obj ~= 0 then
        p1flags2 = space:read_u16(p1obj + OBJ_OFLAGS2)
        p1opal = space:read_u16(p1obj + OBJ_OPAL)
        p1ochar = space:read_u16(p1obj + OBJ_OCHAR)
        p1x = space:read_u16(p1obj + OBJ_OXPOS)
        p1y = space:read_u16(p1obj + OBJ_OYPOS)
    end
    if flame ~= 0 then
        flame_x = space:read_u16(flame + OBJ_OXPOS)
        flame_y = space:read_u16(flame + OBJ_OYPOS)
        flame_flags2 = space:read_u16(flame + OBJ_OFLAGS2)
        flame_opal = space:read_u16(flame + OBJ_OPAL)
        flame_img = space:read_u32(flame + OBJ_OIMG)
        flame_sag = space:read_u32(flame + OBJ_OSAG)
        flame_shape = space:read_u32(flame + OBJ_OSHAPE)
    end
    local action = p1proc ~= 0 and space:read_u16(p1proc + P_ACTION) or 0xffff
    local score_slot_id, score_slot_count = pal_slot(1)
    local score_p_slot, score_p_count = find_pal_slot(SCORE_P_ADDR)
    local hndfire_slot, hndfire_count = find_pal_slot(HNDFIRE_P_ADDR)
    print(string.format(
        "[scorp-aura] frame=%-5d gs=%02x p1s=%04x p2s=%04x chars=%d/%d alt=%04x p1obj=%s p1xy=%04x,%04x p1of2=%04x p1opal=%04x p1ochar=%04x p1act=%04x p1shape=%s aura=%s flame=%s flamexy=%04x,%04x dxy=%d,%d flameof2=%04x flameopal=%04x flameimg=%s flamesag=%s flameshape=%s aura_count=%d mpo=%d obj=%d obj2=%d hp=%d/%d doscore=%04x score1=%s score_slot1=%s/%04x scorep_slot=%d/%04x hndfire_slot=%d/%04x cur=%04x rnd=%04x pc=%s pf=%s",
        frame, g,
        space:read_u16(P1_STATE), space:read_u16(P2_STATE),
        space:read_u16(P1_CHAR), space:read_u16(P2_CHAR),
        space:read_u16(ALT_PAL_OWNER),
        hx(p1obj), p1x, p1y, p1flags2, p1opal, p1ochar, action, hx(p1obj ~= 0 and space:read_u32(p1obj + OBJ_OSHAPE) or 0),
        hx(aura), hx(flame), flame_x, flame_y, flame_x - p1x, flame_y - p1y, flame_flags2, flame_opal, hx(flame_img), hx(flame_sag), hx(flame_shape),
        count_process(PID_SCORPFIRE), count_process(PID_MPO),
        count_list(OBJLST), count_list(OBJLST2),
        space:read_u16(P1_BAR), space:read_u16(P2_BAR),
        space:read_u16(F_DOSCORE), hx(space:read_u32(SCORE_1ST)),
        hx(score_slot_id), score_slot_count, score_p_slot, score_p_count,
        hndfire_slot, hndfire_count,
        space:read_u16(CURBACK), space:read_u16(ROUND_NUM),
        hx(pc()), hx(space:read_u32(PF_RAM))))
end

local function trap_watch()
    if did_trap or not space then return end
    local p = pc()
    local label = p and TRAP_PCS[p] or nil
    if not label then return end

    did_trap = true
    print(string.format("[scorp-aura] TRAP frame=%d pc=%s label=%s a0=%s a1=%s a8=%s a13=%s sp=%s b14=%s",
        frame, hx(p), label,
        hx(cpu_reg("A0") or cpu_reg("a0")),
        hx(cpu_reg("A1") or cpu_reg("a1")),
        hx(cpu_reg("A8") or cpu_reg("a8")),
        hx(cpu_reg("A13") or cpu_reg("a13")),
        hx(cpu_reg("SP")),
        hx(cpu_reg("B14") or cpu_reg("b14"))))
    log_state(true)
    dump_process_list()
    dump_object_list(OBJLST, "objlst")
    dump_object_list(OBJLST2, "objlst2")
    snap("trap")
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        print(string.format("[scorp-aura] loaded - selecting %s Scorpion and watching aura",
            disable_aura_chord and "normal" or "START+Coin"))
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end

    if space then
        local g = space:read_u16(GSTATE)
        if g ~= last_gstate then
            print(string.format("[scorp-aura] gstate %d -> %d at frame %d", last_gstate, g, frame))
            last_gstate = g
        end
        if g == GS_PSEL and charsel_frame == 0 then
            charsel_frame = frame
            print(string.format("[scorp-aura] char select begins at frame=%d", frame))
        end
        if g == GS_POST_PSEL and vs_frame == 0 then
            vs_frame = frame
            snap("vs_start")
        end
        if (g == GS_FIGHTING or g == GS_ROUND) and fighting_frame == 0 then
            fighting_frame = frame
            print(string.format("[scorp-aura] fighting at frame=%d", frame))
            dump_score_entries()
            snap("fight_start")
            did_fight_snap = true
        end
        if charsel_frame > 0 and scorpion_cursor_frame == 0 and space:read_u16(P1_CHAR) == FT_SCORPION then
            scorpion_cursor_frame = frame
            print(string.format("[scorp-aura] cursor reached Scorpion at frame=%d alt=%04x",
                frame, space:read_u16(ALT_PAL_OWNER)))
            snap("cursor_scorpion")
        end
        if not did_select_snap and (space:read_u16(ALT_PAL_OWNER) & 0x0400) ~= 0 then
            did_select_snap = true
            snap("start_coin_claimed")
        end

        local aura = find_process_for_obj(PID_SCORPFIRE, space:read_u32(P1_OBJ))
        if aura == 0 then aura = find_process(PID_SCORPFIRE) end
        if aura ~= 0 and first_aura_frame == 0 then
            first_aura_frame = frame
            print(string.format("[scorp-aura] aura process found at frame=%d proc=%s", frame, hx(aura)))
            dump_process_list()
            snap("aura_proc_found")
        end
        if aura ~= 0 and not did_aura_snap and frame > first_aura_frame + 90 then
            did_aura_snap = true
            snap("aura_running")
        end
        if aura ~= 0 and not did_aura_clear_snap and frame > first_aura_frame + 210 then
            did_aura_clear_snap = true
            snap("aura_clear")
        end
        if fighting_frame > 0 and not did_stance_probe_snap and frame > fighting_frame + 45 then
            did_stance_probe_snap = true
            snap("stance_probe")
        end
        if fighting_frame > 0 and not did_walkf_probe_snap and frame > fighting_frame + 350 then
            did_walkf_probe_snap = true
            snap("walkf_probe")
        end
        if fighting_frame > 0 and not did_walkb_probe_snap and frame > fighting_frame + 570 then
            did_walkb_probe_snap = true
            snap("walkb_probe")
        end

        log_state(false)
        trap_watch()
    end

    if fighting_frame > 0 and frame > fighting_frame + 1800 then
        log_state(true)
        snap("pass_final")
        print("[scorp-aura] PASS reached 1800 fight frames without trap")
        manager.machine:exit()
    end

    if fighting_frame == 0 and frame > 7000 then
        log_state(true)
        snap("never_fought")
        print("[scorp-aura] ERROR never reached fighting state")
        manager.machine:exit()
    end
end)

emu.register_stop(function()
    if logfh then
        logfh:close()
        logfh = nil
    end
end)
