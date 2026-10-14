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
  local h = {window={filter={}}, eventtap={event={types={keyDown=1,flagsChanged=2}}},
    keycodes={map={escape=53}}, canvas={windowLevels={overlay=1}}, image={}, screen={}, timer={}}
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
  function h.screen.mainScreen() return {frame=function() return {x=0,y=0,w=1440,h=900} end} end
  h.screen.watcher={new=function(fn) return timer(fn) end}
  function h.image.imageFromAppBundle(id) return 'icon:'..id end
  function h.image.imageFromName(id) return 'fallback:'..id end
  function h.image.imageFromURL(url) return 'decoded:'..url end
  local canvas = {elements={}}
  function h.canvas.new() allocations=allocations+1; return canvas end
  for _, name in ipairs({'level','behavior','frame'}) do canvas[name]=function(self) return self end end
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
    counts=function() return queries,shown,allocations end,
    event=function(kind,key,flags) return {getType=function() return kind end,getKeyCode=function() return key end,
      getFlags=function() return flags or {} end} end}
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
test('real shortcut bindings preserve both directions, browser isolation and external AltTab disable', function()
  local file=assert(io.open('src/window.lua'));local source=file:read('*a');file:close()
  local first=assert(source:find('-- Keep the inventory',1,true))
  local last=assert(source:find('-- show a dialog to specify a window title',first,true))
  local bound, calls, launched = {}, {}, nil
  local fake = {active=false}
  function fake:cycle(mode,direction,repeated,modifiers)
    calls[#calls+1]={mode=mode,direction=direction,repeated=repeated,modifiers=modifiers}
    if not self.active then self.mode=mode;self.active=true end
    self.options.onActiveChange(true,self.mode)
  end
  function fake:finish() self.active=false;self.options.onActiveChange(false) end
  local function bind(spec,_,pressed,released,repeated)
    if not spec then return end
    local key={pressed=pressed,repeated=repeated}
    function key:enable() self.enabled=true end
    function key:disable() self.enabled=false end
    function key:delete() self.deleted=true end
    bound[spec.name]=key;return key
  end
  local misc={}
  for _,key in ipairs({'switchWindow','switchWindowBack','switchWindowBackTriggered',
    'switchMinimizedWindowBackTriggered','switchBrowserWindow','switchBrowserWindowBack',
    'switchBrowserWindowBackTriggered'}) do
    misc[key]={name=key,mods=key:find('Browser') and {'control','option'} or 'option'}
  end
  local filter={setDefaultFilter=function(self) return self end}
  local env=setmetatable({misc=misc,ignoredApps={},FLAGS={},find=function() end,
    newWindowSwitch=bind,bindWindowSwitch=bind,
    require=function() return {new=function(options) fake.options=options;return fake end} end,
    ExecOnSilentLaunch=function(_,fn) launched=fn end,ExecOnSilentQuit=function() end,
    hs={window={filter={new=function() return filter end}},application={runningApplications=function() return {} end,
      watcher={new=function() return {start=function(self) return self end} end}}}}, {__index=_G})
  assert(load(source:sub(first,last-1),'bindings','t',env))()
  bound.switchWindow.pressed();bound.switchWindowBack.pressed()
  assert(calls[#calls].direction==-1)
  bound.switchWindowBack.repeated();assert(calls[#calls].direction==-1 and calls[#calls].repeated)
  assert(bound.switchWindowBackTriggered.enabled and not bound.switchBrowserWindowBackTriggered.enabled)
  fake:finish()
  bound.switchWindowBack.pressed();bound.switchWindowBack.pressed()
  assert(calls[#calls].direction==1)
  bound.switchMinimizedWindowBackTriggered.pressed();assert(calls[#calls].direction==-1)
  fake:finish()
  bound.switchBrowserWindow.pressed();bound.switchBrowserWindowBack.pressed()
  assert(calls[#calls].direction==-1 and calls[#calls].modifiers[1]=='ctrl')
  assert(bound.switchBrowserWindowBackTriggered.enabled and not bound.switchWindowBackTriggered.enabled)
  launched();assert(bound.switchWindow.deleted and bound.switchWindowBack.deleted)
end)

print(passed .. ' tests passed')
