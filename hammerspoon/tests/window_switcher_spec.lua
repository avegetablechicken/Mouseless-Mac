-- Deterministic behavior tests; no live Hammerspoon or window activation.
package.path = './src/?.lua;' .. package.path
local Switcher = require('window.switcher')
local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ': ' .. tostring(err), 0) end
  passed = passed + 1
  print('PASS ' .. name)
end

local function fixture(count)
  local timers, results, requests, windows, activated = {}, {}, {}, {}, {}
  local now, queries, shown, allocations = 100, 0, 0, 0
  local heldModifiers = {alt=true}
  local screenFrame = {x=0,y=0,w=1440,h=900}
  local h = {window={filter={}}, eventtap={event={types={keyDown=1,flagsChanged=2,scrollWheel=3},properties={keyboardEventAutorepeat=1,scrollWheelEventIsContinuous=2,scrollWheelEventPointDeltaAxis1=3,scrollWheelEventDeltaAxis1=4}}},
    keycodes={map={w=13,h=4,m=46,escape=53,tab=48,['`']=50,left=123,right=124,up=126,down=125}}, canvas={windowLevels={overlay=1}}, image={}, screen={}, timer={}}
  for _, name in ipairs({'windowsChanged','windowFocused','windowTitleChanged','windowMinimized',
    'windowUnminimized','windowHidden','windowUnhidden','windowMoved'}) do h.window.filter[name] = name end
  h.window.filter.sortByFocusedLast = 'focused'
  local function timer(fn)
    local t = {fn=fn,stopped=false}
    function t:stop() self.stopped=true; return self end
    function t:start() self.stopped=false; return self end
    timers[#timers+1] = t
    return t
  end
  function h.timer.doAfter(_,fn) return timer(fn) end
  function h.timer.doEvery(_,fn) return timer(fn) end
  function h.timer.secondsSinceEpoch() return now end
  function h.timer.absoluteTime() return now*1e9 end
  function h.eventtap.new(_,fn) return timer(fn) end
  function h.eventtap.checkKeyboardModifiers() return heldModifiers end
  function h.screen.mainScreen() return {frame=function() return screenFrame end} end
  h.screen.watcher={new=function(fn) return timer(fn) end}
  function h.image.imageFromAppBundle(id) return 'icon:'..id end
  function h.image.imageFromName(id) return 'fallback:'..id end
  function h.image.imageFromURL(url) return 'decoded:'..url end
  local canvas = {elements={}}
  function h.canvas.new() allocations=allocations+1; return canvas end
  for _, name in ipairs({'level','behavior','frame','clickActivating'}) do canvas[name]=function(self) return self end end
  function canvas:replaceElements(...) self.elements={...}; allocations=allocations+1; return self end
  function canvas:elementAttribute(i,key,value)
    assert(self.elements[i], 'missing element '..i)
    if value~=nil then self.elements[i][key]=value; return self end
    return self.elements[i][key]
  end
  function canvas:show() self.visible=true; shown=shown+1; return self end
  function canvas:hide() self.visible=false; return self end
  function canvas:delete() self.deleted=true end
  local filter={}
  function filter:getWindows() queries=queries+1; return windows end
  function filter:subscribe(_,fn) self.callback=fn end
  function filter:delete() self.deleted=true end
  local capture={}
  function capture.request(id,token,priority) requests[#requests+1]={id=id,token=token,priority=priority}; return true end
  function capture.poll() local batch=results; results={}; return batch end
  function capture.positionGlass(x,y,w,h) capture.positions=(capture.positions or 0)+1;capture.frame={x=x,y=y,w=w,h=h} end
  function capture.showGlass() capture.visible=true end
  function capture.hideGlass() capture.visible=false end
  function capture.reset() capture.resetCalled=true end
  local function window(id, attributes)
    local w = attributes or {}
    w.bundle = w.bundle or 'ordinary'
    w.pid = w.pid or id
    local function query(value) queries=queries+1; return value end
    local app={pid=function() return query(w.pid) end,bundleID=function() return query(w.bundle) end,
      name=function() return query('App '..id) end,isHidden=function() return query(w.hidden or false) end}
    w.id=function() return query(id) end
    w.application=function() return query(app) end
    w.title=function() return query(w.label or 'Window '..id) end
    w.isVisible=function() return query(not w.hidden and not w.minimized) end
    w.isMinimized=function() return query(w.minimized or false) end
    w.unminimize=function() w.minimized=false; w.restored=true end
    w.focus=function() activated[#activated+1]=id end
    return w
  end
  for i=1,count or 3 do windows[i]=window(i) end
  local changes={}
  local engine=Switcher.new({filter=filter,capture=capture,browsers={browser=true},
    onActiveChange=function(active,mode) changes[#changes+1]={active=active,mode=mode} end},h)
  return {engine=engine,canvas=canvas,filter=filter,capture=capture,windows=windows,activated=activated,
    changes=changes,requests=requests,timers=timers,window=window,
    setWindows=function(v) windows=v end,
    result=function(v) results[#results+1]=v end,
    advance=function(s) now=now+s end,
    modifiers=function(flags) heldModifiers=flags end,
    screen=function(frame) screenFrame=frame end,
    counts=function() return queries,shown,allocations end,
    event=function(kind,key,flags,repeated) return {getType=function() return kind end,getKeyCode=function() return key end,
      getFlags=function() return flags or {} end,getProperty=function() return repeated and 1 or 0 end} end}
end

test('summon and navigation perform no AX queries, enumeration or screenshot requests',function()
  local f=fixture(40); local e=f.engine
  local queries,_,allocations=f.counts(); local requests=#f.requests
  e:cycle('normal',1,false,{'alt'})
  assert(e.selected==2 and f.canvas.visible)
  assert(select(1,f.counts())==queries and #f.requests==requests)
  for _=1,50 do e:cycle('normal',1,false,{'alt'}) end
  assert(select(1,f.counts())==queries and #f.requests==requests)
  e:finish(false)
  local _,_,pooled=f.counts()
  e:cycle('normal',1,false,{'alt'})
  assert(select(3,f.counts())==pooled and pooled==allocations)
end)

test('normal, minimized and browser inventories exclude hidden applications',function()
  local f=fixture(0)
  f.setWindows({f.window(1),f.window(2,{minimized=true}),f.window(3,{hidden=true}),
    f.window(4,{bundle='browser'}),f.window(5,{bundle='browser',minimized=true})})
  f.engine:rebuild()
  assert(#f.engine.lists.normal==2 and #f.engine.lists.minimized==4 and #f.engine.lists.browsers==1)
  f.engine:cycle('minimized',1,false,{'alt'})
  assert(f.engine.session[f.engine.selected]==2)
  f.engine:finish(true)
  f.engine.focusTimer.fn()
  assert(f.activated[1]==2 and f.engine.records[2].win.restored)
end)

test('Escape consumes event and release afterwards cannot activate a window',function()
  local f=fixture();local e=f.engine
  e:cycle('normal',1,false,{'alt'})
  assert(e.tap.fn(f.event(1,53,{alt=true}))==true)
  assert(not e.active and not f.canvas.visible and e.tap.stopped)
  e.tap.fn(f.event(2,nil,{}))
  assert(#f.activated==0 and f.changes[#f.changes].active==false)
end)

test('release of the base modifier commits once even while Shift remains down',function()
  local f=fixture();local e=f.engine
  e:cycle('minimized',1,false,{'alt'})
  e.tap.fn(f.event(2,nil,{alt=true}))
  assert(e.active and #f.activated==0)
  e.tap.fn(f.event(2,nil,{shift=true}))
  e.tap.fn(f.event(2,nil,{}))
  e.focusTimer.fn()
  assert(#f.activated==1 and f.activated[1]==2)
end)

test('repeat stops at endpoints; separate presses wrap in either direction',function()
  local f=fixture(); local e=f.engine
  e:cycle('normal',1,false,{'alt'})
  e:cycle('normal',1,true,{'alt'}); assert(e.selected==3)
  e:cycle('normal',1,true,{'alt'}); assert(e.selected==3)
  e:cycle('normal',1,false,{'alt'}); assert(e.selected==1)
  e:cycle('normal',-1,true,{'alt'}); assert(e.selected==1)
  e:cycle('normal',-1,false,{'alt'}); assert(e.selected==3)
end)

test('close selected window during navigation and empty list safely cancel',function()
  local f=fixture();local e=f.engine
  e:cycle('normal',1,false,{'alt'})
  f.setWindows({f.windows[1],f.windows[3]});e:rebuild()
  assert(e.session[e.selected]==3)
  f.setWindows({});e:rebuild()
  assert(not e.active and #f.activated==0)
  e:cycle('normal',1,false,{'alt'});assert(not e.active)
end)

test('late screenshots cannot reopen a cancelled panel or attach to a reused ID',function()
  local f=fixture();local e=f.engine
  local old=e.records[2].token
  e:cycle('normal',1,false,{'alt'});e:finish(false)
  f.result({id=2,token=old,image='old'});e:receiveCaptures()
  assert(e.records[2].image=='decoded:old' and not f.canvas.visible)
  f.setWindows({});e:rebuild()
  f.setWindows({f.window(2,{pid=200})});e:rebuild()
  f.result({id=2,token=old,image='wrong'});e:receiveCaptures()
  assert(e.records[2].image==nil)
end)

test('capture failures preserve thumbnails and retry with backoff',function()
  local f=fixture();local e=f.engine;local token=e.records[1].token
  f.result({id=1,token=token,image='valid'});e:receiveCaptures()
  f.result({id=1,token=token,error='minimized'});e:receiveCaptures()
  assert(e.records[1].image=='decoded:valid' and e.lastCaptureError=='minimized')
  local n=#f.requests;e:requestCapture(1,true);assert(#f.requests==n)
  f.advance(11);e:requestCapture(1,true);assert(#f.requests==n+1)
end)

test('dispose cancels session and releases watchers, filters, timers and images',function()
  local f=fixture();local e=f.engine;e:cycle('normal',1,false,{'alt'})
  e:delete(); e:delete()
  assert(#f.activated==0 and f.filter.deleted and f.canvas.deleted and f.capture.resetCalled)
  assert(next(e.records)==nil and e.pollTimer.stopped and e.refreshTimer.stopped)
  assert(e.tap.stopped and e.screenWatcher.stopped)
end)
test('launch chords remain registered without enable/disable churn during navigation', function()
  local file=assert(io.open('src/window.lua'));local source=file:read('*a');file:close()
  local first=assert(source:find('-- Keep the inventory',1,true))
  local last=assert(source:find('-- show a dialog to specify a window title',first,true))
  local bound, calls, launched, quit, launchTap, tapCreations = {}, {}, nil, nil, nil, 0
  local fake = {active=false}
  function fake:cycle(mode,direction,repeated,modifiers)
    calls[#calls+1]={mode=mode,direction=direction,repeated=repeated,modifiers=modifiers}
    self.mode=mode;self.active=true;self.options.onActiveChange(true,self.mode)
  end
  function fake:finish() self.active=false;self.options.onActiveChange(false) end
  local function bind(spec,_,pressed,released,repeated)
    if not spec then return end
    local key={pressed=pressed,repeated=repeated,enabled=true}
    function key:enable() error('session must not enable a launch hotkey') end
    function key:disable() error('session must not disable a launch hotkey') end
    function key:delete() self.deleted=true end
    bound[spec.name]=key;return key
  end
  local misc={}
  for _,key in ipairs({'switchWindow','switchWindowBack','switchWindowBackTriggered',
    'switchMinimizedWindowBackTriggered','switchBrowserWindow','switchBrowserWindowBack',
    'switchBrowserWindowBackTriggered'}) do
    misc[key]={name=key,key=key:find('Triggered') and '`' or 'tab',mods=key:find('Browser') and {'control','option'} or 'option'}
  end
  misc.switchWindowBack.mods={'shift','option'}
  local filter={setDefaultFilter=function(self) return self end}
  local env=setmetatable({misc=misc,ignoredApps={},FLAGS={},find=function() end,
    newWindowSwitch=function() error('navigation must not register a hotkey') end,bindWindowSwitch=bind,
    require=function() return {new=function(options) fake.options=options;return fake end} end,
    ExecOnSilentLaunch=function(_,fn) launched=fn end,ExecOnSilentQuit=function(_,fn) quit=fn end,
    hs={eventtap={event={types={keyDown=1},properties={keyboardEventAutorepeat=1}},new=function(_,fn)
      tapCreations=tapCreations+1;launchTap={fn=fn}
      function launchTap:start() self.running=true;return self end
      function launchTap:stop() self.running=false;return self end
      return launchTap
    end},keycodes={map={tab=48}},window={filter={new=function() return filter end}},application={runningApplications=function() return {} end,
      watcher={new=function() return {start=function(self) return self end} end}}}}, {__index=_G})
  assert(load(source:sub(first,last-1),'bindings','t',env))()
  assert(not bound.switchWindowBackTriggered and not bound.switchMinimizedWindowBackTriggered and not bound.switchBrowserWindowBackTriggered)
  bound.switchWindow.pressed()
  assert(calls[#calls].mode=='normal')
  for _,key in pairs(bound) do assert(key.enabled and key.repeated==nil) end
  assert(bound.switchWindowBack==nil)
  bound.switchWindow.pressed();assert(#calls==1)
  fake:finish();for _,key in pairs(bound) do assert(key.enabled) end
  bound.switchBrowserWindowBack.pressed()
  assert(calls[#calls].direction==-1 and calls[#calls].modifiers[1]=='ctrl')
  launched();assert(bound.switchWindow.deleted and bound.switchWindowBack==nil)
  fake:finish();assert(bound.switchBrowserWindow.enabled and not launchTap.running)
  quit();assert(launchTap.running and tapCreations==1)
  local function event(flags,repeated)
    return {getKeyCode=function() return 48 end,getFlags=function() return flags end,
      getProperty=function() return repeated and 1 or 0 end}
  end
  assert(not launchTap.fn(event({alt=true})))
  assert(not launchTap.fn(event({alt=true,shift=true,ctrl=true})))
  assert(not launchTap.fn(event({alt=true,shift=true},true)))
  env.FLAGS.SUSPEND=true;assert(not launchTap.fn(event({alt=true,shift=true})));env.FLAGS.SUSPEND=false
  assert(launchTap.fn(event({alt=true,shift=true,capslock=true})))
  assert(calls[#calls].mode=='minimized' and calls[#calls].direction==1)
  local count=#calls
  assert(not launchTap.fn(event({alt=true,shift=true})))
  assert(#calls==count and bound.switchWindowBack==nil)
  fake:finish()
end)

test('overflow wraps into visible rows without changing the first row while cycling',function()
  local f=fixture(24);local e=f.engine
  e:cycle('normal',1,false,{'alt'})
  assert(e.rows>1 and e.columns<#e.session)
  assert(f.canvas.elements[3].frame.w>136 and f.canvas.elements[3].frame.h>76)
  local first=f.canvas.elements[3].image
  local firstFrame=f.canvas.elements[3].frame
  for _=1,e.columns do e:cycle('normal',1,false,{'alt'}) end
  assert(f.canvas.elements[3].image==first and f.canvas.elements[3].frame.x==firstFrame.x and f.canvas.elements[3].frame.y==firstFrame.y)
  assert(f.canvas.elements[2].frame.y>e.tileFrames[1].y)
  for i=1,#e.session do assert(f.canvas.elements[3+(i-1)*3].action~='skip') end
  assert(f.capture.visible and f.capture.frame.h<900)
  e:finish(false);assert(not f.capture.visible)
end)

test('eventtap handles forward/reverse, modes, repeats and unrelated keys',function()
  local f=fixture(12);local e=f.engine
  local function key(code,shift,repeated) return e.tap.fn(f.event(1,code,{alt=true,shift=shift},repeated)) end
  e:cycle('normal',1,false,{'alt'})
  assert(key(48,true)==true and e.selected==1)
  key(48,true,true);assert(e.selected==1)
  key(48,true);assert(e.selected==12)
  key(50,false);assert(e.selected==11)
  key(48,false);assert(e.selected==12)
  key(48,false,true);assert(e.selected==12)
  assert(key(0,false)==false)
  e:finish(false);e:cycle('minimized',1,false,{'alt'})
  key(48,true);assert(e.selected==3)
  key(50,true);assert(e.selected==2)
  e:finish(false);assert(key(48,false)==false)
end)

test('arrow keys navigate rows spatially and clamp at the grid edges',function()
  local f=fixture(10);local e=f.engine
  e:cycle('normal',1,false,{'alt'})
  local function key(code) assert(e.tap.fn(f.event(1,code,{alt=true}))) end
  assert(e.columns==4 and e.rows==3)
  key(126);assert(e.selected==2)
  key(125);assert(e.selected==6)
  key(124);assert(e.selected==7)
  key(124);assert(e.selected==8)
  key(124);assert(e.selected==8)
  key(125);assert(e.selected==10)
  key(125);assert(e.selected==10)
  key(126);assert(e.selected==7)
  key(123);key(123);key(123);assert(e.selected==5)
end)

test('grid viewport defaults to 3 rows by 4 columns and fits portrait/landscape',function()
  local grid=Switcher.gridLayout(12,{w=1440,h=900})
  assert(grid.rows==3 and grid.columns==4 and grid.scale==1)
  for _,screen in ipairs({{w=1440,h=900},{w=900,h=1440},{w=1920,h=1080},{w=800,h=600}}) do
    for _,count in ipairs({1,5,12,13,24,60,200}) do
      local g=Switcher.gridLayout(count,screen)
      assert(g.columns*g.rows>=count and (g.rows-1)*g.columns<count)
      assert(g.columns*300*g.scale+24<=screen.w-48+0.001)
      assert(g.visibleRows*230*g.scale+42<=screen.h-48+0.001)
    end
  end
end)

test('new windows join an open panel without reordering survivors or changing selection',function()
  local f=fixture(12);local e=f.engine
  e:cycle('normal',1,false,{'alt'})
  local selected=e.session[e.selected]
  local added=f.window(13)
  local reordered={added};for i=12,1,-1 do reordered[#reordered+1]=f.windows[i] end
  f.setWindows(reordered)
  f.filter.callback(added);e.inventoryTimer.fn()
  assert(#e.session==13 and e.session[13]==13)
  for i=1,12 do assert(e.session[i]==i) end
  assert(e.session[e.selected]==selected)
  assert(e.columns*e.rows>=13 and f.canvas.elements[3+12*3].action~='skip')
  e:rebuild();assert(#e.session==13)
  added.hidden=true;f.filter.callback(added);e.inventoryTimer.fn()
  assert(#e.session==12 and e.session[e.selected]==selected)
end)

test('grid follows fixed count boundaries and neither dimension shrinks as windows are added',function()
  local screen={w=1440,h=900}
  for _,case in ipairs({{1,1,1},{4,1,4},{5,2,4},{8,2,4},{9,3,4},{12,3,4},
    {13,3,5},{15,3,5},{16,4,5},{20,4,5},{21,4,6},{24,4,6},{25,5,6},{30,5,6},
    {31,6,6},{35,6,6},{36,6,6},{37,7,6}}) do
    local g=Switcher.gridLayout(case[1],screen)
    assert(g.rows==case[2] and g.columns==case[3], 'count '..case[1])
  end
  local previous={rows=0,columns=0}
  for count=1,500 do
    local g=Switcher.gridLayout(count,screen)
    assert(g.rows>=previous.rows and g.columns>=previous.columns)
    local portrait=Switcher.gridLayout(count,{w=900,h=1440})
    assert(g.rows==portrait.rows and g.columns==portrait.columns)
    previous=g
  end
  local f=fixture(15);local e=f.engine;e:cycle('normal',1,false,{'alt'})
  assert(e.rows==3 and e.columns==5)
  local selected=e.session[e.selected]
  f.windows[16]=f.window(16);f.filter.callback(f.windows[16]);e.inventoryTimer.fn()
  assert(e.rows==4 and e.columns==5 and e.session[e.selected]==selected)
end)

test('more than thirty windows scroll at fixed card size with a bounded canvas pool',function()
  local f=fixture(47);local e=f.engine
  local base=Switcher.gridLayout(30,{w=1440,h=900})
  e:cycle('normal',1,false,{'alt'})
  assert(e.columns==6 and e.visibleRows==5 and e.rows==8 and e.slots==30 and e.scale==base.scale)
  local selected=e.session[e.selected]
  e:scrollRows(1)
  assert(e.scrollRow==1 and e.session[e.selected]==selected)
  assert(f.canvas.elements[3].image==e.records[e.session[7]].icon)
  assert(f.canvas.elements[2].action=='skip')
  e:rebuild();assert(e.scrollRow==1)
  e:scrollRows(100);assert(e.scrollRow==3)
  assert(f.canvas.elements[3+29*3].action=='skip')
  e:scrollRows(-100);assert(e.scrollRow==0)
  for _=1,29 do e:cycle('normal',1,false,{'alt'}) end
  assert(e.selected==31 and e.scrollRow==1 and f.canvas.elements[2].action~='skip')
  e:finish(false);e:cycle('normal',-1,false,{'alt'})
  assert(e.selected==47 and e.scrollRow==3)
  for _=1,46 do e:cycle('normal',-1,false,{'alt'}) end
  assert(e.selected==1 and e.scrollRow==0)
end)

test('wheel and trackpad events scroll rows, consume input and respect limits',function()
  local f=fixture(60);local e=f.engine;e:cycle('normal',1,false,{'alt'})
  local function wheel(continuous,delta)
    return {getType=function() return 3 end,getProperty=function(_,p)
      if p==2 then return continuous and 1 or 0 end
      if p==3 or p==4 then return delta end
      return 0
    end}
  end
  assert(e.tap.fn(wheel(false,-1)) and e.scrollRow==1)
  e.tap.fn(wheel(true,-20));assert(e.scrollRow==1)
  e.tap.fn(wheel(true,-20));assert(e.scrollRow==2)
  e.tap.fn(wheel(false,100));assert(e.scrollRow==0)
  e:finish(false);assert(not e.tap.fn(wheel(false,-1)))
end)

test('closing windows while scrolled clamps the viewport and keeps selection valid',function()
  local f=fixture(40);local e=f.engine;e:cycle('normal',-1,false,{'alt'})
  assert(e.scrollRow==2)
  local remaining={};for i=1,20 do remaining[i]=f.windows[i] end
  f.setWindows(remaining);e:rebuild()
  assert(#e.session==20 and e.scrollRow==0 and e.selected==20)
  assert(e.visibleRows==e.rows)
end)

test('commit hides both panels before deferred activation and recovers a missed modifier release',function()
  local f=fixture();local e=f.engine
  e:cycle('normal',1,false,{'alt'})
  e.pollTimer.fn();assert(e.active)
  f.modifiers({})
  e.pollTimer.fn()
  assert(not e.active and not f.canvas.visible and not f.capture.visible and e.tap.stopped)
  assert(#f.activated==0 and e.focusTimer)
  e.focusTimer.fn();assert(#f.activated==1 and f.activated[1]==2)
  e.pollTimer.fn();assert(#f.activated==1)
end)

test('a new session or disposal cancels any pending activation',function()
  local f=fixture();local e=f.engine
  e:cycle('normal',1,false,{'alt'});e:finish(true)
  local pending=e.focusTimer
  e:cycle('normal',1,false,{'alt'})
  assert(pending.stopped)
  e:finish(true);pending=e.focusTimer;e:delete()
  assert(pending.stopped and #f.activated==0)
end)

test('unchanged layouts skip native positioning but monitor moves still update geometry',function()
  local f=fixture(12);local e=f.engine
  assert(f.capture.positions==1)
  e:layout();e:layout();assert(f.capture.positions==1)
  e:cycle('normal',1,false,{'alt'});assert(f.capture.positions==1)
  local previousX=f.capture.frame.x
  f.screen({x=1440,y=0,w=1440,h=900});e:layout()
  assert(f.capture.positions==2 and f.capture.frame.x==previousX+1440)
end)

print(passed .. ' tests passed')
