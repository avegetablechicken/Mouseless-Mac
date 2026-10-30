-- Run from the configuration root: lua tests/browser_tab_search_spec.lua
local file = assert(io.open('src/window.lua'))
local source = file:read('*a'); file:close()
local implementation = assert(source:match('(local cancelTabSearch.-)\n%-%- PDF / Tab chooser%.'))
local binding = assert(source:match('(bindWindowSwitch%(misc%["searchTab"%].-)\n%-%- Bind a Stage Manager'))

local function fixture(options)
  options = options or {}
  local state = {tasks = {}, timers = {}, choosers = {}, alerts = {}, scripts = 0}
  local apps = {}
  for i, id in ipairs(options.browsers or {'com.apple.Safari', 'com.google.Chrome'}) do
    apps[i] = {bundleID = function() return id end, pid = function() return i end,
      kind = function() return 1 end, allWindows = function() return {1} end,
      activate = function() state.activated = i end}
  end
  local env = setmetatable({misc = {}, tinsert = table.insert,
    tcontain = function() return false end,
    browserSet = {['com.apple.Safari'] = true, ['com.google.Chrome'] = true},
    bindWindowSwitch = function(_, _, fn) state.open = fn end,
    localizedMenuBarItem = function() return nil end,
    tabFaviconLookup = function()
      return function() return 'favicon' end, function() end
    end,
    hs = {
      application = {runningApplications = function() return apps end,
        frontmostApplication = function() return apps[1] or {bundleID = function() return '' end} end,
        applicationForPID = function(pid) return apps[pid] end},
      json = {decode = function(output)
        if output == 'invalid' then error('invalid JSON') end
        return output
      end},
      image = {imageFromAppBundle = function() return 'app-icon' end},
      alert = {show = function(message) table.insert(state.alerts, message) end},
      osascript = {javascript = function()
        state.scripts = state.scripts + 1; return true, 'selected window'
      end},
      shutdownCallback = function() state.shutdown = true end,
      timer = {doAfter = function(delay, fn)
        local timer = {delay = delay, fire = fn, stop = function(self) self.stopped = true end}
        table.insert(state.timers, timer); return timer
      end},
      chooser = {new = function(callback)
        local chooser = {callback = callback, items = {}, searchSubText = function() end,
          placeholderText = function(self, text) self.prompt = text end,
          hideCallback = function(self, fn) self.onHide = fn end,
          show = function(self) self.visible = true end,
          hide = function(self) self.visible = false; if self.onHide then self.onHide() end end,
          choices = function(self, items) self.items = items; self.updates = (self.updates or 0) + 1 end}
        table.insert(state.choosers, chooser); return chooser
      end},
      task = {new = function(path, callback, args)
        assert(path == '/usr/bin/osascript' and args[1] == '-l' and args[2] == 'JavaScript')
        local task = {args = args,
          start = function(self) self.running = not options.failStart; return self.running and self end,
          isRunning = function(self) return self.running end,
          terminate = function(self) self.terminated = true; self.running = false end,
          finish = function(self, code, output) self.running = false; callback(code, output) end}
        table.insert(state.tasks, task); return task
      end},
    },
  }, {__index = _G})
  assert(load(implementation .. binding, 'tab-search', 't', env))()
  state.hs = env.hs
  return state
end

local tabs = {{title = 'Example', url = 'https://example.invalid', id = 7, winID = 42}}
local s = fixture()
s.open()
assert(s.scripts == 0 and #s.tasks == 2 and s.choosers[1].visible)
local chooser = s.choosers[1]
chooser.query = 'typed while loading'
s.tasks[2]:finish(0, tabs)
assert(#chooser.items == 1 and chooser.items[1].pid == 2)
s.tasks[1]:finish(0, tabs)
assert(#chooser.items == 2 and chooser.query == 'typed while loading' and s.timers[1].stopped)
chooser.callback(chooser.items[1])
assert(s.scripts == 1 and s.activated == 2 and not chooser.visible)

s = fixture()
s.open(); local old = s.choosers[1]
s.open()
assert(s.tasks[1].terminated and s.tasks[2].terminated and not old.visible)
s.tasks[1]:finish(0, tabs)
assert(not old.updates and not s.choosers[2].updates, 'late results must not update either chooser')
s.choosers[2]:hide()
assert(s.tasks[3].terminated and s.tasks[4].terminated)
s.tasks[3]:finish(1, '')
assert(#s.alerts == 0, 'cancellation must be silent')

s = fixture()
s.open(); s.timers[1].fire()
assert(s.tasks[1].terminated and not s.choosers[1].visible and s.alerts[1] == 'TAB SEARCH TIMED OUT')
s.tasks[1]:finish(0, tabs)
assert(not s.choosers[1].updates)

s = fixture({failStart = true})
s.open()
assert(not s.choosers[1].visible and #s.alerts == 1 and s.timers[1].stopped)
s = fixture()
s.open(); s.tasks[1]:finish(0, 'invalid'); s.tasks[2]:finish(0, tabs)
assert(s.choosers[1].visible and #s.choosers[1].items == 1 and #s.alerts == 0)
s = fixture({browsers = {}})
s.open()
assert(#s.tasks == 0 and not s.choosers[1].visible and s.alerts[1] == 'NO VALID TABS')
s = fixture()
s.open(); s.hs.shutdownCallback()
assert(s.shutdown and s.tasks[1].terminated and s.tasks[2].terminated)
print('PASS: async tab search, aggregation, selection, replacement, dismissal, timeout, failures and shutdown')
