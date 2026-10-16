--- raiden_ambient_victory_test.lua - does the ambient crackle bleed into the
--- victory stance?
---
--- Raiden has two unrelated bolt effects:
---   ambient  RN1BOLT..RN6BOLT (RADBOLT1.IMG), spawned by `lightning`
---            (MKGUYS.ASM) every 16-47 ticks while the round is live.
---   victory  RNVICBOLT        (RADBOLT2.IMG), spawned by `victory_lighting`
---            (MKCANNED.ASM) once, ~42 frames into the victory pose.
---
--- Only the victory pair belongs on the victory stance.  `lightning` shuts
--- down the moment the round stops being live, but it used to animate a flash
--- with a plain `mframew`, which always runs the animation to its end - so a
--- flash that was still in the air when the round was decided kept crackling
--- on top of the pose for up to ~36 ticks.
---
--- This harness forces exactly that race instead of waiting for it: it watches
--- for the frame an ambient bolt object APPEARS and kills P2 on that frame, so
--- the round ends with a flash at its very first frame.  Then it reports how
--- long ambient bolt objects survive past the win.
---
--- Env: RDAMB_LOG, RDAMB_OBSERVE (frames after the win, default 200),
---      RDAMB_GRACE (frames of ambient bolt allowed after the win, default 4)

local ROOT = "C:/Users/you/Workplace/mk2-main"

local LOG_PATH = os.getenv("RDAMB_LOG") or (ROOT .. "/tools/raiden_ambient_victory_test.log")
local OBSERVE = tonumber(os.getenv("RDAMB_OBSERVE") or "") or 200
local GRACE = tonumber(os.getenv("RDAMB_GRACE") or "") or 4

local logfh = io.open(LOG_PATH, "w")
local frame = 0
local raw_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    raw_print(line)
    if logfh then logfh:write(line, "\n"); logfh:flush() end
end
local function log(fmt, ...)
    print("[rdamb] " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
end

local symbols = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                symbols[name] = tonumber(addr, 16)
            end
        end
        fh:close()
    end
end
local function sym(n)
    if symbols[n] == nil then log("WARN missing symbol %s", n) end
    return symbols[n] or 0
end

local A = {
    gstate = sym("gstate"), winner_status = sym("winner_status"),
    f_thatsall = sym("f_thatsall"),
    p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    curback = sym("curback"),
    objlst = sym("objlst"), objlst2 = sym("objlst2"), objlst3 = sym("objlst3"),
}
local O = { next = 0x000, oxpos = 0x090, oypos = 0x0b0, osag = 0x100, oimg = 0x1a0 }

local GS_PSEL, GS_FIGHTING = 4, 2
local FT_RAIDEN, FT_JAX = 7, 11
local STAGE_ID = 5

local cpu, space, fields = nil, nil, {}
local last_gstate = -1
local charsel_frame, fighting_frame = 0, 0
local p1_confirm_start = 0
local killed_frame, win_frame = 0, 0
local finished = false
local snap_index = 0
local amb_present_last = false
local amb_last_seen, amb_first_after_win = -1, -1
local amb_flashes_seen = 0
local vic_first_seen, vic_last_seen = -1, -1

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

-- SAG -> label for both bolt families, so an object can be identified by the
-- art it is pointing at (same trick as raiden_victory_test.lua).
local function load_sags(pattern)
    local out, n = {}, 0
    local fh = io.open(ROOT .. "/src/MKBOLTS.TBL", "r")
    local current = nil
    if fh then
        for line in fh:lines() do
            local label = line:match("^(" .. pattern .. "):")
            if label then current = label end
            if current then
                local raw = line:match("%.long%s+0?([%x]+)[Hh]")
                if raw then
                    out[tonumber(raw, 16) & 0x00ffffff] = current
                    current = nil
                    n = n + 1
                end
            end
        end
        fh:close()
    end
    return out, n
end

local ambient_sags, vic_sags
do
    local n1, n2
    ambient_sags, n1 = load_sags("RN%dBOLT[%w]+")
    vic_sags, n2 = load_sags("RNVICBOLT[%w]+")
    log("loaded %d ambient RN*BOLT SAGs, %d RNVICBOLT SAGs", n1, n2)
end

local function cache_fields()
    local wanted = { ["Coin 1"] = true, ["Coin 2"] = true, ["2 Players Start"] = true,
                     ["P1 High Punch"] = true, ["P2 High Punch"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
    for name in pairs(wanted) do
        if not fields[name] then log("input %s MISSING", name); return false end
    end
    return true
end

local function main_screen()
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then return s end
    ok, s = pcall(function() return manager.machine.screens:at(1) end)
    return ok and s or nil
end

local function snap(label)
    local s = main_screen()
    local ok = false
    if s then ok = pcall(function() s:snapshot() end) end
    log("SNAP idx=%04d frame=%d label=%s ok=%s", snap_index, frame, label, tostring(ok))
    snap_index = snap_index + 1
end

local function walk(fn)
    for _, list in ipairs({ A.objlst, A.objlst2, A.objlst3 }) do
        if list ~= 0 then
            local obj, guard, seen = r32(list), 0, {}
            while obj ~= 0 and guard < 400 do
                if seen[obj] then break end
                seen[obj] = true
                fn(obj)
                obj = r32(obj + O.next)
                guard = guard + 1
            end
        end
    end
end

-- Returns two lists: ambient bolt objects, victory bolt objects.
local function bolt_objects()
    local amb, vic = {}, {}
    walk(function(obj)
        local sag1 = r32(obj + O.osag) & 0x00ffffff
        local img = r32(obj + O.oimg)
        local sag2 = img ~= 0 and (r32(img) & 0x00ffffff) or 0
        local a = ambient_sags[sag1] or ambient_sags[sag2]
        local v = vic_sags[sag1] or vic_sags[sag2]
        local where = string.format("@(%d,%d)", r16(obj + O.oxpos), r16(obj + O.oypos))
        if a then amb[#amb + 1] = a .. where end
        if v then vic[#vic + 1] = v .. where end
    end)
    table.sort(amb); table.sort(vic)
    return amb, vic
end

local function state_line(tag)
    local amb, vic = bolt_objects()
    return string.format("%s gs=%d ws=%d thatsall=%d p1hp=%d p2hp=%d amb=%d[%s] vic=%d[%s]",
        tag, r16(A.gstate), r16(A.winner_status),
        A.f_thatsall ~= 0 and r16(A.f_thatsall) or -1,
        r16(A.p1_bar), r16(A.p2_bar),
        #amb, table.concat(amb, " "), #vic, table.concat(vic, " "))
end

local function finish(ok, reason)
    if finished then return end
    finished = true
    snap(ok and "final_ok" or ("final_" .. reason))
    log("%s reason=%s | %s", ok and "PASS" or "FAIL", reason, state_line("end"))
    if logfh then logfh:flush() end
    manager.machine:exit()
end

local function pressed(name)
    if charsel_frame == 0 then
        if name == "Coin 1" or name == "Coin 2" then
            return frame >= 220 and frame < 6000 and (frame % 80) < 20
        end
        if name == "2 Players Start" then
            return frame >= 260 and frame < 6000 and (frame % 80) >= 30 and (frame % 80) < 55
        end
    end
    if charsel_frame > 0 and fighting_frame == 0 then
        if name == "P1 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start and frame < p1_confirm_start + 40
        end
        if name == "P2 High Punch" and p1_confirm_start > 0 then
            return frame >= p1_confirm_start + 80 and frame < p1_confirm_start + 120
        end
    end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        cpu = manager.machine.devices[":maincpu"]
        space = cpu.spaces["program"]
        if not cache_fields() then finish(false, "input_missing"); return end
        log("ambient-bolt / victory overlap probe; observe=%d grace=%d", OBSERVE, GRACE)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs ~= last_gstate then
        if gs == GS_PSEL and charsel_frame == 0 then charsel_frame = frame end
        if gs == GS_FIGHTING and last_gstate ~= GS_FIGHTING and fighting_frame == 0 then
            fighting_frame = frame
            log("fight_start frame=%d | %s", frame, state_line("fs"))
        end
        last_gstate = gs
    end

    if fighting_frame == 0 then
        w16(A.p1_char, FT_RAIDEN)
        w16(A.p2_char, FT_JAX)
        w16(A.curback, STAGE_ID)
        if A.p1_state ~= 0 then w16(A.p1_state, 1) end
        if A.p2_state ~= 0 then w16(A.p2_state, 1) end
        if charsel_frame > 0 and p1_confirm_start == 0 and frame > charsel_frame + 90
            and r16(A.p1_char) == FT_RAIDEN and r16(A.p2_char) == FT_JAX then
            p1_confirm_start = frame + 25
        end
    end

    local amb, vic = {}, {}
    if fighting_frame > 0 then
        amb, vic = bolt_objects()
        local amb_now = #amb > 0

        -- Force the race: end the round on the frame a fresh ambient flash
        -- starts, so the flash has its whole animation still to play.
        if killed_frame == 0 and frame > fighting_frame + 120 then
            if amb_now and not amb_present_last then
                amb_flashes_seen = amb_flashes_seen + 1
                w16(A.p2_bar, 0)
                killed_frame = frame
                log("flash_started_and_killed_p2 frame=%d | %s", frame, state_line("kill"))
            end
        end
        amb_present_last = amb_now
    end

    if killed_frame > 0 and win_frame == 0 then
        local ws = r16(A.winner_status)
        if ws == 1 or ws == 2 then
            win_frame = frame
            log("winner_declared frame=%d (%d after kill) | %s",
                frame, frame - killed_frame, state_line("win"))
        end
    end

    if win_frame > 0 then
        local rel = frame - win_frame
        if #amb > 0 then
            if amb_first_after_win < 0 then amb_first_after_win = rel end
            amb_last_seen = rel
        end
        if #vic > 0 then
            if vic_first_seen < 0 then vic_first_seen = rel end
            vic_last_seen = rel
        end
        if rel <= 60 or rel % 20 == 0 then log("rel=%-3d | %s", rel, state_line("obs")) end
        if (rel == 0 or rel == 10 or rel == 30 or rel == 60 or rel == 120) then
            snap(string.format("vic_%03d", rel))
        end
        if rel >= OBSERVE then
            log("ambient after win: first=%d last=%d | victory bolts: first=%d last=%d",
                amb_first_after_win, amb_last_seen, vic_first_seen, vic_last_seen)
            if amb_last_seen > GRACE then
                finish(false, "ambient_bolt_on_victory_until_rel_" .. amb_last_seen)
            elseif vic_first_seen < 0 then
                finish(false, "victory_bolts_never_appeared")
            else
                finish(true, string.format("ambient_gone_by_rel_%d_victory_bolts_%d_%d",
                    math.max(amb_last_seen, 0), vic_first_seen, vic_last_seen))
            end
            return
        end
    end

    if frame > 6000 and win_frame == 0 then
        finish(false, killed_frame == 0 and "no_ambient_flash_seen" or "never_reached_victory")
        return
    end

    for name, field in pairs(fields) do
        field:set_value(pressed(name) and 1 or 0)
    end
end)
