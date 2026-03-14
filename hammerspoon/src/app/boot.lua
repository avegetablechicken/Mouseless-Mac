---@diagnostic disable: lowercase-global

------------------------------------------------------------
-- # AppKeys
-- Application-level hotkeys (launch / focus / hide)
------------------------------------------------------------

-- Launch an application or hide it if already focused
--
-- Behavior:
--  • If the app is not focused, bring it to front (or launch it)
--  • If the app is already focused, hide it
--  • Special handling is applied for Finder due to Desktop windows
function focusOrHide(hint)
  local app = nil

  -- Resolve application hint:
  --  • table: try each entry until one resolves
  --  • string: bundle id or app name
  --  • otherwise: assume hs.application
  if type(hint) == "table" then
    for _, h in ipairs(hint) do
      app = find(h)
      if app ~= nil then break end
    end
  elseif type(hint) == "string" then
    app = find(hint)
  else
    app = hint
  end

  -- Finder special case
  --
  -- Finder always has a "Desktop" window, which breaks the
  -- usual focus-or-hide logic. We explicitly distinguish:
  --  • desktop-only state
  --  • non-desktop Finder windows
  if app ~= nil and app:bundleID() == "com.apple.finder" then
    local appid = app:bundleID()
    local windowFilter = hs.window.filter.new(false):setAppFilter(app:name())
    local windows = windowFilter:getWindows()
    local nonDesktop = tfind(windows, function(win)
      return hs.window.desktop() == nil or win:id() ~= hs.window.desktop():id()
    end) == nil
    if nonDesktop then
      app = hs.application.open(appid)
    elseif hs.window.focusedWindow() ~= nil
        and hs.window.focusedWindow():application() == app then
      if hs.window.focusedWindow():id() == hs.window.desktop():id() then
        hs.application.open(appid)
        hs.window.focusedWindow():focus()
      else
        app:hide()
      end
    else
      if app:focusedWindow() ~= nil then
        app:focusedWindow():focus()
      else
        app:activate()
      end
    end
    return
  end

  if app == nil
    or hs.window.focusedWindow() == nil
    or hs.window.focusedWindow():application() ~= app then
    if type(hint) == "table" then
      for _, h in ipairs(hint) do
        app = hs.application.open(h, 0.5)
        if app ~= nil then break end
      end
    else
      app = hs.application.open(hint)
    end
  else
    app:hide()
  end
end

-- Resolve Parallels VM application bundle path by OS name
--
-- Parallels stores VMs as *.pvm bundles, but the internal
-- app name may not exactly match the requested OS name.
local function getParallelsVMPath(osname)
  local PVMDir = os.getenv("HOME") .. "/Parallels"
  local path = strfmt(PVMDir .. "/%s.pvm/%s.app", osname, osname)
  if exists(path) then return path end

  for filename in hs.fs.dir(PVMDir) do
    if filename:sub(-4) == '.pvm'
        and filename:sub(1, osname:len()) == osname then
      local stem = filename:sub(1, -5)
      path = strfmt(PVMDir .. "/%s.pvm/%s.app", stem, stem)
      if exists(path) then return path end
    end
  end
end

-- Registered application hotkeys
AppKeys = {}

-- Register all application-level hotkeys
--
-- Hotkeys are rebuilt every time this function runs to ensure
-- consistency with current configuration and running apps.
function registerAppKeys()
  for _, hotkey in ipairs(AppKeys) do
    hotkey:delete()
  end
  AppKeys = {}

  for _, config in ipairs(KeybindingConfigs.hotkeys.appkeys or {}) do
    local appPath, appid
    if config.bundleID then
      if type(config.bundleID) == "string" then
        appPath = hs.application.pathForBundleID(config.bundleID)
        if appPath == "" then appPath = nil end
        if appPath ~= nil then appid = config.bundleID end
      elseif type(config.bundleID) == "table" then
        for _, id in ipairs(config.bundleID) do
          appPath = hs.application.pathForBundleID(id)
          if appPath == "" then appPath = nil end
          if appPath ~= nil then
            appid = id
            break
          end
        end
      end
    end
    if appPath == nil and config.vm ~= nil then
      if config.vm == "com.parallels.desktop.console" then
        appPath = getParallelsVMPath(config.name)
        appid = hs.application.infoForBundlePath(appPath).CFBundleIdentifier
        if not installed(appid) then
          appid = nil
        end
      else
        hs.alert("Unsupported Virtual Machine : " .. config.vm)
      end
    end
    if appPath == nil and config.path ~= nil then
      if type(config.path) == "string" then
        appPath = config.path
      else
        for _, path in ipairs(config.path) do
          if exists(path) then
            appPath = path
            break
          end
        end
      end
      appid = hs.application.infoForBundlePath(appPath).CFBundleIdentifier
    end

    -- Register hotkey if application is resolvable
    if appPath ~= nil then
      local appname
      if appid ~= nil then
        if FLAGS["LOADING"] then
          local app = runningAppsOnLoading[appid]
          appname = app and app:name() or displayName(appid)
        else
          appname = displayName(appid)
        end
      else
        appname = hs.execute(strfmt(
          "mdls -name kMDItemDisplayName -raw '%s'", appPath))
        appname = appname:sub(1, -5)
      end
      local hotkey = bindHotkeySpec(config, appname,
          bind(config.fn or focusOrHide, appid or appname))
      hotkey.kind = HK.APPKEY
      if appid then
        hotkey.appid = appid
      else
        hotkey.appPath = appPath
      end
      tinsert(AppKeys, hotkey)
    end
  end
end


------------------------------------------------------------
-- ## function utilities for process management on app switching
--
-- This section provides a unified event-dispatch layer for
-- application lifecycle changes, including:
--  • launch / running
--  • activation / deactivation
--  • termination
--
-- All callbacks registered here are later invoked by the
-- global application watcher defined in init.lua.
-- Individual modules only register intent here; they do NOT
-- directly interact with hs.application.watcher.
------------------------------------------------------------

-- get hs.application from AXUIElement
-- Used when callbacks are triggered from UI observers
function getAppFromDescendantElement(elem)
  local appUI = elem
  repeat
    appUI = appUI.AXParent
  until appUI.AXParent == nil
  return appUI:asHSApplication()
end

-- normalize application identifier
-- Accepts bundleID, hs.application, or AX element
function getAppId(app)
  if type(app) == 'string' then
    return app
  else
    if app.AXParent ~= nil then
      app = getAppFromDescendantElement(app)
    elseif app.application ~= nil then
      app = app:application()
    end
    return app:bundleID() or app:name()
  end
end

-- check whether an app is a background-only LSUIElement
-- such apps do not emit normal launch/terminate events
local LSUIElements = {}
local LSUIElementTmpFile = appsTmpDir .. '/lsuielement.json'
if exists(LSUIElementTmpFile) then
  LSUIElements = hs.json.read(LSUIElementTmpFile)
  for _, appid in ipairs(LSUIElements) do
    ExecOnSilentLaunch(appid, bind(ExecOnSilentQuit, appid, nil))
    if runningAppsOnLoading[appid] then
      ExecOnSilentQuit(appid)
    end
  end
end
function isLSUIElement(appid)
  if tindex(LSUIElements, appid) then return true end
  local info = hs.application.infoForBundleID(appid)
  if info and info.LSUIElement == true then
    tinsert(LSUIElements, appid)
    ExecOnSilentLaunch(appid, bind(ExecOnSilentQuit, appid, nil))
    if find(appid) then
      ExecOnSilentQuit(appid)
    end
    table.sort(LSUIElements)
    if not exists(appsTmpDir) then
      mkdir(appsTmpDir)
    end
    hs.json.write(LSUIElements, LSUIElementTmpFile, false, true)
    return true
  end
  return false
end

------------------------------------------------------------
-- Evt
--
-- Centralized registry for application lifecycle callbacks.
-- Callbacks are grouped by event type and app identifier.
------------------------------------------------------------
Evt = {}

-- callbacks executed when application is launched
Evt.ProcOnLaunched = {}
-- Register a callback to run when an app is launched
-- LSUIElement apps are handled via silent launch polling
Evt.OnLaunched = function(appid, action)
  if isLSUIElement(appid) then
    ExecOnSilentLaunch(appid, action)
    return
  end

  if Evt.ProcOnLaunched[appid] == nil then
    Evt.ProcOnLaunched[appid] = {}
  end
  tinsert(Evt.ProcOnLaunched[appid], action)
end

-- Register a callback that runs immediately if app is already running,
-- otherwise runs when the app is launched
Evt.OnRunning = function(appid, action)
  Evt.OnLaunched(appid, action)
  local app
  if FLAGS["LOADING"] then
    app = runningAppsOnLoading[appid]
  else
    app = find(appid)
  end
  if app then action(app) end
end

-- callbacks executed when application becomes frontmost
Evt.ProcOnActivated = {}
-- Register a callback for app activation
Evt.OnActivated = function(appid, action)
  if Evt.ProcOnActivated[appid] == nil then
    Evt.ProcOnActivated[appid] = {}
  end
  tinsert(Evt.ProcOnActivated[appid], action)
end

-- callbacks executed when application loses focus
Evt.ProcOnDeactivated = {}
-- Register a callback for app deactivation
Evt.OnDeactivated = function(app, action)
  local appid = getAppId(app)
  if Evt.ProcOnDeactivated[appid] == nil then
    Evt.ProcOnDeactivated[appid] = {}
  end
  tinsert(Evt.ProcOnDeactivated[appid], action)
end

-- callbacks executed when application terminates
Evt.ProcOnTerminated = {}
-- Register a callback for app termination
-- LSUIElement apps are handled via silent quit polling
Evt.OnTerminated = function(app, action)
  local appid = getAppId(app)
  if isLSUIElement(appid) then
    ExecOnSilentQuit(appid, action)
    return
  end

  if Evt.ProcOnTerminated[appid] == nil then
    Evt.ProcOnTerminated[appid] = {}
  end
  tinsert(Evt.ProcOnTerminated[appid], action)
end

-- Stop a UI observer when the app is deactivated
Evt.StopOnDeactivated = function(app, observer, action)
  local appid = getAppId(app)
  Evt.OnDeactivated(appid, function()
    observer:stop()
    if action then action(observer, appid) end
    observer = nil
  end)
end

-- Stop a UI observer when the app terminates
Evt.StopOnTerminated = function(app, observer, action)
  local appid = getAppId(app)
  Evt.OnTerminated(appid, function()
    observer:stop()
    if action then action(observer, appid) end
    observer = nil
  end)
end

-- Register a one-shot observer that fires when a UI element is destroyed
-- Optionally stops on app deactivation or termination
Evt.OnDestroy = function(element, callback, stopWhen, callbackOnStop)
  if not element:isValid() then return end
  local app = getAppFromDescendantElement(element)
  local observer = uiobserver.new(app:pid())
  if element.AXRole == AX.Menu then
    observer:addWatcher(element, uinotifications.menuClosed)
  else
    observer:addWatcher(element, uinotifications.uIElementDestroyed)
  end
  observer:callback(function(obs, ...)
    callback(obs, ...) obs:stop() obs = nil
  end)
  observer:start()

  if type(stopWhen) == 'number' then
    stopWhen = { stopWhen }
  end
  for _, ev in ipairs(stopWhen or {}) do
    if ev == hs.application.watcher.deactivated then
      Evt.StopOnDeactivated(app, observer, callbackOnStop and callback)
    elseif ev == hs.application.watcher.terminated then
      Evt.StopOnTerminated(app, observer, callbackOnStop and callback)
    end
  end

  return observer
end

-- A_AppBuf:
-- Application-scoped runtime cache.
--
-- Data in A_AppBuf lives until another application activates
A_AppBuf = {}
A_AppLocale = nil

-- A_WinBuf:
-- Window-scoped runtime cache.
--
-- Data is automatically cleaned up when the window is destroyed.
local WinBuf = {}
WinBuf.__index = WinBuf

function WinBuf.new()
  local o = {}
  setmetatable(o, WinBuf)
  return o
end

function WinBuf:get(...)
  local n = select("#", ...)
  local fn = select(n, ...)
  local keys = {}
  for i = 1, n - 1 do
    keys[i] = select(i, ...)
  end

  local need_compute = false
  for _, k in ipairs(keys) do
    if self[k] == nil then
      need_compute = true
      break
    end
  end
  if need_compute then
    local results = { fn() }

    assert(
      #results == #keys,
      ("A_WinBuf:get key count (%d) != fn return count (%d)")
        :format(#keys, #results)
    )

    for i, k in ipairs(keys) do
      self[k] = results[i]
    end
  end

  local out = {}
  for i, k in ipairs(keys) do
    out[i] = self[k]
  end
  return table.unpack(out)
end

local winBuf = {}
local winCloseObservers = {}

A_WinBuf = {}
A_WinLocale = nil
function A_WinHotkeyWrapper(fn)
  local newFn = A_HotkeyWrapper(fn)
  local validWinBuf, validWinLocale = A_WinBuf, A_WinLocale
  return function(...)
    local lastWinBuf, lastWinLocale = A_WinBuf, A_WinLocale
    A_WinBuf, A_WinLocale = validWinBuf, validWinLocale
    local ret = newFn(...)
    A_WinBuf, A_WinLocale = lastWinBuf, lastWinLocale
    return ret
  end
end

function injectWindowState(fn)
  return function(win)
    local wid = win:id()
    if winBuf[wid] == nil then
      winBuf[wid] = WinBuf.new()
    end
    A_WinBuf = winBuf[wid]
    if win:application():isFrontmost() then
      A_WinBuf.locale = A_AppLocale
    end
    A_WinLocale = A_WinBuf.locale
    local results = table.pack(fn(win))
    A_WinBuf, A_WinLocale = {}, nil
    if winCloseObservers[wid] == nil and next(winBuf[wid]) then
      winCloseObservers[wid] = Evt.OnDestroy(towinui(win), function()
        winBuf[wid] = nil
        winCloseObservers[wid] = nil
      end)
    end
    return table.unpack(results, 1, results.n)
  end
end

function getBufferedMenuBarItems(app)
  if A_AppBuf.menuBarItems == nil then
    A_AppBuf.menuBarItems = getMenuBarItems(app)
  end
  return A_AppBuf.menuBarItems
end

-- A_CommonCallback:
-- Active callback function of current hotkey configuration
A_CommonCallback = nil

------------------------------------------------------------
-- ## localized title generators for hotkey descriptions
--
-- This section provides a family of helper functions (TC / TG / T / TB / TMB)
-- used to dynamically generate human-readable hotkey messages.
--
-- All returned values are either:
--  • a function(app) -> string
--  • or an immediate string when an app context is provided
--
-- These helpers unify:
--  • application-specific localization
--  • menu path resolution
--  • fallback strategies across macOS versions
------------------------------------------------------------

-- Generate a localized title, primarily used for widely shared UI strings.
--
-- It searches for localized strings from system resources
-- (AppKit, system frameworks, or other Apple-provided bundles),
-- instead of relying on application-specific localization files.
--
-- This makes TC suitable for common actions such as:
--   Hide / Quit / Back / Forward / Zoom
-- where consistent system wording is preferred.

local function getBufferedValidLocale(appid)
  local frontApp = hs.application.frontmostApplication()
  if frontApp and frontApp:bundleID() == appid then
    A_AppBuf.validLocale = A_AppBuf.validLocale
        or applicationValidLocale(appid, A_AppBuf.menuBarItems)
    return A_AppBuf.validLocale
  else
    return applicationValidLocale(appid)
  end
end

local commonLocalizedStringsCache = {}
function TC(message, params, params2)
  local fn
  if message == "Hide" or message == "Quit" then
    fn = function(app)
      local appid = getAppId(app)
      local appname
      if appid == app then
        appname = displayName(appid)
      else
        if app.application then app = app:application() end
        appname = app:name()
      end
      local paramsCopy = params and tcopy(params) or {}
      if paramsCopy.locale == nil then
        paramsCopy.locale = getBufferedValidLocale(appid)
      end
      if paramsCopy.locale ~= nil then
        local result = localizedString(message .. ' App Store',
                                       'com.apple.AppStore', paramsCopy)
        if result then
          result = result:gsub('App Store', appname)
          return result
        end
      end
      return message .. ' ' .. appname
    end
  elseif message == "Back" or message == "Forward"
      or (message == "Zoom" and OS_VERSION >= OS.Tahoe) then
    fn = function(app)
      local appid = getAppId(app)
      local paramsCopy = params and tcopy(params) or {}
      if paramsCopy.locale == nil then
        paramsCopy.locale = getBufferedValidLocale(appid)
      end
      if paramsCopy.locale ~= nil then
        local targetAppId = message == "Zoom" and "com.apple.AppStore"
            or "com.apple.systempreferences"
        local result = localizedString(message, targetAppId, paramsCopy)
        if result then
          return result
        end
      end
      return message
    end
  else
    fn = function(app)
      local appid = getAppId(app)
      local paramsCopy = params and tcopy(params) or {}
      if paramsCopy.locale == nil then
        paramsCopy.locale = getBufferedValidLocale(appid)
      end
      if paramsCopy.locale ~= nil then
        if commonLocalizedStringsCache[paramsCopy.locale]
            and commonLocalizedStringsCache[paramsCopy.locale][message] then
          return commonLocalizedStringsCache[paramsCopy.locale][message]
        end
        paramsCopy.framework = "AppKit.framework"
        for i, stem in ipairs{ 'MenuCommands', 'Menus', 'Common' } do
          paramsCopy.localeFile = stem
          local retry = i > 1
          local result = localizedString(message, paramsCopy, retry)
          if result then
            result = result:gsub('“%%@”', ''):gsub('%%@', '')
            if commonLocalizedStringsCache[paramsCopy.locale] == nil then
              commonLocalizedStringsCache[paramsCopy.locale] = {}
            end
            commonLocalizedStringsCache[paramsCopy.locale][message] = result
            return result
          end
        end
        paramsCopy.framework = "UIKitMacHelper.framework"
        paramsCopy.localeFile = "MainMenu"
        local result = localizedString(message, paramsCopy, true)
        if result then
          result = result:gsub('“%%@”', ''):gsub('%%@', '')
          if commonLocalizedStringsCache[paramsCopy.locale] == nil then
            commonLocalizedStringsCache[paramsCopy.locale] = {}
          end
          commonLocalizedStringsCache[paramsCopy.locale][message] = result
          return result
        end
      end
      return message
    end
  end

  if type(params) == 'userdata' and (params.application
      or params.focusedWindow or params.AXParent) then
    local app = params
    params = params2
    return fn(app)
  else
    return fn
  end
end

-- Generate localized accessibility symbol names
-- Used for system-level UI elements (toolbar icons, symbols)
function TG(message, params, params2)
  local fn = function(app)
    local appid = getAppId(app)
    local paramsCopy = params and tcopy(params) or {}
    if paramsCopy.locale == nil then
      paramsCopy.locale = getBufferedValidLocale(appid)
    end
    if paramsCopy.locale ~= nil then
      paramsCopy.framework = "AccessibilitySharedSupport.framework"
      paramsCopy.localeFile = "SymbolNamesAutoGenerated"
      local result = localizedString(message, paramsCopy)
      if result then
        if result:byte(1) < 127 then
          result = result:sub(1,1):upper()..result:sub(2)
        end
        return result
      end
    end
    return message
  end

  if type(params) == 'userdata' and (params.application
      or params.focusedWindow or params.AXParent) then
    local app = params
    params = params2
    return fn(app)
  else
    return fn
  end
end

-- Pick the most frequent value from a list
-- Used when localization returns multiple candidates
local function mostFrequent(t)
    local count = {}
    local firstIndex = {}

    for i, v in ipairs(t) do
        if not count[v] then
            count[v] = 1
            firstIndex[v] = i
        else
            count[v] = count[v] + 1
        end
    end

    local maxValue = nil
    local maxCount = 0
    local minIndex = math.huge

    for v, c in pairs(count) do
        local idx = firstIndex[v]
        if c > maxCount or (c == maxCount and idx < minIndex) then
            maxCount = c
            minIndex = idx
            maxValue = v
        end
    end

    return maxValue
end

local function getBufferedLocale(app)
  if app.focusedWindow then
    if app:isFrontmost() then
      return A_AppLocale
    end
  elseif app.application then
    local win = app
    if A_WinBuf == nil or A_WinBuf.get == nil then
      if win:application():isFrontmost() then
        return A_AppLocale
      end
    else
      if hs.window.frontmostWindow() == win then
        A_WinLocale = A_WinLocale or A_WinBuf:get("locale", function()
          local locale = applicationLocale(getAppId(app))
          return locale
        end)
      end
      return A_WinLocale
    end
  end

  local locale = applicationLocale(getAppId(app))
  return locale
end

-- Unified localization entry:
--  • string      -> localized string
--  • table path  -> localized menu path
function T(message, params, sep)
  local fn = function(app)
    local appid = getAppId(app)
    local paramsCopy = params and tcopy(params) or {}
    if paramsCopy.locale == nil then
      paramsCopy.locale = getBufferedLocale(app)
    end
    if type(message) == 'string' then
      local str = localizedString(message, appid, paramsCopy) or message
      return type(str) == 'string' and str or mostFrequent(str)
    else
      if sep == nil then sep = ' > ' end
      local str = localizedMenuBarItem(message[1], appid, paramsCopy) or message[1]
      for i=2,#message do
        local itemStr = localizedString(message[i], appid, paramsCopy) or message[i]
        str = str .. sep .. (type(itemStr) == 'string' and itemStr or mostFrequent(itemStr))
      end
      return str
    end
  end

  if type(params) == 'userdata' and (params.application
      or params.focusedWindow or params.AXParent) then
    local app = params
    params = sep
    return fn(app)
  else
    return fn
  end
end

-- Prefix localized title with application display name
-- Used for hotkeys that DO NOT require the target application
-- to be running
function TB(appid, message)
  return function(thisAppId)
    if message == nil then
      message = appid
      appid = thisAppId
    end
    local msg = localizedString(message, thisAppId) or message
    return displayName(appid) .. ' > ' .. msg
  end
end

-- Same as TB, but accepts menu element instead of app bundle identifier
function TMB(appid, message)
  return function(menu)
    local thisAppId = getAppId(menu)
    if message == nil then
      message = appid
      appid = thisAppId
    end
    local msg = localizedString(message, thisAppId) or message
    return displayName(appid) .. ' > ' .. msg
  end
end

------------------------------------------------------------
-- ## application version comparison utilities
--
-- Provides composable predicates for app version matching.
------------------------------------------------------------

Version = {}

local makeVer = require("version").new
function appVer(obj)
  return applicationVersion(getAppId(obj))
end

-- Check if app version is less than target
Version.LessThan = function(version)
  return function(obj)
    return appVer(obj) < makeVer(version)
  end
end

-- Check if app version is greater than target
Version.GreaterThan = function(version)
  return function(obj)
    return appVer(obj) > makeVer(version)
  end
end

-- Check if app version >= target
Version.GreaterEqual = function(version)
  return function(obj)
    return appVer(obj) >= makeVer(version)
  end
end

-- Check if app version <= target
Version.LessEqual = function(version)
  return function(obj)
    return appVer(obj) <= makeVer(version)
  end
end

-- Check whether app version is within a half-open interval.
--
-- Version.Between(a, b) means:
--   a <= version < b
Version.Between = function(version1, version2)
  return function(obj)
    local appVersion = appVer(obj)
    return appVersion >= makeVer(version1)
        and appVersion < makeVer(version2)
  end
end

------------------------------------------------------------
-- ## callback helpers for UI actions
--
-- This section defines reusable callback generators that
-- encapsulate low-level UI interactions such as:
--  • pressing buttons
--  • clicking coordinates
--  • selecting rows
--
-- These callbacks are referenced by hotkey configs and
-- executed by the dispatcher.
------------------------------------------------------------

Callback = {}

-- Perform AX.Press while safely handling Ctrl-modifier edge cases
Callback.Press = function(pressable)
  local flags = hs.eventtap.checkKeyboardModifiers()
  if not flags[Mod.Ctrl.Short] then
    pressable:performAction(AX.Press)
  else
    flags[Mod.Ctrl.Short] = nil
    local tapper
    tapper = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged },
      function(event)
        tapper:stop()
        hs.timer.doAfter(0.01, function()
          local newFlags = hs.eventtap.checkKeyboardModifiers()
          if newFlags[Mod.Ctrl.Short] then
            newFlags[Mod.Ctrl.Short] = nil
            event:setFlags(newFlags):post()
            hs.timer.doAfter(0.01, function()
              pressable:performAction(AX.Press)
            end)
          else
            pressable:performAction(AX.Press)
          end
        end)
        return false
      end):start()
    local event = hs.eventtap.event.newEvent()
    event:setType(hs.eventtap.event.types.flagsChanged)
    event:setFlags(flags):post()
  end
end

-- Perform a left click at a fixed position
Callback.Click = function(position)
  leftClickAndRestore(position)
end

-- Click and hold for a specified delay
Callback.ClickAndHold = function(delay)
  return function(position)
    leftClickAndRestore(position, nil, delay)
  end
end

-- Perform a system-level double click
Callback.DoubleClick = function(position)
  local cmd = hs.execute("which cliclick | tr -d '\\n'", true)
  if cmd == nil then
    hs.alert([[
      Cliclick NOT INSTALLED.
      You can install it by `brew install cliclick`.]])
    return
  end
  local task = hs.task.new(cmd, nil,
      { strfmt([[dc:%d,%d]], math.floor(position.x), math.floor(position.y)) })
  task:start()
end

Callback.PressClick = function(target)
  if target.AXPosition then
    Callback.Press(target)
  else
    Callback.Click(target)
  end
end

-- Check whether an element is enabled
Callback.Enabled = function(element)
  return element and (element.enabled or element.AXEnabled), element
end

-- Check whether an element is safely clickable and return click point
Callback.Clickable = function(element, offset)
  if element == nil or not element:isValid() then return false end
  if offset == nil then
    offset = { element.AXSize.w / 2, element.AXSize.h / 2 }
  end
  local point = hs.geometry.point {
    element.AXPosition.x + offset[1],
    element.AXPosition.y + offset[2],
  }
  local appHere, errMsg = hs.axuielement.systemElementAtPosition(point)
  if appHere == nil and errMsg == "Function or method not implemented" then
    return true, point
  end
  if appHere then
    while appHere.AXParent do
      appHere = appHere.AXParent
    end
    appHere = appHere:asHSApplication()
    if appHere == getAppFromDescendantElement(element) then
      return true, point
    end
  end
  return false
end
