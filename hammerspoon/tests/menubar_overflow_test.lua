-- Run with: lua tests/menubar_overflow_test.lua
local pending, alerts, activated, reveals = {}, 0, 0, 0
local screen = { fullFrame = function() return { x = 0, y = 0, w = 1000, h = 800 } end }
local arrow = { AXPosition = { x = 500, y = 0 }, AXSize = { w = 20, h = 24 } }
local expanded = false
function arrow:attributeValue() return expanded and 'hide' or 'show' end
local window = { AXPosition = { x = 0, y = 0 }, AXSize = { w = 1000, h = 24 } }
local app = { bundleID = function() return 'com.apple.MenuBarAgent' end }
local env = setmetatable({
  OS_VERSION = 27, OS = { ['Golden Gate'] = 27 }, AX = { Window = 'window', Button = 'button' },
  find = function() return app end, toappui = function(a) return a end,
  getc = function(_, role, index)
    if role == 'window' then return index and window or { window } end
    return { arrow }
  end,
  tfind = function(items, predicate) for _, item in ipairs(items) do if predicate(item) then return item end end end,
  tfilter = function(items, predicate) local r = {} for _, item in ipairs(items) do if predicate(item) then r[#r + 1] = item end end return r end,
  localizedString = function(key) return key:find('showOverflow') and 'show' or 'hide' end,
  hs = { screen = { find = function(rect)
    -- Point arguments are display-layout positions, not absolute pixels.
    if rect.w and rect.h and rect.x >= 0 and rect.x < 1000 then return screen end
  end },
    timer = { doAfter = function(_, fn) local timer = { fn = fn }; pending[#pending + 1] = timer; return timer end },
    alert = { show = function() alerts = alerts + 1 end } },
}, { __index = _G })
local m = assert(loadfile('src/utils/menubar_reveal.lua', 't', env))()
local item = { pid = function() return 7 end, AXPosition = { x = 500, y = 0 }, AXSize = { w = 20, h = 24 }, isValid = function() return true end }
m.setOverflowExpanded = function() reveals = reveals + 1; return true end
local rendered = { x = 460, y = 0, w = 20, h = 24, element = item }
m.visibleItems = function() return expanded and { rendered } or {} end
local function activate(target) assert(target == rendered); activated = activated + 1 end
local function tick() table.remove(pending, 1).fn() end
assert(m.revealBeforeActivation(item, activate))
assert(m.revealBeforeActivation(item, activate) and reveals == 1)
tick()
assert(activated == 0, 'must wait for expansion')
expanded = true
tick()
assert(activated == 0, 'a source still stacked beneath the arrow must not match a host')
item.AXPosition.x = 460
tick()
assert(activated == 1 and #pending == 0)
assert(m.revealBeforeActivation(item, activate), 'a revealed item still belongs to the overflow')
tick()
assert(activated == 2)
expanded = false
item.AXPosition.x = 600
assert(not m.revealBeforeActivation(item, activate), 'visible item must not expand overflow')
item.AXPosition.x = 500
assert(m.revealBeforeActivation(item, activate))
for _ = 1, 40 do tick() end
assert(alerts == 1 and activated == 2 and #pending == 0, 'timeout must not click a hidden item')
item.isValid = function() return false end
assert(m.revealBeforeActivation(item, activate))
tick()
assert(#pending == 0 and activated == 2, 'removed item must not activate')
env.OS_VERSION = 26
assert(not m.revealBeforeActivation(item, activate), 'older macOS must retain existing behavior')
print('PASS: overflow expansion, delayed source coordinates, duplicate activation, visible items, timeout, removed item, macOS 26')
env.OS_VERSION = 27
expanded = true
item.isValid = function() return true end
-- Icons of one application are told apart by their own revealed positions.
local left = { x = 300, y = 0, w = 30, h = 24 }
local right = { x = 450, y = 0, w = 30, h = 24 }
m.visibleItems = function() return { right, left } end
local selected
item.AXPosition.x = 303
assert(m.revealBeforeActivation(item, function(target) selected = target end))
tick()
assert(selected == left, 'the host must contain the revealed source item')
local own = { frame = function() return { x = 452, y = 0, w = 26, h = 24 } end }
assert(m.revealBeforeActivation(own, function(target) selected = target end))
tick()
assert(selected == right, 'hs.menubar objects use their live frame')
print('PASS: icons of one application and hs.menubar objects resolve by revealed position')
-- Unnamed icons collapsed together: the entry's slot picks the host in saved order.
local sibling = { pid = item.pid, AXPosition = { x = 500, y = 0 }, AXSize = { w = 20, h = 24 } }
item.AXPosition.x = 500
env.hs.application = { applicationForPID = function() return app end }
env.loadStatusItemsAutosaveName = function() return {}, { 864, 544 }, { item, sibling } end
local farHost = { x = 300, y = 0, w = 30, h = 24, element = { pid = item.pid } }
local nearHost = { x = 450, y = 0, w = 30, h = 24, element = { pid = item.pid } }
m.visibleItems = function() return { farHost, nearHost } end
assert(m.revealBeforeActivation(item, function(target) selected = target end, 544))
tick()
assert(selected == nearHost, 'the smaller saved slot is the rightmost host')
assert(m.revealBeforeActivation(item, function(target) selected = target end, 864))
tick()
assert(selected == farHost, 'the slot, not the arbitrarily assigned source, picks the host')
print('PASS: unnamed collapsed icons resolve by their saved slot')
item.AXPosition.x = 303
m.visibleItems = function() return { right, left } end

-- Both windows remain in AX, but only the rendered window changes its label.
local collapsedArrow = { attributeValue = function() return 'show' end }
local proxyWindow = { AXPosition = window.AXPosition, AXSize = window.AXSize }
local hosts = { window, proxyWindow }
env.getc = function(element, role, index)
  if role == 'window' then return index and hosts[index] or hosts end
  return { element == window and arrow or collapsedArrow }
end
for _, order in ipairs({ { window, proxyWindow }, { proxyWindow, window } }) do
  hosts = order
  selected = nil
  assert(m.revealBeforeActivation(item, function(target) selected = target end))
  tick()
  assert(selected == left, 'expanded host must be recognized in either window order')
end
print('PASS: expanded host is selected in either AX window order')
local events, hovers = {}, {}
env.hs.mouse = { absolutePosition = function() return { x = 900, y = 500 } end }
env.hs.eventtap = { event = {
  types = { leftMouseDown = 1, leftMouseUp = 2, rightMouseDown = 3, rightMouseUp = 4, mouseMoved = 5 },
  properties = { mouseEventClickState = 1 },
  newMouseEvent = function(kind, point)
    return { setProperty = function(self, property, value)
      assert(property == 1); self.clickCount = value; return self
    end, post = function(self)
      if kind == 5 then hovers[#hovers + 1] = point.x return end
      assert(self.clickCount == 1, 'both mouse events must carry a single click')
      events[#events + 1] = kind
    end }
  end,
} }
for _, rightClick in ipairs({ false, true }) do
  assert(m.clickGoldenGate({ x = 300, y = 0, w = 24, h = 28 }, rightClick))
  assert(not m.clickGoldenGate({ x = 300, y = 0, w = 24, h = 28 }, rightClick))
  tick(); tick()
end
assert(table.concat(events, ',') == '1,2,3,4')
assert(#hovers == 2 and hovers[1] == 900, 'restoring the cursor must post mouseMoved for Ping Island')
print('PASS: left/right clicks carry click count 1 on both down and up; duplicate clicks suppressed')

-- The overflow button sits beside the notch; fallbacks must stay on its far side.
local notch, covered = { pid = function() return 9 end }, {}
env.find = function(id) return id == 'com.wudanwu.PingIsland' and notch or app end
env.hs.axuielement = {}
local clicked
local fresh = assert(loadfile('src/utils/menubar_reveal.lua', 't', env))()
fresh.clickGoldenGate = function(frame) clicked = frame.clickPoint; return true end
expanded, covered = false, {}
local owner = { pid = function() return 5 end }
arrow.pid = owner.pid
env.getc = function(_, role, index)
  if role == 'window' then return index and window or { window } end
  return { arrow }
end
env.hs.axuielement.systemElementAtPosition = function(point)
  return covered[point.x] and notch or owner
end
assert(fresh.setOverflowExpanded(screen, true) and clicked.x == 515)
covered = { [515] = true }
assert(fresh.setOverflowExpanded(screen, true) and clicked.x == 519)
covered, clicked = { [515] = true, [519] = true }, nil
assert(not fresh.setOverflowExpanded(screen, true) and clicked == nil,
  'covered far side must not move the click toward the notch')
print('PASS: overflow button clicks stay on the side away from the notch')

-- Overflow expanded only for an activation collapses after the configured delay.
local timers, requests, config, changed = {}, {}, {}, true
env.hs.timer.doAfter = function(delay, fn)
  local timer = { delay = delay, fn = fn }
  function timer:stop() self.stopped = true end
  timers[#timers + 1] = timer
  return timer
end
env.exists = function(path) return path == 'config/misc.json' end
env.hs.json = { read = function() return config end }
local auto = assert(loadfile('src/utils/menubar_reveal.lua', 't', env))()
auto.setOverflowExpanded = function(_, value) requests[#requests + 1] = value; return true, changed end
local function collapses()
  local found = {}
  for _, timer in ipairs(timers) do
    if timer.delay ~= 0.05 and not timer.stopped and not timer.fired then found[#found + 1] = timer end
  end
  return found
end
local function fire() local timer = collapses()[1]; timer.fired = true; timer.fn() end
local function settle() -- let pending reveal polling finish without activating
  item.isValid = function() return false end
  for _, timer in ipairs(timers) do
    if timer.delay == 0.05 and not timer.ran then timer.ran = true; timer.fn() end
  end
  item.isValid = function() return true end
end
expanded = false
assert(auto.revealBeforeActivation(item, activate))
assert(#collapses() == 1 and collapses()[1].delay == 15, 'default collapse delay is 15s')
settle()
local first = collapses()[1]
changed = false
assert(auto.revealBeforeActivation(item, activate))
assert(first.stopped and #collapses() == 1, 'a later activation restarts the delay')
settle()
fire()
assert(requests[#requests] == false, 'collapse requests a collapsed overflow')
assert(auto.revealBeforeActivation(item, activate))
assert(#collapses() == 0, 'overflow that was already shown is left alone')
settle()
changed, config = true, { menuBarOverflowCollapseDelay = 0 }
assert(auto.revealBeforeActivation(item, activate))
assert(#collapses() == 0, 'a zero delay disables automatic collapse')
settle()
config = { menuBarOverflowCollapseDelay = 5 }
assert(auto.revealBeforeActivation(item, activate))
assert(collapses()[1].delay == 5, 'configured delay is honored')
settle()
assert(auto.clickGoldenGate({ x = 300, y = 0, w = 24, h = 28 }))
local count = #requests
fire()
assert(#requests == count and collapses()[1].delay == 1, 'collapse waits for an in-flight click')
print('PASS: overflow expanded for activation collapses after the configured delay')
