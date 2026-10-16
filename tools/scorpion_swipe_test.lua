-- scorpion_swipe_test.lua - SCORPION'S Back+HP SWORD SLASH (do_sc_swipe, MKSCSW.ASM)
--
-- 2P: P1 Scorpion, P2 an idle human Reptile.  Three trials, each: walk in to
-- SS_GAP px, then hold Back and tap High Punch.
--   stand  - P2 stands:  the slash must connect for stk_sc_swipe's 24, and
--            the victim must bleed (a pid_blood process runs).
--   duck   - P2 ducks:   the slash is HIGH, so it must whiff (0 damage).
--   block  - P2 blocks:  chip only, 6.
-- Every trial also requires act_swipe on P1, the sword object drawn, and the
-- sword frame-for-frame with the body (SWIPEn drawn with DSPEARn).
--
-- Addresses come in through the environment (run_scorpion_swipe_test.ps1
-- resolves them out of src/mk2.map every run); Lua reads take RAW BIT
-- addresses.

local LOG = os.getenv("SS_LOG") or "C:/Users/you/Workplace/mk2-main/tools/scorpion_swipe_test.log"
local logfh = io.open(LOG, "w")
local function log(fmt, ...)
    local line = string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local function envhex(name)
    local v = os.getenv(name)
    if not v then log("[ss] FATAL missing env %s", name); manager.machine:exit(); return 0 end
    return tonumber(v, 16)
end

local GSTATE  = envhex("SS_GSTATE")
local P1_CHAR = envhex("SS_P1_CHAR")
local P1_OBJ  = envhex("SS_P1_OBJ")
local P2_OBJ  = envhex("SS_P2_OBJ")
local P1_PROC = envhex("SS_P1_PROC")
local P2_PROC = envhex("SS_P2_PROC")
local P2_BAR  = envhex("SS_P2_BAR")
local P1_BAR  = envhex("SS_P1_BAR")
local FREEZE  = envhex("SS_FREEZE")
local OBJLSTS = { envhex("SS_OBJLST"), envhex("SS_OBJLST2"), envhex("SS_OBJLST3") }
local ACTIVE  = envhex("SS_ACTIVE")
local GAP     = tonumber(os.getenv("SS_GAP") or "85")
-- -Negative: zero ochar_power_punches row 10 IN THE LOADED ROM (no rebuild).
-- It is found by its contents - do_sc_swipe's address as a .long - and must
-- occur exactly once.  Scorpion's Back+HP is then retail's plain high punch,
-- and every trial must report act_swipe never seen.
local NEG     = os.getenv("SS_NEG") == "1"
local COSTUME = os.getenv("SS_COSTUME") or ""   -- "hp": hold 1P Start across the confirm (Start+HP lane)
local PALRAM  = envhex("SS_PALRAM")
local OBJ_OPAL = 0x140
local ROPE_P  = envhex("SS_ROPE")   -- the sword's palette (NJDETHSPEAR1's PON> record)
local SWIPE_ADDR = envhex("SS_SWIPE")

local PROC_ACTION = 0x1f0
local OBJ_OXPOS, OBJ_OIMG, OBJ_OID = 0x090, 0x1a0, 0x1c0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_SCORPION = 10
local ACT_SWIPE = 0x011e
local PID_BLOOD = 0x0201   -- create_blood_proc spawns its droplets under this
local P_PROCID = 0x20

-- body and sword first-piece SAGs, frame by frame (src/MKNJ.TBL)
local BODY = { [0x02646c6e]=1, [0x0264e00c]=2, [0x02653922]=3, [0x0265ad2e]=4 }
local SWORD_LO, SWORD_HI = 0x026ed1d4, 0x026ef000
local SWORD = { [0x026ed1d4]=1, [0x026ed5e0]=2, [0x026edbb8]=3, [0x026ede78]=4 }

local frame, cpu, space, fields = 0, nil, nil, {}
local swordobj = 0
local charsel, vsf, fightf, confirm = 0, 0, 0, 0
local last_gs = -1

local TRIALS = { "stand", "duck", "block" }
local EXPECT = { stand = 24, duck = 0, block = 6 }
local ti, phase, pt = 1, "walk", 0
local res = {}
local cur

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end

local function snap(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot() end) end
    log("[ss] SNAP frame=%d %s", frame, label)
end

local function p1act()
    local p = r32(P1_PROC); return p ~= 0 and r16(p + PROC_ACTION) or 0xffff
end
local function p2act()
    local p = r32(P2_PROC); return p ~= 0 and r16(p + PROC_ACTION) or 0xffff
end
local function sag_of(obj)
    if obj == 0 then return 0 end
    local img = r32(obj + OBJ_OIMG); if img == 0 then return 0 end
    return r32(img)
end
local function scan()
    local sword, blood = 0, 0
    swordobj = 0
    for _, head in ipairs(OBJLSTS) do
        local p, n = r32(head), 0
        while p ~= 0 and n < 256 do
            local s = sag_of(p)
            if s >= SWORD_LO and s < SWORD_HI then sword = s; swordobj = p end
            p = r32(p); n = n + 1
        end
    end
    local p, n = r32(ACTIVE), 0
    while p ~= 0 and n < 512 do
        if r16(p + P_PROCID) == PID_BLOOD then blood = blood + 1 end
        p = r32(p); n = n + 1
    end
    return sword, blood
end
local function gap()
    local a, b = r32(P1_OBJ), r32(P2_OBJ)
    if a == 0 or b == 0 then return 9999 end
    local d = r16(b + OBJ_OXPOS) - r16(a + OBJ_OXPOS)
    if d > 0x7fff then d = d - 0x10000 end
    return d
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" or name == "Coin 2" then
        return charsel == 0 and frame >= 700 and frame < 980 and (frame % 80) < 20
    end
    if name == "1 Player Start" then
        if COSTUME == "hp" and confirm > 0 and charsel > 0 and fightf == 0 then
            return frame >= confirm - 20 and frame < confirm + 45
        end
        return charsel == 0 and frame >= 1000 and frame < 1080
    end
    if name == "2 Players Start" then
        if charsel > 0 and fightf == 0 then local r = frame - charsel; return r >= 5 and r < 45 end
        return charsel == 0 and frame >= 1040 and frame < 1140
    end
    if charsel > 0 and fightf == 0 then
        local r = frame - charsel
        -- Liu Kang -> Scorpion: Down, Down, Right, Right
        if name == "P1 Down" then return (r >= 80 and r < 88) or (r >= 100 and r < 108) end
        if name == "P1 Right" then return (r >= 120 and r < 128) or (r >= 140 and r < 148) end
        if name == "P1 High Punch" and confirm > 0 then return frame >= confirm and frame < confirm + 40 end
        if name == "P2 High Punch" and confirm > 0 then return frame >= confirm + 80 and frame < confirm + 120 end
        if name == "P1 Low Kick" and vsf > 0 then return frame >= vsf + 260 and frame < vsf + 305 end
        return false
    end
    if fightf == 0 or not cur then return false end
    if name == "P2 Down"  then return cur == "duck"  and phase ~= "rest" end
    if name == "P2 Block" then return cur == "block" and phase ~= "rest" end
    if phase == "walk" then return name == "P1 Right" end
    if phase == "fire" then
        if name == "P1 Left" then return pt < 14 end
        if name == "P1 High Punch" then return pt >= 3 and pt < 7 end
    end
    return false
end

local function finish()
    if NEG then
        local any = false
        for _, t in ipairs(TRIALS) do
            local r = res[t]
            log("[ss] negative %s fired=%s dmg=%d", t, r and tostring(r.fired) or "nil", r and r.dmg or -1)
            if not r or r.fired then any = true end
        end
        log("[ss] RESULT %s", any and "FAIL" or "PASS")
        manager.machine:exit(); return
    end
    local pass = true
    for _, t in ipairs(TRIALS) do
        local r = res[t]
        if not r then log("[ss] %s NO RESULT", t); pass = false
        else
            local ok = r.fired and r.sword_frames > 0 and r.lockstep and r.palok ~= false and r.dmg == EXPECT[t]
            if t == "stand" then ok = ok and r.blood > 0 end
            log("[ss] %s %s fired=%s dmg=%d (want %d) sword_frames=%d swordpal=%s lockstep=%s pairs=%s blood=%d p2act_peak=0x%04x",
                t, ok and "PASS" or "FAIL", tostring(r.fired), r.dmg, EXPECT[t], r.sword_frames, r.palok == false and "BAD" or "ROPE_P",
                tostring(r.lockstep), r.pairs, r.blood, r.p2peak)
            pass = pass and ok
        end
    end
    log("[ss] RESULT %s", pass and "PASS" or "FAIL")
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]; space = cpu.spaces["program"]
        local want = { ["UI Select"]=1, ["Coin 1"]=1, ["Coin 2"]=1, ["1 Player Start"]=1, ["2 Players Start"]=1,
            ["P1 Down"]=1, ["P1 Right"]=1, ["P1 Left"]=1, ["P1 High Punch"]=1, ["P1 Low Kick"]=1,
            ["P2 High Punch"]=1, ["P2 Down"]=1, ["P2 Block"]=1 }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        for n, _ in pairs(want) do if not fields[n] then log("[ss] input %s MISSING", n) end end
        log("[ss] loaded gap=%d negative=%s", GAP, tostring(NEG))
        if NEG then
            local rg = manager.machine.memory.regions[":maincpu"]
            local hits = {}
            for off = 0, rg.size - 4, 2 do
                if rg:read_u32(off) == SWIPE_ADDR then hits[#hits + 1] = off end
            end
            if #hits ~= 1 then
                log("[ss] RESULT NO VERDICT (do_sc_swipe address found %d times in the ROM)", #hits)
                manager.machine:exit(); return
            end
            rg:write_u32(hits[1], 0)
            log("[ss] negative: zeroed ochar_power_punches row 10 at rom byte 0x%06x", hits[1])
        end
    end
    if not space then return end

    local gs = r16(GSTATE)
    if gs ~= last_gs then
        log("[ss] frame=%d gstate %d -> %d", frame, last_gs, gs)
        if gs == GS_PSEL and charsel == 0 then charsel = frame end
        if gs == GS_POST and vsf == 0 then vsf = frame end
        if gs == GS_FIGHTING and fightf == 0 then fightf = frame; pt = 0; cur = TRIALS[1] end
        last_gs = gs
    end
    if charsel > 0 and confirm == 0 and frame > charsel + 170 and r16(P1_CHAR) == FT_SCORPION then
        confirm = frame + 30; log("[ss] P1 on Scorpion, confirm at %d", confirm)
    end

    if fightf > 0 and cur and frame > fightf + 60 then
        space:write_u16(FREEZE, 1)              -- the round clock must not end a trial
        if r16(P1_BAR) < 0x40 then space:write_u16(P1_BAR, 0xa1) end
        pt = pt + 1
        local g = gap()
        if phase == "walk" then
            if g <= GAP or pt > 400 then
                phase, pt = "settle", 0
            end
        elseif phase == "settle" then
            if pt >= 20 then
                phase, pt = "fire", 0
                res[cur] = { fired=false, sword_frames=0, lockstep=true, pairs="", dmg=0, blood=0,
                             p2peak=0, bar0=r16(P2_BAR), gap=g }
                log("[ss] %s: firing at gap %d bar %d", cur, g, res[cur].bar0)
            end
        elseif phase == "fire" then
            local r = res[cur]
            local act = p1act()
            local sword, blood = scan()
            if cur == "stand" and pt <= 40 then
                local o = r32(P1_OBJ); local op = o ~= 0 and r16(o + OBJ_OPAL) or 0
                local m = (op >> 8) & 0xff
                log("[ss] tick %d act=0x%04x opal=0x%04x palram[%d]=0x%08x sag=0x%08x sword=0x%08x",
                    pt, act, op, m, r32(PALRAM + m * 0x40), sag_of(o), sword)
                if pt % 3 == 0 then snap(string.format("stand_t%02d", pt)) end
            end
            if act == ACT_SWIPE then
                if not r.fired then r.fired = true; snap(cur .. "_start") end
                local b = BODY[sag_of(r32(P1_OBJ))]
                local s = SWORD[sword]
                if sword ~= 0 then
                    r.sword_frames = r.sword_frames + 1
                    local m = (r16(swordobj + OBJ_OPAL) >> 8) & 0xff
                    local pal = r32(PALRAM + m * 0x40)
                    if pal ~= ROPE_P then
                        if r.palok ~= false then log("[ss] %s sword palette 0x%08x, not ROPE_P 0x%08x", cur, pal, ROPE_P) end
                        r.palok = false
                    end
                end
                if b and s then
                    local tag = b .. "/" .. s
                    if r.pairs:sub(-#tag) ~= tag then r.pairs = r.pairs .. (r.pairs == "" and "" or ",") .. tag end
                    if b ~= s then r.lockstep = false end
                    if b == 3 and not r.snapped then r.snapped = true; snap(cur .. "_slash") end
                end
            end
            if blood > r.blood then r.blood = blood end
            local pa = p2act(); if pa > r.p2peak and pa ~= 0xffff then r.p2peak = pa end
            local d = r.bar0 - r16(P2_BAR); if d > r.dmg then r.dmg = d end
            if pt == 40 then snap(cur .. "_after") end
            if pt >= 120 then
                if not r.fired then log("[ss] %s: act_swipe never seen", cur) end
                space:write_u16(P2_BAR, 0xa1)
                phase, pt = "rest", 0
            end
        elseif phase == "rest" then
            if pt >= 60 then
                ti = ti + 1; cur = TRIALS[ti]
                if not cur then finish(); return end
                phase, pt = "walk", 0
            end
        end
    end

    for name, f in pairs(fields) do f:set_value(pressed(name) and 1 or 0) end

    if frame > 9000 then log("[ss] RESULT NO VERDICT (timeout, gs=%d fight=%d)", gs, fightf); manager.machine:exit() end
end)
