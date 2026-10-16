-- sz_airice_flight_probe.lua
--
-- Where does Sub-Zero's AIR ice actually go?
--
-- sz_airice_freeze_test showed the air ice casting 3/3 and connecting 0/3 on a
-- standing victim at the same 96px spacing where the GROUND ice connects 2/2.
-- Three things could produce that, and they need different fixes:
--   1. the move never spawns a projectile at all
--   2. it spawns one that dies immediately
--   3. it spawns one that flies over the victim's head
--
-- So follow the object: every projectile process (procid 0700h..08ffh, which
-- covers pid_proj1/2 and the pid_ice1/2 the ice re-stamps itself with) is
-- reported with its saved a8's position, next to both fighters.
--
-- AIR TRIAL FIRST.  Running the ground trial first leaves the victim frozen for
-- 080h ticks, and a second ice into a frozen victim is freeze_backfire - it
-- freezes SUB-ZERO instead, which then eats the next trial's inputs.
--
-- Env: AIRICEF_LOG
-- Usage: tools/run_sz_airice_flight_probe.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local LOGP = os.getenv("AIRICEF_LOG") or (ROOT .. "/tools/sz_airice_flight_probe.log")
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[flight] " .. string.format(fmt, ...)
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
    gstate=sym("gstate"), curback=sym("curback"), active=sym("active"),
    p1_char=sym("p1_char"), p2_char=sym("p2_char"),
    p1_state=sym("p1_state"), p2_state=sym("p2_state"),
    p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"),
    p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
    p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
    p1_bar_view=sym("p1_bar_view"), p2_bar_view=sym("p2_bar_view"),
    winner_status=sym("winner_status"), battle_num=sym("battle_num"),
    map_position=sym("map_position"), f_freeze_timer=sym("f_freeze_timer"),
}

local O = { next=0x000, oxvel=0x040, oyvel=0x060, oxval=0x080, oxpos=0x090,
            oyval=0x0a0, oypos=0x0b0, oflags=0x0f0, osag=0x100, oid=0x1c0 }
local P = { next=0x000, id=0x020, pa8=0x0c0, action=0x1f0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_REPTILE = 8, 9
local ACT_AIR_ICE, ACT_FROZEN = 0x0015, 0x0401

local SZ_X, GAP = 240, 0x60
local CYCLE, ATTEMPTS = 240, 2
local TRIALS = { "air_vs_air", "air_vs_ground" }

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local trial, trial_start = 1, 0
local fields, done = {}, false
local seen = {}                -- procid -> first frame seen
local last_a1, last_a2 = -1, -1
local froze = {}               -- trial -> { {r=, y=}, ... }
local was_frozen = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function pact(p) local q=r32(p); if q==0 then return 0xffff end return r16(q+P.action) end
local function setx(p,x) local o=r32(p); if o~=0 then space:write_u32(o+O.oxval,(x & 0xffff)<<16) end end

-- every live projectile process, as {id=, obj=}
local function proj_procs()
    local out = {}
    local p = r32(A.active)
    local guard = 0
    while p ~= 0 and guard < 400 do
        local id = r16(p + P.id)
        if id >= 0x0700 and id <= 0x08ff then
            out[#out+1] = { id=id, obj=r32(p + P.pa8) }
        end
        p = r32(p + P.next)
        guard = guard + 1
    end
    return out
end

local function finish()
    if done then return end
    done = true
    log("")
    for _, k in ipairs(TRIALS) do
        local f = froze[k] or {}
        local air = 0
        for _, e in ipairs(f) do if e.y < 60 then air = air + 1 end end
        log("RESULT %-14s attempts=%d freezes=%d frozeInAir=%d", k, ATTEMPTS, #f, air)
        for i, e in ipairs(f) do
            log("   %s freeze #%d at r=%d, victim oypos=%d (%s)",
                k, i, e.r, e.y, e.y < 60 and "AIRBORNE" or "grounded")
        end
    end
    log("done")
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["Coin 2"]=true, ["1 Player Start"]=true,
                   ["2 Players Start"]=true, ["P1 High Punch"]=true,
                   ["P1 Low Punch"]=true, ["P1 Right"]=true, ["P1 Down"]=true,
                   ["P1 Up"]=true, ["P2 High Punch"]=true, ["P2 Up"]=true }
    for _,port in pairs(manager.machine.ioport.ports) do
        for _,f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input %s", n) end end
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
    local r = (frame - trial_start) % CYCLE
    if name == "P1 Up" then return r >= 0 and r < 6 end
    if name == "P2 Up" then return TRIALS[trial] == "air_vs_air" and r >= 0 and r < 6 end
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
        log("---- air ice flight probe (oypos: smaller = higher on screen) ----")
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
        local o = r32(A.p2_obj)
        log("fight start: victim oypos=%d", s16(r16(o+O.oypos)))
        log("---- trial %s ----", TRIALS[trial])
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar,MAX_HP); w16(A.p1_bar_view,MAX_HP)
    w16(A.p2_bar,MAX_HP); w16(A.p2_bar_view,MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status,0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer,1) end

    setx(A.p1_obj, SZ_X)
    setx(A.p2_obj, SZ_X + GAP)

    local mode = TRIALS[trial]
    local r = (frame - trial_start) % CYCLE
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    local a1, a2 = pact(A.p1_proc), pact(A.p2_proc)

    if a1 ~= last_a1 or a2 ~= last_a2 then
        log("%s r=%3d  ACT sz=%04x y=%3d   vic=%04x y=%3d", mode, r,
            a1, s16(r16(p1o+O.oypos)), a2, s16(r16(p2o+O.oypos)))
        last_a1, last_a2 = a1, a2
    end

    if a2 == ACT_FROZEN and not was_frozen then
        froze[mode] = froze[mode] or {}
        local f = froze[mode]
        f[#f+1] = { r=r, y=s16(r16(p2o+O.oypos)) }
        log("%s r=%3d  VICTIM FROZE at oypos=%d", mode, r, f[#f].y)
    end
    was_frozen = (a2 == ACT_FROZEN)

    local live = {}
    for _, pp in ipairs(proj_procs()) do
        live[pp.id] = true
        if not seen[pp.id] then
            seen[pp.id] = frame
            log("%s r=%3d  PROJ %04x born", mode, r, pp.id)
        end
        local o = pp.obj
        if o ~= 0 and (frame % 2) == 0 then
            log("%s r=%3d  proj %04x x=%4d y=%4d yvel=%d | sz x=%4d y=%3d | vic x=%4d y=%3d",
                mode, r, pp.id,
                s16(r16(o+O.oxpos)), s16(r16(o+O.oypos)),
                s16((r32(o+O.oyvel) >> 16) & 0xffff),
                s16(r16(p1o+O.oxpos)), s16(r16(p1o+O.oypos)),
                s16(r16(p2o+O.oxpos)), s16(r16(p2o+O.oypos)))
        end
    end
    for id, f0 in pairs(seen) do
        if not live[id] then
            log("%s r=%3d  PROJ %04x gone (lived %d frames)", mode, r, id, frame - f0)
            seen[id] = nil
        end
    end

    if frame - trial_start >= CYCLE*ATTEMPTS then
        trial = trial + 1
        if trial > #TRIALS then finish(); return end
        trial_start = frame
        last_a1, last_a2 = -1, -1
        log("---- trial %s ----", TRIALS[trial])
    end

    if frame > 40000 then log("ERROR backstop"); finish() end
end)
