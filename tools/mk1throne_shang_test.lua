-- mk1throne_shang_test.lua
--
-- THE THRONE ROOM (MK1), curback 01Ch: prove that SHANG TSUNG ON THE THRONE
-- behaves the way MK1's does - he turns his head to follow the camera while
-- the round is being fought, and applauds once it is decided.
--
-- WATCHING.  There is no animation lane.  Every mk1t_sh_rate ticks the stage
-- reads plane 1's camera and picks one of seven poses by how far that camera
-- is from mk1t_sh_mid, mk1t_sh_step pixels to a step, clamped at mk1t_sh_maxb,
-- with everything at or left of mk1t_sh_flat taking bucket 3 outright.
--
-- CLAPPING.  Once winner_status is non-zero he runs mk1t_sh_clap - MK1's own
-- four-step lane, which loops.
--
-- WHAT THIS CHECKS, and why it is not circular: the rig recomputes the bucket
-- here, in Lua, from the constants in src/MK1THRNB.ASM, and compares the
-- resulting table ROW with mk1t_sh_shown - the row the stage actually put on
-- screen.  The ASM's repeated-subtraction divide, its clamp and its flat
-- branch are all independent of this arithmetic, so a wrong one shows up.
-- After the win it requires every pose shown to come from the clap table and
-- every one of its steps to appear.
--
-- A SAMPLE IS ONLY TAKEN WHEN THE CAMERA HAS BEEN STILL for a full re-pick
-- plus slack - the stage re-picks every mk1t_sh_rate ticks, so a moving camera
-- is legally one bucket behind and comparing there would fail a correct build.
--
-- env: MK2_SHANG_TAG (log tag), MK2_SHANG_NEG (the crossed control)

local frame = 0
local ROOT = "C:/Users/you/Workplace/mk2-main"
local TAG = os.getenv("MK2_SHANG_TAG") or "base"
local LOG_PATH = ROOT .. "/tools/mk1throne_shang_test_" .. TAG .. ".log"
local logfh = io.open(LOG_PATH, "w")
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end

local symbols, fatal = {}, false
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if not fh then print("[shang] FATAL no src/mk2.map"); fatal = true
    else
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(n)
    local v = symbols[n]
    if not v then print("[shang] FATAL missing map symbol " .. n); fatal = true end
    return v
end

-- the generated constants, read out of the ASM rather than typed here
local K = {}
do
    local fh = io.open(ROOT .. "/src/MK1THRNB.ASM", "r")
    if not fh then print("[shang] FATAL no src/MK1THRNB.ASM"); fatal = true
    else
        for line in fh:lines() do
            local n, v = line:match("^mk1t_sh_(%w+)%s+%.set%s+(-?%d+)")
            if n then K[n] = tonumber(v) end
        end
        fh:close()
    end
end
for _, n in ipairs({"mid", "step", "maxb", "flat", "rate", "x", "y",
                    "slots", "cn", "crate", "cframes", "cwait"}) do
    if not K[n] then print("[shang] FATAL no mk1t_sh_" .. n .. " in MK1THRNB.ASM"); fatal = true end
end

local A = { gstate = sym("gstate"), curback = sym("curback"),
            worldtlx = sym("worldtlx"), worldtlx4 = sym("worldtlx4"),
            winner = sym("winner_status"),
            shown = sym("mk1t_sh_shown"), track = sym("mk1t_sh_track"),
            clap = sym("mk1t_sh_clap"),
            p1bar = sym("p1_bar"), p2bar = sym("p2_bar"),
            p1matchw = sym("p1_matchw") }
-- MK2_SHANG_FINISH: P1 already holds one match win when the round is forced, so
-- it is match-deciding and goes to FINISH HIM.  He must NOT applaud that round -
-- not at FINISH HIM, and not when play4 writes the winner back afterwards.
local FINISH = (os.getenv("MK2_SHANG_FINISH") or "") ~= ""
local saw_finish = false
local FULL, WIN_AT, END_AT = 0xA1, 2100, 3200
local GS_PSEL, GS_FIGHTING = 4, 2
local STAGE = 0x1c
-- one pose is mk1t_sh_slots .long records, and these are BIT addresses
local POSE = 32 * (K.slots or 4)

local space, fields = nil, {}
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
-- w16 MUST be declared after `space`: defined earlier it captures the GLOBAL
-- of that name, which is nil, and every write throws once the fight starts.
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end; return v end
local function wx(a) return s16(r32(a) >> 16) end

-- MK1's pick, recomputed here.  MK2_SHANG_NEG crosses it by one bucket: the
-- control, which must FAIL - a rig that cannot fail has not been calibrated.
local NEG = (os.getenv("MK2_SHANG_NEG") or "") ~= ""
local function want_bucket(cam)
    local b
    if cam <= K.flat then
        b = 3
    else
        local d = K.mid - cam
        if d < 0 then d = -d end
        b = d // K.step
        if b > K.maxb then b = K.maxb end
    end
    if NEG then b = (b + 1) % (K.maxb + 1) end
    return b
end

local function cache_fields()
    local want = { ["UI Select"] = true, ["Coin 1"] = true, ["Coin 2"] = true,
        ["1 Player Start"] = true, ["2 Players Start"] = true,
        ["P1 High Punch"] = true, ["P2 High Punch"] = true,
        ["P1 Left"] = true, ["P1 Right"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end
local function press(name, on)
    local f = fields[name]
    if f then f:set_value(on and 1 or 0) end
end

local select_frame, fight_frame = 0, 0

-- THE APPLAUSE: mk1t_shang sends triple_sndtab2 $68 as the clap starts, which
-- reaches the latch as DCS TRACK $0118-$011A (one per channel), not as $68.
-- Paired the same rolling way as iceooo_test.lua; the tap handle is KEPT, or
-- it is collected and never fires again.
local SND_PORT, SND_LO, SND_HI = 0x01d01030, 0x01d00000, 0x01d01fff
local snd_hi, snd_tap, applause = nil, nil, {}
-- every code sent once the round is decided, so whatever CUTS the applause
-- (a later send on the same channel) is in the log beside it
local snd_after = nil
local function on_sound(offset, data, mask)
    if offset ~= SND_PORT then return data end
    local w = data & 0xffff
    if (w & 0xff00) ~= 0xff00 then snd_hi = nil; return data end
    if snd_hi == nil then
        if (w & 0xff) <= 0x07 then snd_hi = w & 0xff end
        return data
    end
    local code = (snd_hi << 8) | (w & 0xff); snd_hi = nil
    if snd_after then
        print(string.format("[shang] frame=%d +%d sound %04X", frame, frame - snd_after, code))
    end
    if code >= 0x0118 and code <= 0x011A then
        applause[#applause + 1] = frame
        print(string.format("[shang] frame=%d applause track %04X", frame, code))
    end
    return data
end
local last_cam, still, samples, bad = nil, 0, 0, 0
local seen = {}
local last_clap, clap_n, clap_bad, clap_steps = nil, 0, 0, {}
local clap_first = nil
-- the first WATCHING pose after the clap: his arms back on the chair.  It has
-- to come as the lane ends, not at the next round's rebuild (MK1 - and the
-- first cut here - froze him on the last clap frame until teardown).
local back_rel = nil

emu.register_frame_done(function()
    frame = frame + 1
    if fatal then
        print("[shang] RESULT FAIL reason=setup")
        logfh:close(); manager.machine:exit(); return
    end
    if not space then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        snd_tap = space:install_write_tap(SND_LO, SND_HI, "shang_snd", on_sound)
    end
    local gs = r16(A.gstate)

    if fight_frame == 0 then
        local k = frame % 60
        press("Coin 1", frame > 120 and frame < 400 and k < 4)
        press("Coin 2", frame > 120 and frame < 400 and k >= 8 and k < 12)
        press("1 Player Start", frame > 200 and frame < 500 and k >= 20 and k < 24)
        press("2 Players Start", frame > 200 and frame < 500 and k >= 30 and k < 34)
        press("P1 High Punch", frame > 500 and frame < 640 and k < 4)
        press("P2 High Punch", frame > 500 and frame < 640 and k >= 8 and k < 12)
        if gs == GS_PSEL and select_frame == 0 then select_frame = frame end
        if select_frame > 0 then
            press("P1 Left", r16(A.curback) ~= STAGE and ((frame - select_frame) % 16) < 3)
        end
        if gs == GS_FIGHTING and r16(A.curback) == STAGE then
            fight_frame = frame
            print(string.format("[shang] FIGHT on curback=%02x at frame=%d", r16(A.curback), frame))
        end
        if frame > 4000 then
            print("[shang] RESULT FAIL reason=never_reached_stage")
            logfh:close(); manager.machine:exit(); return
        end
        return
    end

    local rel = frame - fight_frame
    -- Sweep the camera across the stage in steps, standing still between each
    -- so there is a settled camera to sample.  {frames, direction}
    local LEG = { {90, ""}, {150, "P1 Right"}, {90, ""}, {150, "P1 Right"}, {90, ""},
                  {150, "P1 Right"}, {90, ""}, {200, "P1 Left"}, {90, ""},
                  {200, "P1 Left"}, {90, ""}, {200, "P1 Left"}, {90, ""},
                  {250, "P1 Left"}, {120, ""} }
    local t, dir = rel, ""
    for _, leg in ipairs(LEG) do
        if t < leg[1] then dir = leg[2]; break end
        t = t - leg[1]
    end
    press("P1 Right", dir == "P1 Right")
    press("P1 Left", dir == "P1 Left")

    -- After the sweep, force a round win so the clap can be watched.  P2 is
    -- pinned at ONE and P1 walks in and punches: writing a bar to 0 does
    -- nothing on its own, because a KO is decided when damage is applied.
    w16(A.p1bar, FULL)
    if rel < WIN_AT then
        w16(A.p2bar, FULL)
    elseif r16(A.winner) == 0 then
        if rel == WIN_AT then print(string.format("[shang] rel=%d forcing the round win%s", rel,
            FINISH and " (match-deciding: FINISH HIM)" or "")) end
        if FINISH then w16(A.p1matchw, 1) end
        if r16(A.p2bar) > 1 then w16(A.p2bar, 1) end
        press("P1 Right", (rel % 24) < 16)
        press("P1 Left", false)
        press("P1 High Punch", (rel % 24) >= 18 and (rel % 24) < 21)
    end

    local cam = wx(A.worldtlx)
    if cam == last_cam then still = still + 1 else still = 0 end
    last_cam = cam
    local won = r16(A.winner) ~= 0
    if won and not snd_after then snd_after = frame end
    if r16(A.winner) == 3 and not saw_finish then
        saw_finish = true
        print(string.format("[shang] rel=%-5d FINISH HIM (winner_status 3)", rel))
    end

    -- WATCHING: sample through each standstill, one full re-pick plus slack
    if not won and still >= K.rate + 4 and still % 4 == 0 then
        local got = r32(A.shown)
        local b = want_bucket(cam)
        local expect = A.track + POSE * b
        samples = samples + 1
        seen[b] = (seen[b] or 0) + 1
        local ok = (got == expect)
        if not ok then bad = bad + 1 end
        print(string.format("[shang] rel=%-5d cam=%-4d plane4=%-4d bucket=%d expect=%08X got=%08X %s",
            rel, cam, wx(A.worldtlx4), b, expect, got, ok and "ok" or "MISMATCH"))
    end

    -- CLAPPING: once the round is decided he must run the lane, and while it is
    -- running every pose must come from it.  A watching pose BEFORE the first
    -- clap frame is legal (the process only looks at winner_status after its
    -- own sleep, and MK1 waits mk1t_sh_cwait ticks too), and so is one AFTER
    -- the lane has run its mk1t_sh_cframes - by then the round has torn down
    -- and the stage has built him again for the next one.
    if won then
        local got = r32(A.shown)
        if got ~= last_clap then
            last_clap = got
            local step = (got - A.clap) // POSE
            local is_clap = got >= A.clap and step >= 0 and step < K.cn
            if is_clap then
                if not clap_first then clap_first = rel end
                clap_steps[step] = (clap_steps[step] or 0) + 1
                clap_n = clap_n + 1
                print(string.format("[shang] rel=%-5d WON - clap step %d", rel, step))
            elseif clap_first and rel < clap_first + K.cframes * K.crate then
                clap_bad = clap_bad + 1
                print(string.format("[shang] rel=%-5d MID-CLAP but showing %08X, not a clap pose",
                    rel, got))
            else
                if clap_first and not back_rel and got >= A.track
                   and got < A.track + POSE * (K.maxb + 1) then back_rel = rel end
                print(string.format("[shang] rel=%-5d WON, watching pose %08X (%s the clap)",
                    rel, got, clap_first and "after" or "before"))
            end
        end
    end

    if rel >= END_AT then
        local nb = 0
        for _ in pairs(seen) do nb = nb + 1 end
        local list = {}
        for b = 0, K.maxb do if seen[b] then list[#list + 1] = b .. "x" .. seen[b] end end
        print(string.format("[shang] buckets seen: %s", table.concat(list, " ")))
        local cs, csteps = {}, 0
        for st = 0, K.cn - 1 do
            cs[#cs + 1] = st .. "x" .. (clap_steps[st] or 0)
            if clap_steps[st] then csteps = csteps + 1 end
        end
        print(string.format("[shang] clap: %d pose changes, steps %s, %d not a clap pose",
            clap_n, table.concat(cs, " "), clap_bad))
        if FINISH then
            if saw_finish and clap_n == 0 and #applause == 0 and samples >= 20 and bad == 0 then
                print(string.format("[shang] RESULT PASS (finish) samples=%d no clap through FINISH HIM", samples))
            else
                print(string.format("[shang] RESULT FAIL (finish) saw_finish=%s clap=%d applause=%d samples=%d mismatches=%d",
                    tostring(saw_finish), clap_n, #applause, samples, bad))
            end
        elseif NEG then
            if samples >= 20 and bad == samples then
                print(string.format("[shang] RESULT PASS (negative) samples=%d all mismatched", samples))
            else
                print(string.format("[shang] RESULT FAIL (negative) samples=%d mismatches=%d "
                    .. "- the crossed expectation still agreed, so the rig proves nothing",
                    samples, bad))
            end
        elseif samples >= 20 and bad == 0 and nb >= 4 and clap_bad == 0
               and csteps == K.cn and clap_n >= K.cframes and #applause == 1
               and back_rel and back_rel - clap_first <= K.cframes * K.crate + 2 * K.rate + 4 then
            print(string.format("[shang] RESULT PASS samples=%d buckets=%d clap=%d changes over %d steps, applause sent once (rel %d, first clap rel %d), arms back on the chair %d ticks after the first clap",
                samples, nb, clap_n, csteps, applause[1] - fight_frame, clap_first, back_rel - clap_first))
        else
            print(string.format("[shang] RESULT FAIL samples=%d mismatches=%d buckets=%d "
                .. "clap_bad=%d clap_steps=%d applause=%d back=%s (need >=20 samples, 0 mismatches, >=4 buckets, "
                .. "0 bad clap poses, all %d clap steps, applause sent exactly once, arms back on the chair as the lane ends)",
                samples, bad, nb, clap_bad, csteps, #applause,
                back_rel and tostring(back_rel - (clap_first or 0)) or "never", K.cn))
        end
        logfh:close(); manager.machine:exit()
    end
end)
