-- Run with: lua tests/menubar_positions_test.lua
local appid = 'org.hammerspoon.Hammerspoon'
local items = {{AXPosition={x=855}}, {AXPosition={x=856}}}
local old = {['NSStatusItem Preferred Position Item-0']=1017,
  ['NSStatusItem Preferred Position PROXY']=551}
local reads = 0
local env = setmetatable({
  OS_VERSION=27, OS={['Golden Gate']=27,Tahoe=26}, AX={MenuBarItem='AXMenuBarItem'},
  require=function(name)
    assert(name=='utils.menubar_reveal')
    return {collapsedInOverflow=function(item) return item.collapsed==true end}
  end,
  tinsert=table.insert, strfmt=string.format, getc=function() return items end, toappui=function() return {} end,
  hs={application={infoForBundleID=function(id)
    return {CFBundleExecutable=id=="example.owner" and "example-process" or "Hammerspoon"}
  end},settings={bundleID=appid,getKeys=function() return {} end},fs={pathToAbsolute=function(path) return path end},plist={read=function(path)
    if path:match('com%.apple%.controlcenter%.plist$') then
      return {['NSStatusItem VisibleCC Clock']=true,['NSStatusItem VisibleCC BentoBox-0']=true}
    end
    reads=reads+1
    assert(path:match('com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist$'))
    return {TrailingItemPreferredPositions={
      ['status:'..appid..'::Item-0']=889, ['status:'..appid..'::PROXY']=551,
      ['status:other.app::Item-0']=50}}
  end}},
},{__index=_G})
local m=assert(loadfile('src/utils/menubar.lua','t',env))()
local proxy={autosaveName=function() return 'PROXY' end,
  frame=function() error('New OS must not match overlapping frame coordinates') end}
m.register(proxy)
local app={bundleID=function() return appid end}
local map,p=env.loadStatusItemsAutosaveName(app,true)
assert(map[1]=='Item-0' and map[2]=='PROXY' and map.PROXY==2)
assert(p[1]==889 and p[2]==551 and reads==1)
-- A shared snapshot serves multiple apps without rereading disk.
local layout=m.readLayout()
local before=reads
map,p=env.loadStatusItemsAutosaveName(app,true,layout)
assert(map.PROXY==2 and reads==before)
-- Missing/stale/ambiguous records must not fall back to old preferences.
assert(env.loadStatusItemsAutosaveName(app,true,{})==nil)
local extra={}
for k,v in pairs(layout) do extra[k]=v end
extra['status:'..appid..'::removed']=999
assert(env.loadStatusItemsAutosaveName(app,true,extra)==nil)
items[2].AXPosition.x=855
assert(env.loadStatusItemsAutosaveName(app,true,layout)==nil)
items[2].AXPosition.x=856
-- Icons collapsed together keep their saved slots but stay unnamed.
items[1].collapsed, items[2].collapsed = true, true
items[2].AXPosition.x=855
local stack
map,p,stack=env.loadStatusItemsAutosaveName(app,true,layout)
assert(next(map)==nil and #stack==2)
assert((p[1]==889 and p[2]==551) or (p[1]==551 and p[2]==889))
-- A single collapsed icon remains unambiguous.
items[2].collapsed=false; items[2].AXPosition.x=856
map=env.loadStatusItemsAutosaveName(app,true,layout)
assert(map[1]=='Item-0' and map[2]=='PROXY')
items[1].collapsed, items[2].collapsed = nil, nil
-- Control Center reuses the shared autosave-name mapping; transient items stay unnamed.
function env.tfind(t,f) for _,v in ipairs(t) do if f(v) then return v end end end
function env.tifilter(t,f) local r={} for _,v in ipairs(t) do if f(v) then r[#r+1]=v end end return r end
function env.tcontain(t,x) return env.tfind(t,function(v) return v==x end)~=nil end
function env.foreach(t,f) for _,v in ipairs(t) do f(v) end end
function env.strsplit(s,sep) local r={} for p in (s..'.'):gmatch('(.-)'..sep) do r[#r+1]=p end return r end
local function ccItem(id,x,desc)
  return {AXIdentifier=id,AXPosition={x=x},attributeValue=function() return desc end}
end
env.getValidControlCenterMenuBarItemsTahoe=function()
  return {ccItem('com.apple.menuextra.clock',300,'Clock'),
    ccItem('com.apple.menuextra.controlcenter',200,'Control Center'),
    ccItem('com.apple.example.liveActivity',100,'Activity')}
end
local cc={bundleID=function() return 'com.apple.controlcenter' end,
  name=function() return 'Control Center' end}
local ccmap,ccpos,ccitems=env.loadStatusItemsAutosaveName(cc,true,
  {['module:Clock']=0,['module:BentoBox-0']=133})
assert(ccmap[1]=='Clock' and ccpos[1]==0 and ccmap[2]=='BentoBox-0')
assert(#ccitems==3 and ccmap[3]==nil)
-- Framework-created status items may use CFBundleExecutable as their owner.
local originalItems=items
items={{AXPosition={x=500}}}
local executableApp={bundleID=function() return 'example.owner' end}
local execMap,execPositions=env.loadStatusItemsAutosaveName(executableApp,true,
  {['status:example-process::Item-0']=476})
assert(execMap[1]=='Item-0' and execPositions[1]==476)
items=originalItems
-- Older systems retain their own preferences and registered-frame correction.
env.OS_VERSION=26
items[1].AXPosition.x=100; items[2].AXPosition.x=200
proxy.frame=function() return {x=200} end
env.hs.settings.getKeys=function()
  return {'NSStatusItem Preferred Position Item-0','NSStatusItem Preferred Position PROXY'}
end
env.hs.settings.get=function(k) return old[k] end
map,p=env.loadStatusItemsAutosaveName(app,true)
assert(map[1]=='Item-0' and map[2]=='PROXY' and p[1]==1017 and p[2]==551)
assert(reads==before, 'Older OS must not read the new storage')
print('PASS: shared layout, stale/ambiguous records, collapsed icons, system modules, and legacy mapping')
