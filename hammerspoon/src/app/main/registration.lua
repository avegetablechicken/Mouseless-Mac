LoadBuf.allowedMenuBarApps = nil
LoadBuf.menubarObserverStarted = {}
LoadBuf.menubarSelectedObserverStarted = {}
LoadBuf.daemonAppFocusedWindowFilters = {}

local runningApplications = LoadBuf.runningApplications

-- Register AppKeys
registerAppKeys()

-- register hotekys & watchers for hotkeys

local frontApp = hs.application.frontmostApplication()
local frontWin = hs.window.frontmostWindow()

-- register hotkeys for background apps
for appid, appConfig in pairs(AppHotKeyCallbacks) do
  registerRunningAppHotKeys(appid)
  local hasNotPersistentBackgroundHotkey = any(appConfig, function(cfg, hkID)
    local keybinding = getKeybinding(appid, hkID)
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isBackground = keybinding.background ~= nil
        and keybinding.background or cfg.background
    local isPersistent = keybinding.persist ~= nil
        and keybinding.persist or cfg.persist
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    return hasKey and not isForWindow and isBackground and not isPersistent
  end)
  if hasNotPersistentBackgroundHotkey then
    Evt.OnLaunched(appid, bind(registerRunningAppHotKeys, appid))
  end
end

-- register hotkeys for active app
LAZY_REGISTER_MENUBAR_OBSERVER = false
if not LAZY_REGISTER_MENUBAR_OBSERVER then
  local appMenuBarItems = tmap(runningApplications, function(app)
    return registerMenuBarObserverForHotkeyValidity(app)
  end)
  local focusedApp = hs.axuielement.systemWideElement().AXFocusedApplication
  if focusedApp then
    FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] = false
  else
    FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] = any(appMenuBarItems, function(items)
      return any(items, function(item) return item.AXSelected end)
    end)
  end
end

---@diagnostic disable-next-line: lowercase-global
function onLaunchedAndActivated(app, menuBarChanged)
  local menuBarItems = getBufferedMenuBarItems(app)
  if menuBarChanged then
    unregisterInAppHotKeys(app, true)
    HotkeyRegistry.clearWindowHotkeys(app, true)
    local appid = app:bundleID() or app:name()
---@diagnostic disable-next-line: undefined-global
    ActivatedAppConditionChain[appid] = nil
  end
  if type(menuBarChanged) == 'string' then
    altMenuBarItem(app, nil, menuBarChanged)
  else
    altMenuBarItem(app)
  end
  registerInAppHotKeys(app)
  registerWinFiltersForApp(app)
  remapPreviousTab(app)
  registerOpenRecent(app)
  registerZoomHotkeys(app)
  registerResizeHotkeys(app)
  registerObserverForSettingsMenuItem(app)

  return menuBarItems ~= nil
end
if frontApp then
  local appid = frontApp:bundleID() or frontApp:name()
  A_AppLocale = applicationLocale(appid)
  registerForOpenSavePanel(frontApp)
  onLaunchedAndActivated(frontApp)
end

-- register watchers for window belonging to daemon app
for appid, appConfig in pairs(AppHotKeyCallbacks) do
  local hasDaemonAppWindowHotkey = any(appConfig, function(cfg, hkID)
    local keybinding = getKeybinding(appid, hkID, true)
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local isBackground = keybinding.background ~= nil
        and keybinding.background or cfg.background
    return hasKey and isForWindow and isBackground
  end)
  if hasDaemonAppWindowHotkey then
    Evt.OnRunning(appid, function(app)
      registerWinFiltersForDaemonApp(app, appConfig)
    end)
  end
end

-- register hotkeys for focused window belonging to daemon app
if frontWin ~= nil then
  local frontWinAppID = frontWin:application():bundleID() or frontWin:application():name()
  local frontWinAppFilters = LoadBuf.daemonAppFocusedWindowFilters[frontWinAppID] or {}
  for _, filter in ipairs(frontWinAppFilters) do
    if isWindowAllowed(frontWin, filter) then
      registerDaemonAppInWinHotkeys(frontWin, frontWinAppID, filter)
    end
  end
end

-- register hotkeys for non-frontmost window belonging to daemon app
for appid, _ in pairs(LoadBuf.daemonAppFocusedWindowFilters) do
  local app = runningApplications[appid]
  if app then
    local nonFrontmostFilters = {}
    for hkID, cfg in pairs(AppHotKeyCallbacks[appid]) do
      local keybinding = getKeybinding(appid, hkID, true)
      if keybinding.nonFrontmost or cfg.nonFrontmost then
        local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
        if hasKey then
          tinsert(nonFrontmostFilters, keybinding.windowFilter or cfg.windowFilter)
        end
      end
    end
    for _, filter in ipairs(nonFrontmostFilters) do
      local win = tfind(app:visibleWindows(), function(win)
        local isAllowed = isWindowAllowed(win, filter)
        return isAllowed
      end)
      if win then
        registerDaemonAppInWinHotkeys(win, appid, filter)
      end
    end
  end
end

-- register watchers for menu of menubar app
for appid, appConfig in pairs(AppHotKeyCallbacks) do
  local hasMenuBarMenuHotkey = any(appConfig, function(cfg, hkID)
    local keybinding = getKeybinding(appid, hkID, true)
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isMenuBarMenu = keybinding.menubarFilter ~= nil
        or cfg.menubarFilter ~= nil
    return hasKey and isMenuBarMenu
  end)
  if hasMenuBarMenuHotkey then
    Evt.OnRunning(appid, function(app)
      registerObserversForMenuBarMenu(app, appConfig)
    end)
  end
end

-- register hotkeys for menu of menubar app
for _, appid in ipairs(LoadBuf.menubarObserverStarted) do
  local app = find(appid)  -- "LoadBuf.runningApplications" may lead to null menubar item
  for _, menuBarItem in ipairs(getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)) do
    if menuBarItem.AXSelected then
      registerInMenuHotkeys(app)
      break
    end
  end
end

-- register watchers for preferences menu item in right menu bar menu
for _, appid in ipairs(LoadBuf.menubarSelectedObserverStarted) do
  local app = runningApplications[appid]
  registerObserverForRightMenuBarSettingsMenuItem(app)
end

LoadBuf.allowedMenuBarApps = nil
LoadBuf.menubarObserverStarted = nil
LoadBuf.menubarSelectedObserverStarted = nil
LoadBuf.daemonAppFocusedWindowFilters = nil
