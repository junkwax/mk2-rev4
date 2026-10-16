-- jade_lk_test.lua - retail's secret JADE fight (jade_check, MKTOAST.ASM).
--
--   1P game, P1 Liu Kang vs a forced CPU Jax.  map_position is held at 10 - the
--   match before the "?" - for the whole first round, P1's bar is pinned full
--   and the CPU's held at 1, and P1 walks in kicking.  jade_check runs after
--   every round's bonus_count: a winner who pressed none of HP / LP / Block /
--   HK that round is sent to gs_sec_intro and fights Jade.
--
--   JL_MODE  lk  - Low Kick only: must reach gs_sec_intro and a Jade fight
--            hp  - High Punch as well (the control): must NOT
--   JL_LOG   log path;  MK2_ROOT  tree whose src/mk2.map matches the ROM
if _G.JL_LOADED then return end
_G.JL_LOADED = true
local ROOT = (os.getenv("MK2_ROOT") or "."):gsub("\\", "/")
local MODE = os.getenv("JL_MODE") or "lk"
local logfh = assert(io.open(assert(os.getenv("JL_LOG"), "JL_LOG"), "w"))
local function log(fmt, ...)
    local line = "[jl] " .. string.format(fmt, ...)
    print(line); logfh:write(line, "\n"); logfh:flush()
end
local function finish(verdict, fmt, ...)
    log("%s " .. fmt, verdict, ...); logfh:close(); manager.machine:exit()
end

local S = {}
for line in assert(io.open(ROOT .. "/src/mk2.map")):lines() do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[n] = tonumber(a, 16) end
end
local function sym(n) return assert(S[n], "missing map symbol " .. n) end
local A = {
    gstate = sym("gstate"), p1_char = sym("p1_char"), p2_char = sym("p2_char"),
    p2_state = sym("p2_state"), p1_bar = sym("p1_bar"), p2_bar = sym("p2_bar"),
    winner_status = sym("winner_status"), map_position = sym("map_position"),
    f_secret = sym("f_secret"), p1_matchw = sym("p1_matchw"),
}
local GS_PSEL, GS_FIGHTING, GS_SEC_INTRO = 4, 2, 0x0f
local MAX_HP, FT_KANG, FT_JAX, FT_JADE = 0xa1, 1, 11, 16

local frame, space, fields = 0, nil, {}
local charsel, confirm, fight, decided, secret = 0, 0, 0, 0, 0
local last_gs

local function r16(a) return space:read_u16(a) end
local function w16(a, v) space:write_u16(a, v & 0xffff) end

local function pressed(name)
    if charsel == 0 then
        if name == "Coin 1" then return frame >= 150 and frame < 1000 and (frame % 60) < 20 end
        if name == "1 Player Start" then return frame >= 1000 and frame < 1080 end
        return false
    end
    if fight == 0 then
        return name == "P1 High Punch" and confirm > 0 and frame >= confirm and frame < confirm + 30
    end
    if decided > 0 or r16(A.gstate) ~= GS_FIGHTING then return false end
    local t = frame % 16
    if name == "P1 Right" then return true end
    if name == "P1 Low Kick" then return t < 3 end
    if name == "P1 High Punch" then return MODE == "hp" and t >= 8 and t < 11 end
    return false
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        local want = { ["Coin 1"] = 1, ["1 Player Start"] = 1, ["P1 High Punch"] = 1, ["P1 Low Kick"] = 1,
                       ["P1 Right"] = 1 }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if want[f.name] then fields[f.name] = f end end
        end
        log("START mode=%s", MODE)
    end
    for n, f in pairs(fields) do f:set_value(pressed(n) and 1 or 0) end
    if not space then return end
    local gs = r16(A.gstate)

    if gs == GS_PSEL and charsel == 0 then charsel = frame; log("select frame=%d", frame) end
    if charsel > 0 and fight == 0 then
        w16(A.p1_char, FT_KANG); w16(A.p2_char, FT_JAX); w16(A.p2_state, 0)
        if confirm == 0 and frame - charsel > 90 then confirm = frame end
        if gs == GS_FIGHTING then
            fight = frame
            log("FIGHT frame=%d p1=%d p2=%d", frame, r16(A.p1_char), r16(A.p2_char))
        end
        if frame > 9000 then finish("NOVERDICT", "never reached the fight") end
        return
    end

    if gs ~= last_gs then
        log("gstate %d -> %d frame=%d winner_status=%d map_position=%d f_secret=%d p2_char=%d",
            last_gs or -1, gs, frame, r16(A.winner_status), r16(A.map_position), r16(A.f_secret),
            r16(A.p2_char))
        last_gs = gs
    end
    if decided == 0 then
        w16(A.map_position, 10)
        if gs == GS_FIGHTING then
            w16(A.p1_bar, MAX_HP)
            if r16(A.p2_bar) > 1 then w16(A.p2_bar, 1) end
        end
        if r16(A.winner_status) == 1 then decided = frame; log("ROUND_WON frame=%d", frame) end
        if frame - fight > 6000 then finish("NOVERDICT", "round never won") end
        return
    end
    if gs == GS_SEC_INTRO and secret == 0 then secret = frame; log("SEC_INTRO frame=%d", frame) end
    if secret > 0 and gs == GS_FIGHTING then
        local p2 = r16(A.p2_char)
        if MODE == "lk" and p2 == FT_JADE then finish("PASS", "Low Kick only -> fighting Jade") end
        finish("FAIL", "secret intro but opponent is %d", p2)
    end
    if frame - decided > 2500 then
        if MODE == "hp" and secret == 0 then finish("PASS", "High Punch pressed -> no Jade (control)") end
        finish("FAIL", "mode=%s secret=%d gstate=%d f_secret=%d p2_char=%d", MODE, secret, gs,
            r16(A.f_secret), r16(A.p2_char))
    end
end)
