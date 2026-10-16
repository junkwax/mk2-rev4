-- sweep_addon_column.lua - read the EXACT rectangle the hit compare used.
--
-- The overlay already parks every box it draws in bx_list (MKDISP.ASM) before
-- box_pass strokes it, so the compared rectangle can be read out of RAM rather
-- than eyeballed off a screenshot. That turns "the hurt box drifts off his
-- torso" from a claim into a pair of numbers.
--
-- bx_list is BX_MAX=8 records of BX_REC=128 bits: left, top, right, bottom,
-- colour, stamp - six 16-bit words. Colours are cbox_body 007h (the sprite
-- SILHOUETTE, green) and cbox_hurt 00eh (white, the box that actually decided
-- the hit). The gap between those two is the squeeze, and WHERE the white one
-- sits inside the green one is the whole anchorcol question.
--
-- The victim is driven into a WIDE pose - a sweep, or Baraka's blade swipe -
-- because that is when the two models disagree: retail centres the column on
-- the silhouette, so an extended leg or arm drags it off the body, while
-- anchorcol centres it on the anipoint, which does not move. A standing victim
-- differs by about 3 px and proves nothing.
--
-- COLUMN_POSE=sweep|swipe|idle    what the victim is doing
-- COLUMN_TAG=before|after         output file tag
--
-- Output: tools/column_<tag>_<pose>.txt

local ROOT = "C:/Users/you/Workplace/mk2-main"
local POSE = (os.getenv("COLUMN_POSE") or "sweep"):lower()
local TAG = os.getenv("COLUMN_TAG") or "run"
local OUT = ROOT .. "/tools/column_" .. TAG .. "_" .. POSE .. ".txt"

local sym = {}
do
    local fh = io.open(ROOT .. "/src/mk2.map", "r")
    if fh then
        for line in fh:lines() do
            for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do
                sym[n] = tonumber(a, 16)
            end
        end
        fh:close()
    end
end
local S = function(n) return sym[n] end
local gstate = S("gstate")
local p1_obj, p2_obj = S("p1_obj"), S("p2_obj")
local p1_proc, p2_proc = S("p1_proc"), S("p2_proc")
local p1_bar, p2_bar = S("p1_bar"), S("p2_bar")
local right_edge, f_colbox, bx_list = S("right_edge"), S("f_colbox"), S("bx_list")
local worldtlx = S("worldtlx")
if not (gstate and p1_proc and right_edge and f_colbox and bx_list) then
    print("[column] symbols missing - addon disabled"); return
end

local P = { action = 0x1f0 }
local O = { oxval = 0x080, oxpos = 0x090 }
local BX = { max = 8, rec = 128, left = 0, top = 16, right = 32,
             bottom = 48, colour = 64, stamp = 80 }
local CBOX_BODY, CBOX_HURT = 0x007, 0x00e
local MASK = 7                    -- strike + silhouette + hurt
local MAX_HP = 0xa1

local acts, actname = {}, {}
do
    local fh = io.open(ROOT .. "/src/MAINEQU.ASM", "r")
    if fh then
        for line in fh:lines() do
            local n, v = line:match("^(act_[%w_]+)%s+%.set%s+(%x+)h")
            if n and v then
                acts[n] = tonumber(v, 16)
                actname[tonumber(v, 16)] = n
            end
        end
        fh:close()
    end
end
local TARGET = ({ sweep = acts.act_sweep, swipe = acts.act_swipe,
                  idle = acts.act_stance })[POSE]

local logf = io.open(OUT, "a")
local function log(f, ...)
    local l = select("#", ...) > 0 and string.format(f, ...) or f
    print("[column] " .. l)
    if logf then logf:write(l, "\n"); logf:flush() end
end

local space, frame, fight0 = nil, 0, 0
local vx0 = nil
local fields = {}
local function s16(v) v = v & 0xffff; if v >= 0x8000 then return v - 0x10000 end return v end

-- Slots are a ring the producer overwrites, so read all eight and take the
-- ones stamped this tick or last - the same window box_pass drains.
local function boxes()
    local out = {}
    for i = 0, BX.max - 1 do
        local rec = bx_list + i * BX.rec
        out[#out + 1] = {
            l = s16(space:read_u16(rec + BX.left)),
            r = s16(space:read_u16(rec + BX.right)),
            t = s16(space:read_u16(rec + BX.top)),
            b = s16(space:read_u16(rec + BX.bottom)),
            c = space:read_u16(rec + BX.colour) & 0xffff,
            s = space:read_u16(rec + BX.stamp) & 0xffff,
        }
    end
    return out
end

-- same walk as box_bounds (MKDISP.ASM): piece left = oxpos - dx
local MP = { sag = 0, xsize = 32, dx = 80, stride = 112, max = 13 }
local OIMG = 0x1a0
local function mpart_span(obj)
    local img = space:read_u32(obj + OIMG)
    if img == 0 or img < 0x01000000 or img >= 0x01400000 then return nil end
    local ox = s16(space:read_u16(obj + O.oxpos))
    local l, r, n = 30000, -30000, 0
    for i = 0, MP.max - 1 do
        local rec = img + i * MP.stride
        if space:read_u32(rec + MP.sag) == 0 then break end
        local xs = s16(space:read_u16(rec + MP.xsize))
        local dx = s16(space:read_u16(rec + MP.dx))
        local pl = ox - dx
        if pl < l then l = pl end
        if pl + xs > r then r = pl + xs end
        n = n + 1
    end
    if n == 0 then return nil end
    return l, r
end

local samples, seen_act = {}, {}

emu.register_frame(function()
    frame = frame + 1
    if not space then
        local ok = pcall(function()
            space = manager.machine.devices[":maincpu"].spaces["program"]
        end)
        if not ok or not space then return end
    end
    if next(fields) == nil then
        local want = { ["P1 High Kick"] = true, ["P2 Right"] = true,
                       ["P2 Low Kick"] = true, ["P2 High Punch"] = true }
        for _, port in pairs(manager.machine.ioport.ports) do
            for _, fd in pairs(port.fields) do
                if want[fd.name] then fields[fd.name] = fd end
            end
        end
    end
    if space:read_u16(gstate) ~= 2 then return end
    local o1, o2 = space:read_u32(p1_obj), space:read_u32(p2_obj)
    local r1, r2 = space:read_u32(p1_proc), space:read_u32(p2_proc)
    if o1 == 0 or o2 == 0 or r1 == 0 or r2 == 0 then return end
    if fight0 == 0 then
        fight0 = frame
        log("=== hit column, tag=%s pose=%s ===", TAG, POSE)
    end
    local rel = frame - fight0
    if rel < 60 then return end
    space:write_u16(f_colbox, MASK)
    space:write_u16(p1_bar, MAX_HP)
    space:write_u16(p2_bar, MAX_HP)

    -- close enough that the attacker's box always reaches him, so a hurt box
    -- is emitted on every one of the attacker's active frames
    -- PIN WHERE THE CAMERA CAN SEE THEM.  right_edge + 300 is a legal world
    -- position but well outside the scroll clamp, so the fighters sat off
    -- screen and every screenshot came back as an empty stage (the sweep
    -- harness flagged it as level_out_of_scope and I read past it).  Take the
    -- position from worldtlx ONCE and then hold it, so the camera settles on
    -- them instead of chasing a target that moves with it.
    if vx0 == nil then
        vx0 = s16(space:read_u16(worldtlx + 16)) + 250
    end
    local vx = vx0
    space:write_u32(o2 + O.oxval, (vx << 16) & 0xffffffff)
    space:write_u16(o2 + O.oxpos, vx)
    local ax = vx - 70
    space:write_u32(o1 + O.oxval, (ax << 16) & 0xffffffff)
    space:write_u16(o1 + O.oxpos, ax)

    -- victim throws the wide pose on a cycle; attacker kicks continuously so a
    -- strike check - and therefore a hurt box - exists while it is out
    local ph = rel % 40
    for n, fd in pairs(fields) do
        local on = false
        if n == "P1 High Kick" then on = (rel % 10) < 3
        elseif POSE ~= "idle" then
            if n == "P2 Right" then on = (ph >= 2 and ph < 12)
            elseif n == "P2 Low Kick" then on = (POSE == "sweep" and ph >= 6 and ph < 9)
            elseif n == "P2 High Punch" then on = (POSE == "swipe" and ph >= 6 and ph < 9)
            end
        end
        fd:set_value(on and 1 or 0)
    end

    local a2 = space:read_u16(r2 + P.action)

    -- THE SILHOUETTE IS NOT IN bx_list.  box_pass computes it itself with
    -- box_bounds and strokes it with box_rect; only the producer-parked boxes
    -- - the attacker's strike box and the victim's hurt box - go through
    -- box_add.  Looking for a green record here found nothing and reported
    -- "no samples" on a run where the victim threw 651 frames of sweep.
    -- Walk the victim's multipart chain directly instead, which is what
    -- box_bounds does anyway.
    local bl, br = mpart_span(o2)
    local hurt = nil
    for _, b in ipairs(boxes()) do
        if b.c == CBOX_HURT then hurt = b end
    end
    local body = bl and { l = bl, r = br } or nil
    -- Key by the victim's ACTION as well as the geometry.  Filtering to one
    -- target action up front produced "NO SAMPLES" and told me nothing about
    -- why - whether the victim never threw the move, or threw it and never
    -- overlapped a strike check.  Recording every action makes the negative
    -- result diagnostic instead of silent.
    seen_act[a2] = (seen_act[a2] or 0) + 1
    if body and hurt then
        local key = string.format("%d|%d|%d|%d|%d", a2, body.l - vx,
                                  body.r - vx, hurt.l - vx, hurt.r - vx)
        samples[key] = (samples[key] or 0) + 1
    end
end)

emu.register_stop(function()
    local keys = {}
    for k, v in pairs(samples) do keys[#keys + 1] = { k = k, n = v } end
    table.sort(keys, function(a, b) return a.n > b.n end)
    local al = {}
    for a, n in pairs(seen_act) do
        al[#al + 1] = { a = a, n = n }
    end
    table.sort(al, function(x, y) return x.n > y.n end)
    local parts = {}
    for i = 1, math.min(#al, 8) do
        parts[#parts + 1] = string.format("%s:%d",
            actname[al[i].a] or string.format("%04xh", al[i].a), al[i].n)
    end
    log("victim actions seen: %s", table.concat(parts, " "))

    if #keys == 0 then
        log("NO SAMPLES - a silhouette and a hurt box were never in bx_list "
            .. "on the same frame; the attacker's strike checks and the "
            .. "victim's poses never overlapped")
        return
    end
    log("everything relative to the VICTIM's anipoint (his oxpos = 0):")
    log("%6s  %-16s %-18s %-18s %s", "frames", "victim action",
        "silhouette", "compared column", "column centre")
    for i = 1, math.min(#keys, 8) do
        local a, bl, br, hl, hr =
            keys[i].k:match("(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)")
        a, bl, br, hl, hr = tonumber(a), tonumber(bl), tonumber(br),
                            tonumber(hl), tonumber(hr)
        log("%6d  %-16s %+5d .. %+5d   %+5d .. %+5d   %+d (width %d)",
            keys[i].n, actname[a] or string.format("%04xh", a),
            bl, br, hl, hr, math.floor((hl + hr) / 2), hr - hl)
    end
    log("column centre 0 = on the anipoint; a large value = off the body")
end)
