-- wolf_kano_check.lua - MK1 KANO (Wolf only, ochar 22): Shang Tsung's morph
-- into him (Back, Forward + Block - kn_st_morph_check, MK1KNM.ASM), his body
-- playing MK2's normals on his MK1 frames, and his two MK1 specials:
--   knife      hold Block, Back, Forward   -> action 0008h (act_throw_fans)
--   cannonball hold Block, F, D, B, U       -> action 020eh (act_kano)
-- Requires: ochar goes to 22; every piece P1 is drawn with while he is Kano
-- (outside act_morph) is in the MK1KNO pack (src/MK1KNO.TBL); both specials
-- seen; illop_count unchanged.  Snapshots every 40 frames after the morph.
-- Env: WS_MAP tmp/wolf/src/MK2.MAP, WS_TBL src/MK1KNO.TBL
local LOG = os.getenv("WB_LOG")
local f = nil
local function log(fmt, ...)
    if not f then f = io.open(LOG, "w"); f:write("wolf_kano_check start\n") end
    f:write(string.format(fmt, ...) .. "\n"); f:flush()
end

local S = {}
for line in io.lines(os.getenv("WS_MAP")) do
    for addr, name in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do S[name] = tonumber(addr, 16) end
end
-- her SAG range, from the pack's own table
local SAG_LO, SAG_HI = nil, nil
do
    for l in io.lines(os.getenv("WS_TBL")) do
        local h = l:match("%.long%s+0?(%x+)[hH]")
        if h and #h >= 7 then
            local v = tonumber(h, 16)
            if v >= 0x6000000 then
                SAG_LO = SAG_LO and math.min(SAG_LO, v) or v
                SAG_HI = SAG_HI and math.max(SAG_HI, v) or v
            end
        end
    end
end
local A = {}
for _, n in ipairs({"gstate", "p1_char", "p2_char", "p1_obj", "p2_obj", "p1_proc", "p2_proc",
                    "curback", "illop_count", "p1_bar", "p2_bar"}) do
    A[n] = S[n] or error("no symbol " .. n)
end
local O = { oxpos = 0x090, oypos = 0x0b0, oimg = 0x1a0, ochar = 0x1f0 }
local P = { action = 0x1f0 }

local space = manager.machine.devices[":maincpu"].spaces["program"]
local function r16(a) return space:read_u16(a) end
local function r32(a) return space:read_u32(a) end
local function w16(a, v) space:write_u16(a, v) end
local NAMES = {"Coin 1", "2 Players Start", "P1 High Punch", "P2 High Punch", "P1 Low Punch",
               "P1 High Kick", "P1 Low Kick", "P1 Block", "P1 Up", "P1 Down", "P1 Left", "P1 Right",
               "P2 Low Kick", "P2 Left", "P2 Right"}
local F = {}
for _, n in ipairs(NAMES) do
    for _, q in pairs(manager.machine.ioport.ports) do if q.fields[n] then F[n] = q.fields[n] end end
    if not F[n] then error("no input " .. n) end
end

-- the pieces P1 is drawn with: a multipart object's oimg is its SHAPE RAM,
-- 112-bit nodes (DISPEQU: mp_sag 0, sizes, control, anipoints) ended by a 0
local function sags(o)
    local out = {}
    local node = r32(o + O.oimg)
    for _ = 1, 32 do
        if node == 0 then break end
        local s = r32(node)
        if s == 0 then break end
        out[#out + 1] = s
        node = node + 112
    end
    return out
end

local frame, started = 0, false
local sel, fight, confirm, morph_f, ill0 = nil, nil, nil, nil, nil
local seen, own, other, script_i = {}, 0, 0, 1
-- the moves after the morph: {frames, {inputs...}}
local SCRIPT = {
    {40, {}},
    -- the knife: hold Block, Back, Forward
    {4, {"P1 Block"}}, {4, {"P1 Block", "P1 Left"}}, {2, {"P1 Block"}}, {4, {"P1 Block", "P1 Right"}}, {80, {}},
    -- the cannonball: hold Block, Forward, Down, Back, Up
    {4, {"P1 Block"}}, {4, {"P1 Block", "P1 Right"}}, {4, {"P1 Block", "P1 Down"}},
    {4, {"P1 Block", "P1 Left"}}, {4, {"P1 Block", "P1 Up"}}, {90, {}},
    {40, {}}, {30, {"P1 Right"}}, {20, {}}, {6, {"P1 High Punch"}}, {24, {}}, {6, {"P1 Low Punch"}}, {24, {}},
    {6, {"P1 High Kick"}}, {30, {}}, {6, {"P1 Low Kick"}}, {30, {}},
    {6, {"P1 Down"}}, {6, {"P1 Down", "P1 High Punch"}}, {40, {}},
    {6, {"P1 Down"}}, {6, {"P1 Down", "P1 Low Kick"}}, {40, {}},
    {6, {"P1 Up"}}, {60, {}}, {6, {"P1 Up", "P1 Right"}}, {70, {}},
    {6, {"P1 Left"}}, {6, {"P1 Left", "P1 High Kick"}}, {40, {}},
    {30, {"P1 Block"}}, {30, {}},
}
local script_t = 0
local last_act, knife, ball = -1, false, false
local throws, throw_t0 = 0, 0
local snaps = {}
local function snap(tag) if not snaps[tag] then snaps[tag] = true; manager.machine.video:snapshot(); log("snap %s at %d", tag, frame) end end

-- his UMK3 sounds (tools/make_wolf_audio.py, tracks 0669h..0686h): every
-- code in that range written to the sound port, paired rolling
local kano_codes, prevb, tap = {}, nil, nil
local function on_sound(offset, data, mask)
    local v = data & 0xff
    local c = ((prevb or 0) << 8) | v
    prevb = v
    if c >= 0x0669 and c <= 0x0686 then kano_codes[c] = (kano_codes[c] or 0) + 1 end
    if os.getenv("KC_ALL") and morph_f and frame - morph_f < 300 and (offset & 0x1f) == 0 then
        log("  code %04X at +%d", c, frame - morph_f)
    end
    return data
end
emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start; his SAGs %08X..%08X", SAG_LO or 0, SAG_HI or 0)
    end
    frame = frame + 1
    if os.getenv("KC_TRACE") and morph_f and frame - morph_f == 60 then
        manager.machine.debugger:command("trace off")
    end
    if not tap then
        tap = space:install_write_tap(0x01680000, 0x0168001f, "kn_snd", on_sound)
        if os.getenv("KC_ALL") then
            _G.t_rsa = space:install_read_tap(S.rsnd_attack, S.rsnd_attack + 15, "rsa", function(o, d, m)
                if morph_f and frame - morph_f < 300 then
                    local a8 = manager.machine.devices[":maincpu"].state["A8"].value
                    log("  rsnd_attack fetched at +%d a8=%08X ochar=%d p1obj=%08X", frame - morph_f, a8,
                        r16(a8 + 0x1f0), r32(A.p1_obj))
                end
                return d
            end)
            for _, n in ipairs({"chan1pri", "chan2pri", "chan3pri"}) do
                _G["t_" .. n] = space:install_write_tap(S[n], S[n] + 15, n, function(o, d, m)
                    if morph_f and frame - morph_f < 300 then
                        local cpu = manager.machine.devices[":maincpu"]
                        log("  %s <- %04X at +%d pc=%08X", n, d & 0xffff, frame - morph_f, cpu.state["PC"].value)
                    end
                    return d
                end)
            end
        end
    end
    for _, n in ipairs(NAMES) do F[n]:set_value(0) end
    local gs = r16(A.gstate)
    if gs == 4 and not sel then sel = frame; log("select at %d", frame) end
    if not sel and frame >= 1500 then
        local k = (frame - 1500) % 200
        F["Coin 1"]:set_value((k < 6 or (k >= 30 and k < 36)) and 1 or 0)
        F["2 Players Start"]:set_value((k >= 80 and k < 86) and 1 or 0)
    end
    if not fight then
        if sel then
            w16(A.p1_char, 6); w16(A.p2_char, 11); w16(A.curback, 0)   -- Shang v Jax, Dead Pool
            if not confirm and frame > sel + 90 then confirm = frame + 25 end
            if confirm then
                F["P1 High Punch"]:set_value((frame >= confirm and frame < confirm + 6) and 1 or 0)
                F["P2 High Punch"]:set_value((frame >= confirm + 60 and frame < confirm + 66) and 1 or 0)
            end
        end
        if gs == 2 then fight = frame; ill0 = r16(A.illop_count); log("fight at %d", frame) end
        if frame > 12000 then log("no fight - NO VERDICT"); f:close(); manager.machine:exit() end
        return
    end
    local rel = frame - fight
    local p1o = r32(A.p1_obj)
    if p1o == 0 then return end
    local och = r16(p1o + O.ochar)
    -- the morph: Back, Forward, then Block (he starts on the left, facing right)
    if not morph_f then
        if rel >= 40 then
            local k = (rel - 40) % 60
            F["P1 Left"]:set_value(k < 4 and 1 or 0)
            F["P1 Right"]:set_value((k >= 6 and k < 10) and 1 or 0)
            F["P1 Block"]:set_value((k >= 12 and k < 16) and 1 or 0)
        end
        if och == 22 then morph_f = frame; log("MORPHED to ochar 22 at +%d", rel); snap("morph") end
        if rel > 900 then log("FAIL the morph never happened (ochar %d)", och); f:close(); manager.machine:exit() end
        return
    end
    -- keep both alive for the whole script
    if r16(A.p1_bar) < 40 then w16(A.p1_bar, 0xa1) end
    if r16(A.p2_bar) < 40 then w16(A.p2_bar, 0xa1) end
    local t = frame - morph_f
    -- what is P1 drawn with, while she is Sonya
    -- (act_morph 0404h: the morph frames out and back are SHANG's art)
    if och == 22 and r16(r32(A.p1_proc) + P.action) ~= 0x0404 then
        for _, s in ipairs(sags(p1o)) do
            if s >= SAG_LO and s <= SAG_HI then
                if not seen[s] then seen[s] = true; own = own + 1 end
            else
                other = other + 1
                if other <= 5 then log("NOT HIS ART: sag %08X at +%d (action %04X)", s, t, r16(r32(A.p1_proc) + P.action)) end
            end
        end
    end
    local act = r16(r32(A.p1_proc) + P.action)
    if act ~= last_act then
        log("action %04X at +%d (ochar %d)", act, t, och); last_act = act
        if act == 0x0008 and och == 22 then knife = true; snap("knife") end
        if act == 0x020e and och == 22 then ball = true; snap("ball") end
    end
    -- the script
    if script_i <= #SCRIPT then
        local step = SCRIPT[script_i]
        for _, n in ipairs(step[2]) do F[n]:set_value(1) end
        script_t = script_t + 1
        if script_t >= step[1] then script_i = script_i + 1; script_t = 0; throw_t0 = t end
    else
        -- part two: stay Sonya (re-morph when the timer has reverted him),
        -- and let Jax THROW her - the thrown lanes are Kitana's, re-framed
        local k = (t - throw_t0) % 120
        if och ~= 22 then
            local j = k % 60
            F["P1 Left"]:set_value(j < 4 and 1 or 0)
            F["P1 Right"]:set_value((j >= 6 and j < 10) and 1 or 0)
            F["P1 Block"]:set_value((j >= 12 and j < 16) and 1 or 0)
        else
            local p2o = r32(A.p2_obj)
            if k < 4 and r16(r32(A.p1_proc) + P.action) == 0 then
                local x1 = r16(p1o + O.oxpos)
                local x2 = r16(p2o + O.oxpos)
                local nx = (x2 > x1) and (x1 + 38) or (x1 - 38)
                space:write_u16(p2o + O.oxpos, nx); space:write_u32(p2o + 0x080, (nx << 16) & 0xffffffff)
            end
            if k >= 6 and k < 12 then F["P2 High Punch"]:set_value(1); throws = throws + (k == 6 and 1 or 0) end
        end
    end
    if t % 40 == 0 and t <= 3000 then snap("t" .. t) end
    if r16(A.illop_count) ~= ill0 then log("FAIL illop_count moved at +%d (a reboot)", t); f:close(); manager.machine:exit(); return end
    if t >= 3000 then
        log("ochar now %d, his distinct pieces drawn %d, pieces NOT his %d, throw presses %d, knife %s, ball %s",
            och, own, other, throws, tostring(knife), tostring(ball))
        local ks = {}
        for c, n in pairs(kano_codes) do ks[#ks + 1] = string.format("%04X x%d", c, n) end
        table.sort(ks)
        log("his UMK3 sound codes heard: %s", #ks > 0 and table.concat(ks, ", ") or "none")
        log((own >= 20 and other == 0 and knife and ball and #ks > 0) and "PASS" or "FAIL")
        f:close(); manager.machine:exit()
    end
end)
