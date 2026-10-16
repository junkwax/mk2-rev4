-- cage_shadow_ghost_demo.lua - what Cage's shadow kick costs, and what it
-- would look like drawn as ghost_rec afterimages instead.
--
-- No rebuild: this runs on any ROM that has the ghost code compiled in.
--   CSG_MODE=stock  the game's own trail_proc shadows (7 of them)
--   CSG_MODE=ghost  every pid_trail / shadow_dummy_proc process is sent to
--                   sucide as it appears, and ghost_rec is armed on Cage
--                   instead - the same 4 ghosts a producer would ask for
--
-- Both modes drive the identical fight and inputs, capture the same frames,
-- and log the free object / process counts every frame of the kick, so the
-- pools can be compared directly.
--
-- Cage's shadow kick is scom_jc_shadow: Back, Forward + Low Kick.
--
-- env: CSG_MODE (stock|ghost), CSG_LOG, CSG_STAGE, MK2_ROOT
local ROOT = (os.getenv("MK2_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local MODE = os.getenv("CSG_MODE") or "stock"
local STAGE = tonumber(os.getenv("CSG_STAGE") or "0")
local LOG = os.getenv("CSG_LOG") or (ROOT .. "/tools/cage_shadow_ghost_demo.log")

local logfh = assert(io.open(LOG, "w"))
local function log(fmt, ...)
    local line = "[csg] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end

local symbols = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do symbols[n] = tonumber(a, 16) end
end
local function sym(n) return assert(symbols[n], "missing map symbol " .. n) end
local A = {
    gstate = sym("gstate"), curback = sym("curback"), map_position = sym("map_position"),
    battle_num = sym("battle_num"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p1_state = sym("p1_state"), p2_state = sym("p2_state"),
    p1_obj = sym("p1_obj"), p2_obj = sym("p2_obj"), p1_proc = sym("p1_proc"),
    p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    p1_bar_view = sym("p1_bar_view"), p2_bar_view = sym("p2_bar_view"),
    winner_status = sym("winner_status"), active = sym("active"),
    ofree = symbols["ofree"], pfree = symbols["free"], sucide = sym("sucide"),
    gh_src = sym("gh_src"), gh_n = sym("gh_n"), gh_gap = sym("gh_gap"),
    gh_col = sym("gh_col"), gh_life = sym("gh_life"), ghost_lst = sym("ghost_lst"),
}
local PROCID, PWAKE, OXVAL, OXPOS, PACTION = 0x20, 0xe0, 0x080, 0x090, 0x1f0
local PID_TRAIL, PID_JC1, PID_JC2 = 0x0104, 0x0106, 0x0107   -- MAINEQU pid_trail / pid_jc_shadow1 / 2
local GS_PSEL, GS_FIGHTING, MAXBAR = 4, 2, 0xa1
local ACT_SHADK = 0x0205        -- MAINEQU act_shadk
local PENS = { 0x0b0b, 0x0505, 0x0404, 0x0a0a }

local frame, space, fields = 0, nil, {}
local charsel, fighting, confirm = 0, 0, 0
local kick_at, snaps, killed = 0, 0, 0
local pool = {}
local finished = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end
local function w32(a, v) space:write_u32(a, v & 0xffffffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end

local function free_len(head, cap)
    if not head then return nil end
    local n, p = 0, r32(head)
    while p ~= 0 and n < cap do n = n + 1; p = r32(p) end
    return n
end
local function list_len(head)
    local n, p = 0, r32(head)
    while p ~= 0 and n < 16 do n = n + 1; p = r32(p) end
    return n
end
local function p1_action() local p = r32(A.p1_proc); return p ~= 0 and r16(p + PACTION) or 0xffff end

-- every live process whose id looks like a trail helper, sent to sucide
local function kill_trail_procs()
    local p, guard = r32(A.active), 0
    while p ~= 0 and guard < 200 do
        local id = r16(p + PROCID)
        if id == PID_TRAIL or id == PID_JC1 or id == PID_JC2 then
            w32(p + PWAKE, A.sucide)
            killed = killed + 1
        end
        p = r32(p); guard = guard + 1
    end
end

local function arm_ghosts()
    local o = r32(A.p1_obj)
    if o == 0 then return end
    w32(A.gh_src, A.p1_obj)
    w16(A.gh_n, 4); w16(A.gh_gap, 3); w16(A.gh_life, 40)
    for i, pen in ipairs(PENS) do w16(A.gh_col + (i - 1) * 16, pen) end
end

local function cache_fields()
    local want = { ["Coin 1"] = true, ["2 Players Start"] = true, ["P1 High Punch"] = true,
                   ["P2 High Punch"] = true, ["P1 Left"] = true, ["P1 Right"] = true, ["P1 Low Kick"] = true }
    for _, port in pairs(manager.machine.ioport.ports) do
        for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
    end
end

local function pressed(name)
    if charsel == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "2 Players Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fighting == 0 then
        return (name == "P1 High Punch" or name == "P2 High Punch") and confirm > 0
               and frame >= confirm and frame < confirm + 40
    end
    local rel = frame - fighting
    -- scom_jc_shadow: Back, Forward, then Low Kick (window 0x18 = 24 ticks)
    if name == "P1 Left" then return rel >= 80 and rel < 86 end
    if name == "P1 Right" then return rel >= 90 and rel < 96 end
    if name == "P1 Low Kick" then return rel >= 92 and rel < 98 end
    return false
end

local function finish()
    if finished then return end
    finished = true
    local mn, mx = 999, 0
    for _, v in ipairs(pool) do mn = math.min(mn, v.obj); mx = math.max(mx, v.obj) end
    local pmn, pmx = 999, 0
    for _, v in ipairs(pool) do pmn = math.min(pmn, v.proc); pmx = math.max(pmx, v.proc) end
    log("RESULT mode=%s kick_at=%d snaps=%d killed=%d free_obj %d..%d free_proc %d..%d samples=%d",
        MODE, kick_at, snaps, killed, mn, mx, pmn, pmx, #pool)
    manager.machine:exit()
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields()
        log("start mode=%s stage=%d", MODE, STAGE)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space or finished then return end
    local gs = r16(A.gstate)
    if gs == GS_PSEL and charsel == 0 then charsel = frame end
    if charsel > 0 and fighting == 0 then
        w16(A.p1_state, 1); w16(A.p2_state, 1)
        w16(A.p1_char, 2); w16(A.p2_char, 11)      -- Cage vs Jax
        w16(A.curback, STAGE); w16(A.map_position, 0); w16(A.battle_num, 1)
        if confirm == 0 and frame - charsel > 90 then confirm = frame end
    end
    if gs == GS_FIGHTING and fighting == 0 then
        fighting = frame
        log("PREARM frame=%d p1x=%d p2x=%d", frame, s16(r16(r32(A.p1_obj) + OXPOS)), s16(r16(r32(A.p2_obj) + OXPOS)))
    end
    if fighting == 0 then
        if frame > 7000 then log("ERROR never reached fight"); finish() end
        return
    end
    w16(A.p1_bar, MAXBAR); w16(A.p2_bar, MAXBAR)
    w16(A.p1_bar_view, MAXBAR); w16(A.p2_bar_view, MAXBAR)
    w16(A.winner_status, 0)

    if p1_action() == ACT_SHADK and kick_at == 0 then
        kick_at = frame
        log("KICK frame=%d rel=%d", frame, frame - fighting)
        if MODE == "ghost" then arm_ghosts() end
    end
    if MODE == "ghost" and kick_at > 0 then kill_trail_procs() end

    if kick_at > 0 then
        local rel = frame - kick_at
        if rel <= 60 then
            pool[#pool + 1] = { obj = free_len(A.ofree, 400) or 0, proc = free_len(A.pfree, 200) or 0 }
            if rel % 3 == 0 and snaps < 16 then
                manager.machine.video:snapshot()
                snaps = snaps + 1
                log("SNAP rel=%d free_obj=%s free_proc=%s ghosts=%d", rel,
                    tostring(free_len(A.ofree, 400)), tostring(free_len(A.pfree, 200)), list_len(A.ghost_lst))
            end
        elseif rel > 120 then
            finish()
        end
    elseif frame - fighting > 400 then
        log("ERROR shadow kick never came out")
        finish()
    end
end)

emu.register_stop(function() if logfh then logfh:close() end end)
