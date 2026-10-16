-- sweep_addon_hudcall.lua - do the KOUNTER / PUNISH / REVERSAL callouts fire,
--                           and do they fire on the RIGHT thing?
--
-- The classification (hud_callout, MKDISP.ASM) reads the VICTIM's action at
-- the moment of a clean hit and uses MK2's action categories:
--
--   FIRST HIT      once a round, cal_first
--   06xx           a recovery state -> one of the PUNISH family, picked by
--                  cal_last (what the strike he is recovering from DID):
--                    CAL_BLOCKED 1 -> BLOCK PUNISH
--                    CAL_HIT     2 -> PUNISH
--                    CAL_NOTHING 0 -> WHIFF PUNISH
--                  act_upcutted 0606h excluded - it is a 06xx REACTION
--   airborne       ANTI-AIR, if he is NOT in 05xx and I am on the ground
--   REVERSAL       cal_atk (init_special) - cal_free (reaction/block_exit)
--   01xx           he was attacking -> KOUNTER
--
-- Plus "N HIT COMBO", armed from back_to_normal when a string ENDS, which is
-- where MK3 arms its own combo message. The word for that one is built in
-- RAM (cal_buf) rather than pointed at ROM, so the rig reads it back as a
-- string instead of matching a symbol.
--
-- Drawing is not what this checks - hud_pass is already proven by hudtest.
-- What it checks is that the word ARMED is the word the situation deserves,
-- which is the only part that can be silently wrong.
--
-- Every arming is cross-checked against the victim's action READ INDEPENDENTLY
-- on the same frame. If hud_callout says KOUNTER, the victim had better have
-- been in 01xx. A rig that only counted armings would pass on a routine that
-- always said "PUNISH".
--
-- SECOND thing checked, since the word now FLIES IN from the side the way
-- MK3's combo message does: the trajectory. Every frame of every callout's
-- life is sampled out of cal_x / cal_phase and compared against MK3's curve
-- recomputed here from MKFX.ASM - x += xvel, then xvel -= xvel>>3 for 15h
-- ticks, coast 2, park 48h with xvel 0, then -entry velocity for 10.
-- "It slides" is not the claim; "it slides on MK3's numbers" is, and only a
-- position-by-position compare can tell those apart. The start is checked
-- too: -(width of the word) measured out of sysfont for p1, scrrgt for p2.
--
-- Env: HUDCALL_LOG
-- Driven by run_hudcall_test.ps1.

local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("HUDCALL_LOG") or (ROOT .. "/tools/hudcall.txt")

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        sym[n] = tonumber(a, 16)
    end
end
local gstate  = sym.gstate
local p1_proc, p2_proc = sym.p1_proc, sym.p2_proc
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local p1_bar, p2_bar = sym.p1_bar, sym.p2_bar
local cal_word, cal_tick = sym.cal_word, sym.cal_tick
local cal_phase, cal_x, cal_xv = sym.cal_phase, sym.cal_x, sym.cal_xv
local cal_arms = sym.cal_arms
local cal_last = sym.cal_last
local rd11font = sym.rd11font
local objlst = sym.objlst
local hud_drew = sym.hud_drew
local OID = 0x1c0
local OID_CALOUT = 0x806        -- p1; p2 is this + 1
local hud_drew = sym.hud_drew   -- hud_count is ZEROED by hud_pass every
                                -- frame ('consume the list'), so Lua always
                                -- reads 0. hud_drew only increments on a frame
                                -- that actually completed a draw loop.
local f_doscore = sym.f_doscore

local WORDS = {
    [sym.hc_kounter_s] = "KOUNTER",
    [sym.hc_punish]    = "PUNISH",
    [sym.hc_reversal]  = "REVERSAL",
    [sym.hc_firsthit]  = "FIRST HIT",
    [sym.hc_blockpun]  = "BLOCK PUNISH",
    [sym.hc_whiffpun]  = "WHIFF PUNISH",
    [sym.hc_antiair]   = "ANTI-AIR",
    [sym.hc_flawblk]   = "FLAWLESS BLOCK",
}
local cal_buf = sym.cal_buf

-- pdata is 100h, and these are all pdata-relative in MAINEQU: p_action is
-- pdata+0f0h, which is the 1f0h that was already here. Writing the raw
-- pdata-relative number instead reads a different field entirely - it made
-- every airborne test true and p_hit garbage, and it looked exactly like the
-- ROM classifying wrongly.
local P_ACTION = 0x1f0          -- pdata+0f0h
local P_STK    = 0x350          -- pdata+250h
local P_HIT    = 0x370          -- pdata+270h
local P_GANIY  = 0x200          -- pdata+100h
local OXPOS, OXVAL = 0x090, 0x080
local OYPOS, OYVEL = 0x0b0, 0x060   -- DISPEQU: 0a0h is oyVAL, 0d0h is ozpos
local MAX_HP = 0xA1
local ACT_UPCUTTED = 0x0606

-- Declared up here because strwidth() reads memory through it: a local
-- declared further down would leave that reading a nil global instead.
local space = nil

-- MK3's numbers (MKFX.ASM setup_combo_message / slide_combo_msg), duplicated
-- here on purpose: a rig that read them out of the ROM would agree with
-- whatever value the ROM happened to hold.
-- 0a0000h, not MK3's 0f0000h: the entry speed is what decides where the
-- word parks, and 15.0 left it 48 pixels off the edge. Everything else here
-- is still MK3's.
local VEL, SLIDE, COAST, HOLD, OUT = 0x0A0000, 0x15, 2, 0x48, 10
-- The word is AIMED now: it ends lined up with the life bar above it, on the
-- edge nearest the screen, so the start is that target a whole travel away.
-- 22 is where setup_score_ram puts p1's bar; 377 is what mainlp right-
-- justifies p2's against; 76 is what the damping covers at this entry speed.
local X_LEFT, X_RIGHT, TRAVEL = 22, 377, 76
local LIFE = SLIDE + COAST + HOLD + OUT

local function s32(v)
    v = v & 0xffffffff
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
end
local function sra(v, n)              -- arithmetic, like the 34010's SRA
    if v >= 0 then return v >> n end
    return -((-v + (1 << n) - 1) >> n)
end
-- 16.16 -> whole pixels. Floor division, NOT >>16: Lua's shift is logical on
-- 64-bit ints, so a negative x - which is most of the slide in from the left -
-- comes out as 2^48-ish. It compared equal anyway (both sides went through the
-- same wrong transform) but it printed nonsense, and a rig that only works by
-- symmetry is one edit from not working at all.
local function px(v) return v // 65536 end

-- What the ROM's cot_width should have measured. The word is drawn in
-- rd11font - the font the credits line uses - as objects, at 1:1, and the
-- advance is isizex + COT_GAP. Table entries start at '!'. Getting this from
-- the wrong font is not a small error: it moves p1's start x, which is
-- -(width), and every position after it.
-- COT_SCLTXT is index 2 of cot_scltab, whose multiplier is 0e4h: the text is
-- drawn a little under nine tenths of the art, and the ADVANCE is scaled with
-- it or the letters would not match the glyphs.
-- MUL is cot_scltab's advance multiplier for the scale the WORDS draw at.
-- 0x100 since COT_SCLTXT became COT_SCL11: they are drawn at the size the
-- credits font was made at, not resampled down to 0.89 (0xe4).
local GAP, SPACE, MUL = 2, 5, 0x100
-- The four words that lead with an icon, and how wide that icon is. Drawn at
-- 1:1 in front of the text with COT_ICONGAP between, so it is part of the
-- toast's width - which is what p2's start position is measured back from.
-- Duplicated here rather than read out of the IMG, for the same reason the
-- MK3 constants above are.
local ICON_W = { ["FIRST HIT"]      = 16,   -- DRAGTOST (re-exported 21x17 -> 16x16)
                 ["REVERSAL"]       = 18,   -- YINTOST
                 ["PUNISH"]         = 14,   -- GOROTOST
                 ["KOUNTER"]        = 18,   -- SHAOTOST
                 ["BLOCK PUNISH"]   = 15,   -- SKULTOST
                 ["ANTI-AIR"]       = 21,   -- RADTOST
                 ["FLAWLESS BLOCK"] = 8 }   -- BOLTOST
local ICON_GAP = 9        -- COT_ICONGAP

-- FLAWLESS BLOCK draws at COT_SCLCMB instead (cal_wscl, MKDISP.ASM): 0cdh.
local WORD_MUL = { ["FLAWLESS BLOCK"] = 0xcd }

local function strwidth(str)
    if not rd11font then return nil end
    local MUL = WORD_MUL[str] or MUL
    local w = 0
    for i = 1, #str do
        local c = str:byte(i)
        if c == 32 then
            w = w + ((SPACE * MUL) >> 8)
        elseif c > 32 and c < 127 then
            local ent = space:read_u32(rd11font + (c - 0x21) * 32)
            w = w + ((((space:read_u16(ent) & 0xffff) + GAP) * MUL) >> 8)
        end
    end
    return w
end

-- How many glyph objects that player's word has on the object list. The
-- callouts are DMA objects again and never touch hud_pass, so hud_drew says
-- nothing about them; counting the objects asks the same question of the
-- path that is actually running.
local function glyphs(i)
    if not objlst then return 0 end
    local n, o, guard = 0, space:read_u32(objlst), 0
    while o ~= 0 and guard < 400 do
        if (space:read_u16(o + OID) & 0xffff) == (OID_CALOUT + i) then
            n = n + 1
        end
        o = space:read_u32(o)
        guard = guard + 1
    end
    return n
end

-- The ladder in hud_callout, recomputed from the four things it reads. This
-- is the point of the rig: the ORDER is the part that can be silently wrong,
-- and a routine that always said PUNISH would pass a test that only counted.
--
--   va   the victim's p_action        mair  is the ATTACKER off the ground
--   last cal_last for the VICTIM      air   is the VICTIM off the ground
--
-- FIRST HIT and the combo word are not in here: one is a fact about the round
-- and the other is armed from back_to_normal, not from this path at all.
-- REVERSAL sits between the punishes and ANTI-AIR and depends on two
-- timestamps, so it is allowed anywhere the punishes are not.
local function classify(va, last, air, mair)
    local cat = (va >> 8) & 0xff
    if cat == 6 and va ~= ACT_UPCUTTED then
        return (last == 1 and "BLOCK PUNISH")
            or (last == 2 and "PUNISH") or "WHIFF PUNISH"
    elseif air and cat ~= 5 and not mair then
        return "ANTI-AIR"
    elseif cat == 1 then
        return "KOUNTER"
    end
    return nil
end
local function ispunish(w)
    return w == "BLOCK PUNISH" or w == "WHIFF PUNISH" or w == "PUNISH"
end

-- MK3's flight, frame by frame, as a list of integer screen x.
local function model(x0, dir)
    local pos, v, out = x0 << 16, dir * VEL, {}
    for _ = 1, SLIDE do
        pos = pos + v; v = v - sra(v, 3); out[#out + 1] = px(pos)
    end
    for _ = 1, COAST do pos = pos + v; out[#out + 1] = px(pos) end
    for _ = 1, HOLD  do out[#out + 1] = px(pos) end
    v = -dir * VEL
    for _ = 1, OUT   do pos = pos + v; out[#out + 1] = px(pos) end
    return out
end

-- The combo message's word is built in cal_buf, so its pointer is not a
-- symbol. Read the ASCIZ back out of RAM instead.
local function ramstr(addr)
    local out = {}
    for k = 0, 15 do
        local c = space:read_u8(addr + k * 8)
        if c == 0 then break end
        out[#out + 1] = string.char(c)
    end
    return table.concat(out)
end

local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[hudcall] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end

for _, n in ipairs({
    "P1 Left","P1 Right","P1 Up","P1 Down",
    "P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block",
    "P2 Left","P2 Right","P2 Up","P2 Down",
    "P2 High Punch","P2 Low Punch","P2 High Kick","P2 Low Kick","P2 Block",
}) do ADDON_OWNS[n] = true end

local verify_flight            -- forward: defined below, used in the loop
local frame, fight0 = 0, 0
local fields = {}
local prev_word = {[0] = 0, [1] = 0}
local prev_tick = {[0] = 0, [1] = 0}
local prev_arms = {[0] = nil, [1] = nil}
local prev_act  = {[0] = 0, [1] = 0}
local flight = {[0] = nil, [1] = nil}   -- trajectory being recorded
local flights, flights_bad, flights_cut = 0, 0, 0
local combos = 0
local prev_last = {[0] = 0, [1] = 0}   -- cal_last, one frame back
local prev_air  = {[0] = false, [1] = false}
local prev_hit  = {[0] = 0, [1] = 0}   -- p_hit, one frame back
-- back_to_normal clears p_hit one instruction after cal_combo reads it, so by
-- the time the arming is visible to Lua the count is already 0. The peak
-- since the string started is what the word should say.
local peak_hit  = {[0] = 0, [1] = 0}
local snapped = {}                      -- one shot per word, while it is parked
local counts, wrong = {}, 0
local rev_stale = 0
local last_drew, drew_frames = nil, 0
local peak_glyphs = {[0] = 0, [1] = 0}
local no_glyphs = 0
local peak_glyphs = {[0] = 0, [1] = 0}
local no_glyphs = 0
local function s16(v) v = v & 0xffff
    if v >= 0x8000 then return v - 0x10000 end return v end
local function press(n, on)
    local f = fields[n]; if f then f:set_value(on and 1 or 0) end
end

-- Compare one recorded flight against MK3's curve. The first sample lands one
-- frame after the arm, which is exactly the model's first entry: hud_callout
-- arms it, and the NEXT pass through hud_callout_draw is the first move.
verify_flight = function(i, fl)
    flights = flights + 1
    local w = strwidth(fl.word)
    local iw = ICON_W[fl.word]
    if w and iw then w = w + iw + ICON_GAP end
    local x0  = (i == 0) and (X_LEFT - TRAVEL)
                         or (X_RIGHT + TRAVEL - (w or 0))
    local dir = (i == 0) and 1 or -1
    local want = model(x0, dir)
    if #fl.x < LIFE then
        flights_cut = flights_cut + 1
        log("  FLIGHT p%d %-8s CUT SHORT: %d frames of %d (re-armed, or the round ended)",
            i + 1, fl.word, #fl.x, LIFE)
        return
    end
    local bad, first = 0, nil
    for n = 1, LIFE do
        if fl.x[n] ~= want[n] then
            bad = bad + 1
            if not first then
                first = string.format("frame %d got %d want %d", n, fl.x[n], want[n])
            end
        end
    end
    if bad > 0 then
        flights_bad = flights_bad + 1
        log("  FLIGHT p%d %-8s OFF MK3's CURVE: %d/%d samples, first %s",
            i + 1, fl.word, bad, LIFE, first)
    elseif flights <= 3 then
        log("  FLIGHT p%d %-8s width=%d  enters at %d, parks at %d for %d, %d frames EXACT",
            i + 1, fl.word, w or -1, want[1], want[SLIDE + COAST], HOLD, LIFE)
    end
end

-- Census of the object list by oid. 0806/0807 are the callout glyphs; this
-- exists because an object leak here reads as "the game died", not as
-- "the callouts are wrong".
local reported = false
local function watch_explosion(t)
    if reported or (t % 8) ~= 0 or not objlst then return end
    local tab, o, n = {}, space:read_u32(objlst), 0
    while o ~= 0 and n < 400 do
        local id = space:read_u16(o + OID) & 0xffff
        tab[id] = (tab[id] or 0) + 1
        o = space:read_u32(o); n = n + 1
    end
    if n > 90 then
        reported = true
        local out = {}
        for id, c in pairs(tab) do out[#out+1] = string.format("%04x:%d", id, c) end
        table.sort(out)
        log("  EXPLOSION t=%d objects=%d  %s", t, n, table.concat(out, " "))
        for i = 0, 1 do
            log("     p%d phase=%d tick=%d arms=%d", i + 1,
                space:read_u16(cal_phase + i*16) & 0xffff,
                space:read_u16(cal_tick + i*16) & 0xffff,
                space:read_u16(cal_arms + i*16) & 0xffff)
        end
    end
end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do
                if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== hud callouts === do they fire, and on the right thing?")
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame end
    local t = frame - fight0
    watch_explosion(t)

    -- Both bars pinned: the rig throws hundreds of hits and a corpse measures
    -- nothing. (The harness pins P1's only.)
    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)

    local pr = {space:read_u32(p1_proc), space:read_u32(p2_proc)}
    local act = {}
    for i = 0, 1 do
        act[i] = pr[i + 1] ~= 0 and (space:read_u16(pr[i + 1] + P_ACTION) & 0xffff) or 0
    end

    -- cal_last, p_hit and "off the ground" for both players, sampled the
    -- frame BEFORE the arming, same as the action is. Airborne is recomputed
    -- from oypos/oyvel against p_ganiy rather than trusted from the ROM -
    -- is_he_airborn is part of what is being checked.
    local cur_last, cur_air, cur_hit = {}, {}, {}
    for i = 0, 1 do
        cur_last[i] = space:read_u16(cal_last + i * 16) & 0xffff
        local pp, ob = pr[i + 1], space:read_u32(i == 0 and p1_obj or p2_obj)
        cur_hit[i] = pp ~= 0 and (space:read_u8(pp + P_HIT) & 0xff) or 0
        if pp ~= 0 and ob ~= 0 then
            local gy = s16(space:read_u16(pp + P_GANIY))
            local y  = s16(space:read_u16(ob + OYPOS))
            local yv = space:read_u32(ob + OYVEL)
            cur_air[i] = (yv ~= 0) or (y ~= gy)
        else
            cur_air[i] = false
        end
    end

    for i = 0, 1 do
        if cur_hit[i] > peak_hit[i] then peak_hit[i] = cur_hit[i] end
    end

    -- "Did it actually draw": count the glyph objects while the word is
    -- parked (phase 3), when every one of them should be on the list.
    for i = 0, 1 do
        if (space:read_u16(cal_phase + i * 16) & 0xffff) == 3 then
            local n = glyphs(i)
            if n > 0 then
                drew_frames = drew_frames + 1
                if n > peak_glyphs[i] then peak_glyphs[i] = n end
            else
                no_glyphs = no_glyphs + 1
            end
        end
    end

    -- An arming is cal_arms ticking over. It used to be "cal_tick jumped back
    -- to full", which cannot survive the slide: cal_tick is a PHASE clock now
    -- and reaches a maximum three times in one callout's life.
    for i = 0, 1 do
        local w = space:read_u32(cal_word + i * 32)
        local tk = space:read_u16(cal_tick + i * 16) & 0xffff
        local ph = space:read_u16(cal_phase + i * 16) & 0xffff
        local xi = px(s32(space:read_u32(cal_x + i * 32)))
        local arms = space:read_u16(cal_arms + i * 16) & 0xffff

        -- The flight in progress: one sample a frame until it goes idle.
        local fl = flight[i]
        if fl then
            if arms ~= fl.arms then
                verify_flight(i, fl); flight[i] = nil     -- re-armed on top of it
            elseif ph == 0 then
                -- The frame it goes idle is still a frame it MOVED on: the
                -- last position is stored before the phase is cleared, so
                -- this sample is the 105th, not one past the end.
                fl.x[#fl.x + 1] = xi
                verify_flight(i, fl); flight[i] = nil
            else
                fl.x[#fl.x + 1] = xi
                fl.ph[#fl.ph + 1] = ph
                -- One snapshot per word, taken while it is PARKED (phase 3)
                -- and a good way into the hold, so the picture shows where it
                -- came to rest rather than a blur on the way in.
                -- One more, MID-SLIDE on p1, where the word is still half
                -- off the left edge. That is the frame that would expose the
                -- left clip going wrong: glyphs land in the page's xpadding
                -- there, and if that padding were ever visible they would
                -- show up as a smear against the edge.
                if i == 0 and ph == 1 and #fl.x == 4 and not snapped._slide then
                    snapped._slide = true
                    log("  SNAP p1 %-8s mid-slide at x=%d", fl.word, xi)
                    pcall(function() manager.machine.video:snapshot() end)
                end
                if ph == 3 and #fl.x > SLIDE + COAST + 20
                   and not snapped[fl.word] then
                    snapped[fl.word] = true
                    log("  SNAP p%d %-8s parked at x=%d", i + 1, fl.word, xi)
                    pcall(function() manager.machine.video:snapshot() end)
                end
            end
        end

        if w ~= 0 and prev_arms[i] and arms ~= prev_arms[i] then
            local name = WORDS[w]
            if not name then
                -- cal_buf is the only word that lives in RAM: the combo one.
                local mine = cal_buf and (w == cal_buf + i * 128)
                name = mine and ramstr(w) or string.format("?%08x", w)
            end
            -- the VICTIM is the other player; his state on the PREVIOUS frame
            -- is what hud_callout classified (this frame he is already in a
            -- reaction).
            -- Lua samples once a frame; the ROM classified DURING one. A
            -- fighter who starts an attack or leaves the ground on the frame
            -- he is hit therefore looks different from either side of that
            -- edge, so the answer is checked against BOTH the frame before
            -- and the frame of - a genuinely wrong ladder still fails, since
            -- neither frame would justify it.
            local va   = prev_act[1 - i]
            local expect  = classify(va, prev_last[1 - i] or 0,
                                     prev_air[1 - i] or false,
                                     prev_air[i] or false)
            local expect2 = classify(act[1 - i] or 0, cur_last[1 - i] or 0,
                                     cur_air[1 - i] or false,
                                     cur_air[i] or false)

            counts[name] = (counts[name] or 0) + 1
            -- REVERSAL's stamps are consumed as it is armed, so cal_atk must
            -- read 0 straight after. Before that, one cal_atk could fire the
            -- word again on every later hit until the player next left stun.
            if name == "REVERSAL" and sym.cal_atk then
                local ak = space:read_u16(sym.cal_atk + i * 16) & 0xffff
                if ak ~= 0 then rev_stale = rev_stale + 1 end
            end
            -- REVERSAL outranks the last two but not the punishes, and the
            -- combo word is armed from somewhere else entirely, so neither
            -- can be predicted from the victim's state alone.
            local iscombo = name:find("HIT COMBO") ~= nil
            -- FLAWLESS BLOCK is not a rung in the ladder and cannot be
            -- predicted from the victim's action: it is a hit that was
            -- BLOCKED, decided by jd_arm on the guard's age. classify()
            -- models a hit that LANDED, so it has nothing to say about it.
            -- Exempted here rather than guessed at - a guess would be the
            -- same free pass FIRST HIT used to get.
            local notaladder = (name == "FLAWLESS BLOCK")
            local ok = notaladder or (name == expect) or (name == expect2)
                    or (name == "FIRST HIT" and (counts["FIRST HIT"] or 0) >= 1)
                    or iscombo
                    -- Same +/-1 frame allowance as the direct match: if
                    -- EITHER frame is not a punish, the ROM could honestly
                    -- have read that one, and REVERSAL outranks what is
                    -- left. Both frames a punish, and it is wrong.
                    or (name == "REVERSAL"
                        and not (ispunish(expect) and ispunish(expect2)))
            if iscombo then
                combos = combos + 1
                local n = tonumber(name:match("^(%d+)"))
                local want = peak_hit[1 - i]
                peak_hit[1 - i] = 0
                if not n or n ~= want then
                    wrong = wrong + 1
                    log("  MISMATCH p%d combo said %s but he took %d hits",
                        i + 1, name, want)
                elseif combos <= 3 then
                    log("  %-12s p%d  t=%d  (victim p_hit=%d)", name, i + 1, t, want)
                end
            elseif not ok then
                wrong = wrong + 1
                log("  MISMATCH p%d %-12s  victim act=%04x/%04x last=%d/%d"
                    .. " air=%s -> expected %s or %s", i + 1, name, va,
                    act[1 - i] or 0, prev_last[1 - i] or 0, cur_last[1 - i] or 0,
                    tostring(prev_air[1 - i]), expect or "nothing",
                    expect2 or "nothing")
            elseif (counts[name] or 0) <= 2 then
                log("  %-12s p%d  t=%d  victim act=%04x last=%d air=%s",
                    name, i + 1, t, va, prev_last[1 - i] or 0,
                    tostring(prev_air[1 - i]))
            end
            -- Start recording the flight. The word belongs to the ATTACKER,
            -- so p1's comes in from the left and p2's from the right.
            flight[i] = {arms = arms, word = name, x = {}, ph = {}, t = t}
        end
        prev_word[i] = w
        prev_tick[i] = tk
        prev_arms[i] = arms
    end
    prev_act[0],  prev_act[1]  = act[0], act[1]
    prev_last[0], prev_last[1] = cur_last[0], cur_last[1]
    prev_air[0],  prev_air[1]  = cur_air[0], cur_air[1]
    prev_hit[0],  prev_hit[1]  = cur_hit[0], cur_hit[1]

    -- Drive the fight so every word in the ladder can actually happen. Both
    -- attack constantly; what varies is the DISTANCE, on a cycle short enough
    -- that a move started at whiff range is still recovering when the other
    -- man is snapped into range:
    --
    --   far (135px)   attacks whiff  -> cal_last stays CAL_NOTHING
    --   close (52px)  they connect   -> KOUNTER / BLOCK PUNISH / WHIFF PUNISH
    --
    -- and P2 jumps every 90 ticks, which is the only way an ANTI-AIR can turn
    -- up at all. Without the distance cycle the rig produced BLOCK PUNISH and
    -- nothing else, and "the other two compiled" is not evidence.
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local x1 = o1 ~= 0 and s16(space:read_u16(o1 + OXPOS)) or 0
    local x2 = o2 ~= 0 and s16(space:read_u16(o2 + OXPOS)) or 0
    local jumping = (t % 90) < 26
    if o1 ~= 0 and o2 ~= 0 and not jumping then
        -- 60 ticks close then 60 far: long enough at close range for a
        -- string to reach two hits (the combo word), long enough at far
        -- range for a move to whiff and still be recovering when the snap
        -- brings the other man back in (the whiff punish).
        local far = (t % 120) >= 60
        local gap = far and 135 or 52
        local tx = (x1 < x2) and (x1 + gap) or (x1 - gap)
        space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16)
    end

    -- Three P1 attacks inside one 22-tick cycle, 7 ticks apart. That gap is
    -- inside hitstun, which is what makes a two-hit string - and the string
    -- is the only thing that produces the combo word.
    local c = t % 22
    press("P1 High Punch", c == 0 or c == 1)
    press("P1 High Kick",  c == 7 or c == 8)
    press("P1 Low Kick",   c == 14 or c == 15)

    local d = t % 34
    press("P2 Up", (t % 90) == 0 or (t % 90) == 1)
    press("P2 Block", d < 8)
    press("P2 High Kick", d == 20 or d == 21)
    press("P2 High Punch", d == 28 or d == 29)
end)

emu.register_stop(function()
    local total = 0
    for k, v in pairs(counts) do
        log("RESULT %-9s x%d", k, v); total = total + v
    end
    local ds = space and (space:read_u16(f_doscore) & 0xffff) or -1
    log("SUMMARY armings=%d  mismatches=%d  frames_drawn=%d  f_doscore=%d",
        total, wrong, drew_frames, ds)
    log("SUMMARY reversals with an unconsumed cal_atk: %d", rev_stale)
    log("SUMMARY flights=%d  off_curve=%d  cut_short=%d  (MK3 life = %d ticks)",
        flights, flights_bad, flights_cut, LIFE)
    log("SUMMARY parked_frames_with_glyphs=%d  with_NONE=%d  peak p1=%d p2=%d",
        drew_frames, no_glyphs, peak_glyphs[0], peak_glyphs[1])
    if total == 0 then
        log("VERDICT NO-CASE (nothing ever armed - the hook did not fire)")
    elseif wrong > 0 then
        log("VERDICT FAIL - %d callouts did not match the victim's action", wrong)
    elseif drew_frames == 0 then
        log("VERDICT FAIL - armed but no glyph object was ever on the list")
    elseif no_glyphs > 0 then
        log("VERDICT FAIL - %d parked frames with no glyphs on the list", no_glyphs)
    elseif flights_bad > 0 then
        log("VERDICT FAIL - %d callouts did not fly MK3's curve", flights_bad)
    elseif flights - flights_cut == 0 then
        log("VERDICT NO-CASE (no callout was left alone long enough to measure)")
    else
        log("VERDICT PASS - %d callouts, all matching, drawn on %d frames", total, drew_frames)
    end
end)
