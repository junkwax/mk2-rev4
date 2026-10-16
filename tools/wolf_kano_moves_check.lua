-- wolf_kano_moves_check.lua - MK1 KANO's block, sweep, cannonball and knife
-- impact against what MAME `mk` does (tools/run_mk1_kano_probe.ps1 -Moves2,
-- -BallTest).  P1 Shang morphs into Kano against an idle P2 Jax, then:
--   BLOCK  held: once the guard is up his drawn frame never changes, and it
--          is KNHIBLOCK3 (MK1's lane 38h frame 3) - not the arms coming down;
--   SWEEP  Back held, then Back + LK: his art is MK1's 25h (KNSWEEPKIK - Liu
--          Kang's name for the frame), and it connects;
--   CROUCH KICK  Down + HK and Down + LK both play MK1's 0Dh to its extension
--          (KNDUCKIKHI4, Liu Kang's name) and connect;
--   BALL   Block, F, D, B, U, Block HELD 60 more ticks: curled and spinning,
--          he moves no more than 2 px; let go, he rolls out, then comes back;
--   KNIFE  from 170, 120, 100 and 80 px: the impact frame's blade end sits
--          18-30 px inside his front edge (MK1: 28; MK1KNM kn_knife_in 24) -
--          stuck in the front of his chest, whatever the distance - and while
--          it is still flying its drawn blade never gets more than 35 px into
--          him (it used to fly right through him before the box touched him).
-- Env as tools/wolf_kano_mk1_check.lua.
local LOG = os.getenv("WB_LOG")
local f = io.open(LOG, "w")
local function log(fmt, ...) f:write(string.format(fmt, ...) .. "\n"); f:flush() end
log("wolf_kano_moves_check start")

local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
-- every record's SAG in his pack, by family
local FAM = {}            -- sag -> "hand" | "flight" | "hit"
do
    local lab
    for l in io.lines(os.getenv("WS_TBL")) do
        local nm = l:match("^(%w+):")
        if nm then lab = nm end
        local h = l:match("%.long%s+0?(%x+)[hH]")
        if lab and h and #h >= 7 then
            local fam
            if lab:match("^KNKNIFEHIT") then fam = "hit"
            elseif lab:match("^KNKNIFE[123]%u$") then fam = "hand"
            elseif lab:match("^KNKNIFE%d+%u$") then fam = "flight" end
            if fam then FAM[tonumber(h, 16)] = fam end
            lab = nil
        end
    end
end
-- his MK1 tracks: the channel-1 track of each mk1kn_ row
local TRK = {}
for l in io.lines(os.getenv("WS_SND")) do
    local t, key = l:match("%.word%s+%x+h|%d+,0?(%x+)h%s*;%s*%x+%s+(mk1kn_[%w_]+)")
    if t then local n = tonumber(t, 16); TRK[n] = key; TRK[n + 1] = key; TRK[n + 2] = key end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "curback",
                    "illop_count", "p1_bar", "p2_bar", "p1_state", "p2_state", "objlst", "objlst2", "objlst3", "palram",
                    "KNKNIFE_P"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { olink = 0, oxpos = 0x090, oflags = 0x0f0, opal = 0x140, oimg = 0x1a0, ochar = 0x1f0 }
local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Low Punch",
               "P1 High Kick", "P1 Low Kick", "P1 Block", "P1 Up", "P1 Down", "P1 Left", "P1 Right"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end

-- every record's SAG -> its name, for the families this rig reads
local NAME = {}
local SAGNAMES = {}     -- SAG -> " name name " (LOAD2 folds identical records)
do
    local lab
    for l in io.lines(os.getenv("WS_TBL")) do
        local nm = l:match("^(%w+):")
        if nm then lab = nm end
        local h = l:match("%.long%s+0?(%x+)[hH]")
        if lab and h and #h >= 7 then
            -- LOAD2 FOLDS identical records onto one SAG (KNDUCKIKHI4A and
            -- KNDUCKIKLO2A are one MK1 pose under two of Liu Kang's names), so a
            -- drawn SAG can be any of several names: keep them all
            local v = tonumber(h, 16)
            NAME[v] = lab; SAGNAMES[v] = (SAGNAMES[v] or " ") .. lab .. " "; lab = nil
        end
    end
end
-- a multipart object's pieces: shape RAM, 112-bit nodes (DISPEQU: mp_sag 0)
local function pieces(o)
    local out, node = {}, r32(o + O.oimg)
    for _ = 1, 16 do
        if node == 0 then break end
        local s = r32(node)
        if s == 0 then break end
        out[#out + 1] = s
        node = node + 112
    end
    return out
end
local function key(o) return table.concat((function() local t = {} for i, s in ipairs(pieces(o)) do t[i] = string.format("%x", s) end return t end)(), ",") end
local function first_name(o) local p = pieces(o); return p[1] and NAME[p[1]] or "?" end
-- true if the first piece drawn is (or is folded with) a record matching pat
local function first_is(o, pat)
    local p = pieces(o)
    for n in ((p[1] and SAGNAMES[p[1]]) or ""):gmatch("%S+") do if n:match(pat) then return true end end
    return false
end
-- drawn left/right of an object, from its pieces' size and anipoint words
local function bounds(o)
    -- shape RAM node: mp_sizex at bit 20h, mp_anix at bit 50h - the piece's
    -- anipoint as ani2 laid it (flip applied); a piece's x is oxpos - anix
    local node, x0 = r32(o + O.oimg), r16(o + O.oxpos)
    local lo, hi = 1e9, -1e9
    for _ = 1, 16 do
        if node == 0 or r32(node) == 0 then break end
        local w = r16(node + 0x20)
        local ax = (r16(node + 0x50) + 0x8000) % 0x10000 - 0x8000
        lo = math.min(lo, x0 - ax); hi = math.max(hi, x0 - ax + w)   -- as mpart_bounds
        node = node + 112
    end
    return lo, hi
end

local frame, started, sel, fight, confirm, morph_f, ill0 = 0, false, nil, nil, nil, nil, nil
local phase, pt, result = 1, 0, {}
local ck_ext, ck_bar0, ck_hit
local blk_keys, blk_changes, blk_hold0, blk_hold0_ok = {}, 0, nil, false
local sweep_seen, sweep_bar0, sweep_hit = false, nil, false
local ball_x0, ball_spin_max, ball_rel_x, ball_far, ball_back, ball_seen = nil, 0, nil, nil, nil, false
local knives, knife_dist, knife_last, kidx = {}, {170, 120, 100, 80}, nil, nil
local flight_deep, flight_width = {}, {}
local function place(p1o, p2o, d)
    local x1 = r16(p1o + O.oxpos)
    local nx = x1 + d
    w16(p2o + O.oxpos, nx); space:write_u32(p2o + 0x080, (nx << 16) & 0xffffffff)
end
local function done(msg) log(msg); f:close(); manager.machine:exit() end
local function press(names) for _, n in ipairs(names) do F[n]:set_value(1) end end

emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true
    end
    frame = frame + 1
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    local gs = r16(A.gstate)
    if gs == 4 and not sel then sel = frame end
    if not sel and frame >= 1500 then
        local k = (frame - 1500) % 200
        F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
        F["2 Players Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
    end
    if not fight then
        if sel then
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, 0)
            if r16(A.p1_state) ~= 0 then w16(A.p2_state, r16(A.p1_state)) end   -- p2 human at select
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count); log("fight at %d", frame) end
        if frame > 12000 then done("no fight - NO VERDICT") end
        return
    end
    if r16(A.illop_count) ~= ill0 then done("FAIL illop_count moved (a reboot)"); return end
    if r16(A.p1_state) ~= 0 and r16(A.p2_state) == 0 then
        w16(A.p2_state, r16(A.p1_state))   -- P2 an idle HUMAN, never the CPU, however the start went
    end
    local p1o, p2o = r32(A.p1_obj), r32(A.p2_obj)
    if p1o == 0 or p2o == 0 or gs ~= 2 then return end
    if r16(A.p1_bar) < 60 then w16(A.p1_bar, 0xa1) end
    if r16(A.p2_bar) < 60 then w16(A.p2_bar, 0xa1) end
    w16(S.f_freeze_timer, 1)          -- the round clock outlasts nothing: stop it
    if r16(p1o + O.ochar) ~= 22 then
        if pt > 0 then log("  (he turned back into Shang at phase %d +%d - morphing again)", phase, pt) end
        local k = frame % 60
        F["P1 Left"]:set_value(k < 4 and 1 or 0)
        F["P1 Right"]:set_value((k >= 6 and k < 10) and 1 or 0)
        F["P1 Block"]:set_value((k >= 12 and k < 16) and 1 or 0)
        pt = 0
        return
    end
    pt = pt + 1
    local act = r16(r32(A.p1_proc) + 0x1f0)

    if phase == 1 then            -- BLOCK: up 60 ticks; once raised, the frame must not change
        if pt == 1 then place(p1o, p2o, 120) end
        if pt >= 20 and pt < 80 then press({"P1 Block"}) end
        if pt >= 32 and pt < 80 then
            local k = key(p1o)
            if blk_keys.last and blk_keys.last ~= k then blk_changes = blk_changes + 1 end
            blk_keys.last = k
            if not blk_hold0 then blk_hold0_ok = first_is(p1o, "^KNHIBLOCK3%u$") end
            blk_hold0 = blk_hold0 or first_name(p1o)
        end
        if pt == 81 then
            log("BLOCK held 48 ticks: frame %s, %d changes", tostring(blk_hold0), blk_changes)
            -- MK1's block frame 3, under Liu Kang's name for his held guard
            result.block = blk_changes == 0 and blk_hold0 and blk_hold0_ok
            phase, pt = 2, 0
        end
    elseif phase == 2 then        -- SWEEP: Back held, then Back + LK, close
        if pt == 1 then place(p1o, p2o, 70); sweep_bar0 = r16(A.p2_bar) end
        if pt >= 20 and pt < 34 then press({"P1 Left"}) end
        if pt >= 30 and pt < 34 then press({"P1 Low Kick"}) end
        if pt > 30 and pt < 90 then
            local n = first_name(p1o)
            if n:match("^KNSWEEP") and not sweep_seen then sweep_seen = true; log("SWEEP frame %s at +%d", n, pt) end
            if r16(A.p2_bar) < sweep_bar0 and not sweep_hit then sweep_hit = true; log("SWEEP connected for %d", sweep_bar0 - r16(A.p2_bar)) end
        end
        if pt == 140 then
            result.sweep = sweep_seen and sweep_hit
            log("SWEEP: art %s, hit %s", tostring(sweep_seen), tostring(sweep_hit))
            phase, pt = 2.5, 0
        end
    elseif phase == 2.5 then      -- CROUCH KICK: Down held, then + HK, then + LK - both MK1's 0Dh,
        local which = (pt <= 120) and "P1 High Kick" or "P1 Low Kick"   -- reaching its extension (KNDUCKIKHI4)
        local s = (pt - 1) % 120
        if s == 0 then place(p1o, p2o, 75); ck_ext, ck_bar0, ck_hit = false, r16(A.p2_bar), false end
        if s >= 10 and s < 34 then press({"P1 Down"}) end
        if s >= 22 and s < 26 then press({which}) end
        if s > 22 and s < 80 then
            if first_is(p1o, "^KNDUCKIKHI4%u$") then ck_ext = true end
            if r16(A.p2_bar) < ck_bar0 then ck_hit = true end
        end
        if s == 110 then
            log("CROUCH KICK (Down + %s): extension %s, connected %s", which:sub(4), tostring(ck_ext), tostring(ck_hit))
            result.crouch = (result.crouch ~= false) and ck_ext and ck_hit
        end
        if pt == 240 then phase, pt = 3, 0 end
    elseif phase == 3 then        -- CANNONBALL: Block, F, D, B, U, Block HELD 60 more, then let go
        if pt == 1 then             -- (a restarted phase - the morph timer - starts clean)
            place(p1o, p2o, 220)
            ball_x0, ball_spin_max, ball_far, ball_back, ball_seen = nil, 0, nil, nil, false
        end
        local s = pt - 10
        if s >= 0 and s < 6 then press({"P1 Block"}) end
        if s >= 6 and s < 9 then press({"P1 Block", "P1 Right"}) end
        if s >= 9 and s < 12 then press({"P1 Block", "P1 Down"}) end
        if s >= 12 and s < 15 then press({"P1 Block", "P1 Left"}) end
        if s >= 15 and s < 18 then press({"P1 Block", "P1 Up"}) end
        if s >= 18 and s < 78 then press({"P1 Block"}) end
        local n = first_name(p1o)
        local x = r16(p1o + O.oxpos)
        -- the ball's art (MK1 2Bh), a special with names of its own: KNBALL1-8
        local curled = first_is(p1o, "^KNBALL%d%u$")
        if curled then ball_seen = true end
        if s >= 30 and s < 78 and curled then
            ball_x0 = ball_x0 or x
            ball_spin_max = math.max(ball_spin_max, math.abs(x - ball_x0))
        end
        if s >= 78 and ball_x0 then
            ball_far = math.max(ball_far or x, x)
            if ball_far and x < ball_far - 30 then ball_back = true end
        end
        if s == 200 then
            log("BALL: curled %s; spin drift while held %d px; rolled to +%d; came back %s",
                tostring(ball_seen), ball_spin_max, (ball_far or 0) - (ball_x0 or 0), tostring(ball_back))
            result.ball = ball_seen and ball_x0 and ball_spin_max <= 2 and (ball_far - ball_x0) > 40 and ball_back
            phase, pt = 4, 0
        end
    elseif phase == 4 then        -- KNIFE from three distances: impact centred on him
        kidx = kidx or 1
        local i = kidx
        if i > #knife_dist then phase = 5; return end
        local s = pt
        if s == 1 then place(p1o, p2o, knife_dist[i]); knife_last = nil end
        if s >= 10 and s < 14 then press({"P1 Block"}) end
        if s >= 14 and s < 18 then press({"P1 Block", "P1 Left"}) end
        if s >= 18 and s < 20 then press({"P1 Block"}) end
        if s >= 20 and s < 24 then press({"P1 Block", "P1 Right"}) end
        if s % 6 == 0 and s <= 36 and knife_dist[i] <= 100 then
            log("  +%d act %04x  kano x %d, jax x %d", s, act, r16(p1o + O.oxpos), r16(p2o + O.oxpos))
        end
        local ko
        for _, l in ipairs({A.objlst, A.objlst2, A.objlst3}) do
            local o = r32(l)
            for _ = 1, 200 do
                if o == 0 then break end
                local n = first_name(o)
                if n:match("^KNKNIFEHIT") then ko = o end
                o = r32(o + O.olink)
            end
        end
        for _, l in ipairs({A.objlst, A.objlst2, A.objlst3}) do
            local o = r32(l)
            for _ = 1, 200 do
                if o == 0 then break end
                local n = first_name(o)
                if n:match("^KNKNIFE%d") and not n:match("^KNKNIFE[123]%u") then   -- in flight
                    local kl, kh = bounds(o)
                    local vl, vh = bounds(p2o)
                    flight_deep[i] = math.max(flight_deep[i] or -999, kh - vl)
                    flight_width[i] = vh - vl
                end
                if n:match("^KNKNIFE%d") and s % 4 == 0 and s < 120 then
                    local kl, kh = bounds(o)
                    local vl, vh = bounds(p2o)
                    log("  +%d %s knife %d..%d him %d..%d act %04x", s, n, kl, kh, vl, vh, r16(r32(A.p1_proc) + 0x1f0))
                end
                o = r32(o + O.olink)
            end
        end
        if ko then
            knife_last = (knife_last or 0) + 1
            if knife_last == 5 then manager.machine.video:snapshot() end   -- the screen runs ~2 ticks behind
            if knife_last == 1 then
                local kl, kh = bounds(ko)
                local vl, vh = bounds(p2o)
                -- MK1's placement: the blade end kn_knife_in (24) px inside his near edge
                local inside = kh - vl
                knives[i] = inside
                log("KNIFE from %d px: blade end %d px inside his front edge (his body %d..%d); %s",
                    knife_dist[i], inside, vl, vh, flight_deep[i] and string.format("in flight it reached %d px into him", flight_deep[i]) or "hit before any flight frame was drawn")
            end
        end
        if s == 140 then
            if not knives[i] then knives[i] = "none"; log("KNIFE from %d px: no impact seen", knife_dist[i]) end
            pt = 0
            kidx = kidx + 1                  -- the next distance only after this throw is over
        end
    else
        local kok = true
        for _, v in ipairs(knives) do if v == "none" or v < 18 or v > 30 then kok = false end end
        -- and the flying knife never passes THROUGH him before it sticks
        -- (none drawn at all is fine: close in it is hit before its first flight frame)
        for i in ipairs(knives) do if (flight_deep[i] or -999) > 35 then kok = false end end
        result.knife = kok
        log("block %s, sweep %s, crouch kick %s, ball %s, knife %s", tostring(result.block), tostring(result.sweep),
            tostring(result.crouch), tostring(result.ball), tostring(result.knife))
        done((result.block and result.sweep and result.crouch and result.ball and result.knife) and "PASS" or "FAIL")
    end
    if frame - fight > 20000 then done("FAIL out of frames") end
end)
