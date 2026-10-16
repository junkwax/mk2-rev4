-- reflect_test.lua - reflect_p1p2 (MKDISP.ASM): a stage's water reflection of
-- the fighters, graphics audit row 21 (doc/graphics_opportunities/REFLECT_CONTRACT.md).
--
-- THE DEAD POOL, a two-human fight, both idle, the round clock frozen.  One
-- boot per mode:
--
--   RF_MODE=none    f_reflect never set                          (baseline)
--   RF_MODE=stage   f_reflect=1 FROM POWER-UP: the stage's own record
--                   (dedpool_refl).  Its attract and select snapshots are the
--                   leak test - the 2026-08-20 version drew on those screens.
--   RF_MODE=phase1  the stage's record copied into refl_ram with ONE phase
--   RF_MODE=flip    a mirror hung from the FRONT acid strip (refl_ram)
--
-- f_reflect is cleared at rel 440, so rel 400/430 are armed and 460 is not.
-- env: RF_MODE, RF_LOG, MK2_ROOT (map dir)
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("RF_MODE") or "none"
local LOG = assert(os.getenv("RF_LOG"), "RF_LOG")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[rf] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local S = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[n] = tonumber(a, 16) end
end
local function sym(n) return assert(S[n], "missing map symbol " .. n) end
local A = {
    gstate = sym("gstate"), curback = sym("curback"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"), p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    f_reflect = sym("f_reflect"), refl_parm = sym("refl_parm"), refl_ram = sym("refl_ram"),
    dedpool_refl = S["dedpool_refl"] or 0,   -- a BGND local: not in the map
    ground_y = sym("ground_y"), worldtly = sym("worldtly"),
    worldtlx = sym("worldtlx"), f_freeze_timer = S["f_freeze_timer"], rand = S["rand"],
    peak_overload = S["peak_overload"], qdma_drops = S["qdma_drops"], dmaq_late = S["dmaq_late"],
    deep_dmaq = S["deep_dmaq"], map_position = S["map_position"], battle_num = S["battle_num"],
}
local OXPOS = 0x090
local CRAM = 0x01800000
local GS_PSEL, GS_FIGHTING = 4, 2
local DEADPOOL = 0
local SNAPS = { 400, 430, 460 }

local frame, space, fields = 0, nil, {}
local charsel, confirm, fight = 0, 0, 0
local presnaps = 0

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then v = v - 0x10000 end; return v end

local function screen_x(h)
    local o = r32(h); if o == 0 then return -9999 end
    return s16(r16(o + OXPOS)) - s16(r32(A.worldtlx) >> 16)
end

-- a record in refl_ram: base, shift, flip, plog, top, bot, colour
local function put_record(base, shift, flip, plog, top, bot, colour)
    local r = A.refl_ram
    w16(r, base); w16(r + 16, shift); w16(r + 32, flip); w16(r + 48, plog)
    w16(r + 64, top); w16(r + 80, bot); w32(r + 96, colour)
    w32(A.refl_parm, r)
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame <= 35 end
    if charsel == 0 then
        if name == "Coin 1" or name == "Coin 2" then return frame >= 700 and frame < 1100 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1100 and frame < 1180 end
        if name == "2 Players Start" then return frame >= 1140 and frame < 1240 end
        return false
    end
    if fight == 0 and confirm > 0 then
        if name == "P1 High Punch" then return frame >= confirm and frame < confirm + 45 end
        if name == "P2 High Punch" then return frame >= confirm + 70 and frame < confirm + 115 end
    end
    return false
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["UI Select"] = 1, ["Coin 1"] = 1, ["Coin 2"] = 1, ["1 Player Start"] = 1,
                       ["2 Players Start"] = 1, ["P1 High Punch"] = 1, ["P2 High Punch"] = 1 }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("mode=%s", MODE)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    -- armed from power-up in every mode but the baseline: attract and select are the leak test
    if MODE ~= "none" and fight == 0 then w16(A.f_reflect, 1) end

    local gs = r16(A.gstate)
    if frame == 600 then manager.machine.video:snapshot(); log("PRESNAP attract frame=%d gstate=%d", frame, gs) end
    if gs == GS_PSEL and charsel == 0 then charsel = frame end
    if charsel > 0 and fight == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1); w16(A.p1_char, 1); w16(A.p2_char, 2)
        w16(A.curback, DEADPOOL)
        if A.map_position then w16(A.map_position, 0) end
        if A.battle_num then w16(A.battle_num, 1) end
        if frame == charsel + 60 then manager.machine.video:snapshot(); log("PRESNAP select frame=%d gstate=%d", frame, gs) end
        if confirm == 0 and frame - charsel > 90 then confirm = frame end
    end
    if gs == GS_FIGHTING and fight == 0 then fight = frame; log("FIGHT frame=%d curback=%d", frame, r16(A.curback)) end
    if fight == 0 then
        if frame > 9000 then log("ERROR never reached the fight"); logfh:close(); manager.machine:exit() end
        return
    end

    local rel = frame - fight
    if A.f_freeze_timer then w16(A.f_freeze_timer, 1) end
    if rel == 249 then
        log("PREARM p1x=%d p2x=%d rand=%s parm=%08x stage_rec=%08x", screen_x(A.p1_obj), screen_x(A.p2_obj),
            A.rand and string.format("%08x", r32(A.rand)) or "n/a", r32(A.refl_parm), A.dedpool_refl)
        if A.peak_overload then w16(A.peak_overload, 0) end
    end
    if rel == 250 then
        if MODE == "phase1" then put_record(20, 4, 0, 0, -28, -17, 0x06060000) end
        if MODE == "flip" then put_record(-22, 4, 1, 1, 22, 29, 0x06060000) end
    end
    if MODE ~= "none" and rel < 440 then w16(A.f_reflect, 1) end
    if rel == 440 then w16(A.f_reflect, 0) end
    for _, at in ipairs(SNAPS) do
        if rel == at then
            manager.machine.video:snapshot()
            log("SNAP rel%d frame=%d ground_y=%d wty=%d p1x=%d p2x=%d", at, frame, s16(r16(A.ground_y)),
                s16(r32(A.worldtly) >> 16), screen_x(A.p1_obj), screen_x(A.p2_obj))
        end
    end
    if rel == 300 then log("PEN colour=%04x", r16(CRAM + 6 * 16)) end
    if rel == SNAPS[#SNAPS] + 5 then
        log("RESULT mode=%s peak_overload=%s qdma_drops=%s dmaq_late=%s deep_dmaq_cells=%s",
            MODE, A.peak_overload and tostring(r16(A.peak_overload)) or "na",
            A.qdma_drops and tostring(r16(A.qdma_drops)) or "na",
            A.dmaq_late and tostring(r16(A.dmaq_late)) or "na",
            A.deep_dmaq and tostring((r16(A.deep_dmaq) + 5) // 6) or "na")
        logfh:close()
        manager.machine:exit()
    end
end)
