-- sz_airice_freeze_test.lua
--
-- "Sub-Zero's air ice does not freeze the opponent in the air any more."
--
-- Three trials, each isolating one half of that sentence:
--
--   air_vs_ground  P1 jumps, throws the AIR ice at a standing victim.
--                  Control: does the air freeze work at all?
--   ground_vs_air  P1 stands, throws the GROUND ice at a JUMPING victim.
--                  Control: can any freeze catch an airborne victim?
--   air_vs_air     both jump; P1 throws the air ice at the jumping victim.
--                  This is the reported case.
--
-- Every attempt records four separate facts, because "it doesn't freeze" has
-- four different causes and they need different fixes:
--   cast   p1 action reached act_air_ice/act_throw_ice  -> the gate in
--          sz_lo_punch let the move out
--   hit    p2's life bar dropped                        -> the projectile's
--          strike box actually reached him
--   froze  p2 action reached act_frozen                 -> r_ice ran
--   height p2's pixels above his grounded y at that moment
--
-- l_freeze / l_freeze_any are dumped per attempt so a refused cast can be
-- attributed to the cooldown rather than to the input.
--
-- Env: AIRICE_LOG
-- Usage: tools/run_sz_airice_freeze_test.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("AIRICE_LOG") or (ROOT .. "/tools/sz_airice_freeze_test.log")
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[airice] " .. string.format(fmt, ...)
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
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate=sym("gstate"), curback=sym("curback"),
    p1_char=sym("p1_char"), p2_char=sym("p2_char"),
    p1_state=sym("p1_state"), p2_state=sym("p2_state"),
    p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"),
    p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
    p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
    p1_bar_view=sym("p1_bar_view"), p2_bar_view=sym("p2_bar_view"),
    winner_status=sym("winner_status"), battle_num=sym("battle_num"),
    map_position=sym("map_position"), f_freeze_timer=sym("f_freeze_timer"),
    l_freeze=sym("l_freeze"), l_freeze_any=sym("l_freeze_any"), tick=sym("tick"),
}

local OXVAL, OYPOS = 0x080, 0x0b0
local P_ACTION = 0x1f0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_REPTILE = 8, 9
local ACT_THROW_ICE, ACT_AIR_ICE, ACT_FROZEN = 0x0010, 0x0015, 0x0401

local SZ_X, GAP = 240, 0x60
local CYCLE, ATTEMPTS = 200, 3
local TRIALS = { "air_vs_ground", "ground_vs_air", "air_vs_air" }

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local trial, trial_start = 1, 0
local fields, results, done = {}, {}, false
local FLOOR_Y = 0
local att = nil          -- current attempt record
local attempts = {}      -- for this trial
local was_casting = false
local last_a1, last_a2 = -1, -1

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function pact(p) local q=r32(p); if q==0 then return 0xffff end return r16(q+P_ACTION) end
local function setx(p,x) local o=r32(p); if o~=0 then space:write_u32(o+OXVAL,(x & 0xffff)<<16) end end
local function gety(p) local o=r32(p); if o==0 then return nil end return s16(r16(o+OYPOS)) end
local function height(p) local y=gety(p); if not y then return -1 end return FLOOR_Y - y end

local function tsl(base, half)   -- ticks since that stamp, -1 = never
    local st = r16(base + half*16)
    if st == 0 then return -1 end
    local t = r16(A.tick)
    return (t - st) & 0xffff
end

local function summarize()
    log("")
    for _, k in ipairs(TRIALS) do
        local rs = results[k] or {}
        local cast, hit, froze, air = 0, 0, 0, 0
        for _, a in ipairs(rs) do
            if a.cast then cast = cast + 1 end
            if a.hit then hit = hit + 1 end
            if a.froze then froze = froze + 1 end
            if a.froze and (a.froze_h or 0) > 16 then air = air + 1 end
        end
        log("RESULT %-14s attempts=%d cast=%d hit=%d froze=%d frozeInAir=%d",
            k, #rs, cast, hit, froze, air)
        for i, a in ipairs(rs) do
            log("   %s #%d cast=%s hit=%s froze=%s  h@cast=%d h@hit=%d h@froze=%d  lfz=%d lfzany=%d",
                k, i, a.cast and "y" or "N", a.hit and "y" or "N", a.froze and "y" or "N",
                a.h_cast or -1, a.h_hit or -1, a.froze_h or -1, a.lfz or -1, a.lfzany or -1)
        end
    end
end

local function finish()
    if done then return end
    done = true
    summarize()
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["Coin 2"]=true, ["1 Player Start"]=true,
                   ["2 Players Start"]=true, ["P1 High Punch"]=true,
                   ["P1 Low Punch"]=true, ["P1 Right"]=true, ["P1 Down"]=true,
                   ["P1 Up"]=true, ["P2 High Punch"]=true, ["P2 Up"]=true }
    local missing = {}
    for _,port in pairs(manager.machine.ioport.ports) do
        for _,f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then missing[#missing+1] = n end end
    if #missing > 0 then log("MISSING input field(s): %s", table.concat(missing, ", ")) end
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
    if fighting_frame == 0 then
        if p1_confirm > 0 then
            if name == "P1 High Punch" then return frame >= p1_confirm and frame < p1_confirm+45 end
            if name == "P2 High Punch" then return frame >= p1_confirm+70 and frame < p1_confirm+115 end
        end
        return false
    end

    local mode = TRIALS[trial]
    local r = (frame - trial_start) % CYCLE
    local p1_jumps = (mode ~= "ground_vs_air")
    local p2_jumps = (mode ~= "air_vs_ground")

    if name == "P1 Up" then return p1_jumps and r >= 0 and r < 6 end
    if name == "P2 Up" then return p2_jumps and r >= 0 and r < 6 end
    if name == "P1 Down"      then return r >= 10 and r < 18 end
    if name == "P1 Right"     then return r >= 18 and r < 26 end
    if name == "P1 Low Punch" then return r >= 24 and r < 30 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- Sub-Zero AIR ICE vs an airborne victim ----")
    end
    for n,f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state,1); w16(A.p2_state,1)
        w16(A.p1_char,FT_SUBZERO); w16(A.p2_char,FT_REPTILE); w16(A.curback,0)
        if A.map_position ~= 0 then w16(A.map_position,0) end
        if A.battle_num ~= 0 then w16(A.battle_num,1) end
        if p1_confirm == 0 and frame-charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING then w16(A.p2_state,1) end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; trial_start = frame
        FLOOR_Y = gety(A.p2_obj) or 0
        log("fight start frame=%d, victim grounded oypos=%d", frame, FLOOR_Y)
        log("---- trial %s ----", TRIALS[trial])
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar,MAX_HP); w16(A.p1_bar_view,MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status,0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer,1) end

    local mode = TRIALS[trial]
    local r = (frame - trial_start) % CYCLE
    local a1, a2 = pact(A.p1_proc), pact(A.p2_proc)

    if a1 ~= last_a1 or a2 ~= last_a2 then
        log("  %s r=%3d p1act=%04x p2act=%04x p1h=%d p2h=%d",
            mode, r, a1, a2, height(A.p1_obj), height(A.p2_obj))
        last_a1, last_a2 = a1, a2
    end

    -- fixed spacing, x only; y is the game's business
    setx(A.p1_obj, SZ_X)
    setx(A.p2_obj, SZ_X + GAP)

    -- new attempt window
    if r == 0 then
        if att then attempts[#attempts+1] = att end
        att = { cast=false, hit=false, froze=false,
                lfz=tsl(A.l_freeze,0), lfzany=tsl(A.l_freeze_any,0) }
        was_casting = false
    end

    if att then
        local casting = (a1 == ACT_AIR_ICE or a1 == ACT_THROW_ICE)
        if casting and not was_casting then
            att.cast = true; att.h_cast = height(A.p2_obj)
            log("%s: CAST act=%04x at r=%d, victim %d px up", mode, a1, r, att.h_cast)
        end
        was_casting = casting

        local hp = r16(A.p2_bar)
        if hp < MAX_HP then
            if not att.hit then
                att.hit = true; att.h_hit = height(A.p2_obj)
                log("%s: HIT at r=%d (-%d hp), victim %d px up", mode, r, MAX_HP-hp, att.h_hit)
            end
        end
        w16(A.p2_bar,MAX_HP); w16(A.p2_bar_view,MAX_HP)

        if a2 == ACT_FROZEN and not att.froze then
            att.froze = true; att.froze_h = height(A.p2_obj)
            log("%s: FROZE at r=%d, victim %d px up", mode, r, att.froze_h)
        end
    end

    if frame - trial_start >= CYCLE*ATTEMPTS then
        if att then attempts[#attempts+1] = att; att = nil end
        results[mode] = attempts
        attempts = {}
        trial = trial + 1
        if trial > #TRIALS then finish(); return end
        trial_start = frame
        last_a1, last_a2 = -1, -1
        log("---- trial %s ----", TRIALS[trial])
    end

    if frame > 40000 then log("ERROR backstop"); finish() end
end)
