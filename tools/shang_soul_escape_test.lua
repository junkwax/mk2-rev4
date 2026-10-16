-- shang_soul_escape_test.lua
--
-- MK1's ending on MK2's Shang (src/MKSOULS.ASM, doc/MK2_SHANG_SOUL_ESCAPE.md).
-- Plays the REAL path: a one-player game, the CPU is Shang, the human beats
-- him twice, and instead of FINISH HIM his souls escape.
--
-- P1 (Liu Kang) walks in punching with his bar pinned full; Shang's bar is
-- held at 1, so the first clean hit ends each round.  Nothing about the
-- ending itself is forced - p2_char is written during select (and until the
-- fight starts, so the ladder cannot overwrite it) and that is all.
--
-- PASS needs every one of:
--   stage      curback is 8 (KAHN'S ARENA) for the Shang fight - chosen by
--              boss_minumum_diff, not by this script
--   no_finish  winner_status never reads 3 after the deciding KO
--   status4    it reads 4 (the souls) instead
--   souls      pid_soul processes appear, peaking at 2+ at once
--   complete   f_soulesc goes 1 -> -1 (Shang down) and back to 0
--   declared   winner_status goes to 1 (P1) after it
--   advances   the game leaves the fight afterwards (gstate changes away from
--              the round) - a wedged round-end looks exactly like a held pose
--              to a sampler, so "it finished" is not evidence on its own
--
-- Snapshots every SNAP_EVERY frames from status 4 for the whole sequence, into
-- the snapshot directory the wrapper sets.
--
-- Usage: tools\run_shang_soul_escape_test.ps1

local LOGP = os.getenv("SSE_LOG") or
    "C:/Users/you/Workplace/mk2-main/tools/shang_soul_escape_test.log"
local READY = os.getenv("SSE_READY") or
    "C:/Users/you/Workplace/mk2-main/tools/shang_soul_escape_test.ready"
local SNAP_EVERY = tonumber(os.getenv("SSE_SNAP_EVERY") or "3")

local logfh = io.open(LOGP, "w")
local function log(fmt, ...)
    local line = "[sse] " .. string.format(fmt, ...)
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
    if not v then missing[#missing + 1] = n; return 0 end
    return v
end

local A = {
    gstate = sym("gstate"), curback = sym("curback"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    winner_status = sym("winner_status"), f_soulesc = sym("f_soulesc"),
    round_num = sym("round_num"), battle_num = sym("battle_num"),
    active = sym("active"),
    f_soul_kintaro = sym("f_soul_kintaro"), f_soul_knock = sym("f_soul_knock"),
    soul_shang = sym("soul_shang"), soul_kintaro = sym("soul_kintaro"),
    map_position = sym("map_position"),
}

local OCHAR = 0x1f0          -- DISPEQU ochar
local OSHAPE, OPAL, OFLAGS2, OID, OZVAL = 0x1d0, 0x140, 0x160, 0x1c0, 0x0c0
local OXPOS, OYPOS = 0x090, 0x0b0
local OFLAGS, OSCALE, OIMG = 0x0f0, 0x180, 0x1a0
local M_INVISO = 0x20
local OBJLST = sym("objlst")
local DUMP_AT = tonumber(os.getenv("SSE_DUMP_AT") or "0")
local PROCID = 0x20
local PS_ACTIVE = 1
local GS_PSEL, GS_FIGHTING = 4, 2
local MAX_HP = 0xa1
local FT_KANG, FT_ST, FT_CAGE, FT_GORO = 1, 6, 2, 12
local MAP_SHANG = 12            -- ladder rung: 12 Shang, 13 Kintaro, 14 Kahn
local PID_SOUL = 0x0120

-- MODE=souls   the real thing: the CPU is Shang, and his souls escape
-- MODE=control the negative control: the CPU is somebody else, so FINISH HIM
--              must happen exactly as before and status 4 must never appear
local MODE = os.getenv("SSE_MODE") or "souls"
-- control mode only: force the stage, so the same arena can be compared
local FORCE_STAGE = tonumber(os.getenv("SSE_STAGE") or "-1")

local frame, space = 0, nil
local charsel_frame, fighting_frame, p1_confirm = 0, 0, 0
local fields = {}
local seen = { stage = nil, status3 = false, status4 = 0, souls_peak = 0,
               soul_frames = 0, esc1 = 0, escm1 = 0, esc0 = 0, declared = 0,
               advanced = 0, spawned = 0, battle0 = nil,
               kin1 = 0, kin2 = 0, knock = 0, gone = 0,
               nextchar = -1, nextmap = -1 }
local snaps = 0
local souls_prev = 0
local SOULS_WANTED = 11         -- soul_roster_n in MKSOULS.ASM (12 main, less Shang)

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local PALRAM = sym("palram")
local PALRSIZ = 0x40
local byaddr = {}
for n, a in pairs(symbols) do byaddr[a] = n end
local function palid_of(obj)
    if obj == 0 or PALRAM == 0 then return 0, "?" end
    local map = r16(obj + 0x140) & 0xff
    local id = r32(PALRAM + map * PALRSIZ)
    return id, (byaddr[id] or string.format("%08x", id)), map
end

local function count_pid(pid)
    local n, p, guard = 0, r32(A.active), 0
    while p ~= 0 and guard < 400 do
        if r16(p + PROCID) == pid then n = n + 1 end
        p = r32(p); guard = guard + 1
    end
    return n
end

local function finish(reason)
    local fails = {}
    local souls = seen.spawned > 0 and seen.spawned - 1 or 0   -- less the spawner itself
    if MODE == "control" then
        -- an ordinary CPU opponent: nothing here may have changed
        if seen.status4 > 0 then fails[#fails + 1] = "status 4 on a non-Shang opponent" end
        if not seen.status3 then fails[#fails + 1] = "no FINISH HIM (status 3)" end
        if seen.esc1 > 0 then fails[#fails + 1] = "f_soulesc was set" end
        if seen.advanced == 0 then fails[#fails + 1] = "game never reached the next battle" end
        log("stats(control): stage=%s status3=%s status4@%d advanced@%d (%s)",
            tostring(seen.stage), tostring(seen.status3), seen.status4, seen.advanced, reason)
        if #fails == 0 then log("PASS shang_soul_escape control")
        else log("FAIL shang_soul_escape control: %s", table.concat(fails, "; ")) end
        manager.machine:exit()
        return
    end
    if seen.stage ~= 8 then fails[#fails + 1] = "stage was " .. tostring(seen.stage) .. " not 8 (Kahn's Arena)" end
    if seen.status3 then fails[#fails + 1] = "FINISH HIM (status 3) happened" end
    if seen.status4 == 0 then fails[#fails + 1] = "never saw status 4" end
    if seen.souls_peak < 2 then fails[#fails + 1] = "souls peak " .. seen.souls_peak end
    if seen.esc1 == 0 or seen.escm1 == 0 or seen.esc0 == 0 then
        fails[#fails + 1] = string.format("f_soulesc 1@%d -1@%d 0@%d", seen.esc1, seen.escm1, seen.esc0)
    end
    if seen.declared == 0 then fails[#fails + 1] = "winner never declared" end
    if souls ~= SOULS_WANTED then
        fails[#fails + 1] = string.format("%d souls, wanted %d", souls, SOULS_WANTED)
    end
    -- the finisher: the arena prop leaps (1), hands over to the fight-size
    -- Kintaro (2), and what is left of Shang goes under the stomp
    if seen.kin1 == 0 then fails[#fails + 1] = "Kintaro never asked to leap" end
    if seen.kin2 == 0 then fails[#fails + 1] = "the arena prop never left the stands" end
    if seen.gone == 0 then fails[#fails + 1] = "Shang's body never went away" end
    if seen.advanced == 0 then fails[#fails + 1] = "game never reached the next battle" end
    -- the hand-off itself: beating Shang has to lead to KINTARO
    if seen.advanced > 0 and seen.nextchar ~= FT_GORO then
        fails[#fails + 1] = string.format("next opponent is %d, wanted Kintaro (%d)",
                                          seen.nextchar or -1, FT_GORO)
    end
    log("stats: stage=%s status4@%d souls=%d peak=%d soul_frames=%d esc1@%d esc-1@%d esc0@%d declared@%d advanced@%d snaps=%d (%s)",
        tostring(seen.stage), seen.status4, souls, seen.souls_peak, seen.soul_frames,
        seen.esc1, seen.escm1, seen.esc0, seen.declared, seen.advanced, snaps, reason)
    log("stats(kintaro): leap@%d left_stands@%d body_gone@%d knockback@%d next_opponent=%d map=%d",
        seen.kin1, seen.kin2, seen.gone, seen.knock, seen.nextchar, seen.nextmap)
    if #fails == 0 then log("PASS shang_soul_escape")
    else log("FAIL shang_soul_escape: %s", table.concat(fails, "; ")) end
    manager.machine:exit()
end

local function cache_fields()
    local want = { ["Coin 1"]=true, ["1 Player Start"]=true,
                   ["P1 High Punch"]=true, ["P1 Low Punch"]=true, ["P1 Right"]=true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do
            if want[f.name] then fields[f.name] = f end
        end
    end
    for n in pairs(want) do
        if not fields[n] then log("MISSING input field: %s", n) end
    end
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting_frame == 0 then
        return name == "P1 High Punch" and p1_confirm > 0 and
               frame >= p1_confirm and frame < p1_confirm + 30
    end
    -- in the fight: walk in, punch - only while a round is actually on
    if seen.status4 > 0 or r16(A.gstate) ~= GS_FIGHTING then return false end
    local t = frame % 16
    if name == "P1 Right" then return true end
    if name == "P1 High Punch" then return t < 3 end
    if name == "P1 Low Punch" then return t >= 8 and t < 11 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("---- Shang defeated: the souls escape ----")
        if #missing > 0 then log("UNRESOLVED symbols: %s", table.concat(missing, ",")) end
    end
    if frame == 120 then
        local fh = io.open(READY, "w"); if fh then fh:write("ok"); fh:close() end
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end

    local gs = r16(A.gstate)
    local ws = r16(A.winner_status)
    if gs == GS_PSEL and charsel_frame == 0 then
        charsel_frame = frame
        log("select screen frame=%d", frame)
    end

    -- select -> fight: P1 Liu Kang human, the CPU is Shang (or, for the
    -- control, Johnny Cage)
    if charsel_frame > 0 and fighting_frame == 0 then
        w16(A.p1_char, FT_KANG)
        w16(A.p2_char, MODE == "control" and FT_CAGE or FT_ST)
        w16(A.p2_state, 0)
        -- Put him on the REAL ladder rung, not just in the seat.  The tail of
        -- every map is fixed - 12 Shang, 13 Kintaro, 14 Shao Kahn (map_1 in
        -- MKSEL.ASM, and build_dynamic_map skips Shang because "he lives in
        -- the tail") - so starting at 12 means beating him advances to
        -- Kintaro, which is the whole point of the hand-off.  Forcing p2_char
        -- alone put him at battle 1 and the next fight was whatever the tower
        -- drew, so the hand-off could never be tested.
        if MODE ~= "control" and A.map_position ~= 0 then
            w16(A.map_position, MAP_SHANG)
        end
        if FORCE_STAGE >= 0 then w16(A.curback, FORCE_STAGE) end
        if p1_confirm == 0 and frame - charsel_frame > 90 then p1_confirm = frame end
        if gs == GS_FIGHTING then
            fighting_frame = frame
            seen.stage = r16(A.curback)
            seen.battle0 = r16(A.battle_num)
            log("fight start frame=%d mode=%s curback=%d p1=%d p2=%d p1_state=%d p2_state=%d",
                frame, MODE, seen.stage, r16(A.p1_char), r16(A.p2_char),
                r16(A.p1_state), r16(A.p2_state))
        end
        if frame > 9000 then log("ERROR never reached a fight"); finish("no fight") end
        return
    end

    -- the next battle beginning is the only proof the round really ended:
    -- the round-end wedge parks at gstate 5 with the last pose still up
    if fighting_frame > 0 and seen.advanced == 0 and seen.battle0
       and r16(A.battle_num) ~= seen.battle0 then
        seen.advanced = frame
        seen.nextchar = r16(A.p2_char)
        seen.nextmap = A.map_position ~= 0 and r16(A.map_position) or -1
        log("next battle at %d: battle_num %d -> %d, gstate %d, p2_char=%d map_position=%d",
            frame, seen.battle0, r16(A.battle_num), gs, seen.nextchar, seen.nextmap)
    end
    -- battle_num moves BEFORE the game writes the next p2_char, so the value on
    -- that frame depends on timing: a run 17 frames behind (the arena haze at
    -- full cost, 2026-09-16) caught it at gstate 5 still reading Shang and
    -- FAILED with the right opponent on the way.  Judge the settled value.
    if seen.advanced > 0 and r16(A.p2_char) ~= seen.nextchar then
        seen.nextchar = r16(A.p2_char)
        log("next opponent settled at %d: p2_char=%d gstate %d", frame, seen.nextchar, gs)
    end
    if seen.advanced > 0 and frame - seen.advanced > 300 then finish("done") end

    -- the fight: pin P1, hold Shang at 1
    if seen.status4 == 0 and gs == GS_FIGHTING then
        w16(A.p1_bar, MAX_HP)
        if r16(A.p2_bar) > 1 then w16(A.p2_bar, 1) end
    end
    if ws == 3 then
        if not seen.status3 then log("status 3 (FINISH HIM) at frame %d", frame) end
        seen.status3 = true
    end
    if ws == 4 and seen.status4 == 0 then
        seen.status4 = frame
        log("status 4 at frame %d (round %d, curback %d, battle %d)",
            frame, r16(A.round_num), r16(A.curback), r16(A.battle_num))
    end

    local esc = s16(r16(A.f_soulesc))
    if esc == 1 and seen.esc1 == 0 then seen.esc1 = frame; log("f_soulesc 1 at %d", frame) end
    if esc == -1 and seen.escm1 == 0 then seen.escm1 = frame; log("f_soulesc -1 at %d (Shang down)", frame) end
    if esc == 0 and seen.escm1 > 0 and seen.esc0 == 0 then seen.esc0 = frame; log("f_soulesc 0 at %d", frame) end
    if seen.status4 > 0 and ws == 1 and seen.declared == 0 then
        seen.declared = frame; log("winner declared (status 1) at %d", frame)
    end

    -- the Kintaro finisher.  f_soul_kintaro is 1 while the arena prop is
    -- crouching to leap and 2 once BGND.ASM has handed him over; the flag is
    -- raised inside Shang's own process, so f_soulesc has not gone -1 yet.
    if A.f_soul_kintaro ~= 0 then
        local k = r16(A.f_soul_kintaro)
        if k == 1 and seen.kin1 == 0 then
            seen.kin1 = frame; log("Kintaro asked to leap at %d", frame)
        end
        if k == 2 and seen.kin2 == 0 then
            seen.kin2 = frame; log("arena prop left the stands at %d", frame)
        end
    end
    if A.f_soul_knock ~= 0 and seen.knock == 0 and r16(A.f_soul_knock) ~= 0 then
        seen.knock = frame; log("stomp knocked the winner back at %d", frame)
    end
    -- soul_shang is a private .bss and never reaches the map, so read the
    -- body through p2_obj - the CPU Shang IS p2 in this rig
    if seen.kin2 > 0 and seen.gone == 0 then
        local o = r32(A.p2_obj)
        if o ~= 0 and (r16(o + OFLAGS2) & M_INVISO) ~= 0 then
            seen.gone = frame; log("Shang's body is gone at %d (+%d)", frame, frame - seen.kin2)
        end
    end
    -- the dropping fight-size Kintaro, every tick he is on the way down:
    -- oid_fx/ochar/shape/scale/palette, which is what tells a garbled blit
    -- from a mispositioned one
    if seen.kin2 > 0 and frame - seen.kin2 < 90 then
        local o, guard = r32(OBJLST), 0
        while o ~= 0 and guard < 200 do
            if r16(o + OCHAR) == 12 then       -- ft_goro
                local id, nm = palid_of(o)
                log("  KIN +%d obj=%08x y=%d x=%d shape=%08x img=%08x fl=%04x fl2=%04x scale=%08x pal=%s",
                    frame - seen.kin2, o, s16(r16(o + OYPOS)), s16(r16(o + OXPOS)),
                    r32(o + OSHAPE), r32(o + OIMG), r16(o + OFLAGS),
                    r16(o + OFLAGS2), r32(o + OSCALE), nm)
            end
            o = r32(o); guard = guard + 1
        end
    end

    if seen.status4 > 0 then
        -- pid_soul is the spawner AND every soul, so a rise in the count is
        -- a new soul; the spawner itself is the very first one, hence the -1.
        local n = count_pid(PID_SOUL)
        if n > souls_prev then seen.spawned = seen.spawned + (n - souls_prev) end
        souls_prev = n
        if n > 0 then seen.soul_frames = seen.soul_frames + 1 end
        if n > seen.souls_peak then seen.souls_peak = n end
        local rel = frame - seen.status4
        -- keep shooting past esc0: the pulp runs 15 frames at soul_pulp_rate
        -- and the round is still up, so the tail of it was never captured
        -- ...and right through the hand-off into the next battle, which is
        -- Kintaro: the whole point is that it runs from the body into the
        -- match with no winner banner, and that is only visible here
        if (seen.advanced == 0 or frame - seen.advanced < 260)
           and rel % SNAP_EVERY == 0 then
            local ok = pcall(function() manager.machine.video:snapshot() end)
            if ok then snaps = snaps + 1 end
        end
        -- sample a WINDOW, not one frame: the pulp walks 15 frames at
        -- soul_pulp_rate and only the later ones carry many pieces
        if DUMP_AT > 0 and rel >= DUMP_AT and rel <= DUMP_AT + 24
           and (rel - DUMP_AT) % 6 == 0 then
            log("==== dump at rel %d ====", rel)
            local o, guard = r32(OBJLST), 0
            while o ~= 0 and guard < 200 do
                local shape = r32(o + OSHAPE)
                local fl2 = r16(o + OFLAGS2)
                local _, pnm = palid_of(o)
                log("  OBJ %08x id=%04x ochar=%d pal=%s z=%d xy=%d,%d fl2=%04x shape=%08x img=%08x %s",
                    o, r16(o + OID), r16(o + OCHAR), pnm, r32(o + OZVAL),
                    s16(r16(o + OXPOS)), s16(r16(o + OYPOS)), fl2, shape, r32(o + OIMG),
                    (fl2 & M_INVISO) ~= 0 and "INVISO" or "")
                -- a multipart object's real content is its shape RAM: 112-bit
                -- records of sag / sizes / control / dx,dy.  A garbled blit is
                -- a bad SAG or a bad size here, and nothing else shows it.
                if (fl2 & 0x0002) ~= 0 then          -- m_multipart
                    local mp = r32(o + OIMG)
                    for p = 0, 31 do        -- FPULP5-7 carry 26 pieces
                        local b = mp + p * 112
                        local w, h = r16(b + 32), r16(b + 48)
                        local sag  = r32(b)
                        if sag == 0 and w == 0 and h == 0 then break end
                        log("      piece %d sag=%08x w=%d h=%d ctrl=%04x dx=%d dy=%d",
                            p, sag, w, h, r16(b + 64),
                            s16(r16(b + 80)), s16(r16(b + 96)))
                    end
                end
                o = r32(o); guard = guard + 1
            end
            -- and the background planes.  Anything VISIBLE on these is drawn
            -- too, and objlst is not the only place a bad blit can come from.
            for n = 1, 8 do
                local head = symbols["baklst" .. n] or 0
                if head ~= 0 then
                    local b, g = r32(head), 0
                    while b ~= 0 and g < 60 do
                        local fl2 = r16(b + OFLAGS2)
                        local _, pnm = palid_of(b)
                        log("  BAK%d %08x ochar=%d pal=%s xy=%d,%d z=%d fl2=%04x shape=%08x %s",
                            n, b, r16(b + OCHAR), pnm,
                            s16(r16(b + OXPOS)), s16(r16(b + OYPOS)), r32(b + OZVAL),
                            fl2, r32(b + OSHAPE),
                            (fl2 & M_INVISO) ~= 0 and "INVISO" or "** VISIBLE **")
                        if (fl2 & 0x0002) ~= 0 and (fl2 & M_INVISO) == 0 then
                            local mp = r32(b + OIMG)
                            for p = 0, 31 do        -- FPULP5-7 carry 26 pieces
                                local q = mp + p * 112
                                local w, h, sag = r16(q + 32), r16(q + 48), r32(q)
                                if sag == 0 and w == 0 and h == 0 then break end
                                log("        piece %d sag=%08x w=%d h=%d ctrl=%04x dx=%d dy=%d",
                                    p, sag, w, h, r16(q + 64), s16(r16(q + 80)), s16(r16(q + 96)))
                            end
                        end
                        b = r32(b); g = g + 1
                    end
                end
            end
        end
        if rel == 26 then
            local used = {}
            for m = 0, 34 do
                local id = r32(PALRAM + m * PALRSIZ)
                if id ~= 0 then used[#used+1] = string.format("%d:%s", m, byaddr[id] or string.format("%08x", id)) end
            end
            log("  FGPAL %d/35 in use: %s", #used, table.concat(used, " "))
        end
        if rel < 40 and rel % 2 == 0 then
            local o = r32(A.p2_obj)
            local id, nm, map = palid_of(o)
            log("  early +%d ochar=%d pal=%s(map %s)", rel,
                o ~= 0 and r16(o + OCHAR) or -1, nm, tostring(map))
        end
        if rel % 30 == 0 then
            local o = r32(A.p2_obj)
            local id, nm, map = palid_of(o)
            log("  +%d gs=%d ws=%d esc=%d souls=%d shang_ochar=%d pal=%s(map %s)",
                rel, gs, ws, esc, n, o ~= 0 and r16(o + OCHAR) or -1, nm, tostring(map))
        end
        if rel > 9000 then finish("timeout") end
    elseif fighting_frame > 0 and frame - fighting_frame > 20000 then
        finish("never beat the CPU")
    end
end)

emu.register_stop(function() if logfh then logfh:close(); logfh = nil end end)
