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
env.hs.application = { applicationForPID = function() return nil end }
local function activate(target) assert(target == rendered); activated = activated + 1 end
local function tick() table.remove(pending, 1).fn() end
assert(m.revealBeforeActivation(item, activate))
assert(m.revealBeforeActivation(item, activate) and reveals == 1)
tick()
assert(activated == 0, 'must wait for expansion')
expanded = true
tick()
assert(item.AXPosition.x == 500, 'source coordinates remain collapsed')
assert(activated == 1 and #pending == 0)
assert(m.revealBeforeActivation(item, activate), 'already expanded overflow still needs rendered coordinates')
tick()
assert(activated == 2)
expanded = false
item.AXPosition.x = 600
assert(not m.revealBeforeActivation(item, activate), 'visible item must not expand overflow')
item.AXPosition.x = 500
assert(m.revealBeforeActivation(item, activate))
for _ = 1, 20 do tick() end
assert(alerts == 1 and activated == 2 and #pending == 0, 'timeout must not click a hidden item')
item.isValid = function() return false end
assert(m.revealBeforeActivation(item, activate))
tick()
assert(#pending == 0 and activated == 2, 'removed item must not activate')
env.OS_VERSION = 26
assert(not m.revealBeforeActivation(item, activate), 'older macOS must retain existing behavior')
print('PASS: overflow expansion, stale source coordinates, duplicate activation, visible items, timeout, removed item, macOS 26')
env.OS_VERSION = 27
expanded = true
item.isValid = function() return true end
local second = { pid = item.pid }
local left = { x = 300, element = { pid = item.pid } }
local right = { x = 450, element = { pid = item.pid } }
env.hs.application = { applicationForPID = function() return app end }
env.loadStatusItemsAutosaveName = function() return {}, { 800, 500 }, { item, second } end
m.visibleItems = function() return { left, right } end
local selected
assert(m.revealBeforeActivation(item, function(target) selected = target end))
tick()
assert(selected == left, 'multiple icons must follow saved order, not host child order')
print('PASS: multiple icons from the same application use saved layout order')

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
local events = {}
env.hs.mouse = { absolutePosition = function() return { x = 900, y = 500 } end }
env.hs.eventtap = { event = {
  types = { leftMouseDown = 1, leftMouseUp = 2, rightMouseDown = 3, rightMouseUp = 4 },
  properties = { mouseEventClickState = 1 },
  newMouseEvent = function(kind)
    return { setProperty = function(self, property, value)
      assert(property == 1); self.clickCount = value; return self
    end, post = function(self)
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
print('PASS: left/right clicks carry click count 1 on both down and up; duplicate clicks suppressed')
