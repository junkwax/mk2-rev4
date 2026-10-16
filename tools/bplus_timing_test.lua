-- bplus_timing_test.lua - Back+HP move timing, measured on the running game.
--
-- 2P: P1 = BT_CHAR (forced during post-select), P2 = an idle human Sub-Zero.
-- Two trials, each: get to a gap, settle, then hold Back and tap High Punch.
--   hit   - walk in to BT_HITGAP: the move must connect
--   whiff - P2 backs off to BT_WHIFFGAP: the move must miss
--
-- What is measured (ticks, one per frame):
--   start  first tick P1's object has m_noblock - init_special sets it on the
--          move's first tick
--   end    first tick it is clear again - back_to_normal clears it, which is
--          the move handing control back
--   hit    first tick P2's bar drops (hit trial)
-- p_action is NOT the marker: retract_strike writes 0 into it part way
-- through Baraka's and Kitana's moves, and Shang's is 0206h.
--
-- Addresses come in through the environment (run_bplus_timing_test.ps1
-- resolves them out of src/mk2.map every run); Lua reads take RAW BIT addresses.

local LOG = os.getenv("BT_LOG") or "bplus_timing_test.log"
local logfh = io.open(LOG, "w")
local function log(fmt, ...)
    local line = string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local function envhex(name)
    local v = os.getenv(name)
    if not v then log("[bt] FATAL missing env %s", name); manager.machine:exit(); return 0 end
    return tonumber(v, 16)
end

local GSTATE  = envhex("BT_GSTATE")
local P1_CHAR = envhex("BT_P1_CHAR")
local P2_CHAR = envhex("BT_P2_CHAR")
local P1_OBJ  = envhex("BT_P1_OBJ")
local P2_OBJ  = envhex("BT_P2_OBJ")
local P1_PROC = envhex("BT_P1_PROC")
local P1_BAR  = envhex("BT_P1_BAR")
local P2_BAR  = envhex("BT_P2_BAR")
local FREEZE  = envhex("BT_FREEZE")
local CHAR    = tonumber(os.getenv("BT_CHAR") or "3")
local VICTIM  = tonumber(os.getenv("BT_VICTIM") or "8")
local HITGAP  = tonumber(os.getenv("BT_HITGAP") or "72")
local WHIFFGAP = tonumber(os.getenv("BT_WHIFFGAP") or "250")

local PROC_ACTION = 0x1f0
local OBJ_OXPOS, OBJ_OFLAGS2 = 0x090, 0x160
local M_NOBLOCK = 0x0004
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2

local frame, space, fields = 0, nil, {}
local charsel, fightf, confirm = 0, 0, 0
local last_gs = -1

local TRIALS = { "hit", "whiff" }
local ti, phase, pt = 1, "walk", 0
local res = {}
local cur

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end

local function p1act()
    local p = r32(P1_PROC); return p ~= 0 and r16(p + PROC_ACTION) or 0xffff
end
local function noblock()
    local o = r32(P1_OBJ); return o ~= 0 and (r16(o + OBJ_OFLAGS2) & M_NOBLOCK) ~= 0
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
    if name == "1 Player Start" then return charsel == 0 and frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then
        if charsel > 0 and fightf == 0 then local r = frame - charsel; return r >= 5 and r < 45 end
        return charsel == 0 and frame >= 1040 and frame < 1140
    end
    if charsel > 0 and fightf == 0 then
        if name == "P1 High Punch" and confirm > 0 then return frame >= confirm and frame < confirm + 40 end
        if name == "P2 High Punch" and confirm > 0 then return frame >= confirm + 80 and frame < confirm + 120 end
        return false
    end
    if fightf == 0 or not cur then return false end
    if phase == "walk" then
        if cur == "hit" then return name == "P1 Right" end
        return name == "P2 Right"           -- P2 faces left: Right backs him off
    end
    if phase == "fire" then
        if name == "P1 Left" then return pt < 14 end
        if name == "P1 High Punch" then return pt >= 3 and pt < 7 end
    end
    return false
end

local function finish()
    for _, t in ipairs(TRIALS) do
        local r = res[t]
        if not r or not r.start or not r.stop then
            log("[bt] %s NO RESULT (start=%s end=%s)", t, r and tostring(r.start) or "nil", r and tostring(r.stop) or "nil")
        else
            log("[bt] %s char=%d gap=%d total=%d windup=%s dmg=%d timeline=%s",
                t, CHAR, r.gap, r.stop - r.start, r.hit and tostring(r.hit - r.start) or "-", r.dmg, r.tl)
        end
    end
    log("[bt] DONE")
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["UI Select"]=1, ["Coin 1"]=1, ["Coin 2"]=1, ["1 Player Start"]=1, ["2 Players Start"]=1,
            ["P1 Right"]=1, ["P1 Left"]=1, ["P1 High Punch"]=1, ["P2 High Punch"]=1, ["P2 Right"]=1 }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        for n, _ in pairs(want) do if not fields[n] and n ~= "UI Select" then log("[bt] input %s MISSING", n) end end
        log("[bt] loaded char=%d victim=%d hitgap=%d whiffgap=%d", CHAR, VICTIM, HITGAP, WHIFFGAP)
    end
    if not space then return end

    local gs = r16(GSTATE)
    if gs ~= last_gs then
        log("[bt] frame=%d gstate %d -> %d", frame, last_gs, gs)
        if gs == GS_PSEL and charsel == 0 then charsel = frame; confirm = frame + 170 end
        if gs == GS_FIGHTING and fightf == 0 then fightf = frame; pt = 0; cur = TRIALS[1] end
        last_gs = gs
    end
    -- force the pair until the fight runs (setup_players reads them in the round intro)
    if charsel > 0 and frame > confirm + 130 and (fightf == 0 or frame < fightf + 60) then
        space:write_u16(P1_CHAR, CHAR)
        space:write_u16(P2_CHAR, VICTIM)
    end

    if fightf > 0 and cur and frame > fightf + 60 then
        space:write_u16(FREEZE, 1)
        if r16(P1_BAR) < 0x40 then space:write_u16(P1_BAR, 0xa1) end
        pt = pt + 1
        local g = gap()
        if phase == "walk" then
            local done = (cur == "hit" and g <= HITGAP) or (cur == "whiff" and g >= WHIFFGAP)
            if done or pt > 400 then phase, pt = "settle", 0 end
        elseif phase == "settle" then
            if pt >= 25 then
                phase, pt = "fire", 0
                res[cur] = { bar0 = r16(P2_BAR), gap = g, dmg = 0, tl = "" }
                log("[bt] %s: firing at gap %d", cur, g)
            end
        elseif phase == "fire" then
            local r = res[cur]
            local nb, act = noblock(), p1act()
            if nb and not r.start and pt >= 3 then r.start = pt end
            if r.start and not r.stop and not nb then r.stop = pt end
            if r.start and not r.stop then
                local tag = string.format("%04x", act)
                local last = r.tl:match("([%x]+)x%d+$")
                if last == tag then
                    r.tl = r.tl:gsub("x(%d+)$", function(n) return "x" .. (tonumber(n) + 1) end)
                else
                    r.tl = r.tl .. (r.tl == "" and "" or ",") .. tag .. "x1"
                end
            end
            local d = r.bar0 - r16(P2_BAR)
            if d > r.dmg then
                if r.dmg == 0 and r.start then r.hit = pt end
                r.dmg = d
            end
            if pt >= 150 then
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

    if frame > 12000 then log("[bt] NO VERDICT (timeout, gs=%d fight=%d)", gs, fightf); manager.machine:exit() end
end)
