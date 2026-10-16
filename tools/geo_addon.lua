-- Experiment addon for the stability sweep: build a jointed lightning bolt in
-- software each frame and hand it to the ROM's geo_pass (MKDISP.ASM), which
-- draws it with the 34010's LINE instruction after the object pass.
--
-- Loaded via SWEEP_ADDON so it rides the harness's character-select + fight
-- sequence instead of reimplementing it.
local ROOT = "C:/Users/you/Workplace/mk2-main"
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local sym = {}
for line in io.open(ROOT.."/src/mk2.map"):lines() do
  for a,n in line:gmatch("(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)") do sym[n]=tonumber(a,16) end
end
local GC, GL = sym.geo_count, sym.geo_list
local P1O, P2O, P1B = sym.p1_obj, sym.p2_obj, sym.p1_bar
local WTLX = sym.worldtlx
local OXPOS, OYPOS = 0x090, 0x0b0
local CORE, OUTER = 0xFFFFFFFF, 0x3F3F3F3F   -- placeholder pixel values
local scr = manager.machine.screens[":screen"]

local function s16(v) v=v&0xffff; if v>=0x8000 then return v-0x10000 end return v end

-- midpoint displacement between two screen points
local function bolt(ax,ay,bx,by,levels,amp)
  local pts={{ax,ay},{bx,by}}
  for _=1,levels do
    local nx={pts[1]}
    for i=1,#pts-1 do
      local p,q=pts[i],pts[i+1]
      local mx,my=(p[1]+q[1])/2,(p[2]+q[2])/2
      local dx,dy=q[1]-p[1],q[2]-p[2]
      local len=math.sqrt(dx*dx+dy*dy); if len<1 then len=1 end
      local off=(math.random()*2-1)*amp
      nx[#nx+1]={mx-(dy/len)*off, my+(dx/len)*off}
      nx[#nx+1]=q
    end
    pts=nx; amp=amp*0.55
  end
  return pts
end

local n, shots = 0, 0
emu.register_frame_done(function()
  n = n + 1
  if sp:read_u16(P1B) == 0 then sp:write_u16(GC,0); return end
  local o1,o2 = sp:read_u32(P1O), sp:read_u32(P2O)
  if o1==0 or o2==0 then sp:write_u16(GC,0); return end
  local wx = s16(sp:read_u16(WTLX))
  local ax = s16(sp:read_u16(o1+OXPOS)) - wx
  local ay = s16(sp:read_u16(o1+OYPOS)) - 40
  local bx = s16(sp:read_u16(o2+OXPOS)) - wx
  local by = s16(sp:read_u16(o2+OYPOS)) - 30
  if ax<0 or ax>399 or bx<0 or bx>399 then sp:write_u16(GC,0); return end

  local pts = bolt(ax,ay,bx,by,3,22)
  local count = 0
  for i=1,#pts-1 do
    if count >= 60 then break end
    local x0,y0 = math.floor(pts[i][1]),   math.floor(pts[i][2])
    local x1,y1 = math.floor(pts[i+1][1]), math.floor(pts[i+1][2])
    local base = GL + count*96
    sp:write_u32(base,      CORE)
    sp:write_u32(base + 32, ((y0 & 0xffff) << 16) | (x0 & 0xffff))
    sp:write_u32(base + 64, (((y1-y0) & 0xffff) << 16) | ((x1-x0) & 0xffff))
    count = count + 1
  end
  sp:write_u16(GC, count)

  shots = shots + 1
  if shots==90 or shots==150 or shots==260 then
    scr:snapshot(); print("[geo] snap "..shots.."  segments="..count)
  end
end)
