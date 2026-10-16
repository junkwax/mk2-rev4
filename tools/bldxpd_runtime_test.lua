-- Adds BLDXPD packing/lifetime assertions to the existing fatal-slam input rig.
-- Run with private cfg/nvram and EFS_SNAP=0; BLD_LOG names this observer's log.
local root = (os.getenv('MK2_ROOT') or 'C:/Users/you/Workplace/mk2-main'):gsub('\\','/')
local out = assert(io.open(assert(os.getenv('BLD_LOG')), 'w'))
local function log(s) out:write('[bld] '..s..'\n');out:flush() end
local symbols = {}
for line in assert(io.open(root..'/src/mk2.map')):lines() do
    for a,n in line:gmatch('(%x%x%x%x%x%x%x%x)%s+([%w_%.]+)') do symbols[n]=tonumber(a,16) end
end
local function sym(n) return assert(symbols[n], 'Missing map symbol '..n) end
local by_sag = {}
local label, width, height, sag
for line in assert(io.open(root..'/src/BLDXPD.TBL')):lines() do
    local n=line:match('^BLDXPD(%d+):')
    if n then label=tonumber(n);width=nil;sag=nil end
    local w,h=line:match('^%s*%.word%s+(%d+),(%d+),')
    if w then width=tonumber(w);height=tonumber(h) end
    local a=line:match('^%s*%.long%s+(%x+)[Hh]')
    if a and width then sag=tonumber(a,16) end
    local c=line:match('^%s*%.word%s+(%x+)[Hh]%s*$')
    if c and sag then by_sag[sag]={n=label,w=width,h=height,ctrl=tonumber(c,16)} end
end
local count=0;for _ in pairs(by_sag) do count=count+1 end
assert(count==13,'Expected 13 packed headers')
local baseline=(os.getenv('BLD_BASELINE') or '0')=='1'
local depths={4,4,4,4,4,4,4,3,3,3,2,2,1}
local seen, slots, failures, sample = {}, {}, 0, 0
local space
local function check(ok,why)
    if not ok then failures=failures+1;if failures<20 then log('ERROR '..why) end end
end
-- Reuse the established real-input setup and fatality-completion assertions.
dofile(root..'/tools/ermac_fatal_slam_test.lua')
emu.register_frame(function()
    sample=sample+1
    space=space or manager.machine.devices[':maincpu'].spaces['program']
    local function r16(a) return space:read_u16(a) end
    local function r32(a) return space:read_u32(a) end
    local active={}
    for _,list in ipairs({'objlst','objlst2','objlst3'}) do
        local obj,guard=r32(sym(list)),0
        while obj~=0 and guard<400 do
            local hdr=r32(obj+0x1a0)
            local rec=hdr>=0xff800000 and by_sag[r32(hdr+0x40)] or nil
            if rec then
                active[obj]=true
                local flags,opal=r16(obj+0xf0),r16(obj+0x140)
                check((flags&0x7f80)==rec.ctrl,string.format('frame %d stale flags %04x != %04x',rec.n,flags,rec.ctrl))
                check(((flags>>12)&7)==(baseline and 4 or depths[rec.n]),'unexpected live bpp')
                check(r16(obj+0x120)==rec.w and r16(obj+0x130)==rec.h,'live dimensions changed')
                check(r16(hdr+0x60)==rec.ctrl and r32(hdr+0x70)==sym('BLDXPD_P'),'linked header differs from source')
                local s=seen[obj]
                if not s then s={frames={},last=0,opal=opal,first=sample};seen[obj]=s end
                check(s.opal==opal,'palette changed during burst')
                if s.last~=rec.n then
                    check(rec.n==s.last+1,'skipped/repeated frame in burst')
                    s.last=rec.n
                    log(string.format('object=%08x frame=%d bpp=%d flags=%04x opal=%04x sample=%d',obj,rec.n,(flags>>12)&7,flags,opal,sample))
                end
                s.frames[rec.n]=(s.frames[rec.n] or 0)+1;s.last_sample=sample
                local slot=opal&0xff;slots[slot]=true
                check(r32(sym('palram')+slot*0x40)==sym('BLDXPD_P'),'wrong palette owner')
            end
            obj=r32(obj);guard=guard+1
        end
        check(guard<400,'object list cycle/overflow')
    end
    for obj,s in pairs(seen) do
        if not active[obj] and not s.gone then s.gone=sample end
        check(not (active[obj] and s.gone),'splat reappeared after deletion')
    end
end)
emu.register_stop(function()
    local objects=0
    for obj,s in pairs(seen) do
        objects=objects+1
        for n=1,13 do check(s.frames[n]==5,'frame '..n..' did not last five refreshes') end
        check(s.last_sample-s.first+1==65,'burst did not last 65 refreshes')
        check(s.gone~=nil,'splat still live on exit')
        log(string.format('lifetime object=%08x samples=%d last=%d removed=%s',obj,s.last_sample-s.first+1,s.last,tostring(s.gone)))
    end
    check(objects==3,'expected three complete splats, got '..objects)
    if space then
        for slot in pairs(slots) do
            local refs=space:read_u16(sym('palram')+slot*0x40+0x20)
            check(refs==0,'palette references not released: '..refs)
            log(string.format('cleanup slot=%d references=%d',slot,refs))
        end
    end
    log(string.format('%s objects=%d failures=%d',failures==0 and 'PASS' or 'FAIL',objects,failures))
    out:close()
end)
