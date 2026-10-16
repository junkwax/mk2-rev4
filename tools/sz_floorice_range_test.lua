-- sz_floorice_range_test.lua
--
-- Sweeps the distance at which Sub-Zero's ground freeze (D,B+LK) actually
-- connects, and prints the reach in pixels.
--
-- Reported bug: "if you jump kick the opponent and then ground freeze it
-- completely misses, even though you see the sprite touch him."  A jump kick
-- knocks the victim back, so the freeze has to reach further than a point
-- blank one - and stk_floor_ice's box had been retuned from the shipped
-- 09dh/080h/060h/010h to 080h/080h/090h/028h.  strike_check builds the box as
-- [oxpos + x_offset - x_size, oxpos + x_offset], so that edit moved it from
-- +61..+157 in front of the ice object to -16..+128: it gained 77px BEHIND
-- the ice, where nobody stands, and lost the front 29px - the far end of the
-- drawn puddle.  Hence "visibly touching, no hit".
--
-- The test pins the pair at a fixed gap, drives the real D,B+LK input, and
-- watches for the victim entering act_slipping.  Gaps are swept coarse to
-- fine.  Note sz_lo_kick gates on l_pud (get_tsl < 040h*3 aborts the move),
-- so trials must be at least ~200 frames apart or the move never comes out -
-- casts are counted separately from hits so a gated trial can't read as a
-- miss.
--
-- Env: ICE_LOG
-- Usage: tools\run_sz_floorice_range_test.ps1

local LOGP = os.getenv("ICE_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/sz_floorice_range_test.log"
local logfh = io.open(LOGP, "a")
local function log(fmt, ...)
    local line = "[ice] " .. string.format(fmt, ...)
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
local function sym(n) return symbols[n] or 0 end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_proc = sym("p1_proc"), p2_proc = sym("p2_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), diff = sym("diff"),
    battle_num = sym("battle_num"), map_position = sym("map_position"),
    f_freeze_timer = sym("f_freeze_timer"), timer = sym("clock_val"),
}
for _, n in ipairs({"gstate","p1_obj","p2_obj","p1_proc","p2_proc","p1_char","p2_char"}) do
    if A[n] == 0 then log("MISSING SYMBOL %s - results are worthless", n) end
end

local OXVAL = 0x080
local PROC_ACTION = 0x1f0
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_SUBZERO, FT_REPTILE = 8, 9
local ACT_FLOOR_ICE = 0x0134       -- MAINEQU: throw ice on the floor
local ACT_SLIPPING  = 0x060e       -- MAINEQU: slip sliding away (on ice)

-- Sub-Zero is parked here in world space; the victim goes at SZ_X + gap.
-- Both stay well clear of the screen edges because sz_lo_kick refuses to
-- cast when get_his_dfe says either fighter is within 060h of an edge.
local SZ_X = 260
local GAPS = { 0x50, 0x60, 0x70, 0x80, 0x90, 0xa0, 0xb0, 0xc0, 0xd0, 0xe0 }
local TRIAL_FRAMES = 300           -- > 040h*3 ticks of l_pud cooldown
local CAST_WINDOW  = 200           -- watch this long after the cast starts

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local trial, trial_start = 1, 0
local cast_seen, hit_seen, cast_frame = false, false, 0
local fields, results, done = {}, {}, false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function proc_act(p) local q = r32(p); if q == 0 then return 0xffff end return r16(q + PROC_ACTION) end
local function setx(p, x)
    local o = r32(p); if o == 0 then return end
    space:write_u32(o + OXVAL, (x & 0xffff) << 16)
end
local function getx(p)
    local o = r32(p); if o == 0 then return nil end
    return s16(r32(o + OXVAL) >> 16)
end

local function finish()
    if done then return end
    done = true
    local reach, gated = 0, 0
    for _, r in ipairs(results) do
        log("RESULT gap=%3d (0x%02x)  cast=%s  froze=%s",
            r.gap, r.gap, r.cast and "yes" or "NO", r.hit and "YES" or "no")
        if not r.cast then gated = gated + 1 end
        if r.cast and r.hit and r.gap > reach then reach = r.gap end
    end
    log("ground-freeze reach = %d px (0x%02x); %d trial(s) never cast", reach, reach, gated)
    -- Shipped box is [+61,+157] in front of the ice object. The ice lands a
    -- little ahead of Sub-Zero, so the reach measured fighter-to-fighter is
    -- larger still. A jump kick leaves the pair around 0a0h-0c0h apart; if
    -- the freeze cannot reach that, the reported bug is present.
    if gated >= #results then
        log("FAIL ice-range: the move never came out - harness problem, not a result")
    elseif reach >= 0xa0 then
        log("PASS ice-range: freeze still connects at %d px, past knockback range", reach)
    else
        log("FAIL ice-range: freeze dies at %d px - it cannot reach a knocked-back victim", reach)
    end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true, ["2 Players Start"]=true,
                   ["P1 High Punch"]=true, ["P1 Low Kick"]=true,
                   ["P1 Left"]=true, ["P1 Right"]=true, ["P1 Down"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
    for n in pairs(want) do if not fields[n] then log("note: no input field %s", n) end end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm > 0 then
            return frame >= p1_confirm and frame < p1_confirm + 45
        end
        return false
    end
    -- in-fight: D, B+LK on a fixed schedule inside each trial
    local r = frame - trial_start
    if r >= 40 and r < 48 then return name == "P1 Down" end
    if r >= 48 and r < 70 then
        return name == "P1 Left" or (r >= 56 and name == "P1 Low Kick")
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- ground freeze range sweep: P1=SubZero P2=Reptile(inert) ----")
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end

    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 0)
        w16(A.p1_char, FT_SUBZERO); w16(A.p2_char, FT_REPTILE); w16(A.curback, 0)
        if A.map_position ~= 0 then w16(A.map_position, 0) end
        if A.battle_num ~= 0 then w16(A.battle_num, 1) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end

    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; trial_start = frame
        log("fight start frame=%d, trial 1 gap=0x%02x", frame, GAPS[1])
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("ERROR never reached fight"); finish() end
        return
    end

    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    if A.winner_status ~= 0 then w16(A.winner_status, 0) end
    if A.f_freeze_timer ~= 0 then w16(A.f_freeze_timer, 1) end

    local gap = GAPS[trial]
    local a1, a2 = proc_act(A.p1_proc), proc_act(A.p2_proc)

    -- Hold the geometry for the WHOLE trial. The victim is the CPU drone, so
    -- releasing the pin at cast time just lets him walk out of (or into) the
    -- puddle and the measured gap stops meaning anything. Sub-Zero is only
    -- pinned until he commits: after that he is in do_proj_sitting_duck and
    -- stays put on his own.
    if not cast_seen then setx(A.p1_obj, SZ_X) end
    if not hit_seen then setx(A.p2_obj, SZ_X + gap) end

    if not cast_seen and a1 == ACT_FLOOR_ICE then
        cast_seen, cast_frame = true, frame
    end
    if cast_seen and not hit_seen and a2 == ACT_SLIPPING then
        hit_seen = true
        log("gap 0x%02x: FROZE %d frames after cast", gap, frame - cast_frame)
    end

    if frame - trial_start > TRIAL_FRAMES then
        results[#results+1] = { gap = gap, cast = cast_seen, hit = hit_seen }
        log("---- gap 0x%02x done: cast=%s froze=%s ----",
            gap, cast_seen and "yes" or "no", hit_seen and "yes" or "no")
        trial = trial + 1
        if trial > #GAPS then finish(); return end
        trial_start = frame
        cast_seen, hit_seen, cast_frame = false, false, 0
    end

    if frame > 40000 then log("ERROR backstop"); finish() end
end)
