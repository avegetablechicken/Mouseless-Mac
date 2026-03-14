-- if app locale changes, it may change its menu bar items, so need to rebind
local appLastLocales = {}
local function updateAppLocale(app)
  local appid = app:bundleID() or app:name()
  local oldAppLocale = appLastLocales[appid]
  appLastLocales[appid] = A_AppLocale
  if oldAppLocale ~= A_AppLocale then
    if matchLocale(oldAppLocale or SYSTEM_LOCALE, { A_AppLocale })
        ~= A_AppLocale then
      resetLocalizationMap(appid)
      localizeCommonMenuItemTitles(A_AppLocale, appid)
      unregisterRunningAppHotKeys(appid, true)
      return true
    end
  end
  return false
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

local function getMenuBarItemTitlesString(app, menuBarItems)
  if menuBarItems == false then
    return ""
  elseif menuBarItems == nil then
    menuBarItems = getMenuBarItems(app)
    A_AppBuf.menuBarItems = menuBarItems
  end
  local appMenuBarStr = getMenuBarItemTitlesStringImpl(menuBarItems or {})
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

local function continouslyWatchMenuBarItems(app)
  local appid = app:bundleID() or app:name()
  menuBarItemTitlesString.app[appid], menuBarItemTitlesString.win[appid]
      = getMenuBarItemTitlesString(app, getBufferedMenuBarItems(app) or false)
  local watcher = ExecContinuouslyQuick(function()
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
    if not app:isFrontmost() then return end
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

local function watchMenuBarItemsByNotification(app, notification)
  local appid = app:bundleID() or app:name()
  menuBarItemTitlesString.app[appid], menuBarItemTitlesString.win[appid]
      = getMenuBarItemTitlesString(app)

  local observer
  observer = uiobserver.new(app:pid())
  local appUI = toappui(app)
  observer:addWatcher(appUI, notification)
  observer:callback(bind(appMenuBarChangeCallback, app))
  observer:start()
  Evt.StopOnDeactivated(app, observer)
end

-- Register observers to detect menu bar changes.
--
-- Some apps change menu bars:
--   - dynamically
--   - per focused window
--   - asynchronously after launch

local appsMayChangeMenuBar = {
  changing = tcopy(get(ApplicationConfigs,
      "menuBarItems", 'changing') or {}),
  focusedWindowChanged = tcopy(get(ApplicationConfigs,
      "menuBarItems", 'focusedWindowChanged') or {}),
  titleChanged = tcopy(get(ApplicationConfigs,
      "menuBarItems", 'titleChanged') or {})
}

local appsMayChangeMenuBarTmpFile =
    appsTmpDir .. '/variable_menubar.json'
if exists(appsMayChangeMenuBarTmpFile) then
  local tmp = hs.json.read(appsMayChangeMenuBarTmpFile)
  for _, appid in ipairs(tmp['changing'] or {}) do
    tinsert(appsMayChangeMenuBar.changing, appid)
  end
  for _, appid in ipairs(tmp['focusedWindowChanged'] or {}) do
    tinsert(appsMayChangeMenuBar.focusedWindowChanged, appid)
  end
  for _, appid in ipairs(tmp['titleChanged'] or {}) do
    tinsert(appsMayChangeMenuBar.titleChanged, appid)
  end
end

local function registerObserverForMenuBarChange(app)
  local appid = app:bundleID() or app:name()
  if tcontain(appsMayChangeMenuBar.changing, appid) then
    continouslyWatchMenuBarItems(app)
  elseif tcontain(appsMayChangeMenuBar.focusedWindowChanged, appid) then
    watchMenuBarItemsByNotification(app, uinotifications.focusedWindowChanged)
  elseif tcontain(appsMayChangeMenuBar.titleChanged, appid) then
    watchMenuBarItemsByNotification(app, uinotifications.titleChanged)
  end
end

local frontApp = hs.application.frontmostApplication()
if frontApp then
  updateAppLocale(frontApp)
  registerObserverForMenuBarChange(frontApp)
end

---@diagnostic disable-next-line: lowercase-global
function processInvalidAltMenu(app, reinvokeKey, windowOnBindAltMenu)
  local appid = app:bundleID() or app:name()
  local curWin = app:focusedWindow()
  local isSameWin, hasSameTitle = false, false
  if curWin and windowOnBindAltMenu then
    isSameWin = curWin:id() == windowOnBindAltMenu.id
    if isSameWin then
      hasSameTitle = curWin:title() == windowOnBindAltMenu.title
    end
  end
  if isSameWin then
    local _, frameworks = getResourceDir(appid)
    if tfind(frameworks, function(f) return f.electron ~= nil end) then
      updateAppLocale(app)
      onLaunchedAndActivated(app, reinvokeKey)
      registerObserverForMenuBarChange(app)
      return
    end
  end
  local type
  if isSameWin then
    if hasSameTitle then
      type = 'changing'
      local pos = tindex(appsMayChangeMenuBar.titleChanged, appid)
      if pos then tremove(appsMayChangeMenuBar.titleChanged, pos) end
    else
      type = 'titleChanged'
    end
    local pos = tindex(appsMayChangeMenuBar.focusedWindowChanged, appid)
    if pos then tremove(appsMayChangeMenuBar.focusedWindowChanged, pos) end
  else
    type = 'focusedWindowChanged'
  end
  tinsert(appsMayChangeMenuBar[type], appid)
  updateAppLocale(app)
  onLaunchedAndActivated(app, reinvokeKey)
  registerObserverForMenuBarChange(app)

  if not exists(appsTmpDir) then
    hs.execute(strfmt("mkdir -p '%s'", appsTmpDir))
  end
  local json = {}
  if exists(appsMayChangeMenuBarTmpFile) then
    json = hs.json.read(appsMayChangeMenuBarTmpFile)
  else
    json = {}
  end
  if json[type] == nil then json[type] = {} end
  tinsert(json[type], appid)
  if isSameWin then
    local pos = tindex(json["focusedWindowChanged"] or {}, appid)
    if pos then tremove(json["focusedWindowChanged"], pos) end
    if hasSameTitle then
      pos = tindex(appsMayChangeMenuBar["titleChanged"] or {}, appid)
      if pos then tremove(appsMayChangeMenuBar["titleChanged"], pos) end
    end
  end
  hs.json.write(json, appsMayChangeMenuBarTmpFile, false, true)
end

-- some apps may launch slowly. Wait until complete launch to operate on menu bar items

local function getNumberOfMenuBarItems(app)
  local menuBarItems = getMenuBarItems(app)
  return menuBarItems and #menuBarItems or 0
end

local appsLaunchSlow = {
  ["com.google.Chrome"] = function(app)
    return findMenuItem(app, { "Help" }) ~= nil
  end,
  ["org.zotero.zotero"] = function(app)
    return getNumberOfMenuBarItems(app) > 0
  end,
  ["com.microsoft.VSCode"] = function(app)
    return getNumberOfMenuBarItems(app) > 1
  end,
  ["com.jetbrains.CLion"] = function(app)
    return getNumberOfMenuBarItems(app) > 2
  end,
  ["com.jetbrains.CLion-EAP"] = function(app)
    return getNumberOfMenuBarItems(app) > 2
  end,
  ["com.jetbrains.intellij"] = function(app)
    return getNumberOfMenuBarItems(app) > 2
  end,
  ["com.jetbrains.pycharm"] = function(app)
    return getNumberOfMenuBarItems(app) > 2
  end,
  ["com.apple.games"] = function(app)
    local win = app:focusedWindow()
    if win == nil then return false end
    local buttons = getc(towinui(win), AX.Toolbar, 1,
        AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
    return buttons and #buttons > 0
  end,
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

-- # callbacks

-- ## application callbacks

local launchTimer
function App_applicationCallback(appname, eventType, app)
  local appid = app:bundleID() or appname
  if appid == "com.apple.dock" then return end
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
    if FLAGS["NEED_DOUBLE_CHECK"] then
      local oldFn = doublecheck
      doublecheck = function()
        return app:isFrontmost() and (not oldFn or oldFn())
      end
    end
    local action = function()
      launchTimer = nil
      A_AppLocale = applicationLocale(appid)
      for _, proc in ipairs(Evt.ProcOnLaunched[appid] or {}) do
        proc(app)
      end
      FLAGS["NO_RESHOW_KEYBINDING"] = true
      local localeUpdated = updateAppLocale(app)
      onLaunchedAndActivated(app, localeUpdated)
      registerObserverForMenuBarChange(app)

      if FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] ~= nil then
        hs.timer.doAfter(1, function()
          registerMenuBarObserverForHotkeyValidity(app)
          local observer = MenuBarMenuSelectedObservers[appid]
          if observer then
            registerObserverForRightMenuBarSettingsMenuItem(app, observer)
          end
        end)
      end
      FLAGS["APP_LAUNCHING"] = nil
    end
    if doublecheck and not doublecheck() then
      launchTimer = hs.timer.waitUntil(doublecheck, action, 0.01)
    else
      action()
    end
    FLAGS["NEED_DOUBLE_CHECK"] = nil
  elseif eventType == hs.application.watcher.activated then
    for bid, processes in pairs(Evt.ProcOnDeactivated) do
      if bid ~= appid then
        local b = find(bid)
        for _, proc in ipairs(processes) do
          proc(b)
        end
        Evt.ProcOnDeactivated[bid] = nil
      end
    end

    if launchTimer then
      launchTimer:stop() launchTimer = nil
      FLAGS["APP_LAUNCHING"] = FLAGS["APP_LAUNCHING_OVERRIDE"]
      FLAGS["APP_LAUNCHING_OVERRIDE"] = nil
    end

    A_AppBuf = {}
    A_AppLocale = applicationLocale(appid)
    if FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] ~= nil then
      FLAGS["SUSPEND"] = not FLAGS["SUSPEND_IN_REMOTE_DESKTOP"]
      FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] = nil
    end
    for _, proc in ipairs(Evt.ProcOnActivated[appid] or {}) do
      proc(app)
    end
    mayRequireHoldToCloseWindow(app)
    selectInputSourceInApp(app)
    reactivateValidSettingsToolbarHotkeys()

    FLAGS["NO_RESHOW_KEYBINDING"] = true
    registerForOpenSavePanel(app)
    FLAGS["NEED_DOUBLE_CHECK"] = FLAGS["APP_LAUNCHING"]
    if not FLAGS["APP_LAUNCHING"] then
      local localeUpdated = updateAppLocale(app)
      onLaunchedAndActivated(app, localeUpdated)
      registerObserverForMenuBarChange(app)
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
      if RemoteDesktopsMappingModifiers[frontAppID] == nil then
        if RemoteDesktopModifierTapper:isEnabled() then
          RemoteDesktopModifierTapper:stop()
        end
      end
    end
  end
end

-- some apps may terminate silently, which is unexpected
AppsTerminateSilently = ApplicationConfigs["terminateSilently"] or {}
for _, appid in ipairs(AppsTerminateSilently) do
  Evt.OnRunning(appid, bind(ExecOnSilentQuit, appid, nil))
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
      for _, appkey in ipairs(AppKeys) do
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

_G.App_applicationCallback = App_applicationCallback
_G.App_applicationInstalledCallback = App_applicationInstalledCallback
