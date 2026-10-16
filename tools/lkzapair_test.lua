-- lkzapair_test.lua
-- PROVE lkzapair (MAINEQU.ASM): Liu Kang's fireball, hitting an AIRBORNE man,
-- runs the anti-juggle separator every other airborne hit runs
-- (no_unlimited_airhits in ar_lkzap, MKREACT.ASM).  Retail's ar_lkzap is
-- generic_airborn_hit's body minus that call.
--
-- 2P, P1 Liu Kang vs P2 Reptile, both driven.  Liu Kang throws the HIGH
-- fireball (F,F+HP) at a fixed beat; Reptile jumps straight up at an offset
-- from it so the ball meets him in the air.  Two groups:
--   fresh  his hit count is left alone - an opening hit, which must NOT
--          separate (p_hit <= 3);
--   deep   p_hit is SEEDED to 4 every tick until the hit lands, so the same
--          hit is deep in a string and MUST separate.
-- The separator transfers the ATTACKER to attacker_getting_separated, which on
-- the ground slides him away at 7px/tick - so the verdict is Liu Kang's x:
-- moved >= 15px away from the victim within 40 ticks of the hit = separated.
-- The rig stops pinning him once the ball is out.
--
-- PASS: at least one airborne hit in each group; every fresh one did not
-- separate, every deep one did.  LZA_NEG=1 NOPs the separator call in memory
-- and keeps the expectations, so the deep trials must FAIL.
--
-- env: LZA_LOG, LZA_MAP
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local LOGP = os.getenv("LZA_LOG") or (ROOT .. "/tools/lkzapair_test.log")
local NEG = (os.getenv("LZA_NEG") or "0") ~= "0"
local logfh = assert(io.open(LOGP, "w"))
local function log(fmt, ...)
    local s = "[lkzap] " .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
do local fh = assert(io.open(os.getenv("LZA_MAP") or (ROOT .. "/src/mk2.map"), "r"))
  for line in fh:lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
      if symbols[n] == nil then symbols[n] = tonumber(a, 16) end end end
  fh:close() end
local need = { "gstate", "curback", "p1_char", "p2_char", "p1_state", "p2_state",
  "p1_obj", "p2_obj", "p1_proc", "p2_proc", "p1_bar", "p2_bar", "p1_bar_view",
  "p2_bar_view", "winner_status", "f_freeze_timer" }
local A, miss = {}, {}
for _, n in ipairs(need) do A[n] = symbols[n]; if not A[n] then miss[#miss+1] = n end end

local OXVAL, OXPOS, OYPOS = 0x080, 0x090, 0x0b0
local P_ACTION, P_FLAGS, P_HIT = 0x1f0, 0x210, 0x100 + 0x270
local PB_REACTING = 2
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_REPTILE = 1, 9
local ACT_LKZAP = 0x0003

local LK_X, GAP = 200, 170
local HP_AT = 56                  -- F 40..44, F 48..52, HP 56..62
local TRIALS = {}
for _, g in ipairs({ "fresh", "deep" }) do
    for _, j in ipairs({ -16, -10, -4, 2, 8 }) do
        TRIALS[#TRIALS + 1] = { name = string.format("%s%+d", g, j), group = g, j = j }
    end
end
local TRIAL_FRAMES = 330

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local ti, tstart = 1, 0
local fields, done = {}, false
local FLOOR_Y = 0
local cur, results = nil, {}

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) v = v & 0xffff; return v >= 0x8000 and v - 0x10000 or v end
local function pact(p) local q = r32(p); if q == 0 then return 0xffff end return r16(q + P_ACTION) end
local function reacting(p) local q = r32(p); return q ~= 0 and (r16(q + P_FLAGS) & (1 << PB_REACTING)) ~= 0 end
local function setx(p, x) local o = r32(p); if o ~= 0 then space:write_u32(o + OXVAL, (x & 0xffff) << 16) end end
local function getx(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OXPOS)) end
local function gety(p) local o = r32(p); if o == 0 then return nil end return s16(r16(o + OYPOS)) end

local function finish()
    if done then return end
    done = true
    local ok, why, n = true, {}, { fresh = 0, deep = 0 }
    for _, t in ipairs(TRIALS) do
        local r = results[t.name]
        if not r or not r.hit_at then
            log("RESULT %-8s no hit (cast=%s) - NO VERDICT", t.name, r and tostring(r.cast) or "?")
        elseif r.h <= 0 then
            log("RESULT %-8s hit ON THE GROUND - not an airborne hit, NO VERDICT", t.name)
        else
            n[t.group] = n[t.group] + 1
            local sep = (r.away or 0) >= 15
            local want = (t.group == "deep")
            local good = sep == want
            if not good then ok = false; why[#why + 1] = string.format("%s %s", t.name,
                sep and "SEPARATED on an opening hit" or "did NOT separate deep in a string") end
            log("RESULT %-8s hit %dpx up, p_hit before %d  Liu Kang moved %+d px away  %s  %s",
                t.name, r.h, r.phit, r.away or 0, sep and "SEPARATED" or "stayed", good and "ok" or "WRONG")
        end
    end
    if n.fresh == 0 then ok = false; why[#why + 1] = "no airborne FRESH hit - the control is missing" end
    if n.deep == 0 then ok = false; why[#why + 1] = "no airborne DEEP hit - nothing was tested" end
    if NEG then
        log("%s lkzapair (NEGATIVE control: separator NOPd - FAIL is the expected result)%s",
            ok and "PASS" or "FAIL", ok and "" or (": " .. table.concat(why, "; ")))
    else
        log("%s lkzapair%s", ok and "PASS" or "FAIL", ok and "" or (": " .. table.concat(why, "; ")))
    end
    logfh:close(); manager.machine:exit()
end

-- ar_lkzap: callr (0D3Fh + disp) then movi 038000h,a0 / movi -060000h,a1 /
-- movi 07000h,a2 - the 07000h gravity is what tells it from
-- attacker_getting_separated's 08000h and generic_airborn_hit.
local function locate()
    local reg = manager.machine.memory.regions[":maincpu"]
    local tail = { 0xE0, 0x09, 0x00, 0x80, 0x03, 0x00,  0xE1, 0x09, 0x00, 0x00, 0xFA, 0xFF }
    local hits = {}
    for i = 0, reg.size - 32, 2 do
        if reg:read_u8(i) == 0x3F and reg:read_u8(i + 1) == 0x0D then
            local okp = true
            for k = 1, #tail do if reg:read_u8(i + 3 + k) ~= tail[k] then okp = false; break end end
            if okp then
                -- movi 07000h,a2: short form 09C2 7000, or long 09E2 00007000
                local w = reg:read_u8(i + 16) | (reg:read_u8(i + 17) << 8)
                local v = reg:read_u8(i + 18) | (reg:read_u8(i + 19) << 8)
                if (w == 0x09C2 and v == 0x7000) or (w == 0x09E2 and v == 0x7000) then hits[#hits + 1] = i end
            end
        end
    end
    return reg, hits
end

local function cache_fields()
    local want = { "Coin 1", "Coin 2", "1 Player Start", "2 Players Start", "P1 High Punch",
                   "P1 Right", "P2 High Punch", "P2 Up" }
    local w = {}
    for _, nm in ipairs(want) do w[nm] = true end
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if w[f.name] then fields[f.name] = f end end
    end
    local m = {}
    for _, nm in ipairs(want) do if not fields[nm] then m[#m + 1] = nm end end
    return m
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then return frame >= 200 and frame < 1000 and (frame % 80) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        if name == "2 Players Start" then return frame >= 1040 and frame < 1140 end
        return false
    end
    if fighting_frame == 0 then
        if p1_confirm > 0 then
            if name == "P1 High Punch" then return frame >= p1_confirm and frame < p1_confirm + 45 end
            if name == "P2 High Punch" then return frame >= p1_confirm + 70 and frame < p1_confirm + 115 end
        end
        return false
    end
    if frame < tstart then return false end
    local r = frame - tstart
    if name == "P1 Right" then return (r >= 40 and r < 44) or (r >= 48 and r < 52) end
    if name == "P1 High Punch" then return r >= HP_AT and r < HP_AT + 6 end
    local t = TRIALS[ti]
    if name == "P2 Up" and t then local s = HP_AT + t.j; return r >= s and r < s + 4 end
    return false
end

emu.register_frame(function()
    if done then return end
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        if #miss > 0 then log("FAIL lkzapair: missing symbols %s", table.concat(miss, ",")); return finish() end
        local m = cache_fields()
        if #m > 0 then log("FAIL lkzapair: missing inputs %s", table.concat(m, ",")); return finish() end
        local reg, hits = locate()
        if #hits ~= 1 then
            log("FAIL lkzapair: the separator call in ar_lkzap found %d times, want 1 - an lkzapair 0 ROM has none", #hits)
            return finish()
        end
        if NEG then
            reg:write_u8(hits[1], 0x00); reg:write_u8(hits[1] + 1, 0x03)
            reg:write_u8(hits[1] + 2, 0x00); reg:write_u8(hits[1] + 3, 0x03)
            log("NEGATIVE: the separator call NOPd at :maincpu+%x", hits[1])
        else
            log("separator call present in ar_lkzap at :maincpu+%x", hits[1])
        end
    end
    for nm, f in pairs(fields) do f:set_value(pressed(nm) and 1 or 0) end

    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_REPTILE); w16(A.curback, 0)
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
    end
    if gs == GS_FIGHTING and fighting_frame == 0 then
        fighting_frame = frame; tstart = frame + 60
        log("fight at %d", frame)
    end
    if fighting_frame == 0 then
        if frame > 6000 then log("FAIL lkzapair: never reached a fight"); finish() end
        return
    end
    w16(A.p1_bar, MAX_HP); w16(A.p1_bar_view, MAX_HP)
    w16(A.p2_bar, MAX_HP); w16(A.p2_bar_view, MAX_HP)
    w16(A.winner_status, 0); w16(A.f_freeze_timer, 1)
    if frame < tstart then return end
    local t = TRIALS[ti]
    if frame == tstart then
        FLOOR_Y = gety(A.p2_obj) or 0
        cur = { cast = false }
    end

    local a1 = pact(A.p1_proc)
    if a1 == ACT_LKZAP and not cur.cast then cur.cast = true end
    if not cur.cast then setx(A.p1_obj, LK_X) end
    if not cur.hit_at then setx(A.p2_obj, LK_X + GAP) end
    local q2 = r32(A.p2_proc)
    if not cur.hit_at then
        if t.group == "deep" and q2 ~= 0 then w16(q2 + P_HIT, 4) end
        if reacting(A.p2_proc) then
            cur.hit_at = frame
            cur.h = FLOOR_Y - (gety(A.p2_obj) or FLOOR_Y)
            cur.phit = q2 ~= 0 and r16(q2 + P_HIT) or -1
            cur.x0 = getx(A.p1_obj); cur.vx = getx(A.p2_obj)
            log("  %s: hit at r=%d, %dpx up, p_hit now %d", t.name, frame - tstart, cur.h, cur.phit)
        end
    elseif frame - cur.hit_at <= 40 then
        local x = getx(A.p1_obj)
        if x and cur.x0 then
            local away = (cur.vx > cur.x0) and (cur.x0 - x) or (x - cur.x0)
            if away > (cur.away or -999) then cur.away = away end
        end
    end
    if frame - tstart >= TRIAL_FRAMES then
        results[t.name] = cur
        ti = ti + 1
        if ti > #TRIALS then return finish() end
        tstart = frame + 1
    end
    if frame > 20000 then log("FAIL lkzapair: backstop"); finish() end
end)
