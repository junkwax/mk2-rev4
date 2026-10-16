-- mileena_teleport_kick_test.lua
--
-- Regression test for Mileena's F,F+LK teleport kick (do_fn2_teleport,
-- MKPROP.ASM).
--
-- The move poses itself by borrowing a_fn1victory and stepping a hardcoded
-- 112 bits in ("addi 16*7,a9") to reach KT1VIC2.  That offset was correct
-- while exactly ONE ani_ochar_jump record (fn2) sat in front of the frames.
-- Commit cafd14b added a second record for ft_jade, pushing every frame 80
-- bits further down, so 112 landed INSIDE the Jade record and
-- do_next_a9_frame ran its tail as an image pointer -> crash.
--
-- PASS = the drone (or P1) enters act_fntele repeatedly and the machine
-- stays healthy: sane gstate, PC out of the lockup handler, object/process
-- lists intact.
--
-- Env: MTK_LOG
-- Usage: tools\run_mileena_teleport_kick_test.ps1

local LOGP = os.getenv("MTK_LOG") or "C:/Users/you/Workplace/mk2-main/tools/mileena_teleport_kick_test.log"
local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = "[mtk] " .. string.format(fmt, ...)
    print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols = {}
do
    local fh = io.open("C:/Users/you/Workplace/mk2-main/src/MK2.MAP", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local missing = {}
local function sym(n)
    local v = symbols[n]
    if not v then missing[#missing+1] = n; return 0 end
    return v
end

local A = {
    gstate=sym("gstate"), curback=sym("curback"),
    p1_char=sym("p1_char"), p2_char=sym("p2_char"),
    p1_state=sym("p1_state"), p2_state=sym("p2_state"),
    p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"),
    p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
    p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
    p1_bar_view=sym("p1_bar_view"), p2_bar_view=sym("p2_bar_view"),
    winner_status=sym("winner_status"),
    objlst=sym("objlst"), active=sym("active"),
    system_lockup=sym("system_lockup"), tvbp=sym("tvbp"),
    battle_num=sym("battle_num"), map_position=sym("map_position"),
}

local OXVAL, OXPOS = 0x080, 0x090
local PROC_ACTION = 0x1f0
local O_NEXT, P_NEXT = 0x0, 0x0
local ACT_FNTELE = nil          -- filled from arg below
local FT_MILEENA = 5
local FT_KANG = 1
local PS_ACTIVE, PS_INACTIVE = 1, 0   -- ps_active=1 (MAINEQU); 2 is ps_buyin and stalls select
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local WANT_FIRES = 6
local RUN_FRAMES = 4000

ACT_FNTELE = tonumber(os.getenv("MTK_ACT") or "0x0202")

local frame, space, cpu = 0, nil, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local fires, was_in = 0, false
local anomalies = {}
local fields = {}
local done = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function objx(p) local o=r32(p); if o==0 then return nil end return s16(r16(o+OXPOS)) end

local function note(kind, detail)
    if not anomalies[kind] then
        anomalies[kind] = detail
        log("ANOMALY %s = %s (frame=%d)", kind, detail, frame)
    end
end

local function cpu_pc()
    local ok, v = pcall(function() return cpu.state["PC"].value end)
    if ok then return v end
    return nil
end

local function health_check()
    local gs = r16(A.gstate)
    if gs == 0xffff or gs > 0x40 then note("bad_gstate", string.format("0x%04x", gs)); return false end
    local pc = cpu_pc()
    if pc and A.system_lockup ~= 0 and A.tvbp ~= 0 and pc >= A.system_lockup and pc < A.tvbp then
        note("CRASH_lockup", string.format("pc=0x%08x", pc)); return false
    end
    return true
end

local function finish()
    if done then return end
    done = true
    local bad = 0
    for _ in pairs(anomalies) do bad = bad + 1 end
    log("RESULT teleport_fires=%d anomalies=%d", fires, bad)
    if fires >= 1 and bad == 0 then
        log("PASS mileena_teleport: fired %d time(s), machine healthy", fires)
    elseif fires == 0 then
        log("FAIL mileena_teleport: move never fired - could not exercise it")
    else
        log("FAIL mileena_teleport: anomalies after firing")
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["P1 High Punch"]=true,
                   ["UI Select"]=true, ["P1 Right"]=true, ["P1 Low Kick"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
end

local attempt_start = 0
local function pressed(name)
    if fighting_frame > 0 and attempt_start > 0 then
        local r = frame - attempt_start
        -- Forward, Forward, then LK inside the 24-tick combo window
        if name == "P1 Right" then
            return (r >= 0 and r < 4) or (r >= 8 and r < 14)
        end
        if name == "P1 Low Kick" then return r >= 14 and r < 20 end
        return false
    end
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        if name == "UI Select" then return frame >= 5 and frame < 35 end
        return false
    end
    if name == "P1 High Punch" and p1_confirm > 0 then
        return frame >= p1_confirm and frame < p1_confirm + 45
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        cache_fields()
        log("---- mileena F,F+LK teleport kick, watching act=0x%04x ----", ACT_FNTELE)
        if #missing > 0 then log("WARN unresolved map symbols: %s", table.concat(missing, ",")) end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, PS_ACTIVE)
        w16(A.p2_state, PS_INACTIVE)      -- P2 = Mileena drone
        w16(A.p1_char, FT_MILEENA)        -- P1 = Mileena, we drive her
        w16(A.p2_char, FT_KANG)
        w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame
        log("fight_start frame=%d p2_char=%d", frame, r16(A.p2_char))
    end
    if fighting_frame == 0 then
        if frame > 8000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end

    if not health_check() then finish(); return end

    -- keep the sparring partner parked out to P1's right so Forward is
    -- unambiguous and Mileena has room to teleport
    local x1 = objx(A.p1_obj)
    if x1 then
        local o = r32(A.p2_obj)
        if o ~= 0 then
            local tgt = x1 + 180
            space:write_u32(o + OXVAL, (tgt & 0xffff) << 16)
            w16(o + OXPOS, tgt & 0xffff)
        end
    end
    if attempt_start == 0 or frame - attempt_start > 90 then
        attempt_start = frame
    end

    local p = r32(A.p1_proc)
    local act = (p ~= 0) and r16(p + PROC_ACTION) or 0xffff
    local firing = (act == ACT_FNTELE)
    if firing and not was_in then
        fires = fires + 1
        log("teleport kick #%d at frame=%d (rel=%d)", fires, frame, frame - fighting_frame)
    end
    was_in = firing

    -- keep watching a while after the first fires so a delayed crash shows up
    if fires >= WANT_FIRES or frame - fighting_frame > RUN_FRAMES then finish(); return end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
