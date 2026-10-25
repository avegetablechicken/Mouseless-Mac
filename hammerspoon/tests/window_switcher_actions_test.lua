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

-- Lifecycle reconciliation is independent of thumbnail success or failure.
local now, snapshot, axReads = 100, {}, 0
h.timer.secondsSinceEpoch=function() return now end
cap.windowIDs=function()
  if snapshot==nil then return nil end
  local ids={}
  for _, info in ipairs(snapshot) do ids[#ids+1]=info.kCGWindowNumber end
  return ids
end
h.axuielement={windowElement=function(w)
  axReads=axReads+1
  return {isValid=function()
    if w.axError then return nil, 'cannotComplete' end
    return not w.invalid
  end}
end}
local results={}
cap.poll=function() local r=results; results={}; return r end
h.image.imageFromURL=function(url) return url end
a.hidden=false
local w=win(50,a)
windows={w}; e:rebuild()
local token=e.records[50].token
e.records[50].image='previous image'
results={{id=50,token=token,error='No screenshot available'}}
e:receiveCaptures()
assert(e.records[50].image=='previous image' and axReads==0,
  'capture failure must retain the window and not query lifecycle')
e:rebuild(true); now=103; e:rebuild(true)
assert(e.records[50] and not e.missing[50], 'missing surface with live AX must stay')
w.invalid=true; e:rebuild(true)
assert(e.records[50], 'first invalid AX observation must not remove the window')
w.axError=true; now=106; e:rebuild(true)
assert(e.records[50] and not e.missing[50], 'AX errors are inconclusive and reset confirmation')
w.axError=false; e:rebuild(true)
snapshot=nil; now=109; e:rebuild(true)
assert(e.records[50], 'failed WindowServer enumeration must not remove a window')
snapshot={{kCGWindowNumber=50}}; e:rebuild(true)
assert(e.records[50] and not e.missing[50], 'retained surface must heal pending AX loss')
snapshot={}; w.min=true; e:rebuild(true)
assert(e.records[50] and not e.missing[50], 'minimized windows must be protected')
w.min=false; a.hidden=true; e:rebuild(true)
assert(e.records[50] and not e.missing[50], 'hidden apps must be protected')
a.hidden=false; e:rebuild(true); now=112; e:rebuild(true)
assert(not e.records[50] and e.ended[50]==w, 'repeated cross-source absence must remove stale filter entries')
w.invalid=false; e:rebuild(true)
assert(e.records[50] and e.records[50].token~=token, 'recovered AX element must return with a fresh token')
local recovered=e.records[50].token
-- A replacement in the same process with the same window ID is a new lifetime.
local replacement=win(50,a); windows={replacement}; e:rebuild()
assert(e.records[50].win==replacement and e.records[50].token~=recovered,
  'ID reuse must not retain the prior AX object or capture token')
results={{id=50,token=token,image='stale image'},{id=50,token=recovered,image='also stale'}}
e:receiveCaptures()
assert(not e.records[50].image, 'late captures from old lifetimes must be ignored')
replacement.invalid=true; e:rebuild(true); now=115; e:rebuild(true)
assert(not e.records[50], 'replacement can independently reach confirmed closure')
snapshot={{kCGWindowNumber=50}}; replacement.invalid=false; e:rebuild(true)
assert(e.records[50] and not e.ended[50], 'reappearing surface must not remain blacklisted')
replacement.invalid=true; snapshot={}; e:rebuild(true)
windows={}; e:rebuild()
assert(not next(e.missing) and not next(e.ended), 'filter removal must prune lifecycle bookkeeping')
print('PASS: capture failure, transient absence, AX errors, hidden/minimized windows, confirmed close, recovery, ID reuse and late captures')

-- A tab can become current without reaching window.filter's create/focus watcher.
-- Reuse its discovery path: new tabs still pass the filter and old tabs survive.
local terminal=app(3)
terminal.bundleID=function() return 'com.apple.Terminal' end
local inactive, standalone, current=win(60,terminal),win(61,terminal),win(62,terminal)
windows={inactive,standalone}
local discoveries=0
local trackedApp={app=terminal,getCurrentSpaceAppWindows=function()
  discoveries=discoveries+1
  if #windows==2 then windows[#windows+1]=current end
end}
filter.windows={[{app=trackedApp,window=inactive}]=true}
snapshot={{kCGWindowNumber=61},{kCGWindowNumber=62}}
e:rebuild(); assert(#e.lists.normal==2, 'fixture must start with a missed tab')
e:rebuild(true)
assert(discoveries==1 and #e.lists.normal==3 and e.records[60] and e.records[61] and e.records[62],
  'rescan must add the current tab without dropping the inactive tab')
e:rebuild(true)
assert(#e.lists.normal==3, 'repeated discovery must not duplicate tabs')
print('PASS: missed Terminal tab discovery preserves inactive tabs without duplicates')

-- window.filter can retain a destroyed entry whose window object is gone; its
-- hole in getWindows used to hide every window focused before it.
local stale={app=trackedApp}
filter.windows[stale]=true
e:rebuild()
assert(filter.windows[stale]==nil and #e.lists.normal==3, 'destroyed filter entries must be pruned')
print('PASS: destroyed window.filter entries do not truncate the inventory')
