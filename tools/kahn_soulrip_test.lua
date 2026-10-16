-- kahn_soulrip_test.lua - Shao Kahn's soul rip (src/MKSOULRP.ASM).
--
-- Rides tools/kahn_boss_moves_test.lua in KAHN_NORMAL_MATCH mode (it does the
-- attract skip, the select and the forced Kahn ladder slot), and on top of it:
--
--   * once the fight is live, hands Kahn his first match win and empties
--     P1's bar, so the round ends as a MATCH win for the CPU Kahn - the
--     one case kahn_soulrip_due says yes to;
--   * films every frame of the sequence (SR_EVERY, default 1) from the
--     moment f_ksoulrip goes up, as snapshots sr_NNNN.png, and logs the
--     script step, the three objects and winner_status;
--   * PASS needs: f_ksoulrip seen 1 then back to 0, f_death -1 at the end,
--     the soul object seen, and Kahn's victory reached (gstate moves on).
--
-- Env: SR_KILL_AT (frames into the fight, default 90), SR_EVERY, SR_TAIL.

local ROOT = (os.getenv("KAHN_TEST_ROOT") or "C:/Users/you/Workplace/mk2-main"):gsub("\\", "/")
local KILL_AT = tonumber(os.getenv("SR_KILL_AT") or "90") or 90
local EVERY = tonumber(os.getenv("SR_EVERY") or "1") or 1
local TAIL = tonumber(os.getenv("SR_TAIL") or "360") or 360

dofile(ROOT .. "/tools/kahn_boss_moves_test.lua")

local SYM = {}
for line in io.lines(ROOT .. "/src/mk2.map") do
    for a, n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do SYM[n] = tonumber(a, 16) end
end
local function mapaddr(name)
    return SYM[name] or error("symbol not in mk2.map: " .. name)
end

local S = {}
for _, n in ipairs({ "gstate", "p1_bar", "p1_bar_view", "p2_matchw", "winner_status",
                     "f_death", "f_ksoulrip", "ksr_vic_down",
                     "p1_obj", "p2_obj", "p2_proc" }) do
    S[n] = mapaddr(n)
end
-- ksr_soul_obj is module-local, so it is not in the map.  MKSOULRP.ASM
-- declares f_ksoulrip(16), ksr_vic_down(16), ksr_soul_obj(32) in that order
-- and the linker lays them out as declared (f_ksoulrip and ksr_vic_down
-- measured 0x10 apart), so it is the next field after ksr_vic_down.
S.ksr_soul_obj = S.ksr_vic_down + 0x10

local sp, fr, fight_at, killed = nil, 0, 0, false
local sr_start, sr_end, soul_seen, sr_max = 0, 0, false, 0
local done_at = 0

local function r16(a) return sp:read_u16(a) end
local function r32(a) return sp:read_u32(a) end
local function w16(a, v) sp:write_u16(a, v) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local OXPOS, OYPOS = 0x90, 0xb0     -- DISPEQU.ASM field BIT offsets
local function pos(obj)
    if obj == 0 then return "-" end
    return string.format("%d,%d", s16(r16(obj + OXPOS)), s16(r16(obj + OYPOS)))
end

local function shot(label)
    local ok, s = pcall(function() return manager.machine.screens[":screen"] end)
    if ok and s then pcall(function() s:snapshot(label .. ".png") end) end
end

emu.register_frame(function()
    fr = fr + 1
    if not sp then
        local ok, cpu = pcall(function() return manager.machine.devices[":maincpu"] end)
        if not ok or not cpu then return end
        sp = cpu.spaces["program"]
        print("[soulrip] rig loaded; kill at fight+" .. KILL_AT)
    end
    local gs = r16(S.gstate)
    if gs == 2 and fight_at == 0 then fight_at = fr end

    if fight_at > 0 and not killed and fr - fight_at >= KILL_AT then
        killed = true
        w16(S.p2_matchw, 1)             -- Kahn already has round one
        w16(S.p1_bar, 0)
        w16(S.p1_bar_view, 0)
        print(string.format("[soulrip] KILL frame=%d", fr))
    end

    local f = s16(r16(S.f_ksoulrip))
    if f ~= 0 and sr_start == 0 then
        sr_start = fr
        print(string.format("[soulrip] START frame=%d winner=%d f_death=%d",
            fr, r16(S.winner_status), s16(r16(S.f_death))))
    end
    if sr_start > 0 and sr_end == 0 and os.getenv("SR_TAP") == "1" and not TAPPED then
        TAPPED = true
        local k = r32(os.getenv("SR_TAP_WHO") == "vic" and S.p1_obj or S.p2_obj)
        local cpu = manager.machine.devices[":maincpu"]
        TAPH = sp:install_write_tap(k + 0x80, k + 0xbf, "srx", function(off, data, mask)
            local rel = fr - sr_start
            if rel >= 100 and rel <= 116 then
                print(string.format("[soulrip]   TAP rel=%d off=%08x data=%08x mask=%08x pc=%08x",
                    rel, off, data, mask, cpu.state["PC"].value))
            end
        end)
        print(string.format("[soulrip] tap on kahn obj %08x", k))
    end
    if sr_start > 0 and sr_end == 0 then
        local rel = fr - sr_start
        local soul = r32(S.ksr_soul_obj)
        if soul ~= 0 then soul_seen = true end
        if rel % EVERY == 0 then
            shot(string.format("sr_%04d", rel))
            local kproc = r32(S.p2_proc)
            print(string.format("[soulrip] rel=%d f=%d ws=%d down=%d step=%d kahn=%s vic=%s soul=%s",
                rel, f, r16(S.winner_status), r16(S.ksr_vic_down),
                kproc ~= 0 and r32(kproc + 0x290) or -1,   -- p_store4 = pdata+190h (bits)
                pos(r32(S.p2_obj)), pos(r32(S.p1_obj)), pos(soul)))
            if os.getenv("SR_DEEP") == "1" then
                local k = r32(S.p2_obj)
                local shp = r32(k + 0x1d0)
                local pc = r32(shp)
                print(string.format("[soulrip]   kahn oxval=%08x oflags=%04x oshape=%08x p0=%08x hdr=%d,%d,%d,%d sag=%08x p1=%08x p2=%08x",
                    r32(k + 0x80), r16(k + 0xf0), shp, pc,
                    s16(r16(pc)), s16(r16(pc + 16)), s16(r16(pc + 32)), s16(r16(pc + 48)),
                    r32(pc + 64), r32(shp + 32), r32(shp + 64)))
            end
        end
        if f == -1 or (f == 0 and rel > 2) then
            sr_end = fr
            print(string.format("[soulrip] END frame=%d rel=%d f_death=%d soul_seen=%s",
                fr, rel, s16(r16(S.f_death)), tostring(soul_seen)))
        end
        if rel > 3000 then
            print("[soulrip] FAIL never finished")
            manager.machine:exit()
        end
    end
    if sr_end > 0 then
        local tail = fr - sr_end
        if tail % 20 == 0 then
            shot(string.format("tail_%04d", tail))
            print(string.format("[soulrip] tail=%d gstate=%d ws=%d f_death=%d",
                tail, r16(S.gstate), r16(S.winner_status), s16(r16(S.f_death))))
        end
        if tail >= TAIL then
            print(string.format("[soulrip] %s soul_seen=%s",
                soul_seen and "PASS" or "FAIL_no_soul", tostring(soul_seen)))
            manager.machine:exit()
        end
    end
end)
