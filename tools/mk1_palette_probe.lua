-- mk1_palette_probe.lua - read MK1's LIVE palettes out of colour RAM.
--
-- Static scans of mk.zip found no teal shadow ramp (18 fighter palettes, 3
-- glow ramps, 69 art-group palettes - all checked).  If the ramp is BUILT AT
-- RUN TIME - a tint or a dim applied to a fighter's own palette - then there
-- are no teal words in the ROM to find and only a live read can get them.
-- That is what this does.
--
--   mame mk -rompath C:\MAME\roms -autoboot_script tools/mk1_palette_probe.lua
--
-- Then just play.  Every frame it reads all 16 colour maps and classifies each
-- one; the moment a map turns CYAN or SHADOW-shaped it latches: writes its words, takes
-- a screen snapshot so you can confirm it is the moment you meant, and keeps
-- going so you can catch more.
--
-- ENV
--   MK1P_OUT     output dir (default the current dir)
--   MK1P_WATCH   cyan (default: cyan + shadow-shaped) | all - latch every map
--   MK1P_ENTRIES entries per map to read (default 64 = 6bpp art)
--   MK1P_MINGAP  frames before the same map may latch again (default 120)
--
-- WRITES
--   palettes.log     one line per latch: frame, map, mid-ramp R,G,B, ceiling
--   pal_MM_FFFFF.txt the map's words, as `.word` lines ready to paste
--   pal_MM_FFFFF.png MAME's own screen at that frame
--   final_dump.txt   all 16 maps as they stood when MAME exited
--
-- COLOUR RAM is at 0x01800000, 16 maps x 256 entries, each entry 16 BITS - and
-- Lua's read_u16 takes the RAW bit address, so entry e of map m is at
-- 0x01800000 + (m*256 + e)*16.  This is the same addressing the Shang-defeat
-- capture rig uses; it is NOT bit_addr/8.
--
-- emu.register_frame_done is what tools/mk1_shang_defeat_capture.lua already
-- runs against this MAME build.  The stop hook prefers the newer
-- add_machine_stop_notifier where it exists (this build warns that
-- register_stop is deprecated) and falls back where it does not; the returned
-- handle is pinned in a global because an unreferenced notifier is collected.
--
-- scr:snapshot is wrapped in pcall: under -video none it throws, and an
-- uncaught error inside the frame callback stops the probe without saying so.

local OUT = (os.getenv("MK1P_OUT") or "."):gsub("\\", "/")
if OUT:sub(-1) ~= "/" then OUT = OUT .. "/" end
local WATCH   = os.getenv("MK1P_WATCH") or "cyan"
local ENTRIES = tonumber(os.getenv("MK1P_ENTRIES") or "64")
local MINGAP  = tonumber(os.getenv("MK1P_MINGAP") or "120")

local CRAM, MAPS = 0x01800000, 16
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]
local log = io.open(OUT .. "palettes.log", "w")

local function L(fmt, ...)
  log:write(string.format(fmt, ...) .. "\n"); log:flush()
end

local function read_map(m)
  local base, w = CRAM + m * 256 * 16, {}
  for e = 0, ENTRIES - 1 do w[e + 1] = mem:read_u16(base + e * 16) end
  return w
end

local function lum(c)
  return 0.299 * ((c >> 10) & 31) + 0.587 * ((c >> 5) & 31) + 0.114 * (c & 31)
end

-- The hue of a ramp lives in its MIDDLE.  Sampling the bright end tells you
-- nothing: MK1's green, magenta and violet glow ramps all end in white, and a
-- first version of this check called all three "neutral" for that reason.
local function classify(w)
  local body = {}
  for _, c in ipairs(w) do if c ~= 0 then body[#body + 1] = c end end
  if #body < 12 then return nil end
  table.sort(body, function(a, b) return lum(a) < lum(b) end)
  local lo, hi = math.floor(#body * 0.25) + 1, math.floor(#body * 0.65)
  local r, g, b, n = 0, 0, 0, 0
  for i = lo, math.max(lo, hi) do
    local c = body[i]
    r = r + ((c >> 10) & 31); g = g + ((c >> 5) & 31); b = b + (c & 31); n = n + 1
  end
  r, g, b = r / n, g / n, b / n
  -- A SHADOW is recognised by SHAPE, not hue.  MK1's real shadow palette
  -- (ffdad980) is 43 of 64 entries one flat dark colour with a short teal
  -- highlight run, and its mid-ramp is 4.0/5.0/6.0 - g-r is only 1.0, so a
  -- hue test demanding g > r+1.5 calls it "neutral" and never latches.  That
  -- is exactly what happened on the first capture that contained it.  Test
  -- the dark ceiling and the flat-colour dominance first.
  local flat, best = {}, 0
  for _, c in ipairs(body) do flat[c] = (flat[c] or 0) + 1 end
  for _, n2 in pairs(flat) do if n2 > best then best = n2 end end
  local ceiling = lum(body[#body])
  -- ceiling has a FLOOR too: a map mid-fade, or one that has been blanked, is
  -- all-but-black and flat by construction and would latch on every fade.
  -- MK1's real shadow sits at 16.7; below ~8 there is no picture left.
  if ceiling >= 8 and ceiling <= 20 and best >= #body * 0.4 then
    return r, g, b, ceiling, "SHADOW"
  end

  local name = "neutral"
  if g > r + 3 and g > b + 3 then name = "green"
  elseif b > r + 3 and b > g + 3 then name = "blue"
  elseif r > g + 3 and b > g + 3 then name = "magenta"
  elseif r > g + 3 and r > b + 3 then name = "red"
  elseif g > r + 1.5 and b > r + 1.5 and math.abs(g - b) <= 4 then name = "CYAN"
  end
  return r, g, b, lum(body[#body]), name
end

local function dump(path, w, head)
  local f = io.open(path, "w")
  f:write("; " .. head .. "\n\n\t.word\t" .. #w .. "\n")
  for i = 1, #w, 8 do
    local row = {}
    for j = i, math.min(i + 7, #w) do row[#row + 1] = string.format("0%04XH", w[j]) end
    f:write("\t.word\t" .. table.concat(row, ",") .. "\n")
  end
  f:close()
end

local frame, last = 0, {}
L("MK1 live palette probe - watch=%s entries=%d", WATCH, ENTRIES)
L("frame  map  mid R,G,B            ceiling  hue")

emu.register_frame_done(function()
  frame = frame + 1
  for m = 0, MAPS - 1 do
    local w = read_map(m)
    local r, g, b, ceil, name = classify(w)
    if r then
      local want = (WATCH == "all") or name == "CYAN" or name == "SHADOW"
      if want and (not last[m] or frame - last[m] > MINGAP) then
        last[m] = frame
        local tag = string.format("%02d_%05d", m, frame)
        L("%5d  %3d  %5.1f %5.1f %5.1f   %5.1f   %s", frame, m, r, g, b, ceil, name)
        dump(OUT .. "pal_" .. tag .. ".txt", w,
             string.format("MK1 colour map %d, live at frame %d - mid R%.1f G%.1f B%.1f, ceiling %.1f, %s",
                           m, frame, r, g, b, ceil, name))
        pcall(function() scr:snapshot(string.format("pal_%s.png", tag)) end)
      end
    end
  end
end)

local reg_stop = emu.add_machine_stop_notifier or emu.register_stop
_G.MK1P_STOP = reg_stop(function()
  local f = io.open(OUT .. "final_dump.txt", "w")
  for m = 0, MAPS - 1 do
    local w = read_map(m)
    local r, g, b, ceil, name = classify(w)
    f:write(string.format("--- map %d  %s ---\n", m,
            r and string.format("mid R%.1f G%.1f B%.1f ceiling %.1f %s", r, g, b, ceil, name) or "empty"))
    for i = 1, #w, 8 do
      local row = {}
      for j = i, math.min(i + 7, #w) do row[#row + 1] = string.format("0%04XH", w[j]) end
      f:write("\t.word\t" .. table.concat(row, ",") .. "\n")
    end
  end
  f:close(); log:close()
end)
