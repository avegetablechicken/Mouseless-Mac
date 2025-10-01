require "utils"

hs.application.enableSpotlightForNameSearches(true)

local runningAppsOnLoading = {}
foreach(hs.application.runningApplications(), function(app)
  runningAppsOnLoading[app:bundleID() or app:name()] = app
end)


-- # appkeys

-- launch or hide applications
local function focusOrHide(hint)
  local app = nil

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

local appkeys = {}

local function registerAppKeys()
  for _, hotkey in ipairs(appkeys) do
    hotkey:delete()
  end
  appkeys = {}
  HyperModal.hyperMode.keys = tfilter(HyperModal.hyperMode.keys,
      function(hotkey) return hotkey.idx ~= nil end)

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

registerAppKeys()


-- ## function utilities for process management on app switching
local function isLSUIElement(appid)
  local info = hs.application.infoForBundleID(appid)
  return info and info.LSUIElement == true
end

local processesOnLaunched = {}
local function onLaunched(appid, action)
  if isLSUIElement(appid) then
    ExecOnSilentLaunch(appid, action)
    return
  end

  if processesOnLaunched[appid] == nil then
    processesOnLaunched[appid] = {}
  end
  tinsert(processesOnLaunched[appid], action)
end

local function onRunning(appid, action)
  onLaunched(appid, action)
  local app
  if FLAGS["LOADING"] then
    app = runningAppsOnLoading[appid]
  else
    find(appid)
  end
  if app then action(app) end
end

local processesOnActivated = {}
local function onActivated(appid, action)
  if processesOnActivated[appid] == nil then
    processesOnActivated[appid] = {}
  end
  tinsert(processesOnActivated[appid], action)
end

local processesOnDeactivated = {}
local function onDeactivated(appid, action)
  if processesOnDeactivated[appid] == nil then
    processesOnDeactivated[appid] = {}
  end
  tinsert(processesOnDeactivated[appid], action)
end

local processesOnTerminated = {}
local function onTerminated(appid, action)
  if isLSUIElement(appid) then
    ExecOnSilentQuit(appid, action)
    return
  end

  if processesOnTerminated[appid] == nil then
    processesOnTerminated[appid] = {}
  end
  tinsert(processesOnTerminated[appid], action)
end

local function stopOnDeactivated(appid, observer, action)
  onDeactivated(appid, function()
    observer:stop()
    if action then action(observer, appid) end
    observer = nil
  end)
end

local function stopOnTerminated(appid, observer, action)
  onTerminated(appid, function()
    observer:stop()
    if action then action(observer, appid) end
    observer = nil
  end)
end

-- get hs.application from AXUIElement
local function getAppFromDescendantElement(elem)
  local appUI = elem
  repeat
    appUI = appUI.AXParent
  until appUI.AXParent == nil
  return appUI:asHSApplication()
end

local function onDestroy(element, callback, stopWhen, callbackOnStop)
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
    local appid = app:bundleID() or app:name()
    if ev == hs.application.watcher.deactivated then
      stopOnDeactivated(appid, closeObserver, callbackOnStop and callback)
    elseif ev == hs.application.watcher.terminated then
      stopOnTerminated(appid, closeObserver, callbackOnStop and callback)
    end
  end

  return closeObserver
end

local function versionCompare(versionStr, comp)
  return function(app)
    local appMajor, appMinor, appPatch = applicationVersion(app:bundleID())
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
end

local function versionLessThan(version)
  return versionCompare(version, "<")
end

local function versionGreaterThan(version)
  return versionCompare(version, ">")
end

local function versionGreaterEqual(version)
  return versionCompare(version, ">=")
end

local function versionLessEqual(version)
  return versionCompare(version, "<=")
end

local function versionRange(version1, version2)
  return function(app)
    return versionGreaterEqual(version1)(app) and versionLessThan(version2)(app)
  end
end

local function press(pressable)
  local flags = hs.eventtap.checkKeyboardModifiers()
  if not flags['ctrl'] then
    pressable:performAction(AX.Press)
  else
    flags['ctrl'] = nil
    local tapper
    tapper = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged },
      function(event)
        tapper:stop()
        hs.timer.doAfter(0.01, function()
          local newFlags = hs.eventtap.checkKeyboardModifiers()
          if newFlags['ctrl'] then
            newFlags['ctrl'] = nil
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

local function click(position)
  leftClickAndRestore(position)
end

local function clickable(element, offset)
  if element == nil then return false end
  if offset == nil then
    offset = { element.AXSize.w / 2, element.AXSize.h / 2 }
  end
  local point = hs.geometry.point {
    element.AXPosition.x + offset[1],
    element.AXPosition.y + offset[2],
  }
  local appHere = hs.axuielement.systemElementAtPosition(point)
  while appHere ~= nil and appHere.AXParent ~= nil do
    appHere = appHere.AXParent
  end
  if appHere then
    local appid = appHere:asHSApplication():bundleID()
    local targetApp = getAppFromDescendantElement(element)
    if appid ~= targetApp:bundleID() then return false end
  end
  return true, point
end


-- # hotkeys in specific application
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

-- ## function utilities for hotkey configs of specific application
local appBuf, winBuf = {}, {}
function winBuf:register(winUI, key, value)
  onDestroy(winUI, function() winBuf[key] = nil end)
  winBuf[key] = value
  return winBuf[key]
end

-- ### Finder
local function getFinderSidebarItemTitle(idx)
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
            stopOnDeactivated(appid, appBuf.finderSidebarItemObserver)
          end
          return header .. ' > ' .. itemTitle
        end
      end
    end
  end
end

local function getFinderSidebarItem(idx)
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

local function openFinderSidebarItem(cell, win)
  local app = win:application()
  local go = localizedString("Go", app)
  local itemTitle = getc(cell, AX.StaticText, 1).AXValue
  if app:findMenuItem({ go, itemTitle }) ~= nil then
    app:selectMenuItem({ go, itemTitle })
  else
    local flags = hs.eventtap.checkKeyboardModifiers()
    if not (flags['cmd'] or flags['alt'] or flags['ctrl']) then
      cell:performAction(AX.Open)
    else
      local tapper
      tapper = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged },
      function(event)
        tapper:stop()
        hs.timer.doAfter(0.01, function()
          local newFlags = hs.eventtap.checkKeyboardModifiers()
          if newFlags['cmd'] or newFlags['alt'] or newFlags['ctrl'] then
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
local function deleteSelectedMessage(app)
  if app:focusedWindow() == nil then return end
  local winUI = towinui(app:focusedWindow())
  local button
  if OS_VERSION >= OS.Tahoe then
    button = getc(winUI, AX.Group, 1, AX.Group, 1,
        AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Button, 2)
  else
    button = getc(winUI, AX.Group, 1, AX.Group, 1,
        AX.Group, 2, AX.Group, 1, AX.Button, 2)
  end
  if button ~= nil then
    press(button)
    hs.timer.doAfter(0.2, function()
      if not app:isRunning() then return end
      if app:focusedWindow():role() == AX.Sheet then
        local sheet = towinui(app:focusedWindow())
        local delete = getc(sheet, AX.Button, 2)
        press(delete)
      end
    end)
    return
  end

  local _, menuItem = findMenuItem(app, {
    OS_VERSION < OS.Ventura and "File" or "Conversation",
    "Delete Conversation…"
  })
  app:selectMenuItem(menuItem)
  hs.timer.doAfter(0.1, function()
    if not app:isRunning() then return end
    hs.eventtap.keyStroke("", "Return", nil, app)
  end)
end

local function messageDeletable(app)
  local appUI = toappui(app)
  local messageItems
  if OS_VERSION >= OS.Tahoe then
    messageItems = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
        AX.StaticText)
  else
    messageItems = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.StaticText)
  end
  if messageItems == nil or #messageItems == 0 then
    return false
  end
  local desc = localizedString('New Message', app)
  if messageItems[1].AXDescription == nil
      or messageItems[1].AXDescription:sub(4) == desc then
    tremove(messageItems, 1)
  end
  return #messageItems > 0, messageItems
end

local function deleteAllMessages(messageItems, app)
  local cnt = #messageItems
  local firstMsg, lastMsg = messageItems[1], messageItems[cnt]
  local frame = app:focusedWindow():frame()
  while frame.y + frame.h < lastMsg.AXPosition.y + lastMsg.AXSize.h do
    cnt = cnt - 1
    lastMsg = messageItems[cnt]
  end

  local firstSelected = firstMsg.AXSelected
  if not firstSelected then
    hs.timer.doAfter(0.1, bind(press, firstMsg))
  end
  if #messageItems == 1
      or (#messageItems == 2 and lastMsg.AXSelected) then
    if firstSelected then
      deleteSelectedMessage(app)
    else
      hs.timer.doAfter(0.3, bind(deleteSelectedMessage, app))
    end
    return
  end

  hs.timer.doAfter(0.5, function()
    for i=2,#messageItems do
      messageItems[i].AXSelected = false
    end
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, true):post()
    hs.timer.doAfter(1, function()
      press(lastMsg)
      hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, false):post()
      deleteSelectedMessage(app)

      hs.timer.doAfter(2, function()
        if not app:isFrontmost() then return end
        local continue
        continue, messageItems = messageDeletable(app)
        if continue then
          deleteAllMessages(messageItems, app)
        end
      end)
    end)
  end)
end

-- ### FaceTime
local FaceTimeMainWindowFilter = {}
onRunning("com.apple.FaceTime", function(app)
  FaceTimeMainWindowFilter.allowTitles = '^' .. app:name() .. '$'
end)

local function deleteMousePositionCall(win)
  local app = win:application()
  local winUI = towinui(win)

  local section
  if OS_VERSION >= OS.Tahoe then
    local collection = getc(winUI, AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 1)
    section = getc(collection, AX.Group, 1, AX.Button, 1)
  else
    local collection = getc(winUI, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 2)
    if collection ~= nil and collection.AXDescription ==
        localizedString("Recent Calls", app) then
      section = getc(collection, AX.Button, 1)
    end
  end
  if section ~= nil then
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
    local locTitle = localizedString("Remove from Recents", app)
    local menuItem = getc(popup, AX.MenuItem, locTitle)
    if menuItem ~= nil then
      press(menuItem)
    end
  end
  return
  winUI:elementSearch(
    function(msg, results, count)
      if count == 0 then return end

      local section = getc(results[1][1], AX.Group, 1)
      if section == nil then return end

      if not rightClick(hs.mouse.absolutePosition(), app) then
        return
      end
      local popups = getc(section, AX.Menu)
      local maxTime, time = 0.5, 0
      while #popups == 0 and time < maxTime do
        hs.timer.usleep(0.01 * 1000000)
        time = time + 0.01
        popups = get(section, AX.Menu)
      end
      for _, popup in ipairs(popups) do
        local menuItem = getc(popup, AX.MenuItem, "menuRemovePersonFromRecents:")
        if menuItem then
          press(menuItem)
        end
      end
    end,
    function(element)
      return element.AXSubrole == AX.CollectionList
          and #element > 0
          and element[1].AXSubrole == AX.SectionList
    end,
    { count = 1 }
  )
end

local function deleteAllCalls(win)
  local app = win:application()
  local winUI = towinui(win)
  local section
  if OS_VERSION >= OS.Tahoe then
    local collection = getc(winUI, AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 1)
    section = getc(collection, AX.Group, 1, AX.Button, 1)
  else
    local collection = getc(winUI, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 2)
    if collection ~= nil and collection.AXDescription ==
        localizedString("Recent Calls", app) then
      section = getc(collection, AX.Button, 1)
    end
  end
  if section ~= nil then
    if not rightClick(section, app) then
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
    local locTitle = localizedString("Remove from Recents", app)
    local menuItem = getc(popup, AX.MenuItem, locTitle)
    if menuItem ~= nil then
      press(menuItem)
    end
    hs.timer.usleep(0.1 * 1000000)
    deleteAllCalls(win)
  end
  return
  winUI:elementSearch(
    function(msg, results, count)
      if count == 0 then return end

      local section = getc(results[1][1], AX.Group, 1)
      if section == nil then return end

      if not rightClickAndRestore(section, app) then
        return
      end
      local popups = getc(section, AX.Menu)
      local maxTime, time = 0.5, 0
      while #popups == 0 and time < maxTime do
        hs.timer.usleep(0.01 * 1000000)
        time = time + 0.01
        popups = getc(section, AX.Menu)
      end
      for _, popup in ipairs(popups) do
        local menuItem  = getc(popup, AX.MenuItem, "menuRemovePersonFromRecents:")
        if menuItem then
          press(menuItem)
          hs.timer.usleep(0.1 * 1000000)
        end
      end
      deleteAllCalls(winUI)
    end,
    function(element)
      return element.AXSubrole == AX.CollectionList
          and #element > 0
          and element[1].AXSubrole == AX.SectionList
    end,
    { count = 1 }
  )
end

-- ### Games
local GamesMainWindowFilter = {
  fn = function(win)
    local buttons = getc(towinui(win), AX.Toolbar, 1,
        AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
    local button = tfind(buttons or {}, function(bt)
      return bt.AXDescription == win:title()
    end)
    return button ~= nil
  end
}

-- ### Visual Studio Code
local function VSCodeToggleSideBarSection(winUI, sidebar, section)
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
        press(button)
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
    press(tab)

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
    local hasToClick = false
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
      hasToClick = true
    end
    for _, sec in ipairs(sections) do
      local button = getc(sec, AX.Button, 1)
          or getc(sec, AX.Group, 1, AX.Button, 1)
      if button[2].AXTitle == section then
        local records = getc(sec, AX.Group, 1, AX.Outline, 1, AX.Group, 1)
            or getc(sec, AX.Group, 1)
        if records == nil or #records == 1 then
          if hasToClick then
            leftClickAndRestore(button)
          else
            press(button)
          end
          break
        end
      end
    end
  end
end

-- ### JabRef
local function JabRefShowLibraryByIndex(idx, testClickable)
  return function(app)
    if app:focusedWindow() == nil then return false end
    local winUI = towinui(app:focusedWindow())
    local tab = getc(winUI, AX.TabGroup, 1, AX.RadioButton, idx)
    if tab ~= nil then
      if testClickable or testClickable == nil then
        return clickable(tab, { 10, 10 })
      else
        return true
      end
    else
      return false
    end
  end
end

-- ### App Cleaner & Uninstaller
local function buttonValidForAppCleanerUninstaller(title)
  return function(app)
    local winUI = towinui(app:focusedWindow())
    local sg = getc(winUI, AX.SplitGroup, 1)
    if sg == nil then return false end
    local locTitle = localizedString(title, app)
    local button = tfind(getc(sg, AX.Button), function(bt)
      return bt.AXIdentifier == "uaid:RemoveSelectedItemsButton"
          and bt.AXTitle == locTitle and bt.AXEnabled
    end)
    return button ~= nil, button
  end
end

local function confirmButtonValidForAppCleanerUninstaller(title)
  return function(app)
    local winUI = towinui(app:focusedWindow())
    local cancel = tfind(getc(winUI, AX.Button), function(bt)
      return bt.AXIdentifier == "uaid:RemoveDialogSecondButton" and bt.AXEnabled
    end)
    if cancel == nil then return false end
    local locTitle = localizedString(title, app)
    local button = getc(winUI, AX.StaticText, locTitle)
    return clickable(button)
  end
end

--- ### QQLive
local QQLiveMainWindowFilter = {
  fn = function(win)
    local winUI = towinui(win)
    return getc(winUI, AX.Group, 2, nil, "频道") ~= nil
        and getc(winUI, AX.Group, 2, nil, "全部频道") ~= nil
  end
}
local function getQQLiveChannelName(index)
  return function(win)
    local QQLiveChannelNames = appBuf.QQLiveChannelNames or {}
    if #QQLiveChannelNames == 0 then
      local list = getc(towinui(win), AX.Group, 2)
      if list == nil or #list == 0 then return end
      local start
      for i, txt in ipairs(list) do
        if txt.AXValue == "频道" then
          start = i
          break
        end
      end
      if start == nil then return end
      for i = 1, 10 do
        if #list - 2 >= start + i then
          local row = list[start + i]
          tinsert(QQLiveChannelNames, row.AXValue)
        end
      end
      appBuf.QQLiveChannelNames = QQLiveChannelNames
    end
    return QQLiveChannelNames[index]
  end
end

local function getQQLiveChannel(index)
  return function(win)
    local list = getc(towinui(win), AX.Group, 2)
    if list == nil or #list == 0 then return false end
    local start
    for i, txt in ipairs(list) do
      if txt.AXValue == "频道" then
        start = i
        break
      end
    end
    if start == nil then return false end
    if #list - 2 >= start + index then
      local row = list[start + index]
      if row.AXPosition.y > list.AXPosition.y
          and row.AXPosition.y + row.AXSize.h < list[#list].AXPosition.y - 15 then
        return clickable(row)
      elseif row.AXPosition.y <= list.AXPosition.y
          and row.AXPosition.y + row.AXSize.h > list.AXPosition.y then
        return clickable(row, { row.AXSize.w / 2, row.AXSize.h })
      elseif row.AXPosition.y + row.AXSize.h >= list[#list].AXPosition.y - 15
          and row.AXPosition.y < list[#list].AXPosition.y - 15 then
        return clickable(row, { row.AXSize.w / 2, 0 })
      end
    end
    return false
  end
end

--- ### Yuanbao
local YuanbaoMainWindowFilter = {}
onRunning("com.tencent.yuanbao", function(app)
  local title = localizedString("Tencent Yuanbao", app)
  YuanbaoMainWindowFilter.allowTitles = '^' .. title .. '$'
end)

--- ### EuDic
local EuDicMainWindowFilter = { allowRoles = AX.StandardWindow }
onRunning("com.eusoft.freeeudic", function(app)
  local functionName = "词 典"
  functionName = localizedString(functionName, app) or functionName
  EuDicMainWindowFilter.fn = function(win)
    local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 1)
    return button and button.AXTitle == functionName
  end
end)

--- ### Parallels Desktop
local ParallelsControlCenterWindowFilter = {}
onRunning("com.parallels.desktop.console", function(app)
  local title = localizedString("Control Center", app)
  ParallelsControlCenterWindowFilter.allowTitles = '^' .. title .. '$'
end)

--- ### Barrier
local function barrierLocalizedMessage(message, params)
  return function(app)
    local str = localizedString(message, app, params) or message
    str = type(str) == 'string' and str or str[1]
    if message:find('&') then
      str = str:gsub("%(&%a%)", ""):gsub('&', '')
    end
    if message:sub(#message) == ':' then
      local len = utf8.len(str)
      local lastChar = str:sub(utf8.offset(str, len))
      if lastChar == ':' or lastChar == '：' then
        str = str:sub(1, utf8.offset(str, len) - 1)
      end
    end
    return str
  end
end

local function barrierLocalizedString(message, appid, params)
  local str = localizedString(message, appid, params) or message
  str = type(str) == 'string' and str or str[1]
  if message:find('&') then
    str = str:gsub('&', "")
  end
  return str
end

-- ### Bartender
local bartenderBarWindowFilter = { allowTitles = "^Bartender Bar$" }
local function getBartenderBarItemTitle(index, rightClick)
  return function(win)
    if winBuf.bartenderBarItemNames == nil then
      local winUI = towinui(win)
      local icons = getc(winUI, AX.ScrollArea, 1, AX.List, 1, AX.List, 1)
      local appnames = tmap(getc(icons, AX.Group), function(g)
        return getc(g, AX.Image, 1).AXDescription
      end)
      if #appnames > 0 then
        local app = win:application()
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
        if missedItemCnt == 0 then
          for i = 1, #appnames do
            local appname = appnames[i]
            local itemID = itemList[splitterIndex + 1 + #appnames - i]
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
      end
    end
    if winBuf.bartenderBarItemNames ~= nil and index <= #winBuf.bartenderBarItemNames then
      return (rightClick and "Right-click " or "Click ")
          .. winBuf.bartenderBarItemNames[index]
    end
  end
end

local function clickBartenderBarItem(index, rightClick)
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

local function getBartenderSidebarItemTitle(index)
  return function(win)
    local winUI = towinui(win)
    local row = getc(winUI, AX.SplitGroup, 1, AX.ScrollArea, 1,
        AX.Outline, 1, AX.Row, index, AX.Cell, 1, AX.StaticText, 1)
    if row ~= nil then
      return row.AXValue
    end
  end
end

local function clickBartenderSidebarItem(index)
  return function(win)
    local winUI = towinui(win)
    local row = getc(winUI, AX.SplitGroup, 1, AX.ScrollArea, 1,
        AX.Outline, 1, AX.Row, index)
    if row then row.AXSelected = true end
  end
end

-- ### Barbee
local barbeeBarWindowFilter = {
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
local function getBarbeeBarItemTitle(index)
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

local function clickBarbeeBarItem(index)
  return function(win)
    local button = getc(towinui(win), AX.Group, 1, AX.Button, -index)
    if button then press(button) end
  end
end

-- ### Ice
local iceBarWindowFilter = { allowTitles = "^Ice Bar$" }
local function getIceBarItemTitle(index)
  return function(win)
    local button = getc(towinui(win), AX.Group, 1,
        AX.ScrollArea, 1, AX.Image, index)
    if button then
      return button.AXAttributedDescription:getString()
    end
  end
end

local function clickIceBarItem(index)
  return function(win)
    local button = getc(towinui(win), AX.Group, 1,
        AX.ScrollArea, 1, AX.Image, index)
    if button then
      leftClickAndRestore(button, win, 0.1)
    end
  end
end

local iceSettingsWindowFilter = {
  fn = function(win)
    return towinui(win).AXIdentifier == "SettingsWindow"
  end
}
local function getIceSidebarItemTitle(index)
  return function(win)
    local row = getc(towinui(win), AX.Group, 1,
        AX.SplitGroup, 1, AX.Group, 1, AX.ScrollArea, 1,
        AX.Outline, 1, AX.Row, index + 1, AX.Cell, 1, AX.StaticText, 1)
    if row ~= nil then
      return row.AXValue
    end
  end
end

local function clickIceSidebarItem(index)
  return function(win)
    local row = getc(towinui(win), AX.Group, 1,
        AX.SplitGroup, 1, AX.Group, 1, AX.ScrollArea, 1,
        AX.Outline, 1, AX.Row, index + 1)
    if row then row.AXSelected = true end
  end
end

-- ### iBar
local iBarWindowFilter = {
  allowRoles = AX.SystemFloatingWindow,
  allowTitles = "^iBarmenu$"
}
local function getiBarItemTitle(index)
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

local function clickiBarItem(index)
  return function(win)
    local button = getc(towinui(win), AX.Button, index)
    if button then
      press(button)
    end
  end
end

-- ### PasswordsMenuBarExtra
local function getPasswordRecordPosition(index)
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
      return clickable(row)
    end
    return false
  end
end

-- ### iCopy
local function iCopySelectHotkeyMod(app)
  return versionLessThan("1.1.1")(app) and "" or "⌃"
end
local iCopyMod

local function iCopySelectHotkeyRemap(idx)
  return function(win)
    if iCopyMod == nil then
      iCopyMod = iCopySelectHotkeyMod(win:application())
    end
    hs.eventtap.keyStroke(iCopyMod, tostring(idx), nil, win:application())
  end
end

local iCopyWindowFilter = {
  allowRegions = {
    hs.geometry.rect(
        0, hs.screen.mainScreen():fullFrame().y
           + hs.screen.mainScreen():fullFrame().h - 400,
        hs.screen.mainScreen():fullFrame().w, 400)
  }
}

-- ### browsers
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
  if ok then return url end
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

local function weiboSideBarTitle(idx, isCommon)
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
      local header = [[<h2 class="Nav_title_[^>]-">首页</h2>]]
      local tailer = [[<div class="[^>]-Home_split_[^>]-">]]
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
      local header = [[<h3 class="Home_title_[^>]-">自定义分组</h3>]]
      local tailer = [[<button class="[^>]-Home_btn_[^>]-">]]
      _, start = source:find(header)
      if start == nil then
        hs.timer.usleep(1 * 1000000)
        source = getTabSource(app)
        if source == nil then return end
        _, start = source:find(header)
      end
      if start == nil then return end
      stop = source:find(tailer, start + 1) or source:len()
    end
    source = source:sub(start + 1, stop - 1)
    if isCommon then
      local url, title = source:match(
          [[<a class="ALink_none[^>]-href="/(.-)">.- title="(.-)"]])
      tinsert(weiboSideBarTitles, title)
      tinsert(weiboSideBarURLs, url)
    end
    for url, title in source:gmatch(
        [[<a class="ALink_none[^>]-href="/(mygroup.-)">.- title="(.-)"]]) do
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

local function weiboNavigateToSideBarCondition(idx, isCommon)
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

local function weiboNavigateToSideBar(url, result, win)
  local schemeEnd = url:find("//")
  local domainEnd = url:find("/", schemeEnd + 2)
  local fullUrl = url:sub(1, domainEnd) .. result
  setTabUrl(win:application(), fullUrl)
end

local function douyinTabTitle(idx)
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

local function douyinNavigateToTabCondition(idx)
  return function()
    if appBuf.douyinTabURLs and #appBuf.douyinTabURLs >= idx then
      return true, appBuf.douyinTabURLs[idx]
    end
    return false
  end
end

local function douyinNavigateToTab(url, result, win)
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

-- some apps save key bindings in plist files
-- we need to parse them and remap specified key bindings to them
local function parsePlistKeyBinding(mods, key)
  mods = tonumber(mods) key = tonumber(key)
  if mods == nil or key == nil then return end
  key = hs.keycodes.map[key]
  local modList = {}
  if mods >= (1 << 17) then
    if mods >= (1 << 23) then tinsert(modList, "fn") end
    if (mods % (1 << 23)) >= (1 << 20) then tinsert(modList, "command") end
    if (mods % (1 << 20)) >= (1 << 19) then tinsert(modList, "option") end
    if (mods % (1 << 19)) >= (1 << 18) then tinsert(modList, "control") end
    if (mods % (1 << 18)) >= (1 << 17) then tinsert(modList, "shift") end
  else
    if mods >= (1 << 12) then tinsert(modList, "control") end
    if (mods % (1 << 12)) >= (1 << 11) then tinsert(modList, "option") end
    if (mods % (1 << 11)) >= (1 << 9) then tinsert(modList, "shift") end
    if (mods % (1 << 9)) >= (1 << 8) then tinsert(modList, "command") end
  end
  return modList, key
end

-- dump specified key bindings to plist files
local function dumpPlistKeyBinding(mode, mods, key)
  local modIdx = 0
  if mode == 1 then
    if tcontain(mods, "command") then modIdx = (1 << 8) end
    if tcontain(mods, "option") then modIdx = modIdx + (1 << 11) end
    if tcontain(mods, "control") then modIdx = modIdx + (1 << 12) end
    if tcontain(mods, "shift") then modIdx = modIdx + (1 << 9) end
  elseif mode == 2 then
    if key:lower():match("^f(%d+)$") then modIdx = 1 << 23 end
    if tcontain(mods, "command") then modIdx = modIdx + (1 << 20) end
    if tcontain(mods, "option") then modIdx = modIdx + (1 << 19) end
    if tcontain(mods, "control") then modIdx = modIdx + (1 << 18) end
    if tcontain(mods, "shift") then modIdx = modIdx + (1 << 17) end
  end
  key = hs.keycodes.map[key]
  return modIdx, key
end

-- fetch localized string as hotkey message after activating the app
local function getAppId(app)
  if type(app) == 'string' then
    return app
  elseif app.application ~= nil then
    return app:application():bundleID() or app:application():name()
  else
    return app:bundleID() or app:name()
  end
end

local function commonLocalizedMessage(message)
  if message == "Hide" or message == "Quit" then
    return function(app)
      local appname = displayName(app.application and app:application() or app)
      local appid = getAppId(app)
      local appLocale = applicationValidLocale(appid)
      if appLocale ~= nil then
        local result = localizedString(message .. ' App Store',
                                       'com.apple.AppStore',
                                       { locale = appLocale })
        if result ~= nil then
          result = result:gsub('App Store', appname)
          return result
        end
      end
      return message .. ' ' .. appname
    end
  elseif message == "Back" then
    return function(app)
      local appid = getAppId(app)
      local appLocale = applicationValidLocale(appid)
      if appLocale ~= nil then
        local result = localizedString(message, 'com.apple.AppStore',
                                       { locale = appLocale })
        if result ~= nil then
          return result
        end
      end
      return message
    end
  else
    return function(app)
      local appid = getAppId(app)
      local appLocale = applicationValidLocale(appid)
      if appLocale ~= nil then
        for i, stem in ipairs{ 'MenuCommands', 'Menus', 'Common' } do
          local retry = i > 1
          local result = localizedString(message, {
            locale = appLocale, localeFile = stem,
            framework = "AppKit.framework"
          }, retry)
          if result ~= nil then
            result = result:gsub('“%%@”', ''):gsub('%%@', '')
            return result
          end
        end
      end
      return message
    end
  end
end

local function localizedMessage(message, params, sep)
  return function(app)
    local appid = getAppId(app)
    if type(message) == 'string' then
      local str = localizedString(message, appid, params) or message
      return type(str) == 'string' and str or str[1]
    else
      if sep == nil then sep = ' > ' end
      local str = localizedMenuBarItem(message[1], appid, params) or message[1]
      for i=2,#message do
        local itemStr = localizedString(message[i], appid, params) or message[i]
        str = str .. sep .. (type(itemStr) == 'string' and itemStr or itemStr[1])
      end
      return str
    end
  end
end

-- fetch title of menu item as hotkey message by key binding
local function menuItemMessage(mods, key, titleIndex, sep)
  return function(app)
    if type(titleIndex) == 'number' then
      local menuItem = findMenuItemByKeyBinding(app, mods, key, true)
      if menuItem ~= nil then return menuItem[titleIndex] end
    else
      if sep == nil then sep = ' > ' end
      local menuItem = findMenuItemByKeyBinding(app, mods, key, true)
      if menuItem == nil then return end
      local str = menuItem[titleIndex[1]]
      for i=2,#titleIndex do
        str = str .. sep .. menuItem[titleIndex[i]]
      end
      return str
    end
  end
end

-- check if the menu item whose path is specified is enabled
-- if so, return the path of the menu item
local function checkMenuItem(menuItemTitle, params, ...)
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

-- possible reasons for failure of hotkey condition
CF = {
  noMenuItemMatchKeybinding = 0,
  uIElementNotFocused       = 1,
  rightMenubarItemSelected  = 2,
  leftMenubarItemSelected   = 3,
  nonEmptyTextFieldFocused  = 4,
  userConditionFail         = 5,
}

-- check if the menu item whose key binding is specified is enabled
-- if so, return the path of the menu item
local function checkMenuItemByKeybinding(mods, key)
  return function(app)
    local menuItem, enabled = findMenuItemByKeyBinding(app, mods, key, true)
    if menuItem ~= nil and enabled then
      return true, menuItem
    else
      return false, CF.noMenuItemMatchKeybinding
    end
  end
end

-- select the menu item returned by the condition
-- work as hotkey callback
local function receiveMenuItem(menuItemTitle, app)
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

-- send key strokes to the app. but if the key binding is found, select corresponding menu item
local function selectMenuItemOrKeyStroke(app, mods, key)
  local menuItemPath, enabled = findMenuItemByKeyBinding(app, mods, key)
  if menuItemPath ~= nil and enabled then
    app:selectMenuItem(menuItemPath)
  else
    hs.eventtap.keyStroke(mods, key, nil, app)
  end
end


-- ## hotkey configs for apps

-- hotkey configs that cound be used in various application
local specialCommonHotkeyConfigs = {
  ["closeWindow"] = {
    mods = "⌘", key = "W",
    message = commonLocalizedMessage("Close Window"),
    condition = function(app)
      local win = app:focusedWindow()
      return win ~= nil and win:role() == AX.Window, win
    end,
    repeatable = true,
    fn = function(win) win:close() end
  },
  ["minimize"] = {
    mods = "⌘", key = "M",
    message = commonLocalizedMessage("Minimize"),
    condition = function(app)
      local win = app:focusedWindow()
      return win ~= nil and win:role() == AX.Window, win
    end,
    repeatable = true,
    fn = function(win) win:minimize() end
  },
  ["hide"] = {
    mods = "⌘", key = "H",
    message = commonLocalizedMessage("Hide"),
    fn = function(app) app:hide() end
  },
  ["quit"] = {
    mods = "⌘", key = "Q",
    message = commonLocalizedMessage("Quit"),
    fn = function(app) app:kill() end
  },
  ["showPrevTab"] = {
    mods = "⇧⌘", key = "[",
    message = menuItemMessage('⇧⌃', "⇥", 2),
    condition = checkMenuItemByKeybinding('⇧⌃', "⇥"),
    repeatable = true,
    fn = receiveMenuItem
  },
  ["showNextTab"] = {
    mods = "⇧⌘", key = "]",
    message = menuItemMessage('⌃', "⇥", 2),
    condition = checkMenuItemByKeybinding('⌃', "⇥"),
    repeatable = true,
    fn = receiveMenuItem
  },
}

appHotKeyCallbacks = {
  ["com.apple.finder"] =
  {
    ["openRecent"] = {
      message = localizedMessage("Recent Folders"),
      condition = checkMenuItem({ "Go", "Recent Folders" }),
      fn = receiveMenuItem
    },
    ["open1stSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open1stSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open1stSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(1),
      windowFilter = true,
      condition = getFinderSidebarItem(1),
      fn = openFinderSidebarItem
    },
    ["open2ndSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open2ndSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open2ndSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(2),
      windowFilter = true,
      condition = getFinderSidebarItem(2),
      fn = openFinderSidebarItem
    },
    ["open3rdSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open3rdSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open3rdSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(3),
      windowFilter = true,
      condition = getFinderSidebarItem(3),
      fn = openFinderSidebarItem
    },
    ["open4thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open4thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open4thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(4),
      windowFilter = true,
      condition = getFinderSidebarItem(4),
      fn = openFinderSidebarItem
    },
    ["open5thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open5thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open5thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(5),
      windowFilter = true,
      condition = getFinderSidebarItem(5),
      fn = openFinderSidebarItem
    },
    ["open6thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open6thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open6thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(6),
      windowFilter = true,
      condition = getFinderSidebarItem(6),
      fn = openFinderSidebarItem
    },
    ["open7thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open7thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open7thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(7),
      windowFilter = true,
      condition = getFinderSidebarItem(7),
      fn = openFinderSidebarItem
    },
    ["open8thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open8thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open8thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(8),
      windowFilter = true,
      condition = getFinderSidebarItem(8),
      fn = openFinderSidebarItem
    },
    ["open9thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open9thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open9thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(9),
      windowFilter = true,
      condition = getFinderSidebarItem(9),
      fn = openFinderSidebarItem
    },
    ["open10thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open10thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open10thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(10),
      windowFilter = true,
      condition = getFinderSidebarItem(10),
      fn = openFinderSidebarItem
    }
  },

  ["com.apple.ActivityMonitor"] =
  {
    ["search"] = {
      message = commonLocalizedMessage("Search"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUI = towinui(app:focusedWindow())
        local searchField = getc(winUI, AX.Toolbar, 1, AX.Group, 2, AX.TextField, 1)
        return clickable(searchField, { 10, 2 })
      end,
      fn = click
    }
  },

  ["com.apple.MobileSMS"] =
  {
    ["deleteConversation"] = {
      message = localizedMessage("Delete Conversation…"),
      condition = function(app)
        local appUI = toappui(app)
        local messageItems
        if OS_VERSION >= OS.Tahoe then
          messageItems = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
              AX.StaticText)
        else
          messageItems = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.StaticText)
        end
        local desc = localizedString('New Message', app)
        local selected = tfind(messageItems or {}, function(msg)
          return msg.AXSelected == true and msg.AXDescription:sub(4) ~= desc
        end)
        if selected == nil then return false end
        return checkMenuItem({
          OS_VERSION < OS.Ventura and "File" or "Conversation",
          "Delete Conversation…"
        })(app)
      end,
      fn = receiveMenuItem
    },
    ["deleteAllConversations"] = {
      message = localizedMessage("Delete All"),
      condition = messageDeletable,
      fn = deleteAllMessages
    },
    ["goToPreviousConversation"] = {
      message = menuItemMessage('⇧⌃', "⇥", 2),
      condition = function(app)
        local appUI = toappui(app)
        local messageItems
        if OS_VERSION >= OS.Tahoe then
          messageItems = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
              AX.StaticText)
        else
          messageItems = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.StaticText)
        end
        local desc = localizedString('New Message', app)
        if messageItems == nil or #messageItems == 0
            or (#messageItems == 1 and (messageItems[1].AXDescription == nil
              or messageItems[1].AXDescription:sub(4) == desc)) then
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
      fn = press
    },
    ["goToNextConversation"] = {
      message = menuItemMessage('⌃', "⇥", 2),
      condition = function(app)
        local appUI = toappui(app)
        local messageItems
        if OS_VERSION >= OS.Tahoe then
          messageItems = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
              AX.StaticText)
        else
          messageItems = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.StaticText)
        end
        local desc = localizedString('New Message', app)
        if messageItems == nil or #messageItems == 0
            or (#messageItems == 1 and (messageItems[1].AXDescription == nil
              or messageItems[1].AXDescription:sub(4) == desc)) then
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
      fn = press
    }
  },

  ["com.apple.FaceTime"] = {
    ["removeFromRecents"] = {
      message = localizedMessage("Remove from Recents"),
      windowFilter = FaceTimeMainWindowFilter,
      fn = deleteMousePositionCall
    },
    ["clearAllRecents"] = {
      message = localizedMessage("Clear All Recents"),
      windowFilter = FaceTimeMainWindowFilter,
      fn = deleteAllCalls
    },
    ["newFaceTime"] = {
      message = localizedMessage("New FaceTime"),
      windowFilter = FaceTimeMainWindowFilter,
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
      fn = press
    },
    ["addPeopleWhenNewFaceTime"] = {
      message = localizedMessage("Add People"),
      windowFilter = {
        allowSheet = true,
        fn = function(win)
          local heading = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.Group, 1, AX.Heading, 1)
          return heading and heading.AXDescription ==
              localizedString("New FaceTime", win)
        end,
      },
      fn = function(win)
        local button = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Button, 1)
        if button then press(button) end
      end
    }
  },

  ["com.apple.Notes"] = {
    ["toggleFolders"] = {
      message = localizedMessage("Show Folders"),
      bindCondition = function() return OS_VERSION < OS.Tahoe end,
      condition = checkMenuItem({ "View", "Show Folders" },
                                { "View", "Hide Folders" }),
      fn = receiveMenuItem
    }
  },

  ["com.apple.games"] = {
    ["back"] = {
      message = commonLocalizedMessage("Back"),
      windowFilter = GamesMainWindowFilter,
      condition = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1, AX.Button)
        local title = commonLocalizedMessage("Back")(win)
        local button = tfind(buttons or {}, function(bt)
          return bt.AXDescription == title
        end)
        return button ~= nil, button
      end,
      fn = press
    },
    ["view1"] = {
      message = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 1 then
          return buttons[1].AXDescription
        end
      end,
      windowFilter = GamesMainWindowFilter,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 1 then
          press(buttons[1])
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
      windowFilter = GamesMainWindowFilter,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 2 then
          press(buttons[2])
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
      windowFilter = GamesMainWindowFilter,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 3 then
          press(buttons[3])
        end
      end
    },
    ["search"] = {
      message = commonLocalizedMessage("Search"),
      windowFilter = GamesMainWindowFilter,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        local title = commonLocalizedMessage("Search")(win)
        local button = tfind(buttons or {}, function(bt)
          return bt.AXDescription == title
        end)
        if button then press(button) end
      end
    }
  },

  ["com.apple.weather"] = {
    ["toggleSidebar"] = {
      message = commonLocalizedMessage("Show Sidebar"),
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
      fn = press
    },
    ["previousLocation"] = {
      message = "Previous Location",
      repeatable = true,
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local list = getc(towinui(app:focusedWindow()), AX.Group, 1,
            AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1)
        if OS_VERSION >= OS.Tahoe then list = getc(list, AX.Group, 1) end
        if list and list.AXDescription
            == localizedString("Location List", app) then
          for i = 1, #list do
            if list[i].AXSelected then
              return true, list[(i - 2) % #list + 1][1]
            end
          end
        end
        return false
      end,
      fn = press
    },
    ["nextLocation"] = {
      message = "Next Location",
      repeatable = true,
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local list = getc(towinui(app:focusedWindow()), AX.Group, 1,
            AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1)
        if OS_VERSION >= OS.Tahoe then list = getc(list, AX.Group, 1) end
        if list and list.AXDescription
            == localizedString("Location List", app) then
          for i = 1, #list do
            if list[i].AXSelected then
              return true, list[i % #list + 1][1]
            end
          end
        end
        return false
      end,
      fn = press
    },
    ["deleteLocation"] = {
      message = commonLocalizedMessage("Delete"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local list = getc(towinui(app:focusedWindow()), AX.Group, 1,
            AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1)
        if OS_VERSION >= OS.Tahoe then list = getc(list, AX.Group, 1) end
        if list and list.AXDescription ==
            localizedString("Location List", app) then
          local selected = tfind(list.AXChildren or {},
              function(item) return item.AXSelected end)
          return selected ~= nil, selected
        end
        return false
      end,
      fn = function(selected, app)
        selected:performAction(AX.ShowMenu)
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(toappui(app), uinotifications.menuOpened)
        observer:callback(function(obs, menu)
          local title = localizedString("Delete", app)
          local delete = getc(menu, AX.MenuItem, title)
          if delete then
            press(delete) obs:stop() obs = nil
          end
        end)
        observer:start()
        stopOnDeactivated(app:bundleID(), observer)
      end
    }
  },

  ["com.apple.AppStore"] =
  {
    ["back"] = {
      message = localizedMessage("Back"),
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
          press(button)
        end
      end
    }
  },

  ["com.apple.Safari"] =
  {
    ["showInFinder"] = {
      message = commonLocalizedMessage("Show in Finder"),
      windowFilter = { allowURLs = "^file://" },
      fn = function(url)
        hs.execute('open -R "' .. url .. '"')
        find("com.apple.finder"):activate()
      end
    },
    ["openRecent"] = {
      message = localizedMessage("Recently Closed"),
      condition = checkMenuItem({ "History", "Recently Closed" }),
      fn = receiveMenuItem
    }
  },

  ["com.apple.Preview"] =
  {
    ["showInFinder"] = {
      message = commonLocalizedMessage("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        find("com.apple.finder"):activate()
      end
    }
  },

  ["com.google.Chrome"] =
  {
    ["openRecent"] = {
      message = localizedMessage("Search Tabs…"),
      condition = checkMenuItem({ "Tab", "Search Tabs…" }),
      fn = receiveMenuItem
    },
    ["showInFinder"] = {
      message = commonLocalizedMessage("Show in Finder"),
      windowFilter = { allowURLs = "^file://" },
      fn = function(url)
        hs.execute('open -R "' .. url .. '"')
        find("com.apple.finder"):activate()
      end
    }
  },

  ["com.microsoft.VSCode"] =
  {
    ["view:toggleOutline"] = {
      message = "View: Toggle Outline",
      condition = function(app)
        if app:focusedWindow() == nil then
          return false
        else
          local winUI = towinui(app:focusedWindow())
          return winUI.AXIdentifier ~= "open-panel", winUI
        end
      end,
      repeatable = true,
      fn = function(winUI)
        VSCodeToggleSideBarSection(winUI, "EXPLORER", "OUTLINE")
      end
    },
    ["view:toggleTimeline"] = {
      message = "View: Toggle Timeline",
      condition = function(app)
        if app:focusedWindow() == nil then
          return false
        else
          local winUI = towinui(app:focusedWindow())
          return winUI.AXIdentifier ~= "open-panel", winUI
        end
      end,
      repeatable = true,
      fn = function(winUI)
        VSCodeToggleSideBarSection(winUI, "EXPLORER", "TIMELINE")
      end
    },
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
    ["openRecent"] = {
      message = "Open Recent",
      condition = checkMenuItem({ "File", "Open Recent", "More…" },
                                { "File", "Open Recent" }),
      fn = receiveMenuItem
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
      message = localizedMessage("Show Main Window"),
      condition = checkMenuItem({ "Window", "Show Main Window" }),
      fn = receiveMenuItem
    },
    ["moveFocusToSidebar"] = {
      message = localizedMessage("Move Focus to Sidebar"),
      condition = checkMenuItem({ "View", "Move Focus to Sidebar" }),
      fn = receiveMenuItem
    },
    ["moveFocusToSnippetsList"] = {
      message = localizedMessage("Move Focus to Snippets List"),
      condition = checkMenuItem({ "View", "Move Focus to Snippets List" }),
      fn = receiveMenuItem
    },
    ["moveFocusToEditor"] = {
      message = localizedMessage("Move Focus to Editor"),
      condition = checkMenuItem({ "View", "Move Focus to Editor" }),
      fn = receiveMenuItem
    },
    ["moveFocusToPreview"] = {
      message = localizedMessage("Move Focus to Preview"),
      condition = checkMenuItem({ "View", "Move Focus to Preview" }),
      fn = receiveMenuItem
    }
  },

  ["com.readdle.PDFExpert-Mac"] =
  {
    ["showInFinder"] = {
      message = localizedMessage("Show in Finder"),
      condition = checkMenuItem({ "File", "Show in Finder" }),
      fn = receiveMenuItem
    },
    ["remapPreviousTab"] = {
      message = localizedMessage("Go to Previous Tab"),
      condition = checkMenuItem({ "Window", "Go to Previous Tab" }),
      repeatable = true,
      fn = receiveMenuItem
    }
  },

  ["com.vallettaventures.Texpad"] =
  {
    ["toggleOutline"] = {
      message = localizedMessage("Toggle Outline"),
      condition = checkMenuItem({ "Workspace", "Toggle Outline" }),
      fn = receiveMenuItem
    },
    ["openRecent"] = {
      message = localizedMessage("Recent Documents"),
      condition = checkMenuItem({ "File", "Recent Documents" }),
      fn = receiveMenuItem
    }
  },

  ["abnerworks.Typora"] =
  {
    ["openFileLocation"] = {
      message = localizedMessage("Open File Location"),
      condition = checkMenuItem({ "File", "Open File Location" }),
      fn = receiveMenuItem
    },
    ["openRecent"] = {
      message = localizedMessage("Open Recent"),
      condition = checkMenuItem({ "File", "Open Quickly…" },
                                { "File", "Open Recent" }),
      fn = receiveMenuItem
    }
  },

  ["com.superace.updf.mac"] =
  {
    ["goToHome"] = {
      message = localizedMessage("Home"),
      windowFilter = {
        allowTitles = "",
        fn = function(win)
          local title = localizedString("Home", win)
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
      message = commonLocalizedMessage("Show Sidebar"),
      condition = function(app)
        local title = localizedString("View", app)
        local menuItems = getc(toappui(app), AX.MenuBar, 1,
            AX.MenuBarItem, title, AX.Menu, 1, AX.MenuItem)
        local firstSidebarMenuItem
        for _, item in ipairs(menuItems or {}) do
          if item.AXTitle == "" then break end
          if #item == 0 then
            if item.AXMenuItemMarkChar then
              return true, item
            end
            firstSidebarMenuItem = firstSidebarMenuItem or item
          end
        end
        return firstSidebarMenuItem ~= nil, firstSidebarMenuItem
      end,
      fn = press
    },
    ["showPrevTab"] = specialCommonHotkeyConfigs["showPrevTab"],
    ["showNextTab"] = specialCommonHotkeyConfigs["showNextTab"],
    ["showInFinder"] = {
      message = localizedMessage("Show in Finder"),
      condition = checkMenuItem({ "File", "Show in Finder" }),
      fn = receiveMenuItem
    },
    ["openRecent"] = {
      message = localizedMessage("Open Quickly…"),
      condition = checkMenuItem({ "File", "Open Quickly…" }),
      fn = receiveMenuItem
    },
    ["confirmDelete"] = {
      message = localizedMessage("Don't Save"),
      condition = function(app)
        local win = app:focusedWindow()
        if win == nil then return false end
        local winUI = towinui(win)
        local buttons = getc(winUI, AX.Button)
        local title = localizedString("Don't Save", app)
        for _, button in ipairs(buttons) do
          if button.AXTitle == title then
            return true, button
          end
        end
        return false
      end,
      fn = press
    }
  },

  ["com.kingsoft.wpsoffice.mac"] =
  {
    ["previousWindow"] = specialCommonHotkeyConfigs["showPrevTab"],
    ["nextWindow"] = specialCommonHotkeyConfigs["showNextTab"],
    ["goToFileTop"] = {
      mods = "", key = "Home",
      message = "Cursor to Top",
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke("⌘", "Home", nil, app) end
    },
    ["goToFileBottom"] = {
      mods = "", key = "End",
      message = "Cursor to Bottom",
      fn = function(app) hs.eventtap.keyStroke("⌘", "End", nil, app) end
    },
    ["selectToFileTop"] = {
      mods = "⇧", key = "Home",
      message = "Select to Top",
      fn = function(app) hs.eventtap.keyStroke("⇧⌘", "Home", nil, app) end
    },
    ["selectToFileBottom"] = {
      mods = "⇧", key = "End",
      message = "Select to Bottom",
      fn = function(app) hs.eventtap.keyStroke("⇧⌘", "End", nil, app) end
    },
    ["properties"] = {
      message = localizedMessage("Properties..."),
      condition = checkMenuItem({ "File", "Properties..." }),
      fn = receiveMenuItem
    },
    ["exportToPDF"] = {
      message = localizedMessage("Export to PDF..."),
      condition = checkMenuItem({ "File", "Export to PDF..." }),
      fn = receiveMenuItem
    },
    ["insertTextBox"] = {
      message = localizedMessage({ "Insert", "Text Box" }),
      condition = checkMenuItem({ "Insert", "Text Box", "Horizontal Text Box" }),
      fn = receiveMenuItem
    },
    ["insertEquation"] = {
      message = localizedMessage({ "Insert", "LaTeXEquation..." }),
      condition = checkMenuItem({ "Insert", "LaTeXEquation..." }),
      fn = receiveMenuItem
    },
    ["pdfHightlight"] = {
      message = localizedMessage("Highlight"),
      condition = checkMenuItem({ "Comment", "Highlight" }),
      fn = receiveMenuItem
    },
    ["pdfUnderline"] = {
      message = localizedMessage("Underline"),
      condition = checkMenuItem({ "Comment", "Underline" }),
      fn = receiveMenuItem
    },
    ["pdfStrikethrough"] = {
      message = localizedMessage("Strikethrough"),
      condition = checkMenuItem({ "Comment", "Strikethrough" }),
      fn = receiveMenuItem
    },
    ["goToHome"] = {
      message = localizedMessage("Home"),
      condition = function(app)
        local win = app:focusedWindow()
        local home = localizedString("Home", app)
        return win ~= nil and win:title() ~= home, win
      end,
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
      message = localizedMessage("Recent"),
      fn = function(app)
        if app:focusedWindow() == nil then return end
        local home = localizedString("Home", app)
        local winUI = towinui(app:focusedWindow())
        if app:focusedWindow():title() ~= home then
          local buttons = getc(winUI, AX.Button)
          local maxX = buttons[#buttons].AXPosition.x
          maxX = math.max(maxX, buttons[#buttons - 1].AXPosition.x)
          maxX = math.max(maxX, buttons[#buttons - 2].AXPosition.x)
          local mousePosition = hs.mouse.absolutePosition()
          local position = hs.geometry.point{ maxX + 100, buttons[#buttons].AXPosition.y }
          hs.eventtap.event.newMouseEvent(
              hs.eventtap.event.types.leftMouseDown, position):post()
          hs.eventtap.event.newMouseEvent(
              hs.eventtap.event.types.leftMouseUp, position):post()
          hs.eventtap.event.newMouseEvent(
              hs.eventtap.event.types.mouseMoved, mousePosition):post()
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
      message = localizedMessage("Share"),
      condition = function(app)
        local win = app:focusedWindow()
        local home = localizedString("Home", app)
        if win == nil or win:title() ~= home then return false end
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
        if firstSplitLine == 4 then return clickable(groups[3]) end
        return false
      end,
      fn = click
    },
    ["goToMyCloudDocuments"] = {
      message = localizedMessage("My Cloud Documents"),
      condition = function(app)
        local win = app:focusedWindow()
        local home = localizedString("Home", app)
        if win == nil or win:title() ~= home then return false end
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
          return clickable(groups[firstSplitLine + 2])
        end
        return false
      end,
      fn = click
    },
    ["goToMyDesktop"] = {
      message = localizedMessage("My Desktop"),
      condition = function(app)
        local win = app:focusedWindow()
        local home = localizedString("Home", app)
        if win == nil or win:title() ~= home then return false end
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
          return clickable(groups[secondSplitLine + 2])
        end
        return false
      end,
      fn = click
    },
    ["goToDocuments"] = {
      message = localizedMessage("Documents"),
      condition = function(app)
        local win = app:focusedWindow()
        local home = localizedString("Home", app)
        if win == nil or win:title() ~= home then return false end
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
          return clickable(groups[secondSplitLine + 3])
        end
        return false
      end,
      fn = click
    },
    ["goToDownloads"] = {
      message = localizedMessage("Downloads"),
      condition = function(app)
        local win = app:focusedWindow()
        local home = localizedString("Home", app)
        if win == nil or win:title() ~= home then return false end
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
          return clickable(groups[secondSplitLine + 4])
        end
        return false
      end,
      fn = click
    },
    ["openFileLocation"] = {
      message = localizedMessage("Open File Location"),
      condition = function(app)
        local win = app:focusedWindow()
        local home = localizedString("Home", app)
        if win == nil or win:title() == home then return false end
        local winUI = towinui(win)
        for i=1,#winUI - 1 do
          if winUI[i].AXRole == AX.Button
              and winUI[i + 1].AXRole == AX.Group then
            return true, winUI[i].AXPosition
          end
        end
        return false
      end,
      fn = function(position, app)
        local title = localizedString("Open File Location", app)
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(toappui(app), uinotifications.created)
        observer:callback(function(obs)
          for _, elem in ipairs(toappui(app)) do
            local menuItem = getc(elem, AX.Menu, 1, AX.MenuItem, title)
            if menuItem then
              press(menuItem)
              if hs.application.frontmostApplication():bundleID() == app:bundleID() then
                hs.eventtap.keyStroke("", "Escape", nil, app)
              end
              obs:stop()
              obs = nil
            end
          end
        end)
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
    }
  },

  ["com.apple.iWork.Keynote"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = localizedMessage({ "Export To", "PDF…" }),
      condition = checkMenuItem({ "File", "Export To", "PDF…" }),
      fn = receiveMenuItem
    },
    ["exportToPPT"] = {  -- File > Export To > PowerPoint…
      message = localizedMessage({ "Export To", "PowerPoint…" }),
      condition = checkMenuItem({ "File", "Export To", "PowerPoint…" }),
      fn = receiveMenuItem
    },
    ["pasteAndMatchStyle"] = {  -- Edit > Paste and Match Style
      message = localizedMessage("Paste and Match Style"),
      condition = checkMenuItem({ "Edit", "Paste and Match Style" }),
      repeatable = true,
      fn = receiveMenuItem
    },
    ["paste"] = {  -- Edit > Paste
      message = localizedMessage("Paste"),
      condition = checkMenuItem({ "Edit", "Paste" }),
      repeatable = true,
      fn = receiveMenuItem
    },
    ["showBuildOrder"] = {  -- View > Show Build Order
      message = localizedMessage("Show Build Order"),
      condition = checkMenuItem({ "View", "Show Build Order" }),
      fn = function(menuItemTitle, app)
        app:selectMenuItem(menuItemTitle)
        hs.timer.doAfter(0.5, function()
          local winTitle = localizedString("Build Order", app)
          local window = tifilter(app:visibleWindows(), function(win)
            return win:title() == winTitle
          end)
          if #window ~= 0 then window[1]:raise() end
        end)
      end
    },
    ["toggleFormatInspector"] = {  -- View > Inspector > Format
      message = localizedMessage({ "Inspector", "Format" }),
      condition = checkMenuItem({ "View", "Inspector", "Format" }),
      fn = receiveMenuItem
    },
    ["play"] = {  -- Play > Play Slideshow
      message = localizedMessage("Play Slideshow"),
      condition = checkMenuItem({ "Play", "Play Slideshow" }),
      fn = receiveMenuItem
    },
    ["insertTextBox"] = {  -- Insert > Text Box
      message = localizedMessage({ "Insert", "Text Box" }),
      condition = checkMenuItem({ "Insert", "Text Box" }),
      fn = receiveMenuItem
    },
    ["insertShape"] = {  -- Insert > Shape
      message = localizedMessage({ "Insert", "Shape" }),
      condition = checkMenuItem({ "Insert", "Shape" }),
      fn = receiveMenuItem
    },
    ["insertLine"] = {  -- Insert > Line
      message = localizedMessage({ "Insert", "Line" }),
      condition = checkMenuItem({ "Insert", "Line" }),
      fn = receiveMenuItem
    },
    ["showInFinder"] = {
      message = commonLocalizedMessage("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        find("com.apple.finder"):activate()
      end
    },
  },

  ["com.apple.iWork.Pages"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = localizedMessage({ "Export To", "PDF…" }),
      condition = checkMenuItem({ "File", "Export To", "PDF…" }),
      fn = receiveMenuItem
    },
    ["exportToWord"] = {  -- File > Export To > Word…
      message = localizedMessage({ "Export To", "Word…" }),
      condition = checkMenuItem({ "File", "Export To", "Word…" }),
      fn = receiveMenuItem
    },
    ["pasteAndMatchStyle"] = {  -- Edit > Paste and Match Style
      message = localizedMessage("Paste and Match Style"),
      condition = checkMenuItem({ "Edit", "Paste and Match Style" }),
      repeatable = true,
      fn = receiveMenuItem
    },
    ["paste"] = {  -- Edit > Paste
      message = localizedMessage("Paste"),
      condition = checkMenuItem({ "Edit", "Paste" }),
      repeatable = true,
      fn = receiveMenuItem
    },
    ["toggleFormatInspector"] = {  -- View > Inspector > Format
      message = localizedMessage({ "Inspector", "Format" }),
      condition = checkMenuItem({ "View", "Inspector", "Format" }),
      fn = receiveMenuItem
    },
    ["showInFinder"] = {
      message = commonLocalizedMessage("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        find("com.apple.finder"):activate()
      end
    },
  },

  ["com.apple.iWork.Numbers"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = localizedMessage({ "Export To", "PDF…" }),
      condition = checkMenuItem({ "File", "Export To", "PDF…" }),
      fn = receiveMenuItem
    },
    ["exportToExcel"] = {  -- File > Export To > Excel…
      message = localizedMessage({ "Export To", "Excel…" }),
      condition = checkMenuItem({ "File", "Export To", "Excel…" }),
      fn = receiveMenuItem
    },
    ["pasteAndMatchStyle"] = {  -- Edit > Paste and Match Style
      message = localizedMessage("Paste and Match Style"),
      condition = checkMenuItem({ "Edit", "Paste and Match Style" }),
      repeatable = true,
      fn = receiveMenuItem
    },
    ["paste"] = {  -- Edit > Paste
      message = localizedMessage("Paste"),
      condition = checkMenuItem({ "Edit", "Paste" }),
      repeatable = true,
      fn = receiveMenuItem
    },
    ["toggleFormatInspector"] = {  -- View > Inspector > Format
      message = localizedMessage({ "Inspector", "Format" }),
      condition = checkMenuItem({ "View", "Inspector", "Format" }),
      fn = receiveMenuItem
    },
    ["showInFinder"] = {
      message = commonLocalizedMessage("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        find("com.apple.finder"):activate()
      end
    },
  },

  ["net.xmind.vana.app"] =
  {
    ["exportToPDF"] = {
      message = localizedMessage({ "Export", "PDF" }),
      condition = checkMenuItem({ "File", "Export", "PDF" }),
      fn = receiveMenuItem
    },
    ["insertEquation"] = {
      message = localizedMessage({ "Insert", "Equation" }),
      condition = checkMenuItem({ 'Insert', "Equation" }),
      fn = receiveMenuItem
    }
  },

  ["com.eusoft.freeeudic"] =
  {
    ["function1"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 1)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDicMainWindowFilter,
      condition = checkMenuItem({ "功能", "返回首页" }),
      fn = receiveMenuItem
    },
    ["function2"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 2)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDicMainWindowFilter,
      fn = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 2)
        press(button)
      end
    },
    ["function3"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 3)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDicMainWindowFilter,
      fn = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 3)
        press(button)
      end
    },
    ["function4"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 4)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDicMainWindowFilter,
      fn = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 4)
        press(button)
      end
    },
    ["function5"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 5)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDicMainWindowFilter,
      fn = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 5)
        press(button)
      end
    },
    ["function6"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 6)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDicMainWindowFilter,
      fn = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 6)
        press(button)
      end
    }
  },

  ["com.openai.chat"] =
  {
    ["toggleSidebar"] = {
      message = localizedMessage("Toggle Sidebar"),
      bindCondition = versionLessEqual("1.2024.332"),
      condition = checkMenuItem({ "View", "Toggle Sidebar" }),
      fn = receiveMenuItem
    },
    ["back"] = {
      message = localizedMessage("Back"),
      windowFilter = {
        fn = function(win)
          return towinui(win).AXIdentifier == "ChatGPTSettingsAppWindow"
        end
      },
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 1, AX.Button, 1)
        return button ~= nil and button.AXEnabled, button
      end,
      fn = press
    },
    ["toggleLauncher"] = {
      message = "Toggle ChatGPT Launcher",
      background = true,
      fn = function()
        clickRightMenuBarItem("ChatGPTHelper", {}, "click")
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
        clickRightMenuBarItem("ChatGPTHelper", {}, "click")
      end
    }
  },

  ["com.tencent.yuanbao"] =
  {
    ["settings"] = {
      message = localizedMessage("Settings"),
      condition = function(app)
        if app:focusedWindow() == nil then
          return versionGreaterEqual("2")(app)
        end
        if app:focusedWindow():title() ==
            localizedString("Tencent Yuanbao Setting", app) then
          return false
        end

        local winUI = towinui(app:focusedWindow())
        local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
          AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        local menu = getc(webarea, AX.Group, 8, AX.Group, 2, AX.Group, 1)

        if menu then
          local title = localizedString("Settings", app)
          local menuItem = getc(menu, AX.StaticText, title)
          return clickable(menuItem)
        end

        local button = tfind(getc(webarea, AX.Group), function(b)
          return tfind(b.AXDOMClassList or {}, function(c)
            return c:find("side%-bar_nickName") ~= nil
                or c:find("side%-bar_name") ~= nil
          end) ~= nil
        end)
        if button ~= nil and button.AXPosition.x ~= winUI.AXPosition.x then
          local ok, position = clickable(button)
          if ok then
            local bt = getc(webarea, AX.StaticText, "\xee\x83\xbe")
            if bt ~= nil then
              return ok, { position, button }
            end
          end
        end

        return versionGreaterEqual("2")(app)
      end,
      fn = function(button, app)
        if app ~= nil then
          if #button == 0 then
            click(button) return
          end
          click(button[1]) button = button[2]

          if tfind(button.AXDOMClassList or {}, function(c)
            return c:find("nickName") ~= nil
          end) ~= nil then
            local menuItem
            local timer = hs.timer.waitUntil(function()
              local winUI = towinui(app:focusedWindow())
              local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
                  AX.ScrollArea, 1, AX.WebArea, 1)
              local menu = getc(webarea, AX.Group, 8, AX.Group, 2, AX.Group, 1)
              if menu then
                local title = localizedString("Settings", app)
                menuItem = getc(menu, AX.StaticText, title)
                return true
              end
            end,
            function() leftClickAndRestore(menuItem, app) end)
            stopOnDeactivated(app:bundleID(), timer)
          end
          return
        end

        app = button
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(toappui(app), uinotifications.windowCreated)
        observer:callback(function(obs, winUI)
          local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
          if webarea then
            local title = localizedString("Settings", app)
            for _, g in ipairs(getc(webarea, AX.Group)) do
              if g[1] and g[1].AXValue == title then
                leftClickAndRestore(g[1], app) break
              end
            end
            obs:stop()
            obs = nil
          end
        end)
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
      message = localizedMessage("New Chat"),
      bindCondition = versionLessThan("1.6.0"),
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
      fn = press
    },
    ["enterTemporaryChat"] = {
      message = localizedMessage("Enter Temporary Chat"),
      windowFilter = YuanbaoMainWindowFilter,
      condition = function(win)
        local webarea = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        local button = getc(webarea, AX.StaticText, "\xee\x84\x83")
        if button == nil then
          button = getc(webarea, AX.StaticText, "\xee\x82\xa8")
        end
        return clickable(button)
      end,
      fn = click
    },
    ["toggleSidebar"] = {
      message = localizedMessage("Show Sidebar"),
      windowFilter = YuanbaoMainWindowFilter,
      condition = function(win)
        local webarea = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        if versionLessThan("1.15.0")(win:application()) then
          local button = tfind(getc(webarea, AX.Group), function(b)
            return tfind(b.AXDOMClassList or {}, function(c)
              return c:find("folder_foldIcon") ~= nil
            end) ~= nil
          end)
          return button ~= nil, button
        else
          local button = getc(webarea, AX.StaticText, "\xee\x84\x82")
          return clickable(button)
        end
      end,
      fn = function(result)
        local action = result.AXTitle ~= nil and press or click
        action(result)
      end
    },
    ["maximize"] = {
      mods = get(KeybindingConfigs.hotkeys.shared, "zoom", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared, "zoom", "key"),
      message = localizedMessage("Maximize"),
      windowFilter = YuanbaoMainWindowFilter,
      condition = checkMenuItem({ "Window", "Maximize" }),
      fn = receiveMenuItem
    },
    ["back"] = {
      message = commonLocalizedMessage("Back"),
      bindCondition = versionLessThan("2"),
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
      fn = press
    },
    ["toggleLauncher"] = {
      message = function(app)
        local appname = displayName(app)
        return "Toggle " .. appname .. " Launcher"
      end,
      background = true,
      fn = function(app)
        if versionLessThan("2")(app) then
          -- false invoke when menubar manager try to show or hide menubar icon
          -- always show the icon to workaround it
          clickRightMenuBarItem(app, {}, "click")
        else
          local observer = uiobserver.new(app:pid())
          observer:addWatcher(toappui(app), uinotifications.windowCreated)
          observer:callback(function(obs, winUI)
            -- false invoke when menubar manager try to show or hide menubar icon
            -- in earley edition
            if winUI.AXSubrole == AX.StandardWindow then return end

            local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
              AX.ScrollArea, 1, AX.WebArea, 1)
            if webarea then
              local title = localizedString("Open Mini Chat", app)
              for _, g in ipairs(getc(webarea, AX.Group)) do
                if g[1] and g[1].AXValue == title then
                  leftClickAndRestore(g[1], app)
                  break
                end
              end
              obs:stop()
              obs = nil
            end
          end)
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
        appHotKeyCallbacks[app:bundleID()]["toggleLauncher"].fn(app)
      end
    },
    ["showMainWindow"] = {
      message = localizedMessage("Open Yuanbao"),
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
      message = localizedMessage("Preferences"),
      condition = checkMenuItem({ "File", "Preferences" }),
      fn = receiveMenuItem
    },
    ["newLibrary"] = {
      message = localizedMessage("New library"),
      condition = checkMenuItem({ "File", "New library" }),
      fn = receiveMenuItem
    },
    ["openRecent"] = {
      message = localizedMessage("Recent libraries"),
      condition = checkMenuItem({ "File", "Recent libraries" }),
      fn = receiveMenuItem
    },
    ["revealLibrayInFinder"] = {
      message = localizedMessage("Reveal in file explorer"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUI = towinui(app:focusedWindow())
        local tab = tfind(getc(winUI, AX.TabGroup, 1, AX.RadioButton) or {},
          function(rb) return rb.AXValue == true
              and rb.AXTitle ~= localizedString("untitled", app)
        end)
        return tab ~= nil, tab
      end,
      fn = function(tab, app)
        tab:performAction(AX.ShowMenu)
        hs.timer.doAfter(0.1, function()
          local title = "Reveal in file explorer"
          title = localizedString(title, app) or title
          local item = getc(toappui(app), AX.Menu, 1, AX.MenuItem, title)
          if item then press(item) end
        end)
      end
    },
    ["openRecordFile"] = {
      message = localizedMessage("Open file"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUI = towinui(app:focusedWindow())
        local row = tfind(getc(winUI, AX.TabGroup, 1, AX.Table, 1, AX.Row) or {},
          function(r) return r.AXFocused
        end)
        if row then
          local cell = tfind(getc(row, AX.Cell), function(c)
            local text = getc(c, AX.StaticText, 1)
            return text ~= nil and text.AXValue == "\xf3\xb0\x88\xa5"
          end)
          return clickable(cell)
        end
      end,
      fn = click
    },
    ["remapPreviousTab"] = {
      message = localizedMessage("Previous library"),
      condition = JabRefShowLibraryByIndex(2, false),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⇧⌃', 'Tab', nil, app) end
    },
    ["showPrevLibrary"] = {
      mods = specialCommonHotkeyConfigs["showPrevTab"].mods,
      key = specialCommonHotkeyConfigs["showPrevTab"].key,
      message = localizedMessage("Previous library"),
      condition = JabRefShowLibraryByIndex(2, false),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⇧⌃', 'Tab', nil, app) end
    },
    ["showNextLibrary"] = {
      mods = specialCommonHotkeyConfigs["showNextTab"].mods,
      key = specialCommonHotkeyConfigs["showNextTab"].key,
      message = localizedMessage("Next library"),
      condition = JabRefShowLibraryByIndex(2, false),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⌃', 'Tab', nil, app) end
    },
    ["1stLibrary"] = {
      message = "First Library",
      condition = JabRefShowLibraryByIndex(1),
      fn = click
    },
    ["2ndLibrary"] = {
      message = "Second Library",
      condition = JabRefShowLibraryByIndex(2),
      fn = click
    },
    ["3rdLibrary"] = {
      message = "Third Library",
      condition = JabRefShowLibraryByIndex(3),
      fn = click
    },
    ["4thLibrary"] = {
      message = "Forth Library",
      condition = JabRefShowLibraryByIndex(4),
      fn = click
    },
    ["5thLibrary"] = {
      message = "Fifth Library",
      condition = JabRefShowLibraryByIndex(5),
      fn = click
    },
    ["6thLibrary"] = {
      message = "Sixth Library",
      condition = JabRefShowLibraryByIndex(6),
      fn = click
    },
    ["7thLibrary"] = {
      message = "Seventh Library",
      condition = JabRefShowLibraryByIndex(7),
      fn = click
    },
    ["8thLibrary"] = {
      message = "Eighth Library",
      condition = JabRefShowLibraryByIndex(8),
      fn = click
    },
    ["9thLibrary"] = {
      message = "Nineth Library",
      condition = JabRefShowLibraryByIndex(9),
      fn = click
    },
    ["10thLibrary"] = {
      message = "Tenth Library",
      condition = JabRefShowLibraryByIndex(10),
      fn = click
    },
    ["minimize"] = specialCommonHotkeyConfigs["minimize"]
  },

  ["org.zotero.zotero"] = {
    ["newCollection"] = {
      message = localizedMessage("New Collection…"),
      condition = checkMenuItem({ "File", "New Collection…" }),
      fn = receiveMenuItem
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
      fn = press
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
          press(button)
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
      fn = press
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
          press(button)
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
      fn = press
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"]
  },

  ["com.apple.iMovieApp"] =
  {
    ["export"] = {
      message = localizedMessage({ "Share", "File…" }),
      condition = checkMenuItem({ "File", "Share", "File…" }),
      fn = receiveMenuItem
    },
    ["openRecent"] = {
      message = localizedMessage("Open Library"),
      condition = checkMenuItem({ "File", "Open Library" }),
      fn = receiveMenuItem
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
      message = commonLocalizedMessage("Back"),
      bindCondition = versionRange("4", "4.0.6"),
      windowFilter = {
        fn = function(win)
          local view1 = getc(towinui(win), AX.Group, 1, AX.Button, 1)
          return view1 and view1.AXTitle == win:title()
        end
      },
      condition = function(win)
        local back = commonLocalizedMessage("Back")(win:application())
        local bt = getc(towinui(win), AX.Group, 1,
            AX.SplitGroup, 1, AX.Button, back)
        return clickable(bt)
      end,
      fn = click
    },
    ["backInOfficialAccounts"] = {
      message = commonLocalizedMessage("Back"),
      bindCondition = versionLessThan("4"),
      windowFilter = {
        fn = function(win)
          local view1 = getc(towinui(win), AX.Group, 1, AX.Button, 1)
          return view1 and view1.AXTitle == win:title()
        end
      },
      condition = function(win)
        local back = localizedString("Common.Navigation.Back", win)
        local g = getc(towinui(win), AX.SplitGroup, 1, AX.SplitGroup, 1)
        if g ~= nil then
          for _, bt in ipairs(getc(g, AX.Button)) do
            if bt.AXTitle == back then
              return true, bt
            end
          end
        end
      end,
      fn = press
    },
    ["backInMoments"] = {
      message = commonLocalizedMessage("Back"),
      bindCondition = versionLessThan("4.0.6"),
      windowFilter = {
        fn = function(win)
          local app = win:application()
          local title = win:title()
          if title:find(app:name()) == nil then
            if versionGreaterEqual("4")(app) then
              local moments = findMenuItemByKeyBinding(app, "⌘", "4", true)
              return moments and title == moments[2]
            else
              local album = localizedString("Album_WindowTitle", win)
              local moments = localizedString("SNS_Feed_Window_Title", win)
              local detail = localizedString("SNS_Feed_Detail_Title", win)
              return title:find(album .. '-') == 1
                  or title == moments .. '-' .. detail
            end
          end
        end
      },
      condition = function(win)
        local title = commonLocalizedMessage("Back")(win)
        return clickable(getc(towinui(win), AX.Button, title))
      end,
      fn = click
    },
    ["hideChat"] = {
      message = function(win)
        if versionLessThan("4")(win:application()) then
          return localizedString("Chats.Menu.Hide", win)
        else
          return localizedString("Hide", win)
        end
      end,
      bindCondition = versionLessThan("4.0.6"),
      windowFilter = {
        fn = function(win)
          local view1 = getc(towinui(win), AX.Group, 1, AX.Button, 1)
          return view1 and view1.AXTitle == win:title()
        end
      },
      condition = function(win)
        local app = win:application()
        local winUI = towinui(win)
        if versionLessThan("4")(app) then
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
            if hide then press(hide) end
          end
        else
          hs.timer.doAfter(0.5, function()
            local app = win:application()
            local menu = toappui(app):elementAtPosition(
                uioffset(chat.AXPosition, { 1, 1 }))
            if menu and menu.AXRole == AX.Menu then
              local title = localizedString("Hide", app)
              local hide = getc(menu, AX.MenuItem, title)
              if hide then leftClickAndRestore(hide, app) end
            end
          end)
        end
      end
    },
    ["showChatProfile"] = {
      message = localizedMessage("Chats.Menu.Profile"),
      bindCondition = versionLessThan("4"),
      windowFilter = {
        fn = function(win)
          local view1 = getc(towinui(win), AX.Group, 1, AX.Button, 1)
          return view1 and view1.AXTitle == win:title()
        end
      },
      condition = function(win)
        local winUI = towinui(win)
        local curChatTitle = getc(winUI, AX.SplitGroup, 1,
            AX.SplitGroup, 1, AX.StaticText, 1)
        if curChatTitle == nil then return false end
        local btTitle = localizedString("ComposeBar.VideoTooltip", win)
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
            if profile then press(profile) end
          end
        end
      end
    },
    ["openInDefaultBrowser"] = {
      message = function(win)
        local app = win:application()
        if versionLessThan("4")(app) then
          return localizedString("Open in Default Browser", app)
        else
          local exBundleID = "com.tencent.flue.WeChatAppEx"
          local appLocale = applicationLocale(app:bundleID())
          return localizedString("Open in default browser", exBundleID,
                                 { locale = appLocale })
        end
      end,
      windowFilter = {
        fn = function(win)
          if versionLessThan("4")(win:application()) then
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
      fn = function(win)
        local app = win:application()
        if versionLessThan("4")(app) then
          local frame = win:frame()
          local position = { frame.x + frame.w - 60, frame.y + 23 }
          leftClickAndRestore(position, win)
          return
        end

        local button = getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Group, 1, AX.Group, 1, nil, 1)
        if button then press(button) end
        if button and button.AXRole == AX.PopUpButton then
          local menuWin, totalDelay = nil, 0
          repeat
            menuWin = tfind(getc(toappui(app), AX.Window), function(win)
              return #win ==  1
            end)
            if menuWin == nil then
              hs.timer.usleep(0.05 * 1000000)
              totalDelay = totalDelay + 0.05
            end
          until menuWin or totalDelay > 1
          local menuItems = getc(menuWin, AX.Group, 1, AX.Menu, 1, AX.MenuItem)
          if menuItems and #menuItems > 0 then
            local exBundleID = "com.tencent.flue.WeChatAppEx"
            local appLocale = applicationLocale(app:bundleID())
            local title = localizedString("Open in default browser", exBundleID,
                                          { locale = appLocale })
            local menuItem = tfind(menuItems, function(item)
              return item.AXDescription == title
            end)
            if menuItem then press(menuItem) end
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
      windowFilter = {
        fn = function(win)
          local app = win:application()
          local appLocale = applicationLocale(app:bundleID())
          local exBundleID = "com.tencent.flue.WeChatAppEx"
          local params = { locale = appLocale }
          local menuItemPath = {
            localizedMenuBarItem("Window", exBundleID, params),
            localizedString("Select Previous Tab", exBundleID, params)
          }
          if #menuItemPath == 2 then
            local menuItem = app:findMenuItem(menuItemPath)
            return menuItem ~= nil
          end
        end
      },
      condition = function(win)
        local app = win:application()
        local appLocale = applicationLocale(app:bundleID())
        local exBundleID = "com.tencent.flue.WeChatAppEx"
        local params = { locale = appLocale }
        local menuItemPath = {
          localizedMenuBarItem("Window", exBundleID, params),
          localizedString("Select Previous Tab", exBundleID, params)
        }
        local menuItem = app:findMenuItem(menuItemPath)
        if menuItem ~= nil and menuItem.enabled then
          return true, menuItemPath
        end
      end,
      repeatable = true,
      fn = receiveMenuItem
    },
    ["closeWindow"] = {
      mods = specialCommonHotkeyConfigs["closeWindow"].mods,
      key = specialCommonHotkeyConfigs["closeWindow"].key,
      message = function(win)
        local exBundleID = "com.tencent.flue.WeChatAppEx"
        local appLocale = applicationLocale(win:application():bundleID())
        return localizedString('Close All Tabs', exBundleID, { locale = appLocale })
      end,
      bindCondition = versionGreaterEqual("4"),
      windowFilter = {
        fn = function(win)
          local exBundleID = "com.tencent.flue.WeChatAppEx"
          local appLocale = applicationLocale(win:application():bundleID())
          local menuItemPath = {
            localizedMenuBarItem('File', exBundleID, { locale = appLocale }),
            localizedString('Close All Tabs', exBundleID, { locale = appLocale })
          }
          if #menuItemPath == 2 then
            local menuItem = win:application():findMenuItem(menuItemPath)
            if menuItem == nil or not menuItem.enabled then return false end
          end
          menuItemPath[2] = localizedString('Close Tab', exBundleID,
                                            { locale = appLocale })
          if #menuItemPath == 2 then
            local menuItem = win:application():findMenuItem(menuItemPath)
            return menuItem and not menuItem.enabled
          end
        end
      },
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
      fn = receiveMenuItem
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
      bindCondition = versionRange("4", "4.0.6"),
      deleteOnDisable = true,
      windowFilter = {
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
          end
        end
      },
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
        return clickable(bt)
      end,
      fn = click
    },
    ["send"] = {
      message = localizedMessage("Send"),
      bindCondition = versionRange("4", "4.0.6"),
      windowFilter = {
        allowSheet = true,
        fn = function(win)
          local winUI = towinui(win)
          local title = localizedString("Send", win)
          local bt = getc(winUI, AX.Button, title)
          if bt == nil then
            title = localizedString("Send To (%d)", win)
            title = title:gsub("%(%%d%)", "%%(%%d%%)")
            bt = tfind(getc(winUI, AX.Button), function(b)
              return b.AXTitle:match(title)
            end)
          end
          return bt ~= nil
        end
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = localizedString("Send", win)
        local bt = getc(towinui(win), AX.Button, title)
        if bt == nil then
          title = localizedString("Send To (%d)", win)
          title = title:gsub("%(%%d%)", "%%(%%d%%)")
          bt = tfind(getc(winUI, AX.Button), function(b)
            return b.AXTitle:match(title)
          end)
        end
        if bt and bt.AXEnabled then
          -- `WeChat` accessibility bug
          local ref = getc(winUI, AX.List, 1)
          if ref.AXPosition.x < winUI.AXPosition.x then
            return clickable(winUI, {
              bt.AXPosition.x - ref.AXPosition.x + bt.AXSize.w / 2,
              winUI.AXSize.h - 13 - bt.AXSize.h / 2
                  - (ref.AXPosition.y + ref.AXSize.h - bt.AXPosition.y - bt.AXSize.h)
            })
          else
            return clickable(bt)
          end
        end
      end,
      fn = click
    },
    ["confirmAll"] = {
      message = commonLocalizedMessage("Confirm"),
      bindCondition = versionGreaterEqual("4.0.6"),
      windowFilter = { allowSheet = true },
      condition = function(win)
        local frame = win:frame()
        return clickable(towinui(win), { frame.w - 80, frame.h - 47 })
      end,
      fn = click
    }
  },

  ["com.tencent.QQMusicMac"] =
  {
    ["back"] = {
      message = "后退",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local titleBar
        if versionLessThan("10.3.0")(app) then
          local appUI = toappui(app)
          local frame = app:focusedWindow():frame()
          titleBar = appUI:elementAtPosition(frame.x + 100, frame.y + 10)
        else
          local winUI = towinui(app:focusedWindow())
          titleBar = getc(winUI, AX.Unknown, 3)
          if titleBar == nil then return false end
        end
        for _, button in ipairs(titleBar) do
          if button.AXHelp == "后退" then
            return true, button
          end
        end
        return false
      end,
      repeatable = true,
      fn = function(button, app)
        leftClickAndRestore(button, app, 0.1)
      end
    },
    ["forward"] = {
      message = "前进",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local titleBar
        if versionLessThan("10.3.0")(app) then
          local appUI = toappui(app)
          local frame = app:focusedWindow():frame()
          titleBar = appUI:elementAtPosition(frame.x + 100, frame.y + 10)
        else
          local winUI = towinui(app:focusedWindow())
          titleBar = getc(winUI, AX.Unknown, 3)
          if titleBar == nil then return false end
        end
        for _, button in ipairs(titleBar) do
          if button.AXHelp == "前进" then
            return true, button
          end
        end
        return false
      end,
      repeatable = true,
      fn = function(button, app)
        leftClickAndRestore(button, app, 0.1)
      end
    },
    ["refresh"] = {
      message = "刷新",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local titleBar
        if versionLessThan("10.3.0")(app) then
          local appUI = toappui(app)
          local frame = app:focusedWindow():frame()
          titleBar = appUI:elementAtPosition(frame.x + 100, frame.y + 10)
        else
          local winUI = towinui(app:focusedWindow())
          titleBar = getc(winUI, AX.Unknown, 3)
          if titleBar == nil then return false end
        end
        local refreshButton, searchButton
        for _, button in ipairs(titleBar) do
          if button.AXHelp == "刷新" then
            refreshButton = button
          elseif button.AXHelp == nil then
            searchButton = button
          end
        end
        return refreshButton ~= nil and searchButton ~= nil
            and refreshButton.AXPosition.x ~= searchButton.AXPosition.x,
            refreshButton
      end,
      fn = function(button, app)
        leftClickAndRestore(button, app, 0.1)
      end
    },
    ["playBarCloseSingleSong"] = {
      message = "关闭单曲",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        if versionLessThan("9")(app) then
          local winUI = towinui(app:focusedWindow())
          local buttons = getc(winUI, AX.Button)
          return #buttons > 4 and getc(winUI, AX.Button, '歌曲详情') ~= nil
        else
          if #app:visibleWindows() < 2 then return false end
          local fWin, mWin = app:focusedWindow(), app:mainWindow()
          local fFrame, mFrame = fWin:frame(), mWin:frame()
          return fWin:id() ~= mWin:id()
              and fFrame.x == mFrame.x and fFrame.y == mFrame.y
              and fFrame.w == mFrame.w and fFrame.h == mFrame.h
        end
      end,
      fn = function(app)
        local winUI = towinui(app:focusedWindow())
        local buttons = getc(winUI, AX.Button)
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
        local menuItem = getc(menuBarItem, AX.Menu, 1, AX.MenuItem, '最近打开')
        if menuItem ~= nil then
          press(menuBarItem)
          press(menuItem)
        end
      end
    },
    ["channel1"] = {
      message = getQQLiveChannelName(1),
      windowFilter = QQLiveMainWindowFilter,
      condition = getQQLiveChannel(1),
      fn = click
    },
    ["channel2"] = {
      message = getQQLiveChannelName(2),
      windowFilter = QQLiveMainWindowFilter,
      condition = getQQLiveChannel(2),
      fn = click
    },
    ["channel3"] = {
      message = getQQLiveChannelName(3),
      windowFilter = QQLiveMainWindowFilter,
      condition = getQQLiveChannel(3),
      fn = click
    },
    ["channel4"] = {
      message = getQQLiveChannelName(4),
      windowFilter = QQLiveMainWindowFilter,
      condition = getQQLiveChannel(4),
      fn = click
    },
    ["channel5"] = {
      message = getQQLiveChannelName(5),
      windowFilter = QQLiveMainWindowFilter,
      condition = getQQLiveChannel(5),
      fn = click
    },
    ["channel6"] = {
      message = getQQLiveChannelName(6),
      windowFilter = QQLiveMainWindowFilter,
      condition = getQQLiveChannel(6),
      fn = click
    },
    ["channel7"] = {
      message = getQQLiveChannelName(7),
      windowFilter = QQLiveMainWindowFilter,
      condition = getQQLiveChannel(7),
      fn = click
    },
    ["channel8"] = {
      message = getQQLiveChannelName(8),
      windowFilter = QQLiveMainWindowFilter,
      condition = getQQLiveChannel(8),
      fn = click
    },
    ["channel9"] = {
      message = getQQLiveChannelName(9),
      windowFilter = QQLiveMainWindowFilter,
      condition = getQQLiveChannel(9),
      fn = click
    },
    ["channel10"] = {
      message = getQQLiveChannelName(10),
      windowFilter = QQLiveMainWindowFilter,
      condition = getQQLiveChannel(10),
      fn = click
    }
  },

  ["com.tencent.meeting"] =
  {
    ["preferences"] = {
      message = localizedMessage("Preferences"),
      fn = function(app)
        local title = localizedString("Preferences", app)
        app:selectMenuItem({ app:name(), title })
      end
    }
  },

  ["com.bytedance.douyin.desktop"] =
  {
    ["settings"] = {
      message = "设置",
      fn = function(app)
        app:selectMenuItem({ app:name(), "设置" })
      end
    },
    ["showMainWindow"] = {
      message = "抖音窗口",
      fn = function(app)
        app:selectMenuItem({ "窗口", "抖音窗口" })
      end
    }
  },

  ["com.tencent.LemonMonitor"] =
  {
    ["closeWindow"] = {
      mods = "", key = "Escape",
      message = commonLocalizedMessage("Close Window"),
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
      message = localizedMessage('Uninstall'),
      condition = buttonValidForAppCleanerUninstaller('Uninstall'),
      fn = press
    },
    ["remove"] = {
      message = localizedMessage('Remove'),
      condition = buttonValidForAppCleanerUninstaller('Remove'),
      fn = press
    },
    ["enable"] = {
      message = localizedMessage('Enable'),
      condition = buttonValidForAppCleanerUninstaller('Enable'),
      fn = press
    },
    ["disable"] = {
      message = localizedMessage('Disable'),
      condition = buttonValidForAppCleanerUninstaller('Disable'),
      fn = press
    },
    ["update"] = {
      message = localizedMessage('Update'),
      condition = buttonValidForAppCleanerUninstaller('Update'),
      fn = press
    },
    ["launchApp"] = {
      message = localizedMessage('Launch App'),
      bindCondition = versionGreaterEqual("8.6"),
      condition = buttonValidForAppCleanerUninstaller('Launch App'),
      fn = press
    },
    ["confirmRemove"] = {
      message = localizedMessage('Remove'),
      condition = confirmButtonValidForAppCleanerUninstaller('Remove'),
      fn = function(position) leftClick(position) end  -- fixme: false click
    },
    ["confirmUpdate"] = {
      message = localizedMessage('Update'),
      condition = confirmButtonValidForAppCleanerUninstaller('Update'),
      fn = function(position) leftClick(position) end  -- fixme: false click
    },
    ["confirmRetry"] = {
      message = localizedMessage('Retry'),
      condition = confirmButtonValidForAppCleanerUninstaller('Retry'),
      fn = function(position) leftClick(position) end  -- fixme: false click
    }
  },

  ["com.nektony.App-Cleaner-SIIICn"] =
  {
    ["remove"] = {
      message = localizedMessage('Remove_Button_Title'),
      condition = buttonValidForAppCleanerUninstaller('Remove_Button_Title'),
      fn = press
    },
    ["enable"] = {
      message = localizedMessage('EnableMenuItemTitle'),
      condition = buttonValidForAppCleanerUninstaller('EnableMenuItemTitle'),
      fn = press
    },
    ["disable"] = {
      message = localizedMessage('DisableMenuItemTitle'),
      condition = buttonValidForAppCleanerUninstaller('DisableMenuItemTitle'),
      fn = press
    },
    ["update"] = {
      message = localizedMessage('UpdateButtonTitle'),
      condition = buttonValidForAppCleanerUninstaller('UpdateButtonTitle'),
      fn = press
    },
    ["launchApp"] = {
      message = localizedMessage('LaunchAppButtonTitle'),
      bindCondition = versionGreaterEqual("8.6"),
      condition = buttonValidForAppCleanerUninstaller('LaunchAppButtonTitle'),
      fn = press
    },
    ["confirmRemove"] = {
      message = localizedMessage('PartialRemove_Remove'),
      condition = confirmButtonValidForAppCleanerUninstaller('PartialRemove_Remove'),
      fn = function(position) leftClick(position) end  -- fixme: false click
    },
    ["confirmUpdate"] = {
      message = localizedMessage('UpdateButtonTitle'),
      condition = confirmButtonValidForAppCleanerUninstaller('UpdateButtonTitle'),
      fn = function(position) leftClick(position) end  -- fixme: false click
    },
    ["confirmRetry"] = {
      message = localizedMessage('PartialRemove_Retry'),
      condition = confirmButtonValidForAppCleanerUninstaller('PartialRemove_Retry'),
      fn = function(position) leftClick(position) end  -- fixme: false click
    }
  },

  ["com.charliemonroe.Downie-4"] =
  {
    ["openRecent"] = {
      message = localizedMessage("Show History"),
      condition = checkMenuItem({ "Window", "Show History" }),
      fn = receiveMenuItem
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
        local start = getc(menu, AX.MenuItem, "Start")
        if start == nil then return end
        if start.AXEnabled then
          press(start)
          hs.alert("Barrier started")
        else
          local stop = getc(menu, AX.MenuItem, "Stop")
          if stop == nil then return end
          press(stop)
          hs.alert("Barrier stopped")
        end
      end,
      onLaunch = function(app)
        if app:focusedWindow() == nil then
          hs.alert("Error occurred")
        else
          local winUI = towinui(app:focusedWindow())
          local start = getc(winUI, AX.Button, "Start")
          if start == nil then return end
          press(start)
          hs.alert("Barrier started")
          hs.timer.doAfter(0.5, function()
            local close = getc(winUI, AX.Button, 4)
            if close == nil then return end
            press(close)
          end)
        end
      end
    },
    ["changeSettings"] = {
      message = barrierLocalizedMessage("Change &Settings"),
      condition = function(app)
        local menuBarItems = getMenuBarItems(app, true)
        local menuBarItem = tfind(menuBarItems, function(item)
          return item.AXTitle == "Barrier"
        end)
        local title = localizedString("Change &Settings", app) or "Change &Settings"
        title = title:gsub("%(&%a%)", ""):gsub("&", "")
        local menuItem = getc(menuBarItem, AX.Menu, 1, AX.MenuItem, title)
        return menuItem and menuItem.AXEnabled, menuItem
      end,
      fn = press
    },
    ["reload"] = {
      message = barrierLocalizedMessage("&Reload"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = barrierLocalizedString("&Reload", win)
        local reload = getc(winUI, AX.Button, title)
        return reload ~= nil and #reload:actionNames() > 0, reload
      end,
      fn = press
    },
    ["start"] = {
      message = barrierLocalizedMessage("&Start"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = barrierLocalizedString("&Start", win)
        local start = getc(winUI, AX.Button, title)
        return start ~= nil and #start:actionNames() > 0, start
      end,
      fn = press
    },
    ["stop"] = {
      message = barrierLocalizedMessage("&Stop"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = barrierLocalizedString("&Stop", win)
        local stop = getc(winUI, AX.Button, title)
        return stop ~= nil and #stop:actionNames() > 0, stop
      end,
      fn = press
    },
    ["serverMode"] = {
      message = barrierLocalizedMessage("&Server (share this computer's mouse and keyboard)"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      fn = function(win)
        local winUI = towinui(win)
        local server = getc(winUI, AX.CheckBox, 1)
        if server then press(server) end
      end
    },
    ["clientMode"] = {
      message = barrierLocalizedMessage("&Client (use another computer's mouse and keyboard):"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      fn = function(win)
        local winUI = towinui(win)
        local client = getc(winUI, AX.CheckBox, 2)
        if client then press(client) end
      end
    },
    ["configureInteractively"] = {
      message = barrierLocalizedMessage("Configure interactively:"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = barrierLocalizedString("Configure interactively:", win)
        local configure = getc(winUI, AX.CheckBox, 1, AX.RadioButton, title)
        return configure ~= nil and #configure:actionNames() > 0, configure
      end,
      fn = press
    },
    ["useExistingConfiguration"] = {
      message = barrierLocalizedMessage("Use existing configuration:"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = barrierLocalizedString("Use existing configuration:", win)
        local configure = getc(winUI, AX.CheckBox, 1, AX.RadioButton, title)
        return configure ~= nil and #configure:actionNames() > 0, configure
      end,
      fn = press
    },
    ["configureServer"] = {
      message = barrierLocalizedMessage("&Configure Server..."),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = barrierLocalizedString("&Configure Server...", win)
        local configure = getc(winUI, AX.CheckBox, 1, AX.Button, title)
        return configure ~= nil and #configure:actionNames() > 0, configure
      end,
      fn = press
    },
    ["configurationFile"] = {
      message = barrierLocalizedMessage("&Configuration file:"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = barrierLocalizedString("&Configuration file:", win)
        local textField = getc(winUI, AX.CheckBox, 1, AX.TextField, title)
        return textField ~= nil and #textField:actionNames() > 0, textField
      end,
      fn = function(textField)
        textField:performAction(AX.Raise)
      end
    },
    ["browse"] = {
      message = barrierLocalizedMessage("&Browse..."),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = barrierLocalizedString("&Browse...", win)
        local browse = getc(winUI, AX.CheckBox, 1, AX.Button, title)
        return browse ~= nil and #browse:actionNames() > 0, browse
      end,
      fn = press
    },
    ["autoConfig"] = {
      message = barrierLocalizedMessage("Auto config"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = barrierLocalizedString("Auto config", win)
        local autoconfig = getc(winUI, AX.CheckBox, 2, AX.CheckBox, title)
        return autoconfig ~= nil and #autoconfig:actionNames() > 0, autoconfig
      end,
      fn = function(checkbox, win)
        local toSpecify = checkbox.AXValue == 1
        press(checkbox)
        if toSpecify then
          local title = barrierLocalizedString("&Server IP:", win)
          local textField = getc(towinui(win), AX.CheckBox, 2, AX.TextField, title)
          if textField then
            textField:performAction(AX.Raise)
          end
        end
      end
    },
    ["showMainWindow"] = {
      message = barrierLocalizedMessage("Show"),
      menubarFilter = { allowIndices =  1 },
      condition = function(menu)
        local app = getAppFromDescendantElement(menu)
        local title = localizedString("Show", app) or "Show"
        local menuItem = getc(menu, AX.MenuItem, title)
        return menuItem and menuItem.AXEnabled, menuItem
      end,
      fn = press
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
  },

  ["com.objective-see.lulu.app"] =
  {
    ["allowConnection"] = {
      message = "Allow Connection",
      bindCondition = versionLessThan("2.9.1"),
      windowFilter = {
        allowTitles = "^LuLu Alert$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, "Allow")
        return button ~= nil, button
      end,
      fn = press
    },
    ["blockConnection"] = {
      message = "Block Connection",
      bindCondition = versionLessThan("2.9.1"),
      windowFilter = {
        allowTitles = "^LuLu Alert$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, "Block")
        return button ~= nil, button
      end,
      fn = press
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
        local button = getc(winUI, AX.Button, "Save")
        return button and button.AXEnabled, button
      end,
      fn = press
    }
  },

  ["com.surteesstudios.Bartender"] =
  {
    ["toggleMenuBar"] = {
      message = "Toggle Menu Bar",
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        hs.osascript.applescript(strfmt([[
          tell application id "%s" to toggle bartender
        ]], app:bundleID()))
      end
    },
    ["click1stBartenderBarItem"] = {
      message = getBartenderBarItemTitle(1),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(1)
    },
    ["rightClick1stBartenderBarItem"] = {
      message = getBartenderBarItemTitle(1, true),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(1, true)
    },
    ["click2ndBartenderBarItem"] = {
      message = getBartenderBarItemTitle(2),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(2)
    },
    ["rightClick2ndBartenderBarItem"] = {
      message = getBartenderBarItemTitle(2, true),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(2, true)
    },
    ["click3rdBartenderBarItem"] = {
      message = getBartenderBarItemTitle(3),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(3)
    },
    ["rightClick3rdBartenderBarItem"] = {
      message = getBartenderBarItemTitle(3, true),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(3, true)
    },
    ["click4thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(4),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(4)
    },
    ["rightClick4thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(4, true),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(4, true)
    },
    ["click5thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(5),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(5)
    },
    ["rightClick5thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(5, true),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(5, true)
    },
    ["click6thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(6),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(6)
    },
    ["rightClick6thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(6, true),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(6, true)
    },
    ["click7thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(7),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(7)
    },
    ["rightClick7thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(7, true),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(7, true)
    },
    ["click8thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(8),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(8)
    },
    ["rightClick8thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(8, true),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(8, true)
    },
    ["click9thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(9),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(9)
    },
    ["rightClick9thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(9, true),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(9, true)
    },
    ["click10thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(10),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(10)
    },
    ["rightClick10thBartenderBarItem"] = {
      message = getBartenderBarItemTitle(10, true),
      windowFilter = bartenderBarWindowFilter,
      background = true,
      fn = clickBartenderBarItem(10, true)
    },
    ["searchMenuBar"] = {
      message = "Search Menu Bar",
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
    ["view1"] =
    {
      message = getBartenderSidebarItemTitle(1),
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(1)
    },
    ["view2"] =
    {
      message = getBartenderSidebarItemTitle(2),
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(2)
    },
    ["view3"] =
    {
      message = getBartenderSidebarItemTitle(3),
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(3)
    },
    ["view4"] =
    {
      message = getBartenderSidebarItemTitle(4),
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(4)
    },
    ["view5"] =
    {
      message = getBartenderSidebarItemTitle(5),
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(5)
    },
    ["view6"] =
    {
      message = getBartenderSidebarItemTitle(6),
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(6)
    },
    ["view7"] =
    {
      message = getBartenderSidebarItemTitle(7),
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(7)
    },
    ["view8"] =
    {
      message = getBartenderSidebarItemTitle(8),
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(8)
    },
    ["view9"] =
    {
      message = getBartenderSidebarItemTitle(9),
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(9)
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
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
      message = commonLocalizedMessage("Show Sidebar"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local button = tfind(getc(towinui(app:focusedWindow()),
                                  AX.Toolbar, 1, AX.Button) or {},
            function(bt) return bt.AXDescription == "Sidebar" end)
        return button ~= nil, button
      end,
      fn = press
    },
    ["click1stBarbeeBarItem"] = {
      message = getBarbeeBarItemTitle(1),
      windowFilter = barbeeBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickBarbeeBarItem(1)
    },
    ["click2ndBarbeeBarItem"] = {
      message = getBarbeeBarItemTitle(2),
      windowFilter = barbeeBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickBarbeeBarItem(2)
    },
    ["click3rdBarbeeBarItem"] = {
      message = getBarbeeBarItemTitle(3),
      windowFilter = barbeeBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickBarbeeBarItem(3)
    },
    ["click4thBarbeeBarItem"] = {
      message = getBarbeeBarItemTitle(4),
      windowFilter = barbeeBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickBarbeeBarItem(4)
    },
    ["click5thBarbeeBarItem"] = {
      message = getBarbeeBarItemTitle(5),
      windowFilter = barbeeBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickBarbeeBarItem(5)
    },
    ["click6thBarbeeBarItem"] = {
      message = getBarbeeBarItemTitle(6),
      windowFilter = barbeeBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickBarbeeBarItem(6)
    },
    ["click7thBarbeeBarItem"] = {
      message = getBarbeeBarItemTitle(7),
      windowFilter = barbeeBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickBarbeeBarItem(7)
    },
    ["click8thBarbeeBarItem"] = {
      message = getBarbeeBarItemTitle(8),
      windowFilter = barbeeBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickBarbeeBarItem(8)
    },
    ["click9thBarbeeBarItem"] = {
      message = getBarbeeBarItemTitle(9),
      windowFilter = barbeeBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickBarbeeBarItem(9)
    },
    ["click10thBarbeeBarItem"] = {
      message = getBarbeeBarItemTitle(10),
      windowFilter = barbeeBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickBarbeeBarItem(10)
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["quit"] = specialCommonHotkeyConfigs["quit"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
  },

  ["com.jordanbaird.Ice"] =
  {
    ["click1stIceBarItem"] = {
      message = getIceBarItemTitle(1),
      windowFilter = iceBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickIceBarItem(1)
    },
    ["click2ndIceBarItem"] = {
      message = getIceBarItemTitle(2),
      windowFilter = iceBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickIceBarItem(2)
    },
    ["click3rdIceBarItem"] = {
      message = getIceBarItemTitle(3),
      windowFilter = iceBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickIceBarItem(3)
    },
    ["click4thIceBarItem"] = {
      message = getIceBarItemTitle(4),
      windowFilter = iceBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickIceBarItem(4)
    },
    ["click5thIceBarItem"] = {
      message = getIceBarItemTitle(5),
      windowFilter = iceBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickIceBarItem(5)
    },
    ["click6thIceBarItem"] = {
      message = getIceBarItemTitle(6),
      windowFilter = iceBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickIceBarItem(6)
    },
    ["click7thIceBarItem"] = {
      message = getIceBarItemTitle(7),
      windowFilter = iceBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickIceBarItem(7)
    },
    ["click8thIceBarItem"] = {
      message = getIceBarItemTitle(8),
      windowFilter = iceBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickIceBarItem(8)
    },
    ["click9thIceBarItem"] = {
      message = getIceBarItemTitle(9),
      windowFilter = iceBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickIceBarItem(9)
    },
    ["click10thIceBarItem"] = {
      message = getIceBarItemTitle(10),
      windowFilter = iceBarWindowFilter,
      background = true,
      nonFrontmost = true,
      fn = clickIceBarItem(10)
    },
    ["view1"] = {
      message = getIceSidebarItemTitle(1),
      windowFilter = iceSettingsWindowFilter,
      fn = clickIceSidebarItem(1)
    },
    ["view2"] = {
      message = getIceSidebarItemTitle(2),
      windowFilter = iceSettingsWindowFilter,
      fn = clickIceSidebarItem(2)
    },
    ["view3"] = {
      message = getIceSidebarItemTitle(3),
      windowFilter = iceSettingsWindowFilter,
      fn = clickIceSidebarItem(3)
    },
    ["view4"] = {
      message = getIceSidebarItemTitle(4),
      windowFilter = iceSettingsWindowFilter,
      fn = clickIceSidebarItem(4)
    },
    ["view5"] = {
      message = getIceSidebarItemTitle(5),
      windowFilter = iceSettingsWindowFilter,
      fn = clickIceSidebarItem(5)
    },
    ["view6"] = {
      message = getIceSidebarItemTitle(6),
      windowFilter = iceSettingsWindowFilter,
      fn = clickIceSidebarItem(6)
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
          hs.eventtap.event.newMouseEvent(
              hs.eventtap.event.types.mouseMoved, uioffset(icon, {-10, 10})):post()
          hs.timer.doAfter(0.2, function()
            hs.eventtap.event.newMouseEvent(
                hs.eventtap.event.types.mouseMoved, uioffset(icon, {-20, 10})):post()
            hs.timer.doAfter(0.2, function()
              hs.eventtap.event.newMouseEvent(
                  hs.eventtap.event.types.mouseMoved, position):post()
            end)
          end)
        else
          leftClickAndRestore(icon, app)
        end
      end
    },
    ["click1stiBarItem"] = {
      message = getiBarItemTitle(1),
      windowFilter = iBarWindowFilter,
      background = true,
      fn = clickiBarItem(1)
    },
    ["click2ndiBarItem"] = {
      message = getiBarItemTitle(2),
      windowFilter = iBarWindowFilter,
      background = true,
      fn = clickiBarItem(2)
    },
    ["click3rdiBarItem"] = {
      message = getiBarItemTitle(3),
      windowFilter = iBarWindowFilter,
      background = true,
      fn = clickiBarItem(3)
    },
    ["click4thiBarItem"] = {
      message = getiBarItemTitle(4),
      windowFilter = iBarWindowFilter,
      background = true,
      fn = clickiBarItem(4)
    },
    ["click5thiBarItem"] = {
      message = getiBarItemTitle(5),
      windowFilter = iBarWindowFilter,
      background = true,
      fn = clickiBarItem(5)
    },
    ["click6thiBarItem"] = {
      message = getiBarItemTitle(6),
      windowFilter = iBarWindowFilter,
      background = true,
      fn = clickiBarItem(6)
    },
    ["click7thiBarItem"] = {
      message = getiBarItemTitle(7),
      windowFilter = iBarWindowFilter,
      background = true,
      fn = clickiBarItem(7)
    },
    ["click8thiBarItem"] = {
      message = getiBarItemTitle(8),
      windowFilter = iBarWindowFilter,
      background = true,
      fn = clickiBarItem(8)
    },
    ["click9thiBarItem"] = {
      message = getiBarItemTitle(9),
      windowFilter = iBarWindowFilter,
      background = true,
      fn = clickiBarItem(9)
    },
    ["click10thiBarItem"] = {
      message = getiBarItemTitle(10),
      windowFilter = iBarWindowFilter,
      background = true,
      fn = clickiBarItem(10)
    }
  },

  ["com.app.menubarx"] =
  {
    ["toggleMenuBarX"] = {
      message = "Toggle MenuBarX",
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
    ["preferencesInMenuBarMenu"] = {
      message = function(app)
        return app:name() .. ' > ' .. localizedString('Preferences', app)
      end,
      menubarFilter = { allowTitles = 'eul' },
      fn = function(menu)
        local app = getAppFromDescendantElement(menu)
        local prefString = localizedString('Preferences', app)
        local button = getc(menu, AX.MenuItem, 1, AX.Group, 1,
            AX.StaticText, prefString)
        leftClickAndRestore(button, app, 0.2)
      end
    }
  },

  ["whbalzac.Dongtaizhuomian"] =
  {
    ["invokeInAppScreenSaver"] = {
      message = localizedMessage("In-app Screensaver",
                                { localeFile = "HotkeyWindowController" }),
      background = true,
      fn = function(app)
        clickRightMenuBarItem(app,
            localizedString("In-app Screensaver", app,
                            { localeFile = "HotkeyWindowController" }))
      end
    },
    ["preferences"] = {
      message = localizedMessage("Preferences..."),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local app = getAppFromDescendantElement(menu)
        local title = localizedString("Preferences...", app)
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then press(menuItem) end
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
          press(switch)
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
    ["openKeyboardSettings"] = {
      message = function(app, menu)
        local menuItem = getc(menu, AX.MenuItem, -1)
        if menuItem then
          return getc(menu, AX.MenuItem, -1).AXTitle
        end
      end,
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local menuItem = getc(menu, AX.MenuItem, -1)
        press(menuItem)
      end
    }
  },

  ["com.apple.Passwords"] = {
    ["search"] = {
      message = localizedMessage("Search"),
      bindCondition = function() return OS_VERSION >= OS.Tahoe end,
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local searchButton = getc(towinui(app:focusedWindow()),
            AX.Toolbar, 1, AX.Group, -1, AX.TextField, 1, AX.Button, 1)
        return clickable(searchButton)
      end,
      fn = click
    }
  },

  ["com.apple.Passwords.MenuBarExtra"] =
  {
    ["showPasswordsDialog"] = {
      message = "Show Passwords Dialog",
      background = true,
      fn = clickRightMenuBarItem
    },
    ["newPassword"] = {
      message = localizedMessage("New Password"),
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Group, 1, AX.Button, 'plus')
        return button ~= nil, button
      end,
      background = true,
      fn = press
    },
    ["showAllPasswords"] = {
      message = localizedMessage("Show all passwords"),
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Group, 1, AX.Button, 'macwindow')
        return button ~= nil, button
      end,
      background = true,
      fn = press
    },
    ["back"] = {
      message = localizedMessage("Back"),
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local elem = getc(winUI, AX.Group, 1)[1]
        return elem.AXRole == AX.Button, elem
      end,
      background = true,
      fn = press
    },
    ["copyUserName"] = {
      message = localizedMessage("Copy User Name"),
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local elem = getc(winUI, AX.Group, 1)[1]
        return elem.AXRole == AX.Button
      end,
      background = true,
      fn = function(win)
        local winUI = towinui(win)
        local outline
        if OS_VERSION >= OS.Tahoe then
          outline = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
              AX.ScrollArea, 1, AX.Outline, 1)
        else
          outline = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
              AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1)
        end
        local field = getc(outline, AX.Row, 2, AX.Cell, 1, AX.StaticText, 2)
        if field then
          leftClickAndRestore(field, win)
          clickRightMenuBarItem(win:application())
        end
      end
    },
    ["copyPassword"] = {
      message = localizedMessage("Copy Password"),
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local elem = getc(winUI, AX.Group, 1)[1]
        return elem.AXRole == AX.Button
      end,
      background = true,
      fn = function(win)
        local winUI = towinui(win)
        local outline
        if OS_VERSION >= OS.Tahoe then
          outline = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
              AX.ScrollArea, 1, AX.Outline, 1)
        else
          outline = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
              AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1)
        end
        local field
        if getc(outline, AX.Row, 3, AX.Cell, 1, AX.StaticText, 1).AXValue
            == localizedString("Password", win) then
          field = getc(outline, AX.Row, 3, AX.Cell, 1, AX.StaticText, 2)
        else
          field = getc(outline, AX.Row, 4, AX.Cell, 1, AX.StaticText, 2)
        end
        if field then
          leftClickAndRestore(field, win)
          clickRightMenuBarItem(win:application())
        end
      end
    },
    ["copyVerificationCode"] = {
      message = function(win)
        local title = OS_VERSION >= OS.Tahoe and "Copy Code"
            or "Copy Verification Code"
        return localizedMessage(title)(win)
      end,
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local elem = getc(winUI, AX.Group, 1)[1]
        if elem.AXRole ~= AX.Button then return false end
        local outline
        if OS_VERSION >= OS.Tahoe then
          outline = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
              AX.ScrollArea, 1, AX.Outline, 1)
        else
          outline = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
              AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1)
        end
        local cell = getc(outline, AX.Row, 5, AX.Cell, 1)
        local title = getc(cell, AX.StaticText, 1)
        local target = OS_VERSION >= OS.Tahoe and "Code" or "Verification Code"
        if title and title.AXValue == localizedString(target, win) then
          return true, getc(cell, AX.StaticText, 2)
        end
        return false
      end,
      background = true,
      fn = function(field, win)
        leftClickAndRestore(field, win)
        clickRightMenuBarItem(win:application())
      end
    },
    ["record1"] = {
      message = "Record 1",
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(1),
      background = true,
      fn = click
    },
    ["record2"] = {
      message = "Record 2",
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(2),
      background = true,
      fn = click
    },
    ["record3"] = {
      message = "Record 3",
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(3),
      background = true,
      fn = click
    },
    ["record4"] = {
      message = "Record 4",
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(4),
      background = true,
      fn = click
    },
    ["record5"] = {
      message = "Record 5",
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(5),
      background = true,
      fn = click
    },
    ["record6"] = {
      message = "Record 6",
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(6),
      background = true,
      fn = click
    },
    ["record7"] = {
      message = "Record 7",
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(7),
      background = true,
      fn = click
    },
    ["record8"] = {
      message = "Record 8",
      windowFilter = {
        allowRoles = AX.SystemDialog,
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(8),
      background = true,
      fn = click
    }
  },

  ["com.apple.weather.menu"] = {
    ["openWeather"] = {
      message = localizedMessage("Open Weather"),
      windowFilter = {
        allowRoles = AX.SystemDialog
      },
      background = true,
      fn = function(win)
        local button = getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Button, -1)
        if button then press(button) end
      end
    },
    ["closeWindow"] = {
      mods = "", key = "Escape",
      message = commonLocalizedMessage("Close Window"),
      bindCondition = function() return OS_VERSION < OS.Tahoe end,
      windowFilter = {
        allowRoles = AX.SystemDialog
      },
      background = true,
      fn = function(win)
        local menuBarItem = getc(toappui(win:application()),
            AX.MenuBar, -1, AX.MenuBarItem, 1)
        if menuBarItem then
          press(menuBarItem)
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
      fn = press
    }
  },

  ["org.pqrs.Karabiner-Menu"] =
  {
    ["settings"] = {
      message = "Settings...",
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local menuItem = getc(menu, AX.MenuItem, "Settings...")
        if menuItem then press(menuItem) end
      end
    }
  },

  ["org.pqrs.Karabiner-EventViewer"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"]
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
      message = localizedMessage("Open Recent"),
      condition = checkMenuItem({ "Game", "Open Recent" }),
      fn = receiveMenuItem
    },
  },

  ["com.apple.clock"] = {
    ["openRecent"] = {
      message = localizedMessage("Start Recent Timer"),
      condition = checkMenuItem({ "File", "Start Recent Timer" }),
      fn = receiveMenuItem
    },
  },

  ["com.apple.ScreenSharing"] =
  {
    ["openRecent"] = {
      message = localizedMessage("Open Recent"),
      condition = checkMenuItem({ "Connect", "Open Recent" }),
      fn = receiveMenuItem
    },
  },

  ["com.microsoft.rdc.macos"] = {
    ["toggleSidebar"] = {
      message = commonLocalizedMessage("Show Sidebar"),
      condition = function(app)
        if app:focusedWindow() == nil then return end
        local buttons = getc(towinui(app:focusedWindow()), AX.Toolbar, 1, AX.Button)
        if buttons == nil then return end
        local btTitle = localizedString("Sidebar", app)
        local button = tfind(buttons, function(bt)
          return bt.AXDescription == btTitle
        end)
        return button ~= nil, button
      end,
      fn = press
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
        return clickable(searchField, { 5, 5 })
      end,
      fn = click
    },
    ["toggleSidebar"] = {
      message = "Toggle sidebar",
      condition = checkMenuItem({ "View", "Show sidebar" }),
      fn = receiveMenuItem
    },
    ["toggleStatusBar"] = {
      message = "Toggle status bar",
      condition = checkMenuItem({ "View", "Show status bar" }),
      fn = receiveMenuItem
    }
  },

  ["com.parallels.desktop.console"] =
  {
    ["new..."] = {
      mods = "⌘", key = "N",
      message = localizedMessage("New..."),
      condition = checkMenuItem({ "File", "New..." }),
      fn = receiveMenuItem
    },
    ["open..."] = {
      mods = "⌘", key = "O",
      message = localizedMessage("Open..."),
      condition = checkMenuItem({ "File", "Open..." }),
      fn = receiveMenuItem
    },
    ["showControlCenter"] = {
      message = localizedMessage("Control Center"),
      condition = checkMenuItem({ "Window", "Control Center" }),
      fn = receiveMenuItem
    },
    ["expandedView"] = {
      message = localizedMessage("Expanded View"),
      windowFilter = ParallelsControlCenterWindowFilter,
      condition = checkMenuItem({ "View", "Expanded View" }),
      fn = receiveMenuItem
    },
    ["compactView"] = {
      message = localizedMessage("Compact View"),
      windowFilter = ParallelsControlCenterWindowFilter,
      condition = checkMenuItem({ "View", "Compact View" }),
      fn = receiveMenuItem
    },
    ["minimize"] = {
      mods = specialCommonHotkeyConfigs["minimize"].mods,
      key = specialCommonHotkeyConfigs["minimize"].key,
      message = localizedMessage("Minimize"),
      condition = checkMenuItem({ "Window", "Minimize" }),
      fn = receiveMenuItem
    },
    ["closeWindow"] = {
      mods = specialCommonHotkeyConfigs["closeWindow"].mods,
      key = specialCommonHotkeyConfigs["closeWindow"].key,
      message = localizedMessage("Close Window"),
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
      mods = specialCommonHotkeyConfigs["closeWindow"].mods,
      key = specialCommonHotkeyConfigs["closeWindow"].key,
      message = localizedMessage("Close"),
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
      message = localizedMessage("Preferences"),
      condition = checkMenuItem({ "Edit", "Preferences" }),
      fn = receiveMenuItem
    },
    ["quit"] = {
      message = localizedMessage("Quit"),
      condition = checkMenuItem({ "File", "Quit" }),
      fn = receiveMenuItem
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
      message = localizedMessage("Show In Finder"),
      condition = checkMenuItem({ "Actions", "Show In Finder" }),
      fn = receiveMenuItem
    }
  },

  ["com.apple.dt.Xcode"] =
  {
    ["showInFinder"] = {
      message = "Show in Finder",
      condition = checkMenuItem({ "File", "Show in Finder" }),
      fn = receiveMenuItem
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
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1, AX.Button, 1)
        end
        return clickable(button)
      end,
      fn = click
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      fn = bind(receiveMenuItem, {"File", "Open..."})
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
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1, AX.Button, 1)
        end
        return clickable(button)
      end,
      fn = click
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      fn = bind(receiveMenuItem, {"File", "Open..."})
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
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1, AX.Button, 1)
        end
        return clickable(button)
      end,
      fn = click
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to IntelliJ IDEA"
      },
      fn = bind(receiveMenuItem, {"File", "Open..."})
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
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1, AX.Button, 1)
        end
        return clickable(button)
      end,
      fn = click
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to PyCharm"
      },
      fn = bind(receiveMenuItem, {"File", "Open..."})
    }
  },

  ["org.qt-project.Designer"] =
  {
    ["openRecent"] = {
      message = localizedMessage("&Recent Forms"),
      condition = checkMenuItem({ "File", "&Recent Forms" }),
      fn = receiveMenuItem
    }
  },

  ["org.qt-project.Linguist"] =
  {
    ["openRecent"] = {
      message = localizedMessage("Recently Opened &Files"),
      condition = checkMenuItem({ "File", "Recently Opened &Files" }),
      fn = receiveMenuItem
    }
  },

  ["io.mountainduck"] =
  {
    ["preferencesInMenuBarMenu"] = {
      message = localizedMessage("Preferences…"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local app = getAppFromDescendantElement(menu)
        local title = localizedString("Preferences…", app)
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then press(menuItem) end
      end
    },
    ["openConnectionInMenuBarMenu"] = {
      message = localizedMessage("Open Connection…"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local app = getAppFromDescendantElement(menu)
        local title = localizedString("Open Connection…", app)
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then press(menuItem) end
      end
    },
    ["historyInMenuBarMenu"] = {
      message = localizedMessage("History"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local app = getAppFromDescendantElement(menu)
        local title = localizedString("History", app)
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then
          press(menu.AXParent)
          hs.eventtap.event.newMouseEvent(
            hs.eventtap.event.types.mouseMoved, uioffset(menuItem, { 20, 5 })):post()
          hs.timer.doAfter(0.1, function()
            hs.eventtap.event.newMouseEvent(
              hs.eventtap.event.types.mouseMoved, uioffset(menuItem, { 10, 5 })):post()
          end)
        end
      end
    },
    ["quitInMenuBarMenu"] = {
      message = function(app)
        local quit = localizedString("Quit", app)
        return quit .. ' ' .. app:name()
      end,
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local app = getAppFromDescendantElement(menu)
        local quit = localizedString("Quit", app)
        local title = quit .. ' ' .. app:name()
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then press(menuItem) end
      end
    }
  },

  ["org.adblockplus.adblockplussafarimac"] = {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.better365.BetterAndBetterHelper"] = {
    ["preferencesInMenuBarMenu"] = {
      message = localizedMessage("Preferences"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local app = getAppFromDescendantElement(menu)
        local title = localizedString("Preferences", app)
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then press(menuItem) end
      end
    }
  },

  ["cn.better365.iShotProHelper"] =
  {
    ["OCR"] = {
      message = "OCR",
      background = true,
      bindCondition = function()
        -- the property update in command line is overridden when app quits
        local appid = "cn.better365.iShotProHelper"
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
    ["preferencesInMenuBarMenu"] = {
      message = localizedMessage("Preferences"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local app = getAppFromDescendantElement(menu)
        local title = localizedString("Preferences", app)
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then press(menuItem) end
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
      message = localizedMessage("Setting"),
      windowFilter = iCopyWindowFilter,
      fn = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 1)
        if button ~= nil then press(button) end
      end
    },
    ["select1stItem"] = {
      mods = "⌘", key = "1",
      message = "Select 1st Item",
      bindCondition = versionLessThan("1.1.3"),
      windowFilter = iCopyWindowFilter,
      fn = iCopySelectHotkeyRemap(1)
    },
    ["select2ndItem"] = {
      mods = "⌘", key = "2",
      message = "Select 2nd Item",
      bindCondition = versionLessThan("1.1.3"),
      windowFilter = iCopyWindowFilter,
      fn = iCopySelectHotkeyRemap(2)
    },
    ["select3rdItem"] = {
      mods = "⌘", key = "3",
      message = "Select 3rd Item",
      bindCondition = versionLessThan("1.1.3"),
      windowFilter = iCopyWindowFilter,
      fn = iCopySelectHotkeyRemap(3)
    },
    ["select4thItem"] = {
      mods = "⌘", key = "4",
      message = "Select 4th Item",
      bindCondition = versionLessThan("1.1.3"),
      windowFilter = iCopyWindowFilter,
      fn = iCopySelectHotkeyRemap(4)
    },
    ["select5thItem"] = {
      mods = "⌘", key = "5",
      message = "Select 5th Item",
      bindCondition = versionLessThan("1.1.3"),
      windowFilter = iCopyWindowFilter,
      fn = iCopySelectHotkeyRemap(5)
    },
    ["select6thItem"] = {
      mods = "⌘", key = "6",
      message = "Select 6th Item",
      bindCondition = versionLessThan("1.1.3"),
      windowFilter = iCopyWindowFilter,
      fn = iCopySelectHotkeyRemap(6)
    },
    ["select7thItem"] = {
      mods = "⌘", key = "7",
      message = "Select 7th Item",
      bindCondition = versionLessThan("1.1.3"),
      windowFilter = iCopyWindowFilter,
      fn = iCopySelectHotkeyRemap(7)
    },
    ["select8thItem"] = {
      mods = "⌘", key = "8",
      message = "Select 8th Item",
      bindCondition = versionLessThan("1.1.3"),
      windowFilter = iCopyWindowFilter,
      fn = iCopySelectHotkeyRemap(8)
    },
    ["select9thItem"] = {
      mods = "⌘", key = "9",
      message = "Select 9th Item",
      bindCondition = versionLessThan("1.1.3"),
      windowFilter = iCopyWindowFilter,
      fn = iCopySelectHotkeyRemap(9)
    },
    ["select10thItem"] = {
      mods = "⌘", key = "0",
      message = "Select 10th Item",
      bindCondition = versionLessThan("1.1.3"),
      windowFilter = iCopyWindowFilter,
      fn = iCopySelectHotkeyRemap(10)
    },
    ["previousItem"] = {
      mods = "", key = "Left",
      message = "Previous Item",
      windowFilter = iCopyWindowFilter,
      repeatable = true,
      fn = function(win)
        hs.eventtap.keyStroke("", "Up", nil, win:application())
      end
    },
    ["nextItem"] = {
      mods = "", key = "Right",
      message = "Next Item",
      windowFilter = iCopyWindowFilter,
      repeatable = true,
      fn = function(win)
        hs.eventtap.keyStroke("", "Down", nil, win:application())
      end
    },
    ["cancelUp"] = {
      mods = "", key = "Up",
      message = "Cancel Up",
      windowFilter = iCopyWindowFilter,
      fn = function() end
    },
    ["cancelDown"] = {
      mods = "", key = "Down",
      message = "Cancel Down",
      windowFilter = iCopyWindowFilter,
      fn = function() end
    },
    ["cancelTap"] = {
      mods = "", key = "Tab",
      message = "Cancel Tab",
      windowFilter = iCopyWindowFilter,
      fn = function() end
    }
  }
}

local browserTabHotKeyCallbacks = {
  ["weiboNavigate1stCommonGroup"] = {
    message = weiboSideBarTitle(1, true),
    condition = weiboNavigateToSideBarCondition(1, true),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate2ndCommonGroup"] = {
    message = weiboSideBarTitle(2, true),
    condition = weiboNavigateToSideBarCondition(2, true),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate3rdCommonGroup"] = {
    message = weiboSideBarTitle(3, true),
    condition = weiboNavigateToSideBarCondition(3, true),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate4thCommonGroup"] = {
    message = weiboSideBarTitle(4, true),
    condition = weiboNavigateToSideBarCondition(4, true),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate1stCustomGroup"] = {
    message = weiboSideBarTitle(1),
    condition = weiboNavigateToSideBarCondition(1),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate2ndCustomGroup"] = {
    message = weiboSideBarTitle(2),
    condition = weiboNavigateToSideBarCondition(2),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate3rdCustomGroup"] = {
    message = weiboSideBarTitle(3),
    condition = weiboNavigateToSideBarCondition(3),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate4thCustomGroup"] = {
    message = weiboSideBarTitle(4),
    condition = weiboNavigateToSideBarCondition(4),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate5thCustomGroup"] = {
    message = weiboSideBarTitle(5),
    condition = weiboNavigateToSideBarCondition(5),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate6thCustomGroup"] = {
    message = weiboSideBarTitle(6),
    condition = weiboNavigateToSideBarCondition(6),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate7thCustomGroup"] = {
    message = weiboSideBarTitle(7),
    condition = weiboNavigateToSideBarCondition(7),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate8thCustomGroup"] = {
    message = weiboSideBarTitle(8),
    condition = weiboNavigateToSideBarCondition(8),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate9thCustomGroup"] = {
    message = weiboSideBarTitle(9),
    condition = weiboNavigateToSideBarCondition(9),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate10thCustomGroup"] = {
    message = weiboSideBarTitle(10),
    condition = weiboNavigateToSideBarCondition(10),
    fn = weiboNavigateToSideBar
  },

  ["douyinNavigate1stTab"] = {
    message = douyinTabTitle(1),
    condition = douyinNavigateToTabCondition(1),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate2ndTab"] = {
    message = douyinTabTitle(2),
    condition = douyinNavigateToTabCondition(2),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate3rdTab"] = {
    message = douyinTabTitle(3),
    condition = douyinNavigateToTabCondition(3),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate4thTab"] = {
    message = douyinTabTitle(4),
    condition = douyinNavigateToTabCondition(4),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate5thTab"] = {
    message = douyinTabTitle(5),
    condition = douyinNavigateToTabCondition(5),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate6thTab"] = {
    message = douyinTabTitle(6),
    condition = douyinNavigateToTabCondition(6),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate7thTab"] = {
    message = douyinTabTitle(7),
    condition = douyinNavigateToTabCondition(7),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate8thTab"] = {
    message = douyinTabTitle(8),
    condition = douyinNavigateToTabCondition(8),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate9thTab"] = {
    message = douyinTabTitle(9),
    condition = douyinNavigateToTabCondition(9),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate10thTab"] = {
    message = douyinTabTitle(10),
    condition = douyinNavigateToTabCondition(10),
    fn = douyinNavigateToTab
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
    local appInstalled = hs.application.pathForBundleID(appid) ~= nil
        and hs.application.pathForBundleID(appid) ~= ""
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local bindable
    if isPersistent and appInstalled then
      bindable = function()
        return cfg.bindCondition == nil or cfg.bindCondition()
      end
    else
      bindable = function()
        if not running then return false end
        if app == nil then
          if FLAGS["LOADING"] then
            app = runningAppsOnLoading[appid]
          else
            find(appid)
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
            hs.timer.doAfter(1, function()
              if find(appid) then
                local cb = cfg.onLaunch or cfg.fn
                cb(find(appid))
              end
            end)
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

MenuBarMenuSelectedObservers = {}
-- note: this process takes a long time for each app
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
          -- assume last menubar menu is closed before next menubar menu is opened
          FLAGS["RIGHT_MENUBAR_ITEM_SELECTED"] = false
        else
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
      stopOnTerminated(appid, observer, function()
        MenuBarMenuSelectedObservers[appid] = nil
      end)
      return menuBarItems
    end
  end
end

WindowCreatedSinceFilter = hs.window.filter.new(true)
local windowCreatedSinceTime = {}

local function resendToFocusedUIElement(cond, nonFrontmostWindow)
  return function(obj)
    local focusedApp = hs.axuielement.systemWideElement().AXFocusedApplication
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
      if focusedApp:asHSApplication():bundleID() ~= app:bundleID() then
        return false, CF.uIElementNotFocused
      end
    end
    return cond(obj)
  end
end

-- check whether the menu bar item is selected
-- if a menu is extended, hotkeys with no modifiers are disabled
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

-- if a text field with value is focused, hotkeys with no modifiers are disabled
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
        succ, result = f()
        if succ then return end
        menuItemNotFound = menuItemNotFound
            or result == CF.noMenuItemMatchKeybinding
      end
      cb = cb.previous
    end
    local mods, key = config.mods, config.key
    if menuItemNotFound then
      hs.eventtap.keyStroke(mods, key, nil, app)
    else
      -- most of the time, directly selecting menu item costs less time than key strokes
      selectMenuItemOrKeyStroke(app, mods, key)
    end
  end
end

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
    -- if a menu is extended, hotkeys with no modifiers are disabled
    if mods == nil or mods == "" or #mods == 0 then
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
    elseif result == CF.leftMenubarItemSelected then
      selectMenuItemOrKeyStroke(app, mods, key)
      return true
    elseif result == CF.rightMenubarItemSelected then
      safeGlobalKeyStroke(mods, key)
      return true
    elseif result == CF.nonEmptyTextFieldFocused then
      hs.eventtap.keyStroke(mods, key, nil, app)
      return true
    elseif result == CF.uIElementNotFocused then
      local focusedApp = hs.axuielement.systemWideElement().AXFocusedApplication
      selectMenuItemOrKeyStroke(focusedApp:asHSApplication(), mods, key)
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
    hs.timer.doAfter(0, function()
      FLAGS["CALLBACK_IS_EXECUTING"] = true
      fn()
      FLAGS["CALLBACK_IS_EXECUTING"] = false
    end)
  end
end

local function bindContextual(obj, config, ...)
  if config.spec ~= nil then
    config.mods = config.spec.mods
    config.key = config.spec.key
    config.spec = nil
  end
  local pressedfn, cond = wrapCondition(obj, config, KEY_MODE.PRESS)
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
  if type(cond) == 'table' then
    hotkey._chainedCond = cond
  else
    hotkey.condition = cond
  end
  return hotkey
end

function AppBind(app, config, ...)
  local hotkey = bindContextual(app, config, ...)
  hotkey.kind = HK.IN_APP
  hotkey.subkind = HK.IN_APP_.APP
  return hotkey
end

-- hotkeys for active app
registerInAppHotKeys = function(app)
  local appid = app:bundleID() or app:name()
  if appHotKeyCallbacks[appid] == nil then return end
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  if not inAppHotKeys[appid] then
    inAppHotKeys[appid] = {}
  end
  for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
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
        if kbShared ~= nil then
          keybinding = { mods = kbShared.mods, key = kbShared.key }
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

  onDeactivated(appid, function()
    unregisterInAppHotKeys(appid)
  end)
  onTerminated(appid, function()
    unregisterInAppHotKeys(appid, true)
    ActivatedAppConditionChain[appid] = nil
  end)
end

unregisterInAppHotKeys = function(appid, delete)
  if type(appid) ~= 'string' then appid = appid:bundleID() or appid:name() end
  if appHotKeyCallbacks[appid] == nil then return end

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
        if kbShared ~= nil then
          keybinding = { mods = kbShared.mods, key = kbShared.key }
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
    onDestroy(towinui(win),
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
local function registerSingleWinFilterForApp(app, filter)
  local appid = app:bundleID() or app:name()
  for f, _ in pairs(FocusedWindowObservers[appid] or {}) do
    -- a window filter can be shared by multiple hotkeys
    if sameFilter(f, filter) then
      return
    end
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

  local appUI = toappui(app)
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
      if win ~= nil and (allowURLs == nil or isWebsiteAllowed(win, allowURLs))
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
  stopOnDeactivated(appid, observer, function()
    FocusedWindowObservers[appid][filter] = nil
  end)
end

local function registerWinFiltersForApp(app)
  local appid = app:bundleID() or app:name()
  for hkID, cfg in pairs(appHotKeyCallbacks[appid] or {}) do
    local keybinding = get(KeybindingConfigs.hotkeys[appid], hkID)
        or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    if hasKey == false then
      local kbShared = get(KeybindingConfigs.hotkeys.shared, hkID)
      if kbShared ~= nil then
        keybinding = { mods = kbShared.mods, key = kbShared.key }
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
  local closeObserver
  for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
    local app = find(appid)
    local keybinding = get(KeybindingConfigs.hotkeys[appid], hkID) or cfg
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
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

        closeObserver = closeObserver or onDestroy(winUI,
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

local function registerSingleWinFilterForDaemonApp(app, filter)
  local appid = app:bundleID() or app:name()
  for f, _ in pairs(DaemonAppFocusedWindowObservers[appid] or {}) do
    -- a window filter can be shared by multiple hotkeys
    if sameFilter(f, filter) then
      return
    end
  end

  local appUI = toappui(app)
  local observer = uiobserver.new(app:pid())
  observer:addWatcher(appUI, uinotifications.windowCreated)
  if type(filter) == 'table' and filter.allowSheet then
    observer:addWatcher(appUI, uinotifications.focusedWindowChanged)
  end
  if type(filter) == 'table' and filter.allowPopover then
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
    local win = element:asHSWindow()
    if win then
      local windowFilter = hs.window.filter.new(false):setAppFilter(
          app:name(), filter)
      if not windowFilter:isWindowAllowed(win) then return end
    end
    registerDaemonAppInWinHotkeys(element:asHSWindow(), appid, filter)
  end)
  observer:start()
  if DaemonAppFocusedWindowObservers[appid] == nil then
    DaemonAppFocusedWindowObservers[appid] = {}
  end
  DaemonAppFocusedWindowObservers[appid][filter] = observer
  stopOnTerminated(appid, observer, function()
    DaemonAppFocusedWindowObservers[appid][filter] = nil
  end)
end

local function registerWinFiltersForDaemonApp(app, appConfig)
  local appid = app:bundleID() or app:name()
  for hkID, cfg in pairs(appConfig) do
    local keybinding = get(KeybindingConfigs.hotkeys[appid], hkID)
        or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
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

-- hotkeys for menu belonging to menubar app
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
  local closeObserver
  for hkID, cfg in pairs(appConfig) do
    local keybinding = get(KeybindingConfigs.hotkeys[appid], hkID)
        or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
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
          and cfg.message or cfg.message(app, menu)
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
          stopOnTerminated(appid, closeObserver, function()
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
  for hkID, cfg in pairs(appConfig) do
    local keybinding = get(KeybindingConfigs.hotkeys[appid], hkID)
        or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
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
        observer:callback(bind(registerInMenuHotkeys, app))
        observer:start()
        MenuBarMenuObservers[appid] = observer
        stopOnTerminated(appid, observer, function()
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


-- ## hotkeys or configs shared by multiple apps

-- basically aims to remap ctrl+` to shift+ctrl+tab to make it more convenient for fingers
local remapPreviousTabHotkey
local function remapPreviousTab(app, menuItems)
  if remapPreviousTabHotkey then
    remapPreviousTabHotkey:delete()
    remapPreviousTabHotkey = nil
  end
  local appid = app:bundleID() or app:name()
  local spec = get(KeybindingConfigs.hotkeys.shared, "remapPreviousTab")
  local specApp = get(appHotKeyCallbacks[appid], "remapPreviousTab")
  if specApp ~= nil or spec == nil or tcontain(spec.excluded or {}, appid) then
    return
  end
  local callback = function(menuItemPath)
    local fn = function()
      app:selectMenuItem(menuItemPath)
    end
    local cond = function()
      local menuItemCond = app:findMenuItem(menuItemPath)
      return menuItemCond ~= nil and menuItemCond.enabled
    end
    remapPreviousTabHotkey = AppBind(app, {
      spec = spec, message = menuItemPath[#menuItemPath],
      fn = fn, repeatedfn = fn, condition = cond
    })
    assert(remapPreviousTabHotkey)
    local info = {
      _chainedCond = remapPreviousTabHotkey._chainedCond,
      idx = remapPreviousTabHotkey.idx
    }
    onDeactivated(appid, function()
      disableConditionInChain(appid, info, true)
      info = nil
    end)
  end
  if menuItems then
    local menuItemPath = findMenuItemByKeyBinding(app, '⇧⌃', '⇥', menuItems)
    callback(menuItemPath)
  else
    findMenuItemByKeyBinding(app, '⇧⌃', '⇥', callback)
  end
end

-- register hotkey to open recent when it is available
local openRecentHotkey
local localizedOpenRecent
local function registerOpenRecent(app)
  if openRecentHotkey then
    openRecentHotkey:delete()
    openRecentHotkey = nil
  end
  local appid = app:bundleID() or app:name()
  local spec = get(KeybindingConfigs.hotkeys.shared, "openRecent")
  local specApp = get(appHotKeyCallbacks[appid], "openRecent")
  if specApp ~= nil or spec == nil or tcontain(spec.excluded or {}, appid) then
    return
  end
  local localizedFile = 'File'
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
      local appLocale = applicationLocale(appid)
      if localizedOpenRecent == nil then
        localizedOpenRecent = localizedString('Open Recent', {
          locale = appLocale,
          localeFile = 'MenuCommands', framework = "AppKit.framework",
        })
      end
      menuItemPath = { localizedFile, localizedOpenRecent }
      menuItem = app:findMenuItem(menuItemPath)
      if menuItem == nil then
        local appLocale = applicationLocale(appid)
        if appLocale ~= SYSTEM_LOCALE and appLocale:sub(1, 2) ~= 'en' then
          local localized = localizedString('Open Recent', {
            locale = appLocale,
            localeFile = 'MenuCommands', framework = "AppKit.framework",
          })
          menuItemPath = { localizedFile, localized }
        end
      end
    else
      local localizedTitle = localizedString('Open Recent', appid)
      if localizedTitle == nil then return end
      menuItemPath = { localizedFile, localizedTitle }
      menuItem = app:findMenuItem(menuItemPath)
    end
  end
  if menuItem ~= nil then
    local fn = function() receiveMenuItem(menuItemPath, app) end
    local cond = function()
      local menuItemCond = app:findMenuItem(menuItemPath)
      return menuItemCond ~= nil and menuItemCond.enabled
    end
    openRecentHotkey = AppBind(app, {
      spec = spec, message = menuItemPath[2],
      fn = fn, condition = cond
    })
    assert(openRecentHotkey)
    local info = {
      _chainedCond = openRecentHotkey._chainedCond,
      idx = openRecentHotkey.idx
    }
    onDeactivated(appid, function()
      disableConditionInChain(appid, info, true)
      info = nil
    end)
  end
end

local zoomHotkeys = {}
local function registerZoomHotkeys(app)
  for _, hotkey in pairs(zoomHotkeys) do
    hotkey:delete()
  end
  zoomHotkeys = {}
  local appid = app:bundleID() or app:name()
  local menuItemTitles = { 'Zoom', 'Zoom All' }
  for i, hkID in ipairs { 'zoom', 'zoomAll' } do
    local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
    local specApp = get(appHotKeyCallbacks[appid], hkID)
    if specApp ~= nil or spec == nil or tcontain(spec.excluded or {}, appid) then
      return
    end

    local title = menuItemTitles[i]
    local menuItemPath = { 'Window', title }
    local menuItem = app:findMenuItem(menuItemPath)
    if menuItem == nil then
      local localizedWindow = localizedMenuBarItem('Window', appid)
      local appLocale = applicationLocale(appid)
      local localizedTitle
      if title == 'Zoom' and OS_VERSION >= OS.Tahoe then
        localizedTitle = localizedString(title, 'com.apple.AppStore')
      else
        localizedTitle = localizedString(title, {
          locale = appLocale,
          localeFile = 'MenuCommands', framework = "AppKit.framework",
        })
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
      zoomHotkeys[hkID] = AppBind(app, {
        spec = spec, message = menuItemPath[2],
        fn = fn, condition = cond
      })
      local info = {
        _chainedCond = zoomHotkeys[hkID]._chainedCond,
        idx = zoomHotkeys[hkID].idx
      }
      onDeactivated(appid, function()
        disableConditionInChain(appid, info, true)
        info = nil
      end)
    end
  end
end

local function getToolbarButtons(winUI)
  local toolbar = getc(winUI, AX.Toolbar, 1)
  return getc(toolbar, AX.Button) or {}
end

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

local specialToolbarButtons = {
  ["com.apple.TextEdit"] = getTabGroupButtons,
  ["org.xquartz.X11"] = getTabGroupButtons,
  ["com.apple.FaceTime"] = waitForSettings(),
  ["com.torusknot.SourceTreeNotMAS"] = waitForSettings(
    function(winUI)
      return getToolbarButtons(winUI), true
    end
  ),
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
  end,
  ["com.tencent.qq"] = waitForSettings(function(winUI)
    local groups = getc(winUI, AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.WebArea, 1,
        AX.Group, 2, AX.Group, 2, AX.Group, 1, AX.Group)
    local buttons = tmap(groups or {}, function(g)
      return getc(g, AX.Group, 1, AX.StaticText, 1)
    end)
    return buttons, true
  end)
}

local settingsToolbarHotkeys = {}
local function registerNavigationForSettingsToolbar(app)
  local deleteFunc = function ()
    for _, hotkey in ipairs(settingsToolbarHotkeys) do
      disableConditionInChain(app:bundleID(), hotkey, true)
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
  local appid = app:bundleID() or app:name()
  local winUI = towinui(win)
  local func = specialToolbarButtons[appid] or getToolbarButtons
  local buttons, toClick = func(winUI)
  local callback = toClick and click or press
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
        condition = function() return clickable(button) end
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
  stopOnDeactivated(appid, closeObserver, deleteFunc)
  stopOnTerminated(appid, closeObserver, deleteFunc)
end

local function registerObserverForSettingsMenuItem(app)
  local appUI = toappui(app)

  local getMenuItem = function()
    local appMenu = getc(appUI, AX.MenuBar, 1, AX.MenuBarItem, 2)
    local appMenuItems = getc(appMenu, AX.Menu, 1, AX.MenuItem)
    if appMenuItems == nil or #appMenuItems == 0 then return end

    local sets = commonLocalizedMessage("Settings…")(app)
    local prefs = commonLocalizedMessage("Preferences…")(app)
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
          or item.AXTitle:find(prefs:sub(1, -4)))
    end)
    settingsMenu = settingsMenu or tfind(appMenuItems, function(item)
      if item.AXMenuItemCmdChar == ','
          and item.AXMenuItemCmdModifiers == 0 then
        local title = item.AXTitle
        if title:find("Settings") or title:find("Preferences") then
          return true
        end
        title = delocalizedString(item.AXTitle, app)
        if title then
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
  stopOnDeactivated(app:bundleID(), observer)
end

-- fixme: menuItemSelected event seems to escape for menu item in right
-- menu bar menu, so the code below does not work as expected actually
local function registerObserverForRightMenuBarSettingsMenuItem(app, observer)
  local oldCallback = observer:callback()
  local callback = function(obs, elem, notification)
    if notification == uinotifications.menuOpened
        and elem.AXParent.AXRole == AX.MenuBar then
      local menuItems = getc(elem, AX.MenuItem)
      local sets = commonLocalizedMessage("Settings…")(app)
      local prefs = commonLocalizedMessage("Preferences…")(app)
      local settingsMenu = tfind(menuItems, function(item)
        return item.AXTitle and
            (item.AXTitle:find(sets) or item.AXTitle:find(prefs))
      end)
      settingsMenu = settingsMenu or tfind(menuItems, function(item)
        return item.AXTitle and
            (item.AXTitle:find(sets:sub(1, -4))
            or item.AXTitle:find(prefs:sub(1, -4)))
      end)
      if settingsMenu ~= nil then
        observer:addWatcher(toappui(app), uinotifications.menuItemSelected)
      end
    elseif notification == uinotifications.menuClosed
        and elem.AXParent.AXRole == AX.MenuBar then
      observer:removeWatcher(toappui(app), uinotifications.menuItemSelected)
    elseif notification == uinotifications.menuItemSelected
        and elem.AXParent.AXParent.AXRole == AX.MenuBar then
      local sets = commonLocalizedMessage("Settings…")(app)
      local prefs = commonLocalizedMessage("Preferences…")(app)
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

-- bind hotkeys for open or save panel that are similar in `Finder`
-- & hotkey to confirm delete
local openSavePanelHotkeys = {}

-- special buttons for no saving in some apps
local specialConfirmFuncs = {
  ["com.kingsoft.wpsoffice.mac"] = function(winUI)
    if winUI.AXSubrole == AX.Dialog then
      local btnName = localizedString("Don't Save", "com.kingsoft.wpsoffice.mac")
      if btnName == nil then return end
      local buttons = getc(winUI, AX.Button)
      for _, button in ipairs(buttons) do
        if button.AXTitle == btnName then
          return button
        end
      end
    end
  end,

  ["JabRef"] = function(winUI)
    if winUI.AXTitle == localizedString("Save before closing", "JabRef") then
      local button = getc(winUI, AX.Unknown, 1, nil, 1, AX.Button, 1)
      if button ~= nil then
        local desc = localizedString("Discard changes", "JabRef")
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

local function registerForOpenSavePanel(app)
  for _, hotkey in ipairs(openSavePanelHotkeys) do
    hotkey:delete()
  end
  openSavePanelHotkeys = {}

  local appid = app:bundleID() or app:name()
  if appid == "com.apple.finder" or appid == "com.apple.dock" then return end
  local appUI = toappui(app)
  if not appUI:isValid() then
    hs.timer.doAfter(0.1, function() registerForOpenSavePanel(app) end)
    return
  end

  local getUIElements = function(winUI)
    local windowIdent = winUI.AXIdentifier
    local dontSaveButton, sidebarCells
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
    if windowIdent == "open-panel" or windowIdent == "save-panel" then
      local outline = getc(winUI, AX.SplitGroup, 1, AX.ScrollArea, 1, AX.Outline, 1)
      if outline ~= nil then
        sidebarCells = {}
        for _, row in ipairs(getc(outline, AX.Row)) do
          if #row == 0 then hs.timer.usleep(0.3 * 1000000) end
          tinsert(sidebarCells, row[1])
        end
      end
    elseif appid == "com.kingsoft.wpsoffice.mac" then
      if winUI.AXSubrole == AX.Dialog then
        local outline = getc(winUI, AX.SplitGroup, 1, AX.List, 1)
        if outline ~= nil then
          sidebarCells = {}
          for _, row in ipairs(getc(outline, AX.StaticText)) do
            if row.AXSize.h > 24 then
              tinsert(sidebarCells, row)
            end
          end
        end
      end
    end
    return dontSaveButton, sidebarCells
  end

  local actionFunc
  actionFunc = function(winUI, callByObserver)
    for _, hotkey in ipairs(openSavePanelHotkeys) do
      disableConditionInChain(appid, hotkey, true)
      hotkey:delete()
    end
    openSavePanelHotkeys = {}

    local dontSaveButton, sidebarCells = getUIElements(winUI)
    local header
    local i = 1
    for _, cell in ipairs(sidebarCells or {}) do
      if i > 10 then break end
      local titleElem = getc(cell, AX.StaticText, 1)
      if titleElem == nil and appid == "com.kingsoft.wpsoffice.mac" then
        local suffix
        if i == 1 then suffix = "st"
        elseif i == 2 then suffix = "nd"
        elseif i == 3 then suffix = "rd"
        else suffix = "th" end
        local hkID = strfmt("open%d%sSidebarItemOnOpenSavePanel", i, suffix)
        local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
        if spec ~= nil then
          local idx = i
          local hotkey = AppWinBind(app:focusedWindow(), {
            spec = spec, message = 'Location ' .. i,
            condition = function()
              local outline = getc(winUI, AX.SplitGroup, 1, AX.List, 1)
              local cnt = 0
              if outline ~= nil then
                for _, row in ipairs(getc(outline, AX.StaticText)) do
                  if row.AXSize.h > 24 then
                    cnt = cnt + 1
                    if cnt == idx then
                      return clickable(row)
                    end
                  end
                end
              end
            end,
            fn = click
          })
          tinsert(openSavePanelHotkeys, hotkey)
          i = i + 1
        end
      elseif titleElem and titleElem.AXIdentifier ~= nil then
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
            fn = function() cell:performAction(AX.Open) end,
          })
          tinsert(openSavePanelHotkeys, hotkey)
          i = i + 1
        end
      end
    end
    if appid ~= "com.kingsoft.wpsoffice.mac" and sidebarCells
        and callByObserver ~= true then
      if sidebarCells[1] and not sidebarCells[1]:isValid() then
        actionFunc(winUI)
        return
      end
      local observer = uiobserver.new(app:pid())
      observer:addWatcher(sidebarCells[1].AXParent.AXParent, uinotifications.rowCountChanged)
      observer:callback(function()
        if appBuf.lastRowCountChangedTimer then
          appBuf.lastRowCountChangedTimer:setNextTrigger(0.1)
          return
        end
        appBuf.lastRowCountChangedTimer = hs.timer.doAfter(0.1, function()
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
      onDestroy(winUI, function()
        if observer then
          observer:stop() observer = nil
        end
      end,
      hs.application.watcher.deactivated, true)
    end

    if dontSaveButton ~= nil then
      local spec = get(KeybindingConfigs.hotkeys.shared, "confirmDelete")
      if spec ~= nil then
        local hotkey = AppWinBind(app:focusedWindow(), {
          spec = spec,
          message = dontSaveButton.AXTitle or dontSaveButton.AXDescription,
          fn = function() press(dontSaveButton) end,
        })
        tinsert(openSavePanelHotkeys, hotkey)
      end
    end

    if dontSaveButton == nil and sidebarCells == nil then return end
    onDestroy(winUI,
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
  stopOnDeactivated(appid, observer)
end

-- bind `alt+?` hotkeys to select left menu bar items
local altMenuBarItemHotkeys = {}

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
    local _, framework = getResourceDir(app:bundleID())
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

local function altMenuBarItem(app, reinvokeKey)
  -- delete previous hotkeys
  for _, hotkey in ipairs(altMenuBarItemHotkeys) do
    hotkey:delete()
  end
  altMenuBarItemHotkeys = {}
  windowOnBindAltMenu = nil

  local appid = app:bundleID() or app:name()
  if appid == nil then return end
  -- check whether called by window filter (possibly with delay)
  if app:bundleID() ~= hs.application.frontmostApplication():bundleID() then
    return
  end
  local enableIndex = get(KeybindingConfigs.hotkeys,
      "menubar", "index", "enable")
  local enableLetter = get(KeybindingConfigs.hotkeys,
      "menubar", "letter", "enable")
  if enableIndex == nil then enableIndex = false end
  if enableLetter == nil then enableLetter = true end
  local excludedForLetter = get(KeybindingConfigs.hotkeys,
      "menubar", "letter", "exclude")
  if excludedForLetter ~= nil and tcontain(excludedForLetter, appid) then
    enableLetter = false
  end
  if enableIndex == false and enableLetter == false then return end

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
        press(menuBarItem)
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
          press(menubarItem)
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
  if enableLetter == true then
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
    if #itemTitles ~= #itemLocTitles then
      if appid == "com.tencent.xinWeChat" then
        local exBundleID = versionLessThan("4")(app)
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
    for i=2,#menuBarItemTitles do
      local spec = invMap[menuBarItemTitles[i]]
      if spec ~= nil then
        local fn = bind(clickMenuCallback, menuBarItemTitles[i], spec[1])
        local hotkey = bindAltMenu(app, "⌥", spec[1], spec[2], fn)
        tinsert(altMenuBarItemHotkeys, hotkey)
        if reinvokeKey == spec[1] then
          clickMenuCallback(menuBarItemTitles[i])
        end
      end
    end
  end

  -- by index
  if enableIndex == true then
    if app:focusedWindow() ~= nil then
      windowOnBindAltMenu = app:focusedWindow():id()
    else
      windowOnBindAltMenu = false
    end

    local maxMenuBarItemHotkey =
        #menuBarItemTitles > 11 and 10 or (#menuBarItemTitles - 1)
    local hotkey = bindAltMenu(app, "⌥", "`", menuBarItemTitles[1],
      function() app:selectMenuItem({ menuBarItemTitles[1] }) end)
    tinsert(altMenuBarItemHotkeys, hotkey)

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
    for i=1,maxMenuBarItemHotkey do
      local fn = bind(clickMenuCallback, menuBarItemTitles[i + 1], i % 10)
      hotkey = bindAltMenu(app, "⌥", tostring(i % 10), itemTitles[i], fn)
      tinsert(altMenuBarItemHotkeys, hotkey)
      if reinvokeKey == i % 10 then
        clickMenuCallback(menuBarItemTitles[i + 1])
      end
    end
  end
end

-- some apps may change their menu bar items irregularly
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
      altMenuBarItem(app)
      remapPreviousTab(app)
      registerOpenRecent(app)
      registerZoomHotkeys(app)
    end
    if mbTitlesStrWin ~= menuBarItemTitlesString.win[appid] then
      menuBarItemTitlesString.win[appid] = mbTitlesStrWin
      altMenuBarItem(app)
    end
  end)
  onDeactivated(appid, function()
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

local function appMenuBarChangeCallback(app)
  local appid = app:bundleID() or app:name()
  local menuBarItemStr, winMenuBarItemStr = getMenuBarItemTitlesString(app)
  if menuBarItemStr == menuBarItemTitlesString.app[appid] then
    if winMenuBarItemStr ~= menuBarItemTitlesString.win[appid] then
      menuBarItemTitlesString.win[appid] = winMenuBarItemStr
      altMenuBarItem(app)
    end
    return
  end
  menuBarItemTitlesString.app[appid] = menuBarItemStr
  altMenuBarItem(app)
  remapPreviousTab(app)
  registerOpenRecent(app)
  registerZoomHotkeys(app)
  hs.timer.doAfter(1, function()
    if hs.application.frontmostApplication():bundleID() ~= app:bundleID() then
      return
    end
    local newMenuBarItemTitlesString = getMenuBarItemTitlesString(app)
    if newMenuBarItemTitlesString ~= menuBarItemStr then
      menuBarItemTitlesString.app[appid] = newMenuBarItemTitlesString
      altMenuBarItem(app)
      remapPreviousTab(app)
      registerOpenRecent(app)
      registerZoomHotkeys(app)
    end
  end)
end

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
  stopOnDeactivated(appid, observer)
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
    onLaunched(appid, bind(registerRunningAppHotKeys, appid))
    onTerminated(appid, bind(unregisterRunningAppHotKeys, appid))
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
  altMenuBarItem(app, reinvokeKey)
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
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local isBackground = keybinding.background ~= nil
        and keybinding.background or cfg.background
    return hasKey and isForWindow and isBackground
  end)
  if hasDaemonAppWindowHotkey then
    onRunning(appid, function(app)
      registerWinFiltersForDaemonApp(app, appConfig)
    end)
  end
end

-- register hotkeys for focused window belonging to daemon app
if frontWin ~= nil then
  local frontWinAppID = frontWin:application():bundleID() or frontWin:application():name()
  if DaemonAppFocusedWindowObservers[frontWinAppID] ~= nil then
    for filter, _ in pairs(DaemonAppFocusedWindowObservers[frontWinAppID]) do
      local allowSheet, allowPopover
      local actualFilter = filter
      if type(filter) == 'table' then
        allowSheet, allowPopover = filter.allowSheet, filter.allowPopover
      end
      if allowSheet or allowPopover then
        actualFilter = false
      end
      local windowFilter = hs.window.filter.new(false):setAppFilter(
          frontWin:application():name(), actualFilter)
      if (allowSheet and frontWin:role() == AX.Sheet)
          or (allowPopover and frontWin:role() == AX.Popover)
          or windowFilter:isWindowAllowed(frontWin) then
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
        if hasKey then
          tinsert(nonFrontmostFilters, keybinding.windowFilter or cfg.windowFilter)
        end
      end
    end
    for _, filter in ipairs(nonFrontmostFilters) do
      local allowSheet, allowPopover
      local actualFilter = filter
      if type(filter) == 'table' then
        allowSheet, allowPopover = filter.allowSheet, filter.allowPopover
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
    onRunning(appid, function(app)
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
local appsHideWithoutWindow = {}
local appsQuitWithoutWindow = {}
-- account for pseudo windows such as popover or sheet
local appsHideWithNoPseudoWindow = {}
local appsQuitWithNoPseudoWindow = {}
-- some apps may first close a window before create a targeted one, so delay is needed before checking
local appsWithoutWindowDelay = {}

do
  local appsHideWithoutWindowLoaded = ApplicationConfigs["hideWithoutWindow"] or {}
  local appsQuitWithoutWindowLoaded = ApplicationConfigs["quitWithoutWindow"] or {}

  for _, item in ipairs(appsHideWithoutWindowLoaded) do
    if type(item) == 'string' then
      appsHideWithoutWindow[item] = true
    else
      for appid, cfg in pairs(item) do
        local windowFilter
        for k, v in pairs(cfg) do
          if (k == "allowPopover" or k == "allowSheet") and v then
            appsHideWithNoPseudoWindow[appid] = {}
            if k == "allowPopover" then
              tinsert(appsHideWithNoPseudoWindow[appid], AX.Popover)
            end
            if k == "allowSheet" then
              tinsert(appsHideWithNoPseudoWindow[appid], AX.Sheet)
            end
          elseif k == "delay" then
            appsWithoutWindowDelay[appid] = v
          else
            if windowFilter == nil then windowFilter = {} end
            windowFilter[k] = v
          end
        end
        appsHideWithoutWindow[appid] = windowFilter or true
      end
    end
  end
  for _, item in ipairs(appsQuitWithoutWindowLoaded) do
    if type(item) == 'string' then
      appsQuitWithoutWindow[item] = true
    else
      for appid, cfg in pairs(item) do
        local windowFilter
        for k, v in pairs(cfg) do
          if (k == "allowPopover" or k == "allowSheet") and v then
            appsQuitWithNoPseudoWindow[appid] = {}
            if k == "allowPopover" then
              tinsert(appsQuitWithNoPseudoWindow[appid], AX.Popover)
            end
            if k == "allowSheet" then
              tinsert(appsQuitWithNoPseudoWindow[appid], AX.Sheet)
            end
          elseif k == "delay" then
            appsWithoutWindowDelay[appid] = v
          else
            if windowFilter == nil then windowFilter = {} end
            windowFilter[k] = v
          end
        end
        appsQuitWithoutWindow[appid] = windowFilter or true
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
    local quit = appsQuitWithoutWindow[appid] ~= nil
    local windowFilterRules = quit and appsQuitWithoutWindow
        or appsHideWithoutWindow
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
    local quit = appsQuitWithoutWindow[appid] ~= nil
    local defaultRule = function()
      local windowFilterRules = quit and appsQuitWithoutWindow
          or appsHideWithoutWindow
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
    return versionLessThan("1.6.9")(app) and defaultRule()
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
  local quit = appsQuitWithNoPseudoWindow[appid] ~= nil
  local windowFilterRules = quit and appsQuitWithoutWindow
      or appsHideWithoutWindow
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
        pseudoWindowObserver = onDestroy(
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
  stopOnTerminated(appid, observer,
      function() PseudoWindowDestroyObservers[appid] = nil end)
end

AutoHideQuitWindowFilter = hs.window.filter.new(false)
for _, configs in ipairs{appsHideWithoutWindow, appsQuitWithoutWindow} do
  for appid, cfg in pairs(configs) do
    onRunning(appid, function(app)
      AutoHideQuitWindowFilter:setAppFilter(app:name(), cfg)
    end)
  end
end
AutoHideQuitWindowFilter:subscribe(hs.window.filter.windowDestroyed,
  function(win)
    if win == nil or win:application() == nil then return end
    local appid = win:application():bundleID()
    processAppWithoutWindow(win:application())
  end)

-- Hammerspoon only account standard windows, so add watchers for pseudo windows here
for _, configs in ipairs {
  appsHideWithNoPseudoWindow,
  appsQuitWithNoPseudoWindow,
} do
  for appid, roles in pairs(configs) do
    onRunning(appid, function(app)
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
      press(menuItem)
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
        press(menuItem)
      end
    end
    local disconnect = localizedString('Disconnect', app)
    for _, item in ipairs(disconnects) do
      local menuItem = getc(menuBar, AX.MenuItem, item,
          AX.Menu, 1, AX.MenuItem, disconnect)
      if menuItem ~= nil then
        press(menuItem)
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
    onRunning("io.mountainduck", function(app)
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
if hs.application.pathForBundleID("barrier") ~= nil
    and hs.application.pathForBundleID("barrier") ~= "" then
  onRunning("barrier", function(app)
    local observer = uiobserver.new(app:pid())
    observer:addWatcher(toappui(app), uinotifications.windowCreated)
    observer:callback(function(_, winUI) winUI:asHSWindow():focus() end)
    observer:start()
    stopOnTerminated(app:bundleID(), observer)
  end)
end

-- ## remote desktop apps
-- remap modifier keys for specified windows of remote desktop apps
local remoteDesktopsMappingModifiers =
    get(KeybindingConfigs, 'remoteDesktopModifiers') or {}
local modifiersShort = {
  control = "ctrl",
  option = "alt",
  command = "cmd",
  shift = "shift",
  fn = "fn"
}
for _, rules in pairs(remoteDesktopsMappingModifiers) do
  for _, r in ipairs(rules) do
    local newMap = {}
    for k, v in pairs(r.map) do
      k = modifiersShort[k]
      if k ~= nil then newMap[k] = modifiersShort[v] end
    end
    r.map = newMap
  end
end

local MicrosoftRemoteDesktopWindowFilter
if hs.application.nameForBundleID("com.microsoft.rdc.macos") == "Windows App" then
  onRunning("com.microsoft.rdc.macos", function(app)
    MicrosoftRemoteDesktopWindowFilter = { rejectTitles = {} }
    for _, title in ipairs {"Favorites", "Devices", "Apps",
      "Settings", "About", "Device View Options", "App View Options" } do
      local locTitle = "^" .. localizedString(title, app) .. "$"
      tinsert(MicrosoftRemoteDesktopWindowFilter.rejectTitles, locTitle)
    end
  end)
else
  MicrosoftRemoteDesktopWindowFilter = {
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
        window:application():name(), MicrosoftRemoteDesktopWindowFilter)
    local result = wFilter:isWindowAllowed(window)
    if result then
      local winUI = towinui(window)
      local title = "Cancel"
      if window:application():name() == "Windows App" then
        title = localizedString(title, appid) or title
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
  onActivated(appid, function()
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
  stopOnDeactivated(app:bundleID(), observer)
  stopOnTerminated(app:bundleID(), observer)
end

for _, appid in ipairs(ApplicationConfigs["suspendHotkeysInRemoteDesktop"] or {}) do
  local frontAppID = frontApp and (frontApp:bundleID() or frontApp:name()) or nil
  if frontAppID == appid then
    watchForRemoteDesktopWindow(frontApp)
    suspendHotkeysInRemoteDesktop(frontApp)
  end
  onActivated(appid, suspendHotkeysInRemoteDesktop)
  onActivated(appid, watchForRemoteDesktopWindow)
end

-- ## hold cmd+w to close window for iOS apps because it will quit them
HoldToQuit = hs.loadSpoon("HoldToQuit")
HoldToQuit.duration = 0.2
HoldToQuit:init()
HoldToQuit:bindHotkeys({ quit = { "⌘", "W" } })
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
      for _, proc in ipairs(processesOnLaunched[appid] or {}) do
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
    for _, proc in ipairs(processesOnActivated[appid] or {}) do
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
  elseif eventType == hs.application.watcher.deactivated and appname ~= nil then
    for _, proc in ipairs(processesOnDeactivated[appid] or {}) do
      proc(app)
    end
    processesOnDeactivated[appid] = nil
  elseif eventType == hs.application.watcher.terminated then
    for _, proc in ipairs(processesOnDeactivated[appid] or {}) do
      proc()
    end
    processesOnDeactivated[appid] = nil
    for _, proc in ipairs(processesOnTerminated[appid] or {}) do
      proc()
    end
    processesOnTerminated[appid] = nil
  elseif eventType == hs.application.watcher.deactivated and appname == nil then
    for id, processes in pairs(processesOnDeactivated) do
      if find(id) == nil then
        for _, proc in ipairs(processes) do
          proc()
        end
        processesOnDeactivated[id] = nil
      end
    end
    for id, processes in pairs(processesOnTerminated) do
      if find(id) == nil then
        for _, proc in ipairs(processes) do
          proc()
        end
        processesOnTerminated[id] = nil
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
    local frontAppID = frontApp:bundleID() or frontApp:name()
    if remoteDesktopsMappingModifiers[frontAppID] == nil then
      if RemoteDesktopModifierTapper:isEnabled() then
        RemoteDesktopModifierTapper:stop()
      end
    end
  end
end

-- some apps may terminate silently, which is unexpected
AppsTerminateSilently = {}
for _, appid in ipairs(ApplicationConfigs["terminateSilently"] or {}) do
  onRunning(appid, function()
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
local phones = {{"ANA-AN00", "HUAWEI"}}
local attached_android_count = 0

function App_usbChangedCallback(device)
  if device.eventType == "added" then
    attached_android_count = attached_android_count + 1
    for _, phone in ipairs(phones) do
      if device.productName == phone[1] and device.vendorName == phone[2] then
        hs.application.launchOrFocus('MacDroid')
        break
      end
    end
  elseif device.eventType == "removed" then
    attached_android_count = attached_android_count - 1
    if attached_android_count == 0 then
      quit('MacDroid Extension')
      quit('MacDroid')
    end
  end
end

runningAppsOnLoading = {}
