require "utils"

hs.application.enableSpotlightForNameSearches(true)

local runningAppsOnLoading = {}
foreach(hs.application.runningApplications(), function(app)
  runningAppsOnLoading[app:bundleID() or app:name()] = app
end)


------------------------------------------------------------
-- # appkeys
-- Application-level hotkeys (launch / focus / hide)
------------------------------------------------------------

-- Launch an application or hide it if already focused
--
-- Behavior:
--  • If the app is not focused, bring it to front (or launch it)
--  • If the app is already focused, hide it
--  • Special handling is applied for Finder due to Desktop windows
local function focusOrHide(hint)
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
local appkeys = {}

-- Register all application-level hotkeys
--
-- Hotkeys are rebuilt every time this function runs to ensure
-- consistency with current configuration and running apps.
local function registerAppKeys()
  for _, hotkey in ipairs(appkeys) do
    hotkey:delete()
  end
  appkeys = {}

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
          appname = displayName(runningAppsOnLoading[appid] or appid)
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
      tinsert(appkeys, hotkey)
    end
  end
end

-- Register appkeys immediately on load
registerAppKeys()


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
local function getAppFromDescendantElement(elem)
  local appUI = elem
  repeat
    appUI = appUI.AXParent
  until appUI.AXParent == nil
  return appUI:asHSApplication()
end

-- normalize application identifier
-- Accepts bundleID, hs.application, or AX element
local function getAppId(app)
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
local function isLSUIElement(appid)
  local info = hs.application.infoForBundleID(appid)
  return info and info.LSUIElement == true
end

------------------------------------------------------------
-- Evt
--
-- Centralized registry for application lifecycle callbacks.
-- Callbacks are grouped by event type and app identifier.
------------------------------------------------------------
local Evt = {}

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
    find(appid)
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
Evt.onDestroy = function(element, callback, stopWhen, callbackOnStop)
  if not element:isValid() then return end
  local app = getAppFromDescendantElement(element)
  local closeObserver = uiobserver.new(app:pid())
  closeObserver:addWatcher(element, uinotifications.uIElementDestroyed)
  closeObserver:callback(function(obs, ...)
    callback(obs, ...) obs:stop() obs = nil
  end)
  closeObserver:start()

  if type(stopWhen) == 'number' then
    stopWhen = { stopWhen }
  end
  for _, ev in ipairs(stopWhen or {}) do
    if ev == hs.application.watcher.deactivated then
      Evt.StopOnDeactivated(app, closeObserver, callbackOnStop and callback)
    elseif ev == hs.application.watcher.terminated then
      Evt.StopOnTerminated(app, closeObserver, callbackOnStop and callback)
    end
  end

  return closeObserver
end

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
local function TC(message, params, params2)
  local fn
  if message == "Hide" or message == "Quit" then
    fn = function(app)
      local appname = displayName(app.application and app:application() or app)
      local appid = getAppId(app)
      params = params and tcopy(params) or {}
      if params.locale == nil then
        params.locale = applicationValidLocale(appid)
      end
      if params.locale ~= nil then
        local result = localizedString(message .. ' App Store',
                                       'com.apple.AppStore', params)
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
      params = params and tcopy(params) or {}
      if params.locale == nil then
        params.locale = applicationValidLocale(appid)
      end
      if params.locale ~= nil then
        local targetAppId = message == "Zoom" and "com.apple.AppStore"
            or "com.apple.systempreferences"
        local result = localizedString(message, targetAppId, params)
        if result then
          return result
        end
      end
      return message
    end
  else
    fn = function(app)
      local appid = getAppId(app)
      params = params and tcopy(params) or {}
      if params.locale == nil then
        params.locale = applicationValidLocale(appid)
      end
      if params.locale ~= nil then
        params.framework = "AppKit.framework"
        for i, stem in ipairs{ 'MenuCommands', 'Menus', 'Common' } do
          params.localeFile = stem
          local retry = i > 1
          local result = localizedString(message, params, retry)
          if result then
            result = result:gsub('“%%@”', ''):gsub('%%@', '')
            return result
          end
        end
        params.framework = "UIKitMacHelper.framework"
        params.localeFile = "MainMenu"
        local result = localizedString(message, params, true)
        if result then
          result = result:gsub('“%%@”', ''):gsub('%%@', '')
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
local function TG(message, params, params2)
  local fn = function(app)
    local appid = getAppId(app)
    params = params and tcopy(params) or {}
    if params.locale == nil then
      params.locale = applicationValidLocale(appid)
    end
    if params.locale ~= nil then
      params.framework = "AccessibilitySharedSupport.framework"
      params.localeFile = "SymbolNamesAutoGenerated"
      local result = localizedString(message, params)
      if result then return result end
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

-- Unified localization entry:
--  • string      -> localized string
--  • table path  -> localized menu path
local function T(message, params, sep)
  local fn = function(app)
    local appid = getAppId(app)
    if type(message) == 'string' then
      local str = localizedString(message, appid, params) or message
      return type(str) == 'string' and str or mostFrequent(str)
    else
      if sep == nil then sep = ' > ' end
      local str = localizedMenuBarItem(message[1], appid, params) or message[1]
      for i=2,#message do
        local itemStr = localizedString(message[i], appid, params) or message[i]
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
local function TB(appid, message)
  return function(thisAppId)
    if message == nil then
      message = appid
      appid = thisAppId
    end
    return displayName(appid) .. ' > ' .. T(message)(thisAppId)
  end
end

-- Same as TB, but accepts menu element instead of app bundle identifier
local function TMB(appid, message)
  return function(menu)
    local thisAppId = getAppId(menu)
    if message == nil then
      message = appid
      appid = thisAppId
    end
    return displayName(appid) .. ' > ' .. T(message)(thisAppId)
  end
end

------------------------------------------------------------
-- ## application version comparison utilities
--
-- Provides composable predicates for app version matching.
------------------------------------------------------------

local Version = {}

-- Build a version comparison predicate
-- Supported operators: == ~= < <= > >=
local function versionCompare(comp, versionStr, extra)
  local fn = function(app)
    local appid = getAppId(app)
    local appMajor, appMinor, appPatch = applicationVersion(appid)
    local version = strsplit(versionStr, "%.")
    local major, minor, patch
    major = tonumber(version[1]:match("%d+"))
    minor = #version > 1 and tonumber(version[2]:match("%d+")) or 0
    patch = #version > 2 and tonumber(version[3]:match("%d+")) or 0
    if comp == "==" then
      return appMajor == major and appMinor == minor and appPatch == patch
    elseif comp == "~=" then
      return appMajor ~= major or appMinor ~= minor or appPatch ~= patch
    elseif comp == "<" or comp == "<=" then
      return appMajor < major
          or (appMajor == major and appMinor < minor)
          or (appMajor == major and appMinor == minor and appPatch < patch)
          or (comp == "<=" and
              appMajor == major and appMinor == minor and appPatch == patch)
    elseif comp == ">" or comp == ">=" then
      return appMajor > major
          or (appMajor == major and appMinor > minor)
          or (appMajor == major and appMinor == minor and appPatch > patch)
          or (comp == ">=" and
              appMajor == major and appMinor == minor and appPatch == patch)
    end
  end

  if type(versionStr) == 'string' then
    return fn
  else
    local app = versionStr
    versionStr = extra
    return fn(app)
  end
end

-- Check if app version is less than target
Version.LessThan = function(...)
  return versionCompare("<", ...)
end

-- Check if app version is greater than target
Version.GreaterThan = function(...)
  return versionCompare(">", ...)
end

-- Check if app version >= target
Version.GreaterEqual = function(...)
  return versionCompare(">=", ...)
end

-- Check if app version <= target
Version.LessEqual = function(...)
  return versionCompare("<=", ...)
end

-- Check whether app version is within a half-open interval.
--
-- Version.Between(a, b) means:
--   a <= version < b
Version.Between = function(version1, version2)
  return function(app)
    return Version.GreaterEqual(app, version1) and Version.LessThan(app, version2)
  end
end

------------------------------------------------------------
-- Parsing and emitting key bindings stored in plist files
------------------------------------------------------------

-- Parse a key binding encoded in macOS plist format.
--
-- Some applications store their key bindings in plist files,
-- where modifiers and keys are represented as bit masks.
local function parsePlistKeyBinding(mods, key)
  mods = tonumber(mods) key = tonumber(key)
  if mods == nil or key == nil then return end
  key = hs.keycodes.map[key]
  local modList = {}
  if mods >= (1 << 17) then
    if mods >= (1 << 23) then tinsert(modList, Mod.Fn) end
    if (mods % (1 << 23)) >= (1 << 20) then tinsert(modList, Mod.Cmd.Long) end
    if (mods % (1 << 20)) >= (1 << 19) then tinsert(modList, Mod.Alt.Long) end
    if (mods % (1 << 19)) >= (1 << 18) then tinsert(modList, Mod.Ctrl.Long) end
    if (mods % (1 << 18)) >= (1 << 17) then tinsert(modList, Mod.Shift.Long) end
  else
    if mods >= (1 << 12) then tinsert(modList, Mod.Ctrl.Long) end
    if (mods % (1 << 12)) >= (1 << 11) then tinsert(modList, Mod.Alt.Long) end
    if (mods % (1 << 11)) >= (1 << 9) then tinsert(modList, Mod.Shift.Long) end
    if (mods % (1 << 9)) >= (1 << 8) then tinsert(modList, Mod.Cmd.Long) end
  end
  return modList, key
end

-- Dump a key binding into plist-compatible encoded values.

local function dumpPlistKeyBinding(mode, mods, key)
  local modIdx = 0
  if mode == 1 then
    if tcontain(mods, Mod.Cmd.Long) then modIdx = (1 << 8) end
    if tcontain(mods, Mod.Alt.Long) then modIdx = modIdx + (1 << 11) end
    if tcontain(mods, Mod.Ctrl.Long) then modIdx = modIdx + (1 << 12) end
    if tcontain(mods, Mod.Shift.Long) then modIdx = modIdx + (1 << 9) end
  elseif mode == 2 then
    if key:lower():match("^f(%d+)$") then modIdx = 1 << 23 end
    if tcontain(mods, Mod.Cmd.Long) then modIdx = modIdx + (1 << 20) end
    if tcontain(mods, Mod.Alt.Long) then modIdx = modIdx + (1 << 19) end
    if tcontain(mods, Mod.Ctrl.Long) then modIdx = modIdx + (1 << 18) end
    if tcontain(mods, Mod.Shift.Long) then modIdx = modIdx + (1 << 17) end
  end
  key = hs.keycodes.map[key]
  return modIdx, key
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

local Callback = {}

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

-- Select a UI row element
Callback.UISelect = function(row)
  row.AXSelected = true
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
  local appHere = hs.axuielement.systemElementAtPosition(point)
  if appHere then
    while appHere.AXParent do
      appHere = appHere.AXParent
    end
    local appid = appHere:asHSApplication():bundleID()
    local targetApp = getAppFromDescendantElement(element)
    if appid == targetApp:bundleID() then
      return true, point
    end
  end
  return false
end


----------------------------------------------------------------------
-- Hotkeys in specific applications
--
-- This section defines:
--   1. Window / application classifiers (WF: Window Filter)
--   2. Title providers for hotkey display
--   3. Action callbacks bound to specific UI elements
--
-- Design principles:
--   - Hotkeys are registered dynamically per application/window
--   - A hotkey exists ONLY when its target window matches WF rules
--   - Titles are computed lazily and may depend on UI structure
--
-- Core concepts:
--   - WF (Window Filter): describes *where* a hotkey is valid
--   - Callback: describes *what* the hotkey does
--   - Title function: describes *how the hotkey is shown*
----------------------------------------------------------------------

local appHotKeyCallbacks
local runningAppHotKeys = {}
local inAppHotKeys = {}
local inWinHotKeys = {}
local daemonAppFocusedWindowHotkeys = {}
local menuBarMenuHotkeys = {}
local registerInAppHotKeys, unregisterInAppHotKeys
local registerInWinHotKeys, unregisterInWinHotKeys
local registerDaemonAppInWinHotkeys
local registerInMenuHotkeys

-- appBuf:
-- Application-scoped runtime cache.
--
-- Data in appBuf lives until another application activates
local appBuf = {}

-- winBuf:
-- Window-scoped runtime cache.
--
-- Data is automatically cleaned up when the window is destroyed.
local winBuf = {}
function winBuf:register(winUI, key, value)
  winBuf.observer = Evt.onDestroy(winUI, function()
    winBuf[key] = nil
    winBuf.observer = nil
  end)
  winBuf[key] = value
  return winBuf[key]
end

local WF = {}

-- ### Finder
local Finder = {}
Finder.sidebarItemTitle = function(idx)
  return function(win)
    local outline = getc(towinui(win), AX.SplitGroup, 1,
        AX.ScrollArea, 1, AX.Outline, 1)
    if outline == nil then return end
    local header
    local cnt = 0
    for _, row in ipairs(getc(outline, AX.Row)) do
      if #row == 0 then hs.timer.usleep(0.3 * 1000000) end
      local titleElem = getc(row, AX.Cell, 1, AX.StaticText, 1)
      if titleElem and titleElem.AXIdentifier ~= nil then
        header = titleElem.AXValue
      elseif titleElem then
        cnt = cnt + 1
        if cnt == idx then
          local itemTitle = titleElem.AXValue
          if appBuf.finderSidebarItemObserver == nil then
            local app = win:application()
            local appid = app:bundleID()
            local observer = uiobserver.new(app:pid())
            observer:addWatcher(outline, uinotifications.rowCountChanged)
            observer:callback(function()
              if appBuf.lastRowCountChangedTimer then
                appBuf.lastRowCountChangedTimer:setNextTrigger(0.1)
                return
              end
              appBuf.lastRowCountChangedTimer = hs.timer.doAfter(0.1, function()
                appBuf.lastRowCountChangedTimer = nil
                for _, hotkeys in pairs(inWinHotKeys[appid]) do
                  for hkID, hotkey in pairs(hotkeys) do
                    if hkID:match('^open(.-)SidebarItem$') then
                      hotkey:delete()
                      hotkeys[hkID] = nil
                    end
                  end
                end
                for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
                  if hkID:match('^open(.-)SidebarItem$') then
                    registerInWinHotKeys(app:focusedWindow(), cfg.windowFilter)
                    break
                  end
                end
              end)
            end)
            observer:start()
            appBuf.finderSidebarItemObserver = observer
            Evt.StopOnDeactivated(app, appBuf.finderSidebarItemObserver)
          end
          return header .. ' > ' .. itemTitle
        end
      end
    end
  end
end

Finder.getSidebarItem = function(idx)
  return function(win)
    local outline = getc(towinui(win), AX.SplitGroup, 1,
        AX.ScrollArea, 1, AX.Outline, 1)
    if outline == nil then return false end
    local cnt = 0
    for _, row in ipairs(getc(outline, AX.Row)) do
      local titleElem = getc(row, AX.Cell, 1, AX.StaticText, 1)
      if titleElem and titleElem.AXIdentifier == nil then
        cnt = cnt + 1
      end
      if cnt == idx then
        return true, getc(row, AX.Cell, 1)
      end
    end
    return false
  end
end

Finder.openSidebarItem = function(cell, win)
  local app = win:application()
  local go = T("Go", app)
  local itemTitle = getc(cell, AX.StaticText, 1).AXValue
  if app:findMenuItem({ go, itemTitle }) ~= nil then
    app:selectMenuItem({ go, itemTitle })
  else
    local flags = hs.eventtap.checkKeyboardModifiers()
    if not (flags[Mod.Cmd.Short] or flags[Mod.Alt.Short] or flags[Mod.Ctrl.Short]) then
      cell:performAction(AX.Open)
    else
      local tapper
      tapper = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged },
      function(event)
        tapper:stop()
        hs.timer.doAfter(0.01, function()
          local newFlags = hs.eventtap.checkKeyboardModifiers()
          if newFlags[Mod.Cmd.Short] or newFlags[Mod.Alt.Short] or newFlags[Mod.Ctrl.Short] then
            event:setFlags({}):post()
            hs.timer.doAfter(0.01, function()
              cell:performAction(AX.Open)
            end)
          else
            cell:performAction(AX.Open)
          end
        end)
        return false
      end):start()
      local event = hs.eventtap.event.newEvent()
      event:setType(hs.eventtap.event.types.flagsChanged)
      event:setFlags({}):post()
    end
  end
end

-- ### Messages
local Messages = {}
Messages.deleteSelected = function(app)
  if app:focusedWindow() == nil then return end
  local winUI = towinui(app:focusedWindow())
  local button
  if OS_VERSION >= OS.Tahoe then
    if hs.host.operatingSystemVersion().minor >= 2 then
      button = getc(winUI, AX.Group, 1, AX.Group, 1,
          AX.Group, 1, AX.Group, 1, AX.Button, 2)
    else
      button = getc(winUI, AX.Group, 1, AX.Group, 1,
          AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Button, 2)
    end
  else
    button = getc(winUI, AX.Group, 1, AX.Group, 1,
        AX.Group, 2, AX.Group, 1, AX.Button, 2)
  end
  if button ~= nil then
    Callback.Press(button)
    hs.timer.doAfter(0.2, function()
      if not app:isRunning() then return end
      if app:focusedWindow():role() == AX.Sheet then
        local sheet = towinui(app:focusedWindow())
        local delete = getc(sheet, AX.Button, 2)
        Callback.Press(delete)
      end
    end)
    return
  end

  local _, menuItem = findMenuItem(app, {
    OS_VERSION < OS.Ventura and "File" or "Conversation",
    "Delete Conversation…"
  })
  app:selectMenuItem(menuItem)
  hs.timer.doAfter(0.2, function()
    if not app:isRunning() then return end
    if app:focusedWindow():role() == AX.Sheet then
      local sheet = towinui(app:focusedWindow())
      local delete = getc(sheet, AX.Button, T("Delete", app))
      Callback.Press(delete)
    end
  end)
end

Messages.messageItems = function(app)
  local appUI = toappui(app)
  if OS_VERSION >= OS.Tahoe then
    if hs.host.operatingSystemVersion().minor >= 2 then
      return getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
          AX.Group, 2, AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.StaticText)
    else
      return getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
          AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
          AX.StaticText)
    end
  else
    return getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.StaticText)
  end
end

Messages.deletable = function(app)
  local messageItems = Messages.messageItems(app)
  if messageItems == nil or #messageItems == 0 then
    return false
  end
  local desc = T('New Message', app)
  if messageItems[1].AXDescription == nil
      or messageItems[1].AXDescription:sub(4) == desc
      or messageItems[1].AXValue ~= nil then
    tremove(messageItems, 1)
  end
  return #messageItems > 0, messageItems
end

Messages.deleteAll = function(messageItems, app)
  local cnt = #messageItems
  local firstMsg, lastMsg = messageItems[1], messageItems[cnt]
  local frame = app:focusedWindow():frame()
  while frame.y + frame.h < lastMsg.AXPosition.y + lastMsg.AXSize.h do
    cnt = cnt - 1
    lastMsg = messageItems[cnt]
  end

  local firstSelected = firstMsg.AXSelected
  if not firstSelected then
    hs.timer.doAfter(0.1, bind(Callback.Press, firstMsg))
  end
  if #messageItems == 1
      or (#messageItems == 2 and lastMsg.AXSelected) then
    if firstSelected then
      Messages.deleteSelected(app)
    else
      hs.timer.doAfter(0.3, bind(Messages.deleteSelected, app))
    end
    return
  end

  hs.timer.doAfter(0.5, function()
    for i=2,#messageItems do
      messageItems[i].AXSelected = false
    end
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, true):post()
    hs.timer.doAfter(1, function()
      Callback.Press(lastMsg)
      hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, false):post()
      Messages.deleteSelected(app)

      hs.timer.doAfter(2, function()
        if not app:isFrontmost() then return end
        local continue
        continue, messageItems = Messages.deletable(app)
        if continue then
          Messages.deleteAll(messageItems, app)
        end
      end)
    end)
  end)
end

-- ### Phone
local Phone = {}
Phone.WF = {}
Phone.WF.Main = {}
if OS_VERSION >= OS.Tahoe then
  Evt.OnRunning("com.apple.mobilephone", function(app)
    Phone.WF.Main.allowTitles = '^' .. app:name() .. '$'
  end)
end

local function PhoneShowViewMenu(winUI)
  local button = getc(winUI, AX.Toolbar, 1,
      AX.Group, 2, AX.Group, 1, AX.MenuButton, 1)
  if button then
    Callback.Press(button) return true
  end
  return false
end

Phone.selectView = function(index)
  return function(win)
    local winUI  = towinui(win)
    if not PhoneShowViewMenu(winUI) then return end
    local menu
    repeat
      hs.timer.usleep(0.01 * 1000000)
      menu = getc(winUI, AX.Toolbar, 1, AX.Group, 2, AX.Menu, 1)
    until menu or not winUI:isValid()
    local menuItem = getc(menu, AX.MenuItem, index)
    if menuItem then Callback.Press(menuItem) end
  end
end

-- ### FaceTime
local FaceTime = {}
FaceTime.WF = {}
FaceTime.WF.Main = {}
Evt.OnRunning("com.apple.FaceTime", function(app)
  FaceTime.WF.Main.allowTitles = '^' .. app:name() .. '$'
end)

FaceTime.hoveringOverCall = function(win)
  local appUI = towinui(win).AXParent
  local elemHoveredOver = appUI:elementAtPosition(hs.mouse.absolutePosition())
  if elemHoveredOver.AXRole ~= AX.Button then return false end
  local collection = elemHoveredOver.AXParent
  if OS_VERSION >= OS.Tahoe then
    collection = collection.AXParent
  end
  return collection.AXDescription == T("Recent Calls", win)
end

FaceTime.deleteMousePositionCall = function(win)
  local app = win:application()
  local winUI = towinui(win)

  if not rightClick(hs.mouse.absolutePosition(), app) then
    return
  end
  local popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
  local maxTime, time = 0.5, 0
  while popup == nil and time < maxTime do
    hs.timer.usleep(0.01 * 1000000)
    time = time + 0.01
    popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
  end
  if popup == nil then
    if not rightClick(hs.mouse.absolutePosition(), app) then
      return
    end
    popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
    time = 0
    while popup == nil and time < maxTime do
      hs.timer.usleep(0.01 * 1000000)
      time = time + 0.01
      popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
    end
    if popup == nil then return end
  end
  local title = app:bundleID() == "com.apple.mobilephone"
      and "Delete" or "Remove from Recents"
  local locTitle = T(title, app)
  local menuItem = getc(popup, AX.MenuItem, locTitle)
  if menuItem ~= nil then
    Callback.Press(menuItem)
  end
end

FaceTime.hasCall = function(win)
  local section
  if OS_VERSION >= OS.Tahoe then
    local collection = getc(towinui(win), AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 1)
    if collection and collection.AXDescription == T("Recent Calls", win) then
      section = getc(collection, AX.Group, 1, AX.Button, 1)
    end
  else
    local collection = getc(towinui(win), AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 2)
    if collection and collection.AXDescription == T("Recent Calls", win) then
      section = getc(collection, AX.Button, 1)
    end
  end
  return section ~= nil, section
end

FaceTime.deleteAll = function(section, win)
  local app = win:application()
  if OS_VERSION < OS.Tahoe then
    local menuItem, menuItemPath = findMenuItem(app, { "FaceTime", "Remove All Recents" })
    if menuItem and menuItem.enabled then
      app:selectMenuItem(menuItemPath)
      return
    end
  end

  if not rightClick(section, app) then
    return
  end

  local winUI = towinui(win)
  local popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
  local maxTime, time = 0.5, 0
  while popup == nil and time < maxTime do
    hs.timer.usleep(0.01 * 1000000)
    time = time + 0.01
    popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
  end
  if popup == nil then
    if not rightClick(section, app) then
      return
    end
    popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
    time = 0
    while popup == nil and time < maxTime do
      hs.timer.usleep(0.01 * 1000000)
      time = time + 0.01
      popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
    end
    if popup == nil then return end
  end
  local title = app:bundleID() == "com.apple.mobilephone"
      and "Delete" or "Remove from Recents"
  local locTitle = T(title, app)
  local menuItem = getc(popup, AX.MenuItem, locTitle)
  if menuItem ~= nil then
    Callback.Press(menuItem)
  end
  hs.timer.usleep(0.1 * 1000000)
  if app:bundleID() == "com.apple.FaceTime" and OS_VERSION >= OS.Tahoe then
    local sheet = getc(winUI, AX.Sheet, 1)
    time, maxTime = 0, 0.2
    while sheet == nil and time < maxTime do
      hs.timer.usleep(0.01 * 1000000)
      time = time + 0.01
      sheet = getc(winUI, AX.Sheet, 1)
    end
    if sheet then
      Callback.Press(getc(sheet, AX.Button, -1))
    end
  end
  FaceTime.deleteAll(section, win)
end

local function FaceTimeShowViewMenu(winUI)
  local button = getc(winUI, AX.Group, 1, AX.Group, 1,
      AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
      AX.Button, 1)
  if button then
    Callback.Press(button) return true
  end
  return false
end

FaceTime.selectView = function(index)
  return function(win)
    local winUI  = towinui(win)
    if not FaceTimeShowViewMenu(winUI) then return end
    local menu
    repeat
      hs.timer.usleep(0.01 * 1000000)
      menu = getc(winUI, AX.Group, 1, AX.Menu, 1)
    until menu or not winUI:isValid()
    local menuItem = getc(menu, AX.MenuItem, index)
    if menuItem then Callback.Press(menuItem) end
  end
end

-- ### Music
local Music = {}
Music.WF = {}
Music.WF.Main = {
  fn = function(win)
    local rows = getc(towinui(win), AX.SplitGroup, 1,
        AX.ScrollArea, 1, AX.Outline, 1, AX.Row)
    return rows and #rows > 0
  end
}

Music.viewTitle = function(index)
  return function(win)
    local outline = getc(towinui(win), AX.SplitGroup, 1,
        AX.ScrollArea, 1, AX.Outline, 1)
    if outline == nil then return end
    local rows, sum = getc(outline, AX.Row), 0
    for _, r in ipairs(rows) do sum = sum + r.AXSize.h end
    local mean = sum / #rows
    rows = tifilter(rows, function(r)
      return r.AXSize.h > mean and getc(r, AX.Cell, 1, AX.StaticText, 1) ~= nil
    end)
    local row = rows[index]
    if row then
      if appBuf.musicSidebarItemObserver == nil then
        local app = win:application()
        local appid = app:bundleID()
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(outline, uinotifications.rowCountChanged)
        observer:callback(function()
          if appBuf.lastRowCountChangedTimer then
            appBuf.lastRowCountChangedTimer:setNextTrigger(0.1)
            return
          end
          appBuf.lastRowCountChangedTimer = hs.timer.doAfter(0.1, function()
            appBuf.lastRowCountChangedTimer = nil
            for _, hotkeys in pairs(inWinHotKeys[appid]) do
              for hkID, hotkey in pairs(hotkeys) do
                if hkID:match('^view(%d-)$') then
                  hotkey:delete()
                  hotkeys[hkID] = nil
                end
              end
            end
            for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
              if hkID:match('^view(%d-)$') then
                registerInWinHotKeys(app:focusedWindow(), cfg.windowFilter)
                break
              end
            end
          end)
        end)
        observer:start()
        appBuf.musicSidebarItemObserver = observer
        Evt.StopOnDeactivated(app, appBuf.musicSidebarItemObserver)
      end
      return getc(row, AX.Cell, 1, AX.StaticText, 1).AXValue
    end
  end
end

Music.selectView = function(index)
  return function(win)
    local rows = getc(towinui(win), AX.SplitGroup, 1,
        AX.ScrollArea, 1, AX.Outline, 1, AX.Row)
    local sum = 0
    for _, r in ipairs(rows) do sum = sum + r.AXSize.h end
    local mean = sum / #rows
    rows = tifilter(rows, function(r)
      return r.AXSize.h > mean and getc(r, AX.Cell, 1, AX.StaticText, 1) ~= nil
    end)
    local row = rows[index]
    if row then
      row.AXSelected = true
    end
  end
end

-- ### Games
local Games = {}
Games.WF = {}
Games.WF.Main = {
  fn = function(win)
    return getc(towinui(win), AX.Toolbar, 1) ~= nil
  end
}

--- ### Weather
local Weather = {}
Weather.getLocationList = function(win)
  if win == nil then return end
  local list
  if OS_VERSION >= OS.Tahoe and hs.host.operatingSystemVersion().minor >= 2 then
    list = getc(towinui(win), AX.Group, 1,
        AX.Group, 1, AX.Group, 2, AX.Group, 2, AX.Group, 1, AX.Group, 1)
  else
    list = getc(towinui(win), AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1)
    if OS_VERSION >= OS.Tahoe then list = getc(list, AX.Group, 1) end
  end
  if list and list.AXDescription == T("Location List", win) then
    return tifilter(list.AXChildren or {}, function(elem)
      return #elem > 0 and elem[1].AXRole == AX.Button
    end)
  end
end

-- ### Visual Studio Code
local VSCode = {}
VSCode.WF = {}
VSCode.WF.Main = {
  fn = function(win)
    local winUI = towinui(win)
    return winUI.AXIdentifier ~= "open-panel"
  end
}

VSCode.toggleSideBarSection = function(win, sidebar, section)
  local pressfn
  if Version.LessThan(win, "1.101") then
    pressfn = Callback.Press
  else
    if appBuf.VSCodeTabClicked then return end
    appBuf.VSCodeTabClicked = false
    pressfn = function(button)
      leftClickAndRestore(button, win)
    end
  end

  local winUI = towinui(win)
  local ancestor = getc(winUI,
      nil, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
      nil, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
      AX.Group, 2, AX.Group, 2, AX.Group, 1, AX.Group, 2)
  if ancestor == nil then
    ancestor = getc(winUI,
        nil, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 2, AX.Group, 2, AX.Group, 1, AX.Group, 2)
  end

  local elem = getc(ancestor, AX.Group, 2, AX.Heading, 1)
      or getc(ancestor, AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Heading, 1)
  if elem and elem.AXTitle:sub(1, #sidebar) == sidebar then
    local sections = getc(ancestor, AX.Group, 2, AX.Group, 2,
          AX.Group, 1, AX.Group, 2, AX.Group)
        or getc(ancestor, AX.Group, 2, AX.Group, 1,
          AX.Group, 1, AX.Group, 2, AX.Group)
    for _, sec in ipairs(sections) do
      local button = getc(sec, AX.Button, 1)
          or getc(sec, AX.Group, 1, AX.Button, 1)
      if button[2].AXTitle == section then
        pressfn(button)
        break
      end
    end
  else
    local tabs = getc(ancestor, AX.Group, 1,
        AX.Group, 1, AX.TabGroup, 1, AX.RadioButton)
    local tab = tfind(tabs, function(t)
      return t.AXTitle:upper():sub(1, #sidebar) == sidebar
          or t.AXDescription:upper():sub(1, #sidebar) == sidebar
    end)
    if Version.GreaterEqual(win, "1.101") then
      appBuf.VSCodeTabClicked = true
      hs.timer.doAfter(2, function()
        appBuf.VSCodeTabClicked = nil
      end)
    end
    pressfn(tab)

    local sections
    local totalDelay = 0
    repeat
      sections = getc(ancestor, AX.Group, 2, AX.Group, 1,
                      AX.Group, 1, AX.Group, 2, AX.Group)
          or getc(ancestor, AX.Group, 2, AX.Group, 2,
                  AX.Group, 1, AX.Group, 2, AX.Group)
      if sections then break end
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
    until totalDelay > 0.2
    if sections == nil then
      leftClickAndRestore(tab, winUI:asHSWindow())
      repeat
        sections = getc(ancestor, AX.Group, 2, AX.Group, 1,
                        AX.Group, 1, AX.Group, 2, AX.Group)
            or getc(ancestor, AX.Group, 2, AX.Group, 2,
                    AX.Group, 1, AX.Group, 2, AX.Group)
        if sections then break end
          hs.timer.usleep(0.05 * 1000000)
          totalDelay = totalDelay + 0.05
      until totalDelay > 2.0
      if sections == nil then return end
    end
    for _, sec in ipairs(sections) do
      local button = getc(sec, AX.Button, 1)
          or getc(sec, AX.Group, 1, AX.Button, 1)
      if button[2].AXTitle == section then
        local records = getc(sec, AX.Group, 1, AX.Outline, 1, AX.Group, 1)
            or getc(sec, AX.Group, 1)
        if records == nil or #records == 1 then
          pressfn(button)
          break
        end
      end
    end
  end
end

-- ### WPS Office
local WPS = {}
WPS.WF = {}

WPS.WF.Home = {}
WPS.WF.NonHome = {}
Evt.OnRunning("com.kingsoft.wpsoffice.mac", function(app)
  local title = T("Home", app)
  WPS.WF.Home.allowTitles = '^'..title..'$'
  WPS.WF.NonHome.rejectTitles = WPS.WF.Home.allowTitles
end)

WPS.WF.Settings = {
  allowRoles = AX.Dialog,
  fn = function(win)
    local winUI = towinui(win)
    return getc(winUI, AX.Button, "Prev") ~= nil
        and getc(winUI, AX.Button, "Next") ~= nil
  end
}

WPS.WF.WPS_WPP = {
  allowTitles = "",
  fn = function(win)
    local appid = win:application():bundleID()
    local menuBarItems = getc(toappui(win:application()),
        AX.MenuBar, 1, AX.MenuBarItem)
    return tfind(menuBarItems, function(item)
      return item.AXTitle == localizedMenuBarItem("Tables", appid)
          or item.AXTitle == localizedMenuBarItem("Slide Show", appid)
    end) ~= nil
  end
}

WPS.WF.WPS_WPP_ET = {
  allowTitles = "",
  fn = function(win)
    local appid = win:application():bundleID()
    local menuBarItems = getc(toappui(win:application()),
        AX.MenuBar, 1, AX.MenuBarItem)
    return tfind(menuBarItems, function(item)
      return item.AXTitle == localizedMenuBarItem("Tables", appid)
          or item.AXTitle == localizedMenuBarItem("Slide Show", appid)
          or item.AXTitle == localizedMenuBarItem("Data", appid)
    end) ~= nil
  end
}

WPS.WF.PDF = {
  allowTitles = "",
  fn = function(win)
    local appid = win:application():bundleID()
    local locTitle = localizedMenuBarItem("Comment", appid)
    local menuBarItem = getc(toappui(win:application()),
        AX.MenuBar, 1, AX.MenuBarItem, locTitle)
    return menuBarItem ~= nil
  end
}

-- ### JabRef
local JabRef = {}

JabRef.WF = {}
JabRef.WF.numberLibraries = function(idx)
  return {
    allowTitles = "",
    fn = function(win)
      local winUI = towinui(win)
      local bts = getc(winUI, AX.TabGroup, 1, AX.RadioButton)
      return bts and #bts >= idx
    end
  }
end

JabRef.showLibraryByIndex = function(idx)
  return function(win)
    local tab = getc(towinui(win), AX.TabGroup, 1, AX.RadioButton, idx)
    return Callback.Clickable(tab, { 10, 10 })
  end
end

-- ### App Cleaner & Uninstaller
local AppCleanerUninstaller = {}
AppCleanerUninstaller.buttonValid = function(title)
  return function(app)
    local winUI = towinui(app:focusedWindow())
    local sg = getc(winUI, AX.SplitGroup, 1)
    if sg == nil then return false end
    local locTitle = T(title, app)
    local button = tfind(getc(sg, AX.Button), function(bt)
      return bt.AXIdentifier == "uaid:RemoveSelectedItemsButton"
          and bt.AXTitle == locTitle and bt.AXEnabled
    end)
    return button ~= nil, button
  end
end

AppCleanerUninstaller.confirmButtonValid = function(title)
  return function(app)
    local winUI = towinui(app:focusedWindow())
    local cancel = tfind(getc(winUI, AX.Button), function(bt)
      return bt.AXIdentifier == "uaid:RemoveDialogSecondButton" and bt.AXEnabled
    end)
    if cancel == nil then return false end
    local locTitle = T(title, app)
    local button = getc(winUI, AX.StaticText, locTitle)
    return Callback.Clickable(button)
  end
end

--- ## WeChat
local WeChat = {}
WeChat.WF = {
  Main = {
    fn = function(win)
      if Version.GreaterEqual(win, "4") then
        local view1 = getc(towinui(win), AX.Group, 1, AX.Button, 1)
        return view1 and view1.AXTitle == win:title()
      else
        local view1 = getc(towinui(win), AX.RadioButton, 1)
        return view1 and view1.AXDescription == T("Tabbar.Chats", win)
      end
    end
  },
  Moments = {
    fn = function(win)
      local app = win:application()
      local title = win:title()
      if title:find(app:name()) == nil then
        if Version.GreaterEqual(app, "4.0.6") then
          local moments = findMenuItemByKeyBinding(app, "⌘", "4", "Window")
          return moments and title == moments[2]
        elseif Version.GreaterEqual(app, "4") then
          return title == T("Moments", win)
        else
          local album = T("Album_WindowTitle", win)
          local moments = T("SNS_Feed_Window_Title", win)
          local detail = T("SNS_Feed_Detail_Title", win)
          return title:find(album .. '-') == 1
              or title == moments .. '-' .. detail
        end
      end
    end
  },
  Preview = { },
  AppEx = {
    fn = function(win)
      local app = win:application()
      local appLocale = applicationLocale(app:bundleID())
      local exBundleID = "com.tencent.flue.WeChatAppEx"
      local params = { locale = appLocale }
      local menuItemPath = {
        localizedMenuBarItem("Window", exBundleID, params),
        localizedString("Select Previous Tab", exBundleID, params)
      }
      if menuItemPath[2] then
        local menuItem = app:findMenuItem(menuItemPath)
        return menuItem ~= nil
      end
    end
  },
  AppExWeb = {
    fn = function(win)
      if Version.LessThan(win, "4") then
        local g = getc(towinui(win), AX.Group, 1)
        return g ~= nil and g.AXDOMClassList ~= nil
      else
        local bt = getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Group, 1, AX.Group, 1, nil, 1)
        return bt ~= nil
            and (bt.AXRole == AX.Button or bt.AXRole == AX.PopUpButton)
      end
    end
  },
  AppExSingleTab = {
    fn = function(win)
      local exBundleID = "com.tencent.flue.WeChatAppEx"
      local appLocale = applicationLocale(win:application():bundleID())
      local menuItemPath = {
        localizedMenuBarItem('File', exBundleID, { locale = appLocale }),
        localizedString('Close All Tabs', exBundleID, { locale = appLocale })
      }
      if menuItemPath[2] then
        local menuItem = win:application():findMenuItem(menuItemPath)
        if menuItem == nil or not menuItem.enabled then return false end
      end
      menuItemPath[2] = localizedString('Close Tab', exBundleID,
                                        { locale = appLocale })
      if menuItemPath[2] then
        local menuItem = win:application():findMenuItem(menuItemPath)
        return menuItem and not menuItem.enabled
      end
    end
  },
  Confirm = {
    allowSheet = true,
    fn = function(win)
      local winUI = towinui(win)
      if #winUI == 4 then
        return winUI[1].AXRole == AX.StaticText
          and winUI[3].AXRole == AX.Button
          and winUI[4].AXRole == AX.Button
          and winUI[4].AXEnabled
      elseif #winUI == 3 then
        return winUI[1].AXRole == AX.StaticText
        and winUI[2].AXRole == AX.StaticText
        and winUI[3].AXRole == AX.Button
        and winUI[3].AXEnabled
      elseif #winUI == 1 then
        repeat
          winUI = winUI[1]
        until #winUI ~= 1
        return #winUI == 3
          and winUI[1].AXRole == AX.StaticText
          and winUI[2].AXRole == AX.Button
          and winUI[3].AXRole == AX.Button
          and winUI[3].AXEnabled
      else
        local title = localizedString("Send To", win)
        if type(title) ~= 'table' then
          title = { title }
        end
        for _, t in ipairs(title) do
          local text = getc(winUI, AX.StaticText, 1)
          if text and text.AXValue == t
              and winUI[#winUI].AXRole == AX.Button then
            return true
          end
        end
        return false
      end
    end
  },
  ConfirmDefault = { allowSheet = true },
  SendTo = {
    allowSheet = true,
    fn = function(win)
      local winUI = towinui(win)
      local title = T("Send", win)
      local bt = getc(winUI, AX.Button, title)
      if bt == nil then
        title = localizedString("Send To (%d)", win)
        if type(title) ~= 'table' then
          title = { title }
        end
        for _, t in ipairs(title) do
          t = t:gsub("%(%%d%)", "%%(%%d%%)")
          bt = tfind(getc(winUI, AX.Button), function(b)
            return b.AXTitle:match(t)
          end)
          if bt then break end
        end
      end
      return bt ~= nil
    end
  }
}
Evt.OnRunning("com.tencent.xinWeChat", function(app)
  local title = T("Preview", app)
  WeChat.WF.Preview.allowTitles = '^' .. title .. '$'
end)

--- ### QQLive
local QQLive = {}
QQLive.WF = {}
QQLive.WF.Main = {
  fn = function(win)
    local winUI = towinui(win)
    local text = getc(winUI, AX.Group, 2, nil, -1)
    return text and text.AXValue == "全部频道"
  end
}
QQLive.channelName = function(index)
  return function(win)
    local QQLiveChannelNames = appBuf.QQLiveChannelNames or {}
    if #QQLiveChannelNames == 0 then
      local list = getc(towinui(win), AX.Group, 2)
      if list == nil or #list == 0 then return end
      local start
      local verticalOffset, verticalOffsetChangeIdx
      for i=2,#list do
        local offset = list[i].AXPosition.y - list[i-1].AXPosition.y
        if offset ~= verticalOffset then
          verticalOffset = offset
          verticalOffsetChangeIdx = i - 1
        elseif i - verticalOffsetChangeIdx >= 5 then
          start = verticalOffsetChangeIdx
          break
        end
      end
      if start == nil then return end
      for i = 1, 10 do
        if #list - 2 >= start + i - 1 then
          local row = list[start + i - 1]
          tinsert(QQLiveChannelNames, row.AXValue)
        end
      end
      appBuf.QQLiveChannelNames = QQLiveChannelNames
    end
    return QQLiveChannelNames[index]
  end
end

QQLive.getChannel = function(index)
  return function(win)
    local list = getc(towinui(win), AX.Group, 2)
    if list == nil or #list == 0 then return false end
    local start
    local verticalOffset, verticalOffsetChangeIdx
    for i=2,#list do
      local offset = list[i].AXPosition.y - list[i-1].AXPosition.y
      if offset ~= verticalOffset then
        verticalOffset = offset
        verticalOffsetChangeIdx = i - 1
      elseif i - verticalOffsetChangeIdx >= 5 then
        start = verticalOffsetChangeIdx
        break
      end
    end
    if start == nil then return false end
    if #list - 2 >= start + index - 1 then
      local row = list[start + index - 1]
      if row.AXPosition.y > list.AXPosition.y
          and row.AXPosition.y + row.AXSize.h < list[#list].AXPosition.y - 15 then
        return Callback.Clickable(row)
      elseif row.AXPosition.y <= list.AXPosition.y
          and row.AXPosition.y + row.AXSize.h > list.AXPosition.y then
        return Callback.Clickable(row, { row.AXSize.w / 2, row.AXSize.h })
      elseif row.AXPosition.y + row.AXSize.h >= list[#list].AXPosition.y - 15
          and row.AXPosition.y < list[#list].AXPosition.y - 15 then
        return Callback.Clickable(row, { row.AXSize.w / 2, 0 })
      end
    end
    return false
  end
end

--- ### Yuanbao
local Yuanbao = {}
Yuanbao.WF = {}
Yuanbao.WF.Main = {}
Evt.OnRunning("com.tencent.yuanbao", function(app)
  local title
  title = Version.LessThan(app, "2.48") and "Tencent Yuanbao" or "Yuanbao"
  title = T(title, app)
  Yuanbao.WF.Main.allowTitles = '^' .. title .. '$'
end)

--- ### EuDic
local EuDic = {}
EuDic.WF = {}
EuDic.WF.Main = { allowRoles = AX.StandardWindow }
Evt.OnRunning("com.eusoft.freeeudic", function(app)
  local title = T("欧路词典", app)
  EuDic.WF.Main.allowTitles = '^' .. title .. '$'
end)

--- ### Parallels Desktop
local Parallels = {}
Parallels.WF = {}
Parallels.WF.ControlCenter = {}
Evt.OnRunning("com.parallels.desktop.console", function(app)
  local title = T("Control Center", app)
  Parallels.WF.ControlCenter.allowTitles = '^' .. title .. '$'
end)

--- ### Barrier
local Barrier = {}
Barrier.localizedMessage = function(message, params)
  return function(app)
    local locale = type(params) == 'table' and params.locale or nil
    local appid = getAppId(app)
    local newParams = params
    if locale == nil and hs.application.frontmostApplication():bundleID() == appid then
      locale = appBuf.barrierLocale
      if locale == nil then
        locale = applicationLocale(appid)
        appBuf.barrierLocale = locale
      end
      if type(newParams) == 'table' then
        newParams = tcopy(newParams)
        newParams.locale = locale
      elseif type(newParams) == 'string' then
        newParams = { localeFile = newParams, locale = locale }
      else
        newParams = { locale = locale }
      end
    end
    local str = T(message, app, newParams)
    assert(type(str) == 'string')
    if message:find('&') then
      str = str:gsub("%(&%a%)", ""):gsub('&', '')
    end
    if message:sub(#message) == ':' then
      local len = utf8.len(str)
      if len then
        local lastChar = str:sub(utf8.offset(str, len))
        if lastChar == ':' or lastChar == '：' then
          str = str:sub(1, utf8.offset(str, len) - 1)
        end
      end
    end
    return str
  end
end

Barrier.localizedString = function(message, app, params)
  local locale = type(params) == 'table' and params.locale or nil
  local appid = getAppId(app)
  local newParams = params
  if locale == nil and hs.application.frontmostApplication():bundleID() == appid then
    locale = appBuf.barrierLocale
    if locale == nil then
      locale = applicationLocale(appid)
      appBuf.barrierLocale = locale
    end
    if type(newParams) == 'table' then
      newParams = tcopy(newParams)
      newParams.locale = locale
    elseif type(newParams) == 'string' then
      newParams = { localeFile = newParams, locale = locale }
    else
      newParams = { locale = locale }
    end
  end
  local str = T(message, app, newParams)
  assert(type(str) == 'string')
  if message:find('&') then
    str = str:gsub('&', "")
  end
  return str
end

-- ### Bartender
local Bartender = {}
Bartender.WF = {}
Bartender.WF.Bar = { allowTitles = "^Bartender Bar$" }
Bartender.barItemTitle = function(index, rightClick)
  return function(win)
    if winBuf.bartenderBarItemNames == nil then
      local winUI = towinui(win)
      local icons = getc(winUI, AX.ScrollArea, 1, AX.List, 1, AX.List, 1)
      local appnames = tmap(getc(icons, AX.Group), function(g)
        return getc(g, AX.Image, 1).AXDescription
      end)
      if #appnames == 0 then return end
      local app = win:application()
      if Version.LessThan(app, "6") or Version.GreaterEqual(app, "6.1.1") then
        local appid = app:bundleID()
        local _, items = hs.osascript.applescript(strfmt([[
          tell application id "%s" to list menu bar items
        ]], appid))
        local itemList = strsplit(items, "\n")
        local splitterIndex = tindex(itemList, appid .. "-statusItem")
        local barSplitterIndex = tindex(appnames, app:name())
        if barSplitterIndex ~= nil then
          splitterIndex = splitterIndex - (#appnames - (barSplitterIndex - 1))
        end
        winBuf:register(winUI, 'bartenderBarItemNames', {})
        winBuf:register(winUI, 'bartenderBarItemIDs', {})
        local missedItemCnt = 0
        if Version.LessThan(app, "5.5") then
          local plistPath = hs.fs.pathToAbsolute(strfmt(
              "~/Library/Preferences/%s.plist", appid))
          if plistPath ~= nil then
            local plist = hs.plist.read(plistPath)
            local allwaysHidden = get(plist, "ProfileSettings",
                "activeProfile", "AlwaysHide")
            local itemIDIdx = splitterIndex + #appnames
            while tcontain(allwaysHidden, itemList[itemIDIdx])
                and itemIDIdx > splitterIndex do
              itemIDIdx = itemIDIdx - 1
            end
            missedItemCnt = #appnames - (itemIDIdx - splitterIndex)
          end
        end
        if missedItemCnt == 0 then
          for i = 1, #appnames do
            local appname = appnames[i]
            local itemID
            if Version.LessThan(app, "5.5") then
              itemID = itemList[splitterIndex + 1 + #appnames - i]
            else
              itemID = itemList[splitterIndex - 1 - #appnames + i]
            end
            local id, idx = itemID:match("(.-)%-Item%-(%d+)$")
            if id ~= nil then
              if idx == "0" then
                tinsert(winBuf.bartenderBarItemNames, appname)
              else
                tinsert(winBuf.bartenderBarItemNames,
                    strfmt("%s (Item %s)", appname, idx))
              end
              tinsert(winBuf.bartenderBarItemIDs, itemID)
            else
              local appByName = find(appname)
              if appByName == nil or
                  appByName:bundleID() ~= itemID:sub(1, #appByName:bundleID()) then
                tinsert(winBuf.bartenderBarItemNames, appname)
                tinsert(winBuf.bartenderBarItemIDs, itemID)
              elseif appByName ~= nil then
                local itemShortName = itemID:sub(#appByName:bundleID() + 2)
                tinsert(winBuf.bartenderBarItemNames,
                    strfmt("%s (%s)", appname, itemShortName))
                tinsert(winBuf.bartenderBarItemIDs, itemID)
              end
            end
          end
        else
          for i = 1, #appnames do
            tinsert(winBuf.bartenderBarItemNames, appnames[i])
            tinsert(winBuf.bartenderBarItemIDs, i)
          end
        end
      elseif #appnames > 0 then
        winBuf:register(winUI, 'bartenderBarItemNames', {})
        winBuf:register(winUI, 'bartenderBarItemIDs', {})
        local alwaysHiddenBar = false
        for _, appname in ipairs(appnames) do
          local hint = appname
          if hint == "Passwords" then
            hint = "com.apple.Passwords.MenuBarExtra"
          end
          local app = find(hint, true)
          if app then
            local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
            local iconAlwaysHiddenPosition = -7000
            local alWaysHiddenMenuBarItems = tifilter(menuBarItems, function(item)
              return item.AXPosition.x < iconAlwaysHiddenPosition
            end)
            if #alWaysHiddenMenuBarItems == #menuBarItems then
              alwaysHiddenBar = true
              break
            end
          end
        end
        for i, appname in ipairs(appnames) do
          local msg = appname
          local hint = appname
          if hint == "Passwords" then
            hint = "com.apple.Passwords.MenuBarExtra"
          end
          local app = find(hint, true)
          if app then
            msg = app:name()
            local indicesForHidden = {}
            for j, name in ipairs(appnames) do
              if name == appname then
                tinsert(indicesForHidden, j)
              end
            end
            local thisIndex = tindex(indicesForHidden, i)
            local map = loadStatusItemsAutosaveName(app)
            if map then
              local iconAlwaysHiddenPosition = -7000
              local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
              if not alwaysHiddenBar then
                local alWaysHiddenMenuBarItems = tifilter(menuBarItems, function(item)
                  return item.AXPosition.x < iconAlwaysHiddenPosition
                end)
                thisIndex = thisIndex + #alWaysHiddenMenuBarItems
              end
              local autosaveName = map[thisIndex]
              if not (autosaveName == "Item-0" and #menuBarItems == 1) then
                msg = msg..'-'..autosaveName
              end
            end
            tinsert(winBuf.bartenderBarItemNames, msg)
            tinsert(winBuf.bartenderBarItemIDs, i)
          end
        end
      end
    end
    if winBuf.bartenderBarItemNames ~= nil and index <= #winBuf.bartenderBarItemNames then
      return (rightClick and "Right-click " or "Click ")
          .. winBuf.bartenderBarItemNames[index]
    end
  end
end

Bartender.clickBarItem = function(index, rightClick)
  return function(win)
    local appid = win:application():bundleID()
    local itemID = winBuf.bartenderBarItemIDs[index]
    if type(itemID) == 'string' then
      local script = strfmt('tell application id "%s" to activate "%s"',
          appid, winBuf.bartenderBarItemIDs[index])
      if rightClick then
        script = script .. " with right click"
      end
      hs.osascript.applescript(script)
      hs.timer.doAfter(0.1, function()
        hs.osascript.applescript(strfmt([[
          tell application id "%s" to toggle bartender
        ]], appid))
      end)
    else
      local winUI = towinui(find(appid):focusedWindow())
      local icon = getc(winUI, AX.ScrollArea, 1, AX.List, 1,
          AX.List, 1, AX.Group, itemID, AX.Image, 1)
      if icon ~= nil then
        local fn = rightClick and rightClickAndRestore or leftClickAndRestore
        fn(icon, win)
      end
    end
  end
end

Bartender.WF.Main = {}
Evt.OnRunning("com.surteesstudios.Bartender", function(app)
  if Version.LessThan(app, "6") then
    Bartender.WF.Main.allowTitles = app:name()
  else
    Bartender.WF.Main.fn = function(win)
      return getc(towinui(win), AX.Group, 1, AX.SplitGroup, 1,
          AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1) ~= nil
    end
  end
end)

Bartender.sidebarItemTitle = function(index)
  return function(win)
    local winUI = towinui(win)
    if Version.LessThan(win, "6") then
      local row = getc(winUI, AX.SplitGroup, 1, AX.ScrollArea, 1,
          AX.Outline, 1, AX.Row, index, AX.Cell, 1, AX.StaticText, 1)
      if row ~= nil then
        return row.AXValue
      end
    else
      local row = getc(winUI, AX.Group, 1, AX.SplitGroup, 1,
          AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1, AX.Row, index,
          AX.Cell, 1, AX.Unknown, 1)
      if row ~= nil then
        return row.AXAttributedDescription:getString()
      end
    end
  end
end

Bartender.sidebarItemSelectable = function(index)
  return function(win)
    local winUI = towinui(win)
    local row
    if Version.LessThan(win, "6") then
      row = getc(winUI, AX.SplitGroup, 1, AX.ScrollArea, 1,
          AX.Outline, 1, AX.Row, index)
    else
      row = getc(winUI, AX.Group, 1, AX.SplitGroup, 1,
          AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1, AX.Row, index)
    end
    return row ~= nil, row
  end
end

-- ### Barbee
local Barbee = {}
Barbee.WF = {}
Barbee.WF.Bar = {
  allowRoles = AX.SystemDialog,
  allowTitles = "^$",
  fn = function(win)
    local winUI = towinui(win)
    if #winUI == 1 and winUI[1].AXRole == AX.Group
        and #winUI[1] == #(getc(winUI[1], AX.Button) or {}) then
      return true
    end
    return false
  end
}
Barbee.barItemTitle = function(index)
  return function(win)
    if winBuf.barbeeBarItemNames == nil then
      local winUI = towinui(win)
      local buttons = getc(winUI, AX.Group, 1, AX.Button)
      winBuf:register(winUI, 'barbeeBarItemNames', tmap(buttons, function(bt)
        return bt.AXHelp
      end))
    end
    if winBuf.barbeeBarItemNames ~= nil and index <= #winBuf.barbeeBarItemNames then
      return "Click "
          .. winBuf.barbeeBarItemNames[#winBuf.barbeeBarItemNames + 1 - index]
    end
  end
end

Barbee.clickBarItem = function(index)
  return function(win)
    local button = getc(towinui(win), AX.Group, 1, AX.Button, -index)
    if button then Callback.Press(button) end
  end
end

-- ### Ice
local Ice = {}
Ice.WF = {}
Ice.WF.Bar = { allowTitles = "^Ice Bar$" }
Ice.barItemTitle = function(index)
  return function(win)
    if winBuf.IceBarItemNames == nil then
      local winUI = towinui(win)
      winBuf:register(winUI, 'IceBarItemNames', {})
      local buttons = getc(winUI, AX.Group, 1,
          AX.ScrollArea, 1, AX.Image) or {}
      local alwaysHiddenBar = false
      for _, button in ipairs(buttons) do
        local appname = button.AXAttributedDescription:getString()
        local hint = appname
        if hint == "Passwords" then
          hint = "com.apple.Passwords.MenuBarExtra"
        end
        local app = find(hint, true)
        if app then
          local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
          local alWaysHiddenMenuBarItems = {}
          local iconAlwaysHidden = getc(toappui(win:application()),
              AX.MenuBar, -1, AX.MenuBarItem, 3)
          if iconAlwaysHidden then
            alWaysHiddenMenuBarItems = tifilter(menuBarItems, function(item)
              return item.AXPosition.x < iconAlwaysHidden.AXPosition.x
            end)
          end
          if #alWaysHiddenMenuBarItems == #menuBarItems then
            alwaysHiddenBar = true
            break
          end
        end
      end
      for i, button in ipairs(buttons) do
        local appname = button.AXAttributedDescription:getString()
        local hint = appname
        if hint == "Passwords" then
          hint = "com.apple.Passwords.MenuBarExtra"
        end
        local msg = appname
        local app = find(hint, true)
        if app then
          msg = app:name()
          local indicesForHidden = {}
          for j, bt in ipairs(buttons) do
            if bt.AXAttributedDescription:getString() == appname then
              tinsert(indicesForHidden, j)
            end
          end
          local thisIndex = tindex(indicesForHidden, i)
          local map = loadStatusItemsAutosaveName(app)
          if map then
            local iconAlwaysHidden = getc(toappui(win:application()),
                AX.MenuBar, -1, AX.MenuBarItem, 3)
            local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
            if iconAlwaysHidden and not alwaysHiddenBar then
              local alWaysHiddenMenuBarItems = tifilter(menuBarItems, function(item)
                return item.AXPosition.x < iconAlwaysHidden.AXPosition.x
              end)
              thisIndex = thisIndex + #alWaysHiddenMenuBarItems
            end
            local autosaveName = map[thisIndex]
            if not (autosaveName == "Item-0" and #menuBarItems == 1) then
              msg = msg..'-'..autosaveName
            end
          end
        end
        tinsert(winBuf.IceBarItemNames, msg)
      end
    end
    return winBuf.IceBarItemNames[index]
  end
end

Ice.clickBarItem = function(index)
  return function(win)
    local button = getc(towinui(win), AX.Group, 1,
        AX.ScrollArea, 1, AX.Image, index)
    if button then
      leftClickAndRestore(button, win, 0.1)
    end
  end
end

Ice.WF.Main = {
  fn = function(win)
    return towinui(win).AXIdentifier == "SettingsWindow"
  end
}
Ice.sidebarItemTitle = function(index)
  return function(win)
    local row = getc(towinui(win), AX.Group, 1,
        AX.SplitGroup, 1, AX.Group, 1, AX.ScrollArea, 1,
        AX.Outline, 1, AX.Row, index + 1, AX.Cell, 1, AX.StaticText, 1)
    if row ~= nil then
      return row.AXValue
    end
  end
end

Ice.clickSidebarItem = function(index)
  return function(win)
    local row = getc(towinui(win), AX.Group, 1,
        AX.SplitGroup, 1, AX.Group, 1, AX.ScrollArea, 1,
        AX.Outline, 1, AX.Row, index + 1)
    if row then row.AXSelected = true end
  end
end

-- ### iBar
local iBar = {}
iBar.WF = {}
iBar.WF.Bar = {
  allowRoles = AX.SystemFloatingWindow,
  allowTitles = "^iBarmenu$"
}
iBar.barItemTitle = function(index)
  return function(win)
    local buttons = getc(towinui(win), AX.Button)
    if buttons and #buttons >= index then
      local ident = buttons[index].AXIdentifier
      local items = strsplit(ident, '/')
      local info = items[#items]
      items = strsplit(info, ' >>> ')
      local itemIdx, appid = items[1], items[2]
      local msg = find(appid):name()
      if itemIdx ~= "Item-0" then
        msg = msg .. ' (' .. itemIdx .. ')'
      end
      return "Click " .. msg
    end
  end
end

iBar.clickBarItem = function(index)
  return function(win)
    local button = getc(towinui(win), AX.Button, index)
    if button then
      Callback.Press(button)
    end
  end
end

-- ### PasswordsMenuBarExtra
local PasswordsMenuBarExtra = {}
PasswordsMenuBarExtra.WF = {
  allowRoles = AX.SystemDialog,
  allowTitles = "^$"
}

PasswordsMenuBarExtra.recordPosition = function(index)
  return function(win)
    local winUI = towinui(win)
    local searchField = getc(winUI, AX.Group, 1, AX.TextField, 1)
    if searchField ~= nil then
      local row
      if OS_VERSION >= OS.Tahoe then
        row = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
            AX.ScrollArea, 1, AX.Outline, 1, AX.Row, index)
      else
        row = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
            AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1, AX.Row, index)
      end
      return Callback.Clickable(row)
    end
    return false
  end
end

PasswordsMenuBarExtra.recordField = function(fieldTitle)
  return function(win)
    local winUI = towinui(win)

    if OS_VERSION > OS.Tahoe or
        (OS_VERSION == OS.Tahoe and hs.host.operatingSystemVersion().minor >= 1) then
      local fieldValues = getc(winUI, AX.Group, 1,
          AX.ScrollArea, 1, AX.Group, 1, AX.StaticText)
      if fieldValues == nil then return false end
      local title = T(fieldTitle, win)
      for i=1,#fieldValues,2 do
        local titleElem = fieldValues[i]
        if titleElem.AXValue == title then
          return Callback.Clickable(fieldValues[i + 1])
        end
      end
      return false
    end

    local outline
    if OS_VERSION >= OS.Tahoe then
      outline = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
          AX.ScrollArea, 1, AX.Outline, 1)
    else
      outline = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
          AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1)
    end
    if outline == nil then return false end
    local title = T(fieldTitle, win)
    for _, row in ipairs(getc(outline, AX.Row)) do
      local cell = getc(row, AX.Cell, 1)
      local titleElem = getc(cell, AX.StaticText, 1)
      if titleElem and titleElem.AXValue == title then
        return Callback.Clickable(getc(cell, AX.StaticText, 2))
      end
    end
    return false
  end
end

-- ### iCopy
local iCopy = {}

iCopy.selectHotkeyRemap = function(idx)
  return function(win)
    local iCopyMod = Version.LessThan(win, "1.1.1") and "" or "⌃"
    hs.eventtap.keyStroke(iCopyMod, tostring(idx), nil, win:application())
  end
end

iCopy.WF = {}
iCopy.WF.Main = {
  allowRegions = {
    hs.geometry.rect(
        0, hs.screen.mainScreen():fullFrame().y
           + hs.screen.mainScreen():fullFrame().h - 400,
        hs.screen.mainScreen():fullFrame().w, 400)
  }
}

-- ### browsers
local Web = {}

local function getTabSource(app)
  local ok, source
  if app:bundleID() == "com.apple.Safari" then
    ok, source = hs.osascript.applescript([[
      tell application id "com.apple.Safari"
        do JavaScript "document.body.innerHTML" in front document
      end tell
    ]])
  else  -- assume chromium-based browsers
    ok, source = hs.osascript.applescript(strfmt([[
      tell application id "%s"
        execute active tab of front window ¬
            javascript "document.documentElement.outerHTML"
      end tell
    ]], app:bundleID()))
  end
  if ok then return source end
end

local function getTabUrl(app)
  local ok, url
  if app:bundleID() == "com.apple.Safari" then
    ok, url = hs.osascript.applescript([[
      tell application id "com.apple.Safari" to get URL of front document
    ]])
  else  -- assume chromium-based browsers
    ok, url = hs.osascript.applescript(strfmt([[
      tell application id "%s" to get URL of active tab of front window
    ]], app:bundleID()))
  end
  if ok and url then
    if url:sub(-2) == '//' then url = url:sub(1, -2) end
    return url
  end
end

local function setTabUrl(app, url)
  if app:bundleID() == "com.apple.Safari" then
    hs.osascript.applescript(strfmt([[
      tell application id "com.apple.Safari"
        set URL of front document to "%s"
      end tell
    ]], url))
  else  -- assume chromium-based browsers
    hs.osascript.applescript(strfmt([[
      tell application id "%s"
        set URL of active tab of front window to "%s"
      end tell
    ]], app:bundleID(), url))
  end
end

Web.Weibo = {}
Web.Weibo.sideBarTitle = function(idx, isCommon)
  return function(win)
    if isCommon and appBuf.weiboSideBarCommonGroupTitles then
      return appBuf.weiboSideBarCommonGroupTitles[idx]
    elseif not isCommon and appBuf.weiboSideBarCustomGroupTitles then
      return appBuf.weiboSideBarCustomGroupTitles[idx]
    end
    local weiboSideBarTitles, weiboSideBarURLs = {}, {}
    local app = win:application()
    local source = getTabSource(app)
    if source == nil then return end
    local start, stop
    if isCommon then
      local header = [[<h2 class="[^>]-_title_[^>]-">首页</h2>]]
      local tailer = [[<div class="[^>]-woo%-divider%-[^>]-">]]
      _, start = source:find(header)
      if start == nil then
        hs.timer.usleep(1 * 1000000)
        source = getTabSource(app)
        if source == nil then return end
        _, start = source:find(header)
      end
      if start == nil then return end
      stop = source:find(tailer, start + 1) or source:len()
    else
      local header = [[<h3 class="[^>]-_title_[^>]-">自定义分组</h3>]]
      local tailers = {
        [[<span class="[^>]-">展开</span></span></button>]],
        [[<span class="[^>]-">收起</span></span></button>]]
      }
      _, start = source:find(header)
      if start == nil then
        hs.timer.usleep(1 * 1000000)
        source = getTabSource(app)
        if source == nil then return end
        _, start = source:find(header)
      end
      if start == nil then return end
      stop = source:find(tailers[1], start + 1) or
          source:find(tailers[2], start + 1) or source:len()
    end
    source = source:sub(start + 1, stop - 1)
    if isCommon then
      local url, title = source:match(
          [[<a href="/(.-)"[^>]-><div role="link" title="(.-)"]])
      tinsert(weiboSideBarTitles, title)
      tinsert(weiboSideBarURLs, url)
    end
    for url, title in source:gmatch(
        [[<a href="/(mygroups.-)"[^>]-><div role="link" title="(.-)"]]) do
      tinsert(weiboSideBarTitles, title)
      tinsert(weiboSideBarURLs, url)
    end
    if isCommon then
      appBuf.weiboSideBarCommonGroupTitles = weiboSideBarTitles
      appBuf.weiboSideBarCommonGroupURLs = weiboSideBarURLs
    else
      appBuf.weiboSideBarCustomGroupTitles = weiboSideBarTitles
      appBuf.weiboSideBarCustomGroupURLs = weiboSideBarURLs
    end
    return weiboSideBarTitles[idx]
  end
end

Web.Weibo.navigateToSideBarCondition = function(idx, isCommon)
  return function()
    if isCommon and appBuf.weiboSideBarCommonGroupURLs
        and #appBuf.weiboSideBarCommonGroupURLs >= idx then
      return true, appBuf.weiboSideBarCommonGroupURLs[idx]
    elseif not isCommon and appBuf.weiboSideBarCustomGroupURLs
        and #appBuf.weiboSideBarCustomGroupURLs >= idx then
      return true, appBuf.weiboSideBarCustomGroupURLs[idx]
    end
    return false
  end
end

Web.Weibo.navigateToSideBar = function(url, result, win)
  local schemeEnd = url:find("//")
  local domainEnd = url:find("/", schemeEnd + 2)
  local fullUrl = url:sub(1, domainEnd) .. result
  setTabUrl(win:application(), fullUrl)
end

Web.Douyin = {}
Web.Douyin.tabTitle = function(idx)
  return function(win)
    if appBuf.douyinTabTitles then return appBuf.douyinTabTitles[idx] end
    appBuf.douyinTabTitles, appBuf.douyinTabURLs = {}, {}
    local app = win:application()
    local source = getTabSource(app)
    if source == nil then return end
    local lastURL = ""
    for url, title in source:gmatch(
        [[<div class="tab\-[^>]-><a href="(.-)".-<span class=".-">(.-)</span>]]) do
      if url ~= lastURL then
        tinsert(appBuf.douyinTabTitles, title)
        tinsert(appBuf.douyinTabURLs, url)
      end
      lastURL = url
    end
    return appBuf.douyinTabTitles[idx]
  end
end

Web.Douyin.navigateToTabCondition = function(idx)
  return function()
    if appBuf.douyinTabURLs and #appBuf.douyinTabURLs >= idx then
      return true, appBuf.douyinTabURLs[idx]
    end
    return false
  end
end

Web.Douyin.navigateToTab = function(url, result, win)
  local fullUrl
  if result:sub(1, 2) == '//' then
    local schemeEnd = url:find("//")
    fullUrl = url:sub(1, schemeEnd - 1) .. result
  else
    fullUrl = result
  end
  setTabUrl(win:application(), fullUrl)
end

-- ## functin utilities for hotkey configs

-- Fetch menu item title as a hotkey message by key binding.
--
-- This helper is mainly used to:
--   - Derive user-facing hotkey descriptions from menu key bindings
--   - Keep displayed messages consistent with the application's menu
local MenuItem = {}
-- fetch title of menu item as hotkey message by key binding
MenuItem.message = function(mods, key, titleIndex, menuBarItemTitle)
  return function(app)
    if type(titleIndex) == 'string' then
      menuBarItemTitle = titleIndex
      titleIndex = nil
    end
    local menuItem = findMenuItemByKeyBinding(app, mods, key, menuBarItemTitle)
    if menuItem == nil then return end
    if type(titleIndex) == 'number' then
      return menuItem[titleIndex]
    elseif type(titleIndex) == 'table' then
      local str = menuItem[titleIndex[1]]
      for i=2,#titleIndex do
        str = str .. ' > ' .. menuItem[titleIndex[i]]
      end
    else
      local str = menuItem[2]
      for i=3,#menuItem do
        str = str .. ' > ' .. menuItem[i]
      end
      return str
    end
  end
end

-- Check whether a specified menu item path is currently enabled.
--
-- This function is commonly used as a hotkey condition:
--   - It tests menu availability at runtime
--   - It does NOT trigger the menu item
--
-- If an enabled menu item is found:
--   returns true, localizedMenuPath
-- Otherwise:
--   returns false
MenuItem.isEnabled = function(menuItemTitle, params, ...)
  local args = { menuItemTitle, params, ... }
  params = nil
  if #args > 0 and (type(args[#args]) == 'string' or #args[#args] == 0) then
    params = args[#args]
    args[#args] = nil
  end
  return function(app)
    if app.application then app = app:application() end
    for _, title in ipairs(args) do
      local menuItem, locTitle = findMenuItem(app, title, params)
      if menuItem ~= nil and menuItem.enabled then
        return true, locTitle
      end
    end
    return false
  end
end

-- possible reasons for failure of hotkey condition-- Possible reasons for hotkey condition failure.
--
CF = {
  noMenuItemMatchKeybinding = 0,
  uIElementNotFocused       = 1,
  rightMenubarItemSelected  = 2,
  leftMenubarItemSelected   = 3,
  nonEmptyTextFieldFocused  = 4,
  userConditionFail         = 5,
}

-- Check whether a menu item associated with a specific key binding
-- is currently enabled.
--
-- This differs from MenuItem.isEnabled in that:
--   - The menu item is identified by its key binding
--   - The check is closer to the actual shortcut behavior
MenuItem.keybindingEnabled = function(mods, key, menuBarItemTitle)
  return function(app)
    local menuItem, enabled = findMenuItemByKeyBinding(app, mods, key, menuBarItemTitle)
    if menuItem ~= nil and enabled then
      return true, menuItem
    else
      return false, CF.noMenuItemMatchKeybinding
    end
  end
end

-- Select a menu item path returned by a hotkey condition.
--
-- This function is designed to be used directly as a hotkey callback.
-- It ensures:
--   - The correct menu bar item is activated if necessary
--   - The final menu item is selected reliably
--
-- The input menuItemTitle must be a valid menu path,
-- typically returned by MenuItem.isEnabled or MenuItem.keybindingEnabled.
Callback.Select = function(menuItemTitle, app)
  if app.application then app = app:application() end
  if #menuItemTitle == 0 then
    app:selectMenuItem(menuItemTitle)
    return
  end
  local menuBarItem = getc(toappui(app), AX.MenuBar, 1,
      AX.MenuBarItem, menuItemTitle[1])
  local menuItem = menuBarItem
  for i=2,#menuItemTitle do
    menuItem = getc(menuItem, AX.Menu, 1, AX.MenuItem, menuItemTitle[i])
  end
  if #menuItem ~= 0 and menuBarItem.AXSelected == false then
    app:selectMenuItem({ menuItemTitle[1] })
  end
  app:selectMenuItem(menuItemTitle)
end


-- ## hotkey configs for apps

-- hotkey configs that cound be used in various application
local specialCommonHotkeyConfigs = {
  ["closeWindow"] = {
    mods = "⌘", key = "W",
    message = TC("Close Window"),
    condition = function(app)
      local win = app:focusedWindow()
      return win ~= nil and win:role() == AX.Window, win
    end,
    repeatable = true,
    fn = function(win) win:close() end
  },
  ["minimize"] = {
    mods = "⌘", key = "M",
    message = TC("Minimize"),
    condition = function(app)
      local win = app:focusedWindow()
      return win ~= nil and win:role() == AX.Window, win
    end,
    repeatable = true,
    fn = function(win) win:minimize() end
  },
  ["hide"] = {
    mods = "⌘", key = "H",
    message = TC("Hide"),
    fn = function(app) app:hide() end
  },
  ["quit"] = {
    mods = "⌘", key = "Q",
    message = TC("Quit"),
    fn = function(app) app:kill() end
  },
  ["showPrevTab"] = {
    mods = "⇧⌘", key = "[",
    message = MenuItem.message('⇧⌃', "⇥"),
    condition = MenuItem.keybindingEnabled('⇧⌃', "⇥"),
    repeatable = true,
    fn = Callback.Select
  },
  ["showNextTab"] = {
    mods = "⇧⌘", key = "]",
    message = MenuItem.message('⌃', "⇥"),
    condition = MenuItem.keybindingEnabled('⌃', "⇥"),
    repeatable = true,
    fn = Callback.Select
  },
}

local function specialCommonHotkeyConfigUpdated(hkID, newConfig)
  local config = tcopy(specialCommonHotkeyConfigs[hkID])
  for k, v in pairs(newConfig) do
    config[k] = v
  end
  return config
end

appHotKeyCallbacks = {
  ["com.apple.finder"] =
  {
    ["openRecent"] = {
      message = T("Recent Folders"),
      condition = MenuItem.isEnabled({ "Go", "Recent Folders" }),
      fn = Callback.Select
    },
    ["open1stSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open1stSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open1stSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(1),
      windowFilter = true,
      condition = Finder.getSidebarItem(1),
      fn = Finder.openSidebarItem
    },
    ["open2ndSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open2ndSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open2ndSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(2),
      windowFilter = true,
      condition = Finder.getSidebarItem(2),
      fn = Finder.openSidebarItem
    },
    ["open3rdSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open3rdSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open3rdSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(3),
      windowFilter = true,
      condition = Finder.getSidebarItem(3),
      fn = Finder.openSidebarItem
    },
    ["open4thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open4thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open4thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(4),
      windowFilter = true,
      condition = Finder.getSidebarItem(4),
      fn = Finder.openSidebarItem
    },
    ["open5thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open5thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open5thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(5),
      windowFilter = true,
      condition = Finder.getSidebarItem(5),
      fn = Finder.openSidebarItem
    },
    ["open6thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open6thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open6thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(6),
      windowFilter = true,
      condition = Finder.getSidebarItem(6),
      fn = Finder.openSidebarItem
    },
    ["open7thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open7thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open7thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(7),
      windowFilter = true,
      condition = Finder.getSidebarItem(7),
      fn = Finder.openSidebarItem
    },
    ["open8thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open8thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open8thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(8),
      windowFilter = true,
      condition = Finder.getSidebarItem(8),
      fn = Finder.openSidebarItem
    },
    ["open9thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open9thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open9thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(9),
      windowFilter = true,
      condition = Finder.getSidebarItem(9),
      fn = Finder.openSidebarItem
    },
    ["open10thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open10thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open10thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(10),
      windowFilter = true,
      condition = Finder.getSidebarItem(10),
      fn = Finder.openSidebarItem
    }
  },

  ["com.apple.ActivityMonitor"] =
  {
    ["search"] = {
      message = TC("Search"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUI = towinui(app:focusedWindow())
        local searchField = getc(winUI, AX.Toolbar, 1, AX.Group, 2, AX.TextField, 1)
        return Callback.Clickable(searchField, { 10, 2 })
      end,
      fn = Callback.Click
    }
  },

  ["com.apple.MobileSMS"] =
  {
    ["deleteConversation"] = {
      message = T("Delete Conversation…"),
      condition = function(app)
        local messageItems = Messages.messageItems(app)
        local desc = T('New Message', app)
        return tfind(messageItems or {}, function(msg)
          return msg.AXSelected == true and msg.AXDescription:sub(4) ~= desc
        end) ~= nil
      end,
      fn = function(app)
        local appUI = toappui(app)
        local button
        if OS_VERSION >= OS.Tahoe then
          if hs.host.operatingSystemVersion().minor >= 2 then
            button = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
                AX.Group, 1, AX.Group, 1, AX.Button, 2)
          else
            button = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
                AX.Group, 1, AX.Group, 1, AX.Button, 2)
          end
        else
          button = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
              AX.Group, 2, AX.Group, 1, AX.Button, 2)
        end
        if button then
          Callback.Press(button)
        else
          local _, menuItem = findMenuItem(app, {
            OS_VERSION < OS.Ventura and "File" or "Conversation",
            "Delete Conversation…"
          })
          app:selectMenuItem(menuItem)
        end
      end
    },
    ["deleteAllConversations"] = {
      message = T("Delete All"),
      condition = Messages.deletable,
      fn = Messages.deleteAll
    },
    ["goToPreviousConversation"] = {
      message = MenuItem.message('⇧⌃', "⇥", "Window"),
      condition = function(app)
        local messageItems = Messages.messageItems(app)
        local desc = T('New Message', app)
        if messageItems == nil or #messageItems == 0
            or (#messageItems == 1 and (messageItems[1].AXDescription == nil
              or messageItems[1].AXDescription:sub(4) == desc)
              or messageItems[1].AXValue ~= nil) then
          return false
        end
        if #messageItems == 1 and messageItems[1].AXSelected then
          return false
        end
        for i=1,#messageItems do
          if messageItems[i].AXSelected then
            local prevIdx = i == 1 and #messageItems or (i - 1)
            return true, messageItems[prevIdx]
          end
        end
        return true, messageItems[#messageItems]
      end,
      repeatable = true,
      fn = Callback.Press
    },
    ["goToNextConversation"] = {
      message = MenuItem.message('⌃', "⇥", "Window"),
      condition = function(app)
        local messageItems = Messages.messageItems(app)
        local desc = T('New Message', app)
        if messageItems == nil or #messageItems == 0
            or (#messageItems == 1 and (messageItems[1].AXDescription == nil
              or messageItems[1].AXDescription:sub(4) == desc)
              or messageItems[1].AXValue ~= nil) then
          return false
        end
        if #messageItems == 1 and messageItems[1].AXSelected then
          return false
        end
        for i=1,#messageItems do
          if messageItems[i].AXSelected then
            local nextIdx = i == #messageItems and 1 or (i + 1)
            return true, messageItems[nextIdx]
          end
        end
        return true, messageItems[1]
      end,
      repeatable = true,
      fn = Callback.Press
    }
  },

  ["com.apple.mobilephone"] = {
    ["removeFromRecents"] = {
      message = T("Remove from Recents"),
      windowFilter = Phone.WF.Main,
      condition = FaceTime.hoveringOverCall,
      fn = FaceTime.deleteMousePositionCall
    },
    ["removeAllRecents"] = {
      message = T("Remove All Recents"),
      windowFilter = Phone.WF.Main,
      condition = FaceTime.hasCall,
      fn = FaceTime.deleteAll
    },
    ["newCall"] = {
      message = T("New Call"),
      windowFilter = Phone.WF.Main,
      fn = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 3, AX.Group, 1, AX.Button, 1)
        if button then Callback.Press(button) end
      end
    },
    ["view1"] = {
      message = T("Calls"),
      windowFilter = Phone.WF.Main,
      fn = Phone.selectView(1)
    },
    ["view2"] = {
      message = T("Missed"),
      windowFilter = Phone.WF.Main,
      fn = Phone.selectView(2)
    },
    ["view3"] = {
      message = T("Voicemail"),
      windowFilter = Phone.WF.Main,
      fn = Phone.selectView(3)
    }
  },

  ["com.apple.FaceTime"] = {
    ["removeFromRecents"] = {
      message = T("Remove from Recents"),
      windowFilter = FaceTime.WF.Main,
      condition = FaceTime.hoveringOverCall,
      fn = FaceTime.deleteMousePositionCall
    },
    ["removeAllRecents"] = {
      message = T("Remove All Recents"),
      windowFilter = FaceTime.WF.Main,
      condition = FaceTime.hasCall,
      fn = FaceTime.deleteAll
    },
    ["newFaceTime"] = {
      message = T("New FaceTime"),
      windowFilter = FaceTime.WF.Main,
      condition = function(win)
        local button
        if OS_VERSION < OS.Tahoe then
          button = getc(towinui(win), AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 1, AX.Button, 2)
        else
          button = getc(towinui(win), AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
              AX.Button, 2)
        end
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["addPeopleWhenNewFaceTime"] = {
      message = T("Add People"),
      windowFilter = {
        allowSheet = true,
        fn = function(win)
          local heading = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.Group, 1, AX.Heading, 1)
          return heading and heading.AXDescription == T("New FaceTime", win)
        end,
      },
      fn = function(win)
        local button = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Button, 1)
        if button then Callback.Press(button) end
      end
    },
    ["view1"] = {
      message = T("Calls"),
      bindCondition = function() return OS_VERSION >= OS.Tahoe end,
      windowFilter = FaceTime.WF.Main,
      fn = FaceTime.selectView(1)
    },
    ["view2"] = {
      message = T("Missed"),
      bindCondition = function() return OS_VERSION >= OS.Tahoe end,
      windowFilter = FaceTime.WF.Main,
      fn = FaceTime.selectView(2)
    },
    ["view3"] = {
      message = T("Video"),
      bindCondition = function() return OS_VERSION >= OS.Tahoe end,
      windowFilter = FaceTime.WF.Main,
      fn = FaceTime.selectView(3)
    },
    ["view4"] = {
      message = T("Voicemail"),
      bindCondition = function() return OS_VERSION >= OS.Tahoe end,
      windowFilter = FaceTime.WF.Main,
      fn = FaceTime.selectView(4)
    },
    ["view5"] = {
      message = T("Spam"),
      bindCondition = function() return OS_VERSION >= OS.Tahoe end,
      windowFilter = FaceTime.WF.Main,
      fn = FaceTime.selectView(5)
    }
  },

  ["com.apple.Photos"] = {
    ["view1"] = {
      message = MenuItem.message('⌃', '1', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '1', 'View'),
      fn = Callback.Select
    },
    ["view2"] = {
      message = MenuItem.message('⌃', '2', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '2', 'View'),
      fn = Callback.Select
    },
    ["view3"] = {
      message = MenuItem.message('⌃', '3', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '3', 'View'),
      fn = Callback.Select
    },
    ["view4"] = {
      message = MenuItem.message('⌃', '4', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '4', 'View'),
      fn = Callback.Select
    },
    ["view5"] = {
      message = MenuItem.message('⌃', '5', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '5', 'View'),
      fn = Callback.Select
    },
    ["view6"] = {
      message = MenuItem.message('⌃', '6', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '6', 'View'),
      fn = Callback.Select
    },
    ["view7"] = {
      message = MenuItem.message('⌃', '7', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '7', 'View'),
      fn = Callback.Select
    },
    ["view8"] = {
      message = MenuItem.message('⌃', '8', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '8', 'View'),
      fn = Callback.Select
    },
    ["view9"] = {
      message = MenuItem.message('⌃', '9', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '9', 'View'),
      fn = Callback.Select
    }
  },

  ["com.apple.Notes"] = {
    ["toggleFolders"] = {
      message = T("Show Folders"),
      bindCondition = function() return OS_VERSION < OS.Tahoe end,
      condition = MenuItem.isEnabled({ "View", "Show Folders" },
                                     { "View", "Hide Folders" }),
      fn = Callback.Select
    }
  },

  ["com.apple.iCal"] =
  {
    ["toggleCalendarList"] = {
      message = T("Show Calendar List"),
      condition = MenuItem.isEnabled({ "View", "Show Calendar List" },
                                     { "View", "Hide Calendar List" }),
      fn = Callback.Select
    }
  },

  ["com.apple.helpviewer"] = {
    ["back"] = {
      message = TC("Back"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local toolbar = getc(towinui(app:focusedWindow()), AX.Toolbar, 1)
        local button
        if toolbar and toolbar[1].AXRole == AX.Button then
          button = getc(toolbar, AX.Group, 1, AX.Group, 1, AX.Button, 1)
        else
          button = getc(toolbar, AX.Group, 2, AX.Group, 1, AX.Button, 1)
        end
        return button and button.AXEnabled, button
      end,
      fn = Callback.Press
    },
    ["forward"] = {
      message = TC("Forward"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local toolbar = getc(towinui(app:focusedWindow()), AX.Toolbar, 1)
        local button
        if toolbar and toolbar[1].AXRole == AX.Button then
          button = getc(toolbar, AX.Group, 1, AX.Group, 1, AX.Button, 2)
        else
          button = getc(toolbar, AX.Group, 2, AX.Group, 1, AX.Button, 2)
        end
        return button and button.AXEnabled, button
      end,
      fn = Callback.Press
    },
    ["home"] = {
      message = TG("house"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local toolbar = getc(towinui(app:focusedWindow()), AX.Toolbar, 1)
        local button
        if OS_VERSION >= OS.Tahoe then
          if toolbar and toolbar[1].AXRole == AX.Button then
            button = getc(toolbar, AX.Group, 2, AX.Group, 1, AX.Button, 1)
          else
            button = getc(toolbar, AX.Group, 3, AX.Group, 1, AX.Button, 1)
          end
        else
          button = getc(toolbar, AX.Button, 2)
        end
        return button and button.AXEnabled, button
      end,
      fn = Callback.Press
    },
    ["helpSearch"] = {
      message = T("Help Search"),
      condition = MenuItem.isEnabled({ "Edit", "Find", "Help Search" }),
      fn = Callback.Select
    }
  },

  ["com.apple.Music"] = {
    ["playCurrent"] = {
      message = T("Play"),
      windowFilter = Music.WF.Main,
      condition = function(win)
        local g = getc(towinui(win), AX.SplitGroup, 1,
            AX.ScrollArea, 2, AX.List, 1, AX.List, 1, AX.Unknown, 1)
            or getc(towinui(win), AX.SplitGroup, 1,
                AX.ScrollArea, 2, AX.Group, 1)
        local button = getc(g, AX.Button, A_Message)
            or getc(g, AX.Button, "Play")
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["view1"] = {
      message = Music.viewTitle(1),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(1)
    },
    ["view2"] = {
      message = Music.viewTitle(2),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(2)
    },
    ["view3"] = {
      message = Music.viewTitle(3),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(3)
    },
    ["view4"] = {
      message = Music.viewTitle(4),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(4)
    },
    ["view5"] = {
      message = Music.viewTitle(5),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(5)
    },
    ["view6"] = {
      message = Music.viewTitle(6),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(6)
    },
    ["view7"] = {
      message = Music.viewTitle(7),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(7)
    },
    ["view8"] = {
      message = Music.viewTitle(8),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(8)
    },
    ["view9"] = {
      message = Music.viewTitle(9),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(9)
    },
    ["view10"] = {
      message = Music.viewTitle(10),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(10)
    }
  },

  ["com.apple.games"] = {
    ["back"] = {
      message = TC("Back"),
      windowFilter = Games.WF.Main,
      condition = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1, AX.Button)
        local button = tfind(buttons or {}, function(bt)
          return bt.AXDescription == A_Message
        end)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["view1"] = {
      message = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 1 then
          return buttons[1].AXDescription
        end
      end,
      windowFilter = Games.WF.Main,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 1 then
          Callback.Press(buttons[1])
        end
      end
    },
    ["view2"] = {
      message = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 2 then
          return buttons[2].AXDescription
        end
      end,
      windowFilter = Games.WF.Main,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 2 then
          Callback.Press(buttons[2])
        end
      end
    },
    ["view3"] = {
      message = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 3 then
          return buttons[3].AXDescription
        end
      end,
      windowFilter = Games.WF.Main,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 3 then
          Callback.Press(buttons[3])
        end
      end
    },
    ["search"] = {
      message = TC("Search"),
      windowFilter = Games.WF.Main,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        local button = tfind(buttons or {}, function(bt)
          return bt.AXDescription == A_Message
        end)
        if button then Callback.Press(button) end
      end
    }
  },

  ["com.apple.weather"] = {
    ["toggleSidebar"] = {
      message = TC("Show Sidebar"),
      bindCondition = function()
        return OS_VERSION < OS.Tahoe
            or (OS_VERSION == OS.Tahoe and
            hs.host.operatingSystemVersion().minor == 0)
      end,
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local toolbar = getc(towinui(app:focusedWindow()), AX.Toolbar, 1)
        if OS_VERSION >= OS.Tahoe then
          if toolbar and #toolbar == 1 and toolbar[1].AXRole == AX.Button then
            return true, toolbar[1]
          end
        else
          if toolbar and #toolbar == 2 and toolbar[1].AXRole == AX.Button
              and toolbar[2].AXSubrole == AX.SearchField then
            return true, toolbar[1]
          end
        end
        return false
      end,
      fn = Callback.Press
    },
    ["previousLocation"] = {
      message = "Previous Location",
      condition = function(app)
        local list = Weather.getLocationList(app:focusedWindow()) or {}
        for i = 1, #list do
          local desc = list[i][1].AXDescription
          if (OS_VERSION < OS.Tahoe and list[i].AXSelected)
              or (desc:match('^'..app:focusedWindow():title()..', ')
                  or desc:match('^'..app:focusedWindow():title()..'、')) then
            return true, list[(i - 2) % #list + 1][1]
          end
        end
        return false
      end,
      fn = Callback.Press
    },
    ["nextLocation"] = {
      message = "Next Location",
      condition = function(app)
        local list = Weather.getLocationList(app:focusedWindow()) or {}
        for i = 1, #list do
          local desc = list[i][1].AXDescription
          if (OS_VERSION < OS.Tahoe and list[i].AXSelected)
              or (desc:match('^'..app:focusedWindow():title()..', ')
                  or desc:match('^'..app:focusedWindow():title()..'、')) then
            return true, list[i % #list + 1][1]
          end
        end
        return false
      end,
      fn = Callback.Press
    },
    ["deleteLocation"] = {
      message = T("Delete"),
      condition = function(app)
        local list = Weather.getLocationList(app:focusedWindow())
        if list then
          local selected = tfind(list, function(item)
            local desc = item[1].AXDescription
            return (OS_VERSION < OS.Tahoe and item.AXSelected)
                or (desc:match('^'..app:focusedWindow():title()..', ')
                    or desc:match('^'..app:focusedWindow():title()..'、'))
          end)
          return selected ~= nil, selected
        end
        return false
      end,
      fn = function(selected, app)
        selected:performAction(AX.ShowMenu)
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(toappui(app), uinotifications.menuOpened)
        observer:callback(A_HotkeyWrapper(function(obs, menu)
          local delete = getc(menu, AX.MenuItem, A_Message)
          if delete then
            Callback.Press(delete) obs:stop() obs = nil
          end
        end))
        observer:start()
        Evt.StopOnDeactivated(app, observer)
      end
    }
  },

  ["com.apple.AppStore"] =
  {
    ["back"] = {
      message = T("Back"),
      bindCondition = function() return OS_VERSION < OS.Tahoe end,
      condition = function(app)
        local menuItem, menuItemTitle = findMenuItem(app, { "Store", "Back" })
        if menuItem ~= nil and menuItem.enabled then
          return true, menuItemTitle
        else
          if app:focusedWindow() == nil then return false end
          local winUI = towinui(app:focusedWindow())
          local button
          button = getc(winUI, AX.SplitGroup, 1, AX.Group, 2, AX.Button, 1)
          if button ~= nil then return true, button end
          local g = getc(winUI, AX.Group, 1)
          if g == nil then return false end
          button = getc(g, AX.Button, "UIA.AppStore.NavigationBackButton")
              or getc(g, AX.Button, "AppStore.backButton")
          return button ~= nil, button
        end
      end,
      repeatable = true,
      fn = function(result, app)
        if type(result) == 'table' then
          app:selectMenuItem(result)
        else
          local button = result
          Callback.Press(button)
        end
      end
    }
  },

  ["com.apple.Safari"] =
  {
    ["toggleSidebar"] = {
      message = T("Show Sidebar"),
      condition = MenuItem.isEnabled({ "View", "Show Sidebar" },
                                     { "View", "Hide Sidebar" }),
      fn = Callback.Select
    },
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      windowFilter = { allowURLs = "^file://" },
      fn = function(url)
        hs.execute('open -R "' .. url .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    },
    ["openRecent"] = {
      message = T("Recently Closed"),
      condition = MenuItem.isEnabled({ "History", "Recently Closed" }),
      fn = Callback.Select
    }
  },

  ["com.apple.Preview"] =
  {
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    }
  },

  ["com.google.Chrome"] =
  {
    ["openRecent"] = {
      message = T("Search Tabs…"),
      condition = MenuItem.isEnabled({ "Tab", "Search Tabs…" }),
      fn = Callback.Select
    },
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      windowFilter = { allowURLs = "^file://" },
      fn = function(url)
        hs.execute('open -R "' .. url .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    }
  },

  ["com.microsoft.VSCode"] =
  {
    ["view:toggleOutline"] = {
      message = "View: Toggle Outline",
      windowFilter = VSCode.WF.Main,
      repeatable = true,
      fn = function(win)
        VSCode.toggleSideBarSection(win, "EXPLORER", "OUTLINE")
      end
    },
    ["view:toggleTimeline"] = {
      message = "View: Toggle Timeline",
      windowFilter = VSCode.WF.Main,
      repeatable = true,
      fn = function(win)
        VSCode.toggleSideBarSection(win, "EXPLORER", "TIMELINE")
      end
    },
    ["toggleSearchEditorWholeWord"] = {
      message = "Search Editor: Toggle Match Whole Word",
      windowFilter = VSCode.WF.Main,
      repeatable = true,
      fn = function(win) hs.eventtap.keyStroke("⌘⌥", "W", nil, win:application()) end
    },
    ["openRecent"] = {
      message = "Open Recent",
      condition = MenuItem.isEnabled({ "File", "Open Recent", "More…" },
                                     { "File", "Open Recent" }),
      fn = Callback.Select
    }
  },

  ["com.sublimetext.4"] =
  {
    ["toggleSearchEditorWholeWord"] = {
      message = "Search Editor: Toggle Match Whole Word",
      condition = function(app)
        if app:focusedWindow() == nil then
          return false
        else
          local winUI = towinui(app:focusedWindow())
          return winUI.AXIdentifier ~= "open-panel"
        end
      end,
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke("⌘⌥", "W", nil, app) end
    },
  },

  ["com.renfei.SnippetsLab"] =
  {
    ["showMainWindow"] = {
      message = T("Show Main Window"),
      condition = MenuItem.isEnabled({ "Window", "Show Main Window" }),
      fn = Callback.Select
    },
    ["moveFocusToSidebar"] = {
      message = T("Move Focus to Sidebar"),
      condition = MenuItem.isEnabled({ "View", "Move Focus to Sidebar" }),
      fn = Callback.Select
    },
    ["moveFocusToSnippetsList"] = {
      message = T("Move Focus to Snippets List"),
      condition = MenuItem.isEnabled({ "View", "Move Focus to Snippets List" }),
      fn = Callback.Select
    },
    ["moveFocusToEditor"] = {
      message = T("Move Focus to Editor"),
      condition = MenuItem.isEnabled({ "View", "Move Focus to Editor" }),
      fn = Callback.Select
    },
    ["moveFocusToPreview"] = {
      message = T("Move Focus to Preview"),
      condition = MenuItem.isEnabled({ "View", "Move Focus to Preview" }),
      fn = Callback.Select
    }
  },

  ["com.readdle.PDFExpert-Mac"] =
  {
    ["showInFinder"] = {
      message = T("Show in Finder"),
      condition = MenuItem.isEnabled({ "File", "Show in Finder" }),
      fn = Callback.Select
    },
    ["remapPreviousTab"] = {
      message = T("Go to Previous Tab"),
      condition = MenuItem.isEnabled({ "Window", "Go to Previous Tab" }),
      repeatable = true,
      fn = Callback.Select
    }
  },

  ["com.vallettaventures.Texpad"] =
  {
    ["toggleOutline"] = {
      message = T("Toggle Outline"),
      condition = MenuItem.isEnabled({ "Workspace", "Toggle Outline" }),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = T("Recent Documents"),
      condition = MenuItem.isEnabled({ "File", "Recent Documents" }),
      fn = Callback.Select
    }
  },

  ["abnerworks.Typora"] =
  {
    ["openFileLocation"] = {
      message = T("Open File Location"),
      condition = MenuItem.isEnabled({ "File", "Open File Location" }),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = T("Open Recent"),
      condition = MenuItem.isEnabled({ "File", "Open Quickly…" },
                                     { "File", "Open Recent" }),
      fn = Callback.Select
    }
  },

  ["com.superace.updf.mac"] =
  {
    ["goToHome"] = {
      message = T("Home"),
      windowFilter = {
        allowTitles = "",
        fn = function(win)
          local title = T("Home", win)
          if title == win:title() then return false end
          local image = getc(towinui(win), AX.TabGroup, 1,
              AX.Button, 1, AX.Image, 1)
          return image ~= nil
        end
      },
      fn = function(win)
        local button = getc(towinui(win), AX.TabGroup, 1, AX.Button, 1)
        if button then leftClickAndRestore(button, win) end
      end
    },
    ["toggleSidebar"] = {
      message = TC("Show Sidebar"),
      condition = function(app)
        local title = T("View", app)
        local menuItems = getc(toappui(app), AX.MenuBar, 1,
            AX.MenuBarItem, title, AX.Menu, 1, AX.MenuItem)
        local firstSidebarMenuItem
        for _, item in ipairs(menuItems or {}) do
          if item.AXTitle == "" then break end
          if #item == 0 then
            if item.AXMenuItemMarkChar then
              return item.AXEnabled, item
            end
            firstSidebarMenuItem = firstSidebarMenuItem or item
          end
        end
        return firstSidebarMenuItem ~= nil, firstSidebarMenuItem
      end,
      fn = Callback.Press
    },
    ["showPrevTab"] = specialCommonHotkeyConfigs["showPrevTab"],
    ["showNextTab"] = specialCommonHotkeyConfigs["showNextTab"],
    ["showInFinder"] = {
      message = T("Show in Finder"),
      condition = MenuItem.isEnabled({ "File", "Show in Finder" }),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = T("Open Quickly…"),
      condition = MenuItem.isEnabled({ "File", "Open Quickly…" }),
      fn = Callback.Select
    },
    ["openRecentFromMB"] = {
      message = TMB("Open Recent"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    },
    ["confirmDelete"] = {
      message = T("Don't Save"),
      condition = function(app)
        local win = app:focusedWindow()
        if win == nil then return false end
        local winUI = towinui(win)
        local button = getc(winUI, AX.Buttonm, A_Message)
            or getc(winUI, AX.Window, 1, AX.Button, A_Message)
        return button ~= nil, button
      end,
      fn = Callback.Press
    }
  },

  ["com.kingsoft.wpsoffice.mac"] =
  {
    ["previousWindow"] = specialCommonHotkeyConfigs["showPrevTab"],
    ["nextWindow"] = specialCommonHotkeyConfigs["showNextTab"],
    ["goToFileTop"] = {
      mods = "", key = "Home",
      message = "Cursor to Top",
      windowFilter = WPS.WF.NonHome,
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke("⌘", "Home", nil, app) end
    },
    ["goToFileBottom"] = {
      mods = "", key = "End",
      message = "Cursor to Bottom",
      windowFilter = WPS.WF.NonHome,
      fn = function(app) hs.eventtap.keyStroke("⌘", "End", nil, app) end
    },
    ["selectToFileTop"] = {
      mods = "⇧", key = "Home",
      message = "Select to Top",
      windowFilter = WPS.WF.NonHome,
      fn = function(app) hs.eventtap.keyStroke("⇧⌘", "Home", nil, app) end
    },
    ["selectToFileBottom"] = {
      mods = "⇧", key = "End",
      message = "Select to Bottom",
      windowFilter = WPS.WF.NonHome,
      fn = function(app) hs.eventtap.keyStroke("⇧⌘", "End", nil, app) end
    },
    ["properties"] = {
      message = T("Properties..."),
      windowFilter = WPS.WF.NonHome,
      condition = MenuItem.isEnabled({ "File", "Properties..." }),
      fn = Callback.Select
    },
    ["exportToPDF"] = {
      message = T("Export to PDF..."),
      windowFilter = WPS.WF.WPS_WPP_ET,
      condition = MenuItem.isEnabled({ "File", "Export to PDF..." }),
      fn = Callback.Select
    },
    ["insertTextBox"] = {
      message = T{"Insert", "Text Box"},
      windowFilter = WPS.WF.WPS_WPP,
      condition = MenuItem.isEnabled({ "Insert", "Text Box", "Horizontal Text Box" }),
      fn = Callback.Select
    },
    ["insertEquation"] = {
      message = T{"Insert", "LaTeXEquation..."},
      windowFilter = WPS.WF.WPS_WPP_ET,
      condition = MenuItem.isEnabled({ "Insert", "LaTeXEquation..." }),
      fn = Callback.Select
    },
    ["pdfHightlight"] = {
      message = T("Highlight"),
      windowFilter = WPS.WF.PDF,
      condition = MenuItem.isEnabled({ "Comment", "Highlight" }),
      fn = Callback.Select
    },
    ["pdfUnderline"] = {
      message = T("Underline"),
      windowFilter = WPS.WF.PDF,
      condition = MenuItem.isEnabled({ "Comment", "Underline" }),
      fn = Callback.Select
    },
    ["pdfStrikethrough"] = {
      message = T("Strikethrough"),
      windowFilter = WPS.WF.PDF,
      condition = MenuItem.isEnabled({ "Comment", "Strikethrough" }),
      fn = Callback.Select
    },
    ["goToHome"] = {
      message = T("Home"),
      windowFilter = WPS.WF.NonHome,
      fn = function(win)
        local winUI = towinui(win)
        local buttons = getc(winUI, AX.Button)
        local maxX = buttons[#buttons].AXPosition.x
        maxX = math.max(maxX, buttons[#buttons - 1].AXPosition.x)
        maxX = math.max(maxX, buttons[#buttons - 2].AXPosition.x)
        leftClickAndRestore({ maxX + 100, buttons[#buttons].AXPosition.y }, win)
      end
    },
    ["openRecent"] = {
      message = T("Recent"),
      fn = function(app)
        if app:focusedWindow() == nil then return end
        local home = T("Home", app)
        local winUI = towinui(app:focusedWindow())
        if app:focusedWindow():title() ~= home then
          local buttons = getc(winUI, AX.Button)
          local maxX = buttons[#buttons].AXPosition.x
          maxX = math.max(maxX, buttons[#buttons - 1].AXPosition.x)
          maxX = math.max(maxX, buttons[#buttons - 2].AXPosition.x)
          local mousePosition = hs.mouse.absolutePosition()
          local position = hs.geometry.point{ maxX + 100, buttons[#buttons].AXPosition.y }
          mouseDown(position)
          mouseUp(position)
          mouseMove(mousePosition)
          hs.timer.usleep(1000000)
        end
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine
        for i, g in ipairs(groups or {}) do
          if g.AXSize.h == 16 then
            firstSplitLine = i
            break
          end
        end
        if firstSplitLine == 4 then
          leftClickAndRestore(groups[1], app)
        end
      end,
    },
    ["goToShare"] = {
      message = T("Share"),
      windowFilter = WPS.WF.Home,
      condition = function(win)
        local winUI = towinui(win)
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine
        for i, g in ipairs(groups) do
          if g.AXSize.h == 16 then
            firstSplitLine = i
            break
          end
        end
        if firstSplitLine == 4 then
          return Callback.Clickable(groups[3])
        end
        return false
      end,
      fn = Callback.Click
    },
    ["goToMyCloudDocuments"] = {
      message = T("My Cloud Documents"),
      windowFilter = WPS.WF.Home,
      condition = function(win)
        local winUI = towinui(win)
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine, secondSplitLine
        for i, g in ipairs(groups) do
          if g.AXSize.h == 16 then
            if firstSplitLine == nil then
              firstSplitLine = i
            elseif secondSplitLine == nil then
              secondSplitLine = i
              break
            end
          end
        end
        if secondSplitLine == nil or (secondSplitLine - firstSplitLine > 2) then
          return Callback.Clickable(groups[firstSplitLine + 2])
        end
        return false
      end,
      fn = Callback.Click
    },
    ["goToMyDesktop"] = {
      message = T("My Desktop"),
      windowFilter = WPS.WF.Home,
      condition = function(win)
        local winUI = towinui(win)
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine, secondSplitLine, thirdSplitLine
        for i, g in ipairs(groups) do
          if g.AXSize.h == 16 then
            if firstSplitLine == nil then
              firstSplitLine = i
            elseif secondSplitLine == nil then
              secondSplitLine = i
            elseif thirdSplitLine == nil then
              thirdSplitLine = i
              break
            end
          end
        end
        if thirdSplitLine ~= nil and thirdSplitLine - secondSplitLine > 2 then
          return Callback.Clickable(groups[secondSplitLine + 2])
        end
        return false
      end,
      fn = Callback.Click
    },
    ["goToDocuments"] = {
      message = T("Documents"),
      windowFilter = WPS.WF.Home,
      condition = function(win)
        local winUI = towinui(win)
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine, secondSplitLine, thirdSplitLine
        for i, g in ipairs(groups) do
          if g.AXSize.h == 16 then
            if firstSplitLine == nil then
              firstSplitLine = i
            elseif secondSplitLine == nil then
              secondSplitLine = i
            elseif thirdSplitLine == nil then
              thirdSplitLine = i
              break
            end
          end
        end
        if thirdSplitLine ~= nil and thirdSplitLine - secondSplitLine > 3 then
          return Callback.Clickable(groups[secondSplitLine + 3])
        end
        return false
      end,
      fn = Callback.Click
    },
    ["goToDownloads"] = {
      message = T("Downloads"),
      windowFilter = WPS.WF.Home,
      condition = function(win)
        local winUI = towinui(win)
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine, secondSplitLine, thirdSplitLine
        for i, g in ipairs(groups) do
          if g.AXSize.h == 16 then
            if firstSplitLine == nil then
              firstSplitLine = i
            elseif secondSplitLine == nil then
              secondSplitLine = i
            elseif thirdSplitLine == nil then
              thirdSplitLine = i
              break
            end
          end
        end
        if thirdSplitLine ~= nil and thirdSplitLine - secondSplitLine > 4 then
          return Callback.Clickable(groups[secondSplitLine + 4])
        end
        return false
      end,
      fn = Callback.Click
    },
    ["openFileLocation"] = {
      message = T("Open File Location"),
      windowFilter = WPS.WF.NonHome,
      condition = function(win)
        local winUI = towinui(win)
        for i=1,#winUI - 1 do
          if winUI[i].AXRole == AX.Button
              and winUI[i + 1].AXRole == AX.Group then
            return true, winUI[i].AXPosition
          end
        end
        return false
      end,
      fn = function(position, win)
        local app = win:application()
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(toappui(app), uinotifications.created)
        observer:callback(A_HotkeyWrapper(function(obs)
          for _, elem in ipairs(toappui(app)) do
            local menuItem = getc(elem, AX.Menu, 1, AX.MenuItem, A_Message)
            if menuItem then
              Callback.Press(menuItem)
              if hs.application.frontmostApplication():bundleID() == app:bundleID() then
                hs.eventtap.keyStroke("", "Escape", nil, app)
              end
              obs:stop()
              obs = nil
            end
          end
        end))
        observer:start()
        local clicked = rightClickAndRestore(position, app)
        if clicked then
          hs.timer.doAfter(2, function()
            if observer ~= nil then
              observer:stop()
              observer = nil
            end
          end)
        else
          observer:stop()
          observer = nil
        end
      end
    },
    ["prevInSettings"] = {
      message = TC("Back"),
      windowFilter = WPS.WF.Settings,
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, "Prev")
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["nextInSettings"] = {
      message = TC("Forward"),
      windowFilter = WPS.WF.Settings,
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, "Next")
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
  },

  ["cn.wps.yunboxtool"] = {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.iWork.Keynote"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = T{"Export To", "PDF…"},
      condition = MenuItem.isEnabled({ "File", "Export To", "PDF…" }),
      fn = Callback.Select
    },
    ["exportToPPT"] = {  -- File > Export To > PowerPoint…
      message = T{"Export To", "PowerPoint…"},
      condition = MenuItem.isEnabled({ "File", "Export To", "PowerPoint…" }),
      fn = Callback.Select
    },
    ["pasteAndMatchStyle"] = {  -- Edit > Paste and Match Style
      message = T("Paste and Match Style"),
      condition = MenuItem.isEnabled({ "Edit", "Paste and Match Style" }),
      repeatable = true,
      fn = Callback.Select
    },
    ["paste"] = {  -- Edit > Paste
      message = T("Paste"),
      condition = MenuItem.isEnabled({ "Edit", "Paste" }),
      repeatable = true,
      fn = Callback.Select
    },
    ["toggleSlideOnly"] = {
      message = T("Slide Only"),
      condition = function(app)
        local menuItem, menuItemPath = findMenuItem(app, { "View", "Slide Only" })
        if menuItem and menuItem.ticked then
          menuItem, menuItemPath = findMenuItem(app, { "View", "Navigator"})
        end
        return menuItem and menuItem.enabled, menuItemPath
      end,
      fn = Callback.Select
    },
    ["showBuildOrder"] = {  -- View > Show Build Order
      message = T("Show Build Order"),
      condition = MenuItem.isEnabled({ "View", "Show Build Order" }),
      fn = function(menuItemTitle, app)
        app:selectMenuItem(menuItemTitle)
        hs.timer.doAfter(0.5, function()
          local winTitle = T("Build Order", app)
          local window = tifilter(app:visibleWindows(), function(win)
            return win:title() == winTitle
          end)
          if #window ~= 0 then window[1]:raise() end
        end)
      end
    },
    ["toggleFormatInspector"] = {  -- View > Inspector > Format
      message = T{"Inspector", "Format"},
      condition = MenuItem.isEnabled({ "View", "Inspector", "Format" }),
      fn = Callback.Select
    },
    ["play"] = {  -- Play > Play Slideshow
      message = T("Play Slideshow"),
      condition = MenuItem.isEnabled({ "Play", "Play Slideshow" }),
      fn = Callback.Select
    },
    ["insertTextBox"] = {  -- Insert > Text Box
      message = T{"Insert", "Text Box"},
      condition = MenuItem.isEnabled({ "Insert", "Text Box" }),
      fn = Callback.Select
    },
    ["insertShape"] = {  -- Insert > Shape
      message = T{"Insert", "Shape"},
      condition = MenuItem.isEnabled({ "Insert", "Shape" }),
      fn = Callback.Select
    },
    ["insertLine"] = {  -- Insert > Line
      message = T{"Insert", "Line"},
      condition = MenuItem.isEnabled({ "Insert", "Line" }),
      fn = Callback.Select
    },
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    },
  },

  ["com.apple.iWork.Pages"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = T{"Export To", "PDF…"},
      condition = MenuItem.isEnabled({ "File", "Export To", "PDF…" }),
      fn = Callback.Select
    },
    ["exportToWord"] = {  -- File > Export To > Word…
      message = T{"Export To", "Word…"},
      condition = MenuItem.isEnabled({ "File", "Export To", "Word…" }),
      fn = Callback.Select
    },
    ["pasteAndMatchStyle"] = {  -- Edit > Paste and Match Style
      message = T("Paste and Match Style"),
      condition = MenuItem.isEnabled({ "Edit", "Paste and Match Style" }),
      repeatable = true,
      fn = Callback.Select
    },
    ["paste"] = {  -- Edit > Paste
      message = T("Paste"),
      condition = MenuItem.isEnabled({ "Edit", "Paste" }),
      repeatable = true,
      fn = Callback.Select
    },
    ["toggleFormatInspector"] = {  -- View > Inspector > Format
      message = T{"Inspector", "Format"},
      condition = MenuItem.isEnabled({ "View", "Inspector", "Format" }),
      fn = Callback.Select
    },
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    },
  },

  ["com.apple.iWork.Numbers"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = T{"Export To", "PDF…"},
      condition = MenuItem.isEnabled({ "File", "Export To", "PDF…" }),
      fn = Callback.Select
    },
    ["exportToExcel"] = {  -- File > Export To > Excel…
      message = T{"Export To", "Excel…"},
      condition = MenuItem.isEnabled({ "File", "Export To", "Excel…" }),
      fn = Callback.Select
    },
    ["pasteAndMatchStyle"] = {  -- Edit > Paste and Match Style
      message = T("Paste and Match Style"),
      condition = MenuItem.isEnabled({ "Edit", "Paste and Match Style" }),
      repeatable = true,
      fn = Callback.Select
    },
    ["paste"] = {  -- Edit > Paste
      message = T("Paste"),
      condition = MenuItem.isEnabled({ "Edit", "Paste" }),
      repeatable = true,
      fn = Callback.Select
    },
    ["toggleFormatInspector"] = {  -- View > Inspector > Format
      message = T{"Inspector", "Format"},
      condition = MenuItem.isEnabled({ "View", "Inspector", "Format" }),
      fn = Callback.Select
    },
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    },
  },

  ["net.xmind.vana.app"] =
  {
    ["exportToPDF"] = {
      message = T{"Export", "PDF"},
      condition = MenuItem.isEnabled({ "File", "Export", "PDF" }),
      fn = Callback.Select
    },
    ["insertEquation"] = {
      message = T{"Insert", "Equation"},
      condition = MenuItem.isEnabled({ 'Insert', "Equation" }),
      fn = Callback.Select
    }
  },

  ["com.eusoft.freeeudic"] =
  {
    ["function1"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 1)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = MenuItem.isEnabled({ "功能", "返回首页" }),
      fn = Callback.Select
    },
    ["function2"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 2)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 2)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["function3"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 3)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 3)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["function4"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 4)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 4)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["function5"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 5)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 5)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["function6"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 6)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 6)
        return button ~= nil, button
      end,
      fn = Callback.Press
    }
  },

  ["com.eusoft.freeeudic.LightPeek"] =
  {
    ["preferencesFromMB"] = {
      message = TMB("com.eusoft.freeeudic", "偏好设置..."),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["com.openai.chat"] =
  {
    ["toggleSidebar"] = {
      message = T("Toggle Sidebar"),
      bindCondition = Version.LessEqual("1.2024.332"),
      condition = MenuItem.isEnabled({ "View", "Toggle Sidebar" }),
      fn = Callback.Select
    },
    ["back"] = {
      message = T("Back"),
      windowFilter = {
        allowTitles = "",
        fn = function(win)
          if towinui(win).AXIdentifier == "ChatGPTSettingsAppWindow" then
            local button = getc(towinui(win), AX.Toolbar, 1,
                AX.Button, 1, AX.Button, 1)
            return button ~= nil
          end
        end
      },
      fn = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1,
            AX.Button, 1, AX.Button, 1)
        if button and button.AXEnabled then Callback.Press(button) end
      end
    },
    ["openLink"] = {
      message = T("Open link"),
      windowFilter = {
        allowSheet = true,
        fn = function(win)
          local title = T("Open link", win)
          local button = tfind(getc(towinui(win), AX.Group, 1,
              AX.Group, 1, AX.Button) or {}, function(bt)
            return bt.AXAttributedDescription:getString()
                and bt.AXAttributedDescription:getString() == title
          end)
          return button ~= nil
        end
      },
      fn = function(win)
        local button = tfind(getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Button) or {}, function(bt)
          return bt.AXAttributedDescription:getString()
              and bt.AXAttributedDescription:getString() == A_Message
        end)
        if button ~= nil then Callback.Press(button) end
      end
    },
    ["toggleChatBar"] = {
      message = TB("Open Chat Bar"),
      background = true,
      fn = function(app)
        local output, status = hs.execute(strfmt([[
          defaults read '%s' KeyboardShortcuts_toggleLauncher | tr -d '\n'
        ]], app:bundleID()))
        if status and output ~= "0" then
          local json = hs.json.decode(output)
          local mods, key = parsePlistKeyBinding(
              json["carbonModifiers"], json["carbonKeyCode"])
          if mods == nil or key == nil then return end
          safeGlobalKeyStroke(mods, key)
        else
          clickRightMenuBarItem("ChatGPTHelper", {}, "click")
        end
      end,
      onLaunch = function(app)
        local retry = 0
        while app:focusedWindow() == nil do
          hs.timer.usleep(10000)
          retry = retry + 1
          if retry == 100 then return end
        end
        app:focusedWindow():close()
        app:hide()
        hs.timer.usleep(1000000)
        A_HotkeyWrapper(appHotKeyCallbacks[app:bundleID()]["toggleChatBar"].fn)(app)
      end
    }
  },

  ["com.tencent.yuanbao"] =
  {
    ["settings"] = {
      message = T("Settings"),
      condition = function(app)
        if app:focusedWindow() == nil then
          return Version.GreaterEqual(app, "2")
        end
        if app:focusedWindow():title() == T("Tencent Yuanbao Setting", app) then
          return false
        end

        local winUI = towinui(app:focusedWindow())
        local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
          AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        local menu = getc(webarea, AX.Group, 8, AX.Group, 2, AX.Group, 1)

        if menu then
          local menuItem = getc(menu, AX.StaticText, A_Message)
          return Callback.Clickable(menuItem)
        end

        local button = tfind(getc(webarea, AX.Group), function(b)
          return tfind(b.AXDOMClassList or {}, function(c)
            return c:find("side%-bar_nickName") ~= nil
                or c:find("side%-bar_name") ~= nil
          end) ~= nil
        end)
        if button ~= nil and button.AXPosition.x ~= winUI.AXPosition.x then
          local ok, position = Callback.Clickable(button)
          if ok then
            local bt = getc(webarea, AX.StaticText, "\xee\x83\xbe")
            if bt ~= nil then
              return ok, { position, button }
            end
          end
        end

        return Version.GreaterEqual(app, "2")
      end,
      fn = function(button, app)
        if app ~= nil then
          if #button == 0 then
            Callback.Click(button) return
          end
          Callback.Click(button[1]) button = button[2]

          if tfind(button.AXDOMClassList or {}, function(c)
            return c:find("nickName") ~= nil
          end) ~= nil then
            local menuItem
            local timer = hs.timer.waitUntil(A_HotkeyWrapper(function()
              local winUI = towinui(app:focusedWindow())
              local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
                  AX.ScrollArea, 1, AX.WebArea, 1)
              local menu = getc(webarea, AX.Group, 8, AX.Group, 2, AX.Group, 1)
              if menu then
                menuItem = getc(menu, AX.StaticText, A_Message)
                return true
              end
            end),
            function() leftClickAndRestore(menuItem, app) end)
            Evt.StopOnDeactivated(app, timer)
          end
          return
        end

        app = button
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(toappui(app), uinotifications.windowCreated)
        observer:callback(A_HotkeyWrapper(function(obs, winUI)
          local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
              AX.ScrollArea, 1, AX.WebArea, 1)
          if webarea then
            for _, g in ipairs(getc(webarea, AX.Group)) do
              if g[1] and g[1].AXValue == A_Message then
                leftClickAndRestore(g[1], app)
                obs:stop() obs = nil
                return
              end
            end
            winUI:asHSWindow():close()
          end
        end))
        observer:start()
        local clicked = clickRightMenuBarItem(app, {}, "right-click")
        if clicked then
          hs.timer.doAfter(5, function()
            if observer ~= nil then
              observer:stop()
              observer = nil
            end
          end)
        else
          observer:stop()
          observer = nil
        end
      end
    },
    ["newChat"] = {
      message = T("New Chat"),
      bindCondition = Version.LessThan("1.6.0"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUI = towinui(app:focusedWindow())
        local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        local button = tfind(getc(webarea, AX.Group), function(b)
          return tfind(b.AXDOMClassList or {}, function(c)
            return c:find("chat_new%-chat%-close") ~= nil
                or c:find("side%-bar_newChatIcon") ~= nil
          end) ~= nil
        end)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["enterTemporaryChat"] = {
      message = T("Enter Temporary Chat"),
      windowFilter = Yuanbao.WF.Main,
      condition = function(win)
        local webarea = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        local button = getc(webarea, AX.StaticText, "\xee\x84\x83")
        if button == nil then
          button = getc(webarea, AX.StaticText, "\xee\x82\xa8")
        end
        return Callback.Clickable(button)
      end,
      fn = Callback.Click
    },
    ["toggleSidebar"] = {
      message = T("Show Sidebar"),
      windowFilter = Yuanbao.WF.Main,
      condition = function(win)
        local webarea = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        if Version.LessThan(win, "1.15.0") then
          local button = tfind(getc(webarea, AX.Group), function(b)
            return tfind(b.AXDOMClassList or {}, function(c)
              return c:find("folder_foldIcon") ~= nil
            end) ~= nil
          end)
          return button ~= nil, button
        else
          local button = getc(webarea, AX.StaticText, "\xee\x84\x82")
          return Callback.Clickable(button)
        end
      end,
      fn = function(result)
        local action = result.AXTitle ~= nil and Callback.Press or Callback.Click
        action(result)
      end
    },
    ["maximize"] = {
      mods = get(KeybindingConfigs.hotkeys.shared, "zoom", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared, "zoom", "key"),
      message = T("Maximize"),
      windowFilter = Yuanbao.WF.Main,
      condition = MenuItem.isEnabled({ "Window", "Maximize" }),
      fn = Callback.Select
    },
    ["back"] = {
      message = TC("Back"),
      bindCondition = Version.LessThan("2"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUI = towinui(app:focusedWindow())
        local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        local button = tfind(getc(webarea, AX.Group), function(b)
          return tfind(b.AXDOMClassList or {}, function(c)
            return c:find("setting_arrowLeft") ~= nil
          end) ~= nil
        end)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["toggleMiniChat"] = {
      message = TB("Open Mini Chat"),
      background = true,
      fn = function(app)
        if Version.LessThan(app, "2") then
          -- false invoke when menubar manager try to show or hide menubar icon
          -- always show the icon to workaround it
          clickRightMenuBarItem(app, {}, "click")
        else
          local observer = uiobserver.new(app:pid())
          observer:addWatcher(toappui(app), uinotifications.windowCreated)
          observer:callback(A_HotkeyWrapper(function(obs, winUI)
            -- false invoke when menubar manager try to show or hide menubar icon
            -- in earley edition
            if winUI.AXSubrole == AX.StandardWindow then return end

            local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
              AX.ScrollArea, 1, AX.WebArea, 1)
            if webarea then
              local title = strsplit(A_Message, " > ")[2]
              for _, g in ipairs(getc(webarea, AX.Group)) do
                if g[1] and g[1].AXValue == title then
                  leftClickAndRestore(g[1], app)
                  break
                end
              end
              obs:stop()
              obs = nil
            end
          end))
          observer:start()
          local clicked = clickRightMenuBarItem(app, {}, "right-click")
          if clicked then
            hs.timer.doAfter(5, function()
              if observer ~= nil then
                observer:stop()
                observer = nil
              end
            end)
          else
            observer:stop()
            observer = nil
          end
        end
      end,
      onLaunch = function(app)
        local retry = 0
        while app:focusedWindow() == nil do
          hs.timer.usleep(10000)
          retry = retry + 1
          if retry == 100 then return end
        end
        app:focusedWindow():close()
        app:hide()
        hs.timer.usleep(1000000)
        A_HotkeyWrapper(appHotKeyCallbacks[app:bundleID()]["toggleMiniChat"].fn)(app)
      end
    },
    ["showMainWindowFromMB"] = {
      message = T("Open Yuanbao"),
      windowFilter = {
        allowRoles = AX.SystemDialog
      },
      background = true,
      fn = function(win)
        hs.application.launchOrFocusByBundleID(win:application():bundleID())
      end
    }
  },

  ["JabRef"] =
  {
    ["preferences"] = {
      message = T("Preferences"),
      condition = MenuItem.isEnabled({ "File", "Preferences" }),
      fn = Callback.Select
    },
    ["newLibrary"] = {
      message = T("New library"),
      condition = MenuItem.isEnabled({ "File", "New library" }),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = T("Recent libraries"),
      condition = MenuItem.isEnabled({ "File", "Recent libraries" }),
      fn = Callback.Select
    },
    ["revealLibrayInFinder"] = {
      message = T("Reveal in file explorer"),
      windowFilter = JabRef.WF.numberLibraries(1),
      condition = function(win)
        local tab = tfind(getc(towinui(win), AX.TabGroup, 1, AX.RadioButton) or {},
          function(rb) return rb.AXValue == true
              and rb.AXTitle ~= T("untitled", win)
        end)
        return tab ~= nil, tab
      end,
      fn = function(tab, win)
        tab:performAction(AX.ShowMenu)
        hs.timer.doAfter(0.1, A_HotkeyWrapper(function()
          local app = win:application()
          local item = getc(toappui(app), AX.Menu, 1, AX.MenuItem, A_Message)
          if item then Callback.Press(item) end
        end))
      end
    },
    ["openRecordFile"] = {
      message = T("Open file"),
      windowFilter = JabRef.WF.numberLibraries(1),
      condition = function(win)
        local row = tfind(getc(towinui(win), AX.TabGroup, 1, AX.Table, 1, AX.Row) or {},
          function(r) return r.AXFocused
        end)
        if row then
          local cell = tfind(getc(row, AX.Cell), function(c)
            local text = getc(c, AX.StaticText, 1)
            return text ~= nil and text.AXValue == "\xf3\xb0\x88\xa5"
          end)
          return Callback.Clickable(cell)
        end
      end,
      fn = Callback.Click
    },
    ["remapPreviousTab"] = {
      message = T("Previous library"),
      windowFilter = JabRef.WF.numberLibraries(2),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⇧⌃', 'Tab', nil, app) end
    },
    ["showPrevLibrary"] = {
      mods = specialCommonHotkeyConfigs["showPrevTab"].mods,
      key = specialCommonHotkeyConfigs["showPrevTab"].key,
      message = T("Previous library"),
      windowFilter = JabRef.WF.numberLibraries(2),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⇧⌃', 'Tab', nil, app) end
    },
    ["showNextLibrary"] = {
      mods = specialCommonHotkeyConfigs["showNextTab"].mods,
      key = specialCommonHotkeyConfigs["showNextTab"].key,
      message = T("Next library"),
      windowFilter = JabRef.WF.numberLibraries(2),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⌃', 'Tab', nil, app) end
    },
    ["1stLibrary"] = {
      message = "First Library",
      windowFilter = JabRef.WF.numberLibraries(1),
      condition = JabRef.showLibraryByIndex(1),
      fn = Callback.Click
    },
    ["2ndLibrary"] = {
      message = "Second Library",
      windowFilter = JabRef.WF.numberLibraries(2),
      condition = JabRef.showLibraryByIndex(2),
      fn = Callback.Click
    },
    ["3rdLibrary"] = {
      message = "Third Library",
      windowFilter = JabRef.WF.numberLibraries(3),
      condition = JabRef.showLibraryByIndex(3),
      fn = Callback.Click
    },
    ["4thLibrary"] = {
      message = "Forth Library",
      windowFilter = JabRef.WF.numberLibraries(4),
      condition = JabRef.showLibraryByIndex(4),
      fn = Callback.Click
    },
    ["5thLibrary"] = {
      message = "Fifth Library",
      windowFilter = JabRef.WF.numberLibraries(5),
      condition = JabRef.showLibraryByIndex(5),
      fn = Callback.Click
    },
    ["6thLibrary"] = {
      message = "Sixth Library",
      windowFilter = JabRef.WF.numberLibraries(6),
      condition = JabRef.showLibraryByIndex(6),
      fn = Callback.Click
    },
    ["7thLibrary"] = {
      message = "Seventh Library",
      windowFilter = JabRef.WF.numberLibraries(7),
      condition = JabRef.showLibraryByIndex(7),
      fn = Callback.Click
    },
    ["8thLibrary"] = {
      message = "Eighth Library",
      windowFilter = JabRef.WF.numberLibraries(8),
      condition = JabRef.showLibraryByIndex(8),
      fn = Callback.Click
    },
    ["9thLibrary"] = {
      message = "Nineth Library",
      windowFilter = JabRef.WF.numberLibraries(9),
      condition = JabRef.showLibraryByIndex(9),
      fn = Callback.Click
    },
    ["10thLibrary"] = {
      message = "Tenth Library",
      windowFilter = JabRef.WF.numberLibraries(10),
      condition = JabRef.showLibraryByIndex(10),
      fn = Callback.Click
    },
    ["minimize"] = specialCommonHotkeyConfigs["minimize"]
  },

  ["org.zotero.zotero"] = {
    ["newCollection"] = {
      message = T("New Collection…"),
      condition = MenuItem.isEnabled({ "File", "New Collection…" }),
      fn = Callback.Select
    }
  },

  ["org.klatexformula.klatexformula"] =
  {
    ["render"] = {
      message = "Render",
      windowFilter = {
        allowTitles = "^KLatexFormula$"
      },
      condition = function(win)
        local g = getc(towinui(win), AX.SplitGroup, 1)
        local ta = getc(g, AX.TextArea, 1)
        return ta ~= nil and ta.AXValue ~= "", getc(g, AX.Button, 2)
      end,
      fn = Callback.Press
    },
    ["renderClipboardInKlatexformula"] = {
      message = "Render Clipboard in klatexformula",
      fn = function(app)
        app:mainWindow():focus()
        app:selectMenuItem({"Shortcuts", "Activate Editor and Select All"})
        hs.eventtap.keyStroke("⌘", "V", nil, app)

        local winUI = towinui(app:mainWindow())
        local button = getc(winUI, AX.SplitGroup, 1, AX.Button, 2)
        if button ~= nil then
          Callback.Press(button)
        end
      end
    },
    ["copy"] = {
      message = "Copy",
      windowFilter = {
        allowTitles = "^KLatexFormula$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.SplitGroup, 1, AX.Button, "COPY")
        return button ~= nil and button.AXEnabled, button
      end,
      fn = Callback.Press
    },
    ["clear"] = {
      message = "Clear",
      windowFilter = {
        allowTitles = "^KLatexFormula$"
      },
      fn = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.SplitGroup, 1, AX.Button, 1)
        if button ~= nil then
          Callback.Press(button)
        end
      end
    },
    ["save"] = {
      message = "Save",
      windowFilter = {
        allowTitles = "^KLatexFormula$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.SplitGroup, 1, AX.Button, "SAVE")
        return button ~= nil and button.AXEnabled, button
      end,
      fn = Callback.Press
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"]
  },

  ["com.apple.iMovieApp"] =
  {
    ["export"] = {
      message = T{"Share", "File…"},
      condition = MenuItem.isEnabled({ "File", "Share", "File…" }),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = T("Open Library"),
      condition = MenuItem.isEnabled({ "File", "Open Library" }),
      fn = Callback.Select
    }
  },

  ["com.tdesktop.Telegram"] =
  {
    ["remapPreviousTab"] = {
      message = "Go to Previous Chat",
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⇧⌃', 'Tab', nil, app) end
    }
  },

  ["com.tencent.xinWeChat"] =
  {
    ["backFromMinizedGroups"] = {
      message = function(win)
        return T("Minimized Groups", win) .. ' > ' .. TC("Back", win)
      end,
      bindCondition = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.Main,
      condition = function(win)
        local title = strsplit(A_Message, ' > ')[2]
        local bt = getc(towinui(win), AX.Group, 1,
            AX.SplitGroup, 1, AX.Button, title)
        return Callback.Clickable(bt)
      end,
      fn = Callback.Click
    },
    ["backInOfficialAccounts"] = {
      message = T({ "Tabbar.OA", "Common.Navigation.Back" }),
      bindCondition = Version.LessThan("4"),
      windowFilter = WeChat.WF.Main,
      condition = function(win)
        local g = getc(towinui(win), AX.SplitGroup, 1, AX.SplitGroup, 1)
        if g ~= nil then
          local title = strsplit(A_Message, ' > ')[2]
          for _, bt in ipairs(getc(g, AX.Button)) do
            if bt.AXTitle == title then
              return true, bt
            end
          end
        end
      end,
      fn = Callback.Press
    },
    ["backInMoments"] = {
      message = TC("Back"),
      bindCondition = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.Moments,
      condition = function(win)
        local button
        if Version.LessThan(win, "4") then
          button = tfind(getc(towinui(win), AX.Button) or {},
              function(bt) return bt.AXDescription == A_Message end)
        else
          button = getc(towinui(win), AX.Button, A_Message)
        end
        return Callback.Clickable(button)
      end,
      fn = Callback.Click
    },
    ["hideChat"] = {
      message = function(win)
        if Version.LessThan(win, "4") then
          local title = T("Chats.Menu.Hide", win)
          local chats = getc(towinui(win), AX.SplitGroup, 1,
              AX.ScrollArea, 1, AX.Table, 1)
          if chats and chats.AXDescription then
            return chats.AXDescription .. ' > ' .. title
          else
            return title
          end
        else
          local title = localizedString("Hide", win)
          if type(title) == 'table' then title = title[#title] end
          local chats = getc(towinui(win), AX.Group, 1,
              AX.SplitGroup, 1, AX.List, -1)
          if chats and chats.AXTitle then
            return chats.AXTitle .. ' > ' .. title
          else
            return title
          end
        end
      end,
      bindCondition = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.Main,
      condition = function(win)
        local winUI = towinui(win)
        if Version.LessThan(win, "4") then
          local chats = getc(winUI, AX.SplitGroup, 1,
              AX.ScrollArea, 1, AX.Table, 1, AX.Row)
          if chats == nil then return end
          local curChatTitle = getc(winUI, AX.SplitGroup, 1,
              AX.SplitGroup, 1, AX.StaticText, 1)
              or getc(winUI, AX.SplitGroup, 1, AX.StaticText, 1)
          if curChatTitle == nil then
            local curChat = tfind(chats, function(row)
              return row.AXFocused
            end)
            return curChat ~= nil, curChat
          end
          local title = curChatTitle.AXValue
          local curChat = tfind(chats, function(c)
            local row = getc(c, AX.Cell, 1, AX.Row, 1)
            return row ~= nil and (row.AXTitle == title
                or row.AXTitle:sub(1, #title + 1) == title .. ",")
          end)
          return curChat ~= nil, getc(curChat, AX.Cell, 1)
        else
          local chats = getc(winUI, AX.Group, 1,
              AX.SplitGroup, 1, AX.List, -1, AX.StaticText)
          if chats == nil then return end
          local curChatTitle = getc(winUI, AX.Group, 1,
              AX.SplitGroup, 1, AX.StaticText, -1)
          if curChatTitle == nil then
            local curChat = tfind(chats, function(row)
              return row.AXFocused
            end)
            return curChat ~= nil, curChat
          end
          if #curChatTitle > 0 then
            curChatTitle = getc(curChatTitle, AX.StaticText, 1)
          end
          local title = curChatTitle.AXValue
          local curChat = tfind(chats, function(row)
            return row.AXTitle == title
                or row.AXTitle:sub(1, #title + 1) == title .. " "
          end)
          return curChat ~= nil, curChat
        end
      end,
      fn = function(chat, win)
        chat:performAction(AX.ShowMenu)
        if chat.AXRole == AX.Cell then
          local menu = getc(chat, AX.Row, 1, AX.Menu, 1)
          if menu then
            local hide = getc(menu, AX.MenuItem, "contextMenuHide:")
            if hide then Callback.Press(hide) end
          end
        else
          hs.timer.doAfter(0.5, A_HotkeyWrapper(function()
            local app = win:application()
            local menu = toappui(app):elementAtPosition(
                uioffset(chat.AXPosition, { 1, 1 }))
            if menu and menu.AXRole == AX.Menu then
              local title = strsplit(A_Message, ' > ')[2]
              local hide = getc(menu, AX.MenuItem, title)
              if hide then leftClickAndRestore(hide, app) end
            end
          end))
        end
      end
    },
    ["showChatProfile"] = {
      message = function(win)
        local title = T("Chats.Menu.Profile", win)
        local chats = getc(towinui(win), AX.SplitGroup, 1,
            AX.ScrollArea, 1, AX.Table, 1)
        if chats and chats.AXDescription then
          return chats.AXDescription .. ' > ' .. title
        else
          return title
        end
      end,
      bindCondition = Version.LessThan("4"),
      windowFilter = WeChat.WF.Main,
      condition = function(win)
        local winUI = towinui(win)
        local curChatTitle = getc(winUI, AX.SplitGroup, 1,
            AX.SplitGroup, 1, AX.StaticText, 1)
        if curChatTitle == nil then return false end
        local btTitle = T("ComposeBar.VideoTooltip", win)
        local bt = getc(winUI, AX.SplitGroup, 1,
            AX.SplitGroup, 1, AX.Button, btTitle)
        return bt ~= nil, curChatTitle.AXValue
      end,
      fn = function(title, win)
        local winUI = towinui(win)
        local chats = getc(winUI, AX.SplitGroup, 1,
            AX.ScrollArea, 1, AX.Table, 1, AX.Row)
        local curChat = tfind(chats, function(c)
          local row = getc(c, AX.Cell, 1, AX.Row, 1)
          return row ~= nil and (row.AXTitle == title
              or row.AXTitle:sub(1, #title + 1) == title .. ",")
        end)
        if curChat ~= nil then
          getc(curChat, AX.Cell, 1):performAction(AX.ShowMenu)
          local menu = getc(curChat, AX.Cell, 1,
              AX.Row, 1, AX.Menu, 1)
          if menu then
            local profile = getc(menu, AX.MenuItem, "contextMenuProfile:")
            if profile then Callback.Press(profile) end
          end
        end
      end
    },
    ["previewPreview"] = {
      message = T("Preview"),
      bindCondition = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        local button = getc(towinui(win), AX.Button, A_Message)
        if button and button.AXEnabled then
          return Callback.Clickable(getc(button, AX.Button, 1))
        end
      end,
      fn = Callback.Click
    },
    ["previewImageSize"] = {
      message = function(win)
        return T("Original image size", win) .. ' / ' .. T("Fit to Window", win)
      end,
      bindCondition = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        local titles = strsplit(A_Message, ' / ')
        local button = getc(towinui(win), AX.Button, titles[1])
            or getc(towinui(win), AX.Button, titles[2])
        if button and button.AXEnabled then
          return Callback.Clickable(getc(button, AX.Button, 1))
        end
      end,
      fn = Callback.Click
    },
    ["previewRotate"] = {
      message = T("Rotate"),
      bindCondition = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        local button = getc(towinui(win), AX.Button, A_Message)
        if button and button.AXEnabled then
          return Callback.Clickable(getc(button, AX.Button, 1))
        end
      end,
      fn = Callback.Click
    },
    ["previewEdit"] = {
      message = T("Edit"),
      bindCondition = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        local button = getc(towinui(win), AX.Button, A_Message)
        if button and button.AXEnabled then
          return Callback.Clickable(getc(button, AX.Button, 1))
        end
      end,
      fn = Callback.Click
    },
    ["previewTranslate"] = {
      message = T("Translate"),
      bindCondition = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        local button = getc(towinui(win), AX.Button, A_Message)
        if button and button.AXEnabled then
          return Callback.Clickable(getc(button, AX.Button, 1))
        end
      end,
      fn = Callback.Click
    },
    ["previewExtractText"] = {
      message = T("Extract Text"),
      bindCondition = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        local button = getc(towinui(win), AX.Button, A_Message)
        if button and button.AXEnabled then
          return Callback.Clickable(getc(button, AX.Button, 1))
        end
      end,
      fn = Callback.Click
    },
    ["openInDefaultBrowser"] = {
      message = function(win)
        local app = win:application()
        if Version.LessThan(app, "4") then
          return T("Open in Default Browser", app)
        else
          local exBundleID = "com.tencent.flue.WeChatAppEx"
          local appLocale = applicationLocale(app:bundleID())
          return localizedString("Open in default browser", exBundleID,
                                 { locale = appLocale })
        end
      end,
      windowFilter = WeChat.WF.AppExWeb,
      condition = function(win)
        local app = win:application()
        if Version.LessThan(app, "4") then return true end
        local button = getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Group, 1, AX.Group, 1, nil, 1)
        if button == nil then return false end
        if button.AXRole == AX.PopUpButton then
          local tabs = getc(towinui(win), AX.Group, 1,
              AX.Group, 1, AX.Group, 1, AX.Group, 2,
              AX.TabGroup, 1, AX.ScrollArea, 1,  AX.RadioButton)
          local tab = tfind(tabs or {}, function(rb) return rb.AXValue == true end)
          if tab then
            local exBundleID = "com.tencent.flue.WeChatAppEx"
            if tab.AXDescription
                == localizedString("Mini-Program", exBundleID,
                                   { locale = 'zh-Hans' }) then
              return false
            end
          end
        end
        return true, button
      end,
      fn = function(button, win)
        if win == nil then
          win = button
          local frame = win:frame()
          local position = uioffset(frame, { frame.w - 60, 23 })
          leftClickAndRestore(position, win)
          return
        end

        Callback.Press(button)
        if button and button.AXRole == AX.PopUpButton then
          local menuWin, totalDelay = nil, 0
          repeat
            menuWin = tfind(getc(toappui(win:application()), AX.Window), function(win)
              return #win ==  1 and #win[1] == 1 and win[1][1].AXRole == AX.Menu
            end)
            if menuWin == nil then
              hs.timer.usleep(0.05 * 1000000)
              totalDelay = totalDelay + 0.05
            end
          until menuWin or totalDelay > 1
          local menuItems = getc(menuWin, AX.Group, 1, AX.Menu, 1, AX.MenuItem)
          if menuItems and #menuItems > 0 then
            local menuItem = tfind(menuItems, function(item)
              return item.AXDescription == A_Message
            end)
            if menuItem then
              Callback.Press(menuItem)
            else
              hs.eventtap.keyStroke('', 'escape', nil, win:application())
            end
          end
        end
      end
    },
    ["remapPreviousTab"] = {
      message = function(win)
        local appLocale = applicationLocale(win:application():bundleID())
        local exBundleID = "com.tencent.flue.WeChatAppEx"
        local params = { locale = appLocale }
        return localizedString("Select Previous Tab", exBundleID, params)
      end,
      bindCondition = Version.GreaterEqual("4"),
      windowFilter = WeChat.WF.AppEx,
      condition = function(win)
        local app = win:application()
        local appLocale = applicationLocale(app:bundleID())
        local exBundleID = "com.tencent.flue.WeChatAppEx"
        local params = { locale = appLocale }
        local menuItemPath = {
          localizedMenuBarItem("Window", exBundleID, params), A_Message
        }
        local menuItem = app:findMenuItem(menuItemPath)
        if menuItem ~= nil and menuItem.enabled then
          return true, menuItemPath
        end
      end,
      repeatable = true,
      fn = Callback.Select
    },
    ["closeWindow"] = {
      message = TC('Close Window'),
      bindCondition = Version.GreaterEqual("4"),
      windowFilter = WeChat.WF.AppExSingleTab,
      condition = function(win)
        local exBundleID = "com.tencent.flue.WeChatAppEx"
        local appLocale = applicationLocale(win:application():bundleID())
        local menuItemPath = {
          localizedMenuBarItem('File', exBundleID, { locale = appLocale }),
          localizedString('Close All Tabs', exBundleID, { locale = appLocale })
        }
        local menuItem = win:application():findMenuItem(menuItemPath)
        return menuItem ~= nil and menuItem.enabled, menuItemPath
      end,
      fn = Callback.Select
    },
    ["confirm"] = {
      message = function(win)
        local bt
        local winUI = towinui(win)
        if #winUI > 1 then
          bt = getc(winUI, nil, -1)
        else
          repeat
            winUI = winUI[1]
          until #winUI ~= 1
          bt = getc(winUI, AX.Button, 1)
        end
        if bt then
          if bt.AXTitle ~= "" then
            return bt.AXTitle
          else
            return bt.AXDescription
          end
        end
      end,
      bindCondition = Version.Between("4", "4.0.6"),
      deleteOnDisable = true,
      windowFilter = WeChat.WF.Confirm,
      condition = function(win)
        local bt
        local winUI = towinui(win)
        if #winUI > 1 then
          bt = getc(winUI, nil, -1)
        else
          repeat
            winUI = winUI[1]
          until #winUI ~= 1
          bt = getc(winUI, AX.Button, 1)
        end
        return Callback.Clickable(bt)
      end,
      fn = Callback.Click
    },
    ["send"] = {
      message = T("Send"),
      bindCondition = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.SendTo,
      condition = function(win)
        local winUI = towinui(win)
        local bt = getc(towinui(win), AX.Button, A_Message)
        if bt == nil then
          local title = localizedString("Send To (%d)", win)
          if type(title) ~= 'table' then
            title = { title }
          end
          for _, t in ipairs(title) do
            t = t:gsub("%(%%d%)", "%%(%%d%%)")
            bt = tfind(getc(winUI, AX.Button), function(b)
              return b.AXTitle:match(t)
            end)
            if bt then break end
          end
        end
        if bt and bt.AXEnabled then
          -- `WeChat` accessibility bug
          local ref = getc(winUI, AX.List, 1)
          if ref.AXPosition.x < winUI.AXPosition.x then
            return Callback.Clickable(winUI, {
              bt.AXPosition.x - ref.AXPosition.x + bt.AXSize.w / 2,
              winUI.AXSize.h - 13 - bt.AXSize.h / 2
                  - (ref.AXPosition.y + ref.AXSize.h - bt.AXPosition.y - bt.AXSize.h)
            })
          else
            return Callback.Clickable(bt)
          end
        end
      end,
      fn = Callback.Click
    },
    ["confirmAll"] = {
      message = TC("Confirm"),
      bindCondition = Version.GreaterEqual("4.0.6"),
      windowFilter = WeChat.WF.ConfirmDefault,
      condition = function(win)
        local frame = win:frame()
        return Callback.Clickable(towinui(win), { frame.w - 80, frame.h - 47 })
      end,
      fn = Callback.Click
    }
  },

  ["com.tencent.qq"] = {
    ["switchUIMode"] = {
      message = "切换界面模式",
      bindCondition = Version.GreaterEqual("6.9.82"),
      windowFilter = { allowTitles = "^QQ$" },
      condition = function(win)
        local webarea = getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.WebArea, 1)
        local image = getc(webarea, AX.Group, 1,
            AX.Group, 2, AX.Group, 1, nil, 1, AX.Image, 1)
        if Version.GreaterEqual(win, "6.9.83") then
          return Callback.Clickable(image)
        else
          return image ~= nil, image
        end
      end,
      fn = function(image)
        if image.AXPosition then
          Callback.Press(image)
        else
          Callback.Click(image)
        end
      end
    }
  },

  ["com.tencent.QQMusicMac"] =
  {
    ["back"] = {
      message = "后退",
      windowFilter = {
        allowRoles = AX.StandardWindow,
        allowTitles = "^$"
      },
      condition = function(win)
        local titleBar
        if Version.LessThan(win, "10.3.0") then
          local appUI = toappui(win:application())
          local frame = win:frame()
          titleBar = appUI:elementAtPosition(uioffset(frame, { 100, 10 }))
        else
          titleBar = getc(towinui(win), AX.Unknown, 3)
          if titleBar == nil then return false end
        end
        for _, button in ipairs(titleBar) do
          if button.AXHelp == A_Message then
            return Callback.Clickable(button)
          end
        end
        return false
      end,
      repeatable = true,
      fn = Callback.ClickAndHold(0.1)
    },
    ["forward"] = {
      message = "前进",
      windowFilter = {
        allowRoles = AX.StandardWindow,
        allowTitles = "^$"
      },
      condition = function(win)
        local titleBar
        if Version.LessThan(win, "10.3.0") then
          local appUI = toappui(win:application())
          local frame = win:frame()
          titleBar = appUI:elementAtPosition(uioffset(frame, { 100, 10 }))
        else
          titleBar = getc(towinui(win), AX.Unknown, 3)
          if titleBar == nil then return false end
        end
        for _, button in ipairs(titleBar) do
          if button.AXHelp == A_Message then
            return Callback.Clickable(button)
          end
        end
        return false
      end,
      repeatable = true,
      fn = Callback.ClickAndHold(0.1)
    },
    ["refresh"] = {
      message = "刷新",
      windowFilter = {
        allowRoles = AX.StandardWindow,
        allowTitles = "^$"
      },
      condition = function(win)
        local titleBar
        if Version.LessThan(win, "10.3.0") then
          local appUI = toappui(win:application())
          local frame = win:frame()
          titleBar = appUI:elementAtPosition(uioffset(frame, { 100, 10 }))
        else
          titleBar = getc(towinui(win), AX.Unknown, 3)
          if titleBar == nil then return false end
        end
        local refreshButton, searchButton
        for _, button in ipairs(titleBar) do
          if button.AXHelp == A_Message then
            refreshButton = button
          elseif button.AXHelp == nil then
            searchButton = button
          end
        end
        if refreshButton ~= nil and searchButton ~= nil
            and refreshButton.AXPosition.x ~= searchButton.AXPosition.x then
          return Callback.Clickable(refreshButton)
        end
      end,
      fn = Callback.ClickAndHold(0.1)
    },
    ["playBarCloseSingleSong"] = {
      message = TC("Close Window"),
      windowFilter = {
        allowRoles = AX.Unknown,
        fn = function(win)
          local mWin = win:application():mainWindow()
          local fFrame, mFrame = win:frame(), mWin:frame()
          return win:id() ~= mWin:id()
              and fFrame.x == mFrame.x and fFrame.y == mFrame.y
              and fFrame.w == mFrame.w and fFrame.h == mFrame.h
        end
      },
      fn = function(win)
        local buttons = getc(towinui(win), AX.Button)
        buttons[#buttons - 2]:performAction(AX.Press)
      end
    }
  },

  ["com.tencent.tenvideo"] =
  {
    ["openRecent"] = {
      message = "最近打开",
      fn = function(app)
        -- in early version of macOS there was a duplicated menu bar item '文件'
        -- which does not have menu items. So we have to manually filter it out
        local menuBarItems = getMenuBarItems(app)
        local menuBarItem = tfind(menuBarItems, function(item)
          return #item > 0 and item.AXTitle == '文件'
        end)
        local menuItem = getc(menuBarItem, AX.Menu, 1, AX.MenuItem, A_Message)
        if menuItem ~= nil then
          Callback.Press(menuBarItem)
          Callback.Press(menuItem)
        end
      end
    },
    ["channel1"] = {
      message = QQLive.channelName(1),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(1),
      fn = Callback.Click
    },
    ["channel2"] = {
      message = QQLive.channelName(2),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(2),
      fn = Callback.Click
    },
    ["channel3"] = {
      message = QQLive.channelName(3),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(3),
      fn = Callback.Click
    },
    ["channel4"] = {
      message = QQLive.channelName(4),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(4),
      fn = Callback.Click
    },
    ["channel5"] = {
      message = QQLive.channelName(5),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(5),
      fn = Callback.Click
    },
    ["channel6"] = {
      message = QQLive.channelName(6),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(6),
      fn = Callback.Click
    },
    ["channel7"] = {
      message = QQLive.channelName(7),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(7),
      fn = Callback.Click
    },
    ["channel8"] = {
      message = QQLive.channelName(8),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(8),
      fn = Callback.Click
    },
    ["channel9"] = {
      message = QQLive.channelName(9),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(9),
      fn = Callback.Click
    },
    ["channel10"] = {
      message = QQLive.channelName(10),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(10),
      fn = Callback.Click
    }
  },

  ["com.tencent.meeting"] =
  {
    ["preferences"] = {
      message = T("Preferences"),
      fn = function(app)
        app:selectMenuItem({ app:name(), A_Message })
      end
    }
  },

  ["com.bytedance.douyin.desktop"] =
  {
    ["settings"] = {
      message = "设置",
      fn = function(app)
        app:selectMenuItem({ app:name(), A_Message })
      end
    },
    ["showMainWindow"] = {
      message = "抖音窗口",
      fn = function(app)
        app:selectMenuItem({ "窗口", A_Message })
      end
    }
  },

  ["com.tencent.LemonMonitor"] =
  {
    ["closeWindow"] = {
      mods = "", key = "Escape",
      message = TC("Close Window"),
      windowFilter = {
        allowRoles = AX.Unknown
      },
      background = true,
      nonFrontmost = true,
      fn = function(win)
        clickRightMenuBarItem(win:application(), {}, "click")
      end
    }
  },

  ["com.nektony.App-Cleaner-SIII"] =
  {
    ["uninstall"] = {
      message = T('Uninstall'),
      condition = AppCleanerUninstaller.buttonValid('Uninstall'),
      fn = Callback.Press
    },
    ["remove"] = {
      message = T('Remove'),
      condition = AppCleanerUninstaller.buttonValid('Remove'),
      fn = Callback.Press
    },
    ["enable"] = {
      message = T('Enable'),
      condition = AppCleanerUninstaller.buttonValid('Enable'),
      fn = Callback.Press
    },
    ["disable"] = {
      message = T('Disable'),
      condition = AppCleanerUninstaller.buttonValid('Disable'),
      fn = Callback.Press
    },
    ["update"] = {
      message = T('Update'),
      condition = AppCleanerUninstaller.buttonValid('Update'),
      fn = Callback.Press
    },
    ["launchApp"] = {
      message = T('Launch App'),
      bindCondition = Version.GreaterEqual("8.6"),
      condition = AppCleanerUninstaller.buttonValid('Launch App'),
      fn = Callback.Press
    },
    ["confirmRemove"] = {
      message = T('Remove'),
      condition = AppCleanerUninstaller.confirmButtonValid('Remove'),
      fn = Callback.DoubleClick
    },
    ["confirmUpdate"] = {
      message = T('Update'),
      condition = AppCleanerUninstaller.confirmButtonValid('Update'),
      fn = Callback.DoubleClick
    },
    ["confirmRetry"] = {
      message = T('Retry'),
      condition = AppCleanerUninstaller.confirmButtonValid('Retry'),
      fn = Callback.DoubleClick
    }
  },

  ["com.nektony.App-Cleaner-SIIICn"] =
  {
    ["remove"] = {
      message = T('Remove_Button_Title'),
      condition = AppCleanerUninstaller.buttonValid('Remove_Button_Title'),
      fn = Callback.Press
    },
    ["enable"] = {
      message = T('EnableMenuItemTitle'),
      condition = AppCleanerUninstaller.buttonValid('EnableMenuItemTitle'),
      fn = Callback.Press
    },
    ["disable"] = {
      message = T('DisableMenuItemTitle'),
      condition = AppCleanerUninstaller.buttonValid('DisableMenuItemTitle'),
      fn = Callback.Press
    },
    ["update"] = {
      message = T('UpdateButtonTitle'),
      condition = AppCleanerUninstaller.buttonValid('UpdateButtonTitle'),
      fn = Callback.Press
    },
    ["launchApp"] = {
      message = T('LaunchAppButtonTitle'),
      bindCondition = Version.GreaterEqual("8.6"),
      condition = AppCleanerUninstaller.buttonValid('LaunchAppButtonTitle'),
      fn = Callback.Press
    },
    ["confirmRemove"] = {
      message = T('PartialRemove_Remove'),
      condition = AppCleanerUninstaller.confirmButtonValid('PartialRemove_Remove'),
      fn = Callback.DoubleClick
    },
    ["confirmUpdate"] = {
      message = T('UpdateButtonTitle'),
      condition = AppCleanerUninstaller.confirmButtonValid('UpdateButtonTitle'),
      fn = Callback.DoubleClick
    },
    ["confirmRetry"] = {
      message = T('PartialRemove_Retry'),
      condition = AppCleanerUninstaller.confirmButtonValid('PartialRemove_Retry'),
      fn = Callback.DoubleClick
    }
  },

  ["com.charliemonroe.Downie-4"] =
  {
    ["openRecent"] = {
      message = T("Show History"),
      condition = MenuItem.isEnabled({ "Window", "Show History" }),
      fn = Callback.Select
    }
  },

  ["barrier"] =
  {
    ["toggleBarrier"] = {
      message = "Toggle Barrier",
      background = true,
      fn = function(app)
        local appUI = toappui(app)
        local menu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1, AX.Menu, 1)
        if menu == nil then
          local invoked = clickRightMenuBarItem(app)
          if not invoked then return end
          menu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1, AX.Menu, 1)
        end
        local locale = applicationLocale(app:bundleID())
        local title = T("&Start", app, { locale = locale })
        assert(type(title) == 'string')
        title = title:gsub("%(&%a%)", ""):gsub("&", "")
        local start = getc(menu, AX.MenuItem, title)
        if start == nil then return end
        if start.AXEnabled then
          Callback.Press(start)
          hs.alert("Barrier started")
        else
          title = T("S&top", app, { locale = locale })
          assert(type(title) == 'string')
          title = title:gsub("%(&%a%)", ""):gsub("&", "")
          local stop = getc(menu, AX.MenuItem, title)
          if stop == nil then return end
          Callback.Press(stop)
          hs.alert("Barrier stopped")
        end
      end,
      onLaunch = function(app)
        if app:focusedWindow() == nil then
          hs.alert("Error occurred")
        else
          local winUI = towinui(app:focusedWindow())
          local title = Barrier.localizedString("&Start", app)
          local start = getc(winUI, AX.Button, title)
          if start == nil then return end
          Callback.Press(start)
          hs.alert("Barrier started")
          hs.timer.doAfter(0.5, function()
            local close = getc(winUI, AX.Button, 4)
            if close == nil then return end
            Callback.Press(close)
          end)
        end
      end
    },
    ["changeSettings"] = {
      message = Barrier.localizedMessage("Change &Settings"),
      condition = function(app)
        local menuBarItems = getMenuBarItems(app, true)
        local menuBarItem = tfind(menuBarItems, function(item)
          return item.AXTitle == "Barrier"
        end)
        local menuItem = getc(menuBarItem, AX.Menu, 1, AX.MenuItem, A_Message)
        return menuItem and menuItem.AXEnabled, menuItem
      end,
      fn = Callback.Press
    },
    ["reload"] = {
      message = Barrier.localizedMessage("&Reload"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Reload", win)
        local reload = getc(winUI, AX.Button, title)
        return reload ~= nil and #reload:actionNames() > 0, reload
      end,
      fn = Callback.Press
    },
    ["start"] = {
      message = Barrier.localizedMessage("&Start"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Start", win)
        local start = getc(winUI, AX.Button, title)
        return start ~= nil and #start:actionNames() > 0, start
      end,
      fn = Callback.Press
    },
    ["stop"] = {
      message = Barrier.localizedMessage("&Stop"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Stop", win)
        local stop = getc(winUI, AX.Button, title)
        return stop ~= nil and #stop:actionNames() > 0, stop
      end,
      fn = Callback.Press
    },
    ["serverMode"] = {
      message = Barrier.localizedMessage("&Server (share this computer's mouse and keyboard)"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      fn = function(win)
        local winUI = towinui(win)
        local server = getc(winUI, AX.CheckBox, 1)
        if server then Callback.Press(server) end
      end
    },
    ["clientMode"] = {
      message = Barrier.localizedMessage("&Client (use another computer's mouse and keyboard):"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      fn = function(win)
        local winUI = towinui(win)
        local client = getc(winUI, AX.CheckBox, 2)
        if client then Callback.Press(client) end
      end
    },
    ["configureInteractively"] = {
      message = Barrier.localizedMessage("Configure interactively:"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("Configure interactively:", win)
        local configure = getc(winUI, AX.CheckBox, 1, AX.RadioButton, title)
        return configure ~= nil and #configure:actionNames() > 0, configure
      end,
      fn = Callback.Press
    },
    ["useExistingConfiguration"] = {
      message = Barrier.localizedMessage("Use existing configuration:"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("Use existing configuration:", win)
        local configure = getc(winUI, AX.CheckBox, 1, AX.RadioButton, title)
        return configure ~= nil and #configure:actionNames() > 0, configure
      end,
      fn = Callback.Press
    },
    ["configureServer"] = {
      message = Barrier.localizedMessage("&Configure Server..."),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Configure Server...", win)
        local configure = getc(winUI, AX.CheckBox, 1, AX.Button, title)
        return configure ~= nil and #configure:actionNames() > 0, configure
      end,
      fn = Callback.Press
    },
    ["configurationFile"] = {
      message = Barrier.localizedMessage("&Configuration file:"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Configuration file:", win)
        local textField = getc(winUI, AX.CheckBox, 1, AX.TextField, title)
        return textField ~= nil and #textField:actionNames() > 0, textField
      end,
      fn = function(textField)
        textField:performAction(AX.Raise)
      end
    },
    ["browse"] = {
      message = Barrier.localizedMessage("&Browse..."),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Browse...", win)
        local browse = getc(winUI, AX.CheckBox, 1, AX.Button, title)
        return browse ~= nil and #browse:actionNames() > 0, browse
      end,
      fn = Callback.Press
    },
    ["autoConfig"] = {
      message = Barrier.localizedMessage("Auto config"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local autoconfig = getc(winUI, AX.CheckBox, 2, AX.CheckBox, A_Message)
        return autoconfig ~= nil and #autoconfig:actionNames() > 0, autoconfig
      end,
      fn = function(checkbox, win)
        local toSpecify = checkbox.AXValue == 1
        Callback.Press(checkbox)
        if toSpecify then
          local title = Barrier.localizedString("&Server IP:", win)
          local textField = getc(towinui(win), AX.CheckBox, 2, AX.TextField, title)
          if textField then
            textField:performAction(AX.Raise)
          end
        end
      end
    },
    ["showMainWindowFromMB"] = {
      message = TMB("Show"),
      menubarFilter = { allowIndices =  1 },
      condition = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        return menuItem and menuItem.AXEnabled, menuItem
      end,
      fn = Callback.Press
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
  },

  ["com.objective-see.lulu.app"] =
  {
    ["allowConnection"] = {
      message = "Allow Connection",
      bindCondition = Version.LessThan("2.9.1"),
      windowFilter = {
        allowTitles = "^LuLu Alert$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, "Allow")
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["blockConnection"] = {
      message = "Block Connection",
      bindCondition = Version.LessThan("2.9.1"),
      windowFilter = {
        allowTitles = "^LuLu Alert$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, "Block")
        return button ~= nil, button
      end,
      fn = Callback.Press
    }
  },

  ["com.runningwithcrayons.Alfred-Preferences"] =
  {
    ["saveInSheet"] = {
      message = "Save",
      windowFilter = {
        allowSheet = true,
        fn = function(win)
          local winUI = towinui(win)
          local button = getc(winUI, AX.Button, "Save")
          return button ~= nil
        end,
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, A_Message)
        return button and button.AXEnabled, button
      end,
      fn = Callback.Press
    }
  },

  ["com.surteesstudios.Bartender"] =
  {
    ["toggleMenuBar"] = {
      message = T("Show menu bar item"),
      bindCondition = function(app)
        return Version.LessThan(app, "6") or Version.GreaterEqual(app, "6.1.1")
      end,
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        hs.osascript.applescript(strfmt([[
          tell application id "%s" to toggle bartender
        ]], app:bundleID()))
      end
    },
    ["click1stBartenderBarItem"] = {
      message = Bartender.barItemTitle(1),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(1)
    },
    ["rightClick1stBartenderBarItem"] = {
      message = Bartender.barItemTitle(1, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(1, true)
    },
    ["click2ndBartenderBarItem"] = {
      message = Bartender.barItemTitle(2),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(2)
    },
    ["rightClick2ndBartenderBarItem"] = {
      message = Bartender.barItemTitle(2, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(2, true)
    },
    ["click3rdBartenderBarItem"] = {
      message = Bartender.barItemTitle(3),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(3)
    },
    ["rightClick3rdBartenderBarItem"] = {
      message = Bartender.barItemTitle(3, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(3, true)
    },
    ["click4thBartenderBarItem"] = {
      message = Bartender.barItemTitle(4),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(4)
    },
    ["rightClick4thBartenderBarItem"] = {
      message = Bartender.barItemTitle(4, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(4, true)
    },
    ["click5thBartenderBarItem"] = {
      message = Bartender.barItemTitle(5),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(5)
    },
    ["rightClick5thBartenderBarItem"] = {
      message = Bartender.barItemTitle(5, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(5, true)
    },
    ["click6thBartenderBarItem"] = {
      message = Bartender.barItemTitle(6),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(6)
    },
    ["rightClick6thBartenderBarItem"] = {
      message = Bartender.barItemTitle(6, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(6, true)
    },
    ["click7thBartenderBarItem"] = {
      message = Bartender.barItemTitle(7),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(7)
    },
    ["rightClick7thBartenderBarItem"] = {
      message = Bartender.barItemTitle(7, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(7, true)
    },
    ["click8thBartenderBarItem"] = {
      message = Bartender.barItemTitle(8),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(8)
    },
    ["rightClick8thBartenderBarItem"] = {
      message = Bartender.barItemTitle(8, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(8, true)
    },
    ["click9thBartenderBarItem"] = {
      message = Bartender.barItemTitle(9),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(9)
    },
    ["rightClick9thBartenderBarItem"] = {
      message = Bartender.barItemTitle(9, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(9, true)
    },
    ["click10thBartenderBarItem"] = {
      message = Bartender.barItemTitle(10),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(10)
    },
    ["rightClick10thBartenderBarItem"] = {
      message = Bartender.barItemTitle(10, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(10, true)
    },
    ["searchMenuBar"] = {
      message = "Search Menu Bar",
      bindCondition = function(app)
        return Version.LessThan(app, "6") or Version.GreaterEqual(app, "6.1.1")
      end,
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        hs.osascript.applescript(strfmt([[
          tell application id "%s" to quick search
        ]], app:bundleID()))
      end
    },
    ["keyboardNavigate"] = {
      message = "Navigate Menu Bar",
      kind = HK.MENUBAR,
      background = true,
      bindCondition = function(app)
        if Version.GreaterEqual(app, "6") then return false end
        -- the property update in command line is not working
        local _, ok = hs.execute(strfmt(
            "defaults read '%s' hotkeyKeyboardNav", app:bundleID()))
        return ok
      end,
      fn = function(app)
        local output = hs.execute(strfmt(
            "defaults read '%s' hotkeyKeyboardNav", app:bundleID()))
        local spec = strsplit(output, "\n")
        local mods = spec[4]:match("modifierFlags = (%d+)")
        local key = spec[3]:match("keyCode = (%d+)")
        mods, key = parsePlistKeyBinding(mods, key)
        safeGlobalKeyStroke(mods, key)
      end
    },
    ["toggleSidebar"] = {
      message = TC("Show Sidebar"),
      bindCondition = Version.GreaterEqual("6"),
      condition = function(app)
        return app:focusedWindow() ~= nil, app:focusedWindow()
      end,
      fn = function(win)
        local button = getc(towinui(win),
            AX.Toolbar, 1, AX.Button, 1, AX.Button, 1)
        if button then Callback.Press(button) end
      end
    },
    ["view1"] =
    {
      message = Bartender.sidebarItemTitle(1),
      windowFilter = Bartender.WF.Main,
      condition = Bartender.sidebarItemSelectable(1),
      fn = Callback.UISelect
    },
    ["view2"] =
    {
      message = Bartender.sidebarItemTitle(2),
      windowFilter = Bartender.WF.Main,
      condition = Bartender.sidebarItemSelectable(2),
      fn = Callback.UISelect
    },
    ["view3"] =
    {
      message = Bartender.sidebarItemTitle(3),
      windowFilter = Bartender.WF.Main,
      condition = Bartender.sidebarItemSelectable(3),
      fn = Callback.UISelect
    },
    ["view4"] =
    {
      message = Bartender.sidebarItemTitle(4),
      windowFilter = Bartender.WF.Main,
      condition = Bartender.sidebarItemSelectable(4),
      fn = Callback.UISelect
    },
    ["view5"] =
    {
      message = Bartender.sidebarItemTitle(5),
      windowFilter = Bartender.WF.Main,
      condition = Bartender.sidebarItemSelectable(5),
      fn = Callback.UISelect
    },
    ["view6"] =
    {
      message = Bartender.sidebarItemTitle(6),
      windowFilter = Bartender.WF.Main,
      condition = Bartender.sidebarItemSelectable(6),
      fn = Callback.UISelect
    },
    ["view7"] =
    {
      message = Bartender.sidebarItemTitle(7),
      windowFilter = Bartender.WF.Main,
      condition = Bartender.sidebarItemSelectable(7),
      fn = Callback.UISelect
    },
    ["view8"] =
    {
      message = Bartender.sidebarItemTitle(8),
      windowFilter = Bartender.WF.Main,
      condition = Bartender.sidebarItemSelectable(8),
      fn = Callback.UISelect
    },
    ["view9"] =
    {
      message = Bartender.sidebarItemTitle(9),
      windowFilter = Bartender.WF.Main,
      condition = Bartender.sidebarItemSelectable(9),
      fn = Callback.UISelect
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigUpdated("minimize",
        { bindCondition = Version.LessThan("6") }),
    ["quit"] = specialCommonHotkeyConfigs["quit"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
  },

  ["com.HyperartFlow.Barbee"] =
  {
    ["toggleMenuBar"] = {
      message = "Toggle Menu Bar",
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        local barShown = false
        for _, e in ipairs(getc(toappui(app), AX.Window)) do
          if #e == 1 and e[1].AXRole == AX.Group
              and #e[1] == #(getc(e[1], AX.Button) or {}) then
            barShown = true
          end
        end
        if barShown then
          hs.osascript.applescript(strfmt([[
            tell application id "%s" to hide items
          ]], app:bundleID()))
        else
          hs.osascript.applescript(strfmt([[
            tell application id "%s" to show items
          ]], app:bundleID()))
        end
      end
    },
    ["toggleSidebar"] = {
      message = TC("Show Sidebar"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local button = tfind(getc(towinui(app:focusedWindow()),
                                  AX.Toolbar, 1, AX.Button) or {},
            function(bt) return bt.AXDescription == "Sidebar" end)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["click1stBarbeeBarItem"] = {
      message = Barbee.barItemTitle(1),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(1)
    },
    ["click2ndBarbeeBarItem"] = {
      message = Barbee.barItemTitle(2),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(2)
    },
    ["click3rdBarbeeBarItem"] = {
      message = Barbee.barItemTitle(3),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(3)
    },
    ["click4thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(4),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(4)
    },
    ["click5thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(5),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(5)
    },
    ["click6thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(6),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(6)
    },
    ["click7thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(7),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(7)
    },
    ["click8thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(8),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(8)
    },
    ["click9thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(9),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(9)
    },
    ["click10thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(10),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(10)
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["quit"] = specialCommonHotkeyConfigs["quit"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
  },

  ["com.jordanbaird.Ice"] =
  {
    ["click1stIceBarItem"] = {
      message = Ice.barItemTitle(1),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(1)
    },
    ["click2ndIceBarItem"] = {
      message = Ice.barItemTitle(2),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(2)
    },
    ["click3rdIceBarItem"] = {
      message = Ice.barItemTitle(3),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(3)
    },
    ["click4thIceBarItem"] = {
      message = Ice.barItemTitle(4),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(4)
    },
    ["click5thIceBarItem"] = {
      message = Ice.barItemTitle(5),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(5)
    },
    ["click6thIceBarItem"] = {
      message = Ice.barItemTitle(6),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(6)
    },
    ["click7thIceBarItem"] = {
      message = Ice.barItemTitle(7),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(7)
    },
    ["click8thIceBarItem"] = {
      message = Ice.barItemTitle(8),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(8)
    },
    ["click9thIceBarItem"] = {
      message = Ice.barItemTitle(9),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(9)
    },
    ["click10thIceBarItem"] = {
      message = Ice.barItemTitle(10),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(10)
    },
    ["view1"] = {
      message = Ice.sidebarItemTitle(1),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(1)
    },
    ["view2"] = {
      message = Ice.sidebarItemTitle(2),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(2)
    },
    ["view3"] = {
      message = Ice.sidebarItemTitle(3),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(3)
    },
    ["view4"] = {
      message = Ice.sidebarItemTitle(4),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(4)
    },
    ["view5"] = {
      message = Ice.sidebarItemTitle(5),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(5)
    },
    ["view6"] = {
      message = Ice.sidebarItemTitle(6),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(6)
    }
  },

  ["cn.better365.iBar"] =
  {
    ["toggleMenuBar"] = {
      message = "Toggle Menu Bar",
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        local icon = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem, 1)
        local isAdvancedMode = hs.execute(strfmt([[
          defaults read "%s" advancedMode | tr -d '\n'
        ]], app:bundleID()))
        if isAdvancedMode ~= "1" then
          local position = hs.mouse.absolutePosition()
          mouseMove(uioffset(icon, {-10, 10}))
          hs.timer.doAfter(0.2, function()
            mouseMove(uioffset(icon, {-20, 10}))
            hs.timer.doAfter(0.2, function()
              mouseMove(position)
            end)
          end)
        else
          leftClickAndRestore(icon, app)
        end
      end
    },
    ["click1stiBarItem"] = {
      message = iBar.barItemTitle(1),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(1)
    },
    ["click2ndiBarItem"] = {
      message = iBar.barItemTitle(2),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(2)
    },
    ["click3rdiBarItem"] = {
      message = iBar.barItemTitle(3),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(3)
    },
    ["click4thiBarItem"] = {
      message = iBar.barItemTitle(4),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(4)
    },
    ["click5thiBarItem"] = {
      message = iBar.barItemTitle(5),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(5)
    },
    ["click6thiBarItem"] = {
      message = iBar.barItemTitle(6),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(6)
    },
    ["click7thiBarItem"] = {
      message = iBar.barItemTitle(7),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(7)
    },
    ["click8thiBarItem"] = {
      message = iBar.barItemTitle(8),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(8)
    },
    ["click9thiBarItem"] = {
      message = iBar.barItemTitle(9),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(9)
    },
    ["click10thiBarItem"] = {
      message = iBar.barItemTitle(10),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(10)
    }
  },

  ["com.app.menubarx"] =
  {
    ["toggleMenuBarX"] = {
      message = function(app)
        return T("Toggle MenubarX:", app):gsub(":", ""):gsub("：", "")
      end,
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        local appid = app:bundleID()
        local output = hs.execute(strfmt([[
          defaults read '%s' KeyboardShortcuts_toggleX | tr -d '\n'
        ]], appid))
        if output == "0" then
          local spec = KeybindingConfigs.hotkeys[appid]["toggleMenuBarX"]
          local mods, key = dumpPlistKeyBinding(1, spec.mods, spec.key)
          hs.execute(strfmt([[
            defaults write '%s' KeyboardShortcuts_toggleX -string \
            '{"carbonKeyCode":%d,"carbonModifiers":%d}'
          ]], appid, key, mods))
          app:kill()
          hs.timer.doAfter(1, function()
            hs.execute(strfmt("open -g -b '%s'", appid))
            hs.timer.doAfter(1, function()
              safeGlobalKeyStroke(spec.mods, spec.key)
            end)
          end)
        else
          local json = hs.json.decode(output)
          local mods, key = parsePlistKeyBinding(
              json["carbonModifiers"], json["carbonKeyCode"])
          if mods == nil or key == nil then return end
          safeGlobalKeyStroke(mods, key)
        end
      end
    }
  },

  ["com.gaosun.eul"] =
  {
    ["showSystemStatus"] = {
      message = "Show System Status",
      kind = HK.MENUBAR,
      background = true,
      fn = clickRightMenuBarItem
    },
    ["preferencesFromMB"] = {
      message = TMB("Preferences"),
      menubarFilter = { allowTitles = 'eul' },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local button = getc(menu, AX.MenuItem, 1, AX.Group, 1,
            AX.StaticText, title)
        local app = getAppFromDescendantElement(menu)
        leftClickAndRestore(button, app, 0.2)
      end
    }
  },

  ["whbalzac.Dongtaizhuomian"] =
  {
    ["invokeInAppScreenSaver"] = {
      message = T("In-app Screensaver",
                                { localeFile = "HotkeyWindowController" }),
      background = true,
      fn = function(app)
        clickRightMenuBarItem(app, T("In-app Screensaver", app,
                                   { localeFile = "HotkeyWindowController" }))
      end
    },
    ["preferencesFromMB"] = {
      message = TMB("Preferences..."),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["pl.maketheweb.TopNotch"] =
  {
    ["toggleTopNotch"] = {
      message = "Toggle Top Notch",
      background = true,
      fn = function(app)
        local invoked = clickRightMenuBarItem(app)
        if not invoked then return end
        local appUI = toappui(app)
        hs.timer.doAfter(1, function()
          local switch = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1,
              AX.Popover, 1, AX.Group, 3, AX.Button, 1)
          if switch == nil then
            hs.timer.usleep(0.1 * 1000000)
            switch = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1,
                AX.Popover, 1, AX.Group, 3, AX.Button, 2)
          end
          local state = switch.AXValue
          Callback.Press(switch)
          if state == 'off' then
            hs.eventtap.keyStroke("", "Escape", nil, app)
          else
            hs.timer.doAfter(0.1, function()
              hs.eventtap.keyStroke("", "Space", nil, app)
            end)
          end
        end)
      end
    }
  },

  ["com.jetbrains.toolbox"] =
  {
    ["toggleJetbrainsToolbox"] = {
      message = "Toggle Jetbrains Toolbox",
      background = true,
      fn = focusOrHide
    }
  },

  ["com.mathpix.snipping-tool-noappstore"] =
  {
    ["OCRForLatex"] = {
      message = "OCR for LaTeX",
      background = true,
      fn = function(app)
        local appid = app:bundleID()
        local mods = hs.execute(strfmt(
            "defaults read '%s' getLatexHotKeyModifiersKey | tr -d '\\n'", appid))
        local key = hs.execute(strfmt(
            "defaults read '%s' getLatexHotKeyKey | tr -d '\\n'", appid))
        mods, key = parsePlistKeyBinding(mods, key)
        -- the property update in command line is overridden when app quits
        if mods == nil or key == nil then return end
        local enabled = hs.execute(strfmt(
            "defaults read '%s' getLatexShortcutEnabledKey | tr -d '\\n'", appid))
        if enabled == "0" then
          hs.execute(strfmt(
              "defaults write '%s' getLatexShortcutEnabledKey 1", appid))
          app:kill()
          hs.timer.doAfter(1, function()
            hs.execute(strfmt("open -g -b '%s'", appid))
            hs.timer.doAfter(1, function()
              safeGlobalKeyStroke(mods, key)
            end)
          end)
        end
        safeGlobalKeyStroke(mods, key)
      end
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["hidePopover"] = {
      mods = "", key = "Escape",
      message = "Hide Popover",
      windowFilter = {
        allowPopover = true
      },
      fn = function(win)
        clickRightMenuBarItem(win:application())
      end
    }
  },

  ["com.apple.TextInputMenuAgent"] =
  {
    ["openKeyboardSettingsFromMB"] = {
      message = function(menu)
        local menuItem = getc(menu, AX.MenuItem, -1)
        if menuItem then
          return displayName("com.apple.TextInputMenuAgent")
              .. ' >' .. getc(menu, AX.MenuItem, -1).AXTitle
        end
      end,
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local menuItem = getc(menu, AX.MenuItem, -1)
        Callback.Press(menuItem)
      end
    }
  },

  ["com.apple.Passwords"] = {
    ["search"] = {
      message = T("Search"),
      bindCondition = function() return OS_VERSION >= OS.Tahoe end,
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local searchButton = getc(towinui(app:focusedWindow()),
            AX.Toolbar, 1, AX.Group, -1, AX.TextField, 1, AX.Button, 1)
        return Callback.Clickable(searchButton)
      end,
      fn = Callback.Click
    }
  },

  ["com.apple.Passwords.MenuBarExtra"] =
  {
    ["showPasswordsDialog"] = {
      message = TB("com.apple.Passwords", "Show"),
      background = true,
      fn = clickRightMenuBarItem
    },
    ["newPassword"] = {
      message = T("New Password"),
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Group, 1, AX.Button, 'plus')
        return button ~= nil, button
      end,
      background = true,
      fn = Callback.Press
    },
    ["showAllPasswordsFromMB"] = {
      message = T("Show all passwords"),
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Group, 1, AX.Button, 'macwindow')
        return button ~= nil, button
      end,
      background = true,
      fn = Callback.Press
    },
    ["back"] = {
      message = T("Back"),
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = function(win)
        local winUI = towinui(win)
        local elem = getc(winUI, AX.Group, 1)[1]
        return elem.AXRole == AX.Button, elem
      end,
      background = true,
      fn = Callback.Press
    },
    ["copyUserName"] = {
      message = T("Copy User Name"),
      windowFilter = PasswordsMenuBarExtra.WF,
      background = true,
      condition = PasswordsMenuBarExtra.recordField("User Name"),
      fn = function(field, win)
        Callback.Click(field)
        clickRightMenuBarItem(win:application())
      end
    },
    ["copyPassword"] = {
      message = T("Copy Password"),
      windowFilter = PasswordsMenuBarExtra.WF,
      background = true,
      condition = PasswordsMenuBarExtra.recordField("Password"),
      fn = function(field, win)
        Callback.Click(field)
        clickRightMenuBarItem(win:application())
      end
    },
    ["copyVerificationCode"] = {
      message = function(win)
        local title = OS_VERSION >= OS.Tahoe and "Copy Code"
            or "Copy Verification Code"
        return T(title, win)
      end,
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordField(
          OS_VERSION >= OS.Tahoe and "Code" or "Verification Code"),
      background = true,
      fn = function(field, win)
        Callback.Click(field)
        clickRightMenuBarItem(win:application())
      end
    },
    ["record1"] = {
      message = "Record 1",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(1),
      background = true,
      fn = Callback.Click
    },
    ["record2"] = {
      message = "Record 2",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(2),
      background = true,
      fn = Callback.Click
    },
    ["record3"] = {
      message = "Record 3",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(3),
      background = true,
      fn = Callback.Click
    },
    ["record4"] = {
      message = "Record 4",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(4),
      background = true,
      fn = Callback.Click
    },
    ["record5"] = {
      message = "Record 5",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(5),
      background = true,
      fn = Callback.Click
    },
    ["record6"] = {
      message = "Record 6",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(6),
      background = true,
      fn = Callback.Click
    },
    ["record7"] = {
      message = "Record 7",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(7),
      background = true,
      fn = Callback.Click
    },
    ["record8"] = {
      message = "Record 8",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(8),
      background = true,
      fn = Callback.Click
    }
  },

  ["com.apple.weather.menu"] = {
    ["openWeatherFromMB"] = {
      message = TMB("com.apple.weather", "Open Weather"),
      windowFilter = {
        allowRoles = AX.SystemDialog
      },
      background = true,
      fn = function(win)
        local button = getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Button, -1)
        if button then Callback.Press(button) end
      end
    },
    ["closeWindow"] = {
      mods = "", key = "Escape",
      message = TC("Close Window"),
      bindCondition = function() return OS_VERSION < OS.Tahoe end,
      windowFilter = {
        allowRoles = AX.SystemDialog
      },
      background = true,
      fn = function(win)
        local menuBarItem = getc(toappui(win:application()),
            AX.MenuBar, -1, AX.MenuBarItem, 1)
        if menuBarItem then
          Callback.Press(menuBarItem)
        end
      end
    }
  },

  ["com.macosgame.iwallpaper"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"]
  },

  ["org.pqrs.Karabiner-Elements.Settings"] =
  {
    ["toggleSidebar"] = {
      message = "Toggle Sidebar",
      condition = function(app)
        if app:focusedWindow() == nil then return end
        local button = getc(towinui(app:focusedWindow()), AX.Toolbar, 1, AX.Button, 1)
        if button == nil then return end
        local msg = button.AXDescription
        if msg == "Show Sidebar" or msg == "Hide Sidebar" then
          return true, button
        end
      end,
      fn = Callback.Press
    }
  },

  ["org.pqrs.Karabiner-Menu"] =
  {
    ["settingsFromMB"] = {
      message = TMB("org.pqrs.Karabiner-Elements.Settings", "Settings..."),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["org.pqrs.Karabiner-EventViewer"] =
  {
    ["toggleSidebar"] = {
      message = "Toggle Sidebar",
      condition = function(app)
        if app:focusedWindow() == nil then return end
        local button = getc(towinui(app:focusedWindow()), AX.Toolbar, 1, AX.Button, 1)
        if button == nil then return end
        local msg = button.AXDescription
        if msg == "Show Sidebar" or msg == "Hide Sidebar" then
          return true, button
        end
      end,
      fn = Callback.Press
    },
    ["closeWindow"] = specialCommonHotkeyConfigUpdated("closeWindow",
      { bindCondition = Version.LessThan("15.4") }
    ),
    ["minimize"] = specialCommonHotkeyConfigUpdated("minimize",
      { bindCondition = Version.LessThan("15.4") }
    ),
    ["hide"] = specialCommonHotkeyConfigUpdated("hide",
      { bindCondition = Version.LessThan("15.4") }
    ),
  },

  ["me.guillaumeb.MonitorControl"] =
  {
    ["preferencesFromMB"] = {
      message = TMB("Preferences…"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["com.pigigaldi.pock"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
    ["quit"] = specialCommonHotkeyConfigs["quit"]
  },

  ["com.mac.utility.screen.recorder"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
  },

  ["com.tencent.LemonUpdate"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"]
  },

  ["com.ameba.SwiftBar"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
    ["quit"] = specialCommonHotkeyConfigs["quit"]
  },

  ["com.apple.controlcenter"] =
  {
    ["closeWindow"] = {
      mods = "", key = "Escape",
      message = TC("Close Window"),
      bindCondition = function() return OS_VERSION >= OS.Tahoe end,
      windowFilter = {
        allowTitles = "^$",
        allowRoles = AX.SystemDialog,
        fn = function(win)
          local g = getc(towinui(win), AX.Group, 1, AX.Group, 1)
          return g and g.AXIdentifier
              and g.AXIdentifier:find('.liveActivity') ~= nil
        end
      },
      background = true,
      nonFrontmost = true,
      condition = function(win)
        local g = getc(towinui(win), AX.Group, 1, AX.Group, 1)
        if g == nil or g.AXIdentifier == nil then
          return false
        end
        local ident = g.AXIdentifier
        local s, e = ident:find('.liveActivity')
        if s == nil then return false end
        local prefix = ident:sub(1, e)
        local menuBarItems = getc(toappui(win:application()),
            AX.MenuBar, -1, AX.MenuBarItem)
        local menuBarItem = tfind(menuBarItems, function(item)
          return item.AXIdentifier and item.AXIdentifier:sub(1, e) == prefix
        end)
        return Callback.Clickable(menuBarItem)
      end,
      fn = Callback.Click
    }
  },

  ["com.apple.Image_Capture"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.VoiceOverUtility"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.DigitalColorMeter"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.CaptiveNetworkAssistant"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.CertificateAssistant"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.displaycalibrator"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"]
  },

  ["com.apple.DeskCam"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.Chess"] =
  {
    ["openRecent"] = {
      message = T("Open Recent"),
      condition = MenuItem.isEnabled({ "Game", "Open Recent" }),
      fn = Callback.Select
    },
  },

  ["com.apple.clock"] = {
    ["openRecent"] = {
      message = T("Start Recent Timer"),
      condition = MenuItem.isEnabled({ "File", "Start Recent Timer" }),
      fn = Callback.Select
    },
  },

  ["com.apple.ScreenSharing"] =
  {
    ["openRecent"] = {
      message = T("Open Recent"),
      condition = MenuItem.isEnabled({ "Connect", "Open Recent" }),
      fn = Callback.Select
    },
  },

  ["com.microsoft.rdc.macos"] = {
    ["toggleSidebar"] = {
      message = TC("Show Sidebar"),
      condition = function(app)
        if app:focusedWindow() == nil then return end
        local buttons = getc(towinui(app:focusedWindow()), AX.Toolbar, 1, AX.Button)
        if buttons == nil then return end
        local btTitle = T("Sidebar", app)
        local button = tfind(buttons, function(bt)
          return bt.AXDescription == btTitle
        end)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
  },

  ["com.realvnc.vncviewer"] = {
    ["search"] = {
      message = "Search",
      windowFilter = {
        allowTitles = "^(Real)VNC Viewer$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local searchField = getc(winUI, AX.TextField, 1)
        return Callback.Clickable(searchField, { 5, 5 })
      end,
      fn = Callback.Click
    },
    ["toggleSidebar"] = {
      message = "Toggle sidebar",
      condition = MenuItem.isEnabled({ "View", "Show sidebar" }),
      fn = Callback.Select
    },
    ["toggleStatusBar"] = {
      message = "Toggle status bar",
      condition = MenuItem.isEnabled({ "View", "Show status bar" }),
      fn = Callback.Select
    },
    ["viewIcons"] = {
      message = "View > Icons",
      condition = MenuItem.isEnabled({ "View", "Icons" }),
      fn = Callback.Select
    },
    ["viewDetails"] = {
      message = "View > Details",
      condition = MenuItem.isEnabled({ "View", "Details" }),
      fn = Callback.Select
    }
  },

  ["com.parallels.desktop.console"] =
  {
    ["new..."] = {
      mods = "⌘", key = "N",
      message = T("New..."),
      condition = MenuItem.isEnabled({ "File", "New..." }),
      fn = Callback.Select
    },
    ["open..."] = {
      mods = "⌘", key = "O",
      message = T("Open..."),
      condition = MenuItem.isEnabled({ "File", "Open..." }),
      fn = Callback.Select
    },
    ["showControlCenter"] = {
      message = T("Control Center"),
      condition = MenuItem.isEnabled({ "Window", "Control Center" }),
      fn = Callback.Select
    },
    ["expandedView"] = {
      message = T("Expanded View"),
      windowFilter = Parallels.WF.ControlCenter,
      condition = MenuItem.isEnabled({ "View", "Expanded View" }),
      fn = Callback.Select
    },
    ["compactView"] = {
      message = T("Compact View"),
      windowFilter = Parallels.WF.ControlCenter,
      condition = MenuItem.isEnabled({ "View", "Compact View" }),
      fn = Callback.Select
    },
    ["minimize"] = {
      message = T("Minimize"),
      condition = MenuItem.isEnabled({ "Window", "Minimize" }),
      fn = Callback.Select
    },
    ["closeWindow"] = {
      message = T("Close Window"),
      condition = function(app)
        local menuItem, menuItemTitle =
            findMenuItem(app, { "File", "Close Window" })
        if menuItem ~= nil and menuItem.enabled then
          return true, menuItemTitle
        elseif app:focusedWindow() ~= nil then
          return true, app:focusedWindow()
        else
          return false
        end
      end,
      repeatable = true,
      fn = function(result, app)
        if type(result) == 'table' then
          app:selectMenuItem(result)
        else
          result:close()
        end
      end
    }
  },

  ["org.wireshark.Wireshark"] =
  {
    ["closeWindow"] = {
      message = T("Close"),
      condition = function(app)
        local menuItem, menuItemTitle =
            findMenuItem(app, { "File", "Close" })
        if menuItem ~= nil and menuItem.enabled then
          return true, menuItemTitle
        else
          local win = app:focusedWindow()
          return win ~= nil and win:role() == AX.Window, win
        end
      end,
      fn = function(result, app)
        if type(result) == 'table' then
          app:selectMenuItem(result)
        else
          result:close()
        end
      end
    }
  },

  ["re.rizin.cutter"] =
  {
    ["preferences"] = {
      message = T("Preferences"),
      condition = MenuItem.isEnabled({ "Edit", "Preferences" }),
      fn = Callback.Select
    },
    ["quit"] = {
      message = T("Quit"),
      condition = MenuItem.isEnabled({ "File", "Quit" }),
      fn = Callback.Select
    }
  },

  ["com.apple.Terminal"] =
  {
    ["tmuxPreviousPane"] = {
      -- previous pane
      message = "Previous Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "o", nil, win:application())
      end
    },
    ["tmuxNextPane"] = {
      -- next pane
      message = "Next Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", ";", nil, win:application())
      end
    },
    ["tmuxAbovePane"] = {
      -- above pane
      message = "Above Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "Up", nil, win:application())
      end
    },
    ["tmuxBelowPane"] = {
      -- below pane
      message = "Below Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "Down", nil, win:application())
      end
    },
    ["tmuxLeftPane"] = {
      -- left pane
      message = "Left Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "Left", nil, win:application())
      end
    },
    ["tmuxRightPane"] = {
      -- right pane
      message = "Right Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "Right", nil, win:application())
      end
    },
    ["tmuxNewHorizontalPane"] = {
      -- new pane (horizontal)
      message = "New Pane (Horizontal)",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("⇧", "5", nil, win:application())  -- %
      end
    },
    ["tmuxNewVerticalPane"] = {
      -- new pane (vertical)
      message = "New Pane (Vertical)",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("⇧", "'", nil, win:application())  -- "
      end
    },
    ["tmuxClosePane"] = {
      -- close pane
      message = "Close Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "x", nil, win:application())
      end
    },
    ["tmuxPreviousWindow"] = {
      -- previous window
      message = "Previous Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "p", nil, win:application())
      end
    },
    ["tmuxNextWindow"] = {
      -- next window
      message = "Next Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "n", nil, win:application())
      end
    },
    ["tmuxWindow0"] = {
      -- 0th window
      message = "0th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "0", nil, win:application())
      end
    },
    ["tmuxWindow1"] = {
      -- 1st window
      message = "1st Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "1", nil, win:application())
      end
    },
    ["tmuxWindow2"] = {
      -- 2nd window
      message = "2nd Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "2", nil, win:application())
      end
    },
    ["tmuxWindow3"] = {
      -- 3rd window
      message = "3rd Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "3", nil, win:application())
      end
    },
    ["tmuxWindow4"] = {
      -- 4th window
      message = "4th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "4", nil, win:application())
      end
    },
    ["tmuxWindow5"] = {
      -- 5th window
      message = "5th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "5", nil, win:application())
      end
    },
    ["tmuxWindow6"] = {
      -- 6th window
      message = "6th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "6", nil, win:application())
      end
    },
    ["tmuxWindow7"] = {
      -- 7th window
      message = "7th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "7", nil, win:application())
      end
    },
    ["tmuxWindow8"] = {
      -- 8th window
      message = "8th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "8", nil, win:application())
      end
    },
    ["tmuxWindow9"] = {
      -- 9th window
      message = "9th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "9", nil, win:application())
      end
    },
    ["tmuxNewWindow"] = {
      message = "New Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "c", nil, win:application())
      end
    },
    ["tmuxCloseWindow"] = {
      message = "Close Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("⇧", "7", nil, win:application())  -- &
      end
    },
    ["tmuxDetachSession"] = {
      message = "Detach Session",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "D", nil, win:application())
      end
    },
    ["tmuxEnterCopyMode"] = {
      message = "Copy Mode",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "[", nil, win:application())
      end
    },
    ["tmuxSearch"] = {
      message = "Search",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "[", nil, win:application())
        hs.eventtap.keyStroke("⌃", "s", nil, win:application())  -- emacs mode
      end
    }
  },

  ["com.torusknot.SourceTreeNotMAS"] =
  {
    ["showInFinder"] = {
      message = T("Show In Finder"),
      condition = MenuItem.isEnabled({ "Actions", "Show In Finder" }),
      fn = Callback.Select
    }
  },

  ["com.apple.dt.Xcode"] =
  {
    ["showInFinder"] = {
      message = "Show in Finder",
      condition = MenuItem.isEnabled({ "File", "Show in Finder" }),
      fn = Callback.Select
    }
  },

  ["com.jetbrains.CLion"] =
  {
    ["newProject"] = {
      message = "New Project",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = function(win)
        local menuItemPath = {"File", "New", "Project…"}
        local ok = win:application():findMenuItem(menuItemPath)
        if ok then return ok, menuItemPath end
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1)
          if #button > 0 then
            button = button[1]
          end
        end
        return Callback.Clickable(button)
      end,
      fn = function(menuItemOrButton, win)
        if menuItemOrButton.AXPosition then
          Callback.Click(menuItemOrButton)
        else
          Callback.Select(menuItemOrButton, win)
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = MenuItem.isEnabled({"File", "Open..."}, {"File", "Open…"}),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = "Recent Projects",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = MenuItem.isEnabled({"File", "Recent Projects"}),
      fn = Callback.Select
    }
  },

  ["com.jetbrains.CLion-EAP"] =
  {
    ["newProject"] = {
      message = "New Project",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = function(win)
        local menuItemPath = {"File", "New", "Project…"}
        local ok = win:application():findMenuItem(menuItemPath)
        if ok then return ok, menuItemPath end
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1)
          if #button > 0 then
            button = button[1]
          end
        end
        return Callback.Clickable(button)
      end,
      fn = function(menuItemOrButton, win)
        if menuItemOrButton.AXPosition then
          Callback.Click(menuItemOrButton)
        else
          Callback.Select(menuItemOrButton, win)
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = MenuItem.isEnabled({"File", "Open..."}, {"File", "Open…"}),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = "Recent Projects",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = MenuItem.isEnabled({"File", "Recent Projects"}),
      fn = Callback.Select
    }
  },

  ["com.jetbrains.intellij"] =
  {
    ["newProject"] = {
      message = "New Project",
      windowFilter = {
        allowTitles = "Welcome to IntelliJ IDEA"
      },
      condition = function(win)
        local menuItemPath = {"File", "New", "Project…"}
        local ok = win:application():findMenuItem(menuItemPath)
        if ok then return ok, menuItemPath end
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1)
          if #button > 0 then
            button = button[1]
          end
        end
        return Callback.Clickable(button)
      end,
      fn = function(menuItemOrButton, win)
        if menuItemOrButton.AXPosition then
          Callback.Click(menuItemOrButton)
        else
          Callback.Select(menuItemOrButton, win)
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to IntelliJ IDEA"
      },
      condition = MenuItem.isEnabled({"File", "Open..."}, {"File", "Open…"}),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = "Recent Projects",
      windowFilter = {
        allowTitles = "Welcome to IntelliJ IDEA"
      },
      condition = MenuItem.isEnabled({"File", "Recent Projects"}),
      fn = Callback.Select
    }
  },

  ["com.jetbrains.pycharm"] =
  {
    ["newProject"] = {
      message = "New Project",
      windowFilter = {
        allowTitles = "Welcome to PyCharm"
      },
      condition = function(win)
        local menuItemPath = {"File", "New", "Project…"}
        local ok = win:application():findMenuItem(menuItemPath)
        if ok then return ok, menuItemPath end
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1)
          if #button > 0 then
            button = button[1]
          end
        end
        return Callback.Clickable(button)
      end,
      fn = function(menuItemOrButton, win)
        if menuItemOrButton.AXPosition then
          Callback.Click(menuItemOrButton)
        else
          Callback.Select(menuItemOrButton, win)
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to PyCharm"
      },
      condition = MenuItem.isEnabled({"File", "Open..."}, {"File", "Open…"}),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = "Recent Projects",
      windowFilter = {
        allowTitles = "Welcome to PyCharm"
      },
      condition = MenuItem.isEnabled({"File", "Recent Projects"}),
      fn = Callback.Select
    }
  },

  ["org.qt-project.Designer"] =
  {
    ["openRecent"] = {
      message = T("&Recent Forms"),
      condition = MenuItem.isEnabled({ "File", "&Recent Forms" }),
      fn = Callback.Select
    }
  },

  ["org.qt-project.Linguist"] =
  {
    ["openRecent"] = {
      message = T("Recently Opened &Files"),
      condition = MenuItem.isEnabled({ "File", "Recently Opened &Files" }),
      fn = Callback.Select
    }
  },

  ["io.mountainduck"] =
  {
    ["preferencesFromMB"] = {
      message = TMB("Preferences…"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    },
    ["openConnectionFromMB"] = {
      message = TMB("Open Connection…"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    },
    ["historyFromMB"] = {
      message = TMB("History"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then
          Callback.Press(menu.AXParent)
          mouseMove(uioffset(menuItem, { 20, 5 }))
          hs.timer.doAfter(0.1, function()
            mouseMove(uioffset(menuItem, { 10, 5 }))
          end)
        end
      end
    },
    ["quitFromMB"] = {
      message = function(menu)
        local app = getAppFromDescendantElement(menu)
        local quit = T("Quit", app)
        return quit .. ' ' .. app:name()
      end,
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local menuItem = getc(menu, AX.MenuItem, A_Message)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["org.adblockplus.adblockplussafarimac"] = {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.better365.BetterAndBetterHelper"] = {
    ["preferencesFromMB"] = {
      message = TMB("cn.better365.BetterAndBetter", "Preferences"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["cn.better365.iShotProHelper"] =
  {
    ["OCR"] = {
      message = "OCR",
      background = true,
      bindCondition = function(appid)
        -- the property update in command line is overridden when app quits
        local _, ok = hs.execute(strfmt(
            "defaults read '%s' dicOfShortCutKey | grep OCRRecorder", appid))
        return ok
      end,
      fn = function(app)
        local output = hs.execute(strfmt(
            "defaults read '%s' dicOfShortCutKey | grep OCRRecorder -A4",
            app:bundleID()))
        local spec = strsplit(output, "\n")
        local mods = spec[5]:match("modifierFlags = (%d+);")
        local key = spec[4]:match("keyCode = (%d+);")
        mods, key = parsePlistKeyBinding(mods, key)
        if mods == nil or key == nil then return end
        safeGlobalKeyStroke(mods, key)
      end
    },
    ["preferencesFromMB"] = {
      message = TMB("cn.better365.iShotPro", "Preferences"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["cn.better365.Cleaner"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
    ["quit"] = specialCommonHotkeyConfigs["quit"]
  },

  ["cn.better365.iCopy"] =
  {
    ["setting"] = {
      message = T("Setting"),
      windowFilter = iCopy.WF.Main,
      fn = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 1)
        if button ~= nil then Callback.Press(button) end
      end
    },
    ["select1stItem"] = {
      mods = "⌘", key = "1",
      message = "Select 1st Item",
      bindCondition = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(1)
    },
    ["select2ndItem"] = {
      mods = "⌘", key = "2",
      message = "Select 2nd Item",
      bindCondition = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(2)
    },
    ["select3rdItem"] = {
      mods = "⌘", key = "3",
      message = "Select 3rd Item",
      bindCondition = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(3)
    },
    ["select4thItem"] = {
      mods = "⌘", key = "4",
      message = "Select 4th Item",
      bindCondition = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(4)
    },
    ["select5thItem"] = {
      mods = "⌘", key = "5",
      message = "Select 5th Item",
      bindCondition = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(5)
    },
    ["select6thItem"] = {
      mods = "⌘", key = "6",
      message = "Select 6th Item",
      bindCondition = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(6)
    },
    ["select7thItem"] = {
      mods = "⌘", key = "7",
      message = "Select 7th Item",
      bindCondition = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(7)
    },
    ["select8thItem"] = {
      mods = "⌘", key = "8",
      message = "Select 8th Item",
      bindCondition = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(8)
    },
    ["select9thItem"] = {
      mods = "⌘", key = "9",
      message = "Select 9th Item",
      bindCondition = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(9)
    },
    ["select10thItem"] = {
      mods = "⌘", key = "0",
      message = "Select 10th Item",
      bindCondition = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(10)
    },
    ["previousItem"] = {
      mods = "", key = "Left",
      message = "Previous Item",
      windowFilter = iCopy.WF.Main,
      repeatable = true,
      fn = function(win)
        hs.eventtap.keyStroke("", "Up", nil, win:application())
      end
    },
    ["nextItem"] = {
      mods = "", key = "Right",
      message = "Next Item",
      windowFilter = iCopy.WF.Main,
      repeatable = true,
      fn = function(win)
        hs.eventtap.keyStroke("", "Down", nil, win:application())
      end
    },
    ["cancelUp"] = {
      mods = "", key = "Up",
      message = "Cancel Up",
      windowFilter = iCopy.WF.Main,
      fn = function() end
    },
    ["cancelDown"] = {
      mods = "", key = "Down",
      message = "Cancel Down",
      windowFilter = iCopy.WF.Main,
      fn = function() end
    },
    ["cancelTap"] = {
      mods = "", key = "Tab",
      message = "Cancel Tab",
      windowFilter = iCopy.WF.Main,
      fn = function() end
    }
  }
}

local browserTabHotKeyCallbacks = {
  ["weiboNavigate1stCommonGroup"] = {
    message = Web.Weibo.sideBarTitle(1, true),
    condition = Web.Weibo.navigateToSideBarCondition(1, true),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate2ndCommonGroup"] = {
    message = Web.Weibo.sideBarTitle(2, true),
    condition = Web.Weibo.navigateToSideBarCondition(2, true),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate3rdCommonGroup"] = {
    message = Web.Weibo.sideBarTitle(3, true),
    condition = Web.Weibo.navigateToSideBarCondition(3, true),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate4thCommonGroup"] = {
    message = Web.Weibo.sideBarTitle(4, true),
    condition = Web.Weibo.navigateToSideBarCondition(4, true),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate1stCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(1),
    condition = Web.Weibo.navigateToSideBarCondition(1),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate2ndCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(2),
    condition = Web.Weibo.navigateToSideBarCondition(2),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate3rdCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(3),
    condition = Web.Weibo.navigateToSideBarCondition(3),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate4thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(4),
    condition = Web.Weibo.navigateToSideBarCondition(4),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate5thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(5),
    condition = Web.Weibo.navigateToSideBarCondition(5),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate6thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(6),
    condition = Web.Weibo.navigateToSideBarCondition(6),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate7thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(7),
    condition = Web.Weibo.navigateToSideBarCondition(7),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate8thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(8),
    condition = Web.Weibo.navigateToSideBarCondition(8),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate9thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(9),
    condition = Web.Weibo.navigateToSideBarCondition(9),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate10thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(10),
    condition = Web.Weibo.navigateToSideBarCondition(10),
    fn = Web.Weibo.navigateToSideBar
  },

  ["douyinNavigate1stTab"] = {
    message = Web.Douyin.tabTitle(1),
    condition = Web.Douyin.navigateToTabCondition(1),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate2ndTab"] = {
    message = Web.Douyin.tabTitle(2),
    condition = Web.Douyin.navigateToTabCondition(2),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate3rdTab"] = {
    message = Web.Douyin.tabTitle(3),
    condition = Web.Douyin.navigateToTabCondition(3),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate4thTab"] = {
    message = Web.Douyin.tabTitle(4),
    condition = Web.Douyin.navigateToTabCondition(4),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate5thTab"] = {
    message = Web.Douyin.tabTitle(5),
    condition = Web.Douyin.navigateToTabCondition(5),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate6thTab"] = {
    message = Web.Douyin.tabTitle(6),
    condition = Web.Douyin.navigateToTabCondition(6),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate7thTab"] = {
    message = Web.Douyin.tabTitle(7),
    condition = Web.Douyin.navigateToTabCondition(7),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate8thTab"] = {
    message = Web.Douyin.tabTitle(8),
    condition = Web.Douyin.navigateToTabCondition(8),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate9thTab"] = {
    message = Web.Douyin.tabTitle(9),
    condition = Web.Douyin.navigateToTabCondition(9),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate10thTab"] = {
    message = Web.Douyin.tabTitle(10),
    condition = Web.Douyin.navigateToTabCondition(10),
    fn = Web.Douyin.navigateToTab
  }
}
for _, appid in ipairs{
  "com.apple.Safari", "com.google.Chrome",
  "com.microsoft.edgemac", "com.microsoft.edgemac.Dev"
} do
  if appHotKeyCallbacks[appid] == nil then
    appHotKeyCallbacks[appid] = {}
  end
  for k, v in pairs(browserTabHotKeyCallbacks) do
    appHotKeyCallbacks[appid][k] = v
  end
  if KeybindingConfigs.hotkeys[appid] == nil then
    KeybindingConfigs.hotkeys[appid] = {}
  end
  for k, v in pairs(KeybindingConfigs.hotkeys.browsers or {}) do
    KeybindingConfigs.hotkeys[appid][k] = v
  end
end

-- hotkeys for background apps
local function registerRunningAppHotKeys(appid, app)
  if appHotKeyCallbacks[appid] == nil then return end
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  if runningAppHotKeys[appid] == nil then
    runningAppHotKeys[appid] = {}
  end

  local running = true
  -- do not support "condition" property currently
  for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
    if runningAppHotKeys[appid][hkID] ~= nil then
      runningAppHotKeys[appid][hkID]:enable()
      goto L_CONTINUE
    end
    -- prefer properties specified in configuration file than in code
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isPersistent = keybinding.persist ~= nil
        and keybinding.persist or cfg.persist
    local isBackground = isPersistent or (keybinding.background ~= nil
        and keybinding.background or cfg.background)
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local bindable
    if isPersistent and installed(appid) then
      bindable = function()
        return cfg.bindCondition == nil or cfg.bindCondition(appid)
      end
    else
      bindable = function()
        if not running then return false end
        if app == nil then
          if FLAGS["LOADING"] then
            app = runningAppsOnLoading[appid]
          else
            app = find(appid)
          end
        end
        running = app ~= nil
        return app and (cfg.bindCondition == nil or cfg.bindCondition(app))
      end
    end
    if hasKey and isBackground and not isForWindow and bindable() then
      local fn
      if isPersistent then
        fn = function()
          if find(appid) then
            cfg.fn(find(appid))
          else
            hs.execute(strfmt("open -g -b '%s'", appid))
            hs.timer.doAfter(1, A_HotkeyWrapper(function()
              if find(appid) then
                local cb = cfg.onLaunch or cfg.fn
                cb(find(appid))
              end
            end))
          end
        end
      else
        fn = bind(cfg.fn, app)
      end
      local repeatable = keybinding.repeatable ~= nil
          and keybinding.repeatable or cfg.repeatable
      local repeatedFn = repeatable and fn or nil
      local msg
      if type(cfg.message) == 'string' then
        msg = cfg.message
      elseif not isPersistent then
        msg = cfg.message(app)
      else
        msg = cfg.message(appid)
      end
      if msg ~= nil then
        local hotkey = bindHotkeySpec(keybinding, msg, fn, nil, repeatedFn)
        if isPersistent then
          hotkey.persist = true
        end
        hotkey.kind = cfg.kind or HK.BACKGROUND
        hotkey.appid = appid
        runningAppHotKeys[appid][hkID] = hotkey
      end
    end
    ::L_CONTINUE::
  end
end

local function unregisterRunningAppHotKeys(appid)
  if appHotKeyCallbacks[appid] == nil then return end

  local allDeleted = true
  for _, hotkey in pairs(runningAppHotKeys[appid] or {}) do
    if not hotkey.persist then
      hotkey:delete()
    else
      allDeleted = false
    end
  end
  if allDeleted then
    runningAppHotKeys[appid] = nil
  end
end

------------------------------------------------------------
-- Context-aware hotkey registration
--
-- This section implements a unified hotkey system that supports:
--
--   - App-scoped hotkeys (active application)
--   - Window-scoped hotkeys (focused window, with filters)
--   - Background (daemon) app hotkeys
--   - Menu bar–scoped hotkeys
--
-- A hotkey may be registered:
--   - eagerly or lazily
--   - conditionally (runtime UI / menu / focus state)
--   - chained with other hotkeys sharing the same key binding
--
-- The core idea is:
--   hotkey = keybinding + condition + execution context
--
-- All hotkeys are dynamically enabled / disabled based on:
--   - app lifecycle
--   - window focus changes
--   - menu open / close state
------------------------------------------------------------

-- Check whether an application owns menu bar status items.
--
-- This is used to determine whether we should register
-- menu bar observers for hotkey validity tracking.
local function hasStatusItems(app)
  local appid = app:bundleID() or app:name()
  local errorReadingDefaults = false
  local plistPath, defaults
  local prefix = "NSStatusItem Preferred Position "
  plistPath = hs.fs.pathToAbsolute(strfmt(
      "~/Library/Containers/%s/Data/Library/Preferences/%s.plist", appid, appid))
  if plistPath ~= nil then
    defaults = hs.plist.read(plistPath)
    if defaults then
      local prefix_len = #prefix
      for k, v in pairs(defaults) do
        if k:sub(1, prefix_len) == prefix then
          return true
        end
      end
    else
      errorReadingDefaults = true
    end
  end
  plistPath = hs.fs.pathToAbsolute(strfmt(
      "~/Library/Preferences/%s.plist", appid))
  if plistPath ~= nil then
    defaults = hs.plist.read(plistPath)
    if defaults then
      local prefix_len = #prefix
      for k, v in pairs(defaults) do
        if k:sub(1, prefix_len) == prefix then
          return true
        end
      end
    else
      errorReadingDefaults = true
    end
  end
  if errorReadingDefaults then
    local records, ok = hs.execute(strfmt([[
      defaults read %s | grep '"%s'
    ]], appid, prefix))
    return ok == true
  end
  return false
end

-- Register observers to track menu bar selection state for hotkey validity.
--
-- Purpose:
--   When a right-side menu bar item is expanded, certain hotkeys
--   should be disabled or redirected to avoid interfering with menu input.
--
-- This observer:
--   - Tracks menu open / close events
--   - Sets FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"]
--
-- Note:
--   This process is expensive and is registered per-app only once.
MenuBarMenuSelectedObservers = {}
local function registerMenuBarObserverForHotkeyValidity(app)
  local appid = app:bundleID() or app:name()
  if MenuBarMenuSelectedObservers[appid] then return end
  if hs.window.filter.ignoreAlways[appid]
      or hs.window.filter.ignoreAlways[app:name()]
      or app:kind() < 0 then
    return
  end
  if hasStatusItems(app) then
    local appUI = toappui(app)
    local menuBarItems = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem) or {}
    menuBarItems = tifilter(menuBarItems, function(item) return #item > 0 end)
    if #menuBarItems > 0 then
      local observer = uiobserver.new(app:pid())
      observer:addWatcher(appUI, uinotifications.menuOpened)
      observer:addWatcher(appUI, uinotifications.menuClosed)
      observer:callback(function(_, menu, notification)
        if notification == uinotifications.menuClosed then
          -- When a menu is closed, assume no menu bar item is selected
          FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] = false
        else
          -- Determine whether the opened menu belongs to the right side
          -- of the menu bar (i.e. status items instead of app menus)
          local elem = menu.AXParent
          while elem and elem.AXRole ~= AX.MenuBar do
            elem = elem.AXParent
          end
          if elem and elem.AXPosition.x ~= hs.screen.mainScreen():fullFrame().x then
            FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] = true
          end
        end
      end)
      observer:start()
      MenuBarMenuSelectedObservers[appid] = observer
      Evt.StopOnTerminated(app, observer, function()
        MenuBarMenuSelectedObservers[appid] = nil
      end)
      return menuBarItems
    end
  end
end

WindowCreatedSinceFilter = hs.window.filter.new(true)
local windowCreatedSinceTime = {}

-- Redirect hotkey execution to the system-focused UI element if needed.
--
-- This wrapper handles cases where:
--   - the hotkey target is not the frontmost app/window
--   - a menu bar item is currently expanded
--
-- It ensures that:
--   - hotkeys do not interfere with menu interaction
--   - fallback keystrokes are sent to the correct UI context
local function resendToFocusedUIElement(cond, nonFrontmostWindow)
  return function(obj)
    local focusedApp = hs.axuielement.systemWideElement().AXFocusedApplication
    -- Lazily initialize RIGHT_MENUBAR_ITEM_SELECTED if unknown
    if FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] == nil and focusedApp == nil then
      local apps = hs.application.runningApplications()
      local appMenuBarItems = tmap(apps, function(app)
        return registerMenuBarObserverForHotkeyValidity(app)
      end)
      FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] = any(appMenuBarItems, function(items)
        return any(items, function(item) return item.AXSelected end)
      end)
    end
    if FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] and focusedApp == nil then
      return false, CF.rightMenubarItemSelected
    end

    if nonFrontmostWindow then
      local frontWin = hs.window.frontmostWindow()
      if frontWin ~= nil then
        if frontWin:role() == AX.Sheet or frontWin:role() == AX.Popover then
          return false, CF.uIElementNotFocused
        end
        for wino, _ in pairs(WindowCreatedSinceFilter.windows) do
          if wino.id == frontWin:id() then
            if wino.timeCreated > windowCreatedSinceTime[obj:id()] then
              return false, CF.uIElementNotFocused
            end
            break
          end
        end
      end
    elseif focusedApp then  -- supposed to be non-null
      local app = obj.application ~= nil and obj:application() or obj
      local fAppid, appid = focusedApp:asHSApplication():bundleID(), app:bundleID()
      if fAppid ~= appid then
        if not (appid == "com.apple.Safari" and
            fAppid == "com.apple.Safari.SandboxBroker") then
          return false, CF.uIElementNotFocused
        end
      end
    end
    return cond(obj)
  end
end

-- Disable hotkeys when a left-side menu bar menu is expanded.
--
-- This prevents hotkeys without modifiers from interfering
-- with normal menu navigation.
local function noSelectedLeftMenuBarItemFunc(fn)
  return function(obj)
    local app = obj.application ~= nil and obj:application() or obj
    for i, menuBarItem in ipairs(getMenuBarItems(app, false, false)) do
      if i > 1 and menuBarItem.AXSelected then
        return false, CF.leftMenubarItemSelected
      end
    end
    return fn(obj)
  end
end

-- Disable hotkeys when a non-empty text field is focused.
--
-- This avoids breaking text input by unmodified hotkeys.
local function noFocusedNonEmptyTextFieldFunc(fn)
  return function(obj)
    local focused = hs.axuielement.systemWideElement().AXFocusedUIElement
    if focused and focused.AXRole == AX.TextField and focused.AXValue ~= nil then
      return false, CF.nonEmptyTextFieldFocused
    end
    return fn(obj)
  end
end

KEY_MODE = {
  PRESS = 1,
  REPEAT = 2,
}

ActivatedAppConditionChain = {}
DaemonAppConditionChain = {}

-- Append a conditional hotkey into a per-app condition chain.
--
-- Multiple hotkeys may share the same key binding.
-- They are stored as a linked list and evaluated in order:
--   newest → oldest
--
-- The first satisfied condition wins.
local function appendConditionChain(app, config, pressedfn, repeatedfn, cond)
  local appid = app:bundleID() or app:name()
  local mods, key = config.mods, config.key
  local message = config.message
  local chain = config.background and DaemonAppConditionChain
      or ActivatedAppConditionChain

  if chain[appid] == nil then
    chain[appid] = {}
  end
  local hkIdx = hotkeyIdx(mods, key)
  local prevHotkeyInfo = chain[appid][hkIdx]
  chain[appid][hkIdx] = {
    pressedfn = pressedfn,
    repeatedfn = repeatedfn,
    condition = cond,
    message = message,
    enabled = true,
    previous = prevHotkeyInfo,
  }
  if prevHotkeyInfo then
    prevHotkeyInfo.next = chain[appid][hkIdx]
  end
  return chain[appid][hkIdx]
end

local function enableConditionInChain(hotkey)
  if hotkey._chainedCond == nil then return end
  hotkey._chainedCond.enabled = true
end

local function disableConditionInChain(appid, hotkey, delete)
  if hotkey._chainedCond == nil then return end
  hotkey._chainedCond.enabled = false
  if delete or hotkey.deleteOnDisable then
    if hotkey._chainedCond.previous then
      hotkey._chainedCond.previous.next = hotkey._chainedCond.next
    end
    if hotkey._chainedCond.next then
      hotkey._chainedCond.next.previous = hotkey._chainedCond.previous
    else
      local chain = (hotkey.kind == HK.IN_WIN or hotkey.kind == HK.MENUBAR)
          and DaemonAppConditionChain or ActivatedAppConditionChain
      if chain[appid] then
        chain[appid][hotkey.idx] = hotkey._chainedCond.previous
      end
    end
  end
end

-- Execute a chain of conditional hotkeys sharing the same key binding.
--
-- Evaluation order:
--   1. Try the current hotkey
--   2. Walk backward through the condition chain
--   3. If no condition matches, fall back to:
--        - menu item selection (if available)
--        - raw keystroke delivery
local function wrapConditionChain(app, fn, mode, config)
  return function()
    local succ, result = fn()
    if succ then return end
    local menuItemNotFound = result == CF.noMenuItemMatchKeybinding
    local hkIdx = hotkeyIdx(config.mods, config.key)
    local chain = config.background and DaemonAppConditionChain
        or ActivatedAppConditionChain
    local cb = chain[app:bundleID() or app:name()][hkIdx]
    while cb do
      if cb.enabled then
        local f = mode == KEY_MODE.PRESS and cb.pressedfn or cb.repeatedfn
        A_Message = cb.message
        succ, result = f()
        if succ then return end
        menuItemNotFound = menuItemNotFound
            or result == CF.noMenuItemMatchKeybinding
      end
      cb = cb.previous
    end
    local mods, key = config.mods, config.key
    if not menuItemNotFound then
      -- most of the time, directly selecting menu item costs less time than key strokes
      local menuItemPath, enabled = findMenuItemByKeyBinding(app, mods, key)
      if menuItemPath ~= nil and enabled then
        app:selectMenuItem(menuItemPath)
        return
      end
    end
    hs.eventtap.keyStroke(mods, key, nil, app)
  end
end

-- Wrap a hotkey callback with condition evaluation and fallback logic.
--
-- This function:
--   - Evaluates the user-defined condition
--   - Handles focus / menu / text-field edge cases
--   - Decides whether to:
--       * execute the callback
--       * resend keystrokes
--       * abort execution
--
-- It returns:
--   wrappedFn, wrappedCondition
local function wrapCondition(obj, config, mode)
  local mods, key = config.mods, config.key
  local func = mode == KEY_MODE.REPEAT and config.repeatedfn or config.fn
  local condition = config.condition
  local cond = function(o)
    if condition == nil then return true end
    local satisfied, result = condition(o)
    if not satisfied then result = CF.userConditionFail end
    return satisfied, result
  end

  local app
  if obj.focusedWindow then  -- AppBind
    app = obj
  elseif obj.application then  -- WinBind or AppWinBind
    app = obj:application()
    if not config.background then obj = nil end
  end

  if obj == nil or obj.asHSApplication == nil then
    -- if a menu is extended, hotkeys with no modifiers or only 'shift' are disabled
    -- currently allow hotkeys with 'option' or 'shift'+'option' as modifiers
    if mods == nil or #mods == 0
        or (type(mods) == 'string' and mods:lower() == Mod.Shift.Long)
        or (type(mods) == 'table' and #mods == 1 and mods[1]:lower() == Mod.Shift.Long) then
      cond = noFocusedNonEmptyTextFieldFunc(noSelectedLeftMenuBarItemFunc(cond))
    end
    -- send key strokes to system focused UI element instead of this obj
    cond = resendToFocusedUIElement(cond, config.nonFrontmost)
  end
  local oldCond = cond
  cond = function(o)
    o = o or obj or app:focusedWindow()
    return oldCond(o)
  end
  local fn = func
  -- Final execution wrapper that unifies:
  --   condition checking, fallback routing, and callback invocation
  fn = function()
    local o = obj or app:focusedWindow()
    local satisfied, result, url = cond(o)
    if satisfied then
      if result ~= nil then  -- condition function can pass result to callback function
        if url ~= nil then
          func(result, url, o)
        else
          func(result, o)
        end
      else
        func(o)
      end
      return true
    elseif result == CF.rightMenubarItemSelected then
      safeGlobalKeyStroke(mods, key)
      return true
    elseif result == CF.leftMenubarItemSelected
        or result == CF.nonEmptyTextFieldFocused then
      hs.eventtap.keyStroke(mods, key, nil, app)
      return true
    elseif result == CF.uIElementNotFocused then
      local focusedApp = hs.axuielement.systemWideElement().AXFocusedApplication
      hs.eventtap.keyStroke(mods, key, nil, focusedApp:asHSApplication())
      return true
    end
    return false, result
  end
  return fn, cond
end

-- in current version of Hammerspoon, if a callback lasts kind of too long,
-- keeping pressing a hotkey may lead to unexpected repeated triggering of callback function
-- a workaround is to check if callback function is executing, if so, do nothing
-- note that this workaround may not work when the callback lasts really too long
FLAGS["CALLBACK_IS_EXECUTING"] = false
local function callBackExecutingWrapper(fn)
  return function()
    if FLAGS["CALLBACK_IS_EXECUTING"] then return end
    hs.timer.doAfter(0, A_HotkeyWrapper(function()
      FLAGS["CALLBACK_IS_EXECUTING"] = true
      fn()
      FLAGS["CALLBACK_IS_EXECUTING"] = false
    end))
  end
end

-- Bind a hotkey with full contextual awareness.
--
-- This is the central assembly point that combines:
--   - key binding
--   - condition logic
--   - execution context (app / window / menu)
--   - repeat handling
--   - condition chaining
--
-- All higher-level bind helpers (AppBind / WinBind / MenuBarBind)
-- eventually delegate here.
local function bindContextual(obj, config, ...)
  if config.spec ~= nil then
    config.mods = config.spec.mods
    config.key = config.spec.key
    config.spec = nil
  end
  local pressedfn, cond = wrapCondition(obj, config, KEY_MODE.PRESS)
  local tbl = { message = config.message }
  cond = A_HotkeyWrapper(cond, tbl)
  if config.repeatedfn == nil and config.condition ~= nil then
    -- if hotkey condition is not satisfied, holding event should be passed to the app
    -- so callback for holding event must always be registered
    config.repeatedfn = function() end
  end
  local repeatedfn = config.repeatedfn
  if repeatedfn ~= nil then
    repeatedfn = wrapCondition(obj, config, KEY_MODE.REPEAT)
  end

  if config.condition ~= nil then
    -- multiple conditioned hotkeys may share a common keybinding
    -- they are cached in a linked list.
    -- each condition will be tested until one is satisfied
    local app
    if obj.application ~= nil then
      app = obj:application()
    elseif obj.asHSApplication ~= nil then
      app = getAppFromDescendantElement(obj)
    else
      app = obj
    end
    cond = appendConditionChain(app, config, pressedfn, repeatedfn, cond)
    pressedfn = wrapConditionChain(app, pressedfn, KEY_MODE.PRESS, config)
    if repeatedfn ~= nil then
      repeatedfn = wrapConditionChain(app, repeatedfn, KEY_MODE.REPEAT, config)
    end
  end

  if config.condition ~= nil then  -- executing condition may take too much time
    pressedfn = callBackExecutingWrapper(pressedfn)
    if repeatedfn ~= nil then
      repeatedfn = callBackExecutingWrapper(repeatedfn)
    end
  end
  local hotkey = bindHotkeySpec(config, config.message,
                                pressedfn, nil, repeatedfn, ...)
  hotkey.deleteOnDisable = config.deleteOnDisable
  tbl.hotkey = hotkey
  if type(cond) == 'table' then
    hotkey._chainedCond = cond
  else
    hotkey.condition = cond
  end
  return hotkey
end

-- Bind a hotkey scoped to the active application.
function AppBind(app, config, ...)
  local hotkey = bindContextual(app, config, ...)
  hotkey.kind = HK.IN_APP
  hotkey.subkind = HK.IN_APP_.APP
  return hotkey
end

-- Register hotkeys for an active application.
--
-- Hotkeys are:
--   - enabled on activation
--   - disabled or deleted on deactivation / termination
registerInAppHotKeys = function(app)
  local appid = app:bundleID() or app:name()
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  if not inAppHotKeys[appid] then
    inAppHotKeys[appid] = {}
  end
  for hkID, cfg in pairs(appHotKeyCallbacks[appid] or {}) do
    if type(hkID) == 'number' then break end
    if inAppHotKeys[appid][hkID] ~= nil then
      local hotkey = inAppHotKeys[appid][hkID]
      hotkey:enable()
      enableConditionInChain(hotkey)
    else
      -- prefer properties specified in configuration file than in code
      local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
      local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
      if hasKey == false then
        local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
            or specialCommonHotkeyConfigs[hkID]
        if kbShared ~= nil then
          keybinding.mods = kbShared.mods
          keybinding.key = kbShared.key
          hasKey = true
        end
      end
      local isBackground = keybinding.background ~= nil
          and keybinding.background or cfg.background
      local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
      local isMenuBarMenu = keybinding.menubarFilter ~= nil
          or cfg.menubarFilter ~= nil
      local bindable = function()
        return cfg.bindCondition == nil or cfg.bindCondition(app)
      end
      if hasKey and not isBackground and not isForWindow
          and not isMenuBarMenu and bindable() then
        local msg = type(cfg.message) == 'string'
            and cfg.message or cfg.message(app)
        if msg ~= nil then
          local config = tcopy(cfg)
          config.mods = keybinding.mods
          config.key = keybinding.key
          config.message = msg
          if keybinding.repeatable ~= nil then
            config.repeatable = keybinding.repeatable
          end
          config.repeatedfn = config.repeatable and config.fn or nil
          inAppHotKeys[appid][hkID] = AppBind(app, config)
        end
      end
    end
  end

  Evt.OnDeactivated(app, function()
    unregisterInAppHotKeys(appid)
  end)
  Evt.OnTerminated(app, function()
    unregisterInAppHotKeys(appid, true)
    ActivatedAppConditionChain[appid] = nil
  end)
end

unregisterInAppHotKeys = function(appid, delete)
  if type(appid) ~= 'string' then appid = appid:bundleID() or appid:name() end

  local allDeleted = delete
  if delete then
    for hkID, hotkey in pairs(inAppHotKeys[appid] or {}) do
      disableConditionInChain(appid, hotkey, true)
      hotkey:delete()
      inAppHotKeys[appid][hkID] = nil
    end
  else
    for hkID, hotkey in pairs(inAppHotKeys[appid] or {}) do
      hotkey:disable()
      disableConditionInChain(appid, hotkey)
      if hotkey.deleteOnDisable then
        hotkey:delete()
        inAppHotKeys[appid][hkID] = nil
      else
        allDeleted = false
      end
    end
  end
  if allDeleted then
    inAppHotKeys[appid] = nil
  end
end

-- Bind a hotkey scoped to a specific window of the active application.
function AppWinBind(win, config, ...)
  local hotkey = bindContextual(win, config, ...)
  hotkey.kind = HK.IN_APP
  hotkey.subkind = HK.IN_APP_.WINDOW
  return hotkey
end

-- hotkeys for focused window of active app

-- check if a window filter is the same as another
-- if a value is a list, the order of elements matters
local function sameFilter(a, b)
  if type(a) ~= "table" then return a == b end
  if a == b then return true end
  for k, av in pairs(a) do
    local bv = b[k]
    if av ~= bv then
      if type(av) == 'table' then
        if type(bv) ~= 'table' then return false end
        for i=1,#av do
          if av[i].equals then
            if not av[i]:equals(bv[i]) then return false end
          else
            if av[i] ~= bv[i] then return false end
          end
        end
      elseif type(av) == 'function' or type(av) == 'boolean' then
        return false
      else
        if av.equals then
          if not av:equals(bv) then return false end
        else
          if av ~= bv then return false end
        end
      end
    end
  end
  for k, _ in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- Register hotkeys for a focused window matching a filter.
--
-- Window-scoped hotkeys are dynamically managed based on:
--   - window focus
--   - window title / role / URL
registerInWinHotKeys = function(win, filter)
  if win == nil then return end
  local app = win:application()
  local appid = app:bundleID() or app:name()
  if appHotKeyCallbacks[appid] == nil then return end
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  if not inWinHotKeys[appid] then
    inWinHotKeys[appid] = {}
  end
  if not inWinHotKeys[appid][filter] then
    inWinHotKeys[appid][filter] = {}
  end
  local hotkeys = inWinHotKeys[appid][filter]
  local needCloseWatcher = true
  local url
  for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
    if hotkeys[hkID] == nil then
      -- prefer properties specified in configuration file than in code
      local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
      local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
      if hasKey == false then
        local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
            or specialCommonHotkeyConfigs[hkID]
        if kbShared ~= nil then
          keybinding.mods = kbShared.mods
          keybinding.key = kbShared.key
          hasKey = true
        end
      end
      local windowFilter = keybinding.windowFilter or cfg.windowFilter
      local isForWindow = windowFilter ~= nil
      local isBackground = keybinding.background ~= nil
          and keybinding.background or cfg.background
      local bindable = function()
        return cfg.bindCondition == nil or cfg.bindCondition(app)
      end
      if hasKey and isForWindow and not isBackground and bindable()
          and sameFilter(windowFilter, filter) then
        local msg, fallback
        if type(cfg.message) == 'string' then msg = cfg.message
        else msg, fallback = cfg.message(win) end
        if msg ~= nil and hotkeys[hkID] == nil then
          -- double check for website-specific hotkeys
          local config = tcopy(cfg)
          config.mods = keybinding.mods
          config.key = keybinding.key
          config.message = msg
          if keybinding.repeatable ~= nil then
            config.repeatable = keybinding.repeatable
          end
          config.background = false
          if type(windowFilter) == 'table' and windowFilter.allowURLs then
            url = url or getTabUrl(app)
            config.fn = bind(config.fn, url)
          end
          config.repeatedfn = config.repeatable and config.fn or nil
          config.deleteOnDisable = config.deleteOnDisable or fallback
          hotkeys[hkID] = AppWinBind(win, config)
        end
      end
    else
      needCloseWatcher = false
      hotkeys[hkID]:enable()
      enableConditionInChain(hotkeys[hkID])
    end
  end

  if needCloseWatcher then
    Evt.onDestroy(towinui(win),
      function() unregisterInWinHotKeys(appid, true, filter) end,
      hs.application.watcher.deactivated, true
    )
  end
end

unregisterInWinHotKeys = function(appid, delete, filter)
  if type(appid) ~= 'string' then appid = appid:bundleID() or appid:name() end
  local hotkeys = get(inWinHotKeys, appid, filter)
  if appHotKeyCallbacks[appid] == nil or hotkeys == nil then
    return
  end

  local allDeleted = delete
  if delete then
    for hkID, hotkey in pairs(hotkeys) do
      disableConditionInChain(appid, hotkey, true)
      hotkey:delete()
      hotkeys[hkID] = nil
    end
  else
    for hkID, hotkey in pairs(hotkeys) do
      hotkey:disable()
      disableConditionInChain(appid, hotkey)
      if hotkey.deleteOnDisable then
        hotkey:delete()
        hotkeys[hkID] = nil
      else
        allDeleted = false
      end
    end
  end
  if allDeleted then
    inWinHotKeys[appid][filter] = nil
  end
end

local function isWebsiteAllowed(win, allowURLs)
  if win:subrole() ~= AX.StandardWindow then
    return false
  end
  local url = getTabUrl(win:application())
  if url ~= nil then
    if type(allowURLs) == 'string' then
      allowURLs = { allowURLs }
    end
    for _, v in ipairs(allowURLs) do
      if url:match(v) ~= nil then
        return true
      end
    end
  end
  return false
end

FocusedWindowObservers = {}
local function registerSingleWinFilterForApp(app, filter, retry)
  local appid = app:bundleID() or app:name()
  for f, _ in pairs(FocusedWindowObservers[appid] or {}) do
    -- a window filter can be shared by multiple hotkeys
    if sameFilter(f, filter) then
      return
    end
  end

  local appUI = toappui(app)
  if not tcontain(appUI:attributeNames() or {}, "AXFocusedWindow") then
    retry = retry and retry + 1 or 1
    if not FLAGS["Loading"] and retry <= 3 then
      hs.timer.doAfter(1,
          bind(registerSingleWinFilterForApp, app, filter, retry))
    end
    return
  end

  local actualFilter, allowSheet, allowPopover, condition, allowURLs
  if type(filter) == 'table' then
    actualFilter = tcopy(filter)
    allowSheet, allowPopover = filter.allowSheet, filter.allowPopover
    actualFilter.allowSheet, actualFilter.allowPopover = nil, nil
    condition, allowURLs = actualFilter.fn, actualFilter.allowURLs
    actualFilter.fn, actualFilter.allowURLs = nil, nil
    if sameFilter(actualFilter, {}) then actualFilter = true end
  else
    actualFilter = filter
  end
  if allowSheet or allowPopover then
    actualFilter = false
  end
  local windowFilter = hs.window.filter.new(false):setAppFilter(app:name(), actualFilter)

  local observer = uiobserver.new(app:pid())
  local win = app:focusedWindow()
  if win and (allowURLs == nil or isWebsiteAllowed(win, allowURLs))
      and ((allowSheet and win:role() == AX.Sheet)
        or (allowPopover and win:role() == AX.Popover)
        or windowFilter:isWindowAllowed(win))
      and (condition == nil or condition(win)) then
    registerInWinHotKeys(win, filter)
  end

  observer:addWatcher(appUI, uinotifications.focusedWindowChanged)
  observer:addWatcher(appUI, uinotifications.windowMiniaturized)
  if allowPopover then
    observer:addWatcher(appUI, uinotifications.focusedUIElementChanged)
  end
  if win and (allowURLs or (type(filter) == 'table'
      and (filter.allowTitles or filter.rejectTitles))) then
    observer:addWatcher(towinui(win), uinotifications.titleChanged)
  end
  observer:callback(function(_, element, notification)
    win = app:focusedWindow()
    if win == nil then return end
    if notification == uinotifications.focusedUIElementChanged
        and win:role() ~= AX.Popover then
      return
    end
    if notification == uinotifications.focusedWindowChanged
        and win ~= nil and (allowURLs or (type(filter) == 'table'
            and (filter.allowTitles or filter.rejectTitles))) then
      observer:addWatcher(towinui(win), uinotifications.titleChanged)
    end
    if notification == uinotifications.windowMiniaturized then
      observer:removeWatcher(element, uinotifications.titleChanged)
    end
    if not element:isValid() then return end

    local action = function()
      if win ~= nil and win:application() ~= nil
          and (allowURLs == nil or isWebsiteAllowed(win, allowURLs))
          and ((allowSheet and win:role() == AX.Sheet)
            or (allowPopover and win:role() == AX.Popover)
            or windowFilter:isWindowAllowed(win))
          and (condition == nil or condition(win)) then
        registerInWinHotKeys(win, filter)
      else
        unregisterInWinHotKeys(appid, false, filter)
      end
    end
    -- "hs.window.filter" waits for stop of changing title,
    -- affecting the return of "hs.window.filter.isWindowAllowed"
    -- we have to workaround it
    if notification == uinotifications.titleChanged and (type(filter) == 'table'
        and (filter.allowTitles or filter.rejectTitles)) then
      local function matchTitles(titles, t)
        if type(titles) == 'string' then
          titles = { titles }
        end
        for _, title in ipairs(titles) do
          if t:match(title) then return true end
        end
      end
      local allowTitles, rejectTitles = filter.allowTitles, filter.rejectTitles
      if allowTitles then
        if type(allowTitles) == 'number' then
          if #win:title() <= allowTitles then
            unregisterInWinHotKeys(appid, false, filter)
            return
          end
        elseif not matchTitles(allowTitles, win:title()) then
          unregisterInWinHotKeys(appid, false, filter)
          return
        end
      end
      if rejectTitles and matchTitles(rejectTitles, win:title()) then
        unregisterInWinHotKeys(appid, false, filter)
        return
      end
      local tempFilter
      local empty = true
      tempFilter = {}
      for k, v in pairs(actualFilter) do
        if k ~= "allowTitles" and k ~= "rejectTitles" then
          tempFilter[k] = v
          empty = false
        end
      end
      if empty then tempFilter = true end
      windowFilter:setAppFilter(app:name(), tempFilter)
      action()
      windowFilter:setAppFilter(app:name(), actualFilter)
      return
    end
    action()
  end)
  observer:start()
  if FocusedWindowObservers[appid] == nil then
    FocusedWindowObservers[appid] = {}
  end
  FocusedWindowObservers[appid][filter] = observer
  Evt.StopOnDeactivated(app, observer, function()
    FocusedWindowObservers[appid][filter] = nil
  end)
end

local function registerWinFiltersForApp(app)
  local appid = app:bundleID() or app:name()
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  for hkID, cfg in pairs(appHotKeyCallbacks[appid] or {}) do
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    if hasKey == false then
      local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
          or specialCommonHotkeyConfigs[hkID]
      if kbShared ~= nil then
        hasKey = true
      end
    end
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local isBackground = keybinding.background ~= nil
        and keybinding.background or cfg.background
    local bindable = function()
      return cfg.bindCondition == nil or cfg.bindCondition(app)
    end
    if hasKey and isForWindow and not isBackground and bindable() then
      local windowFilter = keybinding.windowFilter or cfg.windowFilter
      registerSingleWinFilterForApp(app, windowFilter)
    end
  end
end

-- Bind a hotkey scoped to a focused window.
function WinBind(win, config, ...)
  local hotkey = bindContextual(win, config, ...)
  hotkey.kind = HK.IN_WIN
  return hotkey
end

-- hotkeys for focused window belonging to daemon app
-- the window is frontmost unless specified "nonFrontmost"
DaemonAppFocusedWindowObservers = {}
registerDaemonAppInWinHotkeys = function(win, appid, filter)
  local winUI = towinui(win)
  local wid = win:id()
  if daemonAppFocusedWindowHotkeys[wid] == nil then
    daemonAppFocusedWindowHotkeys[wid] = {}
  end
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  local closeObserver
  for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
    local app = find(appid)
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    if hasKey == false then
      local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
          or specialCommonHotkeyConfigs[hkID]
      if kbShared ~= nil then
        keybinding.mods = kbShared.mods
        keybinding.key = kbShared.key
        hasKey = true
      end
    end
    local isBackground = keybinding.background ~= nil
        and keybinding.background or cfg.background
    local windowFilter = keybinding.windowFilter or cfg.windowFilter
    local isForWindow = windowFilter ~= nil
    local bindable = function()
      return cfg.bindCondition == nil or cfg.bindCondition(app)
    end
    if hasKey and isForWindow and isBackground and bindable()
        and sameFilter(windowFilter, filter) then
      local msg = type(cfg.message) == 'string'
          and cfg.message or cfg.message(win)
      if msg ~= nil then
        local config = tcopy(cfg)
        config.mods = keybinding.mods
        config.key = keybinding.key
        config.message = msg
        if keybinding.repeatable ~= nil then
          config.repeatable = keybinding.repeatable
        end
        config.background = true
        if keybinding.nonFrontmost ~= nil then
          config.nonFrontmost = keybinding.nonFrontmost
        end
        config.repeatedfn = config.repeatable and config.fn or nil
        local hotkey = WinBind(win, config)
        tinsert(daemonAppFocusedWindowHotkeys[wid], hotkey)

        if config.nonFrontmost then
          if type(windowFilter) == 'table' and windowFilter.allowRoles then
            local allowRoles = windowFilter.allowRoles
            if type(allowRoles) == 'string' then allowRoles = { allowRoles } end
            local extraRoles = tfilter(allowRoles, function(role)
                return hs.window.filter.allowedWindowRoles[role] == nil end)
            if #extraRoles > 0 then
              WindowCreatedSinceFilter:setAppFilter(app:name(), {
                allowRoles = extraRoles,
              })
            end
          end
          if windowCreatedSinceTime[wid] == nil then
            -- tell "hs.window.filter" to record time of windows to be created
            -- if no subscriptions have been made then this is necessary
            -- WindowCreatedSinceFilter:subscribe(
            --     hs.window.filter.windowCreated, function() end)
            windowCreatedSinceTime[wid] = hs.timer.secondsSinceEpoch()
          end
        end

        closeObserver = closeObserver or Evt.onDestroy(winUI,
          function()
            if daemonAppFocusedWindowHotkeys[wid] ~= nil then
              for i, hotkey in ipairs(daemonAppFocusedWindowHotkeys[wid]) do
                if hotkey.idx ~= nil then
                  disableConditionInChain(appid, hotkey, true)
                  hotkey:delete()
                  daemonAppFocusedWindowHotkeys[wid][i] = nil
                end
              end
              if #daemonAppFocusedWindowHotkeys[wid] == 0 then
                daemonAppFocusedWindowHotkeys[wid] = nil
              end
            end
            -- WindowCreatedSinceFilter:unsubscribeAll()
            windowCreatedSinceTime[wid] = nil
          end,
          hs.application.watcher.terminated, true
        )
      end
    end
  end
end

local function registerSingleWinFilterForDaemonApp(app, filter, retry)
  local appid = app:bundleID() or app:name()
  for f, _ in pairs(DaemonAppFocusedWindowObservers[appid] or {}) do
    -- a window filter can be shared by multiple hotkeys
    if sameFilter(f, filter) then
      return
    end
  end

  local appUI = toappui(app)
  if not tcontain(appUI:attributeNames() or {}, "AXFocusedWindow") then
    retry = retry and retry + 1 or 1
    if not FLAGS["Loading"] and retry <= 3 then
      hs.timer.doAfter(1,
          bind(registerSingleWinFilterForDaemonApp, app, filter, retry))
    end
    return
  end

  local actualFilter, allowSheet, allowPopover, condition
  if type(filter) == 'table' then
    actualFilter = tcopy(filter)
    allowSheet, allowPopover = filter.allowSheet, filter.allowPopover
    actualFilter.allowSheet, actualFilter.allowPopover = nil, nil
    condition = actualFilter.fn
    actualFilter.fn, actualFilter.allowURLs = nil, nil
    if sameFilter(actualFilter, {}) then actualFilter = true end
  else
    actualFilter = filter
  end
  if allowSheet or allowPopover then
    actualFilter = false
  end

  local observer = uiobserver.new(app:pid())
  observer:addWatcher(appUI, uinotifications.windowCreated)
  if allowSheet then
    observer:addWatcher(appUI, uinotifications.focusedWindowChanged)
  end
  if allowPopover then
    observer:addWatcher(appUI, uinotifications.focusedUIElementChanged)
  end
  observer:callback(function(_, element, notification)
    if not element:isValid() then return end
    if notification == uinotifications.focusedWindowChanged
        and element.AXRole ~= AX.Sheet then
      return
    end
    if notification == uinotifications.focusedUIElementChanged then
      local elem = element
      while elem and elem.AXRole ~= AX.Popover do
        elem = elem.AXParent
      end
      if elem == nil then return end
    end

    local windowFilter = hs.window.filter.new(false):setAppFilter(
        app:name(), actualFilter)
    local win = element:asHSWindow()
    if win ~= nil
        and ((allowSheet and win:role() == AX.Sheet)
          or (allowPopover and win:role() == AX.Popover)
          or windowFilter:isWindowAllowed(win))
        and (condition == nil or condition(win)) then
      registerDaemonAppInWinHotkeys(win, appid, filter)
    end
  end)
  observer:start()
  if DaemonAppFocusedWindowObservers[appid] == nil then
    DaemonAppFocusedWindowObservers[appid] = {}
  end
  DaemonAppFocusedWindowObservers[appid][filter] = observer
  Evt.StopOnTerminated(app, observer, function()
    DaemonAppFocusedWindowObservers[appid][filter] = nil
  end)
end

local function registerWinFiltersForDaemonApp(app, appConfig)
  local appid = app:bundleID() or app:name()
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  for hkID, cfg in pairs(appConfig) do
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    if hasKey == false then
      local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
          or specialCommonHotkeyConfigs[hkID]
      if kbShared ~= nil then
        hasKey = true
      end
    end
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local isBackground = keybinding.background ~= nil
        and keybinding.background or cfg.background
    local bindable = function()
      return cfg.bindCondition == nil or cfg.bindCondition(app)
    end
    if hasKey and isForWindow and isBackground and bindable() then
      local windowFilter = keybinding.windowFilter or cfg.windowFilter
      registerSingleWinFilterForDaemonApp(app, windowFilter)
    end
  end
end

-- Bind a hotkey scoped to an open menu bar menu.
function MenuBarBind(menu, config)
  local hotkey = bindContextual(menu, config)
  hotkey.kind = HK.MENUBAR
  return hotkey
end

registerInMenuHotkeys = function(app)
  local appid = app:bundleID() or app:name()
  local appUI = toappui(app)
  local appConfig = appHotKeyCallbacks[appid]
  if menuBarMenuHotkeys[appid] == nil then
    menuBarMenuHotkeys[appid] = {}
  end
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  local closeObserver
  for hkID, cfg in pairs(appConfig) do
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    if hasKey == false then
      local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
          or specialCommonHotkeyConfigs[hkID]
      if kbShared ~= nil then
        keybinding = { mods = kbShared.mods, key = kbShared.key }
        hasKey = true
      end
    end
    local menubarFilter = keybinding.menubarFilter or cfg.menubarFilter
    local bindable = function()
      return cfg.bindCondition == nil or cfg.bindCondition(app)
    end
    if hasKey and menubarFilter ~= nil and bindable() then
      local menu
      if type(menubarFilter) == 'table' then
        if menubarFilter.allowIndices then
          local t = menubarFilter.allowIndices
          if type(t) ~= 'table' then t = { t } end
          for _, idx in ipairs(t) do
            local item = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, idx)
            if item.AXSelected then
              menu = getc(item, AX.Menu, 1) break
            end
          end
          if menu == nil then
            for _, idx in ipairs(t) do
              menu = getc(appUI, AX.MenuBar, -1, AX.Menu, idx)
              if menu then break end
            end
          end
        elseif menubarFilter.allowTitles then
          local t = menubarFilter.allowTitles
          if type(t) ~= 'table' then t = { t } end
          local map = loadStatusItemsAutosaveName(app)
          for _, title in ipairs(t) do
            local idx = tindex(map, title)
            if idx then
              local item = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, idx)
              if item.AXSelected then
                menu = getc(item, AX.Menu, 1) break
              end
            end
          end
          if menu == nil then
            for _, title in ipairs(t) do
              local idx = tindex(map, title)
              if idx then
                menu = getc(appUI, AX.MenuBar, -1, AX.Menu, idx)
                if menu then break end
              end
            end
          end
        end
      elseif menubarFilter == true then
        local mbItem = tfind(getc(appUI, AX.MenuBar, -1, AX.MenuBarItem),
            function(item) return item.AXSelected end)
        if mbItem then
          menu = getc(mbItem, AX.Menu, 1)
        end
      end
      if menu == nil then return end
      local msg = type(cfg.message) == 'string'
          and cfg.message or cfg.message(menu)
      if msg ~= nil then
        local config = tcopy(cfg)
        config.mods = keybinding.mods
        config.key = keybinding.key
        config.message = msg
        config.background = true
        if keybinding.repeatable ~= nil then
          config.repeatable = keybinding.repeatable
        end
        config.repeatedfn = config.repeatable and config.fn or nil
        tinsert(menuBarMenuHotkeys[appid], MenuBarBind(menu, config))
        if closeObserver == nil then
          closeObserver = uiobserver.new(app:pid())
          closeObserver:addWatcher(menu, uinotifications.menuClosed)
          local callback = function(obs)
            if menuBarMenuHotkeys[appid] ~= nil then
              for i, hotkey in ipairs(menuBarMenuHotkeys[appid]) do
                if hotkey.idx ~= nil then
                  disableConditionInChain(appid, hotkey, true)
                  hotkey:delete()
                  menuBarMenuHotkeys[appid][i] = nil
                end
              end
              if #menuBarMenuHotkeys[appid] == 0 then
                menuBarMenuHotkeys[appid] = nil
              end
            end
            obs:stop()
            obs = nil
          end
          closeObserver:callback(callback)
          closeObserver:start()
          Evt.StopOnTerminated(app, closeObserver, function()
            callback(closeObserver)
          end)
        end
      end
    end
  end
end

MenuBarMenuObservers = {}
local function registerObserversForMenuBarMenu(app, appConfig)
  local appid = app:bundleID() or app:name()
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  for hkID, cfg in pairs(appConfig) do
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    if hasKey == false then
      local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
          or specialCommonHotkeyConfigs[hkID]
      if kbShared ~= nil then
        hasKey = true
      end
    end
    local isMenuBarMenu = keybinding.menubarFilter ~= nil
        or cfg.menubarFilter ~= nil
    local bindable = function()
      return cfg.bindCondition == nil or cfg.bindCondition(app)
    end
    if hasKey and isMenuBarMenu and bindable() then
      local observer = MenuBarMenuObservers[appid]
      if observer == nil then
        local appUI = toappui(app)
        observer = uiobserver.new(app:pid())
        if not appUI:isValid() then return end
        observer:addWatcher(appUI, uinotifications.menuOpened)
        observer:callback(function(obs, menu)
          if menu.AXParent.AXRole == AX.MenuBar then
            registerInMenuHotkeys(app)
          end
        end)
        observer:start()
        MenuBarMenuObservers[appid] = observer
        Evt.StopOnTerminated(app, observer, function()
          MenuBarMenuObservers[appid] = nil
        end)
      end
      break
    end
  end
end

local appLocales = {} -- if app locale changes, it may change its menu bar items, so need to rebind
local function updateAppLocale(appid)
  if type(appid) ~= 'string' then appid = appid:bundleID() or appid:name() end
  local appLocale = applicationLocale(appid)
  local oldAppLocale = appLocales[appid] or SYSTEM_LOCALE
  appLocales[appid] = appLocale
  if oldAppLocale ~= appLocale then
    if matchLocale(oldAppLocale, { appLocale }) ~= appLocale then
      resetLocalizationMap(appid)
      localizeCommonMenuItemTitles(appLocale, appid)
      unregisterRunningAppHotKeys(appid)
      return true
    end
  end
  return false
end


------------------------------------------------------------
-- Shared hotkeys and behaviors across multiple applications
--
-- This section defines cross-app hotkeys that:
--   - are not bound to a single app explicitly
--   - depend on menu bar structure or standard menu items
--   - need to adapt dynamically to localization and app behaviors
--
-- Typical examples include:
--   - remapping tab navigation
--   - opening "Recent" menus
--   - window zoom / resize
--   - menu bar navigation (Alt-based access)
--   - open/save panel navigation
--
-- Most hotkeys here are:
--   - registered lazily
--   - rebuilt when menu bar changes
--   - automatically cleaned up on app deactivation
------------------------------------------------------------

-- Remap "previous tab" behavior for apps that support tab switching.
--
-- This globally remaps:
--   Ctrl + `  →  Shift + Ctrl + Tab
--
-- The hotkey is:
--   - skipped if app explicitly defines its own handler
--   - skipped for excluded apps
--   - dynamically rebuilt when menu items change
local function remapPreviousTab(app, force)
  local appid = app:bundleID() or app:name()
  local hkID = "remapPreviousTab"
  local hotkey = get(inAppHotKeys, appid, hkID)
  if hotkey then
    if force then
      hotkey:delete()
      disableConditionInChain(appid, hotkey, true)
      inAppHotKeys[appid][hkID] = nil
    else
      hotkey:enable()
      enableConditionInChain(hotkey)
      return
    end
  end
  local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
  local specApp = get(appHotKeyCallbacks[appid], hkID)
  if specApp ~= nil or spec == nil or tcontain(spec.excluded or {}, appid) then
    return
  end

  -- Register a conditional hotkey that selects the resolved menu item
  -- only when the menu item exists and is enabled.
  findMenuItemByKeyBinding(app, '⇧⌃', '⇥', function(menuItemPath)
    local fn = function()
      app:selectMenuItem(menuItemPath)
    end
    local cond = function()
      local menuItemCond = app:findMenuItem(menuItemPath)
      return menuItemCond ~= nil and menuItemCond.enabled
    end
    if inAppHotKeys[appid] == nil then
      inAppHotKeys[appid] = {}
    end
    inAppHotKeys[appid][hkID] = AppBind(app, {
      spec = spec, message = menuItemPath[#menuItemPath],
      fn = fn, repeatedfn = fn, condition = cond
    })
  end)
end

-- Register a shared hotkey for "Open Recent" menu item.
--
-- The hotkey:
--   - is only registered if the menu exists and is enabled
--   - respects localization and app-specific menu naming
--   - is skipped if app defines its own implementation
local function registerOpenRecent(app, force)
  local appid = app:bundleID() or app:name()
  local hkID = "openRecent"
  local hotkey = get(inAppHotKeys, appid, hkID)
  if hotkey then
    if force then
      hotkey:delete()
      disableConditionInChain(appid, hotkey, true)
      inAppHotKeys[appid][hkID] = nil
    else
      hotkey:enable()
      enableConditionInChain(hotkey)
      return
    end
  end

  local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
  local specApp = get(appHotKeyCallbacks[appid], hkID)
  if specApp ~= nil or spec == nil or tcontain(spec.excluded or {}, appid) then
    return
  end

  -- Resolve localized "File > Open Recent" menu path across:
  --   - Apple apps
  --   - third-party apps
  --   - mixed localization environments
  local localizedFile
  localizedFile = 'File'
  if app:findMenuItem({ localizedFile }) == nil then
    localizedFile = localizedMenuBarItem("File", appid)
    if localizedFile == nil then return end
    if app:findMenuItem({ localizedFile }) == nil then return end
  end
  local appUI = toappui(app)
  local findMenu = getc(appUI, AX.MenuBar, 1,
      AX.MenuBarItem, localizedFile, AX.Menu, 1)
  if findMenu == nil then return end
  local extendableItems = tifilter(findMenu, function(item)
    return #item > 0
  end)
  if #extendableItems == 0 then return end
  local menuItemPath = { 'File', 'Open Recent' }
  local menuItem = app:findMenuItem(menuItemPath)
  if menuItem == nil then
    if appid:sub(1, 10) == "com.apple." then
      local localizedOpenRecent = TC('Open Recent', app)
      menuItemPath = { localizedFile, localizedOpenRecent }
      menuItem = app:findMenuItem(menuItemPath)
      if menuItem == nil then
        local appLocale = applicationLocale(appid)
        if appLocale ~= SYSTEM_LOCALE and appLocale:sub(1, 2) ~= 'en' then
          local localized = TC('Open Recent', app)
          menuItemPath = { localizedFile, localized }
        end
      end
    else
      local localizedTitle = T('Open Recent', app)
      if localizedTitle then
        menuItemPath = { localizedFile, localizedTitle }
        menuItem = app:findMenuItem(menuItemPath)
      end
    end
  end
  if menuItem ~= nil then
    local fn = function() Callback.Select(menuItemPath, app) end
    local cond = function()
      local menuItemCond = app:findMenuItem(menuItemPath)
      return menuItemCond ~= nil and menuItemCond.enabled
    end
    if inAppHotKeys[appid] == nil then
      inAppHotKeys[appid] = {}
    end
    inAppHotKeys[appid][hkID] = AppBind(app, {
      spec = spec, message = menuItemPath[2],
      fn = fn, condition = cond
    })
  end
end

-- Register shared window zoom hotkeys (Zoom / Zoom All).
--
-- These hotkeys are bound only when:
--   - the corresponding menu items exist
--   - the app does not override them
--   - the app is not excluded
local function registerZoomHotkeys(app, force)
  local appid = app:bundleID() or app:name()
  local allHKIDs = { 'zoom', 'zoomAll' }
  local allMenuItemTitles = { 'Zoom', 'Zoom All' }
  local hkIDs, menuItemTitles = {}, {}
  for i, hkID in ipairs(allHKIDs) do
    local hotkey = get(inAppHotKeys, appid, hkID)
    if hotkey then
      if force then
        hotkey:delete()
        disableConditionInChain(appid, hotkey, true)
        inAppHotKeys[appid][hkID] = nil
        tinsert(menuItemTitles, allMenuItemTitles[i])
        tinsert(hkIDs, hkID)
      else
        hotkey:enable()
        enableConditionInChain(hotkey)
      end
    else
      tinsert(menuItemTitles, allMenuItemTitles[i])
      tinsert(hkIDs, hkID)
    end
  end

  for i, hkID in ipairs(hkIDs) do
    local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
    local specApp = get(appHotKeyCallbacks[appid], hkID)
    if specApp ~= nil or spec == nil or tcontain(spec.excluded or {}, appid) then
      goto ZOOM_CONTINUE
    end

    local title = menuItemTitles[i]
    local menuItemPath = { 'Window', title }
    local menuItem = app:findMenuItem(menuItemPath)
    if menuItem == nil then
      local localizedWindow = localizedMenuBarItem('Window', appid)
      local localizedTitle = TC(title, app)
      if localizedTitle == title and SYSTEM_LOCALE:sub(1, 2) ~= 'en' then
        localizedTitle = TC(title, app, { locale = SYSTEM_LOCALE })
      end
      if localizedTitle ~= nil then
        menuItemPath = { localizedWindow, localizedTitle }
        menuItem = app:findMenuItem(menuItemPath)
      end
      if menuItem == nil then
        if localizedTitle ~= nil then
          menuItemPath = { 'Window', localizedTitle }
          menuItem = app:findMenuItem(menuItemPath)
        end
        if menuItem == nil then
          menuItemPath = { localizedWindow, title }
          menuItem = app:findMenuItem(menuItemPath)
        end
      end
    end
    if menuItem ~= nil then
      local fn = function() app:selectMenuItem(menuItemPath) end
      local cond = function()
        local menuItemCond = app:findMenuItem(menuItemPath)
        return menuItemCond ~= nil and menuItemCond.enabled
      end
      if inAppHotKeys[appid] == nil then
        inAppHotKeys[appid] = {}
      end
      inAppHotKeys[appid][hkID] = AppBind(app, {
        spec = spec, message = menuItemPath[2],
        fn = fn, condition = cond
      })
    end
    ::ZOOM_CONTINUE::
  end
end

-- Enable or disable resize-related hotkeys based on fullscreen state.
--
-- Background:
--   Since macOS Sequoia, native "Move & Resize" menu items may
--   conflict with custom resize hotkeys.
--
-- This function dynamically:
--   - disables conflicting hotkeys in fullscreen spaces
--   - re-enables them when returning to normal spaces
FullscreenObserver = nil
local WINDOWMOVED_DELAY = 0.5
local windowMovedTimer
local function registerResizeHotkeys(app)
  if OS_VERSION < OS.Sequoia then return end
  if FullscreenObserver then
    FullscreenObserver:stop()
    FullscreenObserver = nil
  end
  if windowMovedTimer then
    windowMovedTimer:stop()
    windowMovedTimer = nil
  end
  local menu, submenu = "Window", "Move & Resize"
  local menuItem = app:findMenuItem({ menu, submenu })
  if menuItem == nil then
    local localizedMenu = localizedMenuBarItem('Window', app:bundleID())
    local localizedSubmenu = TC(submenu, app)
    if localizedSubmenu == submenu and SYSTEM_LOCALE:sub(1, 2) ~= 'en' then
      localizedSubmenu = TC(submenu, app, { locale = SYSTEM_LOCALE })
    end
    if localizedSubmenu ~= nil then
      menuItem = app:findMenuItem({ localizedMenu, localizedSubmenu })
    end
    if menuItem == nil then
      if localizedSubmenu ~= nil then
        menuItem = app:findMenuItem({ menu, localizedSubmenu })
      end
      if menuItem == nil then
        menuItem = app:findMenuItem({ localizedMenu, submenu })
      end
    end
  end
  local toEnable = menuItem == nil and not inFullscreenSpace()
  for _, hotkey in ipairs(HotkeysResizeConflictedSinceSequia or {}) do
    if toEnable then
      hotkey:enable()
    else
      hotkey:disable()
    end
  end
  if FLAGS["LOADING"] then
    FLAGS["NO_MOVE_RESIZE"] = toEnable
  else
    FLAGS["NO_MOVE_RESIZE"] = nil
  end
  if menuItem == nil and
      tcontain(toappui(app):attributeNames() or {}, "AXFocusedWindow") then
    FullscreenObserver = uiobserver.new(app:pid())
    FullscreenObserver:addWatcher(toappui(app), uinotifications.windowResized)
    FullscreenObserver:callback(function()
      -- Delay handling to debounce continuous resize events
      if windowMovedTimer then
        windowMovedTimer:setNextTrigger(WINDOWMOVED_DELAY)
        return
      end
      windowMovedTimer = hs.timer.doAfter(WINDOWMOVED_DELAY, function()
        windowMovedTimer = nil
        if inFullscreenSpace() then
          for _, hotkey in ipairs(HotkeysResizeConflictedSinceSequia or {}) do
            hotkey:disable()
          end
        else
          for _, hotkey in ipairs(HotkeysResizeConflictedSinceSequia or {}) do
            hotkey:enable()
          end
        end
      end)
    end)
    FullscreenObserver:start()
  end
end

-- Fetch toolbar buttons from a window UI hierarchy.
local function getToolbarButtons(winUI)
  local toolbar = getc(winUI, AX.Toolbar, 1)
  return getc(toolbar, AX.Button) or {}
end

-- Fetch tab-group buttons for apps that implement tabs as radio buttons.
local function getTabGroupButtons(winUI)
  local tabgroup = getc(winUI, AX.TabGroup, 1)
  local buttons = {}
  for _, elem in ipairs(tabgroup or {}) do
    if elem.AXRole == AX.RadioButton and elem.AXSubrole == AX.TabButton then
      tinsert(buttons, elem)
    else
      return buttons
    end
  end
end

-- Retry wrapper for toolbar discovery when UI is not immediately ready.
--
-- Used for apps where toolbar elements appear asynchronously.
local function waitForSettings(fn, maxWaitTime)
  return function(winUI)
    fn = fn or getToolbarButtons
    local buttons, toClick = fn(winUI)
    if #buttons == 0 then
      local app = getAppFromDescendantElement(winUI)
      local totalDelay = 0
      maxWaitTime = maxWaitTime or 0.1
      repeat
        hs.timer.usleep(10000)
        totalDelay = totalDelay + 0.01
        local win = app:focusedWindow()
        if win == nil then return {} end
        winUI = towinui(win)
        buttons, toClick = fn(winUI)
      until #buttons > 0 or totalDelay > maxWaitTime
    end
    return buttons, toClick
  end
end

-- App-specific overrides for extracting toolbar buttons.
--
-- Some apps use non-standard accessibility hierarchies.
-- This table provides per-app strategies to locate toolbar-like controls.
local specialToolbarButtons = {
  ["com.apple.TextEdit"] = getTabGroupButtons,
  ["org.xquartz.X11"] = getTabGroupButtons,
  ["com.apple.FaceTime"] = waitForSettings(),
  ["com.apple.Safari"] = waitForSettings(),
  ["com.torusknot.SourceTreeNotMAS"] = function(winUI)
    local fn = getToolbarButtons
    local buttons = fn(winUI)
    if #buttons == 0 or tfind(buttons, function(bt)
        return bt.AXTitle == winUI.AXTitle end) == nil then
      local app = getAppFromDescendantElement(winUI)
      local totalDelay = 0
      local maxWaitTime = 0.1
      repeat
        hs.timer.usleep(10000)
        totalDelay = totalDelay + 0.01
        local win = app:focusedWindow()
        if win == nil then return {} end
        winUI = towinui(win)
        buttons = fn(winUI)
      until (#buttons > 0 and tfind(buttons, function(bt)
            return bt.AXTitle == winUI.AXTitle end) ~= nil)
          or totalDelay > maxWaitTime
    end
    return buttons, true
  end,
  ["com.superace.updf.mac"] = function(winUI)
    local buttons = {}
    for _, elem in ipairs(winUI) do
      if elem.AXRole == AX.Button and elem.AXSubrole == nil then
        tinsert(buttons, elem)
      else
        return buttons
      end
    end
  end,
  ["com.kingsoft.wpsoffice.mac"] = function(winUI)
    local lastText = 1
    for i=#winUI,1,-1 do
      if winUI[i].AXRole == AX.StaticText then
        lastText = i break
      end
    end
    local buttons = {}
    for i=lastText+1,#winUI do
      if winUI[i].AXRole == AX.Button then
        tinsert(buttons, winUI[i])
      elseif #buttons > 1 then
        break
      end
    end
    return buttons
  end,
  ["org.klatexformula.klatexformula"] = function(winUI)
    local buttons = {}
    local found = false
    for _, elem in ipairs(winUI) do
      if elem.AXRole == AX.CheckBox then
        found = true
        tinsert(buttons, elem)
      elseif found then
        return buttons, true
      end
    end
  end,
  ["com.tencent.xinWeChat"] = function(winUI)
    -- only in version < 4.0.6
    local buttons = {}
    local found = false
    for _, elem in ipairs(winUI) do
      if elem.AXRole == AX.Button and #elem == 2
          and elem[1].AXRole == AX.Button and elem[2].AXRole == AX.StaticText then
        found = true
        tinsert(buttons, elem)
      elseif found then
        return buttons, true
      end
    end
    return buttons
  end,
  ["com.tencent.qq"] = waitForSettings(function(winUI)
    local groups = getc(winUI, AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.WebArea, 1,
        AX.Group, 2, AX.Group, 2, AX.Group, 1, AX.Group)
    local buttons = tmap(groups or {}, function(g)
      return getc(g, AX.Group, 1, AX.StaticText, 1)
    end)
    return buttons, true
  end),
  ["com.netease.uuremote"] = waitForSettings(function(winUI)
    local toolbar = getc(winUI, AX.Toolbar, 1)
    return tmap(getc(toolbar, AX.Group) or {},
        function(g) return getc(g, AX.StaticText, 1) end), true
  end)
}

-- Register numbered navigation hotkeys for Settings / Preferences windows.
--
-- Features:
--   - Dynamically detects toolbar buttons
--   - Binds numeric hotkeys to toolbar items
--   - Cleans up automatically on window close / app deactivation
--
-- This enables keyboard navigation in apps that lack native shortcuts
-- for settings toolbar switching.
local settingsToolbarHotkeys = {}
local function registerNavigationForSettingsToolbar(app)
  local appid = app:bundleID() or app:name()

  local deleteFunc = function ()
    for _, hotkey in ipairs(settingsToolbarHotkeys) do
      disableConditionInChain(appid, hotkey, true)
      hotkey:delete()
    end
    settingsToolbarHotkeys = {}
  end
  deleteFunc()

  local win = app:focusedWindow()
  if win == nil then
    local totalDelay = 0
    repeat
      hs.timer.usleep(10000)
      totalDelay = totalDelay + 0.01
      win = app:focusedWindow()
    until win or totalDelay > 0.1
  end
  if win == nil then return end
  local winUI = towinui(win)
  local func = specialToolbarButtons[appid] or getToolbarButtons
  local buttons, toClick = func(winUI)
  local callback = toClick and Callback.Click or Callback.Press
  for i, button in ipairs(buttons) do
    local suffix
    if i == 1 then suffix = "st"
    elseif i == 2 then suffix = "nd"
    elseif i == 3 then suffix = "rd"
    else suffix = "th" end
    local hkID = strfmt("open%d%sToolbarItemOnSettingsWindow", i, suffix)
    local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
    if spec then
      local condition
      if toClick then
        condition = function() return Callback.Clickable(button) end
      end
      local msg
      if button.AXRole == AX.StaticText then
        msg = button.AXValue
      else
        msg = button.AXTitle or button.AXDescription
      end
      if msg == "" and button.AXAttributedDescription ~= nil then
        msg = button.AXAttributedDescription:getString()
      end
      local hotkey = AppWinBind(win, {
        spec = spec, message = msg,
        condition = condition, fn = bind(callback, button)
      })
      tinsert(settingsToolbarHotkeys, hotkey)
    end
  end
  if #buttons == 0 then return end
  local elem = buttons[1]
  repeat
    elem = elem.AXParent
  until elem.AXRole == AX.Window
  winUI = elem
  win = winUI:asHSWindow()
  local closeObserver = uiobserver.new(app:pid())
  closeObserver:addWatcher(winUI, uinotifications.uIElementDestroyed)
  closeObserver:addWatcher(winUI, uinotifications.windowMiniaturized)
  closeObserver:addWatcher(toappui(app), uinotifications.focusedWindowChanged)
  closeObserver:callback(function(obs, elem, notification)
    if notification == uinotifications.uIElementDestroyed then
      obs:stop() obs = nil
      deleteFunc()
      return
    elseif notification == uinotifications.windowMiniaturized then
      closeObserver:addWatcher(winUI, uinotifications.windowDeminiaturized)
      closeObserver:removeWatcher(winUI, uinotifications.windowMiniaturized)
    elseif notification == uinotifications.windowDeminiaturized then
      closeObserver:addWatcher(winUI, uinotifications.windowMiniaturized)
      closeObserver:removeWatcher(winUI, uinotifications.windowDeminiaturized)
    end
    if app:focusedWindow() and app:focusedWindow():id() == win:id() then
      for _, hotkey in ipairs(settingsToolbarHotkeys) do
        hotkey:enable()
        enableConditionInChain(hotkey)
      end
    elseif hs.window.get(win:id()) == nil then
      obs:stop() obs = nil
      deleteFunc()
    else
      for _, hotkey in ipairs(settingsToolbarHotkeys) do
        disableConditionInChain(app:bundleID(), hotkey)
        hotkey:disable()
      end
    end
  end)
  closeObserver:start()
  Evt.StopOnDeactivated(app, closeObserver, deleteFunc)
  Evt.StopOnTerminated(app, closeObserver, deleteFunc)
end

-- Observe selection of "Settings…" / "Preferences…" menu items.
--
-- When triggered, automatically registers toolbar navigation hotkeys
-- for the newly opened settings window.
local function registerObserverForSettingsMenuItem(app)
  local appUI = toappui(app)

  local getMenuItem = function()
    local appMenu = getc(appUI, AX.MenuBar, 1, AX.MenuBarItem, 2)
    local appMenuItems = getc(appMenu, AX.Menu, 1, AX.MenuItem)
    if appMenuItems == nil or #appMenuItems == 0 then return end

    local sets = TC("Settings…", app)
    local prefs = TC("Preferences…", app)
    local settingsMenu = tfind(appMenuItems, function(item)
      return item.AXTitle and
          (item.AXTitle:find(sets) or item.AXTitle:find(prefs))
    end)
    if settingsMenu == nil then
      if appMenu.AXTitle:find(sets:sub(1, -4))
          or appMenu.AXTitle:find(prefs:sub(1, -4)) then
        return
      end
    end
    settingsMenu = settingsMenu or tfind(appMenuItems, function(item)
      return item.AXTitle and
          (item.AXTitle:find(sets:sub(1, -4))
          or item.AXTitle:find(prefs:sub(1, -4))
          or item.AXTitle:find("Settings")
          or item.AXTitle:find("Preferences"))
    end)
    settingsMenu = settingsMenu or tfind(appMenuItems, function(item)
      if item.AXMenuItemCmdChar == ','
          and item.AXMenuItemCmdModifiers == 0 then
        local title = delocalizedString(item.AXTitle, app)
        if type(title) == 'string' then
          return title:find("Settings") or title:find("Preferences")
        end
      end
      return false
    end)
    return settingsMenu
  end
  local settingsMenu = getMenuItem()
  if settingsMenu == nil then return end
  local observer = uiobserver.new(app:pid())
  observer:addWatcher(appUI, uinotifications.menuItemSelected)
  observer:callback(function(obs, elem)
    if settingsMenu.AXTitle == nil then
      settingsMenu = getMenuItem()
      if settingsMenu == nil then
        obs:stop() obs = nil
        return
      end
    end
    if elem.AXTitle == settingsMenu.AXTitle then
      registerNavigationForSettingsToolbar(app)
    end
  end)
  observer:start()
  Evt.StopOnDeactivated(app, observer)
end

-- fixme: menuItemSelected event seems to escape for menu item in right
-- menu bar menu, so the code below does not work as expected actually
local function registerObserverForRightMenuBarSettingsMenuItem(app, observer)
  local oldCallback = observer:callback()
  local callback = function(obs, elem, notification)
    if notification == uinotifications.menuOpened
        and elem.AXParent.AXRole == AX.MenuBar then
      local menuItems = getc(elem, AX.MenuItem)
      local sets = TC("Settings…", app)
      local prefs = TC("Preferences…", app)
      local settingsMenu = tfind(menuItems, function(item)
        return item.AXTitle and
            (item.AXTitle:find(sets) or item.AXTitle:find(prefs))
      end)
      settingsMenu = settingsMenu or tfind(menuItems, function(item)
        return item.AXTitle and
            (item.AXTitle:find(sets:sub(1, -4))
            or item.AXTitle:find(prefs:sub(1, -4))
            or item.AXTitle:find("Settings")
            or item.AXTitle:find("Preferences"))
      end)
      if settingsMenu ~= nil then
        observer:addWatcher(toappui(app), uinotifications.menuItemSelected)
      end
    elseif notification == uinotifications.menuClosed
        and elem.AXParent.AXRole == AX.MenuBar then
      observer:removeWatcher(toappui(app), uinotifications.menuItemSelected)
    elseif notification == uinotifications.menuItemSelected
        and elem.AXParent.AXParent.AXRole == AX.MenuBar then
      local sets = TC("Settings…", app)
      local prefs = TC("Preferences…", app)
      if elem.AXTitle:find(sets:sub(1, -4))
          or elem.AXTitle:find(prefs:sub(1, -4)) then
        registerNavigationForSettingsToolbar(app)
      end
    end
    if oldCallback then
      oldCallback(obs, elem, notification)
    end
  end
  observer:callback(callback)
end

------------------------------------------------------------
-- Open / Save panel navigation and confirmation hotkeys
--
-- This section adds:
--   - numeric navigation for sidebar locations
--   - hotkeys to confirm "Don't Save" / delete dialogs
--
-- Behavior:
--   - only active while open/save panels are visible
--   - dynamically adapts to app-specific UI structures
------------------------------------------------------------

-- bind hotkeys for open or save panel that are similar in `Finder`
-- & hotkey to confirm delete
local openSavePanelHotkeys = {}

-- special buttons for no saving in some apps
local specialConfirmFuncs = {
  ["com.kingsoft.wpsoffice.mac"] = function(winUI)
    if winUI.AXSubrole == AX.Dialog then
      local btnName = T("Don't Save", getAppFromDescendantElement(winUI))
      if not btnName then return end
      local buttons = getc(winUI, AX.Button)
      for _, button in ipairs(buttons) do
        if button.AXTitle:match('^'..btnName) then
          return button
        end
      end
    end
  end,

  ["JabRef"] = function(winUI)
    local app = getAppFromDescendantElement(winUI)
    if winUI.AXTitle == T("Save before closing", app) then
      local button = getc(winUI, AX.Unknown, 1, nil, 1, AX.Button, 1)
      if button ~= nil then
        local desc = T("Discard changes", app)
        if button.AXDescription == desc then
          return button
        end
      end
    end
  end,

  ["re.rizin.cutter"] = function(winUI)
    if winUI.AXSubrole == AX.Dialog then
      local buttons = getc(winUI, AX.Group, 1, AX.Button) or {}
      for _, button in ipairs(buttons) do
        if button.AXTitle == "Don't Save" then
          return button
        end
      end
    end
  end
}

-- special outline rows for sidebar in some apps
local specialSidebarRowsFuncs = {
  ["com.kingsoft.wpsoffice.mac"] = function(winUI)
    if winUI.AXSubrole == AX.Dialog then
      local outline = getc(winUI, AX.SplitGroup, 1, AX.List, 1)
      if outline ~= nil then
        return getc(outline, AX.StaticText)
      end
    end
  end
}

local specialSidebarRowsSelectFuncs = {
  ["com.kingsoft.wpsoffice.mac"] = function(outlineRows)
    if outlineRows == nil or #outlineRows == 0 then return end
    local app = getAppFromDescendantElement(outlineRows[1])
    local win = app:focusedWindow()

    local sum = 0
    for _, r in ipairs(outlineRows) do sum = sum + r.AXSize.h end
    local mean = sum / #outlineRows
    outlineRows = tifilter(outlineRows, function(r)
      return r.AXSize.h > mean
    end)

    local i = 1
    for _=1,#outlineRows do
      if i > 10 then break end
      local suffix
      if i == 1 then suffix = "st"
      elseif i == 2 then suffix = "nd"
      elseif i == 3 then suffix = "rd"
      else suffix = "th" end
      local hkID = strfmt("open%d%sSidebarItemOnOpenSavePanel", i, suffix)
      local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
      if spec ~= nil then
        local idx = i
        local hotkey = AppWinBind(win, {
          spec = spec, message = 'Location ' .. i,
          condition = function()
            local outline = getc(towinui(win), AX.SplitGroup, 1, AX.List, 1)
            if outline ~= nil then
              local rows = getc(outline, AX.StaticText)
              rows = tifilter(rows or {}, function(r)
                return r.AXSize.h > mean
              end)
              local cnt = 0
              for _, row in ipairs(rows) do
                if row.AXSize.h > mean then
                  cnt = cnt + 1
                  if cnt == idx then
                    return Callback.Clickable(row)
                  end
                end
              end
            end
          end,
          fn = Callback.Click
        })
        tinsert(openSavePanelHotkeys, hotkey)
        i = i + 1
      end
    end
  end
}

-- Register navigation and confirmation hotkeys for open/save panels.
--
-- Hotkeys are:
--   - bound per focused window
--   - rebuilt on panel content changes
--   - cleaned up on panel close or app deactivation
local function registerForOpenSavePanel(app, retry)
  for _, hotkey in ipairs(openSavePanelHotkeys) do
    hotkey:delete()
  end
  openSavePanelHotkeys = {}

  local appid = app:bundleID() or app:name()
  if appid == "com.apple.finder" or appid == "com.apple.dock" then return end
  local appUI = toappui(app)
  if not tcontain(appUI:attributeNames() or {}, "AXFocusedWindow") then
    retry = retry and retry + 1 or 1
    if not FLAGS["Loading"] and retry <= 3 then
      hs.timer.doAfter(0.1, bind(registerForOpenSavePanel, app, retry))
    end
    return
  end

  local getUIElements = function(winUI)
    local windowIdent = winUI.AXIdentifier

    local dontSaveButton
    if get(KeybindingConfigs.hotkeys, appid, "confirmDelete") == nil then
      local specialConfirmFunc = specialConfirmFuncs[appid]
      if specialConfirmFunc ~= nil then
        dontSaveButton = specialConfirmFunc(winUI)
      elseif windowIdent == "save-panel" then
        local elem = winUI
        if OS_VERSION >= OS.Tahoe then elem = getc(winUI, AX.SplitGroup, 1) end
        for _, button in ipairs(getc(elem, AX.Button) or {}) do
          if button.AXIdentifier == "DontSaveButton" then
            dontSaveButton = button
            break
          end
        end
      end
    end

    local outlineRows
    if windowIdent == "open-panel" or windowIdent == "save-panel" then
      local outline = getc(winUI, AX.SplitGroup, 1, AX.ScrollArea, 1, AX.Outline, 1)
      if outline ~= nil then
        outlineRows = {}
        for _, row in ipairs(getc(outline, AX.Row)) do
          if #row == 0 then hs.timer.usleep(0.3 * 1000000) end
          tinsert(outlineRows, row)
        end
      end
    elseif specialSidebarRowsFuncs[appid] then
      local specialSidebarRowsFunc = specialSidebarRowsFuncs[appid]
      outlineRows = specialSidebarRowsFunc(winUI)
    end
    return dontSaveButton, outlineRows
  end

  local actionFunc
  actionFunc = function(winUI, callByObserver)
    for _, hotkey in ipairs(openSavePanelHotkeys) do
      disableConditionInChain(appid, hotkey, true)
      hotkey:delete()
    end
    openSavePanelHotkeys = {}

    local windowIdent = winUI.AXIdentifier
    local dontSaveButton, outlineRows = getUIElements(winUI)
    local header
    local i = 1
    if windowIdent == "open-panel" or windowIdent == "save-panel" then
      for _, row in ipairs(outlineRows or {}) do
        if i > 10 then break end
        local titleElem = getc(row, AX.Cell, 1, AX.StaticText, 1)
        if titleElem and titleElem.AXIdentifier ~= nil then
          header = titleElem.AXValue
        elseif titleElem then
          local suffix
          if i == 1 then suffix = "st"
          elseif i == 2 then suffix = "nd"
          elseif i == 3 then suffix = "rd"
          else suffix = "th" end
          local hkID = strfmt("open%d%sSidebarItemOnOpenSavePanel", i, suffix)
          local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
          if spec ~= nil then
            if not titleElem:isValid() then
              actionFunc(winUI)
            end
            local folder = titleElem.AXValue
            local msg = folder
            if header then msg = header .. ' > ' .. msg end
            local hotkey = AppWinBind(app:focusedWindow(), {
              spec = spec, message = msg,
              fn = function() row.AXSelected = true end,
            })
            tinsert(openSavePanelHotkeys, hotkey)
            i = i + 1
          end
        end
      end
      if outlineRows and callByObserver ~= true
          and not (appid == "com.apple.Safari"
                   and windowIdent == "save-panel") then
        if outlineRows[1] and not outlineRows[1]:isValid() then
          actionFunc(winUI)
          return
        end
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(outlineRows[1].AXParent, uinotifications.rowCountChanged)
        observer:callback(function()
          if appBuf.lastRowCountChangedTimer then
            appBuf.lastRowCountChangedTimer:setNextTrigger(0.3)
            return
          end
          appBuf.lastRowCountChangedTimer = hs.timer.doAfter(0.3, function()
            appBuf.lastRowCountChangedTimer = nil
            for _, hotkey in ipairs(openSavePanelHotkeys) do
              disableConditionInChain(appid, hotkey, true)
              hotkey:delete()
            end
            openSavePanelHotkeys = {}
            actionFunc(winUI, true)
          end)
        end)
        observer:start()
        Evt.onDestroy(winUI, function()
          if observer then
            observer:stop() observer = nil
          end
        end,
        hs.application.watcher.deactivated, true)
      end
    elseif specialSidebarRowsSelectFuncs[appid] then
      local specialSidebarRowsSelectFunc = specialSidebarRowsSelectFuncs[appid]
      specialSidebarRowsSelectFunc(outlineRows)
    end

    if dontSaveButton ~= nil then
      local spec = get(KeybindingConfigs.hotkeys.shared, "confirmDelete")
      if spec ~= nil then
        local hotkey = AppWinBind(app:focusedWindow(), {
          spec = spec,
          message = dontSaveButton.AXTitle or dontSaveButton.AXDescription,
          fn = function() Callback.Press(dontSaveButton) end,
        })
        tinsert(openSavePanelHotkeys, hotkey)
      end
    end

    if dontSaveButton == nil and outlineRows == nil then return end
    Evt.onDestroy(winUI,
      function()
        for _, hotkey in ipairs(openSavePanelHotkeys) do
          disableConditionInChain(appid, hotkey, true)
          hotkey:delete()
        end
        openSavePanelHotkeys = {}
      end,
      hs.application.watcher.deactivated)
  end
  if app:focusedWindow() ~= nil then
    actionFunc(towinui(app:focusedWindow()))
  end

  local observer = uiobserver.new(app:pid())
  observer:addWatcher(toappui(app), uinotifications.focusedWindowChanged)
  observer:callback(function(_, element, notifications)
    hs.timer.doAfter(0.2, bind(actionFunc, element))
  end)
  observer:start()
  Evt.StopOnDeactivated(app, observer)
end

-- Bind a single Alt-based menu bar navigation hotkey.
--
-- This handles:
--   - non-frontmost apps (e.g. Steam helper)
--   - focus redirection
--   - menu activation via accessibility APIs
local function bindAltMenu(app, mods, key, message, fn)
  local config = {
    mods = mods, key = key, message = message, fn = fn,
  }
  if app:bundleID() == "com.valvesoftware.steam" then
    config.nonFrontmost = true
    config.condition = function()
      local focusedApp = hs.axuielement.systemWideElement().AXFocusedApplication
      if focusedApp then
        focusedApp = focusedApp:asHSApplication()
      end
      if focusedApp and (focusedApp:bundleID() ~= app:bundleID()
          and focusedApp:bundleID() ~= "com.valvesoftware.steam.helper" ) then
        return false, CF.uIElementNotFocused
      end
      return true
    end
  end
  local hotkey = AppBind(app, config)
  hotkey.subkind = HK.IN_APP_.MENU
  return hotkey
end

local function searchHotkeyByNth(itemTitles, alreadySetHotkeys, index)
  local notSetItems = {}
  for _, title in pairs(itemTitles) do
    if index == nil then
      index = title[2]:find(" ")
      if index ~= nil then
        index = index + 1
      end
    end
    local hotkey
    if index ~= nil then
      hotkey = title[2]:sub(index, index):upper()
    end

    if hotkey ~= nil and alreadySetHotkeys[hotkey] == nil then
        alreadySetHotkeys[hotkey] = title[1]
    else
      tinsert(notSetItems, title)
    end
  end
  return notSetItems, alreadySetHotkeys
end

local appsMayChangeMenuBar = {
  changing = tcopy(get(ApplicationConfigs, "menuBarItems", 'changing') or {}),
  onWindow = tcopy(get(ApplicationConfigs, "menuBarItems", 'changeOnWindow') or {})
}
local appsMayChangeMenuBarTmpDir =
    hs.fs.temporaryDirectory() .. hs.settings.bundleID .. '/application'
local appsMayChangeMenuBarTmpFile =
    appsMayChangeMenuBarTmpDir .. '/variable_menubar.json'
local windowOnBindAltMenu

local onLaunchedAndActivated
local function processInvalidAltMenu(app, reinvokeKey)
  local appid = app:bundleID() or app:name()
  local curWin = app:focusedWindow() and app:focusedWindow():id() or false
  local isSameWin = curWin == windowOnBindAltMenu
  if isSameWin then
    local _, framework = getResourceDir(appid)
    if framework.electron then
      onLaunchedAndActivated(app, reinvokeKey)
      return
    end
  end
  if isSameWin then
    tinsert(appsMayChangeMenuBar.changing, appid)
    local pos = tindex(appsMayChangeMenuBar.onWindow, appid)
    if pos then tremove(appsMayChangeMenuBar.onWindow, pos) end
  else
    tinsert(appsMayChangeMenuBar.onWindow, appid)
  end
  onLaunchedAndActivated(app, reinvokeKey)

  if not exists(appsMayChangeMenuBarTmpDir) then
    hs.execute(strfmt("mkdir -p '%s'", appsMayChangeMenuBarTmpDir))
  end
  local json = {}
  if exists(appsMayChangeMenuBarTmpFile) then
    json = hs.json.read(appsMayChangeMenuBarTmpFile)
  else
    json = {}
  end
  local key = isSameWin and "changing" or "onWindow"
  if json[key] == nil then json[key] = {} end
  tinsert(json[key], appid)
  if isSameWin then
    local pos = tindex(json["onWindow"] or {}, appid)
    if pos then tremove(json["onWindow"], pos) end
  end
  hs.json.write(json, appsMayChangeMenuBarTmpFile, false, true)
end

-- Applications typically use standard menu bar titles (e.g., "File", "Edit",
-- "View", "Window", "Help"). Because these titles are often localized by the OS,
-- we intentionally do not attempt to de-localize them through app bundle searches.
-- Note that some apps may still use uncommon English titles.
local specialLocalizedCommonMenuBarTitle = {
  ["com.tencent.yuanbao"] = { View = "Display" },
}
Evt.OnRunning("com.tencent.xinWeChat", function(app)
  local appid = app:bundleID()
  if applicationVersion(appid) >= 4 then
    specialLocalizedCommonMenuBarTitle[appid] = { View = "Show" }
  end
end)

-- Dynamically bind Alt-based hotkeys for menu bar items.
--
-- Supports:
--   - letter-based access (Alt + letter)
--   - index-based access (Alt + number)
--   - window-specific menu bars
--
-- Hotkeys are rebuilt when:
--   - menu bar structure changes
--   - focused window changes
--   - localization differs
local function altMenuBarItem(app, force, reinvokeKey)
  windowOnBindAltMenu = nil

  local appid = app:bundleID() or app:name()
  local prefix = '__menubar__'
  local enabled = false
  for hkID, hotkey in pairs(inAppHotKeys[appid] or {}) do
    if hkID:sub(1, #prefix) == prefix then
      if force then
        hotkey:delete()
        inAppHotKeys[appid][hkID] = nil
      else
        hotkey:enable()
        enabled = true
      end
    end
  end
  if enabled then return end

  -- check whether called by window filter (possibly with delay)
  if appid ~= hs.application.frontmostApplication():bundleID() then
    return
  end
  local modsIndex = get(KeybindingConfigs.hotkeys,
      "menubar", "index", "mods")
  if modsIndex == "" or (type(modsIndex) == 'table' and #modsIndex == 0) then
    modsIndex = false
  end
  local modsLetter = get(KeybindingConfigs.hotkeys,
      "menubar", "letter", "mods")
  if modsLetter == "" or (type(modsLetter) == 'table' and #modsLetter == 0) then
    modsLetter = false
  end
  local specAppMenu = get(KeybindingConfigs.hotkeys, "menubar", "appMenu")
  local excludedForIndex = get(KeybindingConfigs.hotkeys,
      "menubar", "index", "exclude")
  if excludedForIndex ~= nil and tcontain(excludedForIndex, appid) then
    modsIndex = false
  end
  local excludedForLetter = get(KeybindingConfigs.hotkeys,
      "menubar", "letter", "exclude")
  if excludedForLetter ~= nil and tcontain(excludedForLetter, appid) then
    modsLetter = false
  end
  if not (modsIndex or modsLetter) then return end

  if appid == "com.valvesoftware.steam.helper" then
    appid = "com.valvesoftware.steam"
    app = find(appid)
    if app == nil then return end
  end

  local menuBarItems, menuBarItemTitles
  local useWindowMenuBar
  if app:focusedWindow() ~= nil then
    local winUI = towinui(app:focusedWindow())
    if #getc(winUI, AX.MenuBar) > 0 then
      local menus = getc(winUI, AX.MenuBar, 1, AX.Menu)
      if #menus == 0 then
        menus = getc(winUI, AX.MenuBar, 1, AX.MenuBar)
      end
      if #menus > 0 then
        useWindowMenuBar = true
        menuBarItemTitles = tmap(menus, function(item)
          return item.AXTitle:gsub("[%c%s]+$", ""):gsub("^[%c%s]+", "")
        end)
        tinsert(menuBarItemTitles, 1, app:name())
        menuBarItems = menus
      end
    end
  end
  local menuBarItemActualIndices = {}
  if menuBarItemTitles == nil then
    menuBarItems = getMenuBarItems(app)
    if #menuBarItems == 0 then return end
    local itemDict = {}
    menuBarItemTitles = {}
    for i, item in ipairs(menuBarItems) do
      if item.AXTitle == nil then
        -- invalid menu bar item
        -- e.g. expected "Edit" menu in `Adblock Plus`
        goto CHECK_MENU_ITEM_CONTINUE
      end
      if itemDict[item.AXTitle] then
        if item.AXTitle == app:name() then
          -- ordinary menu bar item share the same title with app menu
          -- e.g. "Barrier" menu in `Barrier`
          menuBarItemActualIndices[item.AXTitle] = i
        elseif itemDict[item.AXTitle].AXChildren == nil then
          -- two ordinary menu bar items share the same title, but the former is invalid
          -- e.g. two "File" menus in `QQLive`
          local idx = tindex(menuBarItemTitles, item.AXTitle)
          tremove(menuBarItemTitles, idx)
          menuBarItemActualIndices[item.AXTitle] = i
        elseif item.AXChildren == nil then
          -- two ordinary menu bar items share the same title, but the latter is invalid
          goto CHECK_MENU_ITEM_CONTINUE
        end
        -- assume at most two menu bar items share the same title
      end
      itemDict[item.AXTitle] = item
      tinsert(menuBarItemTitles, item.AXTitle)
      ::CHECK_MENU_ITEM_CONTINUE::
    end
    menuBarItemTitles = tfilter(menuBarItemTitles, function(item)
      return item ~= nil and item ~= ""
    end)
  end
  if menuBarItemTitles == nil or #menuBarItemTitles == 0 then return end
  if app:focusedWindow() ~= nil then
    windowOnBindAltMenu = app:focusedWindow():id()
  else
    windowOnBindAltMenu = false
  end

  local clickMenuCallback
  if useWindowMenuBar then
    clickMenuCallback = function(title, k)
      local menuBarItem = tfind(menuBarItems, function(item)
        return item.AXTitle:gsub("[%c%s]+$", ""):gsub("^[%c%s]+", "") == title
      end)
      if menuBarItem == nil then
        processInvalidAltMenu(app, k)
        return
      end
      local actionNames = menuBarItem:actionNames()
      if actionNames ~= nil and tcontain(actionNames, AX.Pick) then
        menuBarItem:performAction(AX.Pick)
      elseif actionNames ~= nil and tcontain(actionNames, AX.Press) then
        Callback.Press(menuBarItem)
      else
        leftClick(menuBarItem, app)
      end
    end
  else
    clickMenuCallback = function(title, k)
      local index = menuBarItemActualIndices[title]
      if index then
        local menubarItem = menuBarItems[index]
        if menubarItem then
          Callback.Press(menubarItem)
          return
        end
      else
        local ok = app:selectMenuItem({ title })
        if ok then return end
      end
      processInvalidAltMenu(app, k)
    end
  end

  -- by initial or otherwise second letter in title
  local alreadySetHotkeys = {}
  if modsLetter then
    local itemTitles = {}
    for i=2,#menuBarItemTitles do
      local title, letter = menuBarItemTitles[i]:match("(.-)%s*%((.-)%)")
      if letter then
        alreadySetHotkeys[letter:upper()] = {menuBarItemTitles[i], title}
      else
        letter = menuBarItemTitles[i]:match("[^%s]-&(%a)")
        if letter ~= nil then
          title = menuBarItemTitles[i]:gsub('([^%s]-)&(%a)', '%1%2')
          alreadySetHotkeys[letter:upper()] = { menuBarItemTitles[i], title }
        else
          tinsert(itemTitles, menuBarItemTitles[i])
        end
      end
    end

    -- process localized titles
    local itemLocTitles = delocalizeMenuBarItems(itemTitles, appid)
    local specialMap = specialLocalizedCommonMenuBarTitle[appid]
    if specialMap then
      for _, title in ipairs(itemLocTitles) do
        if title[1] ~= title[2] and specialMap[title[2]] then
          title[2] = specialMap[title[2]]
        end
      end
    end
    if #itemTitles ~= #itemLocTitles then
      if appid == "com.tencent.xinWeChat" then
        local exBundleID = Version.LessThan(app, "4")
            and "com.tencent.xinWeChat.WeChatAppEx" or "com.tencent.flue.WeChatAppEx"
        local newItemLocTitles = delocalizeMenuBarItems(itemTitles, exBundleID)
        if #itemTitles == #newItemLocTitles then
          itemLocTitles = newItemLocTitles
        end
      end
    end
    itemTitles = itemLocTitles
    for i=#itemTitles,1,-1 do
      local letter = itemTitles[i][2]:match("[^%s]-&(%a)")
      if letter ~= nil then
        alreadySetHotkeys[letter:upper()] = itemTitles[i][1]
        tremove(itemTitles, i)
      end
    end

    local notSetItems = {}
    for _, title in ipairs(itemTitles) do
      if tcontain({ 'File', 'Edit', 'View', 'Window', 'Help' }, title[2]) then
        local hotkey = title[2]:sub(1, 1)
        if alreadySetHotkeys[hotkey] == nil then
          alreadySetHotkeys[hotkey] = title[1]
        else
          tinsert(notSetItems, title)
        end
      else
        tinsert(notSetItems, title)
      end
    end
    notSetItems, alreadySetHotkeys =
        searchHotkeyByNth(notSetItems, alreadySetHotkeys, 1)
    -- if there are still items not set, set them by first letter of second word
    notSetItems, alreadySetHotkeys =
        searchHotkeyByNth(notSetItems, alreadySetHotkeys, nil)
    -- if there are still items not set, set them by second letter
    notSetItems, alreadySetHotkeys =
        searchHotkeyByNth(notSetItems, alreadySetHotkeys, 2)
    -- if there are still items not set, set them by third letter
    notSetItems, alreadySetHotkeys =
        searchHotkeyByNth(notSetItems, alreadySetHotkeys, 3)
    -- if there are still items not set, set them by fourth letter
    searchHotkeyByNth(notSetItems, alreadySetHotkeys, 4)
    local invMap = {}
    for key, title in pairs(alreadySetHotkeys) do
      local menuBarItem = type(title) == 'table' and title[1] or title
      local msg = type(title) == 'table' and title[2] or title
      invMap[menuBarItem] = {key, msg}
    end
    if inAppHotKeys[appid] == nil then
      inAppHotKeys[appid] = {}
    end
    local prefixL = prefix .. 'letter__'
    for i=2,#menuBarItemTitles do
      local spec = invMap[menuBarItemTitles[i]]
      if spec ~= nil then
        local fn = bind(clickMenuCallback, menuBarItemTitles[i], spec[1])
        local hotkey = bindAltMenu(app, modsLetter, spec[1], spec[2], fn)
        inAppHotKeys[appid][prefixL..tostring(i-1)] = hotkey
        if reinvokeKey == spec[1] then
          clickMenuCallback(menuBarItemTitles[i])
        end
      end
    end
  end

  -- by index
  if modsIndex then
    if app:focusedWindow() ~= nil then
      windowOnBindAltMenu = app:focusedWindow():id()
    else
      windowOnBindAltMenu = false
    end

    local maxMenuBarItemHotkey =
        #menuBarItemTitles > 11 and 10 or (#menuBarItemTitles - 1)

    local itemTitles = {}
    for i=2,#menuBarItemTitles do
      local title, letter = menuBarItemTitles[i]:match("(.-)%s*%((.-)%)")
      if letter then
        tinsert(itemTitles, title)
      else
        letter = menuBarItemTitles[i]:match("[^%s]-&(%a)")
        if letter ~= nil then
          title = menuBarItemTitles[i]:gsub('([^%s]-)&(%a)', '%1%2')
          tinsert(itemTitles, title)
        else
          tinsert(itemTitles, menuBarItemTitles[i])
        end
      end
    end
    if inAppHotKeys[appid] == nil then
      inAppHotKeys[appid] = {}
    end
    local prefixI = prefix .. 'index__'
    for i=1,maxMenuBarItemHotkey do
      local fn = bind(clickMenuCallback, menuBarItemTitles[i + 1], i % 10)
      local hotkey = bindAltMenu(app, modsIndex, tostring(i % 10), itemTitles[i], fn)
      inAppHotKeys[appid][prefixI..tostring(i)] = hotkey
      if reinvokeKey == i % 10 then
        clickMenuCallback(menuBarItemTitles[i + 1])
      end
    end
  end

  -- app menu
  if specAppMenu and specAppMenu.key then
    if inAppHotKeys[appid] == nil then
      inAppHotKeys[appid] = {}
    end
    local hotkey = bindAltMenu(app, specAppMenu.mods, specAppMenu.key,
        menuBarItemTitles[1],
        function() app:selectMenuItem({ menuBarItemTitles[1] }) end)
    inAppHotKeys[appid][prefix..'app'] = hotkey
  end
end

-- Generate a comparable string representation of menu bar titles.
--
-- Used to detect structural changes in menu bars.
local menuBarItemTitlesString = { app = {}, win = {} }

local function getMenuBarItemTitlesStringImpl(menuBarItems)
  if #menuBarItems == 0 then return "" end
  local menuBarItemTitles = {}
  for _, item in ipairs(menuBarItems) do
    tinsert(menuBarItemTitles, item.AXTitle)
  end
  return table.concat(menuBarItemTitles, "|")
end

local function getMenuBarItemTitlesString(app)
  local menuBarItems = getMenuBarItems(app)
  local appMenuBarStr = getMenuBarItemTitlesStringImpl(menuBarItems)
  local winMenuBarStr
  if app:focusedWindow() ~= nil then
    local winUI = towinui(app:focusedWindow())
    if #getc(winUI, AX.MenuBar) > 0 then
      local winMenuBarItems = getc(winUI, AX.MenuBar, 1, AX.Menu)
      if #winMenuBarItems == 0 then
        winMenuBarItems = getc(winUI, AX.MenuBar, 1, AX.MenuBar)
      end
      winMenuBarStr = getMenuBarItemTitlesStringImpl(winMenuBarItems)
    end
  end
  return appMenuBarStr, winMenuBarStr
end

local function watchMenuBarItems(app)
  local appid = app:bundleID() or app:name()
  menuBarItemTitlesString.app[appid], menuBarItemTitlesString.win[appid]
      = getMenuBarItemTitlesString(app)
  local watcher = ExecContinuously(function()
    local app = find(appid)
    if app == nil then return end
    local mbTitlesStr, mbTitlesStrWin
        = getMenuBarItemTitlesString(app)
    -- assume menu mars of app & window don't change at the same time
    if mbTitlesStr ~= menuBarItemTitlesString.app[appid] then
      menuBarItemTitlesString.app[appid] = mbTitlesStr
      altMenuBarItem(app, true)
      remapPreviousTab(app, true)
      registerOpenRecent(app, true)
      registerZoomHotkeys(app, true)
      registerResizeHotkeys(app)
    end
    if mbTitlesStrWin ~= menuBarItemTitlesString.win[appid] then
      menuBarItemTitlesString.win[appid] = mbTitlesStrWin
      altMenuBarItem(app, true)
    end
  end)
  Evt.OnDeactivated(app, function()
    StopExecContinuously(watcher)
    menuBarItemTitlesString.app[appid] = nil
  end)
end

-- some apps may change their menu bar items based on the focused window
if exists(appsMayChangeMenuBarTmpFile) then
  local tmp = hs.json.read(appsMayChangeMenuBarTmpFile)
  for _, appid in ipairs(tmp['changing'] or {}) do
    tinsert(appsMayChangeMenuBar.changing, appid)
  end
  for _, appid in ipairs(tmp['onWindow'] or {}) do
    tinsert(appsMayChangeMenuBar.onWindow, appid)
  end
end

-- Callback invoked when menu bar structure may have changed.
--
-- This triggers re-registration of shared hotkeys.
local function appMenuBarChangeCallback(app)
  local appid = app:bundleID() or app:name()
  local menuBarItemStr, winMenuBarItemStr = getMenuBarItemTitlesString(app)
  if menuBarItemStr == menuBarItemTitlesString.app[appid] then
    if winMenuBarItemStr ~= menuBarItemTitlesString.win[appid] then
      menuBarItemTitlesString.win[appid] = winMenuBarItemStr
      altMenuBarItem(app, true)
    end
    return
  end
  menuBarItemTitlesString.app[appid] = menuBarItemStr
  altMenuBarItem(app, true)
  remapPreviousTab(app, true)
  registerOpenRecent(app, true)
  registerZoomHotkeys(app, true)
  registerResizeHotkeys(app)
  hs.timer.doAfter(1, function()
    if hs.application.frontmostApplication():bundleID() ~= app:bundleID() then
      return
    end
    local newMenuBarItemTitlesString = getMenuBarItemTitlesString(app)
    if newMenuBarItemTitlesString ~= menuBarItemStr then
      menuBarItemTitlesString.app[appid] = newMenuBarItemTitlesString
      altMenuBarItem(app, true)
      remapPreviousTab(app, true)
      registerOpenRecent(app, true)
      registerZoomHotkeys(app, true)
      registerResizeHotkeys(app)
    end
  end)
end

-- Register observers to detect menu bar changes.
--
-- Some apps change menu bars:
--   - dynamically
--   - per focused window
--   - asynchronously after launch
local function registerObserverForMenuBarChange(app)
  local appid = app:bundleID() or app:name()

  if tcontain(appsMayChangeMenuBar.changing, appid) then
    watchMenuBarItems(app)
  end

  if not tcontain(appsMayChangeMenuBar.onWindow, appid) then
    return
  end

  menuBarItemTitlesString.app[appid], menuBarItemTitlesString.win[appid]
      = getMenuBarItemTitlesString(app)

  local observer
  observer = uiobserver.new(app:pid())
  local appUI = toappui(app)
  observer:addWatcher(appUI, uinotifications.focusedWindowChanged)
  observer:callback(bind(appMenuBarChangeCallback, app))
  observer:start()
  Evt.StopOnDeactivated(app, observer)
end


-- register hotekys & watchers for hotkeys

local frontApp = hs.application.frontmostApplication()
local frontWin = hs.window.frontmostWindow()

-- register hotkeys for background apps
for appid, appConfig in pairs(appHotKeyCallbacks) do
  registerRunningAppHotKeys(appid)
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}
  local hasNotPersistentBackgroundHotkey =
      any(appConfig, function(cfg, hkID)
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
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
    Evt.OnTerminated(appid, bind(unregisterRunningAppHotKeys, appid))
  end
end

-- register hotkeys for active app
LAZY_REGISTER_MENUBAR_OBSERVER = true
if not LAZY_REGISTER_MENUBAR_OBSERVER then
  local appMenuBarItems = tmap(runningAppsOnLoading, function(app)
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

onLaunchedAndActivated = function(app, reinvokeKey)
  local menuBarItems = getMenuBarItems(app)
  local localeUpdated = updateAppLocale(app)
  local menuBarChanged = reinvokeKey ~= nil
  altMenuBarItem(app, nil, reinvokeKey)
  if localeUpdated or menuBarChanged then
    unregisterInAppHotKeys(app, true)
    local appid = app:bundleID() or app:name()
    foreach(FocusedWindowObservers[appid] or {},
        function(observer) observer:stop() end)
    FocusedWindowObservers[appid] = nil
    foreach(inWinHotKeys[appid] or {}, function(hotkeys)
      foreach(hotkeys, function(hk) hk:delete() end)
    end)
    inWinHotKeys[appid] = nil
    ActivatedAppConditionChain[appid] = nil
  end
  registerInAppHotKeys(app)
  registerWinFiltersForApp(app)
  remapPreviousTab(app)
  registerOpenRecent(app)
  registerZoomHotkeys(app)
  registerResizeHotkeys(app)
  registerObserverForMenuBarChange(app)
  registerObserverForSettingsMenuItem(app)

  return #menuBarItems > 0
end
if frontApp then
  registerForOpenSavePanel(frontApp)
  onLaunchedAndActivated(frontApp)
end

-- register watchers for window belonging to daemon app
for appid, appConfig in pairs(appHotKeyCallbacks) do
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}
  local hasDaemonAppWindowHotkey = any(appConfig, function(cfg, hkID)
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    if hasKey == false then
      local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
          or specialCommonHotkeyConfigs[hkID]
      if kbShared ~= nil then
        hasKey = true
      end
    end
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
  if DaemonAppFocusedWindowObservers[frontWinAppID] ~= nil then
    for filter, _ in pairs(DaemonAppFocusedWindowObservers[frontWinAppID]) do
      local actualFilter, allowSheet, allowPopover, condition
      if type(filter) == 'table' then
        actualFilter = tcopy(filter)
        allowSheet, allowPopover = filter.allowSheet, filter.allowPopover
        actualFilter.allowSheet, actualFilter.allowPopover = nil, nil
        condition = actualFilter.fn
        actualFilter.fn, actualFilter.allowURLs = nil, nil
        if sameFilter(actualFilter, {}) then actualFilter = true end
      else
        actualFilter = filter
      end
      if allowSheet or allowPopover then
        actualFilter = false
      end
      local windowFilter = hs.window.filter.new(false):setAppFilter(
          frontWin:application():name(), actualFilter)
      if (allowSheet and frontWin:role() == AX.Sheet)
          or (allowPopover and frontWin:role() == AX.Popover)
          or windowFilter:isWindowAllowed(frontWin)
          and (condition == nil or condition(frontWin)) then
        registerDaemonAppInWinHotkeys(frontWin, frontWinAppID, filter)
      end
    end
  end
end

-- register hotkeys for non-frontmost window belonging to daemon app
for appid, _ in pairs(DaemonAppFocusedWindowObservers) do
  local app = runningAppsOnLoading[appid]
  if app then
    local nonFrontmostFilters = {}
    for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
      local keybinding = get(KeybindingConfigs.hotkeys[appid], hkID)
          or { mods = cfg.mods, key = cfg.key }
      if keybinding.nonFrontmost or cfg.nonFrontmost then
        local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
        if hasKey == false then
          local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
              or specialCommonHotkeyConfigs[hkID]
          if kbShared ~= nil then
            hasKey = true
          end
        end
        if hasKey then
          tinsert(nonFrontmostFilters, keybinding.windowFilter or cfg.windowFilter)
        end
      end
    end
    for _, filter in ipairs(nonFrontmostFilters) do
      local actualFilter, allowSheet, allowPopover, condition
      if type(filter) == 'table' then
        actualFilter = tcopy(filter)
        allowSheet, allowPopover = filter.allowSheet, filter.allowPopover
        actualFilter.allowSheet, actualFilter.allowPopover = nil, nil
        condition = actualFilter.fn
        actualFilter.fn, actualFilter.allowURLs = nil, nil
        if sameFilter(actualFilter, {}) then actualFilter = true end
      else
        actualFilter = filter
      end
      if allowSheet or allowPopover then
        actualFilter = false
      end
      local windowFilter = hs.window.filter.new(false):setAppFilter(
          app:name(), actualFilter)
      local win = tfind(app:visibleWindows(), function(win)
        return (frontWin == nil or win:id() ~= frontWin:id())
          and (allowSheet and win:role() == AX.Sheet)
          or (allowPopover and win:role() == AX.Popover)
          or windowFilter:isWindowAllowed(win)
          and (condition == nil or condition(win))
      end)
      if win then
        registerDaemonAppInWinHotkeys(win, appid, filter)
      end
    end
  end
end

-- register watchers for menu of menubar app
for appid, appConfig in pairs(appHotKeyCallbacks) do
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}
  local hasMenuBarMenuHotkey = any(appConfig, function(cfg, hkID)
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
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
for appid, _ in pairs(MenuBarMenuObservers) do
  local app = find(appid)  -- "runningAppsOnLoading" may lead to null menubar item
  for _, menuBarItem in ipairs(getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)) do
    if menuBarItem.AXSelected then
      registerInMenuHotkeys(app)
      break
    end
  end
end

-- register watchers for preferences menu item in right menu bar menu
for appid, observer in pairs(MenuBarMenuSelectedObservers) do
  local app = runningAppsOnLoading[appid]
  registerObserverForRightMenuBarSettingsMenuItem(app, observer)
end

-- auto hide or quit apps with no windows (including pseudo windows such as popover or sheet)
local appsWithoutWindow = { hide = {}, quit = {} }
-- account for pseudo windows such as popover or sheet
local appsWithNoPseudoWindow = { hide = {}, quit = {} }
-- some apps may first close a window before create a targeted one, so delay is needed before checking
local appsWithoutWindowDelay = {}

do
  local appsHideWithoutWindowLoaded = ApplicationConfigs["hideWithoutWindow"] or {}
  local appsQuitWithoutWindowLoaded = ApplicationConfigs["quitWithoutWindow"] or {}

  for _, item in ipairs(appsHideWithoutWindowLoaded) do
    if type(item) == 'string' then
      appsWithoutWindow.hide[item] = true
    else
      for appid, cfg in pairs(item) do
        local windowFilter
        for k, v in pairs(cfg) do
          if (k == "allowPopover" or k == "allowSheet") and v then
            appsWithNoPseudoWindow.hide[appid] = {}
            if k == "allowPopover" then
              tinsert(appsWithNoPseudoWindow.hide[appid], AX.Popover)
            end
            if k == "allowSheet" then
              tinsert(appsWithNoPseudoWindow.hide[appid], AX.Sheet)
            end
          elseif k == "delay" then
            appsWithoutWindowDelay[appid] = v
          else
            if windowFilter == nil then windowFilter = {} end
            windowFilter[k] = v
          end
        end
        appsWithoutWindow.hide[appid] = windowFilter or true
      end
    end
  end
  for _, item in ipairs(appsQuitWithoutWindowLoaded) do
    if type(item) == 'string' then
      appsWithoutWindow.quit[item] = true
    else
      for appid, cfg in pairs(item) do
        local windowFilter
        for k, v in pairs(cfg) do
          if (k == "allowPopover" or k == "allowSheet") and v then
            appsWithNoPseudoWindow.quit[appid] = {}
            if k == "allowPopover" then
              tinsert(appsWithNoPseudoWindow.quit[appid], AX.Popover)
            end
            if k == "allowSheet" then
              tinsert(appsWithNoPseudoWindow.quit[appid], AX.Sheet)
            end
          elseif k == "delay" then
            appsWithoutWindowDelay[appid] = v
          else
            if windowFilter == nil then windowFilter = {} end
            windowFilter[k] = v
          end
        end
        appsWithoutWindow.quit[appid] = windowFilter or true
      end
    end
  end
end

local specialNoWindowRules = {
  ["com.apple.finder"] = function(app)
    if #hs.window.visibleWindows() == 1 and (hs.window.desktop()
        and hs.window.visibleWindows()[1]:id() == hs.window.desktop():id()) then
      return false
    end
    local nonDesktopWindows = tifilter(app:visibleWindows(), function(win)
      return hs.window.desktop() == nil or win:id() ~= hs.window.desktop():id()
    end)
    if #nonDesktopWindows == 0 then return true end
    local appid = app:bundleID()
    local quit = appsWithoutWindow.quit[appid] ~= nil
    local windowFilterRules = quit and appsWithoutWindow.quit
        or appsWithoutWindow.hide
    local windowFilter = hs.window.filter.new(false):setAppFilter(
      app:name(), windowFilterRules[appid])
    return tfind(nonDesktopWindows, function(win)
      return windowFilter:isWindowAllowed(win)
    end) == nil
  end
}
local function processAppWithoutWindow(app)
  local appid = app:bundleID() or app:name()
  local fn = function()
    local quit = appsWithoutWindow.quit[appid] ~= nil
    local defaultRule = function()
      local windowFilterRules = quit and appsWithoutWindow.quit
          or appsWithoutWindow.hide
      local windowFilter = hs.window.filter.new(false):setAppFilter(
          app:name(), windowFilterRules[appid])
      return tfind(app:visibleWindows(), function(win)
        return win:application() and windowFilter:isWindowAllowed(win)
      end) == nil
    end
    local specialRule = specialNoWindowRules[appid]
    if (specialRule == nil and defaultRule())
        or (specialRule ~= nil and specialRule(app, defaultRule)) then
      if quit == true then
        local wFilter = hs.window.filter.new(app:name())
        if #wFilter:getWindows() == 0 then
          app:kill()
        end
      else
        app:hide()
      end
    end
  end
  if appsWithoutWindowDelay[appid] == nil then
    fn()
  else
    hs.timer.doAfter(appsWithoutWindowDelay[appid], fn)
  end
end

local specialNoPseudoWindowRules = {
  ["com.app.menubarx"] = function(app, defaultRule)
    return Version.LessThan(app, "1.6.9") and defaultRule()
  end
}
PseudoWindowDestroyObservers = {}
local function registerPseudoWindowDestroyObserver(app, roles)
  local appid = app:bundleID() or app:name()
  local observer = PseudoWindowDestroyObservers[appid]
  local appUI = toappui(app)
  if observer ~= nil then observer:start() return end
  observer = uiobserver.new(app:pid())
  observer:addWatcher(appUI, uinotifications.focusedUIElementChanged)
  local quit = appsWithNoPseudoWindow.quit[appid] ~= nil
  local windowFilterRules = quit and appsWithoutWindow.quit
      or appsWithoutWindow.hide
  local windowFilter = hs.window.filter.new(false):setAppFilter(
      app:name(), windowFilterRules[appid])
  local criterion = function(element) return tcontain(roles, element.AXRole) end
  local params = { count = 1, depth = 2 }
  local pseudoWindowObserver
  local observerCallback = function()
    appUI:elementSearch(function(msg, results, count)
      if count > 0 then
        if pseudoWindowObserver ~= nil then
          pseudoWindowObserver:stop()
          pseudoWindowObserver = nil
        end
        local role = results[1].AXRole
        local pseudoWindowObserverCallback = function()
          appUI:elementSearch(function(newMsg, newResults, newCount)
              if newCount == 0 then
                local defaultRule = function()
                  local noWindow = tfind(app:visibleWindows(), function(win)
                    return windowFilter:isWindowAllowed(win)
                  end) == nil
                  local noMenuFromPopover = true
                  if role == AX.Popover then
                    local menuBarMenu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1)
                    noMenuFromPopover = menuBarMenu.AXSelected == false
                  end
                  return noWindow and noMenuFromPopover
                end
                local specialRule = specialNoPseudoWindowRules[appid]
                if (specialRule == nil and defaultRule())
                    or (specialRule ~= nil and specialRule(app, defaultRule)) then
                  if quit == true then
                    local wFilter = hs.window.filter.new(app:name())
                    if #wFilter:getWindows() == 0 then
                      app:kill()
                    end
                  else
                    app:hide()
                  end
                end
              end
            end,
            criterion, params)
        end
        if appsWithoutWindowDelay[appid] then
          local oldCallback = pseudoWindowObserverCallback
          pseudoWindowObserverCallback = function()
            hs.timer.doAfter(appsWithoutWindowDelay[appid], oldCallback)
          end
        end
        pseudoWindowObserver = Evt.onDestroy(
          results[1],
          pseudoWindowObserverCallback,
          hs.application.watcher.deactivated
        )
      end
    end,
    criterion, params)
  end
  observer:callback(observerCallback)
  observer:start()
  PseudoWindowDestroyObservers[appid] = observer
  Evt.StopOnTerminated(app, observer,
      function() PseudoWindowDestroyObservers[appid] = nil end)
end

AutoHideQuitWindowFilter = hs.window.filter.new(false)
for _, configs in ipairs{appsWithoutWindow.hide, appsWithoutWindow.quit} do
  for appid, cfg in pairs(configs) do
    Evt.OnRunning(appid, function(app)
      AutoHideQuitWindowFilter:setAppFilter(app:name(), cfg)
    end)
  end
end
AutoHideQuitWindowFilter:subscribe(hs.window.filter.windowDestroyed,
  function(win)
    if win == nil or win:application() == nil then return end
    processAppWithoutWindow(win:application())
  end)

-- Hammerspoon only account standard windows, so add watchers for pseudo windows here
for _, configs in ipairs {
  appsWithNoPseudoWindow.hide,
  appsWithNoPseudoWindow.quit,
} do
  for appid, roles in pairs(configs) do
    Evt.OnRunning(appid, function(app)
      registerPseudoWindowDestroyObserver(app, roles)
    end)
  end
end


-- ## configure specific apps

-- ### Mountain Duck
-- connect to servers on launch
local function connectMountainDuckEntries(app, connection)
  local appUI = toappui(app)
  local menuBar = getc(appUI, AX.MenuBar, -1, AX.Menu, 1)

  if type(connection) == 'string' then
    local menuItem = getc(menuBar, AX.MenuItem, connection,
        AX.Menu, 1, AX.MenuItem, 1)
    if menuItem ~= nil then
      Callback.Press(menuItem)
    end
  else
    local fullfilled = connection.condition(app)
    if fullfilled == nil then return end
    local connects = connection[connection.locations[fullfilled and 1 or 2]]
    local disconnects = connection[connection.locations[fullfilled and 2 or 1]]
    for _, item in ipairs(connects) do
      local menuItem = getc(menuBar, AX.MenuItem, item,
          AX.Menu, 1, AX.MenuItem, 1)
      if menuItem ~= nil then
        Callback.Press(menuItem)
      end
    end
    local disconnect = T('Disconnect', app)
    for _, item in ipairs(disconnects) do
      local menuItem = getc(menuBar, AX.MenuItem, item,
          AX.Menu, 1, AX.MenuItem, disconnect)
      if menuItem ~= nil then
        Callback.Press(menuItem)
      end
    end
  end
end
do
  local mountainDuckConfig = ApplicationConfigs["io.mountainduck"]
  if mountainDuckConfig ~= nil and mountainDuckConfig.connections ~= nil then
    for _, connection in ipairs(mountainDuckConfig.connections) do
      if type(connection) == 'table' then
        local shell_command = get(connection, "condition", "shell_command")
        if shell_command ~= nil then
          connection.condition = function()
            local _, _, _, rc = hs.execute(shell_command)
            if rc == 0 then
              return true
            elseif rc == 1 then
              return false
            else
              return nil
            end
          end
        else
          connection.condition = nil
        end
      end
    end
    Evt.OnRunning("io.mountainduck", function(app)
      for _, connection in ipairs(mountainDuckConfig.connections) do
        connectMountainDuckEntries(app, connection)
      end
    end)
  end
end

-- ## Barrier
-- barrier window may not be focused when it is created, so focus it
-- note: barrier is mistakenly recognized as an app prohibited from having GUI elements,
--       so window filter does not work unless the app is activated once.
--       we use uielement observer instead
if installed("barrier") then
  Evt.OnRunning("barrier", function(app)
    local observer = uiobserver.new(app:pid())
    observer:addWatcher(toappui(app), uinotifications.windowCreated)
    observer:callback(function(_, winUI) winUI:asHSWindow():focus() end)
    observer:start()
    Evt.StopOnTerminated(app, observer)
  end)
end

-- ## remote desktop apps
-- remap modifier keys for specified windows of remote desktop apps
local remoteDesktopsMappingModifiers =
    get(KeybindingConfigs, 'remoteDesktopModifiers') or {}
for _, rules in pairs(remoteDesktopsMappingModifiers) do
  for _, r in ipairs(rules) do
    local newMap = {}
    for k, v in pairs(r.map) do
      k = toshort(k)
      if k ~= nil then newMap[k] = toshort(v) end
    end
    r.map = newMap
  end
end

WF.MRD = {}
WF.MRD.Remote = {}
if hs.application.nameForBundleID("com.microsoft.rdc.macos") == "Windows App" then
  Evt.OnRunning("com.microsoft.rdc.macos", function(app)
    WF.MRD.Remote = { rejectTitles = {} }
    for _, title in ipairs {"Favorites", "Devices", "Apps",
      "Settings", "About", "Device View Options", "App View Options" } do
      local locTitle = "^" .. T(title, app) .. "$"
      tinsert(WF.MRD.Remote.rejectTitles, locTitle)
    end
  end)
else
  WF.MRD.Remote = {
    rejectTitles = {
      "^Microsoft Remote Desktop$",
      "^Preferences$",
    }
  }
end

local function isDefaultRemoteDesktopWindow(window)
  local appid = window:application():bundleID()
  if appid == "com.realvnc.vncviewer" then
    local winUI = towinui(window)
    return tfind(getc(winUI, AX.Button),
      function(child) return child.AXHelp == "Session information" end) ~= nil
  elseif appid == "com.microsoft.rdc.macos" then
    local wFilter = hs.window.filter.new(false):setAppFilter(
        window:application():name(), WF.MRD.Remote)
    local result = wFilter:isWindowAllowed(window)
    if result then
      local winUI = towinui(window)
      local title
      title = "Cancel"
      if window:application():name() == "Windows App" then
        title = T(title, window:application())
      end
      for _, bt in ipairs(getc(winUI, AX.Button)) do
        if bt.AXTitle == title then
          return false
        end
      end
    end
    return result
  end
  return true
end

local function remoteDesktopWindowFilter(app)
  local appid = app:bundleID()
  local rules = remoteDesktopsMappingModifiers[appid]
  local win = app:focusedWindow()
  for _, r in ipairs(rules or {}) do
    local valid = false
    -- some remote desktop like 'VNC Viewer' works at a lower level than Hammerspoon,
    -- so we have to remap modifiers by app like 'Karabiner' which works at a even lower level
    -- and restore modifiers in non-remote windows
    if win == nil or win:role() == AX.Sheet or win:role() == AX.Popover then
      valid = r.type == 'restore'
    elseif r.condition == nil then
      local isRDW = isDefaultRemoteDesktopWindow(win)
      valid = (r.type == 'restore' and not isRDW) or (r.type ~= 'restore' and isRDW)
    else
      if r.condition.windowFilter ~= nil then  -- currently only support window filter
        local wFilter = hs.window.filter.new(false):setAppFilter(
            app:name(), r.condition.windowFilter)
        valid = wFilter:isWindowAllowed(win)
      end
    end
    if valid then
      return r
    end
  end
  return nil
end
FLAGS["JUST_MODIFIED_MODIFIERS_FOR_MRD"] = false
RemoteDesktopModifierTapper = hs.eventtap.new({
  hs.eventtap.event.types.flagsChanged,
  hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.keyUp,
},
function(ev)
  local rule = remoteDesktopWindowFilter(hs.application.frontmostApplication())
  if rule ~= nil then
    if not FLAGS["JUST_MODIFIED_MODIFIERS_FOR_MRD"] then
      FLAGS["JUST_MODIFIED_MODIFIERS_FOR_MRD"] = true
      local evFlags =	ev:getFlags()
      local newEvFlags = {}
      for k, _ in pairs(evFlags) do
        if rule.map[k] == nil then
          newEvFlags[k] = true
        else
          newEvFlags[rule.map[k]] = true
        end
      end
      ev:setFlags(newEvFlags)
      ev:post()
      return true
    else
      FLAGS["JUST_MODIFIED_MODIFIERS_FOR_MRD"] = false
    end
  end
  return false
end)

if frontApp then
  local frontAppID = frontApp:bundleID() or frontApp:name()
  if remoteDesktopsMappingModifiers[frontAppID] then
    RemoteDesktopModifierTapper:start()
  end
end
for appid, _ in pairs(remoteDesktopsMappingModifiers) do
  Evt.OnActivated(appid, function()
    if not RemoteDesktopModifierTapper:isEnabled() then
      RemoteDesktopModifierTapper:start()
    end
  end)
end

local function suspendHotkeysInRemoteDesktop(app)
  local win = app:focusedWindow()
  if win ~= nil then
    if isDefaultRemoteDesktopWindow(win) then
      if FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] == nil then
        FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] = not FLAGS["SUSPEND"]
      end
      FLAGS["SUSPEND"] = true
      return
    end
  end
  if FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] ~= nil then
    FLAGS["SUSPEND"] = not FLAGS["SUSPEND_IN_REMOTE_DESKTOP"]
    FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] = nil
  end
end

local function watchForRemoteDesktopWindow(app)
  local appUI = toappui(app)
  local observer = uiobserver.new(app:pid())
  observer:addWatcher(appUI, uinotifications.focusedWindowChanged)
  observer:callback(bind(suspendHotkeysInRemoteDesktop, app))
  observer:start()
  Evt.StopOnDeactivated(app, observer)
  Evt.StopOnTerminated(app, observer)
end

for _, appid in ipairs(ApplicationConfigs["suspendHotkeysInRemoteDesktop"] or {}) do
  local frontAppID = frontApp and (frontApp:bundleID() or frontApp:name()) or nil
  if frontAppID == appid then
    watchForRemoteDesktopWindow(frontApp)
    suspendHotkeysInRemoteDesktop(frontApp)
  end
  Evt.OnActivated(appid, suspendHotkeysInRemoteDesktop)
  Evt.OnActivated(appid, watchForRemoteDesktopWindow)
end

-- ## hold cmd+w to close window for iOS apps because it will quit them
HoldToQuit = hs.loadSpoon("HoldToQuit")
HoldToQuit.duration = 0.2
HoldToQuit:init()
HoldToQuit:newHotkeys({ quit = { "⌘", "W" } })
local function mayRequireHoldToCloseWindow(app)
  local appid = app:bundleID()
  if appid == nil then return end
  local appPath = hs.application.pathForBundleID(appid)
  if exists(appPath .. '/WrappedBundle')
      or appPath:find("Steam/steamapps/common") then
    HoldToQuit:start()
  else
    HoldToQuit:stop()
  end
end
if frontApp then
  mayRequireHoldToCloseWindow(frontApp)
end


-- # callbacks

-- ## application callbacks

-- specify input source for apps
local function selectInputSourceInApp(app)
  local inputSource = get(ApplicationConfigs, "inputSource",
      app:bundleID() or app:name())
  if inputSource ~= nil then
    local currentSourceID = hs.keycodes.currentSourceID()
    if type(inputSource) == 'string' then
      if currentSourceID ~= inputSource then
        hs.keycodes.currentSourceID(inputSource)
      end
    else
      for _, source in ipairs(inputSource) do
        if currentSourceID == source then
          return
        end
        if hs.keycodes.currentSourceID(source) then
          break
        end
      end
    end
  end
end

-- some apps may launch slowly. Wait until complete launch to operate on menu bar items
local appsLaunchSlow = {
  ["com.google.Chrome"] = function(app)
    return findMenuItem(app, { "Help" }) ~= nil
  end,
  ["org.zotero.zotero"] = function(app)
    return #getMenuBarItems(app) > 0
  end,
  ["com.microsoft.VSCode"] = function(app)
    return #getMenuBarItems(app) > 1
  end,
  ["com.jetbrains.CLion"] = function(app)
    return #getMenuBarItems(app) > 10
  end,
  ["com.jetbrains.CLion-EAP"] = function(app)
    return #getMenuBarItems(app) > 10
  end,
  ["com.jetbrains.intellij"] = function(app)
    return #getMenuBarItems(app) > 10
  end,
  ["com.jetbrains.pycharm"] = function(app)
    return #getMenuBarItems(app) > 10
  end
}

local forbiddenApps = ApplicationConfigs["forbidden"] or {}
for _, appid in ipairs(forbiddenApps) do
  if isLSUIElement(appid) then
    ExecOnSilentLaunch(appid, function(app)
      app:kill9()
      hs.execute(strfmt("sudo rm -rf \"%s\"", app:path()))
    end)
  end
end

local launchTimer
function App_applicationCallback(appname, eventType, app)
  local appid = app:bundleID() or appname
  if eventType == hs.application.watcher.launching then
    if tcontain(forbiddenApps, appid) then
      app:kill9()
      hs.execute(strfmt("sudo rm -rf \"%s\"", app:path()))
      return
    end
    if FLAGS["APP_LAUNCHING"] then
      FLAGS["APP_LAUNCHING_OVERRIDE"] = true
    end
    FLAGS["APP_LAUNCHING"] = true
  elseif eventType == hs.application.watcher.launched then
    local doublecheck
    if FLAGS["APP_LAUNCHING"] and appsLaunchSlow[appid] then
      doublecheck = bind(appsLaunchSlow[appid], app)
    end
    if FLAGS["MENUBAR_ITEMS_PREPARED"] ~= nil then
      local oldFn = doublecheck
      doublecheck = function()
        return hs.application.frontmostApplication():bundleID() == app:bundleID()
            and (not oldFn or oldFn())
      end
    end
    local action = function()
      launchTimer = nil
      for _, proc in ipairs(Evt.ProcOnLaunched[appid] or {}) do
        proc(app)
      end
      FLAGS["NO_RESHOW_KEYBINDING"] = true
      onLaunchedAndActivated(app)
      if FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] ~= nil then
        registerMenuBarObserverForHotkeyValidity(app)
        local observer = MenuBarMenuSelectedObservers[appid]
        if observer then
          registerObserverForRightMenuBarSettingsMenuItem(app, observer)
        end
      end
      FLAGS["APP_LAUNCHING"] = nil
    end
    if doublecheck and not doublecheck() then
      launchTimer = hs.timer.waitUntil(doublecheck, action, 0.01)
    else
      action()
    end
    FLAGS["MENUBAR_ITEMS_PREPARED"] = nil
  elseif eventType == hs.application.watcher.activated then
    for bid, processes in pairs(Evt.ProcOnDeactivated) do
      local b = find(bid)
      for _, proc in ipairs(processes) do
        proc(b)
      end
      Evt.ProcOnDeactivated[bid] = nil
    end

    if launchTimer then
      launchTimer:stop() launchTimer = nil
      FLAGS["APP_LAUNCHING"] = FLAGS["APP_LAUNCHING_OVERRIDE"]
      FLAGS["APP_LAUNCHING_OVERRIDE"] = nil
    end

    appBuf = {}
    if FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] ~= nil then
      FLAGS["SUSPEND"] = not FLAGS["SUSPEND_IN_REMOTE_DESKTOP"]
      FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] = nil
    end
    for _, proc in ipairs(Evt.ProcOnActivated[appid] or {}) do
      proc(app)
    end
    mayRequireHoldToCloseWindow(app)
    selectInputSourceInApp(app)

    FLAGS["NO_RESHOW_KEYBINDING"] = true
    registerForOpenSavePanel(app)
    if not FLAGS["APP_LAUNCHING"] then
      FLAGS["MENUBAR_ITEMS_PREPARED"] = onLaunchedAndActivated(app)
    elseif FLAGS["APP_LAUNCHING"] and appsLaunchSlow[appid] == nil then
      FLAGS["MENUBAR_ITEMS_PREPARED"] = false
    end
  elseif eventType == hs.application.watcher.terminated then
    for _, proc in ipairs(Evt.ProcOnTerminated[appid] or {}) do
      proc()
    end
    Evt.ProcOnTerminated[appid] = nil
  elseif eventType == hs.application.watcher.deactivated and appname == nil then
    for id, processes in pairs(Evt.ProcOnTerminated) do
      if find(id) == nil then
        for _, proc in ipairs(processes) do
          proc()
        end
        Evt.ProcOnTerminated[id] = nil
      end
    end
  end
  if eventType == hs.application.watcher.deactivated then
    FLAGS["NO_RESHOW_KEYBINDING"] = false
    if HSKeybindings ~= nil and HSKeybindings.isShowing then
      local validOnly = HSKeybindings.validOnly
      local showCustom = HSKeybindings.showCustom
      local showApp = HSKeybindings.showApp
      HSKeybindings:reset()
      HSKeybindings:update(validOnly, showCustom, showApp, true)
    end
    local frontApp = hs.application.frontmostApplication()
    if frontApp then
      local frontAppID = frontApp:bundleID() or frontApp:name()
      if remoteDesktopsMappingModifiers[frontAppID] == nil then
        if RemoteDesktopModifierTapper:isEnabled() then
          RemoteDesktopModifierTapper:stop()
        end
      end
    end
  end
end

-- some apps may terminate silently, which is unexpected
AppsTerminateSilently = {}
for _, appid in ipairs(ApplicationConfigs["terminateSilently"] or {}) do
  Evt.OnRunning(appid, function()
    ExecOnSilentQuit(appid, function() end)
  end)
end

function App_applicationInstalledCallback(files, flagTables)
  files = tcopy(files) flagTables = tcopy(flagTables)
  for i=#files,1,-1 do
    if flagTables[i].itemCreated then
      local appid = hs.application.infoForBundlePath(files[i]).CFBundleIdentifier
      if tcontain(forbiddenApps, appid)
          or tcontain(forbiddenApps, files[i]:sub(1, -5)) then
        hs.execute(strfmt("rm -rf \"%s\"", files[i]))
        tremove(files, i) tremove(flagTables, i)
      end
    end
  end
  for i, file in ipairs(files) do
    local appid = hs.application.infoForBundlePath(file).CFBundleIdentifier
    if flagTables[i].itemRemoved then
      for _, appkey in ipairs(appkeys) do
        if appkey.appid == appid or appkey.appPath == file then
          registerAppKeys()
          return
        end
      end
    elseif flagTables[i].itemCreated then
      registerAppKeys()
      if appid then
        registerRunningAppHotKeys(appid)
      end
      return
    end
  end
end

-- ## monitor callbacks

-- launch applications automatically when connected to an external monitor
function App_monitorChangedCallback()
  local screens = hs.screen.allScreens()

  -- only for built-in monitor
  local builtinMonitorEnable = any(screens, function(screen)
    return screen:name() == "Built-in Retina Display"
  end)
  if builtinMonitorEnable then
    -- hs.application.launchOrFocusByBundleID("pl.maketheweb.TopNotch")
  else
    quit("pl.maketheweb.TopNotch")
  end

  -- for external monitors
  if (builtinMonitorEnable and #screens > 1)
    or (not builtinMonitorEnable and #screens > 0) then
    if find("me.guillaumeb.MonitorControl") == nil then
      hs.execute([[open -g -b "me.guillaumeb.MonitorControl"]])
    end
  elseif builtinMonitorEnable and #screens == 1 then
    quit("me.guillaumeb.MonitorControl")
  end
end

-- ## usb callbacks

-- launch `MacDroid` automatically when connected to android phone
local phones = ApplicationConfigs.androidDevices or {}
local phonesManagers = ApplicationConfigs.manageAndroidDevices or {}
if type(phonesManagers) == 'string' then phonesManagers = { phonesManagers } end
local attached_android_count = 0

function App_usbChangedCallback(device)
  if device.eventType == "added" then
    attached_android_count = attached_android_count + 1
    for _, phone in ipairs(phones) do
      if device.productName == phone[1] and device.vendorName == phone[2] then
        for _, appid in ipairs(phonesManagers) do
          if installed(appid) then
            hs.execute(strfmt("open -g -b '%s'", appid))
            return
          end
        end
      end
    end
  elseif device.eventType == "removed" then
    attached_android_count = attached_android_count - 1
    if attached_android_count == 0 then
      for _, appid in ipairs(phonesManagers) do
        quit(appid)
        if appid == "us.electronic.macdroid" then
          quit('MacDroid Extension')
        end
      end
    end
  end
end

runningAppsOnLoading = {}
