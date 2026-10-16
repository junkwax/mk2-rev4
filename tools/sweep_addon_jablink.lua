-- sweep_addon_jablink.lua - does a jab linked into a NON-jab count as hit 2?
--
-- cmbrules hands an ordinary High/Low Punch's hit back (a run of jabs is not a
-- combo), which also made jab + anything read as two single hits.  strike_check
-- (JOY.ASM, jlk_out) now credits the jab back when the next hit is not a jab
-- and the victim is still in the jab's stun (p_pblock > 0).
--
-- P1 Kung Lao vs a passive human, pinned at JL_GAP.  First the backfist
-- (Back+HP) alone = its unscaled damage D0.  Then HP, and Back+HP JL_DELAY..
-- frames later, at several delays.  A trial is a LINK only if the backfist
-- landed with the victim's p_pblock still up; a link must read cmb_hits 2 and
-- do D0 - D0>>2.  A backfist that lands after he recovered is NOT a link and
-- must do D0 (the control, in the same run).  No link at any delay = NO VERDICT.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local OUT  = os.getenv("JL_LOG") or (ROOT .. "/tools/jablink.txt")
local GAP  = tonumber(os.getenv("JL_GAP") or "80")
local DELAYS = {8, 11, 14, 17, 20, 24, 60}
local sym = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n] = tonumber(a, 16) end
end
local P_ACTION, P_HITBY, P_HIT = 0x1f0, 0x360, 0x370
local OXPOS, OXVAL = 0x090, 0x080
local fh = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[jablink] " .. l); if fh then fh:write(l, "\n"); fh:flush() end
end
for _, n in ipairs({"P1 Left","P1 Right","P1 Up","P1 Down",
    "P1 High Punch","P1 Low Punch","P1 High Kick","P1 Low Kick","P1 Block"}) do ADDON_OWNS[n] = true end
local space, frame, fight0, fields = nil, 0, 0, {}
local trial, t0, prev, done = 0, 0, nil, false
local hits, results, d0 = {}, {}, nil
local function press(n, on) local f = fields[n]; if f then f:set_value(on and 1 or 0) end end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end
local function finish()
    if done then return end; done = true
    local links, bad = 0, 0
    for _, r in ipairs(results) do
        log("delay %2d: %s", r.delay, r.text)
        if r.link then links = links + 1 end
        if r.bad then bad = bad + 1 end
    end
    if not d0 then log("VERDICT NO VERDICT - the backfist alone never landed")
    elseif links == 0 then log("VERDICT NO VERDICT - no delay produced a link")
    elseif bad > 0 then log("VERDICT FAIL - %d trial(s) wrong", bad)
    else log("VERDICT PASS - %d link(s), backfist alone %d", links, d0) end
end
emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function() space = manager.machine.devices[":maincpu"].spaces["program"] end)
        if not ok or not space then return end
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, f in pairs(port.fields) do if ADDON_OWNS[f.name] then fields[f.name] = f end end end
        log("=== jab link: Kung Lao HP -> Back+HP, gap %d ===", GAP)
    end
    if done or space:read_u16(sym.gstate) ~= 2 then return end
    if fight0 == 0 then fight0, t0 = frame, frame + 90 end
    local pr1, pr2 = space:read_u32(sym.p1_proc), space:read_u32(sym.p2_proc)
    local o1, o2 = space:read_u32(sym.p1_obj), space:read_u32(sym.p2_obj)
    if pr1 == 0 or pr2 == 0 or o1 == 0 or o2 == 0 then return end
    space:write_u16(sym.p1_bar, 0xa1)
    local w = space:read_u16(pr2 + 0x380)
    local now = { hp = space:read_u16(sym.p2_bar), hit = space:read_u16(pr2 + P_HIT) & 0xff,
                  pblk = (w >> 8) & 0xff, act = space:read_u16(pr1 + P_ACTION) }
    if prev and now.hp < prev.hp then
        hits[#hits + 1] = { dmg = prev.hp - now.hp, hit = prev.hit, pblk = prev.pblk,
            act = now.act, r = frame - t0, cmb = space:read_u16(sym.cmb_hits) }
        local h = hits[#hits]
        log("  t=%d dmg=%d p_hit(before)=%d p_pblock(before)=%d p1act=0x%04x cmb_hits=%d",
            h.r, h.dmg, h.hit, h.pblk, h.act, h.cmb)
    end
    prev = now
    local x1 = s16(space:read_u16(o1 + OXPOS))
    local tx = x1 + GAP
    space:write_u32(o2 + OXVAL, (tx & 0xffff) << 16); space:write_u16(o2 + OXPOS, tx)
    for _, n in ipairs({"P1 Left","P1 High Punch"}) do press(n, false) end
    local r = frame - t0
    if r < 0 then return end
    local delay = (trial == 0) and 0 or DELAYS[trial]
    if trial > 0 then press("P1 High Punch", r < 3) end
    if r >= delay and r < delay + 8 then press("P1 Left", true) end
    if r >= delay + 2 and r < delay + 6 then press("P1 High Punch", true) end
    if r > 150 then
        if trial == 0 then
            for _, h in ipairs(hits) do if h.act == 0x010b then d0 = h.dmg end end
            log("backfist alone: %s", d0 and tostring(d0) or "never landed")
            if not d0 then finish(); return end
        else
            local bf
            for _, h in ipairs(hits) do if h.act == 0x010b then bf = h end end
            local res = { delay = delay }
            if not bf then res.text = "backfist did not come out / land (not exercised)"
            elseif bf.pblk > 0 then
                res.link = true
                local want = d0 - (d0 >> 2)
                res.bad = not (bf.cmb == 2 and bf.dmg == want)
                res.text = string.format("LINK  kounter %d (want 2)  backfist %d (want %d)  %s",
                    bf.cmb, bf.dmg, want, res.bad and "WRONG" or "ok")
            else
                res.bad = bf.dmg ~= d0
                res.text = string.format("no link (he had recovered)  backfist %d (want %d)  %s",
                    bf.dmg, d0, res.bad and "WRONG" or "ok")
            end
            results[#results + 1] = res
        end
        trial = trial + 1; hits = {}
        space:write_u16(sym.p2_bar, 0xa1); prev = nil
        t0 = frame + 60
        if not DELAYS[trial] then finish() end
    end
end)
emu.register_stop(function() finish() end)
