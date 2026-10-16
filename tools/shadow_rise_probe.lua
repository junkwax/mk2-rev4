-- shadow_rise_probe.lua
--
-- Measures where a fighter's shadow is drawn while he is IN THE AIR.
--
-- shadow_p1p2 (MKDISP.ASM) does not project the shadow onto the floor - it
-- CLIMBS it, ground_y-(height/4), and hangs a quarter-height below the feet.
-- DEDPOOL is a catwalk with acid on BOTH sides (stone only on screen rows
-- 208-245), so both ends of the shadow run off it.  @shad_hi / @shad_lo clip
-- the blit to the stone; init_bakmods defaults them to 255 (never clips) and
-- calla_dedpool sets 16 / 21.
--
-- SHAD_CLIP=off reopens the band every frame, reproducing stock behaviour from
-- the SAME ROM - that is the A/B.
--
-- Env: SHADOW_LOG, SHADOW_STAGE (decimal curback, default 0 = Dead Pool),
--      SHAD_CLIP=off
-- Usage: tools/run_shadow_rise_probe.ps1 [-Stage 0] [-ClipOff]

local ROOT  = "C:/Users/you/Workplace/mk2-main"
local LOGP  = os.getenv("SHADOW_LOG") or (ROOT .. "/tools/shadow_rise_probe.log")
local STAGE = tonumber(os.getenv("SHADOW_STAGE") or "") or 0
local FORCE = (os.getenv("SHAD_CLIP") == "off")   -- reopen the band = stock behaviour
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[rise] " .. string.format(fmt, ...)
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
                     "p1_obj", "p2_obj", "p1_bar", "p2_bar", "p1_bar_view", "p2_bar_view",
                     "winner_status", "battle_num", "map_position", "f_shadows",
                     "f_noscrolly", "f_freeze_timer", "ground_y", "worldtly", "worldtlx",
                     "shad_hi", "shad_lo", "shad_ytop", "shad_ybot", "p1_shadadj" }) do
    A[n] = symbols[n] or 0
    if A[n] == 0 then log("MISSING SYMBOL %s", n) end
end

local OXVAL, OXPOS, OYPOS = 0x080, 0x090, 0x0b0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_KANG = 8, 1

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local shots, done, best = 0, false, 0
local base_y = nil                      -- his GROUNDED anchor (oypos is head-anchored)
local want = { 25, 45, 65, 85 }         -- heights off the ground to capture at
local got  = {}
local fields = {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function objy(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end
local function objx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function setx(p, x) local o = r32(p); if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end end

local function cache_fields()
    local w = { ["Coin 1"]=true, ["Coin 2"]=true, ["1 Player Start"]=true,
                ["2 Players Start"]=true, ["P1 High Punch"]=true, ["P2 High Punch"]=true,
                ["P1 Up"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if w[f.name] then fields[f.name] = f end
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
        return false
    end
    -- in the fight: tap Up to jump, and again after each landing
    if name == "P1 Up" and fighting_frame > 0 then
        local r = frame - fighting_frame
        return r > 40 and (r % 90) < 8
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- stage %d, clip %s ----", STAGE, FORCE and "FORCED OFF (stock)" or "as the stage sets it")
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
        if A.battle_num  ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight start frame=%d curback=%d ground_y=%d shad_hi=%d shad_lo=%d shadadj=%d f_shadows=%d",
            frame, r16(A.curback), s16(r16(A.ground_y)), s16(r16(A.shad_hi)),
            s16(r16(A.shad_lo)), s16(r16(A.p1_shadadj)), r16(A.f_shadows))
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); logfh:close(); manager.machine:exit() end
        return
    end

    -- hold the fight still: full bars, no timer, no vertical camera chase, so
    -- world y -> screen row stays a constant offset for the whole run
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status  ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end
    if A.f_noscrolly    ~= 0 then w16(A.f_noscrolly, 1) end
    if FORCE then w16(A.shad_hi, 255); w16(A.shad_lo, 255) end
    w16(A.p2_state, 1)

    local r = frame - fighting_frame
    if r < 30 then setx(A.p1_obj, 420); setx(A.p2_obj, 570) end

    local gy   = s16(r16(A.ground_y))
    local adj  = s16(r16(A.p1_shadadj))
    local wtly = s16(r16(A.worldtly + 16))
    local wtlx = s16(r16(A.worldtlx + 16))
    local py   = objy(A.p1_obj)
    local px   = objx(A.p1_obj)
    if not py then return end

    -- oypos is HEAD-anchored, so ground_y - oypos is the sprite's height, not
    -- his.  Take his own grounded anchor while he is still standing and
    -- measure the jump against that.
    if r < 38 then base_y = py; return end
    if r < 40 then log("grounded anchor oypos=%d (ground_y=%d)", base_y, gy); return end

    local h    = base_y - py                   -- height off the ground
    local rise = h // 4
    if h > best then best = h end

    if r % 240 == 0 then
        log("hb r=%d h=%d py=%d best=%d", r, h, py, best)
    end

    for _, target in ipairs(want) do
        if not got[target] and h >= target and h < target + 12 then
            got[target] = true
            shots = shots + 1
            log("snap %d  height=%3d  climb=%2d  shadow top screen_row=%3d   clip band rows %d..%d   p1 screen_x=%d",
                shots, h, rise, gy + adj - wtly - rise,
                s16(r16(A.shad_ytop)), s16(r16(A.shad_ybot)), px - wtlx)
            manager.machine.video:snapshot()
        end
    end

    if shots >= #want and not done then
        done = true
        log("done - %d snapshots, worldtly=%d (world_y = screen_row + %d)", shots, wtly, wtly)
        logfh:close(); manager.machine:exit()
    end
    if frame > 20000 then
        log("ERROR backstop - %d/%d snapshots, highest jump reached %d", shots, #want, best)
        logfh:close(); manager.machine:exit()
    end
end)
