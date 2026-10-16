-- Regression: Smoke, Noob, and Jade must preserve the stage chosen by the
-- normal rotation instead of forcing Goro's Lair in boss_minumum_diff.

local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local SECRET = tonumber(os.getenv("SECRET_CHAR") or "14")
local TWO_PLAYER = os.getenv("SECRET_TWO_PLAYER") == "1"
local INPUT_STAGE = tonumber(os.getenv("SECRET_STAGE") or "3")
local ONE_PLAYER_STAGE = { [14] = 0x17, [15] = 0x16, [16] = 9 }
local EXPECTED_STAGE = TWO_PLAYER and INPUT_STAGE or assert(ONE_PLAYER_STAGE[SECRET], "unsupported secret fighter")
local LOG_PATH = os.getenv("SECRET_STAGE_LOG") or (ROOT .. "/tools/secret_stage_rotation_test.log")
local out = assert(io.open(LOG_PATH, "w"))

local function log(fmt, ...)
    local line = "[secret-stage] " .. string.format(fmt, ...)
    print(line)
    out:write(line, "\n")
    out:flush()
end

local symbols = {}
local map = assert(io.open(ROOT .. "/src/mk2.map", "r"))
for line in map:lines() do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[name] = tonumber(addr, 16)
    end
end
map:close()

local function sym(name)
    assert(symbols[name], "missing map symbol " .. name)
    return symbols[name]
end

local A = {
    gstate = sym("gstate"),
    p1_char = sym("p1_char"),
    p2_char = sym("p2_char"),
    p1_state = sym("p1_state"),
    p2_state = sym("p2_state"),
    curback = sym("curback"),
}

local GS_FIGHTING, GS_PSEL, GS_PFSETUP, GS_ROUND_INTRO, GS_POST = 2, 4, 6, 7, 0x0d
local FT_KITANA, FT_SUBZERO, FT_JAX = 4, 8, 11
local frame, space, charsel_frame, confirm_frame, post_seen, post_frame = 0, nil, 0, 0, false, 0
local fields, finished, last_gstate, pfsetup_seen, stage_at_pfsetup = {}, false, -1, false, -1

local function r16(addr) return space:read_u16(addr) end
local function w16(addr, value) space:write_u16(addr, value & 0xffff) end

local function finish(ok, reason)
    if finished then return end
    finished = true
    log("%s secret=%d expected_stage=%d actual_stage=%d reason=%s",
        ok and "PASS" or "ERROR", SECRET, EXPECTED_STAGE, r16(A.curback), reason)
    out:close()
    manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"] = true,
        ["Coin 1"] = true,
        ["Coin 2"] = true,
        ["1 Player Start"] = true,
        ["2 Players Start"] = true,
        ["P1 High Punch"] = true,
        ["P2 High Punch"] = true,
        ["P1 Low Kick"] = true,
    }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" then return charsel_frame == 0 and frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "Coin 2" then return TWO_PLAYER and charsel_frame == 0 and frame >= 700 and frame < 980 and frame % 80 < 20 end
    if name == "1 Player Start" then return not TWO_PLAYER and charsel_frame == 0 and frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then return TWO_PLAYER and charsel_frame == 0 and frame >= 1000 and frame < 1080 end
    if name == "P1 High Punch" and confirm_frame > 0 then
        return frame >= confirm_frame and frame < confirm_frame + 45
    end
    if name == "P2 High Punch" and TWO_PLAYER and confirm_frame > 0 then
        return frame >= confirm_frame + 80 and frame < confirm_frame + 125
    end
    if name == "P1 Low Kick" and post_seen then return frame % 80 < 20 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("loaded mode=%s secret=%d input_stage=%d expected_stage=%d",
            TWO_PLAYER and "2P" or "1P", SECRET, INPUT_STAGE, EXPECTED_STAGE)
    end
    if finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        log("frame=%d gstate=%d curback=%d p1=%d states=%d/%d", frame, gs,
            r16(A.curback), r16(A.p1_char), r16(A.p1_state), r16(A.p2_state))
        last_gstate = gs
    end

    if gs == GS_PSEL then
        if charsel_frame == 0 then charsel_frame = frame end
        local select_char = TWO_PLAYER and SECRET or FT_KITANA
        if TWO_PLAYER and SECRET == 15 then select_char = FT_SUBZERO end
        w16(A.p1_char, select_char)
        if TWO_PLAYER then w16(A.p2_char, FT_JAX) end
        w16(A.curback, INPUT_STAGE)
        if confirm_frame == 0 and frame - charsel_frame > 90 then confirm_frame = frame end
    elseif gs == GS_POST then
        post_seen = true
        if post_frame == 0 then post_frame = frame end
        local post_char = TWO_PLAYER and SECRET or FT_KITANA
        -- Directly entering Noob's id before the VS page is composed lacks
        -- the real unlock route's setup. Let Sub-Zero compose normally, then
        -- switch late in the VS hold so only the round policy is under test.
        if TWO_PLAYER and SECRET == 15 and frame - post_frame < 90 then
            post_char = FT_SUBZERO
        end
        w16(A.p1_char, post_char)
        if TWO_PLAYER then w16(A.p2_char, FT_JAX) end
        w16(A.curback, INPUT_STAGE)
    elseif post_seen and not TWO_PLAYER and not pfsetup_seen and gs == GS_ROUND_INTRO then
        -- The 1P ladder runs before pre-fight setup. Replace its selected CPU
        -- opponent here so round_init sees a true one-human secret encounter.
        w16(A.p2_char, SECRET)
        w16(A.curback, INPUT_STAGE)
    elseif post_seen and gs == GS_PFSETUP and not pfsetup_seen then
        -- boss_minumum_diff has run by the time this state is visible to Lua.
        -- Capture its result without writing curback and masking a regression.
        pfsetup_seen = true
        stage_at_pfsetup = r16(A.curback)
        log("policy result mode=%s secret=%d curback=%d states=%d/%d",
            TWO_PLAYER and "2P" or "1P", SECRET, stage_at_pfsetup,
            r16(A.p1_state), r16(A.p2_state))
        if stage_at_pfsetup ~= EXPECTED_STAGE then
            finish(false, "wrong_stage_after_round_init")
            return
        end
    elseif post_seen and gs == GS_FIGHTING then
        local actual_secret = TWO_PLAYER and r16(A.p1_char) or r16(A.p2_char)
        if actual_secret ~= SECRET then
            finish(false, "secret_character_was_not_retained")
        elseif stage_at_pfsetup ~= EXPECTED_STAGE then
            finish(false, "wrong_stage_captured_at_prefight_setup")
        elseif r16(A.curback) ~= EXPECTED_STAGE then
            finish(false, "stage_was_overwritten_during_fight_setup")
        else
            finish(true, TWO_PLAYER and "normal_rotation_stage_preserved" or "one_player_secret_stage_applied")
        end
        return
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
    if frame > 6000 then finish(false, "timeout") end
end)
