-- Run manually in Hammerspoon Console. No shortcut registration or window activation.
local root = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/') .. '/'
local output = hs.fs.temporaryDirectory() .. 'fast-window-switcher-'
local report = { started = hs.timer.secondsSinceEpoch(), samples = {} }
local engine, timers = nil, {}
local function write()
  local f=assert(io.open(output .. 'result.json','w'));f:write(hs.json.encode(report,true));f:close()
end
local function cleanup()
  for _,timer in ipairs(timers) do timer:stop() end
  if engine then engine:delete(); engine=nil end
end
local function checked(fn)
  local ok,err=xpcall(fn,debug.traceback)
  if not ok then report.error=err;cleanup();report.done=true;write();print('FAST_SWITCHER_DONE',err) end
end
local function after(delay,fn)
  timers[#timers+1]=hs.timer.doAfter(delay,function() checked(fn) end)
end
checked(function()
  local filter=hs.window.filter.new():setDefaultFilter({})
  for _, item in ipairs((ApplicationConfigs or {}).windowSwitcherIgnore or {}) do
    if type(item)=='string' then local app=hs.application.get(item);if app then filter:setAppFilter(app:name(),false) end
    elseif type(item)=='table' then for id,rule in pairs(item) do local app=hs.application.get(id);if app then filter:setAppFilter(app:name(),rule) end end end
  end
  engine=dofile(root..'src/window/switcher.lua').new({filter=filter,browsers={['com.apple.Safari']=true},
    capture=dofile(root..'src/window/capture.lua').new(hs),onActiveChange=function() end})
  report.normal=#engine.lists.normal;report.minimized=#engine.lists.minimized
  engine:cycle('normal',1,false,{})
  report.coldShowMs=engine.metrics.lastShowMs
  after(0.3,function() engine:finish(false) end)
  after(8,function()
    engine:cycle('normal',1,false,{})
    report.warmShowMs=engine.metrics.lastShowMs
    after(0.3,function()
      engine.canvas:imageFromCanvas():saveToFile(output .. 'preview.png')
      engine:finish(false)
      for i=1,20 do
        engine:cycle('normal',1,false,{})
        report.samples[i]=engine.metrics.lastShowMs
        engine:finish(false)
      end
      report.images=0;for _,r in pairs(engine.records) do if r.image then report.images=report.images+1 end end
      report.captureErrors=engine.captureErrors;report.lastCaptureError=engine.lastCaptureError
      cleanup();report.done=true;write();print('FAST_SWITCHER_DONE',hs.json.encode(report))
    end)
  end)
  print('FAST_SWITCHER_STARTED',report.normal,report.minimized)
end)
