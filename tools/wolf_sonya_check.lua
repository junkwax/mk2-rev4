-- wolf_sonya_check.lua - MK3 SONYA (Wolf only, ochar 20): Shang Tsung's morph
-- into her, and her body playing MK2's normals with her own art.
--
-- A 2-player Shang Tsung (P1) v Jax (P2).  On the first fighting frames P1
-- holds Down + Block and taps Low Punch (stlp_fight, MOVES.ASM); the rig then
-- requires:
--   * P1's ochar goes to 20 (shang_morph);
--   * every piece P1 is drawn with while she is Sonya is one of HER records -
--     a SAG inside the UMK3SNY pack (src/UMK3SNY.TBL), counted per distinct
--     SAG - except while morphing (act_morph), which draws Shang's frames;
--   * a scripted round of normals (walk, punches, kicks, uppercut, sweep,
--     jump, block) and a few hits FROM Jax all play out with illop_count
--     unchanged (every "reboot" in this build is illop_recover).
-- Snapshots every 40 frames after the morph go to <out>/snap.
-- Env (run_wolf_boot_probe.ps1 -Script wolf_sonya_check.lua):
--   WS_MAP  tmp/wolf/src/MK2.MAP     WS_TBL  src/UMK3SNY.TBL
local LOG = os.getenv("WB_LOG")
local f = nil
local function log(fmt, ...)
    if not f then f = io.open(LOG, "w"); f:write("wolf_sonya_check start\n") end
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
    {40, {}}, {30, {"P1 Right"}}, {20, {}}, {6, {"P1 High Punch"}}, {24, {}}, {6, {"P1 Low Punch"}}, {24, {}},
    {6, {"P1 High Kick"}}, {30, {}}, {6, {"P1 Low Kick"}}, {30, {}},
    {6, {"P1 Down"}}, {6, {"P1 Down", "P1 High Punch"}}, {40, {}},
    {6, {"P1 Down"}}, {6, {"P1 Down", "P1 Low Kick"}}, {40, {}},
    {6, {"P1 Up"}}, {60, {}}, {6, {"P1 Up", "P1 Right"}}, {70, {}},
    {6, {"P1 Left"}}, {6, {"P1 Left", "P1 High Kick"}}, {40, {}},
    {30, {"P1 Block"}}, {30, {}},
}
local script_t = 0
local throws, throw_t0 = 0, 0
local snaps = {}
local function snap(tag) if not snaps[tag] then snaps[tag] = true; manager.machine.video:snapshot(); log("snap %s at %d", tag, frame) end end

emu.register_frame(function()
    if not started then
        if manager.machine.time:as_double() < 0.5 then return end
        started = true; log("start; her SAGs %08X..%08X", SAG_LO or 0, SAG_HI or 0)
    end
    frame = frame + 1
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
    -- the morph chord: Down + Block held, Low Punch tapped inside it
    if not morph_f then
        if rel >= 40 then
            local k = (rel - 40) % 60
            F["P1 Down"]:set_value(k < 20 and 1 or 0)
            F["P1 Block"]:set_value(k < 20 and 1 or 0)
            F["P1 Low Punch"]:set_value((k >= 8 and k < 12) and 1 or 0)
        end
        if och == 20 then morph_f = frame; log("MORPHED to ochar 20 at +%d", rel); snap("morph") end
        if rel > 900 then log("FAIL the morph never happened (ochar %d)", och); f:close(); manager.machine:exit() end
        return
    end
    -- keep both alive for the whole script
    if r16(A.p1_bar) < 40 then w16(A.p1_bar, 0xa1) end
    if r16(A.p2_bar) < 40 then w16(A.p2_bar, 0xa1) end
    local t = frame - morph_f
    -- what is P1 drawn with, while she is Sonya
    -- (act_morph 0404h: the morph frames out and back are SHANG's art)
    if och == 20 and r16(r32(A.p1_proc) + P.action) ~= 0x0404 then
        for _, s in ipairs(sags(p1o)) do
            if s >= SAG_LO and s <= SAG_HI then
                if not seen[s] then seen[s] = true; own = own + 1 end
            else
                other = other + 1
                if other <= 5 then log("NOT HER ART: sag %08X at +%d (action %04X)", s, t, r16(r32(A.p1_proc) + P.action)) end
            end
        end
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
        if och ~= 20 then
            F["P1 Down"]:set_value(k % 60 < 20 and 1 or 0)
            F["P1 Block"]:set_value(k % 60 < 20 and 1 or 0)
            F["P1 Low Punch"]:set_value((k % 60 >= 8 and k % 60 < 12) and 1 or 0)
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
        log("ochar now %d, her distinct pieces drawn %d, pieces NOT hers %d, throw presses %d",
            och, own, other, throws)
        log((own >= 20 and other == 0) and "PASS" or "FAIL")
        f:close(); manager.machine:exit()
    end
end)
