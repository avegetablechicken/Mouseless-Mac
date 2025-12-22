local windowParams = KeybindingConfigs["parameters"] or {}
local moveStep = windowParams.windowMoveStep or 20
local resizeStep = windowParams.windowResizeStep or 100

local winHK = KeybindingConfigs.hotkeys.global

local function bindWindow(...)
  local hotkey = bindHotkeySpec(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.WIN_OP
  return hotkey
end

local frameCacheMaximize = {}

local function bindMoveWindow(hkID, message, fn, repeatable)
  local spec = winHK[hkID]
  if spec == nil then return end
  local newFn = function()
    fn()
    local win = hs.window.focusedWindow()
    if win == nil then return end
    frameCacheMaximize[win:id()] = nil
  end
  local repeatedfn = repeatable and newFn or nil
  local hotkey = bindWindow(spec, message, newFn, nil, repeatedfn)
  hotkey.subkind = HK.WIN_OP_.MOVE
  return hotkey
end

local windowMoveToFuncs = {}
local windowMoveTowardsFuncs = {}
local function bindURLEventForWindowMove()
  hs.urlevent.bind("windowmove", function(eventName, params)
    local fn
    if params["mode"] == "to" then
      fn = windowMoveToFuncs[params["direction"]]
    elseif params["mode"] == "towards" then
      fn = windowMoveTowardsFuncs[params["direction"]]
    end
    if fn then fn() end
  end)
end

local function bindMoveWindowURL(direction, mode, fn)
  local newFn = function()
    fn()
    local win = hs.window.focusedWindow()
    if win == nil then return end
    frameCacheMaximize[win:id()] = nil
  end
  if mode == 1 then
    windowMoveToFuncs[direction] = newFn
  elseif mode == 2 then
    windowMoveTowardsFuncs[direction] = newFn
  end
end

local windowResizeFuncs = {}
local function bindURLEventForWindowResize()
  hs.urlevent.bind("windowresize", function(eventName, params)
    local fn = windowResizeFuncs[params["mode"]]
    if fn then fn() end
  end)
end

local function bindResizeWindowURL(mode, fn)
  local newFn = fn
  if mode ~= "max" then
    newFn = function()
      fn()
      local win = hs.window.focusedWindow()
      if win == nil then return end
      frameCacheMaximize[win:id()] = nil
    end
  end
  windowResizeFuncs[mode] = newFn
end

local function bindResizeWindow(hkID, message, fn, repeatable)
  local spec = winHK[hkID]
  if spec == nil then return end
  local newFn = function()
    fn()
    local win = hs.window.focusedWindow()
    if win == nil then return end
    frameCacheMaximize[win:id()] = nil
  end
  local repeatedfn = repeatable and newFn or nil
  local hotkey = bindWindow(spec, message, newFn, nil, repeatedfn)
  hotkey.subkind = HK.WIN_OP_.RESIZE
  return hotkey
end

-- continuously move the focused window

-- move towards top-left
bindMoveWindow("moveTowardsTopLeft", "Move towards Top-Left",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  f.x = f.x - moveStep
  f.y = f.y - moveStep
  win:setFrame(f)
end)

-- move towards top
bindMoveWindow("moveTowardsTop", "Move towards Top",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  f.y = f.y - moveStep
  win:setFrame(f)
end)

-- move towards top-right
bindMoveWindow("moveTowardsTopRight", "Move towards Top-Right",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  f.x = f.x + moveStep
  f.y = f.y - moveStep
  win:setFrame(f)
end)

-- move towards left
bindMoveWindow("moveTowardsLeft", "Move towards Left",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  f.x = f.x - moveStep
  win:setFrame(f)
end)

-- move towards right
bindMoveWindow("moveTowardsRight", "Move towards Right",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  f.x = f.x + moveStep
  win:setFrame(f)
end)

-- move towards bottom-left
bindMoveWindow("moveTowardsBottomLeft", "Move towards Bottom-Left",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  f.x = f.x - moveStep
  f.y = f.y + moveStep
  win:setFrame(f)
end)

-- move towards bottom
bindMoveWindow("moveTowardsBottom", "Move towards Bottom",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  f.y = f.y + moveStep
  win:setFrame(f)
end)

-- move towards bottom-right
bindMoveWindow("moveTowardsBottomRight", "Move towards Bottom-Right",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  f.x = f.x + moveStep
  f.y = f.y + moveStep
  win:setFrame(f)
end)


local function getScreenFrame(win)
  local frame = win:screen():frame()
  local manager = find("com.apple.WindowManager")
  if manager then
    local groups = getc(toappui(manager), AX.Group)
    local g = tfind(groups or {}, function(g)
      return g.AXPosition.x == frame.x
    end)
    if g then
      local maxW = 0
      local buttons = getc(g, AX.List, 1, AX.Button) or {}
      if buttons[1] and buttons[1].AXPosition.x > g.AXPosition.x then
        foreach(buttons, function(bt)
          if bt.AXSize.w > maxW then maxW = bt.AXSize.w end
        end)
      end
      maxW = (math.ceil(maxW / 10) - 3) * 10
      frame.w = frame.w - maxW
      if buttons[1].AXPosition.x - g.AXPosition.x < g.AXSize.w / 2 then
        frame.x = frame.x + maxW
      end
    end
  end
  return frame
end

-- move and zoom to left
bindResizeWindow("zoomToLeftHalf", "Zoom To Left Half",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x
  f.y = max.y
  f.w = max.w / 2
  f.h = max.h
  win:setFrame(f)
end)

-- move and zoom to right
bindResizeWindow("zoomToRightHalf", "Zoom To Right Half",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x + max.w / 2
  f.y = max.y
  f.w = max.w / 2
  f.h = max.h
  win:setFrame(f)
end)

-- move and zoom to top
bindResizeWindow("zoomToTopHalf", "Zoom To Top Half",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x
  f.y = max.y
  f.w = max.w
  f.h = max.h / 2
  win:setFrame(f)
end)

-- move and zoom to bottom
bindResizeWindow("zoomToBottomHalf", "Zoom To Bottom Half",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x
  f.y = max.y + max.h / 2
  f.w = max.w
  f.h = max.h / 2
  win:setFrame(f)
end)

-- move and zoom to top-left
bindResizeWindow("zoomToTopLeft", "Zoom to Top-Left",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x
  f.y = max.y
  f.w = max.w / 2
  f.h = max.h / 2
  win:setFrame(f)
end)

-- move and zoom to top-right
bindResizeWindow("zoomToTopRight", "Zoom to Top-Right",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x + max.w / 2
  f.y = max.y
  f.w = max.w / 2
  f.h = max.h / 2
  win:setFrame(f)
end)

-- move and zoom to bottom-left
bindResizeWindow("zoomToBottomLeft", "Zoom to Bottom-Left",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x
  f.y = max.y + max.h / 2
  f.w = max.w / 2
  f.h = max.h / 2
  win:setFrame(f)
end)

-- move and zoom to bottom-right
bindResizeWindow("zoomToBottomRight", "Zoom to Bottom-Right",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x + max.h / 2
  f.y = max.y + max.h / 2
  f.w = max.w / 2
  f.h = max.h / 2
  win:setFrame(f)
end)

-- move and zoom to left 1/3
bindResizeWindow("zoomToLeft1/3", "Zoom to Left 1/3",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x
  f.y = max.y
  f.w = max.w / 3
  f.h = max.h
  win:setFrame(f)
end)

-- move and zoom to right 1/3
bindResizeWindow("zoomToRight1/3", "Zoom to Right 1/3",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x + max.w * 2 / 3
  f.y = max.y
  f.w = max.w / 3
  f.h = max.h
  win:setFrame(f)
end)

-- move and zoom to left 2/3
bindResizeWindow("zoomToLeft2/3", "Zoom to Left 2/3",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x
  f.y = max.y
  f.w = max.w * 2 / 3
  f.h = max.h
  win:setFrame(f)
end)

-- move and zoom to right 2/3
bindResizeWindow("zoomToRight2/3", "Zoom to Right 2/3",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)
  f.x = max.x + max.w * 2 / 3
  f.y = max.y
  f.w = max.w * 2 / 3
  f.h = max.h
  win:setFrame(f)
end)

-- maximize
bindResizeWindowURL("max",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  if frameCacheMaximize[win:id()] then
    win:setFrame(frameCacheMaximize[win:id()])
    frameCacheMaximize[win:id()] = nil
  else
    frameCacheMaximize[win:id()] = win:frame()
    local max = getScreenFrame(win)
    win:setFrame(max)
  end
end)

-- expand on left
bindResizeWindow("leftBorderExpand", "Left Border Expands",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local screen = win:screen()
  local max = screen:frame()

  local r = f.x + f.w
  f.x = math.max(max.x, f.x - resizeStep)
  f.w = r - f.x
  win:setFrame(f)
end)

-- shrink on left
bindResizeWindow("leftBorderShrink", "Left Border Shrinks",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  local r = f.x + f.w
  f.w = math.max(resizeStep, f.w - resizeStep)
  f.x = r - f.w
  win:setFrame(f)
end)

-- expand on right
bindResizeWindow("rightBorderExpand", "Right Border Expands",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local screen = win:screen()
  local max = screen:frame()

  f.w = math.min(max.x + max.w - f.x, f.w + resizeStep)
  win:setFrame(f)
end)

-- shrink on right
bindResizeWindow("rightBorderShrink", "Right Border Shrinks",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  f.w = math.max(resizeStep, f.w - resizeStep)
  win:setFrame(f)
end)

-- expand on top
bindResizeWindow("topBorderExpand", "Top Border Expands",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local screen = win:screen()
  local max = screen:frame()

  local b = f.y + f.h
  f.y = math.max(max.y, f.y - resizeStep)
  f.h = b - f.y
  win:setFrame(f)
end)

-- shrink on top
bindResizeWindow("topBorderShrink", "Top Border Shrinks",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  local b = f.y + f.h
  f.h = math.max(resizeStep, f.h - resizeStep)
  f.y = b - f.h
  win:setFrame(f)
end)

-- expand on bottom
bindResizeWindow("bottomBorderExpand", "Bottom Border Expands",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local screen = win:screen()
  local max = screen:frame()

  f.h = math.min(max.y + max.h - f.y, f.h + resizeStep)
  win:setFrame(f)
end)

-- shrink on bottom
bindResizeWindow("bottomBorderShrink", "Bottom Border Shrinks",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()

  f.h = math.max(resizeStep, f.h - resizeStep)
  win:setFrame(f)
end)

-- move to top-left
bindMoveWindow("moveToTopLeft", "Move to Top-Left",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)

  f.x = max.x
  f.y = max.y
  win:setFrame(f)
end)

-- move to top
bindMoveWindow("moveToTop", "Move to Top",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local screen = win:screen()
  local max = screen:frame()

  f.y = max.y
  win:setFrame(f)
end)

-- move to top-right
bindMoveWindow("moveToTopRight", "Move to Top-Right",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)

  f.x = max.x + max.w - f.w
  f.y = max.y
  win:setFrame(f)
end)

-- move to left
bindMoveWindow("moveToLeft", "Move to Left",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)

  f.x = max.x
  win:setFrame(f)
end)

-- move to center
local centerHK = bindMoveWindow("moveToCenter", "Move to Center",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)

  -- make the bahavior consistent with the system "Center" shortcut
  f.x = max.x + math.ceil((max.w - f.w) / 2)
  f.y = max.y + math.ceil((max.h - f.h + 1) / 2)
  win:setFrame(f)
end)
if centerHK then centerHK.subkind = 0 end

-- move to right
bindMoveWindow("moveToRight", "Move to Right",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)

  f.x = max.x + max.w - f.w
  win:setFrame(f)
end)

-- move to bottom-left
bindMoveWindow("moveToBottomLeft", "Move to Bottom-Left",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)

  f.x = max.x
  f.y = max.y + max.h - f.h
  win:setFrame(f)
end)

-- move to bottom
bindMoveWindow("moveToBottom", "Move to Bottom",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local screen = win:screen()
  local max = screen:frame()

  f.y = max.y + max.h - f.h
  win:setFrame(f)
end)

-- move to bottom-right
bindMoveWindow("moveToBottomRight", "Move to Bottom-Right",
function()
  local win = hs.window.focusedWindow()
  if win == nil then return end
  local f = win:frame()
  local max = getScreenFrame(win)

  f.x = max.x + max.w - f.w
  f.y = max.y + max.h - f.h
  win:setFrame(f)
end)

-- window-based switcher like Windows
local misc = winHK

local function newWindowSwitch(...)
  local hotkey = newHotkeySpec(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.SWITCH
  return hotkey
end

local function bindWindowSwitch(...)
  local hotkey = bindHotkeySpec(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.SWITCH
  return hotkey
end

local function runningAppDisplayNames(bundleIDs)
  local appnames = {}
  for _, bundleID in ipairs(bundleIDs) do
    local app = find(bundleID)
    if app ~= nil then
      table.insert(appnames, app:name())
    end
  end
  return appnames
end

-- visible windows on all user spaces (wallpaper apps excluded)
-- fixme: full screen space will be ignored if not once focused
local ignoredApps
do
  local ignoredAppsLoaded = ApplicationConfigs["windowSwitcherIgnore"] or {}
  ignoredApps = tfind(ignoredAppsLoaded,
      function(item) return type(item) == 'table' end)
  if ignoredApps then
    ignoredApps = tcopy(ignoredApps)
  else
    ignoredApps = {}
  end
  for _, appid in ipairs(ignoredAppsLoaded) do
    if type(appid) == 'string' then
      ignoredApps[appid] = false
    end
  end
end

local switcher

local hotkeyEnabledByWindowSwitcher = false
local function enabledByWindowSwitcherFunc()
  return hotkeyEnabledByWindowSwitcher
end

local windowSwitcherWindowIdx = nil
local windowSwitcherWindowNumber = nil
local nextWindowHotkey, lastWindowHotkey
local anotherLastWindowHotkey
local anotherLastWindowModifierTap

local function registerWindowSwitcher()
  anotherLastWindowHotkey =
  newWindowSwitch(misc["switchWindowBackTriggered"], 'Previous Window',
  function()
    if windowSwitcherWindowNumber > 0 then
      windowSwitcherWindowIdx = windowSwitcherWindowIdx - 1
      if windowSwitcherWindowIdx == 0 then
        windowSwitcherWindowIdx = windowSwitcherWindowNumber
      end
    end
    switcher:previous()
  end, nil,
  function()
    if windowSwitcherWindowIdx > 1 then
      windowSwitcherWindowIdx = windowSwitcherWindowIdx - 1
      switcher:previous()
    end
  end,
  { fn = enabledByWindowSwitcherFunc, or_ = true })

  local _lastWindowMods = misc["switchWindow"].mods
  if type(_lastWindowMods) == 'string' then
    _lastWindowMods = { _lastWindowMods }
  end
  local lastWindowMods = {}
  for _, mod in ipairs(_lastWindowMods) do
    if mod == Mod.Cmd.Long then
      tinsert(lastWindowMods, Mod.Cmd.Short)
    elseif mod == Mod.Alt.Long then
      tinsert(lastWindowMods, Mod.Alt.Short)
    elseif mod == Mod.Ctrl.Long then
      tinsert(lastWindowMods, Mod.Ctrl.Short)
    elseif mod == Mod.Shift.Long then
      tinsert(lastWindowMods, Mod.Shift.Short)
    end
  end

  anotherLastWindowModifierTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged },
  function(event)
    local flags = event:getFlags()
    if not flags:contain(lastWindowMods) then
      hotkeyEnabledByWindowSwitcher = false
      FLAGS["SUSPEND"] = false
      if anotherLastWindowHotkey ~= nil then
        anotherLastWindowHotkey:disable()
      end
      anotherLastWindowModifierTap:stop()
      switcher = nil
      windowSwitcherWindowIdx = nil
      windowSwitcherWindowNumber = nil
    end
    return false
  end)

  nextWindowHotkey = bindWindowSwitch(misc["switchWindow"], 'Next Window',
  function()
    if not anotherLastWindowModifierTap:isEnabled() then
      hotkeyEnabledByWindowSwitcher = true
      FLAGS["SUSPEND"] = true
      if anotherLastWindowHotkey ~= nil then
        anotherLastWindowHotkey:enable()
      end
      anotherLastWindowModifierTap:start()
    end
    if switcher == nil then
      local filter = hs.window.filter.new()
        for appid, rule in pairs(ignoredApps) do
        if find(appid) then
          filter:setAppFilter(find(appid):name(), rule)
        end
      end
      switcher = hs.window.switcher.new(filter)
    end
    switcher:next()
    if windowSwitcherWindowIdx == nil then
      windowSwitcherWindowNumber = 0
      for _, _ in pairs(switcher.wf.windows) do
        windowSwitcherWindowNumber = windowSwitcherWindowNumber + 1
      end
      if windowSwitcherWindowNumber > 1 then
        windowSwitcherWindowIdx = 2
      else
        windowSwitcherWindowIdx = windowSwitcherWindowNumber
      end
    else
      windowSwitcherWindowIdx = windowSwitcherWindowIdx + 1
      if windowSwitcherWindowIdx > windowSwitcherWindowNumber then
        windowSwitcherWindowIdx = 1
      end
    end
  end,
  nil,
  function()
    if windowSwitcherWindowIdx ~= windowSwitcherWindowNumber then
      windowSwitcherWindowIdx = windowSwitcherWindowIdx + 1
      switcher:next()
    end
  end,
  { fn = enabledByWindowSwitcherFunc, or_ = true })

  lastWindowHotkey = bindWindowSwitch(misc["switchWindowBack"], 'Previous Window',
  function()
    if not anotherLastWindowModifierTap:isEnabled() then
      hotkeyEnabledByWindowSwitcher = true
      FLAGS["SUSPEND"] = true
      if anotherLastWindowHotkey ~= nil then
        anotherLastWindowHotkey:enable()
      end
      anotherLastWindowModifierTap:start()
    end
    if switcher == nil then
      local filter = hs.window.filter.new()
      for appid, rule in pairs(ignoredApps) do
        if find(appid) then
          filter:setAppFilter(find(appid):name(), rule)
        end
      end
      switcher = hs.window.switcher.new(filter)
    end
    switcher:previous()
    if windowSwitcherWindowIdx == nil then
      windowSwitcherWindowNumber = 0
      for _, _ in pairs(switcher.wf.windows) do
        windowSwitcherWindowNumber = windowSwitcherWindowNumber + 1
      end
      windowSwitcherWindowIdx = windowSwitcherWindowNumber
    else
      if windowSwitcherWindowNumber > 1 then
        windowSwitcherWindowIdx = windowSwitcherWindowIdx - 1
        if windowSwitcherWindowIdx == 0 then
          windowSwitcherWindowIdx = windowSwitcherWindowNumber
        end
      end
    end
  end,
  nil,
  function()
    if windowSwitcherWindowIdx > 1 then
      windowSwitcherWindowIdx = windowSwitcherWindowIdx - 1
      switcher:previous()
    end
  end,
  { fn = enabledByWindowSwitcherFunc, or_ = true })
end

local function unregisterWindowSwitcher()
  if nextWindowHotkey ~= nil then
    nextWindowHotkey:delete()
    nextWindowHotkey = nil
  end
  if lastWindowHotkey ~= nil then
    lastWindowHotkey:delete()
    lastWindowHotkey = nil
  end
  if anotherLastWindowHotkey ~= nil then
    anotherLastWindowHotkey:delete()
    anotherLastWindowHotkey = nil
  end
  windowSwitcherWindowIdx = nil
  windowSwitcherWindowNumber = nil
  switcher = nil
  if anotherLastWindowModifierTap ~= nil then
    anotherLastWindowModifierTap:stop()
    anotherLastWindowModifierTap = nil
  end
end

if misc["switchWindow"] ~= nil then
  local altTabBundleID = "com.lwouis.alt-tab-macos"
  if find(altTabBundleID) == nil then
    registerWindowSwitcher()
  end
  ExecOnSilentLaunch(altTabBundleID, function()
    unregisterWindowSwitcher()
    ExecOnSilentQuit(altTabBundleID, registerWindowSwitcher)
  end)
end

-- visible windows of all browsers on all user spaces
-- fixme: full screen space will be ignored if not once focused
local browserBundleIDs = {
  "com.apple.Safari",
  "com.google.Chrome",
  "com.microsoft.edgemac",
  "com.microsoft.edgemac.Dev",
}
local switcher_browsers

local anotherLastBrowserHotkey
local anotherLastBrowserModifierTap

if misc["switchBrowserWindow"] ~= nil then
  anotherLastBrowserHotkey =
  newWindowSwitch(misc["switchBrowserWindowBackTriggered"], 'Previous Browser Window',
  function()
    if windowSwitcherWindowNumber > 0 then
      windowSwitcherWindowIdx = windowSwitcherWindowIdx - 1
      if windowSwitcherWindowIdx == 0 then
        windowSwitcherWindowIdx = windowSwitcherWindowNumber
      end
    end
    switcher_browsers:previous()
  end, nil,
  function()
    if windowSwitcherWindowIdx > 1 then
      windowSwitcherWindowIdx = windowSwitcherWindowIdx - 1
      switcher_browsers:previous()
    end
  end,
  { fn = enabledByWindowSwitcherFunc, or_ = true })

  local _lastBrowserWindowMods = misc["switchBrowserWindow"].mods
  if type(_lastBrowserWindowMods) == 'string' then
    _lastBrowserWindowMods = { _lastBrowserWindowMods }
  end
  local lastBrowserWindowMods = {}
  for _, mod in ipairs(_lastBrowserWindowMods) do
    if mod == Mod.Cmd.Long then
      tinsert(lastBrowserWindowMods, Mod.Cmd.Short)
    elseif mod == Mod.Alt.Long then
      tinsert(lastBrowserWindowMods, Mod.Alt.Short)
    elseif mod == Mod.Ctrl.Long then
      tinsert(lastBrowserWindowMods, Mod.Ctrl.Short)
    elseif mod == Mod.Shift.Long then
      tinsert(lastBrowserWindowMods, Mod.Shift.Short)
    end
  end

  anotherLastBrowserModifierTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged },
  function(event)
    local flags = event:getFlags()
    if not flags:contain(lastBrowserWindowMods) then
      hotkeyEnabledByWindowSwitcher = false
      FLAGS["SUSPEND"] = false
      if anotherLastBrowserHotkey ~= nil then
        anotherLastBrowserHotkey:disable()
      end
      anotherLastBrowserModifierTap:stop()
      switcher_browsers = nil
      windowSwitcherWindowIdx = nil
      windowSwitcherWindowNumber = nil
    end
    return false
  end)

  bindWindowSwitch(misc["switchBrowserWindow"], 'Next Browser Window',
  function()
    if not anotherLastBrowserModifierTap:isEnabled() then
      hotkeyEnabledByWindowSwitcher = true
      FLAGS["SUSPEND"] = true
      if anotherLastBrowserHotkey ~= nil then
        anotherLastBrowserHotkey:enable()
      end
      anotherLastBrowserModifierTap:start()
    end
    if switcher_browsers == nil then
      switcher_browsers = hs.window.switcher.new(runningAppDisplayNames(browserBundleIDs))
    end
    switcher_browsers:next()
    if windowSwitcherWindowIdx == nil then
      windowSwitcherWindowNumber = 0
      for _, _ in pairs(switcher_browsers.wf.windows) do
        windowSwitcherWindowNumber = windowSwitcherWindowNumber + 1
      end
      if windowSwitcherWindowNumber > 1 then
        windowSwitcherWindowIdx = 2
      else
        windowSwitcherWindowIdx = windowSwitcherWindowNumber
      end
    else
      if windowSwitcherWindowNumber > 1 then
        windowSwitcherWindowIdx = windowSwitcherWindowIdx + 1
        if windowSwitcherWindowIdx > windowSwitcherWindowNumber then
          windowSwitcherWindowIdx = 1
        end
      end
    end
  end,
  nil,
  function()
    if windowSwitcherWindowIdx ~= windowSwitcherWindowNumber then
      windowSwitcherWindowIdx = windowSwitcherWindowIdx + 1
      switcher_browsers:next()
    end
  end,
  { fn = enabledByWindowSwitcherFunc, or_ = true })

  bindWindowSwitch(misc["switchBrowserWindowBack"], 'Previous Browser Window',
  function()
    if not anotherLastBrowserModifierTap:isEnabled() then
      hotkeyEnabledByWindowSwitcher = true
      FLAGS["SUSPEND"] = true
      if anotherLastBrowserHotkey ~= nil then
        anotherLastBrowserHotkey:enable()
      end
      anotherLastBrowserModifierTap:start()
    end
    if switcher_browsers == nil then
      switcher_browsers = hs.window.switcher.new(runningAppDisplayNames(browserBundleIDs))
    end
    switcher_browsers:previous()
    if windowSwitcherWindowIdx == nil then
      windowSwitcherWindowNumber = 0
      for _, _ in pairs(switcher_browsers.wf.windows) do
        windowSwitcherWindowNumber = windowSwitcherWindowNumber + 1
      end
      windowSwitcherWindowIdx = windowSwitcherWindowNumber
    else
      if windowSwitcherWindowNumber > 0 then
        windowSwitcherWindowIdx = windowSwitcherWindowIdx - 1
        if windowSwitcherWindowIdx == 0 then
          windowSwitcherWindowIdx = windowSwitcherWindowNumber
        end
      end
    end
  end,
  nil,
  function()
    if windowSwitcherWindowIdx > 1 then
      windowSwitcherWindowIdx = windowSwitcherWindowIdx - 1
      switcher_browsers:previous()
    end
  end,
  { fn = enabledByWindowSwitcherFunc, or_ = true })
end

-- show a dialog to specify a window title from all visible windows, use it to switch to a window
-- fixme: full screen space will be ignored if not once focused
bindWindowSwitch(misc["searchWindow"], 'Switch to Window',
function()
  local wFilter = hs.window.filter.new()
  for appid, rule in pairs(ignoredApps) do
    if find(appid) then
      wFilter:setAppFilter(find(appid):name(), rule)
    end
  end
  local allWindows = wFilter:getWindows()
  local choices = {}
  for _, window in ipairs(allWindows) do
    tinsert(choices,
        {
          text = window:title(),
          subText = window:application():name(),
          image = window:snapshot(),
          window = window
        })
  end

  if #choices == 0 then
    hs.alert.show("NO VALID WINDOWS")
    return
  end

  local chooser = hs.chooser.new(function(choice)
    if not choice then return end
    choice.window:focus()
  end)
  chooser:searchSubText(true)
  chooser:choices(choices)
  chooser:show()
end)

require 'utils'

local function browserChooser()
  local choices = {}
  -- get URLs and titles of all tabs of all browsers
  for _, browser in ipairs(browserBundleIDs) do
    local app = find(browser)
    if app ~= nil then
      local field, tabIDCmd
      if browser == "com.apple.Safari" then
        field = 'name'
        tabIDCmd = 'set theID to j'
      else
        field = 'title'
        tabIDCmd = 'set theID to id of atab'
      end
      local script = [[
        set theResult to ""
        tell application id "]] .. browser .. [["
          set windowList to every window
          repeat with aWindow in windowList
            set theWinID to ID of aWindow
            set tabList to every tab of aWindow
            repeat with j from 1 to count tabList
              set atab to item j of tabList
              ]] .. tabIDCmd .. [[ 
              set theUrl to URL of atab
              set theTitle to ]] .. field .. [[ of atab
              set theResult to theResult & theWinID & "|||" & theID & "|||" & theUrl & "|||" & theTitle & "|||"
            end repeat
          end repeat
        end tell
        return theResult
      ]]
      local ok, result = hs.osascript.applescript(script)
      -- parse the result and add them to choices
      if ok then
        for winID, id, url, title in result:gmatch("(.-)%|%|%|(.-)%|%|%|(.-)%|%|%|(.-)%|%|%|") do
          tinsert(choices,
              {
                text = title,
                subText = url,
                image = hs.image.imageFromAppBundle(app:bundleID()),
                id = id,
                winID = winID,
                browser = browser
              })
        end
      elseif browser == "com.apple.Safari" then
        hs.alert.show("ERROR for Safari. RESTARTING Safari may solve it")
      end
    end
  end

  if #choices == 0 then
    hs.alert.show("NO VALID TABS")
    return
  end

  local chooser = hs.chooser.new(function(choice)
    if not choice then return end
    local findTabCmd, focusTabCmd, titleField
    if choice.browser == "com.apple.Safari" then
      findTabCmd = 'j is ' .. choice.id
      focusTabCmd = [[
        tell aWindow to set current tab to tab j
      ]]
      titleField = 'name'
    else
      findTabCmd = [[
        (id of item j of tabList is "]] .. tostring(choice.id) .. [[") or ¬
        (id of item j of tabList is ]] .. choice.id .. [[)]]
      focusTabCmd = [[
        tell aWindow to set active tab index to j
      ]]
      titleField = 'title'
    end

    local script = [[
      tell application id "]] .. choice.browser .. [["
        set aWindow to window id ]] .. choice.winID .. [[

        set tabList to every tab of aWindow
        repeat with j from 1 to count of tabList
          if ]] .. findTabCmd .. [[ then
            ]] .. focusTabCmd .. [[
            return ]] .. titleField .. [[ of aWindow
          end if
        end repeat
      end tell
    ]]
    local ok, result = hs.osascript.applescript(script)

    if not ok then return end
    local app = find(choice.browser)
    app:activate()
    local windowMenuItem = localizedMenuBarItem('Window', app:bundleID())
    if windowMenuItem == nil then return end
    hs.timer.doAfter(0.1, function()
      if menuBarVisible() then
        app:selectMenuItem({ windowMenuItem, result })
      else
        hs.eventtap.keyStroke('fn⌃', 'F2')
        app:selectMenuItem({ windowMenuItem, result })
      end
    end)
  end)
  chooser:searchSubText(true)
  chooser:choices(choices)
  chooser:show()
end

local function PDFChooser()
  local choices = {}

  -- `PDF Expert`
  local allWindowsPDFExpert, winTabTitlesPDFExpert
  if find("com.readdle.PDFExpert-Mac") ~= nil then
    local app = find("com.readdle.PDFExpert-Mac")
    local allWindows = hs.window.filter.new(false):allowApp(app:name()):getWindows()
    local winTabTitles = {}
    local winTitles = {}
    local winPaths = {}
    for _, win in ipairs(allWindows) do
      local winUI = towinui(win)
      local filePath = ""
      if #getc(winUI, AX.Unknown) ~= 0 then
        local winIdent = getc(winUI, AX.Unknown, 1).AXIdentifier
        filePath = winIdent:match("PDFTabContentView (.*%.pdf)$")
      end
      local toolbar = nil
      if win:isFullScreen() then
        toolbar = getc(winUI, AX.Group, 1, AX.Toolbar, 1)
      else
        toolbar = getc(winUI, AX.Toolbar, 1)
      end
      local tabList = getc(
          toolbar, AX.Group, 1, AX.TabGroup, 1, AX.ScrollArea, 1, AX.Group)
      local tabTitles = {}
      for _, tab in ipairs(tabList) do
        tinsert(tabTitles, tab.AXHelp)
      end
      tinsert(winTitles, win:title())
      tinsert(winPaths, filePath)
      tinsert(winTabTitles, tabTitles)
    end
    for winID, winTitle in ipairs(winTitles) do
      local tabTitles = winTabTitles[winID]
      for tabID, tabTitle in ipairs(tabTitles) do
        local choice =
            {
              text = tabTitle,
              image = hs.image.imageFromAppBundle(app:bundleID()),
              id = tabID,
              winID = winID,
              app = app:bundleID()
            }
        if winTitle == tabTitle then
          choice.subText = winPaths[winID]
        else
          choice.subText = 'INACTIVE in WINDOW: "' .. winTitle .. '"'
        end
        tinsert(choices, choice)
      end
    end
    allWindowsPDFExpert = allWindows
    winTabTitlesPDFExpert = winTabTitles
  end

  -- `UPDF`
  local allWindowsUPDF
  if find("com.superace.updf.mac") ~= nil then
    local app = find("com.superace.updf.mac")
    local allWindows = hs.window.filter.new(false):allowApp(app:name()):getWindows()
    local winTabTitles = {}
    local title = localizedMenuBarItem('Tab', app:bundleID())
    local menuBarItem = getc(toappui(app), AX.MenuBar, 1, AX.MenuBarItem, title)
    if menuBarItem then
      local subMenuItems = menuBarItem.AXChildren[1]
      local winTitles = {}
      local tabTitles = {}
      if #subMenuItems < 5 then
        menuBarItem:performAction(AX.Press)
        menuBarItem:performAction(AX.Cancel)
      end
      for i=5,#subMenuItems do
        local subMenuItem = subMenuItems[i]
        if subMenuItem.AXEnabled and subMenuItem.AXTitle ~= "" then
          tinsert(tabTitles, subMenuItem.AXTitle)
          if subMenuItem.AXMenuItemMarkChar == "✓" then
            tinsert(winTitles, subMenuItem.AXTitle)
          end
        elseif #tabTitles > 0 then
          tinsert(winTabTitles, tabTitles)
          tabTitles = {}
        end
      end
      if #tabTitles > 0 then
        tinsert(winTabTitles, tabTitles)
      end
      for i, winTitle in ipairs(winTitles) do
        tabTitles = winTabTitles[i]
        for _, tabTitle in ipairs(tabTitles) do
          local choice =
              {
                text = tabTitle,
                image = hs.image.imageFromAppBundle(app:bundleID()),
                winTitle = winTitle,
                app = app:bundleID()
              }
          if winTitle ~= tabTitle then
            choice.subText = 'INACTIVE in WINDOW: "' .. winTitle .. '"'
          end
          tinsert(choices, choice)
        end
      end
    end
    allWindowsUPDF = allWindows
  end

  -- `Preview`
  if find("com.apple.Preview") ~= nil then
    local app = find("com.apple.Preview")
    local ok, results = hs.osascript.applescript([[
      tell application id "]] .. app:bundleID() .. [[" to get {id, name} of (every window whose name ends with ".pdf")
    ]])
    if ok and #results[1] > 0 then
      for i=1,#results[1] do
        tinsert(choices,
            {
              text = results[2][i],
              image = hs.image.imageFromAppBundle(app:bundleID()),
              id = results[1][i],
              app = app:bundleID()
            })
      end
    end
  end

  -- browsers
  for _, browser in ipairs({"com.apple.Safari", "com.google.Chrome",
                            "com.microsoft.edgemac", "com.microsoft.edgemac.Dev"}) do
    local app = find(browser)
    if app ~= nil then
      local field, tabIDCmd
      if browser == "com.apple.Safari" then
        field = 'name'
        tabIDCmd = 'set theID to j\n'
      else
        field = 'title'
        tabIDCmd = 'set theID to id of atab\n'
      end
      local script = [[
        set theResult to ""
        tell application id "]] .. browser .. [["
          set windowList to every window
          repeat with aWindow in windowList
            set theWinID to ID of aWindow
            set tabList to every tab of aWindow
            repeat with j from 1 to count tabList
              set atab to item j of tabList
              set theUrl to URL of atab
              if theUrl ends with ".pdf" then
                ]] .. tabIDCmd .. [[
                set theTitle to ]] .. field .. [[ of atab
                set theResult to theResult & theWinID & "|||" & theID & "|||" & theUrl & "|||" & theTitle & "|||"
              end if
            end repeat
          end repeat
        end tell
        return theResult
      ]]
      local ok, result = hs.osascript.applescript(script)
      -- parse the result and add them to choices
      if ok then
        for winID, id, url, title in result:gmatch("(.-)%|%|%|(.-)%|%|%|(.-)%|%|%|(.-)%|%|%|") do
          tinsert(choices,
              {
                text = title,
                subText = url,
                image = hs.image.imageFromAppBundle(browser),
                id = id,
                winID = winID,
                app = browser
              })
        end
      end
    end
  end

  if #choices == 0 then
    hs.alert.show("NO VALID TABS")
    return
  end

  local chooser = hs.chooser.new(function(choice)
    if not choice then return end
    if choice.app == "com.readdle.PDFExpert-Mac" then
      allWindowsPDFExpert[choice.winID]:focus()
      if not tcontain(hs.spaces.activeSpaces(),
          hs.spaces.windowSpaces(allWindowsPDFExpert[choice.winID])[1]) then
        hs.timer.usleep(0.5 * 1000000)
      end
      if allWindowsPDFExpert[choice.winID]:title() ~= winTabTitlesPDFExpert[choice.winID][choice.id] then
        local app = find(choice.app)
        local isFullScreen = allWindowsPDFExpert[choice.winID]:isFullScreen()
        if not isFullScreen or findMenuItem(app, { 'View', 'Always Show Toolbar' }).ticked then
          local winUI = towinui(app:focusedWindow())
          if isFullScreen then
            winUI = getc(winUI, AX.Group, 1)
          end
          local aTab = getc(winUI, AX.Toolbar, 1, AX.Group, 1,
              AX.TabGroup, 1, AX.ScrollArea, 1, nil, choice.id)
          if aTab ~= nil then
            if leftClickAndRestore(uioffset(aTab, { 10, 0 }), app) then
              return
            end
          end
        end
        local activeIdx = tindex(winTabTitlesPDFExpert[choice.winID],
            allWindowsPDFExpert[choice.winID]:title()) or 0
        if activeIdx < choice.id then
          local _, menuItemPath = findMenuItem(app, { "Window", "Go to Next Tab" })
          for _=1,choice.id-activeIdx do
            app:selectMenuItem(menuItemPath)
          end
        else
          local _, menuItemPath = findMenuItem(app, { "Window", "Go to Previous Tab" })
          for _=1,activeIdx-choice.id do
            app:selectMenuItem(menuItemPath)
          end
        end
      end
    elseif choice.app == "com.superace.updf.mac" then
      local app = find(choice.app)
      local title = localizedMenuBarItem('Tab', app:bundleID())
      local menuBarItem = getc(toappui(app), AX.MenuBar, 1, AX.MenuBarItem, title)
      for _, window in ipairs(allWindowsUPDF) do
        if window:title() == choice.winTitle then
          window:focus()
          if window:isFullScreen() then
            hs.timer.usleep(1000000)
          end
          if choice.winTitle ~= choice.text then
            if #menuBarItem.AXChildren[1] < 5 then
              menuBarItem:performAction(AX.Press)
              menuBarItem:performAction(AX.Cancel)
            end
            app:selectMenuItem({ title, choice.text })
          end
          return
        end
      end
      app:activate()
      hs.timer.doAfter(0.1, function()
        if choice.winTitle ~= choice.text then
          if #menuBarItem.AXChildren[1] < 5 then
            menuBarItem:performAction(AX.Press)
            menuBarItem:performAction(AX.Cancel)
          end
          app:selectMenuItem({ title, choice.text })
        end
      end)
    elseif choice.app == "com.apple.Preview" then
      hs.osascript.applescript([[
        tell application id "]] .. choice.app .. [["
          activate
          set aWindow to window id ]] .. choice.id .. [[ 
          set index of aWindow to 1
        end tell
      ]])
    else
      local findTabCmd, focusTabCmd, titleField
      if choice.app == "com.apple.Safari" then
        findTabCmd = 'j is ' .. choice.id
        focusTabCmd = [[
          tell aWindow to set current tab to tab j
        ]]
        titleField = 'name'
      else
        findTabCmd = [[
          (id of item j of tabList is "]] .. tostring(choice.id) .. [[") or ¬
          (id of item j of tabList is ]] .. choice.id .. [[)]]
        focusTabCmd = [[
          tell aWindow to set active tab index to j
        ]]
        titleField = 'title'
      end
      local script = [[
        tell application id "]] .. choice.app .. [["
          set aWindow to window id ]] .. choice.winID .. [[ 
          set tabList to every tab of aWindow
          repeat with j from 1 to count of tabList
            if ]] .. findTabCmd .. [[ then
              ]] .. focusTabCmd .. [[
              return ]] .. titleField .. [[ of aWindow
            end if
          end repeat
        end tell
      ]]
      local ok, result = hs.osascript.applescript(script)

      if not ok then return end
      local app = find(choice.app)
      app:activate()
      local windowMenuItem = localizedMenuBarItem('Window', app:bundleID())
      if windowMenuItem == nil then return end
      hs.timer.doAfter(0.1, function()
        if menuBarVisible() then
          app:selectMenuItem({ windowMenuItem, result })
        else
          hs.eventtap.keyStroke('fn⌃', 'F2')
          app:selectMenuItem({ windowMenuItem, result })
        end
      end)
    end
  end)
  chooser:choices(choices)
  chooser:show()
end

-- show a dialog to specify a tab title from all windows of browsers or `PDF Expert`
-- use it to switch to a tab
bindWindowSwitch(misc["searchTab"], 'Switch to Tab',
function()
  local app = hs.application.frontmostApplication()
  local appid = app:bundleID()

  if tcontain({ "com.readdle.PDFExpert-Mac", "com.superace.updf.mac" }, appid) then
    PDFChooser()
    return
  end
  if appid == "com.apple.Preview" and app:mainWindow() ~= nil then
    local doc = towinui(app:mainWindow()).AXDocument
    if doc and doc:sub(-4) == '.pdf' then
      PDFChooser()
      return
    end
  end

  browserChooser()
end)

-- window switcher for `Stage Manager`
local function bindStageManagerWindow(spec, index)
  local fn = function()
    local manager = find("com.apple.WindowManager")
    if manager then
      local frame = hs.screen.mainScreen():frame()
      local groups = getc(toappui(manager), AX.Group)
      local g = tfind(groups or {}, function(g)
        return g.AXPosition.x == frame.x
      end)
      if g then
        local button = getc(g, AX.List, 1, AX.Button, index)
        if button then button:performAction(AX.Press) end
      end
    end
  end
  local locApp = localizedString("Stage Manager", "com.apple.controlcenter",
                                 { localeFile = "StageManager",
                                   locale = applicationLocale("com.apple.WindowManager") })
  local locWindow = localizedString("Window", "com.apple.WindowManager")
  local hotkey = bindHotkeySpec(spec, locApp..' > '..locWindow..' '..index, fn)
  hotkey.kind = HK.WIN_OP
  return hotkey
end

for i=1,10 do
  local hkID = "focusStageManagerWindow"..tostring(i)
  if winHK[hkID] then
    bindStageManagerWindow(winHK[hkID], i)
  end
end

local stageManagerWindowSwitchFuncs = {}
local function bindURLEventForStageManager()
  hs.urlevent.bind("stagemanager", function(eventName, params)
    if params["index"] then
      local index = tonumber(params["index"])
      local fn = stageManagerWindowSwitchFuncs[index]
      if fn then fn() end
    end
  end)
end

local function bindStageManagerWindowURL(index)
  local fn = function()
    local manager = find("com.apple.WindowManager")
    if manager then
      local frame = hs.screen.mainScreen():frame()
      local groups = getc(toappui(manager), AX.Group)
      local g = tfind(groups or {}, function(g)
        return g.AXPosition.x == frame.x
      end)
      if g then
        local button = getc(g, AX.List, 1, AX.Button, index)
        if button then button:performAction(AX.Press) end
      end
    end
  end
  stageManagerWindowSwitchFuncs[index] = fn
  local locApp = localizedString("Stage Manager", "com.apple.controlcenter",
                                 { localeFile = "StageManager",
                                   locale = applicationLocale("com.apple.WindowManager") })
  local locWindow = localizedString("Window", "com.apple.WindowManager")
  registerURLHotkeyMessage("stagemanager", "index", tostring(index),
                           locApp..' > '..locWindow..' '..index)
end
