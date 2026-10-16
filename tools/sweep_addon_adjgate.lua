-- sweep_addon_adjgate.lua - do the two operator switches actually gate the
-- readouts IN A FIGHT?
--
-- Driving is lifted from sweep_addon_combofade.lua: pin the two fighters a
-- jab apart and throw paired high punches, which is the shortest thing that
-- makes the combo readout appear at all (hudcmb_min = 2).
--
-- What is watched is one write from inside each gated producer:
--
--   cmb_tick   only ever written by hud_combo_hit          -> KOMBO KOUNTER
--   cal_first  only ever written by hud_callout (3054)     -> KOMBAT TOASTS
--
-- Neither can move if its producer returned at the gate, and neither has any
-- other writer - so "it moved" is proof the feature ran and "it never moved
-- across a whole fight of landed hits" is proof it did not.
--
-- ADJGATE_FORCE=1 writes f_kalout=1 every frame, standing in for an operator
-- who turned KOMBAT TOASTS on.  That is the positive control: without it the
-- run cannot tell "correctly gated off" from "broken".
--
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("ADJGATE_LOG") or (ROOT .. "/tools/adjgate.txt")
local FORCE = os.getenv("ADJGATE_FORCE") == "1"

local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a,16) end
end
local gstate, p1_bar, p2_bar = sym.gstate, sym.p1_bar, sym.p2_bar
local cmb_tick, cmb_hits = sym.cmb_tick, sym.cmb_hits
local cal_first = sym.cal_first
local f_kalout, f_kmbcnt = sym.f_kalout, sym.f_kmbcnt
local p1_obj, p2_obj = sym.p1_obj, sym.p2_obj
local OXPOS, OXVAL, GAP, MAX_HP = 0x090, 0x080, 70, 0xA1
local function s16(v) v=v&0xffff; if v>=0x8000 then return v-0x10000 end return v end

local fh = io.open(OUT,"a")
local function log(f,...) local l=select("#",...)>0 and string.format(f,...) or f
    print("[adjgate] "..l); if fh then fh:write(l,"\n"); fh:flush() end end

for _,n in ipairs({"P1 Left","P1 Right","P1 Down","P1 High Punch","P2 Block"}) do
    ADDON_OWNS[n]=true end

local space, frame, fight0, fields = nil, 0, 0, {}
local max_tick, max_hits, saw_first, hitframes = 0, 0, 0, 0
local kal, kmb = -1, -1
local function press(n,on) local f=fields[n]; if f then f:set_value(on and 1 or 0) end end

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function() space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _,port in pairs(manager.machine.ioport.ports) do
            for _,f in pairs(port.fields) do if ADDON_OWNS[f.name] then fields[f.name]=f end end end
        log("=== adjgate === FORCE=%s (f_kalout pinned to 1)", tostring(FORCE))
    end
    if space:read_u16(gstate) ~= 2 then return end
    if fight0 == 0 then fight0 = frame end
    local t = frame - fight0

    if FORCE then space:write_u16(f_kalout, 1) end
    if kal < 0 then
        kal = space:read_u16(f_kalout) & 0xffff
        kmb = space:read_u16(f_kmbcnt) & 0xffff
        log("fight start: f_kalout=%d f_kmbcnt=%d", kal, kmb)
    end

    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)

    local tick = space:read_u16(cmb_tick) & 0xffff
    local hits = space:read_u16(cmb_hits) & 0xffff
    local first = space:read_u16(cal_first) & 0xffff
    if tick > max_tick then max_tick = tick end
    if hits > max_hits then max_hits = hits; hitframes = hitframes + 1 end
    if first ~= 0 and saw_first == 0 then
        saw_first = t; log("  cal_first went %d at t=%d - a TOAST fired", first, t) end

    local o1,o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    if o1 ~= 0 and o2 ~= 0 then
        local x1,x2 = s16(space:read_u16(o1+OXPOS)), s16(space:read_u16(o2+OXPOS))
        local tx = (x1 < x2) and (x1+GAP) or (x1-GAP)
        space:write_u32(o2+OXVAL, (tx & 0xffff) << 16)
    end
    local c = t % 220
    press("P1 High Punch", c==4 or c==5 or c==16 or c==17)
end)

emu.register_stop(function()
    log("SUMMARY f_kalout=%d f_kmbcnt=%d | max cmb_hits=%d max cmb_tick=%d | cal_first first seen at t=%s",
        kal, kmb, max_hits, max_tick, saw_first==0 and "NEVER" or tostring(saw_first))
    local kounter_ran = max_tick > 0
    local toast_ran   = saw_first ~= 0
    log("  KOMBO KOUNTER  flag=%d  ran=%s  -> %s", kmb, tostring(kounter_ran),
        ((kmb==1) == kounter_ran) and "MATCHES THE FLAG" or "MISMATCH")
    log("  KOMBAT TOASTS  flag=%d  ran=%s  -> %s", kal, tostring(toast_ran),
        ((kal==1) == toast_ran) and "MATCHES THE FLAG" or
        (kal==0 and toast_ran and "MISMATCH - fired while OFF" or "INCONCLUSIVE - no hit earned one"))
end)
