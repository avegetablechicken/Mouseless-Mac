-- Run with: lua tests/menubar_manager_test.lua
-- Native overflow detection: expanded overflow still hides the source item.
local screen = { fullFrame = function() return { x = 0, y = 0, w = 1000, h = 800 } end }
local arrow = { AXPosition = { x = 500, y = 0 }, AXSize = { w = 20, h = 24 } }
local expanded = false
function arrow:attributeValue() return expanded and 'hide' or 'show' end
local window = { AXPosition = { x = 0, y = 0 }, AXSize = { w = 1000, h = 24 } }
local agent = { bundleID = function() return 'com.apple.MenuBarAgent' end }
local revealEnv = setmetatable({
  OS_VERSION = 27, OS = { ['Golden Gate'] = 27 }, AX = { Window = 'window', Button = 'button' },
  find = function() return agent end, toappui = function(a) return a end,
  getc = function(_, role, index)
    if role == 'window' then return index and window or { window } end
    return { arrow }
  end,
  tfind = function(items, predicate) for _, item in ipairs(items) do if predicate(item) then return item end end end,
  tfilter = function(items, predicate) local r = {} for _, item in ipairs(items) do if predicate(item) then r[#r + 1] = item end end return r end,
  localizedString = function(key) return key:find('showOverflow') and 'show' or 'hide' end,
  hs = { screen = { find = function(rect) if rect.x >= 0 and rect.x < 1000 then return screen end end } },
}, { __index = _G })
local reveal = assert(loadfile('src/utils/menubar_reveal.lua', 't', revealEnv))()
local function at(x) return { AXPosition = { x = x, y = 0 }, AXSize = { w = 24, h = 24 } } end
assert(reveal.hiddenBySystemManager(at(500)))
expanded = true
assert(reveal.hiddenBySystemManager(at(300)), 'a revealed item still belongs to the overflow')
assert(not reveal.hiddenBySystemManager(at(600)))
assert(not reveal.hiddenBySystemManager(nil))
revealEnv.OS_VERSION = 26
assert(not reveal.hiddenBySystemManager(at(500)))
print('PASS: native overflow detection, revealed item, visible item, macOS 26')

-- Manager priority: MenuBarAgent first on Golden Gate; third-party managers on older macOS.
local running = {}
local item = { overflow = true, AXPosition = { x = 100 } }
local app = { bundleID = function() return 'example.app' end, name = function() return 'Example' end,
  AXExtrasMenuBar = { item } }
local revealed, clicked = 0, nil
local env = setmetatable({
  OS_VERSION = 27, OS = { ['Golden Gate'] = 27, Tahoe = 26 }, AX = { MenuBarItem = 'AXMenuBarItem' },
  find = function(id) return running[id] end, toappui = function(a) return a end,
  getc = function(bar, _, index)
    local items = bar and (bar.AXExtrasMenuBar or bar) or {}
    if index then return items[index] end
    return items
  end,
  foreach = function(t, f) for _, v in ipairs(t) do f(v) end end,
  tfind = revealEnv.tfind,
  require = function(name)
    assert(name == 'utils.menubar_reveal')
    return {
      hiddenBySystemManager = function(i) return i.overflow end,
      revealBeforeActivation = function(i, activate)
        if not i.overflow then return false end
        revealed = revealed + 1
        activate({ x = 40 })
        return true
      end,
      clickGoldenGate = function(target, right) clicked = { target = target, right = right } end,
    }
  end,
  hs = { screen = { allScreens = function() return { screen } end } },
}, { __index = _G })
assert(loadfile('src/utils/menubar.lua', 't', env))()
running['com.apple.MenuBarAgent'] = agent
local hidden, manager = env.hiddenByMenuBarManager(app, 1)
assert(hidden and manager == agent)
assert(env.clickRightMenuBarItem({ app, 1 }, {}, 'right-click'))
assert(revealed == 1 and clicked.target.x == 40 and clicked.right == true)
local bartender = { bundleID = function() return 'com.surteesstudios.Bartender' end,
  AXExtrasMenuBar = { { AXPosition = { x = 300 } } } }
running['com.surteesstudios.Bartender'] = bartender
hidden, manager = env.hiddenByMenuBarManager(app, 1)
assert(manager == agent and hidden, 'system manager takes precedence on Golden Gate')
env.OS_VERSION = 26
hidden, manager = env.hiddenByMenuBarManager(app, 1)
assert(manager == bartender and not hidden, 'older macOS keeps third-party managers')
running['com.surteesstudios.Bartender'] = nil
assert(env.hiddenByMenuBarManager(app, 1) == false, 'older macOS has no system manager')
print('PASS: system manager priority, asynchronous click, third-party managers on macOS 26')
