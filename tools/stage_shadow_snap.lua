-- stage_shadow_snap.lua
--
-- Boots into one stage, parks both fighters, and snapshots the screen so a
-- shadow fix can be eyeballed.  Pit Bottom (curback 0x0a, mk1pit_mod) had no
-- `-2` shadow marker in dlists_mk1pit, so MKDISP's disp2 never remembered a
-- slot to splice fighter shadows into and the stage rendered without them.
--
-- Env: SHADOW_LOG, SHADOW_STAGE (decimal curback index, default 10 = Pit Bottom)
-- Usage: tools/run_stage_shadow_snap.ps1 [-Stage 10]

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("SHADOW_LOG") or (ROOT .. "/tools/stage_shadow_snap.log")
local STAGE = tonumber(os.getenv("SHADOW_STAGE") or "") or 10
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[shadow] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
local map = assert(io.open(ROOT .. "/src/mk2.map", "r"))
for line in map:lines() do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[name] = tonumber(addr, 16)
    end
end
map:close()

local A = {}
for _, n in ipairs({ "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
                     "p1_obj", "p2_obj", "p1_bar", "p2_bar", "p1_bar_view",
                     "p2_bar_view", "winner_status", "battle_num", "map_position",
                     "f_shadows", "ground_y" }) do
    A[n] = symbols[n] or 0
    if A[n] == 0 then log("MISSING SYMBOL %s", n) end
end

local OXVAL, OYPOS = 0x080, 0x0b0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_KANG = 8, 1

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local shots, done = 0, false
local fields = {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function gety(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end
local function setx(p, x) local o = r32(p); if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["Coin 2"] = true, ["1 Player Start"] = true,
                   ["2 Players Start"] = true, ["P1 High Punch"] = true,
                   ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 200 and frame < 1000 and (frame % 80) < 20
        end
        if name == "1 Player Start"  then return frame >= 1000 and frame < 1080 end
        if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
        return false
    end
    if fighting_frame == 0 and p1_confirm > 0 then
        if name == "P1 High Punch" then return frame >= p1_confirm and frame < p1_confirm + 45 end
        if name == "P2 High Punch" then return frame >= p1_confirm + 70 and frame < p1_confirm + 115 end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- stage %d shadow snapshot ----", STAGE)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_KANG)
        w16(A.curback, STAGE)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == GS_FIGHTING then w16(A.p2_state, 1) end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight start frame=%d curback=%d ground_y=%d f_shadows=%d",
            frame, r16(A.curback), s16(r16(A.ground_y)), r16(A.f_shadows))
        log("P1 oypos=%s P2 oypos=%s", tostring(gety(A.p1_obj)), tostring(gety(A.p2_obj)))
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); logfh:close(); manager.machine:exit() end
        return
    end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end

    -- separate them so each shadow is clearly its own
    local r = frame - fighting_frame
    if r < 200 then setx(A.p1_obj, 420); setx(A.p2_obj, 560) end

    if r > 60 and r % 60 == 0 and shots < 4 then
        shots = shots + 1
        log("snap %d at r=%d (f_shadows=%d)", shots, r, r16(A.f_shadows))
        manager.machine.video:snapshot()
    end
    if shots >= 4 and not done then
        done = true
        log("done - %d snapshots", shots)
        logfh:close(); manager.machine:exit()
    end
    if frame > 20000 then log("ERROR backstop"); logfh:close(); manager.machine:exit() end
end)
