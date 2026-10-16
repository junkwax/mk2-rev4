-- armory_normal_audit.lua
-- Drive a NORMAL 2P game (real simulated input, no memory-forced stage) through
-- coin/start/char-select, navigate the VS stage-select screen to Armory
-- (curback==5) via real Left/Right/confirm presses, then sample the lava
-- color-cycle palette (VAT) and the floor skew state every frame while on
-- Armory. Everything is logged to a file so it can be read back directly -
-- no native debugger console, no forced-state shortcuts.

local ROOT = os.getenv("ARMORY_AUDIT_ROOT") or "C:/Users/you/Workplace/mk2-main"
ROOT = ROOT:gsub("\\", "/")
local LOG_PATH = os.getenv("ARMORY_AUDIT_LOG") or (ROOT .. "/tools/armory_normal_audit.log")
local logfh = io.open(LOG_PATH, "w")
local function logprint(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

-- Resolve symbols from the live build's map file instead of hardcoding
-- addresses, since they shift between rebuilds.
local symbols = {}
do
    local fh = io.open(ROOT .. "/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    else
        logprint("[armory-audit] FATAL: could not open " .. ROOT .. "/src/MK2.MAP")
    end
end

local function sym(name, fallback)
    local v = symbols[name]
    if v then return v end
    logprint(string.format("[armory-audit] WARN missing symbol %s, using fallback 0x%08x", name, fallback or 0))
    return fallback or 0
end

local GSTATE      = sym("gstate",       0x0112a2d0)
local CURBACK     = sym("curback",      0x0112bbd0)
local VAT_ADDR    = sym("VAT",          0)
local LAVA_P_ADDR = sym("LAVA_P",       0)
local SKEW_DX     = sym("skew_dx")
local SKEW_OC     = sym("skew_oc")
local SKEW_Y      = sym("skew_y")
local SKEW_HEIGHT = sym("skew_height")
local SKEW_SCROLL = sym("skew_scroll")
local SKEW_SAG    = sym("skew_sag")
local SKEW_CONSTPAL = sym("skew_constpal")
local PALRAM      = sym("palram",       0x01125720)

local NUMPAL  = 60
local PALRSIZ = 0x40      -- bytes/entry (64 - verified via fpalram/bpalram boundary
                          -- math AND a direct slot-content readback; the earlier
                          -- value of 8 here was wrong and caused false "not found"
                          -- results all session - see ARMORY_LAVA_INVESTIGATION_LOG.md
local COLOR_RAM = 0x01800000

local ARMORY_STAGE = 5

-- VAT's expected static color table (src/BGNDPAL.ASM, confirmed byte-identical
-- to stock by static audit). Used to detect a live mismatch directly.
local MARFLOR_EXPECTED = {
    0x0000,0x24a2,0x2083,0x2082,0x24a4,0x2ce4,0x28c3,0x28c4,
    0x1841,0x1420,0x1862,0x1441,0x1c62,0x28a3,0x20a3,0x24c4,
}

local LAVA_P_EXPECTED = {
    0x0000,0x3127,0x1827,0x2ce3,0x1820,0x2040,0x2460,0x2c80,
    0x30a0,0x38a0,0x40c0,0x48e0,0x5120,0x5d60,0x5d80,0x65a0,
    0x6de0,0x7a40,0x7aa0,0x7ae0,0x7b20,0x7b60,0x7fa0,0x7fe0,
    0x7260,0x7220,0x71a0,0x1005,0x2029,
}

local VAT_EXPECTED = {
    0x0000,0x4967,0x4d87,0x51a7,0x4125,0x3127,0x1c83,0x1827,0x20a2,0x1020,
    0x0000,0x1443,0x0800,0x0400,0x1861,0x0c00,0x1864,0x1022,0x2ce3,0x20a1,
    0x1041,0x0c20,0x1882,0x1ca3,0x28e2,0x1840,0x1820,0x2040,0x2460,0x2c80,
    0x30a0,0x38a0,0x40c0,0x48e0,0x5120,0x5940,0x5520,0x5d60,0x6180,0x5d80,
    0x65a0,0x69c0,0x6de0,0x7a40,0x1420,0x7aa0,0x7ae0,0x7b20,0x7b60,0x7fa0,
    0x7fe0,0x7ba0,0x7b60,0x7b20,0x7b00,0x7aa0,0x7260,0x7220,0x71a0,0x75e0,
    0x1005,0x0c04,0x2029,
}

local frame = 0
local fields = {}
local space, cpu = nil, nil

local charsel_frame = 0
local stage_select_active = false
local stage_confirmed = false
local fight_frame = 0
local last_gstate = -1
local last_curback = -1
local sampled_once = false

local function cache_fields()
    local wanted = {
        ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
        ["1 Player Start"]=true, ["2 Players Start"]=true,
        ["P1 High Punch"]=true, ["P2 High Punch"]=true,
        ["P1 Left"]=true, ["P1 Right"]=true, ["P2 Left"]=true, ["P2 Right"]=true,
        ["P1 Low Kick"]=true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    -- Demo-match length before the attract loop accepts coins varies run to
    -- run, so keep inserting credits/start in a long repeating window instead
    -- of a one-shot frame range - whichever cycle we land in, this catches it.
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 200 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 220 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 50
        end
    end

    if charsel_frame > 0 then
        local r = frame - charsel_frame
        if name == "P1 High Punch" and not stage_select_active then return r >= 130 and r < 170 end
        if name == "P2 High Punch" and not stage_select_active then return r >= 190 and r < 230 end
    end

    if stage_select_active and not stage_confirmed then
        local cb = space and space:read_u16(CURBACK) or -1
        if name == "P1 Right" then
            return cb ~= ARMORY_STAGE and (frame % 6) < 3
        end
        if name == "P1 High Punch" then
            return cb == ARMORY_STAGE
        end
    end
    return false
end

local function dump_cram_slot(slot, count)
    -- Per-color stride is 0x10 (16) bytes - confirmed empirically: both
    -- MARFLOR's and VAT's live dumps showed each real color value repeating
    -- exactly 8 times in a row at a 2-byte stride, which only makes sense if
    -- the true stride is 8x that = 16 bytes. (Two earlier attempts derived
    -- 2 bytes from re-reading PALL.ASM's bit-shift math and both failed
    -- cross-validation - trust the empirical repeat-pattern over the
    -- re-derivation here.)
    local words = {}
    local base = COLOR_RAM + (slot * 0x1000)
    for i = 0, (count or 64) - 1 do
        words[#words + 1] = space:read_u16(base + (i * 0x10))
    end
    return words
end

local function find_palram_slot(target_addr)
    for i = 0, NUMPAL - 1 do
        local id = space:read_u32(PALRAM + i * PALRSIZ)
        if id == target_addr then return i end
    end
    return nil
end

local function compare_vat(words)
    local mismatches = 0
    for i, expect in ipairs(VAT_EXPECTED) do
        local got = words[i]
        if got ~= expect then mismatches = mismatches + 1 end
    end
    return mismatches
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        logprint(string.format("[armory-audit] loaded VAT=0x%08x gstate=0x%08x curback=0x%08x palram=0x%08x",
            VAT_ADDR, GSTATE, CURBACK, PALRAM))
    end

    for name, field in pairs(fields) do
        if pressed(name) then field:set_value(1) else field:clear_value() end
    end

    if not space then return end

    local g = space:read_u16(GSTATE)
    if g ~= last_gstate then
        logprint(string.format("[armory-audit] frame=%d gstate %d -> %d", frame, last_gstate, g))
        last_gstate = g
    end

    if charsel_frame == 0 and g == 4 then
        charsel_frame = frame
        logprint(string.format("[armory-audit] char select begins at frame=%d", frame))
    end

    if not stage_select_active and charsel_frame > 0 and frame - charsel_frame > 250 then
        stage_select_active = true
        logprint(string.format("[armory-audit] stage select begins at frame=%d curback=%d", frame, space:read_u16(CURBACK)))
    end

    if stage_select_active and not stage_confirmed then
        local cb = space:read_u16(CURBACK)
        if cb ~= last_curback then
            logprint(string.format("[armory-audit] curback now=%d (target=%d)", cb, ARMORY_STAGE))
            last_curback = cb
        end
        if cb == ARMORY_STAGE and frame - charsel_frame > 280 then
            stage_confirmed = true
            logprint(string.format("[armory-audit] confirming Armory at frame=%d", frame))
        end
    end

    if fight_frame == 0 and g == 2 and space:read_u16(CURBACK) == ARMORY_STAGE then
        fight_frame = frame
        logprint(string.format("[armory-audit] FIGHT started on curback=%d at frame=%d (test_mode direct-boot path)", space:read_u16(CURBACK), frame))
    end

    if fight_frame > 0 and (frame - fight_frame) % 15 == 0 and (frame - fight_frame) < 1800 then
        local cb = space:read_u16(CURBACK)
        local skew = string.format("skew_dx=%08x skew_oc=%08x skew_y=%04x skew_height=%04x skew_scroll=%08x skew_sag=%08x skew_constpal=%08x",
            space:read_u32(SKEW_DX), space:read_u32(SKEW_OC), space:read_u16(SKEW_Y), space:read_u16(SKEW_HEIGHT),
            space:read_u32(SKEW_SCROLL), space:read_u32(SKEW_SAG), space:read_u32(SKEW_CONSTPAL))
        -- Cross-check: MARFLOR's slot is known directly from skew_constpal
        -- (no findpal scan needed) - if THIS reads correct colors while
        -- LAVA_P reads zero, the read mechanism itself is validated.
        local marflor_slot = space:read_u32(SKEW_CONSTPAL) % 256
        local mf_words = dump_cram_slot(marflor_slot, #MARFLOR_EXPECTED)
        local mf_mismatches = 0
        for i, expect in ipairs(MARFLOR_EXPECTED) do
            if mf_words[i] ~= expect then mf_mismatches = mf_mismatches + 1 end
        end
        local mf_str = {}
        for _, w in ipairs(mf_words) do mf_str[#mf_str+1] = string.format("%04x", w) end
        logprint(string.format("[armory-audit] tick=%d MARFLOR_slot=0x%02x mismatches=%d live=%s", frame - fight_frame, marflor_slot, mf_mismatches, table.concat(mf_str, ",")))

        local lava_p_slot = find_palram_slot(LAVA_P_ADDR)
        if lava_p_slot then
            local lp_words = dump_cram_slot(lava_p_slot, #LAVA_P_EXPECTED)
            local lp_mismatches = 0
            for i, expect in ipairs(LAVA_P_EXPECTED) do
                if lp_words[i] ~= expect then lp_mismatches = lp_mismatches + 1 end
            end
            logprint(string.format("[armory-audit] tick=%d LAVA_P_slot=0x%02x mismatches=%d", frame - fight_frame, lava_p_slot, lp_mismatches))
            if lp_mismatches > 0 then
                local lp_str, lp_exp = {}, {}
                for _, w in ipairs(lp_words) do lp_str[#lp_str+1] = string.format("%04x", w) end
                for _, v in ipairs(LAVA_P_EXPECTED) do lp_exp[#lp_exp+1] = string.format("%04x", v) end
                logprint(string.format("[armory-audit] LAVA_P_LIVE  =%s", table.concat(lp_str, ",")))
                logprint(string.format("[armory-audit] LAVA_P_EXPECT=%s", table.concat(lp_exp, ",")))
            end
        else
            logprint(string.format("[armory-audit] tick=%d LAVA_P_slot=NOT_FOUND", frame - fight_frame))
        end
        local slot = find_palram_slot(VAT_ADDR)
        if slot then
            local words = dump_cram_slot(slot, #VAT_EXPECTED)
            local mismatches = compare_vat(words)
            local wordstr = {}
            for _, w in ipairs(words) do wordstr[#wordstr+1] = string.format("%04x", w) end
            logprint(string.format("[armory-audit] tick=%d curback=%d VAT_slot=0x%02x mismatches=%d %s",
                frame - fight_frame, cb, slot, mismatches, skew))
            if mismatches > 0 then
                logprint(string.format("[armory-audit] VAT_LIVE  =%s", table.concat(wordstr, ",")))
                logprint(string.format("[armory-audit] VAT_EXPECT=%s", table.concat((function()
                    local t = {} for _, v in ipairs(VAT_EXPECTED) do t[#t+1]=string.format("%04x", v) end return t
                end)(), ",")))
            end
        else
            logprint(string.format("[armory-audit] tick=%d curback=%d VAT not found in palram (not yet loaded?) %s",
                frame - fight_frame, cb, skew))
        end
        sampled_once = true
    end

    if fight_frame > 0 and (frame - fight_frame) == 1800 then
        logprint("[armory-audit] done sampling, stopping")
        manager.machine:soft_reset()
    end
end)
