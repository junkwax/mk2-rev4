-- kahn_jumpin_test.lua
--
-- Scripted reproduction of the jump-in exploit the live session found:
-- stand out at jump range, jump forward, press HK, repeat.  That flying kick
-- is the ENABLER for the whole Sub-Zero loop - it lands, Kahn is in hit
-- reaction and therefore cannot block, the air freeze goes in for free, and
-- the uppercut is a gift.  Break the jump-in and the chain has no entry.
--
-- Reports, per run: attempts, how many CONNECTED, damage taken by Kahn, and
-- what he did about it (anti-aired / blocked / nothing).  That connect rate
-- is the number to drive down; the live log had it at ~100%.
--
-- Env: KAHN_JI_CHAR (default 8 = Sub-Zero), KAHN_JI_DIFF (default 9),
--      KAHN_JI_CYCLES (default 14), KAHN_JI_LOG, KAHN_JI_ROOT

local frame = 0
local ROOT = (os.getenv("KAHN_JI_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\","/")
local LOG  = os.getenv("KAHN_JI_LOG") or (ROOT .. "/tools/kahn_jumpin_test.log")
local CHAR = tonumber(os.getenv("KAHN_JI_CHAR") or "8") or 8
local DIFF = tonumber(os.getenv("KAHN_JI_DIFF") or "9") or 9
local CYCLES = tonumber(os.getenv("KAHN_JI_CYCLES") or "14") or 14
local SEED = tonumber(os.getenv("KAHN_JI_SEED") or "") or nil

local fh = io.open(LOG, "w")
local function log(f, ...)
    local s = select("#", ...) > 0 and string.format(f, ...) or f
    print("[jumpin] " .. s)
    if fh then fh:write(s, "\n"); fh:flush() end
end

local symbols = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local function sym(n)
    if not symbols[n] then log("FATAL missing symbol %s", n) end
    return symbols[n] or 0
end

local A = {
    gstate=sym("gstate"), diff=sym("diff"), rand=sym("rand"),
    curback=sym("curback"), map_position=sym("map_position"),
    battle_num=sym("battle_num"), round_num=sym("round_num"),
    p1_state=sym("p1_state"), p2_state=sym("p2_state"),
    p1_char=sym("p1_char"), p2_char=sym("p2_char"),
    p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
    p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"),
    p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
    debug4=sym("debug4"),
}
local O = { oxval=0x080, oyval=0x0a0, oypos=0x0b0 }
local P = { action=0x1f0 }
local GS_PSEL, GS_FIGHTING = 4, 2
local FT_KAHN, KAHN_ARENA = 13, 8

local space, fields = nil, {}
local charsel_frame, fighting_frame, confirm = 0, 0, 0
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function w32(a,v) space:write_u32(a, v & 0xffffffff) end

local function wx(o) return (r32(o + O.oxval) >> 16) end
local function gap()
    local a,b = r32(A.p1_obj), r32(A.p2_obj)
    if a==0 or b==0 then return -1 end
    local d = wx(a) - wx(b); return d<0 and -d or d
end
local function p1_airborne()
    local a = r32(A.p1_obj); if a==0 then return false end
    -- oypos rises off the floor when airborne; compare against the grounded
    -- baseline captured at round start rather than a magic number.
    return (ground_y or 0) - r16(a + O.oypos) > 8
end
local function act(p) local q=r32(p); if q==0 then return 0 end; return r16(q+P.action) end

local function cache()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 Up"]=true,
                   ["P1 Left"]=true, ["P1 Right"]=true, ["P1 High Kick"]=true,
                   ["P1 High Punch"]=true }
    for _,port in pairs(manager.machine.ioport.ports) do
        for _,f in pairs(port.fields) do if want[f.name] then fields[f.name]=f end end
    end
    for n in pairs(want) do if not fields[n] then log("MISSING input %s", n) end end
end

-- ---------------------------------------------------------------- script ---
local ST_WAIT, ST_JUMP, ST_KICK, ST_SETTLE = 0,1,2,3
local st, st_frame = ST_WAIT, 0
local cycles, connects, dmg_dealt, dmg_taken = 0, 0, 0, 0
local answered_upcut, answered_block, unanswered = 0, 0, 0
local last_p2hp, last_p1hp = 161, 161
local cyc_hit, cyc_taken, cyc_kahnact = false, false, "-"
local p1_forward = "R"
local ground_y = nil

local function set_state(s) st, st_frame = s, frame end

local function finish_cycle()
    cycles = cycles + 1
    local verdict
    if cyc_hit and not cyc_taken then
        connects = connects + 1; unanswered = unanswered + 1; verdict = "CONNECTED (unanswered)"
    elseif cyc_hit and cyc_taken then
        connects = connects + 1; answered_block = answered_block + 1; verdict = "traded"
    elseif cyc_taken then
        answered_upcut = answered_upcut + 1; verdict = "ANSWERED (he hit me)"
    else
        answered_block = answered_block + 1; verdict = "stuffed/blocked"
    end
    log("cycle %2d  %-22s kahn_hp=%-4d my_hp=%-4d gap=%-4d kahn_last=%s",
        cycles, verdict, r16(A.p2_bar), r16(A.p1_bar), gap(), cyc_kahnact)
    cyc_hit, cyc_taken, cyc_kahnact = false, false, "-"
end

local function press(name)
    if fighting_frame == 0 then
        if charsel_frame == 0 then
            if name=="Coin 1" then return frame>=700 and frame<980 and (frame%80)<20 end
            if name=="1 Player Start" then return frame>=1000 and frame<1080 end
            return false
        end
        if name=="1 Player Start" and confirm>0 then return frame>=confirm and frame<confirm+45 end
        return false
    end
    local fwd = (p1_forward=="L") and "P1 Left" or "P1 Right"
    if st == ST_JUMP then
        -- hold up+forward for the launch window only
        if name=="P1 Up" then return frame - st_frame < 6 end
        if name==fwd    then return frame - st_frame < 10 end
        return false
    end
    if st == ST_KICK then
        if name=="P1 High Kick" then return (frame - st_frame) < 4 end
        return false
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame==1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache()
        log("---- jump-in repro: P1=%d vs Kahn, diff=%d, %d cycles ----", CHAR, DIFF, CYCLES)
        return
    end
    if not space then return end

    local gs = r16(A.gstate)
    if gs==GS_PSEL and charsel_frame==0 then charsel_frame=frame end
    if gs==GS_FIGHTING and fighting_frame==0 then
        fighting_frame=frame
        local a=r32(A.p1_obj); ground_y = a~=0 and r16(a+O.oypos) or 0
        if SEED then w32(A.rand, SEED) end
        log("fight start  ground_y=%d gap=%d", ground_y or -1, gap())
    end
    if charsel_frame>0 and fighting_frame==0 then
        w16(A.p1_state,1); w16(A.p2_state,0)
        w16(A.p1_char,CHAR); w16(A.p2_char,FT_KAHN)
        w16(A.curback,KAHN_ARENA); w16(A.map_position,14); w16(A.battle_num,15)
        if confirm==0 and frame-charsel_frame>90 then confirm=frame end
    end
    w16(A.diff, DIFF)

    for n,f in pairs(fields) do f:set_value(press(n) and 1 or 0) end
    if fighting_frame==0 then return end

    p1_forward = (wx(r32(A.p1_obj)) < wx(r32(A.p2_obj))) and "R" or "L"

    -- damage bookkeeping
    local p2hp, p1hp = r16(A.p2_bar), r16(A.p1_bar)
    if p2hp < last_p2hp then
        dmg_dealt = dmg_dealt + (last_p2hp-p2hp); cyc_hit = true
    end
    if p1hp < last_p1hp then
        dmg_taken = dmg_taken + (last_p1hp-p1hp); cyc_taken = true
        cyc_kahnact = string.format("act_%03x", act(A.p2_proc))
    end
    last_p2hp, last_p1hp = p2hp, p1hp

    -- keep the fight alive so a long sample is possible
    if p2hp <= 20 then w16(A.p2_bar, 161); last_p2hp = 161 end
    if p1hp <= 20 then w16(A.p1_bar, 161); last_p1hp = 161 end

    if cycles >= CYCLES then
        local pct = cycles>0 and math.floor(100*connects/cycles) or 0
        log("")
        log("RESULT connect_rate=%d%%  (%d/%d)  unanswered=%d  answered=%d  traded/stuffed=%d",
            pct, connects, cycles, unanswered, answered_upcut, answered_block)
        log("RESULT dmg_to_kahn=%d  dmg_to_me=%d", dmg_dealt, dmg_taken)
        manager.machine:exit(); return
    end

    -- state machine: wait at range -> jump -> kick -> settle
    if st == ST_WAIT then
        if not p1_airborne() and gap() > 120 and frame - st_frame > 24 then
            set_state(ST_JUMP)
        elseif gap() <= 120 and frame - st_frame > 40 then
            -- too close to jump in from: back off is not scripted, just wait
            set_state(ST_JUMP)
        end
    elseif st == ST_JUMP then
        if p1_airborne() and gap() < 100 then set_state(ST_KICK)
        elseif frame - st_frame > 70 then set_state(ST_SETTLE) end
    elseif st == ST_KICK then
        if frame - st_frame > 30 then set_state(ST_SETTLE) end
    elseif st == ST_SETTLE then
        if not p1_airborne() and frame - st_frame > 20 then
            finish_cycle(); set_state(ST_WAIT)
        elseif frame - st_frame > 120 then
            finish_cycle(); set_state(ST_WAIT)
        end
    end
end)

emu.register_stop(function()
    if cycles < CYCLES then
        log("RESULT incomplete: %d/%d cycles, connects=%d", cycles, CYCLES, connects)
    end
    if fh then fh:close() end
end)
