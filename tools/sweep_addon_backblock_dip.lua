-- sweep_addon_backblock_dip.lua - does the back-block DIP switch work?
--
-- The retired Comic Book Offer switch (dip_backblock, DIPEQU.ASM) decides
-- whether holding AWAY guards.  dipinit caches it in f_no_bkblk and
-- is_he_blocking (JOY.ASM) reads that.  This rig measures it from the
-- victim's side: P1 (Liu Kang) throws high kicks at a pinned distance while
-- P2 (human) does one of three things:
--
--   away    holds the stick AWAY, no button   <- the case the switch decides
--   button  holds Block                        <- control: blocks either way
--   none    holds nothing                      <- control: hit either way
--
-- Each bar drop is classified by its size: chip is a block, full damage
-- a hit.  Run once per switch position
-- by run_backblock_dip_test.ps1 (BB_EXPECT = on|off).
--
-- Env: BB_LOG, BB_EXPECT, BB_MAP (the map that matches the ROM under test)

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("BB_LOG") or (ROOT .. "/tools/backblock_dip.txt")
local EXPECT = os.getenv("BB_EXPECT") or "on"

local sym = {}
for line in io.lines(os.getenv("BB_MAP") or (ROOT .. "/src/mk2.map")) do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate, p1_obj, p2_obj = sym.gstate, sym.p1_obj, sym.p2_obj
local p2_bar, p2_proc = sym.p2_bar, sym.p2_proc
local f_no_bkblk = sym.f_no_bkblk

local P_ACTION, OXPOS, OXVAL = 0x1f0, 0x090, 0x080
local MAX_HP = 0xA1
-- Classified by DAMAGE, not by P2's action: a guarded hit reads p_action 0
-- (an idle fighter's), never act_blockhi.  Liu Kang's high kick is 32 clean
-- and 8 chip, so anything under 20 is a block.
local CHIP_MAX = 20

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[bbdip] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({
    "P1 Left", "P1 Right", "P1 High Kick",
    "P2 Left", "P2 Right", "P2 Block", "P2 Down",
}) do ADDON_OWNS[n] = true end

local PHASES = {"none", "away", "button"}
local space, frame, fight0, phase_at, pi = nil, 0, 0, 0, 1
local fields = {}
local blocked, hit = {}, {}
for _, p in ipairs(PHASES) do blocked[p], hit[p] = 0, 0 end
local last_hp, flag_seen = nil, nil

local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function press(n, on) local f = fields[n]; if f then f:set_value(on and 1 or 0) end end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end
                if f.name == "Comic Book Offer" then
                    log("DSW Comic Book Offer (= back-block) user_value=%s", tostring(f.user_value))
                end
            end
        end
        log("=== back-block dip === expect %s", EXPECT)
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then
        fight0, phase_at = frame, frame
        flag_seen = space:read_u16(f_no_bkblk) & 0xffff
        log("f_no_bkblk = %d (%s)", flag_seen, flag_seen == 0 and "back-block ON" or "back-block OFF")
        log("--- phase: %s", PHASES[pi])
    end
    local phase = PHASES[pi]
    if not phase then return end

    local p2p = space:read_u32(p2_proc)
    local a2 = p2p ~= 0 and (space:read_u16(p2p + P_ACTION) & 0xffff) or 0
    local hp = space:read_u16(p2_bar) & 0xffff
    if last_hp and hp < last_hp then
        if last_hp - hp < CHIP_MAX then blocked[phase] = blocked[phase] + 1
        else hit[phase] = hit[phase] + 1 end
        if (blocked[phase] + hit[phase]) <= 3 then
            log("  %-7s drop=%d p2_act=%04x", phase, last_hp - hp, a2)
        end
    end
    space:write_u16(p2_bar, MAX_HP)
    last_hp = MAX_HP

    if frame - phase_at > 500 then
        log("%-7s blocked=%2d hit=%2d", phase, blocked[phase], hit[phase])
        pi, phase_at = pi + 1, frame
        if PHASES[pi] then log("--- phase: %s", PHASES[pi]) end
        return
    end

    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 == 0 or o2 == 0 then return end
    local x1 = s16(space:read_u16(o1 + OXPOS))
    local x2 = s16(space:read_u16(o2 + OXPOS))
    -- Pin P2 at 70px: holding away walks him off otherwise.
    local tx = (x1 < x2) and (x1 + 70) or (x1 - 70)
    space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)

    local c = (frame - fight0) % 40
    press("P1 Left", false); press("P1 Right", false)
    press("P1 High Kick", c == 30 or c == 31)

    local p2_right = x2 > x1
    press("P2 Down", false)
    press("P2 Block", phase == "button")
    press("P2 Right", phase == "away" and p2_right)
    press("P2 Left",  phase == "away" and not p2_right)
end)

emu.register_stop(function()
    for _, p in ipairs(PHASES) do
        log("RESULT %-7s blocked=%2d hit=%2d", p, blocked[p], hit[p])
    end
    local ok_flag = (flag_seen == (EXPECT == "on" and 0 or 1))
    local n, a, b = PHASES[1], PHASES[2], PHASES[3]
    local enough = (hit.none + blocked.none) >= 3 and (hit.away + blocked.away) >= 3
                   and (hit.button + blocked.button) >= 3
    if not enough or flag_seen == nil then
        log("VERDICT NO-VERDICT (too few contacts - the fight or the kicks never ran)")
        return
    end
    local ctrl = blocked.none == 0 and hit.button == 0
    local away_ok
    if EXPECT == "on" then away_ok = hit.away == 0 and blocked.away > 0
    else away_ok = blocked.away == 0 and hit.away > 0 end
    log("VERDICT %s (expect %s: flag %s, away %s, controls %s)",
        (ok_flag and away_ok and ctrl) and "PASS" or "FAIL", EXPECT,
        ok_flag and "ok" or "WRONG", away_ok and "ok" or "WRONG", ctrl and "ok" or "WRONG")
end)
