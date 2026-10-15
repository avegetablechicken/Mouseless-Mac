-- Run with: lua tests/window_switcher_actions_test.lua
local M = dofile('src/window/switcher.lua')
local pending, windows, focused = {}, {}, nil
local function timer(fn)
  local t = {fn=fn, stop=function(s) s.stopped=true end}; return t
end
local function flush()
  local batch=pending; pending={}
  for _,t in ipairs(batch) do if not t.stopped then t.fn() end end
end
local canvas = setmetatable({}, {__index=function(_,k)
  if k=='frame' then return function(s,f) if f then s.bounds=f; return s end; return s.bounds end end
  return function(s) return s end
end})
local keys={escape=1,w=2,h=3,m=4,left=5,right=6,up=7,down=8,tab=9}
local filter={subscribe=function() end,getWindows=function() return windows end}
local eventCallback
local h={
  canvas={new=function() return canvas end,windowLevels={overlay=1}},
  eventtap={event={types={keyDown=1,flagsChanged=2,scrollWheel=3,leftMouseDown=4,leftMouseUp=5,mouseMoved=6},properties={keyboardEventAutorepeat=1}},
    new=function(types,fn)
      assert(types[4]==4 and types[5]==5 and types[6]==6,'must subscribe to click and movement events')
      eventCallback=fn; return {start=function() end,stop=function() end}
    end},
  keycodes={map=keys},window={filter={}},
  image={imageFromAppBundle=function() return {} end},
  timer={doAfter=function(_,fn) local t=timer(fn); pending[#pending+1]=t; return t end,
    doEvery=function(_,fn) return timer(fn) end,secondsSinceEpoch=function() return 100 end,absoluteTime=function() return 100 end},
  screen={mainScreen=function() return {frame=function() return {x=0,y=0,w=1920,h=1080} end} end,
    watcher={new=function() return {start=function(s) return s end} end}},
}
local function app(pid)
 return {pid=function() return pid end,bundleID=function() return 'app'..pid end,name=function() return 'app'..pid end,
   isHidden=function(s) return s.hidden or false end,hide=function(s) s.hidden=true end}
end
local a,b=app(1),app(2)
local function win(id, owner)
 local w={min=false, closed=false}
 function w:id() return id end
 function w:application() return owner end
 function w:title() return 'window'..id end
 function w:isVisible() return not self.min and not owner.hidden end
 function w:isMinimized() return self.min end
 function w:minimize() self.min=true end
 function w:unminimize() self.min=false end
 function w:focus() focused=id end
 function w:close()
   if self.saveDialog then return end
   self.closed=true
   for i,v in ipairs(windows) do if v==self then table.remove(windows,i); break end end
 end
 return w
end
for i=1,35 do windows[i]=win(i,i<=2 and a or b) end
local cap={request=function() return false end,positionGlass=function() end,showGlass=function() end,hideGlass=function() end}
local e=M.new({filter=filter,browsers={},capture=cap,onActiveChange=function() end},h)
local function start(mode) e:cycle(mode or 'normal',1,false,{'alt'}) end
local function key(k,repeated)
 return eventCallback({getType=function() return 1 end,getKeyCode=function() return keys[k] end,
   getFlags=function() return {alt=true} end,getProperty=function() return repeated and 1 or 0 end})
end
start('minimized'); e.selected=1
key('m',true); assert(not windows[1].min,'repeat must not act')
key('m'); assert(e.active and windows[1].min and e.session[e.selected]==2,'minimize must keep panel and advance')
flush(); assert(e.session[1]==2,'minimized target must stay excluded this session')
key('h'); assert(e.active and #e.session==33 and e.session[1]==3,'hide must remove all app windows')
flush(); key('w'); flush()
assert(e.active and #e.session==32 and e.session[1]==4,'close must keep panel and advance')
windows[3].saveDialog=true -- ID 4: close cancelled / save confirmation pending
key('w'); flush(); assert(e.session[1]==4,'unconfirmed close must retain window')
e:scrollRows(1)
local i=e.scrollRow*e.columns+1
local tile=e.tileFrames[i]; local x,y=tile.x+10,tile.y-e.scrollRow*e.cellHeight+10
assert(e:indexAt(x,y)==i,'hit test must account for scrolling')
local expected=e.session[i]
local function mouse(kind, px, py)
 return eventCallback({getType=function() return kind end,
   location=function() return {x=canvas.bounds.x+px,y=canvas.bounds.y+py} end})
end
assert(not mouse(6,x,y) and e.selected==i and e.active,'hover must select without activation or consuming movement')
assert(not mouse(6,1,1) and e.selected==i,'padding must retain selection')
assert(not mouse(6,-1,-1) and e.selected==i,'leaving panel must retain selection')
e:moveGrid(1,0); assert(e.selected==i+1,'keyboard navigation must still work after hover')
mouse(6,x,y); assert(e.selected==i,'mouse movement must retake selection after keyboard navigation')
assert(not mouse(4,-1,-1) and not mouse(5,-1,-1),'outside clicks must pass through')
assert(mouse(4,x,y) and mouse(5,-1,-1),'dragging out must consume release')
assert(e.active,'dragging out must not activate')
assert(mouse(4,1,1) and mouse(5,1,1),'panel padding must not pass clicks through')
assert(e.active,'padding must not activate a card')
assert(mouse(4,x,y) and mouse(5,x,y),'card clicks must be consumed')
assert(not e.active and focused==nil,'click must dismiss before deferred activation')
flush(); assert(focused==expected,'click must activate clicked card')
a.hidden=false; e:updateRecord(windows[1]); e:updateRecord(windows[2]); e:rebuild()
start('minimized'); assert(e.session[1]==1,'new session must include previously minimized window')
local target=e.session[2]; local tile2=e.tileFrames[2]
mouse(6,tile2.x+10,tile2.y+10)
eventCallback({getType=function() return 2 end,getFlags=function() return {} end})
flush(); assert(focused==target,'modifier release must activate hovered window')
windows={windows[1]}; e:rebuild(); start('minimized'); e.selected=1; key('m')
assert(not e.active,'no remaining choices must dismiss without restoring minimized window')
print('PASS: W/H/M actions, repeats, save dialog, scrolling hit test, mouse event routing and consumption, deferred focus, session reset, last window')
