-- jade_nitro_crouch_test.lua
--
-- "Jade's nitro kick should be dodgeable in crouch stance without blocking."
--
-- Two runs, selected by the NITRO_MODE env var, because one nitro kick per
-- run is the reliable way to test it (the move gates itself on a cooldown and
-- a repeat harness has to fight that):
--
--   NITRO_MODE=crouch   P2 holds DOWN only -- crouching, NOT blocking.
--                       A hit here is the bug.
--   NITRO_MODE=stand    P2 stands still. A hit here is REQUIRED -- it is the
--                       control that proves the kick still works and that a
--                       "pass" in crouch mode is a duck, not a whiff.
--
-- Judged on P2's health bar dropping, which is the only unambiguous signal:
-- p_hitby survives across moves and act_reacting is transient.
--
-- Boot/selection scaffolding lifted from jade_nitro_uppercut_test.lua --
-- Jade is reached by picking Kitana and rewriting p1_char at GS_POST.
--
-- Env: NITRO_MODE, NITRO_LOG
-- Usage: tools\run_jade_nitro_crouch_test.ps1

local ROOT = "C:/Users/you/Workplace/mk2-main"
local MODE = (os.getenv("NITRO_MODE") or "crouch"):lower()
local LOGP = os.getenv("NITRO_LOG") or (ROOT .. "/tools/jade_nitro_crouch_test.log")
local logfh = assert(io.open(LOGP, "a"))
local function log(fmt, ...)
    local s = "[nitro-crouch:" .. MODE .. "] " .. string.format(fmt, ...)
    print(s); logfh:write(s, "\n"); logfh:flush()
end

local symbols = {}
local map = assert(io.open(ROOT .. "/src/mk2.map", "r"))
for line in map:lines() do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
        symbols[name] = tonumber(addr, 16)
    end
end
map:close()
local function sym(name) assert(symbols[name], "missing symbol " .. name); return symbols[name] end

local A = {
    gstate=sym("gstate"), p1_char=sym("p1_char"), p2_char=sym("p2_char"),
    p1_state=sym("p1_state"), p2_state=sym("p2_state"),
    p1_obj=sym("p1_obj"), p2_obj=sym("p2_obj"),
    p1_proc=sym("p1_proc"), p2_proc=sym("p2_proc"),
    p1_bar=sym("p1_bar"), p2_bar=sym("p2_bar"),
}
local P_ACTION, OXPOS, OYPOS, OIMG = 0x1f0, 0x90, 0xb0, 0x1a0
local GS_PSEL, GS_POST, GS_FIGHTING = 4, 0x0d, 2
local FT_KITANA, FT_REPTILE, FT_JADE = 4, 9, 16
local PS_ACTIVE, ACT_SHADK = 1, 0x0205
local ACT_DUCK, ACT_BLOCKHI, ACT_BLOCKLO = 0x0302, 0x0700, 0x0701

-- Inside stk_fn_nitro's reach: the box runs oxpos+x_offset-x_size ..
-- oxpos+x_offset = +29..+103 in front, and Jade drives forward during it.
local GAP = 70

local frame, space = 0, nil
local fields = {}
local charsel, confirm, fight = 0, 0, 0
local p2hp0, p2hp_low = nil, nil
local nitro_seen, finished = false, false
local p2_was_blocking, p2_was_ducking = false, false
local staged = false

local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a,v) space:write_u16(a, v & 0xffff) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function action(procaddr)
    local p = r32(procaddr); return p ~= 0 and r16(p + P_ACTION) or 0xffff
end
local function objx(objaddr)
    local o = r32(objaddr); return o ~= 0 and s16(r16(o + OXPOS)) or 0
end
local function set_objx(objaddr, x)
    local o = r32(objaddr); if o ~= 0 then space:write_u16(o + OXPOS, x & 0xffff) end
end

-- Multipart bounds, the same geometry strike_check's highest_mpart /
-- lowest_mpart walk. Needed to size the fix rather than guess it: the answer
-- is "how far above the crouching victim's TOP does the kick's box bottom
-- have to sit".
local function bounds(objaddr)
    local o = r32(objaddr); if o == 0 then return 0,0,0,0 end
    local img = r32(o + OIMG); if img == 0 then return 0,0,0,0 end
    local x, y = s16(r16(o + OXPOS)), s16(r16(o + OYPOS))
    local l,t,r,b = 0x7fff,0x7fff,-0x7fff,-0x7fff
    for i = 0, 15 do
        local q = img + i*0x70
        local xs,ys = s16(r16(q+0x20)), s16(r16(q+0x30))
        local xo,yo = s16(r16(q+0x50)), s16(r16(q+0x60))
        local pl,pt = x-xo, y-yo
        l=math.min(l,pl); t=math.min(t,pt); r=math.max(r,pl+xs); b=math.max(b,pt+ys)
        if r32(q+0x70) == 0 then break end
    end
    return l,t,r,b
end

-- stk_fn_nitro, MKSTK.ASM
local STK_YOFF, STK_YSIZE = 0x2e, 0x10
local geom_logged = 0

local function finish(ok, why)
    if finished then return end
    finished = true
    local dmg = (p2hp0 or 0) - (p2hp_low or 0)
    log("RESULT mode=%s nitro_came_out=%s p2_damage=%d (hp %d->%d) ducked=%s blocked=%s",
        MODE, tostring(nitro_seen), dmg, p2hp0 or -1, p2hp_low or -1,
        tostring(p2_was_ducking), tostring(p2_was_blocking))
    log("%s %s", ok and "PASS" or "FAIL", why)
    logfh:close(); manager.machine:exit()
end

local function cache_fields()
    local wanted = {
        ["UI Select"]=true, ["Coin 1"]=true, ["Coin 2"]=true,
        ["1 Player Start"]=true, ["2 Players Start"]=true,
        ["P1 Down"]=true, ["P1 Right"]=true, ["P1 Low Kick"]=true,
        ["P1 High Punch"]=true, ["P2 Down"]=true, ["P2 High Punch"]=true,
    }
    for _,port in pairs(manager.machine.ioport.ports) do
        for _,field in pairs(port.fields) do
            if wanted[field.name] then fields[field.name] = field end
        end
    end
end

local function pressed(name)
    if name == "UI Select" then return frame >= 5 and frame < 35 end
    if name == "Coin 1" or name == "Coin 2" then
        return charsel == 0 and frame >= 700 and frame < 980 and frame % 80 < 20
    end
    if name == "1 Player Start" then return charsel == 0 and frame >= 1000 and frame < 1080 end
    if name == "2 Players Start" then
        if charsel > 0 and fight == 0 then local r=frame-charsel; return r>=5 and r<45 end
        return charsel == 0 and frame >= 1040 and frame < 1140
    end
    if charsel > 0 and fight == 0 and confirm > 0 then
        if name == "P1 High Punch" then return frame >= confirm and frame < confirm+40 end
        if name == "P2 High Punch" then return frame >= confirm+70 and frame < confirm+110 end
    end
    if fight == 0 then return false end

    local r = frame - fight
    -- P2 crouches for the whole window in crouch mode, and never presses
    -- block: the point of the test is that a plain duck is enough.
    if name == "P2 Down" then return MODE == "crouch" and r >= 55 and r < 260 end
    -- D,F+LK
    if name == "P1 Down"     then return r >= 80 and r < 84 end
    if name == "P1 Right"    then return r >= 86 and r < 90 end
    if name == "P1 Low Kick" then return r >= 92 and r < 98 end
    return false
end

emu.register_frame(function()
    frame = frame + 1
    if frame == 1 then
        space = manager.machine.devices[":maincpu"].spaces["program"]
        cache_fields(); log("loaded, gap=%d", GAP)
    end
    if not space or finished then return end

    local gs = r16(A.gstate)
    if gs == GS_PSEL then
        if charsel == 0 then charsel = frame end
        w16(A.p1_state,PS_ACTIVE); w16(A.p2_state,PS_ACTIVE)
        w16(A.p1_char,FT_KITANA); w16(A.p2_char,FT_REPTILE)
        if confirm == 0 and frame-charsel > 90 then confirm = frame end
    elseif gs == GS_POST then
        w16(A.p1_char,FT_JADE)
    elseif gs == GS_FIGHTING then
        w16(A.p2_state,PS_ACTIVE)
        if fight == 0 then
            fight = frame; p2hp0 = r16(A.p2_bar); p2hp_low = p2hp0
            if r16(A.p1_char) ~= FT_JADE then finish(false,"Jade selection failed"); return end
            log("fight frame=%d", frame)
        end
    end

    if fight > 0 then
        local r = frame - fight
        -- Set the gap ONCE, before the kick. Pinning every frame would fight
        -- the move's own forward drive and measure the harness instead.
        if r == 60 and not staged then
            staged = true
            set_objx(A.p2_obj, objx(A.p1_obj) + GAP)
            log("staged gap x=%d/%d", objx(A.p1_obj), objx(A.p2_obj))
        end

        local p1act, p2act = action(A.p1_proc), action(A.p2_proc)
        if p1act == ACT_SHADK then
            nitro_seen = true
            -- Log the geometry for the first few active frames: the kick's
            -- strike box against the victim's actual top/bottom.
            if geom_logged < 6 then
                geom_logged = geom_logged + 1
                local jo = r32(A.p1_obj)
                local jy = jo ~= 0 and s16(r16(jo + OYPOS)) or 0
                local top, bot = jy + STK_YOFF, jy + STK_YOFF + STK_YSIZE
                local _, vt, _, vb = bounds(A.p2_obj)
                log("  geom jade_oypos=%d strikebox_y=%d..%d   victim_y=%d..%d  %s",
                    jy, top, bot, vt, vb,
                    (bot >= vt and top <= vb) and "OVERLAP" or "clear")
            end
        end
        if p2act == ACT_DUCK then p2_was_ducking = true end
        if p2act == ACT_BLOCKHI or p2act == ACT_BLOCKLO then p2_was_blocking = true end
        p2hp_low = math.min(p2hp_low, r16(A.p2_bar))

        if r > 260 then
            local hit = p2hp_low < p2hp0
            if not nitro_seen then
                finish(false, "the nitro kick never came out - trial proves nothing")
            elseif MODE == "crouch" then
                if p2_was_blocking then
                    finish(false, "P2 blocked; this must be a plain duck to mean anything")
                elseif hit then
                    finish(false, "crouching P2 was hit -- the kick is not duckable")
                else
                    finish(true, "crouching P2 took no damage without blocking")
                end
            else
                if hit then
                    finish(true, "standing P2 was hit -- the kick still works")
                else
                    finish(false, "standing P2 was NOT hit -- the kick whiffs entirely, "
                        .. "so a crouch 'pass' would be meaningless")
                end
            end
            return
        end
    end

    if charsel == 0 and frame > 1600 then finish(false,"never reached character select"); return end
    for name,field in pairs(fields) do field:set_value(pressed(name) and 1 or 0) end
end)
