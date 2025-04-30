require "utils"

ApplicationConfigs = nil
if hs.fs.attributes("config/application.json") ~= nil then
  ApplicationConfigs = hs.json.read("config/application.json")
end

hs.application.enableSpotlightForNameSearches(true)


-- # appkeys

-- launch or hide applications
local function focusOrHideFinder(app)
  local windowFilter = hs.window.filter.new(false):setAppFilter(app:name())
  local windows = windowFilter:getWindows()
  local nonDesktop = hs.fnutils.find(windows, function(win)
    return win:id() ~= hs.window.desktop():id()
  end) == nil
  if nonDesktop then
    app = hs.application.open(app:bundleID())
  elseif hs.window.focusedWindow() ~= nil
      and hs.window.focusedWindow():application() == app then
    if hs.window.focusedWindow():id() == hs.window.desktop():id() then
      hs.application.open(app:bundleID())
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
end

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
    focusOrHideFinder(app)
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
  local path = string.format(PVMDir .. "/%s.pvm/%s.app", osname, osname)
  if hs.fs.attributes(path) ~= nil then return path end

  for filename in hs.fs.dir(PVMDir) do
    if filename:sub(-4) == '.pvm' and filename:sub(1, osname:len()) == osname then
      local stem = filename:sub(1, -5)
      path = string.format(PVMDir .. "/%s.pvm/%s.app", stem, stem)
      if hs.fs.attributes(path) ~= nil then return path end
    end
  end
end

local appHotkeys = {}

local function registerAppHotkeys()
  for _, hotkey in ipairs(appHotkeys) do
    hotkey:delete()
  end
  appHotkeys = {}
  HyperModal.hyperMode.keys = hs.fnutils.filter(HyperModal.hyperMode.keys,
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
      else
        hs.alert("Unsupported Virtual Machine : " .. config.vm)
      end
    end
    if appPath == nil and config.path ~= nil then
      if type(config.path) == "string" then
        appPath = config.path
      else
        for _, path in ipairs(config.path) do
          if hs.fs.attributes(path) ~= nil then
            appPath = path
            break
          end
        end
      end
    end
    if appPath ~= nil then
      local appname
      if appid ~= nil then
        appname = displayName(appid)
      else
        appname = hs.execute(string.format("mdls -name kMDItemDisplayName -raw '%s'", appPath))
        appname = appname:sub(1, -5)
      end
      local hotkey = bindHotkeySpec(config, appname,
          hs.fnutils.partial(config.fn or focusOrHide, appid or appname))
      hotkey.kind = HK.APPKEY
      if appid then
        hotkey.appid = appid
      else
        hotkey.appPath = appPath
      end
      table.insert(appHotkeys, hotkey)
    end
  end
end

registerAppHotkeys()


-- # hotkeys in specific application
local appHotKeyCallbacks

local function applicationVersion(appid)
  local appPath = hs.application.pathForBundleID(appid)
  local version = hs.execute(string.format([[mdls -r -name kMDItemVersion '%s']], appPath))
  version = hs.fnutils.split(version, "%.")
  local major, minor, patch
  major = tonumber(version[1]:match("%d+"))
  if major == nil then
    version = hs.application.infoForBundleID(appid).CFBundleShortVersionString
    version = hs.fnutils.split(version, "%.")
    major = tonumber(version[1]:match("%d+"))
  end
  minor = #version > 1 and tonumber(version[2]:match("%d+")) or 0
  patch = #version > 2 and tonumber(version[3]:match("%d+")) or 0
  return major, minor, patch
end

local function versionCompare(versionStr, comp)
  return function(app)
    local appMajor, appMinor, appPatch = applicationVersion(app:bundleID())
    local version = hs.fnutils.split(versionStr, "%.")
    local major, minor, patch
    major = tonumber(version[1]:match("%d+"))
    minor = #version > 1 and tonumber(version[2]:match("%d+")) or 0
    patch = #version > 2 and tonumber(version[3]:match("%d+")) or 0
    if comp == "==" then
      return appMajor == major and appMinor == minor and appPatch == patch
    elseif comp == "~=" then
      return appMajor ~= major or appMinor ~= minor or appPatch ~= patch
    elseif comp == "<" or comp == "<=" then
      if appMajor < major then return true end
      if appMajor == major and appMinor < minor then return true end
      if appMajor == major and appMinor == minor and appPatch < patch then return true end
      if comp == "<=" and appMajor == major and appMinor == minor and appPatch == patch then return true end
      return false
    elseif comp == ">" or comp == ">=" then
      if appMajor > major then return true end
      if appMajor == major and appMinor > minor then return true end
      if appMajor == major and appMinor == minor and appPatch > patch then return true end
      if comp == ">=" and appMajor == major and appMinor == minor and appPatch == patch then return true end
      return false
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

-- ## function utilities for hotkey configs of specific application

-- ### Finder
local function getFinderSidebarItemTitle(idx)
  return function(app)
    if app:focusedWindow() == nil
        or app:focusedWindow():role() == 'AXSheet' then return false end
    local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
    local outlineUIObj = getc(winUIObj,
        "AXSplitGroup", 1, "AXScrollArea", 1, "AXOutline", 1)
    if outlineUIObj == nil then return end
    local header
    local cnt = 0
    for _, rowUIObj in ipairs(getc(outlineUIObj, "AXRow")) do
      if rowUIObj.AXChildren == nil then hs.timer.usleep(0.3 * 1000000) end
      if getc(rowUIObj, nil, 1, "AXStaticText", 1).AXIdentifier ~= nil then
        header = getc(rowUIObj, nil, 1, "AXStaticText", 1).AXValue
      else
        cnt = cnt + 1
        if cnt == idx then
          local itemTitle = getc(rowUIObj, nil, 1, "AXStaticText", 1).AXValue
          return header .. ' > ' .. itemTitle
        end
      end
    end
  end
end

local function getFinderSidebarItem(idx)
  return function(app)
    if app:focusedWindow() == nil
        or app:focusedWindow():role() == 'AXSheet' then return false end
    local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
    local outlineUIObj = getc(winUIObj,
        "AXSplitGroup", 1, "AXScrollArea", 1, "AXOutline", 1)
    if outlineUIObj == nil then return false end
    local cnt = 0
    for _, rowUIObj in ipairs(get(outlineUIObj, "AXRow")) do
      if getc(rowUIObj, nil, 1, "AXStaticText", 1).AXIdentifier == nil then
        cnt = cnt + 1
      end
      if cnt == idx then
        return true, rowUIObj.AXChildren[1]
      end
    end
    return false
  end
end

local function openFinderSidebarItem(cellUIObj, app)
  local go = localizedString("Go", app:bundleID())
  local itemTitle = get(cellUIObj, "AXStaticText", 1).AXValue
  if app:findMenuItem({ go, itemTitle }) ~= nil then
    app:selectMenuItem({ go, itemTitle })
  else
    local flags = hs.eventtap.checkKeyboardModifiers()
    if not (flags['cmd'] or flags['alt'] or flags['ctrl']) then
      cellUIObj:performAction("AXOpen")
    else
      local tapper
      tapper = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
        tapper:stop()
        hs.timer.doAfter(0.01, function()
          local newFlags = hs.eventtap.checkKeyboardModifiers()
          if newFlags['cmd'] or newFlags['alt'] or newFlags['ctrl'] then
            event:setFlags({}):post()
            hs.timer.doAfter(0.01, function()
              cellUIObj:performAction("AXOpen")
            end)
          else
            cellUIObj:performAction("AXOpen")
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
local function deleteSelectedMessage(app, menuItem, force)
  if app:focusedWindow() == nil then return end
  local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
  local button = getc(winUIObj,
      "AXGroup", 1, "AXGroup", 1, "AXGroup", 2, "AXGroup", 1, "AXButton", 2)
  if button ~= nil then
    button:performAction("AXPress")
    if force ~= nil then
      hs.timer.doAfter(0.2, function()
        hs.eventtap.keyStroke("", "Tab", nil, app)
        hs.timer.doAfter(0.2, function()
          hs.eventtap.keyStroke("", "Space", nil, app)
        end)
      end)
    end
    return
  end
  if menuItem == nil then
    local _, menuItemPath = findMenuItem(app, {
      getOSVersion() < OS.Ventura and "File" or "Conversation",
      "Delete Conversation…"
    })
    menuItem = menuItemPath
  end
  app:selectMenuItem(menuItem)
  if force ~= nil then
    hs.timer.doAfter(0.1, function()
      hs.eventtap.keyStroke("", "Return", nil, app)
    end)
  end
end

local function deleteAllMessages(messageItems, app)
  local messageItem = messageItems[1]
  messageItem:performAction("AXPress")
  hs.timer.doAfter(0.1, function()
    deleteSelectedMessage(app, nil, true)
    hs.timer.doAfter(1.9, function()
      deleteAllMessages(messageItems, app)
    end)
  end)
end

-- ### FaceTime
local function deleteMousePositionCall(win)
  local winUIObj = hs.axuielement.windowElement(win)
  local collection = getc(winUIObj, "AXGroup", 1, "AXGroup", 1, "AXGroup", 1, "AXGroup", 2)
  if collection ~= nil and collection.AXDescription ==
      localizedString("Recent Calls", win:application():bundleID()) then
    local section = getc(collection, "AXButton", 1)
    if section ~= nil then
      if not rightClick(hs.mouse.absolutePosition(), win:application():name()) then return end
      local popup = getc(winUIObj, "AXGroup", 1, "AXMenu", 1)
      local maxTime, time = 0.5, 0
      while popup == nil and time < maxTime do
        hs.timer.usleep(0.01 * 1000000)
        time = time + 0.01
        popup = getc(winUIObj, "AXGroup", 1, "AXMenu", 1)
      end
      if popup == nil then
        if not rightClick(hs.mouse.absolutePosition(), win:application():name()) then return end
        popup = getc(winUIObj, "AXGroup", 1, "AXMenu", 1)
        time = 0
        while popup == nil and time < maxTime do
          hs.timer.usleep(0.01 * 1000000)
          time = time + 0.01
          popup = getc(winUIObj, "AXGroup", 1, "AXMenu", 1)
        end
        if popup == nil then return end
      end
      local locTitle = localizedString("Remove from Recents", win:application():bundleID())
      local menuItem = getc(popup, "AXMenuItem", locTitle)
      if menuItem ~= nil then
        menuItem:performAction("AXPress")
      end
    end
    return
  end
  winUIObj:elementSearch(
    function(msg, results, count)
      if count == 0 then return end

      local sectionList = getc(results[1], nil, 1, "AXGroup")
      if #sectionList == 0 then return end

      local section = sectionList[1]
      if not rightClick(hs.mouse.absolutePosition(), win:application():name()) then return end
      local popups = getc(section, "AXMenu")
      local maxTime, time = 0.5, 0
      while #popups == 0 and time < maxTime do
        hs.timer.usleep(0.01 * 1000000)
        time = time + 0.01
        popups = get(section, "AXMenu")
      end
      for _, popup in ipairs(popups) do
        for _, menuItem in ipairs(getc(popup, "AXMenuItem")) do
          if menuItem.AXIdentifier == "menuRemovePersonFromRecents:" then
            menuItem:performAction("AXPress")
            break
          end
        end
      end
    end,
    function(element)
      return element.AXSubrole == "AXCollectionList"
          and element.AXChildren ~= nil and #element.AXChildren > 0
          and element.AXChildren[1].AXSubrole == "AXSectionList"
    end,
    { count = 1 }
  )
end

local function deleteAllCalls(win)
  local winUIObj = hs.axuielement.windowElement(win)
  local collection = getc(winUIObj, "AXGroup", 1, "AXGroup", 1, "AXGroup", 1, "AXGroup", 2)
  if collection ~= nil and collection.AXDescription ==
      localizedString("Recent Calls", win:application():bundleID()) then
    local section = getc(collection, "AXButton", 1)
    if section ~= nil then
      local position = { section.AXPosition.x + 50, section.AXPosition.y + 10 }
      if not rightClick(position, win:application():name()) then return end
      local popup = getc(winUIObj, "AXGroup", 1, "AXMenu", 1)
      local maxTime, time = 0.5, 0
      while popup == nil and time < maxTime do
        hs.timer.usleep(0.01 * 1000000)
        time = time + 0.01
        popup = getc(winUIObj, "AXGroup", 1, "AXMenu", 1)
      end
      if popup == nil then
        if not rightClick(position, win:application():name()) then return end
        popup = getc(winUIObj, "AXGroup", 1, "AXMenu", 1)
        time = 0
        while popup == nil and time < maxTime do
          hs.timer.usleep(0.01 * 1000000)
          time = time + 0.01
          popup = getc(winUIObj, "AXGroup", 1, "AXMenu", 1)
        end
        if popup == nil then return end
      end
      local locTitle = localizedString("Remove from Recents", win:application():bundleID())
      local menuItem = getc(popup, "AXMenuItem", locTitle)
      if menuItem ~= nil then
        menuItem:performAction("AXPress")
      end
      hs.timer.usleep(0.1 * 1000000)
      deleteAllCalls(win)
    end
    return
  end
  winUIObj:elementSearch(
    function(msg, results, count)
      if count == 0 then return end

      local sectionList = getc(results[1], nil, 1, "AXGroup")
      if #sectionList == 0 then return end

      local section = sectionList[1]
      if not rightClickAndRestore(section.AXPosition, win:application():name()) then
        return
      end
      local popups = getc(section, "AXMenu")
      local maxTime, time = 0.5, 0
      while #popups == 0 and time < maxTime do
        hs.timer.usleep(0.01 * 1000000)
        time = time + 0.01
        popups = getc(section, "AXMenu")
      end
      for _, popup in ipairs(popups) do
        for _, menuItem in ipairs(getc(popup, "AXMenuItem")) do
          if menuItem.AXIdentifier == "menuRemovePersonFromRecents:" then
            menuItem:performAction("AXPress")
            hs.timer.usleep(0.1 * 1000000)
            break
          end
        end
      end
      deleteAllCalls(winUIObj)
    end,
    function(element)
      return element.AXSubrole == "AXCollectionList"
          and element.AXChildren ~= nil and #element.AXChildren > 0
          and element.AXChildren[1].AXSubrole == "AXSectionList"
    end,
    { count = 1 }
  )
end

-- ### Visual Studio Code
local function VSCodeToggleSideBarSection(app, sidebar, section)
  local commonPath = [[group 2 of group 1 of group 2 of group 2 of ¬
    group 1 of group 1 of group 1 of group 1 of UI element 1 of ¬
    group 1 of group 1 of group 1 of UI element 1]]
  local commonPathOld = [[group 2 of group 1 of group 2 of group 2 of ¬
    group 1 of group 1 of group 1 of group 1 of UI element 1]]
  local sidebarAction = [[
    set tabs to radio buttons of tab group 1 of group 1 of group 1 of ¬
        %s
    repeat with tab in tabs
      if title of tab starts with "]] .. sidebar .. [["  ¬
          or value of attribute "AXDescription" of tab starts with "]] .. sidebar .. [[" then
        perform action 1 of tab
        exit repeat
      end if
    end repeat
    delay 0.1
  ]]
  local sectionExpand = [[
    set sections to every group of group 2 of group 1 of group 2 of group 2 of ¬
          %s
      repeat with sec in sections
        if title of UI element 2 of button 1 of group 1 of sec is "]] .. section .. [[" then
          if (count value of attribute "AXChildren" of group 1 of sec) is 1 then
            perform action 1 of button 1 of group 1 of sec
          end if
          exit repeat
        end if
      end repeat
  ]]
  local sectionFold = [[
    set sections to every group of group 2 of group 1 of group 2 of group 2 of ¬
          %s
      repeat with sec in sections
        if title of UI element 2 of button 1 of group 1 of sec is "]] .. section .. [[" then
          perform action 1 of button 1 of group 1 of sec
          exit repeat
        end if
      end repeat
  ]]
  hs.osascript.applescript([[
    tell application "System Events"
      tell ]] .. aWinFor(app) .. [[
        if (exists UI element 1 of group 1 of group 1 of group 2 of ¬
              ]] .. commonPath .. [[) ¬
            and (title of UI element 1 of group 1 of group 1 of group 2 of ¬
              ]] .. commonPath .. [[ ¬
              starts with "]] .. sidebar .. [[") then
          ]] .. string.format(sectionFold, commonPath) .. [[
        else if (exists UI element 1 of group 1 of group 1 of group 2 of ¬
              ]] .. commonPathOld .. [[) ¬
            and (title of UI element 1 of group 1 of group 1 of group 2 of ¬
              ]] .. commonPathOld .. [[ ¬
              starts with "]] .. sidebar .. [[") then
          ]] .. string.format(sectionFold, commonPathOld) .. [[
        else if (not exists ]] .. commonPath .. [[) ¬
            or (title of UI element 1 of group 1 of group 1 of group 2 of ¬
              ]] .. commonPath .. [[ ¬
              does not start with "]] .. sidebar .. [[") then
          ]] .. string.format(sidebarAction, commonPath) .. [[
          ]] .. string.format(sectionExpand, commonPath) .. [[
        else if (not exists ]] .. commonPathOld .. [[) ¬
            or (title of UI element 1 of group 1 of group 1 of group 2 of ¬
              ]] .. commonPathOld .. [[ ¬
              does not start with "]] .. sidebar .. [[") then
          ]] .. string.format(sidebarAction, commonPathOld) .. [[
          ]] .. string.format(sectionExpand, commonPathOld) .. [[
        end if
      end tell
    end tell
  ]])
end

-- ### JabRef
local function JabRefShowLibraryByIndex(idx)
  return function(app)
    if app:focusedWindow() == nil then return false end
    local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
    local tab = getc(winUIObj, "AXTabGroup", 1, "AXRadioButton", idx)
    if tab ~= nil then
      return true, { x = tab.AXPosition.x + 10, y = tab.AXPosition.y + 10 }
    else
      return false
    end
  end
end

-- ### App Cleaner & Uninstaller
local function buttonValidForAppCleanerUninstaller(title)
  return function(win)
    local locTitle = localizedString(title, win:application():bundleID())
    local winUIObj = hs.axuielement.windowElement(win)
    local sg = getc(winUIObj, "AXSplitGroup", 1)
    if sg == nil then return false end
    local button = hs.fnutils.find(getc(sg, "AXButton"), function(bt)
      return bt.AXIdentifier == "uaid:RemoveSelectedItemsButton"
          and bt.AXTitle == locTitle and bt.AXEnabled
    end)
    return button ~= nil, button
  end
end

local function confirmButtonValidForAppCleanerUninstaller(title)
  return function(win)
    local locTitle = localizedString(title, win:application():bundleID())
    local winUIObj = hs.axuielement.windowElement(win)
    local cancel = hs.fnutils.find(getc(winUIObj, "AXButton"), function(bt)
      return bt.AXIdentifier == "uaid:RemoveDialogSecondButton" and bt.AXEnabled
    end)
    if cancel == nil then return false end
    local button = getc(winUIObj, "AXStaticText", locTitle)
    return button ~= nil, button ~= nil and button.AXPosition
  end
end

-- ### Bartender
local bartenderBarItemNames
local bartenderBarItemIDs
local bartenderBarWindowFilter = { allowTitles = "^Bartender Bar$" }
BartenderBarFilter = nil
local function getBartenderBarItemTitle(index, rightClick)
  return function(app)
    if bartenderBarItemNames == nil then
      local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
      local icons = getc(winUIObj, "AXScrollArea", 1, "AXList", 1, "AXList", 1)
      local appnames = hs.fnutils.map(getc(icons, "AXGroup"), function(g)
        return getc(g, "AXImage", 1).AXDescription
      end)
      if #appnames > 0 then
        local appid = app:bundleID()
        local _, items = hs.osascript.applescript(string.format([[
          tell application id "%s" to list menu bar items
        ]], appid))
        local itemList = hs.fnutils.split(items, "\n")
        local splitterIndex = hs.fnutils.indexOf(itemList, appid .. "-statusItem")
        local barSplitterIndex = hs.fnutils.indexOf(appnames, app:name())
        if barSplitterIndex ~= nil then
          splitterIndex = splitterIndex - (#appnames - (barSplitterIndex - 1))
        end
        bartenderBarItemNames = {}
        bartenderBarItemIDs = {}
        local missedItemCnt = 0
        local plistPath = hs.fs.pathToAbsolute(string.format(
            "~/Library/Preferences/%s.plist", appid))
        if plistPath ~= nil then
          local plist = hs.plist.read(plistPath)
          local allwaysHidden = get(plist, "ProfileSettings", "activeProfile", "AlwaysHide")
          local itemIDIdx = splitterIndex + #appnames
          while hs.fnutils.contains(allwaysHidden, itemList[itemIDIdx]) and itemIDIdx > splitterIndex do
            itemIDIdx = itemIDIdx - 1
          end
          missedItemCnt = #appnames - (itemIDIdx - splitterIndex)
        end
        if missedItemCnt == 0 then
          for i = 1, #appnames do
            local appname = appnames[i]
            local itemID = itemList[splitterIndex + 1 + #appnames - i]
            local id, idx = string.match(itemID, "(.-)%-Item%-(%d+)$")
            if id ~= nil then
              if idx == "0" then
                table.insert(bartenderBarItemNames, appname)
              else
                table.insert(bartenderBarItemNames, string.format("%s (Item %s)", appname, idx))
              end
              table.insert(bartenderBarItemIDs, itemID)
            else
              local app = find(appname)
              if app == nil or app:bundleID() ~= itemID:sub(1, #app:bundleID()) then
                table.insert(bartenderBarItemNames, appname)
                table.insert(bartenderBarItemIDs, itemID)
              elseif app ~= nil then
                local itemShortName = itemID:sub(#app:bundleID() + 2)
                table.insert(bartenderBarItemNames, string.format("%s (%s)", appname, itemShortName))
                table.insert(bartenderBarItemIDs, itemID)
              end
            end
          end
        else
          for i = 1, #appnames do
            table.insert(bartenderBarItemNames, appnames[i])
            table.insert(bartenderBarItemIDs, i)
          end
        end
        BartenderBarFilter = hs.window.filter.new(false):setAppFilter(
            app:name(), bartenderBarWindowFilter)
        BartenderBarFilter:subscribe(
            { hs.window.filter.windowDestroyed, hs.window.filter.windowUnfocused },
            function()
              bartenderBarItemNames = nil
              bartenderBarItemIDs = nil
              BartenderBarFilter:unsubscribeAll()
              BartenderBarFilter = nil
            end)
      end
    end
    if bartenderBarItemNames ~= nil and index <= #bartenderBarItemNames then
      return (rightClick and "Right-click " or "Click ") .. bartenderBarItemNames[index]
    end
  end
end

local function clickBartenderBarItem(index, rightClick)
  return function(win)
    local appid = win:application():bundleID()
    local itemID = bartenderBarItemIDs[index]
    if type(itemID) == 'string' then
      local script = string.format('tell application id "%s" to activate "%s"',
          appid, bartenderBarItemIDs[index])
      if rightClick then
        script = script .. " with right click"
      end
      hs.osascript.applescript(script)
      hs.timer.doAfter(0.1, function()
        hs.osascript.applescript(string.format([[
          tell application id "%s" to toggle bartender
        ]], appid))
      end)
    else
      local winUIObj = hs.axuielement.windowElement(find(appid):focusedWindow())
      local icon = getc(winUIObj, "AXScrollArea", 1, "AXList", 1, "AXList", 1, "AXGroup", itemID, "AXImage", 1)
      if icon ~= nil then
        local position = { icon.AXPosition.x + 10, icon.AXPosition.y + 10 }
        if rightClick then
          rightClickAndRestore(position, win:application():name())
        else
          leftClickAndRestore(position, win:application():name())
        end
      end
    end
  end
end

local function clickBartenderSidebarItem(index)
  return function(win)
    local winUIObj = hs.axuielement.windowElement(win)
    local row = getc(winUIObj, "AXSplitGroup", 1, "AXScrollArea", 1,
        "AXOutline", 1, "AXRow", index, "AXCell", 1, "AXImage", 1)
    if row ~= nil then
      leftClickAndRestore(row.AXPosition, win:application():name())
    end
  end
end

-- ### PasswordsMenuBarExtra
local function getPasswordRecordPosition(index)
  return function(win)
    local winUIObj = hs.axuielement.windowElement(win)
    local searchField = getc(winUIObj, "AXGroup", 1, "AXTextField", 1)
    if searchField ~= nil then
      local row = getc(winUIObj, "AXGroup", 1, "AXScrollArea", 1,
        "AXGroup", 1, "AXScrollArea", 1, "AXOutline", 1, "AXRow", index)
      if row ~= nil then
        return true, { row.AXPosition.x + 10, row.AXPosition.y + 10 }
      end
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
        0, hs.screen.mainScreen():fullFrame().y + hs.screen.mainScreen():fullFrame().h - 400,
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
    ok, source = hs.osascript.applescript(string.format([[
      tell application id "%s"
        execute active tab of front window javascript "document.documentElement.outerHTML"
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
    ok, url = hs.osascript.applescript(string.format([[
      tell application id "%s" to get URL of active tab of front window
    ]], app:bundleID()))
  end
  if ok then return url end
end

local function weiboNavigateToSideBarCondition(idx, isCommon)
  return function(app)
    if idx == 1 and isCommon then
      return true, ""
    end
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
      if start == nil then return false end
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
      if start == nil then return false end
      stop = source:find(tailer, start + 1) or source:len()
    end
    source = source:sub(start + 1, stop - 1)
    local cnt = isCommon and 1 or 0
    for url in string.gmatch(source, [[<a class="ALink_none[^>]-href="/(mygroup.-)">]]) do
      cnt = cnt + 1
      if cnt == idx then return true, url end
    end
    return false
  end
end

local function weiboNavigateToSideBar(result, url, app)
  local schemeEnd = url:find("//")
  local domainEnd = url:find("/", schemeEnd + 2)
  local fullUrl = url:sub(1, domainEnd) .. result
  if app:bundleID() == "com.apple.Safari" then
    hs.osascript.applescript(string.format([[
      tell application id "com.apple.Safari"
        set URL of front document to "%s"
      end tell
    ]], fullUrl))
  else  -- assume chromium-based browsers
    hs.osascript.applescript(string.format([[
      tell application id "%s"
        set URL of active tab of front window to "%s"
      end tell
    ]], app:bundleID(), fullUrl))
  end
end

local function weiboNavigateToCustomGroupCondition(idx)
  return weiboNavigateToSideBarCondition(idx, false)
end

local function weiboNavigateToCommonGroupCondition(idx)
  return weiboNavigateToSideBarCondition(idx, true)
end

local function douyinNavigateToTabCondition(idx)
  return function(app)
    local source = getTabSource(app)
    if source == nil then return end
    local cnt = 0
    local lastURL = ""
    for url in string.gmatch(source, [[<div class="tab\-[^>]-><a href="(.-)"]]) do
      if url ~= lastURL then cnt = cnt + 1 end
      if cnt == idx then return true, url end
      lastURL = url
    end
    return false
  end
end

local function douyinNavigateToTab(result, url, app)
  local fullUrl
  if result:sub(1, 2) == '//' then
    local schemeEnd = url:find("//")
    fullUrl = url:sub(1, schemeEnd - 1) .. result
  else
    fullUrl = result
  end
  if app:bundleID() == "com.apple.Safari" then
    hs.osascript.applescript(string.format([[
      tell application id "com.apple.Safari"
        set URL of front document to "%s"
      end tell
    ]], fullUrl))
  else  -- assume chromium-based browsers
    hs.osascript.applescript(string.format([[
      tell application id "%s"
        set URL of active tab of front window to "%s"
      end tell
    ]], app:bundleID(), fullUrl))
  end
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
    if mods >= (1 << 23) then table.insert(modList, "fn") end
    if (mods % (1 << 23)) >= (1 << 20) then table.insert(modList, "command") end
    if (mods % (1 << 20)) >= (1 << 19) then table.insert(modList, "option") end
    if (mods % (1 << 19)) >= (1 << 18) then table.insert(modList, "control") end
    if (mods % (1 << 18)) >= (1 << 17) then table.insert(modList, "shift") end
  else
    if mods >= (1 << 12) then table.insert(modList, "control") end
    if (mods % (1 << 12)) >= (1 << 11) then table.insert(modList, "option") end
    if (mods % (1 << 11)) >= (1 << 9) then table.insert(modList, "shift") end
    if (mods % (1 << 9)) >= (1 << 8) then table.insert(modList, "command") end
  end
  return modList, key
end

-- dump specified key bindings to plist files
local function dumpPlistKeyBinding(mode, mods, key)
  local modIdx = 0
  if mode == 1 then
    if hs.fnutils.contains(mods, "command") then modIdx = (1 << 8) end
    if hs.fnutils.contains(mods, "option") then modIdx = modIdx + (1 << 11) end
    if hs.fnutils.contains(mods, "control") then modIdx = modIdx + (1 << 12) end
    if hs.fnutils.contains(mods, "shift") then modIdx = modIdx + (1 << 9) end
  elseif mode == 2 then
    if key:lower():match("^f(%d+)$") then modIdx = 1 << 23 end
    if hs.fnutils.contains(mods, "command") then modIdx = modIdx + (1 << 20) end
    if hs.fnutils.contains(mods, "option") then modIdx = modIdx + (1 << 19) end
    if hs.fnutils.contains(mods, "control") then modIdx = modIdx + (1 << 18) end
    if hs.fnutils.contains(mods, "shift") then modIdx = modIdx + (1 << 17) end
  end
  key = hs.keycodes.map[key]
  return modIdx, key
end

-- fetch localized string as hotkey message after activating the app
local function commonLocalizedMessage(message)
  if message == "Hide" or message == "Quit" then
    return function(app)
      local appname = displayName(app)
      local appid = type(app) == 'string' and app or app:bundleID()
      local appLocale = applicationValidLocale(appid)
      if appLocale ~= nil then
        local result = localizedString(message .. ' App Store', 'com.apple.AppStore',
                                       { locale = appLocale })
        if result ~= nil then
          return result:gsub('App Store', appname)
        end
      end
      return message .. ' ' .. appname
    end
  elseif message == "Back" then
    return function(app)
      local appid = type(app) == 'string' and app or app:bundleID()
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
      local appid = type(app) == 'string' and app or app:bundleID()
      local appLocale = applicationValidLocale(appid)
      if appLocale ~= nil then
        local resourceDir = '/System/Library/Frameworks/AppKit.framework/Resources'
        local locale = getMatchedLocale(appLocale, resourceDir, 'lproj')
        if locale ~= nil then
          for _, stem in ipairs{ 'MenuCommands', 'Menus', 'Common' } do
            local result = localizeByLoctable(message, resourceDir, stem, locale, {})
            if result ~= nil then
              return result:gsub('“%%@”', ''):gsub('%%@', '')
            end
          end
        end
      end
      return message
    end
  end
end

local function localizedMessage(message, params, sep)
  return function(app)
    local appid = type(app) == 'string' and app or app:bundleID()
    if type(message) == 'string' then
      return localizedMenuItem(message, appid, params) or message
    else
      if sep == nil then sep = ' > ' end
      local str = localizedMenuBarItem(message[1], appid, params) or message[1]
      for i=2,#message do
        str = str .. sep .. (localizedMenuItem(message[i], appid, params) or message[i])
      end
      return str
    end
  end
end

-- fetch title of menu item as hotkey message by key binding
local function menuItemMessage(mods, key, titleIndex, sep)
  return function(app)
    if type(titleIndex) == 'number' then
      local menuItem = findMenuItemByKeyBinding(app, mods, key)
      if menuItem ~= nil then return menuItem[titleIndex] end
    else
      if sep == nil then sep = ' > ' end
      local menuItem = findMenuItemByKeyBinding(app, mods, key)
      assert(menuItem)
      local str = menuItem[titleIndex[1]]
      for i=2,#titleIndex do
        str = str .. sep .. menuItem[titleIndex[i]]
      end
    end
  end
end

-- check if the menu item whose path is specified is enabled
-- if so, return the path of the menu item
local function checkMenuItem(menuItemTitle, params)
  return function(app)
    local menuItem, locTitle = findMenuItem(app, menuItemTitle, params)
    return menuItem ~= nil and menuItem.enabled, locTitle
  end
end

-- possible reasons for failure of hotkey condition
local COND_FAIL = {
  NOT_FRONTMOST_WINDOW = "NOT_FRONTMOST_WINDOW",
  MENU_ITEM_SELECTED = "MENU_ITEM_SELECTED",
  NO_MENU_ITEM_BY_KEYBINDING = "NO_MENU_ITEM_BY_KEYBINDING",
  WINDOW_FILTER_NOT_SATISFIED = "WINDOW_FILTER_NOT_SATISFIED",
  WEBSITE_FILTER_NOT_SATISFIED = "WEBSITE_FILTER_NOT_SATISFIED",
}

-- check whether the menu bar item is selected
-- if a menu is extended, hotkeys with no modifiers are disabled
local function noSelectedMenuBarItem(app)
  local appUIObj = hs.axuielement.applicationElement(app)
  local menuBar
  local maxTryTime = 3
  local tryInterval = 0.05
  local tryTimes = 1
  while tryTimes <= maxTryTime / tryInterval do
    menuBar = getc(appUIObj, "AXMenuBar", 1)
    if menuBar ~= nil then break end
    hs.timer.usleep(tryInterval * 1000000)
    tryTimes = tryTimes + 1
  end
  if menuBar == nil then return true end
  for i, menuBarItem in ipairs(getc(menuBar, "AXMenuBarItem")) do
    if i > 1 and menuBarItem.AXSelected then
      return false
    end
  end
  return true
end

local function noSelectedMenuBarItemFunc(fn)
  return function(obj)
    local app = obj.application ~= nil and obj:application() or obj
    local satisfied = noSelectedMenuBarItem(app)
    if satisfied then
      if fn ~= nil then
        return fn(obj)
      else
        return true
      end
    else
      return false, COND_FAIL.MENU_ITEM_SELECTED
    end
  end
end

-- check if the menu item whose key binding is specified is enabled
-- if so, return the path of the menu item
local function checkMenuItemByKeybinding(mods, key)
  return function(app)
    local menuItem, enabled = findMenuItemByKeyBinding(app, mods, key)
    if menuItem ~= nil and enabled then
      return true, menuItem
    else
      return false, COND_FAIL.NO_MENU_ITEM_BY_KEYBINDING
    end
  end
end

-- select the menu item returned by the condition
-- work as hotkey callback
local function receiveMenuItem(menuItemTitle, app)
  app:selectMenuItem(menuItemTitle)
end

-- show the menu item returned by the condition
-- work as hotkey callback
local function showMenuItem(menuItemTitle, app)
  local fn = function()
    app:selectMenuItem({ menuItemTitle[1] })
    if #menuItemTitle > 1 then
      app:selectMenuItem(menuItemTitle)
    end
  end
  fn = showMenuItemWrapper(fn)
  fn()
end

-- click the position returned by the condition
-- work as hotkey callback
local function receivePosition(position, app)
  leftClickAndRestore(position, app:name())
end

-- click the button returned by the condition
-- work as hotkey callback
local function receiveButton(button)
  button:performAction("AXPress")
end

-- send key strokes to the app. but if the key binding is found, select corresponding menu item
local function selectMenuItemOrKeyStroke(app, mods, key, resendToSystem)
  local menuItemPath, enabled = findMenuItemByKeyBinding(app, mods, key)
  if menuItemPath ~= nil and enabled then
    app:selectMenuItem(menuItemPath)
  elseif resendToSystem then
    safeGlobalKeyStroke(mods, key)
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
      return win ~= nil and win:role() == "AXWindow", win
    end,
    repeatable = true,
    fn = function(win) win:close() end
  },
  ["minimize"] = {
    mods = "⌘", key = "M",
    message = commonLocalizedMessage("Minimize"),
    condition = function(app)
      local win = app:focusedWindow()
      return win ~= nil and win:role() == "AXWindow", win
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
      fn = showMenuItem
    },
    ["open1stSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open1stSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open1stSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(1),
      condition = getFinderSidebarItem(1),
      fn = openFinderSidebarItem,
      deleteOnDisable = true
    },
    ["open2ndSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open2ndSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open2ndSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(2),
      condition = getFinderSidebarItem(2),
      fn = openFinderSidebarItem,
      deleteOnDisable = true
    },
    ["open3rdSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open3rdSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open3rdSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(3),
      condition = getFinderSidebarItem(3),
      fn = openFinderSidebarItem,
      deleteOnDisable = true
    },
    ["open4thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open4thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open4thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(4),
      condition = getFinderSidebarItem(4),
      fn = openFinderSidebarItem,
      deleteOnDisable = true
    },
    ["open5thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open5thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open5thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(5),
      condition = getFinderSidebarItem(5),
      fn = openFinderSidebarItem,
      deleteOnDisable = true
    },
    ["open6thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open6thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open6thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(6),
      condition = getFinderSidebarItem(6),
      fn = openFinderSidebarItem,
      deleteOnDisable = true
    },
    ["open7thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open7thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open7thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(7),
      condition = getFinderSidebarItem(7),
      fn = openFinderSidebarItem,
      deleteOnDisable = true
    },
    ["open8thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open8thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open8thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(8),
      condition = getFinderSidebarItem(8),
      fn = openFinderSidebarItem,
      deleteOnDisable = true
    },
    ["open9thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open9thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open9thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(9),
      condition = getFinderSidebarItem(9),
      fn = openFinderSidebarItem,
      deleteOnDisable = true
    },
    ["open10thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open10thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open10thSidebarItemOnOpenSavePanel", "key"),
      message = getFinderSidebarItemTitle(10),
      condition = getFinderSidebarItem(10),
      fn = openFinderSidebarItem,
      deleteOnDisable = true
    }
  },

  ["com.apple.ActivityMonitor"] =
  {
    ["search"] = {
      message = commonLocalizedMessage("Search"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local searchField = getc(winUIObj, "AXToolbar", 1, "AXGroup", 2, "AXTextField", 1)
        if searchField == nil then return false end
        return true, searchField
      end,
      fn = function(searchField, app)
        local position = { searchField.AXPosition.x + 10, searchField.AXPosition.y + 2 }
        leftClickAndRestore(position, app:name())
      end
    }
  },

  ["com.apple.MobileSMS"] =
  {
    ["deleteConversation"] = {
      message = localizedMessage("Delete Conversation…"),
      condition = function(app)
        local appUIObj = hs.axuielement.applicationElement(app)
        local messageItems = getc(appUIObj, "AXWindow", 1, "AXGroup", 1, "AXGroup", 1,
            "AXGroup", 1, "AXGroup", 2, "AXGroup", 1, "AXGroup", 1, "AXStaticText")
        local selected = hs.fnutils.find(messageItems or {}, function(msg)
          return msg.AXSelected == true
        end)
        if selected == nil then return false end
        return checkMenuItem({
          getOSVersion() < OS.Ventura and "File" or "Conversation",
          "Delete Conversation…"
        })(app)
      end,
      fn = function(menuItemTitle, app) deleteSelectedMessage(app, menuItemTitle) end
    },
    ["deleteAllConversations"] = {
      message = "Delete All Conversations",
      condition = function(app)
        local appUIObj = hs.axuielement.applicationElement(app)
        local messageItems = getc(appUIObj, "AXWindow", 1, "AXGroup", 1, "AXGroup", 1,
            "AXGroup", 1, "AXGroup", 2, "AXGroup", 1, "AXGroup", 1, "AXStaticText")
        if messageItems == nil or #messageItems == 0
            or (#messageItems == 1 and (messageItems[1].AXDescription == nil
              or messageItems[1].AXDescription:sub(4) ==
                localizedString('New Message', app:bundleID()))) then
          return false
        end
        return true, messageItems
      end,
      fn = deleteAllMessages
    },
    ["goToPreviousConversation"] = {
      message = menuItemMessage('⇧⌃', "⇥", 2),
      condition = function(app)
        local appUIObj = hs.axuielement.applicationElement(app)
        local messageItems = getc(appUIObj, "AXWindow", 1, "AXGroup", 1, "AXGroup", 1,
            "AXGroup", 1, "AXGroup", 2, "AXGroup", 1, "AXGroup", 1, "AXStaticText")
        if messageItems == nil or #messageItems == 0 then return false end
        if messageItems[1].AXSelected then
          return true, messageItems[#messageItems]
        else
          local selected = hs.fnutils.find(messageItems, function(msg)
            return msg.AXSelected == true
          end)
          if selected == nil then return true, messageItems[#messageItems] end
        end
        return checkMenuItemByKeybinding('⇧⌃', "⇥")(app)
      end,
      repeatable = true,
      fn = function(result, app)
        if type(result) ~= 'table' then
          result:performAction("AXPress")
        else
          app:selectMenuItem(result)
        end
      end
    },
    ["goToNextConversation"] = {
      message = menuItemMessage('⌃', "⇥", 2),
      condition = function(app)
        local appUIObj = hs.axuielement.applicationElement(app)
        local messageItems = getc(appUIObj, "AXWindow", 1, "AXGroup", 1, "AXGroup", 1,
            "AXGroup", 1, "AXGroup", 2, "AXGroup", 1, "AXGroup", 1, "AXStaticText")
        if messageItems == nil or #messageItems == 0 then return false end
        if messageItems[#messageItems].AXSelected then
          return true, messageItems[1]
        else
          local selected = hs.fnutils.find(messageItems, function(msg)
            return msg.AXSelected == true
          end)
          if selected == nil then return true, messageItems[1] end
        end
        return checkMenuItemByKeybinding('⌃', "⇥")(app)
      end,
      repeatable = true,
      fn = function(result, app)
        if type(result) ~= 'table' then
          result:performAction("AXPress")
        else
          app:selectMenuItem(result)
        end
      end
    }
  },

  ["com.apple.FaceTime"] = {
    ["removeFromRecents"] = {
      message = localizedMessage("Remove from Recents"),
      condition = function(app)
        return app:focusedWindow() ~= nil, app:focusedWindow()
      end,
      fn = deleteMousePositionCall
    },
    ["clearAllRecents"] = {
      message = localizedMessage("Clear All Recents"),
      condition = function(app)
        return app:focusedWindow() ~= nil, app:focusedWindow()
      end,
      fn = deleteAllCalls
    },
    ["newFaceTime"] = {
      message = localizedMessage("New FaceTime"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local button = getc(winUIObj, "AXGroup", 1, "AXGroup", 1,
            "AXGroup", 1, "AXGroup", 1, "AXButton", 2)
        return button ~= nil, button
      end,
      fn = receiveButton
    }
  },

  ["com.apple.AppStore"] =
  {
    ["back"] = {
      message = localizedMessage("Back"),
      condition = function(app)
        local menuItem, menuItemTitle = findMenuItem(app, { "Store", "Back" })
        if menuItem ~= nil and menuItem.enabled then
          return true, menuItemTitle
        else
          if app:focusedWindow() == nil then return false end
          local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
          local button
          button = getc(winUIObj, "AXSplitGroup", 1, "AXGroup", 2, "AXButton", 1)
          if button ~= nil then return true, button end
          local g = getc(winUIObj, "AXGroup", 1)
          if g == nil then return false end
          button = hs.fnutils.find(getc(g, "AXButton"), function(b)
            return b.AXIdentifier == "UIA.AppStore.NavigationBackButton"
                or b.AXIdentifier == "AppStore.backButton"
          end)
          return button ~= nil, button
        end
      end,
      repeatable = true,
      fn = function(result, app)
        if type(result) == 'table' then
          app:selectMenuItem(result)
        else
          local button = result
          button:performAction("AXPress")
        end
      end
    }
  },

  ["com.apple.Safari"] =
  {
    ["showInFinder"] = {
      message = commonLocalizedMessage("Show in Finder"),
      condition = function(app)
        local ok, url = hs.osascript.applescript([[
          tell application id "]] .. app:bundleID() .. [[" to return URL of front document
        ]])
        if ok and string.sub(url, 1, 7) == "file://" then
          return true, url
        else
          return false
        end
      end,
      fn = function(url) hs.execute('open -R "' .. url .. '"') end
    },
    ["openRecent"] = {
      message = localizedMessage("Recently Closed"),
      condition = checkMenuItem({ "History", "Recently Closed" }),
      fn = showMenuItem
    }
  },

  ["com.apple.Preview"] =
  {
    ["showInFinder"] = {
      message = commonLocalizedMessage("Show in Finder"),
      condition = function(app)
        local ok, filePath = hs.osascript.applescript([[
          tell application id "]] .. app:bundleID() .. [[" to get path of front document
        ]])
        if ok then
          return true, filePath
        else
          return false
        end
      end,
      fn = function(filePath) hs.execute("open -R '" .. filePath .. "'") end
    }
  },

  ["com.google.Chrome"] =
  {
    ["showInFinder"] = {
      message = commonLocalizedMessage("Show in Finder"),
      condition = function(app)
        local ok, url = hs.osascript.applescript([[
          tell application id "]] .. app:bundleID() .. [[" to return URL of active tab of front window
        ]])
        if ok and string.sub(url, 1, 7) == "file://" then
          return true, url
        else
          return false
        end
      end,
      fn = function(url) hs.execute('open -R "' .. url .. '"') end
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
          local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
          return winUIObj.AXIdentifier ~= "open-panel"
        end
      end,
      repeatable = true,
      fn = function(app)
        VSCodeToggleSideBarSection(app, "EXPLORER", "OUTLINE")
      end
    },
    ["toggleSearchEditorWholeWord"] = {
      message = "Search Editor: Toggle Match Whole Word",
      condition = function(app)
        if app:focusedWindow() == nil then
          return false
        else
          local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
          return winUIObj.AXIdentifier ~= "open-panel"
        end
      end,
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke("⌘⌥", "W", nil, app) end
    },
    ["openRecent"] = {
      message = "Open Recent",
      condition = function(app)
        local enabled, menuItem = checkMenuItem({ "File", "Open Recent", "More…" })(app)
        if enabled then
          return true, menuItem
        else
          return checkMenuItem({ "File", "Open Recent" })(app)
        end
      end,
      fn = function(menuItemTitle, app)
        if #menuItemTitle == 3 then
          app:selectMenuItem(menuItemTitle)
        else
          showMenuItem(menuItemTitle, app)
        end
      end
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
          local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
          return winUIObj.AXIdentifier ~= "open-panel"
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
    ["openRecent"] = {
      message = localizedMessage("Recent Documents"),
      condition = checkMenuItem({ "File", "Recent Documents" }),
      fn = showMenuItem
    }
  },

  ["abnerworks.Typora"] =
  {
    ["openFileLocation"] = {
      message = localizedMessage("Open File Location"),
      condition = checkMenuItem({ "File", "Open File Location" }),
      fn = receiveMenuItem
    },
    ["pasteAsPlainText"] = {
      message = localizedMessage("Paste as Plain Text"),
      repeatable = true,
      fn = function(app)
        selectMenuItem(app, { "Edit", "Paste as Plain Text" })
      end
    },
    ["openRecent"] = {
      message = localizedMessage("Open Recent"),
      condition = function(app)
        local enabled, menuItemPath = checkMenuItem({ "File", "Open Quickly…" })(app)
        if enabled then
          return true, { 1, menuItemPath }
        end
        enabled, menuItemPath = checkMenuItem({ "File", "Open Recent" })(app)
        if enabled then
          return true, { 2, menuItemPath }
        end
        return false
      end,
      fn = function(result, app)
        if result[1] == 1 then
          receiveMenuItem(result[2], app)
        else
          showMenuItem(result[2], app)
        end
      end
    }
  },

  ["com.superace.updf.mac"] =
  {
    ["showPrevTab"] = specialCommonHotkeyConfigs["showPrevTab"],
    ["showNextTab"] = specialCommonHotkeyConfigs["showNextTab"],
    ["showInFinder"] = {
      message = localizedMessage("Show in Finder"),
      condition = checkMenuItem({ "File", "Show in Finder" }),
      fn = receiveMenuItem
    },
    ["confirmDelete"] = {
      message = localizedMessage("Don't Save"),
      condition = function(app)
        local win = app:focusedWindow()
        if win == nil then return false end
        local winUIObj = hs.axuielement.windowElement(win)
        local buttons = getc(winUIObj, "AXButton")
        local title = localizedString("Don't Save", app:bundleID())
        for _, button in ipairs(buttons) do
          if button.AXTitle == title then
            return true, button
          end
        end
        return false
      end,
      fn = receiveButton
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
      condition = function(app)
        local titleMap = delocMap[app:bundleID()]  -- hack for multi-map
        if titleMap ~= nil then
          local localizedFile = localizedMenuBarItem('File', app:bundleID())
          for k, v in pairs(titleMap) do
            if 'Export to PDF...' == v then
              local localizedTitle = k
              local menuItemPath = { localizedFile, localizedTitle }
              local menuItem = app:findMenuItem(menuItemPath)
              if menuItem ~= nil then
                return menuItem.enabled, menuItemPath
              end
            end
          end
        end
        local menuItemPath = { 'File', 'Export to PDF...' }
        local menuItem = app:findMenuItem(menuItemPath)
        return menuItem ~= nil and menuItem.enabled, menuItemPath
      end,
      fn = receiveMenuItem
    },
    ["insertTextBox"] = {
      message = localizedMessage({ "Insert", "Text Box" }),
      condition = function(app)
        local titleMap = delocMap[app:bundleID()]  -- hack for multi-map
        if titleMap ~= nil then
          local localizedInsert = localizedMenuBarItem('Insert', app:bundleID())
          local localizedTextBox = localizedMenuItem('Text Box', app:bundleID())
          for k, v in pairs(titleMap) do
            if 'Horizontal Text Box' == v then
              local localizedTitle = k
              local menuItemPath = { localizedInsert, localizedTextBox, localizedTitle }
              local menuItem = app:findMenuItem(menuItemPath)
              if menuItem ~= nil then
                return menuItem.enabled, menuItemPath
              end
            end
          end
        end
        local menuItemPath = { 'Insert', 'Text Box', 'Horizontal Text Box' }
        local menuItem = app:findMenuItem(menuItemPath)
        return menuItem ~= nil and menuItem.enabled, menuItemPath
      end,
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
    ["openRecent"] = {
      message = localizedMessage("Recent"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local home = localizedString("Home", app:bundleID())
        return app:focusedWindow():title() == home, app:focusedWindow()
      end,
      fn = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local button = getc(winUIObj, "AXSplitGroup", 1, "AXGroup", 4, "AXGroup", 1)
        local position = { button.AXPosition.x + 30, button.AXPosition.y + 10 }
        leftClickAndRestore(position, win:application():name())
      end
    },
    ["openFileLocation"] = {
      message = localizedMessage("Open File Location"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local win = app:focusedWindow()
        local winUIObj = hs.axuielement.windowElement(win)
        for i=1,#winUIObj.AXChildren - 1 do
          if winUIObj.AXChildren[i].AXRole == "AXButton"
              and winUIObj.AXChildren[i + 1].AXRole == "AXGroup" then
            return true, winUIObj.AXChildren[i].AXPosition
          end
        end
        return false
      end,
      fn = function(position, app)
        if not rightClickAndRestore(position, app:name()) then return end
        local title = localizedString("Open File Location", app:bundleID())
        hs.osascript.applescript([[
          tell application "System Events"
            tell first application process whose bundle identifier is "]] .. app:bundleID() .. [["
              set totalDelay to 0.0
              repeat until totalDelay > 0.5
                repeat with e in ui elements
                  if exists menu item "]] .. title .. [[" of menu 1 of e then
                    perform action 1 of menu item "]] .. title .. [[" of menu 1 of e
                    return true
                  end if
                end repeat
                delay 0.05
                set totalDelay to totalDelay + 0.05
              end repeat
              return false
            end tell
          end tell
        ]])
      end
    }
  },

  ["com.apple.iWork.Keynote"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = localizedMessage({ "Export To", "PDF…" }),
      condition = checkMenuItem({ "File", "Export To", "PDF…" }),
      fn = function(menuItemTitle, app)
        app:selectMenuItem({ menuItemTitle[1], menuItemTitle[2] })
        app:selectMenuItem(menuItemTitle)
      end
    },
    ["exportToPPT"] = {  -- File > Export To > PowerPoint…
      message = localizedMessage({ "Export To", "PowerPoint…" }),
      condition = checkMenuItem({ "File", "Export To", "PowerPoint…" }),
      fn = function(menuItemTitle, app)
        app:selectMenuItem({ menuItemTitle[1], menuItemTitle[2] })
        app:selectMenuItem(menuItemTitle)
      end
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
          local winTitle = localizedString("Build Order", app:bundleID())
          local window = hs.fnutils.ifilter(app:visibleWindows(), function(win)
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
      fn = showMenuItem
    },
    ["insertLine"] = {  -- Insert > Line
      message = localizedMessage({ "Insert", "Line" }),
      condition = checkMenuItem({ "Insert", "Line" }),
      fn = showMenuItem
    },
    ["showInFinder"] = {
      message = commonLocalizedMessage("Show in Finder"),
      condition = function(app)
        local ok, filePath = hs.osascript.applescript([[
          tell application id "]] .. app:bundleID() .. [[" to get file of front document
        ]])
        if ok and filePath ~= nil then
          local pos = string.find(filePath, ":", 1)
          assert(pos)
          filePath = string.sub(filePath, pos)
          filePath = string.gsub(filePath, ":", "/")
          return true, filePath
        else
          return false
        end
      end,
      fn = function(filePath) hs.execute("open -R '" .. filePath .. "'") end
    },
  },

  ["com.apple.iWork.Pages"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = localizedMessage({ "Export To", "PDF…" }),
      condition = checkMenuItem({ "File", "Export To", "PDF…" }),
      fn = function(menuItemTitle, app)
        app:selectMenuItem({ menuItemTitle[1], menuItemTitle[2] })
        app:selectMenuItem(menuItemTitle)
      end
    },
    ["exportToWord"] = {  -- File > Export To > Word…
      message = localizedMessage({ "Export To", "Word…" }),
      condition = checkMenuItem({ "File", "Export To", "Word…" }),
      fn = function(menuItemTitle, app)
        app:selectMenuItem({ menuItemTitle[1], menuItemTitle[2] })
        app:selectMenuItem(menuItemTitle)
      end
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
        local ok, filePath = hs.osascript.applescript([[
          tell application id "]] .. app:bundleID() .. [[" to get file of front document
        ]])
        if ok and filePath ~= nil then
          local pos = string.find(filePath, ":", 1)
          assert(pos)
          filePath = string.sub(filePath, pos)
          filePath = string.gsub(filePath, ":", "/")
          return true, filePath
        else
          return false
        end
      end,
      fn = function(filePath) hs.execute("open -R '" .. filePath .. "'") end
    },
  },

  ["com.apple.iWork.Numbers"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = localizedMessage({ "Export To", "PDF…" }),
      condition = checkMenuItem({ "File", "Export To", "PDF…" }),
      fn = function(menuItemTitle, app)
        app:selectMenuItem({ menuItemTitle[1], menuItemTitle[2] })
        app:selectMenuItem(menuItemTitle)
      end
    },
    ["exportToExcel"] = {  -- File > Export To > Excel…
      message = localizedMessage({ "Export To", "Excel…" }),
      condition = checkMenuItem({ "File", "Export To", "Excel…" }),
      fn = function(menuItemTitle, app)
        app:selectMenuItem({ menuItemTitle[1], menuItemTitle[2] })
        app:selectMenuItem(menuItemTitle)
      end
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
        local ok, filePath = hs.osascript.applescript([[
          tell application id "]] .. app:bundleID() .. [[" to get file of front document
        ]])
        if ok and filePath ~= nil then
          local pos = string.find(filePath, ":", 1)
          assert(pos)
          filePath = string.sub(filePath, pos)
          filePath = string.gsub(filePath, ":", "/")
          return true, filePath
        else
          return false
        end
      end,
      fn = function(filePath) hs.execute("open -R '" .. filePath .. "'") end
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
      message = localizedMessage("词典"),
      condition = checkMenuItem({ "功能", "返回首页" }),
      fn = receiveMenuItem
    },
    ["function2"] = {
      message = localizedMessage("百科"),
      condition = checkMenuItem({ "功能", "百科" }),
      fn = receiveMenuItem
    },
    ["function3"] = {
      message = localizedMessage("翻译写作"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local button = getc(winUIObj, "AXToolbar", 1, "AXButton", 3)
        return button ~= nil, button
      end,
      fn = receiveButton
    },
    ["function4"] = {
      message = localizedMessage("生词笔记"),
      condition = checkMenuItem({ "功能", "我的学习记录" }),
      fn = receiveMenuItem
    },
    ["function5"] = {
      message = localizedMessage("背单词"),
      condition = checkMenuItem({ "功能", "背单词" }),
      fn = receiveMenuItem
    },
    ["function6"] = {
      message = function(app)
        return (localizedString("管 理", app:bundleID()) or "管 理"):gsub(' ', '')
      end,
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local button = getc(winUIObj, "AXToolbar", 1, "AXButton", 6)
        return button ~= nil, button
      end,
      fn = receiveButton
    }
  },

  ["com.openai.chat"] =
  {
    ["toggleSidebar"] = {
      message = localizedMessage("Toggle Sidebar"),
      bindCondition = function(app)
        if versionLessEqual("1.2024.332")(app) then return true end
        local keybinding = get(KeybindingConfigs.hotkeys,
            app:bundleID(), "toggleSidebar")
        local menuItemPath = findMenuItemByKeyBinding(app, keybinding.mods, keybinding.key)
        local menuItemTitle = localizedString("Toggle Sidebar", app:bundleID())
        if menuItemPath == nil
            or menuItemPath[#menuItemPath] ~= menuItemTitle then
          return true
        end
        return false
      end,
      condition = checkMenuItem({ "View", "Toggle Sidebar" }),
      fn = receiveMenuItem
    },
    ["back"] = {
      message = commonLocalizedMessage("Back"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        if winUIObj.AXIdentifier ~= "ChatGPTSettingsAppWindow" then
          return false
        end
        local button = getc(winUIObj, "AXToolbar", 1, "AXButton", 1, "AXButton", 1)
        return button ~= nil and button.AXEnabled, button
      end,
      fn = receiveButton
    },
    ["toggleLauncher"] = {
      message = "Toggle ChatGPT Launcher",
      fn = function(app)
        local appid = app:bundleID()
        local output = hs.execute(string.format(
            "defaults read '%s' KeyboardShortcuts_toggleLauncher | tr -d '\\n'", appid))
        if output == "0" then
          local spec = KeybindingConfigs.hotkeys[appid]["toggleLauncher"]
          local mods, key = dumpPlistKeyBinding(1, spec.mods, spec.key)
          hs.execute(string.format(
              [[defaults write '%s' KeyboardShortcuts_toggleLauncher -string '{"carbonKeyCode":%d,"carbonModifiers":%d}']],
              appid, key, mods))
          app:kill()
          hs.timer.doAfter(1, function()
            hs.execute(string.format("open -g -b '%s'", appid))
            hs.timer.doAfter(1, function()
              safeGlobalKeyStroke(spec.mods, spec.key)
            end)
          end)
        else
          local json = hs.json.decode(output)
          local mods, key = parsePlistKeyBinding(json["carbonModifiers"], json["carbonKeyCode"])
          if mods == nil or key == nil then return end
          safeGlobalKeyStroke(mods, key)
        end
      end,
    }
  },

  ["com.tencent.yuanbao"] =
  {
    ["settings"] = {
      message = "设置",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local webarea = getc(winUIObj, "AXGroup", 1, "AXGroup", 1,
          "AXScrollArea", 1, "AXWebArea", 1)
        if webarea == nil then return false end
        local button = hs.fnutils.find(getc(webarea, "AXGroup"), function(b)
          return hs.fnutils.find(b.AXDOMClassList or {}, function(c)
            return c:find("side%-bar_name") ~= nil
          end) ~= nil
        end)
        if button ~= nil and button.AXPosition.x ~= winUIObj.AXPosition.x then
          return true, button.AXPosition
        else
          return false
        end
      end,
      fn = receivePosition
    },
    ["newChat"] = {
      message = "新建对话",
      bindCondition = versionLessThan("1.6.0"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local webarea = getc(winUIObj, "AXGroup", 1, "AXGroup", 1,
            "AXScrollArea", 1, "AXWebArea", 1)
        if webarea == nil then return false end
        local button = hs.fnutils.find(getc(webarea, "AXGroup"), function(b)
          return hs.fnutils.find(b.AXDOMClassList or {}, function(c)
            return c:find("chat_new%-chat%-close") ~= nil
                or c:find("side%-bar_newChatIcon") ~= nil
          end) ~= nil
        end)
        return button ~= nil, button
      end,
      fn = receiveButton
    },
    ["toggleSidebar"] = {
      message = "切换侧栏",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local webarea = getc(winUIObj, "AXGroup", 1, "AXGroup", 1,
            "AXScrollArea", 1, "AXWebArea", 1)
        if webarea == nil then return false end
        local button = hs.fnutils.find(getc(webarea, "AXGroup"), function(b)
          return hs.fnutils.find(b.AXDOMClassList or {}, function(c)
            return c:find("folder_foldIcon") ~= nil
          end) ~= nil
        end)
        return button ~= nil, button
      end,
      fn = receiveButton
    },
    ["maximize"] = {
      mods = get(KeybindingConfigs.hotkeys.shared, "zoom", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared, "zoom", "key"),
      message = "最大化",
      condition = checkMenuItem({"窗口", "最大化"}),
      fn = receiveMenuItem
    },
    ["back"] = {
      message = "返回",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local webarea = getc(winUIObj, "AXGroup", 1, "AXGroup", 1,
            "AXScrollArea", 1, "AXWebArea", 1)
        if webarea == nil then return false end
        local button = hs.fnutils.find(getc(webarea, "AXGroup"), function(b)
          return hs.fnutils.find(b.AXDOMClassList or {}, function(c)
            return c:find("setting_arrowLeft") ~= nil
          end) ~= nil
        end)
        return button ~= nil, button
      end,
      fn = receiveButton
    },
    ["toggleLauncher"] = {
      message = function(app)
        local appname = displayName(app)
        return "Toggle " .. appname .. " Launcher"
      end,
      fn = function(app)
        if find('com.surteesstudios.Bartender') then
          -- fixme: false invoke when `Bartender` try to show or hide menubar icon
          -- always show the icon to workaround it
          hs.osascript.applescript([[
            tell application id "com.surteesstudios.Bartender" to activate "]] .. app:bundleID() .. [[-Item-0"
          ]])
        else
          local appUIObj = hs.axuielement.applicationElement(app)
          local menuBarMenu = getc(appUIObj, "AXMenuBar", -1, "AXMenuBarItem", 1)
          local position = {
            menuBarMenu.AXPosition.x + menuBarMenu.AXSize.w / 2,
            menuBarMenu.AXPosition.y + menuBarMenu.AXSize.h / 2,
          }
          leftClickAndRestore(position, app:name())
        end
      end,
      onLaunch = function(app)
        app:focusedWindow():close()
        app:hide()
        hs.timer.usleep(1000000)
        if find('com.surteesstudios.Bartender') then
          hs.osascript.applescript([[
            tell application id "com.surteesstudios.Bartender" to activate "]] .. app:bundleID() .. [[-Item-0"
          ]])
        else
          local appUIObj = hs.axuielement.applicationElement(app)
          local menuBarMenu = getc(appUIObj, "AXMenuBar", -1, "AXMenuBarItem", 1)
          local position = {
            menuBarMenu.AXPosition.x + menuBarMenu.AXSize.w / 2,
            menuBarMenu.AXPosition.y + menuBarMenu.AXSize.h / 2,
          }
          leftClickAndRestore(position, app:name())
        end
      end
    },
    ["showMainWindow"] = {
      message = "Show Main Window",
      windowFilter = {
        allowRoles = "AXSystemDialog"
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
      message = "Preferences",
      condition = checkMenuItem({ "File", "Preferences" }),
      fn = receiveMenuItem
    },
    ["newLibrary"] = {
      message = "New Library",
      condition = checkMenuItem({ "File", "New library" }),
      fn = receiveMenuItem
    },
    ["openRecent"] = {
      message = "Recent Libraries",
      condition = checkMenuItem({ "File", "Recent libraries" }),
      fn = showMenuItem
    },
    ["remapPreviousTab"] = {
      message = "Previous Library",
      condition = JabRefShowLibraryByIndex(2),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⇧⌃', 'Tab', nil, app) end
    },
    ["showPrevLibrary"] = {
      mods = specialCommonHotkeyConfigs["showPrevTab"].mods,
      key = specialCommonHotkeyConfigs["showPrevTab"].key,
      message = "Previous Library",
      condition = JabRefShowLibraryByIndex(2),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⇧⌃', 'Tab', nil, app) end
    },
    ["showNextLibrary"] = {
      mods = specialCommonHotkeyConfigs["showNextTab"].mods,
      key = specialCommonHotkeyConfigs["showNextTab"].key,
      message = "Next Library",
      condition = JabRefShowLibraryByIndex(2),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⌃', 'Tab', nil, app) end
    },
    ["1stLibrary"] = {
      message = "First Library",
      condition = JabRefShowLibraryByIndex(1),
      fn = receivePosition
    },
    ["2ndLibrary"] = {
      message = "Second Library",
      condition = JabRefShowLibraryByIndex(2),
      fn = receivePosition
    },
    ["3rdLibrary"] = {
      message = "Third Library",
      condition = JabRefShowLibraryByIndex(3),
      fn = receivePosition
    },
    ["4thLibrary"] = {
      message = "Forth Library",
      condition = JabRefShowLibraryByIndex(4),
      fn = receivePosition
    },
    ["5thLibrary"] = {
      message = "Fifth Library",
      condition = JabRefShowLibraryByIndex(5),
      fn = receivePosition
    },
    ["6thLibrary"] = {
      message = "Sixth Library",
      condition = JabRefShowLibraryByIndex(6),
      fn = receivePosition
    },
    ["7thLibrary"] = {
      message = "Seventh Library",
      condition = JabRefShowLibraryByIndex(7),
      fn = receivePosition
    },
    ["8thLibrary"] = {
      message = "Eighth Library",
      condition = JabRefShowLibraryByIndex(8),
      fn = receivePosition
    },
    ["9thLibrary"] = {
      message = "Nineth Library",
      condition = JabRefShowLibraryByIndex(9),
      fn = receivePosition
    },
    ["10thLibrary"] = {
      message = "Tenth Library",
      condition = JabRefShowLibraryByIndex(10),
      fn = receivePosition
    },
    ["minimize"] = specialCommonHotkeyConfigs["minimize"]
  },

  ["org.klatexformula.klatexformula"] =
  {
    ["render"] = {
      message = "Render",
      windowFilter = {
        allowTitles = "^KLatexFormula$"
      },
      fn = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local button = getc(winUIObj, "AXSplitGroup", 1, "AXButton", 2)
        if button ~= nil then
          button:performAction("AXPress")
        end
      end
    },
    ["renderClipboardInKlatexformula"] = {
      message = "Render Clipboard in klatexformula",
      fn = function(app)
        app:mainWindow():focus()
        app:selectMenuItem({"Shortcuts", "Activate Editor and Select All"})
        hs.eventtap.keyStroke("⌘", "V", nil, app)

        local winUIObj = hs.axuielement.windowElement(app:mainWindow())
        local button = getc(winUIObj, "AXSplitGroup", 1, "AXButton", 2)
        if button ~= nil then
          button:performAction("AXPress")
        end
      end
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
      fn = showMenuItem
    }
  },

  ["com.tencent.xinWeChat"] =
  {
    ["back"] = {
      message = localizedMessage("Common.Navigation.Back"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local appid = app:bundleID()

        -- CEF Window
        local exBundleID = "com.tencent.xinWeChat.WeChatAppEx"
        local menuItemPath = {
          localizedMenuBarItem('File', appid),
          localizedString('Back', exBundleID)
        }
        if #menuItemPath == 2 then
          local menuItem = app:findMenuItem(menuItemPath)
          if menuItem ~= nil and menuItem.enabled then
            return true, { 0, menuItemPath }
          end
        end

        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        -- Moments
        if string.find(app:focusedWindow():title(), app:name()) == nil then
          local album = localizedString("Album_WindowTitle", appid)
          local moments = localizedString("SNS_Feed_Window_Title", appid)
          local detail = localizedString("SNS_Feed_Detail_Title", appid)
          if string.find(app:focusedWindow():title(), album .. '-') == 1
              or app:focusedWindow():title() == moments .. '-' .. detail then
            return true, { 2, getc(winUIObj, "AXButton", 1).AXPosition }
          end
          return false
        end

        -- Official Accounts
        local back = localizedString("Common.Navigation.Back", appid)
        local g = getc(winUIObj, "AXSplitGroup", 1, "AXSplitGroup", 1)
        if g ~= nil then
          for _, bt in ipairs(getc(g, "AXButton")) do
            if bt.AXTitle == back then
              return true, { 1, bt }
            end
          end
        end
        return false
      end,
      fn = function(result, app)
        if result[1] == 0 then
          app:selectMenuItem(result[2])
        elseif result[1] == 1 then
          result[2]:performAction("AXPress")
        elseif result[1] == 2 then
          leftClickAndRestore(result[2], app:name())
        end
      end
    },
    ["hideChat"] = {
      message = localizedMessage("Chats.Menu.Hide"),
      condition = function(app)
        if app:focusedWindow() == nil then return end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local curChatTitle = getc(winUIObj, "AXSplitGroup", 1,
            "AXSplitGroup", 1, "AXStaticText", 1)
            or getc(winUIObj, "AXSplitGroup", 1, "AXStaticText", 1)
        if curChatTitle == nil then return false end
        local title = curChatTitle.AXValue
        local chats = getc(winUIObj, "AXSplitGroup", 1,
            "AXScrollArea", 1, "AXTable", 1, "AXRow")
        local curChat = hs.fnutils.find(chats, function(c)
          local row = getc(c, "AXCell", 1, "AXRow", 1)
          return row ~= nil and (row.AXTitle == title
              or row.AXTitle:sub(1, #title + 1) == title .. ",")
        end)
        return curChat ~= nil, curChat
      end,
      fn = function(chat)
        getc(chat, "AXCell", 1):performAction("AXShowMenu")
        local menu = getc(chat, "AXCell", 1, "AXRow", 1, "AXMenu", 1)
        if menu then
          local hide = hs.fnutils.find(getc(menu, "AXMenuItem"),
              function(c) return c.AXIdentifier == "contextMenuHide:" end)
          if hide then hide:performAction("AXPress") end
        end
      end
    },
    ["showChatProfile"] = {
      message = localizedMessage("Chats.Menu.Profile"),
      condition = function(app)
        if app:focusedWindow() == nil then return end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local curChatTitle = getc(winUIObj, "AXSplitGroup", 1,
            "AXSplitGroup", 1, "AXStaticText", 1)
        if curChatTitle == nil then return false end
        local btTitle = localizedString("ComposeBar.VideoTooltip", app:bundleID())
        local bt = getc(winUIObj, "AXSplitGroup", 1,
            "AXSplitGroup", 1, "AXButton", btTitle)
        return bt ~= nil, curChatTitle.AXValue
      end,
      fn = function(title, app)
        if app:focusedWindow() == nil then return end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local chats = getc(winUIObj, "AXSplitGroup", 1,
            "AXScrollArea", 1, "AXTable", 1, "AXRow")
        local curChat = hs.fnutils.find(chats, function(c)
          local row = getc(c, "AXCell", 1, "AXRow", 1)
          return row ~= nil and (row.AXTitle == title
              or row.AXTitle:sub(1, #title + 1) == title .. ",")
        end)
        if curChat ~= nil then
          getc(curChat, "AXCell", 1):performAction("AXShowMenu")
          local menu = getc(curChat, "AXCell", 1,
              "AXRow", 1, "AXMenu", 1)
          if menu then
            local profile = hs.fnutils.find(getc(menu, "AXMenuItem"),
                function(c) return c.AXIdentifier == "contextMenuProfile:" end)
            if profile then profile:performAction("AXPress") end
          end
        end
      end
    },
    ["openInDefaultBrowser"] = {
      message = localizedMessage("Open in Default Browser"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local g = getc(winUIObj, "AXGroup", 1)
        return g ~= nil and g.AXDOMClassList ~= nil
      end,
      fn = function(app)
        local frame = app:focusedWindow():frame()
        local position = { frame.x + frame.w - 60, frame.y + 23 }
        leftClickAndRestore(position, app:name())
      end
    }
  },

  ["com.tencent.QQMusicMac"] =
  {
    ["back"] = {
      message = "上一页",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local titleBarUIObj
        if versionLessThan("10.3.0")(app) then
          local appUIObj = hs.axuielement.applicationElement(app)
          local frame = app:focusedWindow():frame()
          titleBarUIObj = appUIObj:elementAtPosition(frame.x + 100, frame.y + 10)
        else
          local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
          titleBarUIObj = getc(winUIObj, "AXUnknown", 3)
          if titleBarUIObj == nil then return false end
        end
        for _, button in ipairs(titleBarUIObj.AXChildren or {}) do
          if button.AXHelp == "后退" then
            return true, button.AXPosition
          end
        end
        return false
      end,
      repeatable = true,
      fn = function(position, app)
        leftClickAndRestore({ position.x + 5, position.y + 5 }, app:name(), 0.1)
      end
    },
    ["forward"] = {
      message = "下一页",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local titleBarUIObj
        if versionLessThan("10.3.0")(app) then
          local appUIObj = hs.axuielement.applicationElement(app)
          local frame = app:focusedWindow():frame()
          titleBarUIObj = appUIObj:elementAtPosition(frame.x + 100, frame.y + 10)
        else
          local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
          titleBarUIObj = getc(winUIObj, "AXUnknown", 3)
          if titleBarUIObj == nil then return false end
        end
        for _, button in ipairs(titleBarUIObj.AXChildren or {}) do
          if button.AXHelp == "前进" then
            return true, button.AXPosition
          end
        end
        return false
      end,
      repeatable = true,
      fn = function(position, app)
        leftClickAndRestore({ position.x + 5, position.y + 5 }, app:name(), 0.1)
      end
    },
    ["refresh"] = {
      message = "刷新",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local titleBarUIObj
        if versionLessThan("10.3.0")(app) then
          local appUIObj = hs.axuielement.applicationElement(app)
          local frame = app:focusedWindow():frame()
          titleBarUIObj = appUIObj:elementAtPosition(frame.x + 100, frame.y + 10)
        else
          local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
          titleBarUIObj = getc(winUIObj, "AXUnknown", 3)
          if titleBarUIObj == nil then return false end
        end
        local refreshButtonPosition, searchButtonPosition
        for _, button in ipairs(titleBarUIObj.AXChildren or {}) do
          if button.AXHelp == "刷新" then
            refreshButtonPosition = button.AXPosition
          elseif button.AXHelp == nil then
            searchButtonPosition = button.AXPosition
          end
        end
        return refreshButtonPosition ~= nil and searchButtonPosition ~= nil
            and refreshButtonPosition.x ~= searchButtonPosition.x, refreshButtonPosition
      end,
      fn = function(position, app)
        leftClickAndRestore({ position.x + 5, position.y + 5 }, app:name(), 0.1)
      end
    },
    ["playBarCloseSingleSong"] = {
      message = "关闭单曲",
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        if versionLessThan("9")(app) then
          local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
          local buttons = getc(winUIObj, "AXButton")
          return #buttons > 4 and getc(winUIObj, "AXButton", '歌曲详情') ~= nil
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
        local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
        local buttons = getc(winUIObj, "AXButton")
        buttons[#buttons - 2]:performAction("AXPress")
      end
    }
  },

  ["com.tencent.tenvideo"] =
  {
    ["openRecent"] = {
      message = "最近打开",
      fn = function(app)
        local appUIObj = hs.axuielement.applicationElement(app)
        local menuBarItems = getc(appUIObj, 'AXMenuBar', 1,'AXMenuBarItem')
        local menuBarItem = hs.fnutils.find(menuBarItems, function(item)
          return item.AXChildren ~= nil and #item.AXChildren > 0 and item.AXTitle == '文件'
        end)
        if menuBarItem == nil then return end
        local menuItem = hs.fnutils.find(getc(menuBarItem, 'AXMenu', 1,'AXMenuItem'),
                                         function(item) return item.AXTitle == '最近打开' end)
        if menuItem ~= nil then
          menuBarItem:performAction('AXPress')
          menuItem:performAction('AXPress')
        end
      end
    }
  },

  ["com.tencent.meeting"] =
  {
    ["preferences"] = {
      message = "偏好设置",
      fn = function(app) app:selectMenuItem({ app:name(), "偏好设置" }) end
    }
  },

  ["com.tencent.LemonMonitor"] =
  {
    ["closeWindow"] = {
      message = commonLocalizedMessage("Close Window"),
      windowFilter = {},
      background = true,
      nonFrontmost = true,
      fn = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        leftClickAndRestore({ x = winUIObj.AXPosition.x + winUIObj.AXSize.w/2,
                              y = winUIObj.AXPosition.y })
      end
    }
  },

  ["com.nektony.App-Cleaner-SIII"] =
  {
    ["uninstall"] = {
      message = localizedMessage('Uninstall'),
      windowFilter = true,
      condition = buttonValidForAppCleanerUninstaller('Uninstall'),
      fn = receiveButton
    },
    ["remove"] = {
      message = localizedMessage('Remove'),
      windowFilter = true,
      condition = buttonValidForAppCleanerUninstaller('Remove'),
      fn = receiveButton
    },
    ["enable"] = {
      message = localizedMessage('Enable'),
      windowFilter = true,
      condition = buttonValidForAppCleanerUninstaller('Enable'),
      fn = receiveButton
    },
    ["disable"] = {
      message = localizedMessage('Disable'),
      windowFilter = true,
      condition = buttonValidForAppCleanerUninstaller('Disable'),
      fn = receiveButton
    },
    ["update"] = {
      message = localizedMessage('Update'),
      windowFilter = true,
      condition = buttonValidForAppCleanerUninstaller('Update'),
      fn = receiveButton
    },
    ["confirmRemove"] = {
      message = localizedMessage('Remove'),
      windowFilter = true,
      condition = confirmButtonValidForAppCleanerUninstaller('Remove'),
      fn = function(position, win)
        -- fixme: false click
        leftClick(position, win:application():name())
      end
    },
    ["confirmUpdate"] = {
      message = localizedMessage('Update'),
      windowFilter = true,
      condition = confirmButtonValidForAppCleanerUninstaller('Update'),
      fn = function(position, win)
        -- fixme: false click
        leftClick(position, win:application():name())
      end
    },
    ["confirmRetry"] = {
      message = localizedMessage('Retry'),
      windowFilter = true,
      condition = confirmButtonValidForAppCleanerUninstaller('Retry'),
      fn = function(position, win)
        -- fixme: false click
        leftClick(position, win:application():name())
      end
    }
  },

  ["com.nektony.App-Cleaner-SIIICn"] =
  {
    ["remove"] = {
      message = localizedMessage('Remove_Button_Title'),
      windowFilter = true,
      condition = buttonValidForAppCleanerUninstaller('Remove_Button_Title'),
      fn = receiveButton
    },
    ["enable"] = {
      message = localizedMessage('EnableMenuItemTitle'),
      windowFilter = true,
      condition = buttonValidForAppCleanerUninstaller('EnableMenuItemTitle'),
      fn = receiveButton
    },
    ["disable"] = {
      message = localizedMessage('DisableMenuItemTitle'),
      windowFilter = true,
      condition = buttonValidForAppCleanerUninstaller('DisableMenuItemTitle'),
      fn = receiveButton
    },
    ["update"] = {
      message = localizedMessage('UpdateButtonTitle'),
      windowFilter = true,
      condition = buttonValidForAppCleanerUninstaller('UpdateButtonTitle'),
      fn = receiveButton
    },
    ["confirmRemove"] = {
      message = localizedMessage('PartialRemove_Remove'),
      windowFilter = true,
      condition = confirmButtonValidForAppCleanerUninstaller('PartialRemove_Remove'),
      fn = function(position, win)
        -- fixme: false click
        leftClick(position, win:application():name())
      end
    },
    ["confirmUpdate"] = {
      message = localizedMessage('UpdateButtonTitle'),
      windowFilter = true,
      condition = confirmButtonValidForAppCleanerUninstaller('UpdateButtonTitle'),
      fn = function(position, win)
        -- fixme: false click
        leftClick(position, win:application():name())
      end
    },
    ["confirmRetry"] = {
      message = localizedMessage('PartialRemove_Retry'),
      windowFilter = true,
      condition = confirmButtonValidForAppCleanerUninstaller('PartialRemove_Retry'),
      fn = function(position, win)
        -- fixme: false click
        leftClick(position, win:application():name())
      end
    }
  },

  ["barrier"] =
  {
    ["toggleBarrierConnect"] = {
      message = "Toggle Barrier Connect",
      fn = function(app)
        local appUIObj = hs.axuielement.applicationElement(app)
        local menu = getc(appUIObj, "AXMenuBar", 2, "AXMenuBarItem", 1, "AXMenu", 1)
        if menu == nil then
          clickRightMenuBarItem(app)
          menu = getc(appUIObj, "AXMenuBar", 2, "AXMenuBarItem", 1, "AXMenu", 1)
        end
        local start = getc(menu, "AXMenuItem", "Start")
        assert(start)
        if start.AXEnabled then
          start:performAction("AXPress")
          hs.alert("Barrier started")
        else
          local stop = getc(menu, "AXMenuItem", "Stop")
          assert(stop)
          stop:performAction("AXPress")
          hs.alert("Barrier stopped")
        end
      end,
      onLaunch = function(app)
        if app:focusedWindow() == nil then
          hs.alert("Error occurred")
        else
          local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
          local start = getc(winUIObj, "AXButton", "Start")
          assert(start)
          start:performAction("AXPress")
          hs.alert("Barrier started")
          hs.timer.doAfter(0.5, function()
            local close = getc(winUIObj, "AXButton", 4)
            assert(close)
            close:performAction("AXPress")
          end)
        end
      end
    },
    ["reload"] = {
      message = "Reload",
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local reload = getc(winUIObj, "AXButton", "Reload")
        return reload ~= nil and #reload:actionNames() > 0, reload
      end,
      fn = receiveButton
    },
    ["start"] = {
      message = "Start",
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local start = getc(winUIObj, "AXButton", "Start")
        return start ~= nil and #start:actionNames() > 0, start
      end,
      fn = receiveButton
    },
    ["stop"] = {
      message = "Stop",
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local stop = getc(winUIObj, "AXButton", "Stop")
        return stop ~= nil and #stop:actionNames() > 0, stop
      end,
      fn = receiveButton
    },
    ["configureServer"] = {
      message = "Configure Server...",
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local configure = getc(winUIObj, "AXCheckBox", 1, "AXButton", "Configure Server...")
        return configure ~= nil and #configure:actionNames() > 0, configure
      end,
      fn = receiveButton
    },
    ["browse"] = {
      message = "Browse",
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local browse = getc(winUIObj, "AXCheckBox", 1, "AXButton", "Browse...")
        return browse ~= nil and #browse:actionNames() > 0, browse
      end,
      fn = receiveButton
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
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
        local winUIObj = hs.axuielement.windowElement(win)
        local button = getc(winUIObj, "AXButton", "Allow")
        return button ~= nil, button
      end,
      fn = receiveButton
    },
    ["blockConnection"] = {
      message = "Block Connection",
      bindCondition = versionLessThan("2.9.1"),
      windowFilter = {
        allowTitles = "^LuLu Alert$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local button = getc(winUIObj, "AXButton", "Block")
        return button ~= nil, button
      end,
      fn = receiveButton
    }
  },

  ["com.runningwithcrayons.Alfred-Preferences"] =
  {
    ["saveInSheet"] = {
      message = "Save",
      windowFilter = {
        allowSheet = true
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local button = getc(winUIObj, "AXButton", "Save")
        return button ~= nil and button.AXEnabled == true, button
      end,
      fn = receiveButton
    }
  },

  ["com.surteesstudios.Bartender"] =
  {
    ["toggleMenuBar"] = {
      message = "Toggle Menu Bar",
      kind = HK.MENUBAR,
      fn = function(app)
        hs.osascript.applescript(string.format([[
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
      fn = function(app)
        hs.osascript.applescript(string.format([[
          tell application id "%s" to quick search
        ]], app:bundleID()))
      end
    },
    ["keyboardNavigate"] = {
      message = "Navigate Menu Bar",
      kind = HK.MENUBAR,
      bindCondition = function(app)
        -- the property update in command line is not working
        local _, ok = hs.execute(string.format(
            "defaults read '%s' hotkeyKeyboardNav", app:bundleID()))
        return ok
      end,
      fn = function(app)
        local output = hs.execute(string.format(
            "defaults read '%s' hotkeyKeyboardNav", app:bundleID()))
        local spec = hs.fnutils.split(output, "\n")
        local mods = string.match(spec[4], "modifierFlags = (%d+)")
        local key = string.match(spec[3], "keyCode = (%d+)")
        mods, key = parsePlistKeyBinding(mods, key)
        safeGlobalKeyStroke(mods, key)
      end
    },
    ["view1"] =
    {
      message = "General",
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(1)
    },
    ["view2"] =
    {
      message = "Menu Bar Items",
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(2)
    },
    ["view3"] =
    {
      message = "Menu Bar Style",
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(3)
    },
    ["view4"] =
    {
      message = "Presets",
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(4)
    },
    ["view5"] =
    {
      message = "Triggers",
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(5)
    },
    ["view6"] =
    {
      message = "Hotkeys",
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(6)
    },
    ["view7"] =
    {
      message = "Advanced",
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(7)
    },
    ["view8"] =
    {
      message = "License",
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(8)
    },
    ["view9"] =
    {
      message = "About",
      windowFilter = { allowTitles = "^Bartender 5$" },
      fn = clickBartenderSidebarItem(9)
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["quit"] = specialCommonHotkeyConfigs["quit"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
  },

  ["com.app.menubarx"] =
  {
    ["toggleMenuBarX"] = {
      message = "Toggle MenuBarX",
      kind = HK.MENUBAR,
      fn = function(app)
        local appid = app:bundleID()
        local output = hs.execute(string.format(
            "defaults read '%s' KeyboardShortcuts_toggleX | tr -d '\\n'", appid))
        if output == "0" then
          local spec = KeybindingConfigs.hotkeys[appid]["toggleMenuBarX"]
          local mods, key = dumpPlistKeyBinding(1, spec.mods, spec.key)
          hs.execute(string.format(
              [[defaults write '%s' KeyboardShortcuts_toggleX -string '{"carbonKeyCode":%d,"carbonModifiers":%d}']],
              appid, key, mods))
          app:kill()
          hs.timer.doAfter(1, function()
            hs.execute(string.format("open -g -b '%s'", appid))
            hs.timer.doAfter(1, function()
              safeGlobalKeyStroke(spec.mods, spec.key)
            end)
          end)
        else
          local json = hs.json.decode(output)
          local mods, key = parsePlistKeyBinding(json["carbonModifiers"], json["carbonKeyCode"])
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
      fn = clickRightMenuBarItem
    },
    ["preferencesInMenuBarMenu"] = {
      message = function(app)
        return app:name() .. ' > '
            .. localizedString('Preferences', app:bundleID())
      end,
      menubar = true,
      fn = function(app)
        local prefString = localizedString('Preferences', app:bundleID())
        local appUIObj = hs.axuielement.applicationElement(app)
        local button = getc(appUIObj, "AXMenuBar", -1,
            "AXMenuBarItem", 1, "AXMenu", 1, "AXMenuItem", 1, "AXGroup", 1,
            "AXStaticText", prefString)
        local position = {
          button.AXPosition.x + 5,
          button.AXPosition.y + 5
        }
        leftClickAndRestore(position, app:name(), 0.2)
      end
    }
  },

  ["whbalzac.Dongtaizhuomian"] =
  {
    ["invokeInAppScreenSaver"] = {
      message = localizedMessage("In-app Screensaver",
                                { localeFile = "HotkeyWindowController" }),
      fn = function(app)
        clickRightMenuBarItem(app,
            localizedString("In-app Screensaver", app:bundleID(),
                            { localeFile = "HotkeyWindowController" }))
      end
    }
  },

  ["pl.maketheweb.TopNotch"] =
  {
    ["toggleTopNotch"] = {
      message = "Toggle Top Notch",
      fn = function(app)
        clickRightMenuBarItem(app)
        local appUIObj = hs.axuielement.applicationElement(app)
        hs.timer.doAfter(1, function()
          local switch = getc(appUIObj, "AXMenuBar", -1, "AXMenuBarItem", 1,
              "AXPopover", 1, "AXGroup", 3, "AXButton", 1)
          if switch == nil then
            hs.timer.usleep(0.1 * 1000000)
            switch = getc(appUIObj, "AXMenuBar", -1, "AXMenuBarItem", 1,
                "AXPopover", 1, "AXGroup", 3, "AXButton", 2)
          end
          local state = switch.AXValue
          switch:performAction("AXPress")
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
      fn = focusOrHide
    }
  },

  ["com.mathpix.snipping-tool-noappstore"] =
  {
    ["OCRForLatex"] = {
      message = "OCR for LaTeX",
      fn = function(app)
        local appid = app:bundleID()
        local mods = hs.execute(string.format(
            "defaults read '%s' getLatexHotKeyModifiersKey | tr -d '\\n'", appid))
        local key = hs.execute(string.format(
            "defaults read '%s' getLatexHotKeyKey | tr -d '\\n'", appid))
        mods, key = parsePlistKeyBinding(mods, key)
        -- the property update in command line is overridden when app quits
        if mods == nil or key == nil then return end
        local enabled = hs.execute(string.format(
            "defaults read '%s' getLatexShortcutEnabledKey | tr -d '\\n'", appid))
        if enabled == "0" then
          hs.execute(string.format(
              "defaults write '%s' getLatexShortcutEnabledKey 1", appid))
          app:kill()
          hs.timer.doAfter(1, function()
            hs.execute(string.format("open -g -b '%s'", appid))
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
      end,
      deleteOnDisable = true,
      defaultResendToSystem = true
    }
  },

  ["com.apple.Passwords.MenuBarExtra"] =
  {
    ["showPasswordsDialog"] = {
      message = "Show Passwords",
      bindCondition = function()
        local enableMenuBarExtra = hs.execute(
            "defaults read com.apple.Passwords EnableMenuBarExtra | tr -d '\\n'")
        return enableMenuBarExtra == "1"
      end,
      fn = clickRightMenuBarItem
    },
    ["newPassword"] = {
      message = localizedString("New Password", "com.apple.Passwords"),
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local buttons = getc(winUIObj, "AXGroup", 1, "AXButton")
        local button = hs.fnutils.find(buttons, function(btn)
          return btn.AXIdentifier == 'plus'
        end)
        return button ~= nil, button
      end,
      background = true,
      fn = receiveButton
    },
    ["showAllPasswords"] = {
      message = "Show All Passwords",
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local buttons = getc(winUIObj, "AXGroup", 1, "AXButton")
        local button = hs.fnutils.find(buttons, function(btn)
          return btn.AXIdentifier == 'macwindow'
        end)
        return button ~= nil, button
      end,
      background = true,
      fn = receiveButton
    },
    ["back"] = {
      message = commonLocalizedMessage("Back"),
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local elem = getc(winUIObj, "AXGroup", 1, nil, 1)
        return elem.AXRole == "AXButton", elem
      end,
      background = true,
      fn = receiveButton
    },
    ["copyUsername"] = {
      message = localizedString("Username", "com.apple.Passwords"),
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local elem = getc(winUIObj, "AXGroup", 1, nil, 1)
        return elem.AXRole == "AXButton"
      end,
      background = true,
      fn = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local field = getc(winUIObj, "AXGroup", 1, "AXScrollArea", 1,
            "AXGroup", 1, "AXScrollArea", 1, "AXOutline", 1, "AXRow", 2, nil, 1,
            "AXStaticText", 2)
        assert(field)
        local position = {
          field.AXPosition.x + field.AXSize.w / 2,
          field.AXPosition.y + field.AXSize.h / 2
        }
        leftClickAndRestore(position, win:application():name())
        clickRightMenuBarItem(win:application())
      end
    },
    ["copyPassword"] = {
      message = localizedString("Password", "com.apple.Passwords"),
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local elem = getc(winUIObj, "AXGroup", 1, nil, 1)
        return elem.AXRole == "AXButton"
      end,
      background = true,
      fn = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local field = getc(winUIObj, "AXGroup", 1, "AXScrollArea", 1,
            "AXGroup", 1, "AXScrollArea", 1, "AXOutline", 1, "AXRow", 3, nil, 1,
            "AXStaticText", 2)
        assert(field)
        local position = {
          field.AXPosition.x + field.AXSize.w / 2,
          field.AXPosition.y + field.AXSize.h / 2
        }
        leftClickAndRestore(position, win:application():name())
        clickRightMenuBarItem(win:application())
      end
    },
    ["record1"] = {
      message = "Record 1",
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(1),
      background = true,
      fn = function(position, win)
        return receivePosition(position, win:application())
      end
    },
    ["record2"] = {
      message = "Record 2",
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(2),
      background = true,
      fn = function(position, win)
        return receivePosition(position, win:application())
      end
    },
    ["record3"] = {
      message = "Record 3",
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(3),
      background = true,
      fn = function(position, win)
        return receivePosition(position, win:application())
      end
    },
    ["record4"] = {
      message = "Record 4",
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(4),
      background = true,
      fn = function(position, win)
        return receivePosition(position, win:application())
      end
    },
    ["record5"] = {
      message = "Record 5",
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(5),
      background = true,
      fn = function(position, win)
        return receivePosition(position, win:application())
      end
    },
    ["record6"] = {
      message = "Record 6",
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(6),
      background = true,
      fn = function(position, win)
        return receivePosition(position, win:application())
      end
    },
    ["record7"] = {
      message = "Record 7",
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(7),
      background = true,
      fn = function(position, win)
        return receivePosition(position, win:application())
      end
    },
    ["record8"] = {
      message = "Record 8",
      windowFilter = {
        allowRoles = "AXSystemDialog",
        allowTitles = "^$"
      },
      condition = getPasswordRecordPosition(8),
      background = true,
      fn = function(position, win)
        return receivePosition(position, win:application())
      end
    }
  },

  ["com.macosgame.iwallpaper"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"]
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
      fn = showMenuItem
    },
  },

  ["com.apple.ScreenSharing"] =
  {
    ["openRecent"] = {
      message = localizedMessage("Open Recent"),
      condition = checkMenuItem({ "Connect", "Open Recent" }),
      fn = showMenuItem
    },
  },

  ["com.realvnc.vncviewer"] = {
    ["search"] = {
      message = "Search",
      windowFilter = {
        allowTitles = "^(Real)VNC Viewer$"
      },
      fn = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local searchField = getc(winUIObj, "AXTextField", 1)
        if searchField ~= nil then
          local position = {
            searchField.AXPosition.x + 5,
            searchField.AXPosition.y + 5,
          }
          leftClickAndRestore(position, win:application():name())
        end
      end
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
    ["minimize"] = {
      mods = "⌘", key = "M",
      message = localizedMessage("Minimize"),
      repeatable = true,
      fn = function(app)
        selectMenuItem(app, { "Window", "Minimize" })
      end
    },
    ["closeWindow"] = {
      mods = "⌘", key = "W",
      message = localizedMessage("Close Window"),
      condition = function(app)
        local menuItem, menuItemTitle = findMenuItem(app, { "File", "Close Window" })
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
      mods = "⌘", key = "W",
      message = localizedMessage("Close"),
      condition = function(app)
        local menuItem, menuItemTitle = findMenuItem(app, { "File", "Close" })
        if menuItem ~= nil and menuItem.enabled then
          return true, menuItemTitle
        else
          local win = app:focusedWindow()
          return win ~= nil and win:role() == "AXWindow", win
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
      fn = function(app)
        selectMenuItem(app, { "Actions", "Show In Finder" })
      end
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
      fn = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local button = getc(winUIObj, "AXButton", 2, "AXButton", 1)
        if button == nil then
          button = getc(winUIObj, "AXGroup", 2, "AXButton", 1, "AXButton", 1)
        end
        if button ~= nil then
          leftClickAndRestore(button.AXPosition, win:application():name())
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      fn = function(win)
        win:application():selectMenuItem({"File", "Open..."})
      end
    }
  },

  ["com.jetbrains.CLion-EAP"] =
  {
    ["newProject"] = {
      message = "New Project",
      fn = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local button = getc(winUIObj, "AXButton", 2, "AXButton", 1)
        if button == nil then
          button = getc(winUIObj, "AXGroup", 2, "AXButton", 1, "AXButton", 1)
        end
        if button ~= nil then
          leftClickAndRestore(button.AXPosition, win:application():name())
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      fn = function(win)
        win:application():selectMenuItem({"File", "Open..."})
      end
    }
  },

  ["com.jetbrains.intellij"] =
  {
    ["newProject"] = {
      message = "New Project",
      fn = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local button = getc(winUIObj, "AXButton", 2, "AXButton", 1)
        if button == nil then
          button = getc(winUIObj, "AXGroup", 2, "AXButton", 1, "AXButton", 1)
        end
        if button ~= nil then
          leftClickAndRestore(button.AXPosition, win:application():name())
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      fn = function(win)
        win:application():selectMenuItem({"File", "Open..."})
      end
    }
  },

  ["com.jetbrains.pycharm"] =
  {
    ["newProject"] = {
      message = "New Project",
      fn = function(win)
        local winUIObj = hs.axuielement.windowElement(win)
        local button = getc(winUIObj, "AXButton", 2, "AXButton", 1)
        if button == nil then
          button = getc(winUIObj, "AXGroup", 2, "AXButton", 1, "AXButton", 1)
        end
        if button ~= nil then
          leftClickAndRestore(button.AXPosition, win:application():name())
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      fn = function(win)
        win:application():selectMenuItem({"File", "Open..."})
      end
    }
  },

  ["org.qt-project.Designer"] =
  {
    ["openRecent"] = {
      message = localizedMessage("&Recent Forms"),
      condition = checkMenuItem({ "File", "&Recent Forms" }),
      fn = showMenuItem
    }
  },

  ["org.qt-project.Linguist"] =
  {
    ["openRecent"] = {
      message = localizedMessage("Recently Opened &Files"),
      condition = checkMenuItem({ "File", "Recently Opened &Files" }),
      fn = showMenuItem
    }
  },

  ["cn.better365.iShotProHelper"] =
  {
    ["OCR"] = {
      message = "OCR",
      bindCondition = function()
        -- the property update in command line is overridden when app quits
        local appid = "cn.better365.iShotProHelper"
        local _, ok = hs.execute(string.format(
            "defaults read '%s' dicOfShortCutKey | grep OCRRecorder", appid))
        return ok
      end,
      fn = function(app)
        local output = hs.execute(string.format(
            "defaults read '%s' dicOfShortCutKey | grep OCRRecorder -A4",
            app:bundleID()))
        local spec = hs.fnutils.split(output, "\n")
        local mods = string.match(spec[5], "modifierFlags = (%d+);")
        local key = string.match(spec[4], "keyCode = (%d+);")
        mods, key = parsePlistKeyBinding(mods, key)
        if mods == nil or key == nil then return end
        safeGlobalKeyStroke(mods, key)
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
        local winUIObj = hs.axuielement.windowElement(win)
        local button = getc(winUIObj, "AXButton", 1)
        if button ~= nil then button:performAction("AXPress") end
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
      fn = function(win) hs.eventtap.keyStroke("", "Up", nil, win:application()) end
    },
    ["nextItem"] = {
      mods = "", key = "Right",
      message = "Next Item",
      windowFilter = iCopyWindowFilter,
      repeatable = true,
      fn = function(win) hs.eventtap.keyStroke("", "Down", nil, win:application()) end
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
    message = "全部关注",
    condition = weiboNavigateToCommonGroupCondition(1),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate2ndCommonGroup"] = {
    message = "最新微博",
    condition = weiboNavigateToCommonGroupCondition(2),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate3rdCommonGroup"] = {
    message = "特别关注",
    condition = weiboNavigateToCommonGroupCondition(3),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate4thCommonGroup"] = {
    message = "好友圈",
    condition = weiboNavigateToCommonGroupCondition(4),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate1stCustomGroup"] = {
    message = "自定义分组1",
    condition = weiboNavigateToCustomGroupCondition(1),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate2ndCustomGroup"] = {
    message = "自定义分组2",
    condition = weiboNavigateToCustomGroupCondition(2),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate3rdCustomGroup"] = {
    message = "自定义分组3",
    condition = weiboNavigateToCustomGroupCondition(3),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate4thCustomGroup"] = {
    message = "自定义分组4",
    condition = weiboNavigateToCustomGroupCondition(4),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate5thCustomGroup"] = {
    message = "自定义分组5",
    condition = weiboNavigateToCustomGroupCondition(5),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate6thCustomGroup"] = {
    message = "自定义分组6",
    condition = weiboNavigateToCustomGroupCondition(6),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate7thCustomGroup"] = {
    message = "自定义分组7",
    condition = weiboNavigateToCustomGroupCondition(7),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate8thCustomGroup"] = {
    message = "自定义分组8",
    condition = weiboNavigateToCustomGroupCondition(8),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate9thCustomGroup"] = {
    message = "自定义分组9",
    condition = weiboNavigateToCustomGroupCondition(9),
    fn = weiboNavigateToSideBar
  },
  ["weiboNavigate10thCustomGroup"] = {
    message = "自定义分组10",
    condition = weiboNavigateToCustomGroupCondition(10),
    fn = weiboNavigateToSideBar
  },

  ["douyinNavigate1stTab"] = {
    message = "Tab 1",
    condition = douyinNavigateToTabCondition(1),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate2ndTab"] = {
    message = "Tab 2",
    condition = douyinNavigateToTabCondition(2),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate3rdTab"] = {
    message = "Tab 3",
    condition = douyinNavigateToTabCondition(3),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate4thTab"] = {
    message = "Tab 4",
    condition = douyinNavigateToTabCondition(4),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate5thTab"] = {
    message = "Tab 5",
    condition = douyinNavigateToTabCondition(5),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate6thTab"] = {
    message = "Tab 6",
    condition = douyinNavigateToTabCondition(6),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate7thTab"] = {
    message = "Tab 7",
    condition = douyinNavigateToTabCondition(7),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate8thTab"] = {
    message = "Tab 8",
    condition = douyinNavigateToTabCondition(8),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate9thTab"] = {
    message = "Tab 9",
    condition = douyinNavigateToTabCondition(9),
    fn = douyinNavigateToTab
  },
  ["douyinNavigate10thTab"] = {
    message = "Tab 10",
    condition = douyinNavigateToTabCondition(10),
    fn = douyinNavigateToTab
  }
}
local supportedBrowsers = {
  "com.apple.Safari", "com.google.Chrome",
  "com.microsoft.edgemac", "com.microsoft.edgemac.Dev"
}
for _, appid in ipairs(supportedBrowsers) do
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

local runningAppHotKeys = {}
local inAppHotKeys = {}
local inWinHotKeys = {}

-- hotkeys for background apps
local function registerRunningAppHotKeys(appid, app)
  if appHotKeyCallbacks[appid] == nil then return end
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  if app == nil then
    app = find(appid)
  end

  if runningAppHotKeys[appid] == nil then
    runningAppHotKeys[appid] = {}
  end

  -- do not support "condition" property currently
  for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
    if runningAppHotKeys[appid][hkID] ~= nil then
      runningAppHotKeys[appid][hkID]:enable()
      goto L_CONTINUE
    end
    -- prefer properties specified in configuration file than in code
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local isBackground = keybinding.background ~= nil and keybinding.background or cfg.background
    local isPersistent = keybinding.persist ~= nil and keybinding.persist or cfg.persist
    local appInstalled = hs.application.pathForBundleID(appid) ~= nil and hs.application.pathForBundleID(appid) ~= ""
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local bindable = function()
      return cfg.bindCondition == nil or ((app ~= nil and cfg.bindCondition(app))
        or (app == nil and isPersistent and cfg.bindCondition()))
    end
    if isBackground and not isForWindow
        and (app ~= nil or (isPersistent and appInstalled)) -- runninng / installed and persist
        and bindable() then                                       -- bindable
      local fn
      if isPersistent then
        fn = function()
          if find(appid) then
            cfg.fn(find(appid))
          else
            hs.execute(string.format("open -g -b '%s'", appid))
            hs.timer.doAfter(1, function()
              if find(appid) then
                local cb = cfg.onLaunch or cfg.fn
                cb(find(appid))
              end
            end)
          end
        end
      else
        fn = hs.fnutils.partial(cfg.fn, app)
      end
      local repeatable = keybinding.repeatable ~= nil and keybinding.repeatable or cfg.repeatable
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
        hotkey.deleteOnDisable = cfg.deleteOnDisable
        hotkey.appid = appid
        runningAppHotKeys[appid][hkID] = hotkey
      end
    end
    ::L_CONTINUE::
  end
end

local function unregisterRunningAppHotKeys(appid, force)
  if appHotKeyCallbacks[appid] == nil then return end

  if force then
    for _, hotkey in pairs(runningAppHotKeys[appid] or {}) do
      hotkey:delete()
    end
    runningAppHotKeys[appid] = nil
  else
    for _, hotkey in pairs(runningAppHotKeys[appid] or {}) do
      if hotkey.persist ~= true then
        hotkey:disable()
        if hotkey.deleteOnDisable then
          hotkey:delete()
          runningAppHotKeys[appid][hotkey] = nil
        end
      end
    end
  end
end

-- record windows created and alive since last app switch
-- we have to record them because key strokes must be sent to frontmost window instead of frontmost app
-- and some windows may be make frontmost silently
WindowCreatedSince = {}
WindowCreatedSinceWatcher = hs.window.filter.new(true):subscribe(
{hs.window.filter.windowCreated, hs.window.filter.windowFocused, hs.window.filter.windowDestroyed},
function(win, appname, eventType)
  if win == nil or win:application() == nil
      or win:application():bundleID() == hs.application.frontmostApplication():bundleID() then
    return
  end
  if eventType == hs.window.filter.windowCreated or eventType == hs.window.filter.windowFocused then
    WindowCreatedSince[win:id()] = win:application():bundleID()
  else
    for wid, appid in pairs(WindowCreatedSince) do
      if hs.window.get(wid) == nil or hs.window.get(wid):application():bundleID() ~= appid then
        WindowCreatedSince[wid] = nil
      end
    end
  end
end)

local function resendToFrontmostWindow(cond, nonFrontmost)
  return function(obj)
    if obj.application == nil and obj.focusedWindow == nil then return true end
    local app = obj.application ~= nil and obj:application() or obj
    local frontWin = hs.window.frontmostWindow()
    if frontWin ~= nil and app:focusedWindow() ~= nil
        and frontWin:application():bundleID() ~= app:bundleID() then
      return false, COND_FAIL.NOT_FRONTMOST_WINDOW
    elseif frontWin ~= nil and app:focusedWindow() == nil
        and WindowCreatedSince[frontWin:id()] then
      return false, COND_FAIL.NOT_FRONTMOST_WINDOW
    elseif nonFrontmost and frontWin ~= nil
        and WindowCreatedSince[frontWin:id()] then
      return false, COND_FAIL.NOT_FRONTMOST_WINDOW
    end
    if cond ~= nil then
      return cond(obj)
    else
      return true
    end
  end
end

local KEY_MODE = {
  PRESS = 1,
  REPEAT = 2,
}

InWebsiteHotkeyInfoChain = {}
InWinHotkeyInfoChain = {}
local function wrapInfoChain(app, config, cond, mode)
  local appid = app:bundleID()
  local mods, key = config.mods, config.key
  local message = config.message
  local windowFilter = config.windowFilter
  local websiteFilter = config.websiteFilter

  if windowFilter ~= nil then
    if InWinHotkeyInfoChain[appid] == nil then InWinHotkeyInfoChain[appid] = {} end
    if mode == KEY_MODE.PRESS then -- only info for pressing event is enough
      local hkIdx = hotkeyIdx(mods, key)
      local prevHotkeyInfo = InWinHotkeyInfoChain[appid][hkIdx]
      InWinHotkeyInfoChain[appid][hkIdx] = {
        condition = cond,
        message = message,
        previous = prevHotkeyInfo
      }
    end
  elseif websiteFilter ~= nil then
    if InWebsiteHotkeyInfoChain[appid] == nil then InWebsiteHotkeyInfoChain[appid] = {} end
    if mode == KEY_MODE.PRESS then
      local hkIdx = hotkeyIdx(mods, key)
      local prevWebsiteHotkeyInfo = InWebsiteHotkeyInfoChain[appid][hkIdx]
      InWebsiteHotkeyInfoChain[appid][hkIdx] = {
        condition = cond,
        message = message,
        previous = prevWebsiteHotkeyInfo
      }
    end
  end
end

local prevWebsiteCallbacks = {}
local prevWindowCallbacks = {}
local function wrapCondition(app, config, mode)
  local prevWebsiteCallback, prevWindowCallback
  local appid = app:bundleID()

  local mods, key = config.mods, config.key
  local func = mode == KEY_MODE.REPEAT and config.repeatedfn or config.fn
  local cond = config.condition
  local windowFilter = config.windowFilter
  local websiteFilter = config.websiteFilter
  -- some apps only accept system key strokes and neglect key strokes targeted at them
  local resendToSystem = config.defaultResendToSystem

  -- testify window filter and return TF & extra result
  if windowFilter ~= nil and windowFilter ~= 'background' then
    local hkIdx = hotkeyIdx(mods, key)
    prevWindowCallback = get(prevWindowCallbacks, appid, hkIdx, mode)
    local actualFilter  -- remove self-customed properties
    if type(windowFilter) == 'table' then
      for k, v in pairs(windowFilter) do
        if k ~= "allowSheet" and k ~= "allowPopover" then
          if actualFilter == nil then actualFilter = {} end
          actualFilter[k] = v
        end
      end
      if actualFilter == nil then actualFilter = false end
    else
      actualFilter = windowFilter
    end
    local oldCond = cond
    cond = function(win)
      if win == nil then return false end
      local wf = hs.window.filter.new(false):setAppFilter(
        win:application():name(), actualFilter)
      if wf:isWindowAllowed(win)
          or (type(windowFilter) == 'table' and windowFilter.allowSheet and win:role() == "AXSheet")
          or (type(windowFilter) == 'table' and windowFilter.allowPopover and win:role() == "AXPopover") then
        if oldCond ~= nil then
          local satisfied, result = oldCond(win)
          if not satisfied then
            result = COND_FAIL.WINDOW_FILTER_NOT_SATISFIED
          end
          return satisfied, result
        else
          return true
        end
      else
        return false, COND_FAIL.WINDOW_FILTER_NOT_SATISFIED
      end
    end
  end
  -- testify website filter and return TF, valid URL & extra result
  if websiteFilter ~= nil then
    local hkIdx = hotkeyIdx(mods, key)
    prevWebsiteCallback = get(prevWebsiteCallbacks, appid, hkIdx, mode)
    local oldCond = cond
    cond = function(obj)
      if app:focusedWindow() == nil
          or app:focusedWindow():subrole() ~= "AXStandardWindow" then
        return false
      end
      local url = getTabUrl(app)
      if url ~= nil then
        local allowURLs = websiteFilter.allowURLs
        if type(allowURLs) == 'string' then
          allowURLs = { allowURLs }
        end
        for _, v in ipairs(allowURLs) do
          if string.match(url, v) ~= nil then
            if oldCond ~= nil then
              local satisfied, result = oldCond(obj)
              if not satisfied then
                return false, result
              elseif result ~= nil then
                return true, result, url
              else
                return true, url
              end
            else
              return true, url
            end
          end
        end
        return false, COND_FAIL.WEBSITE_FILTER_NOT_SATISFIED
      end
    end
  end
  if config.menubar ~= true then
    -- if a menu is extended, hotkeys with no modifiers are disabled
    if mods == nil or mods == "" or #mods == 0 then
      cond = noSelectedMenuBarItemFunc(cond)
    end
  end
  -- send key strokes to frontmost window instead of frontmost app
  cond = resendToFrontmostWindow(cond, config.nonFrontmost or config.menubar)
  local fn = func
  fn = function(...)
    local obj = windowFilter == nil and app or app:focusedWindow()
    if obj == nil then  -- no window focused when triggering window-specific hotkeys
      selectMenuItemOrKeyStroke(app, mods, key, resendToSystem)
      return
    end
    local satisfied, result, url = cond(obj)
    if satisfied then
      if result ~= nil then  -- condition function can pass result to callback function
        if url ~= nil then
          func(result, url, obj, ...)
        else
          func(result, obj, ...)
        end
      else
        func(obj, ...)
      end
      return
    elseif result == COND_FAIL.NO_MENU_ITEM_BY_KEYBINDING
        or result == COND_FAIL.MENU_ITEM_SELECTED then
      if resendToSystem then
        safeGlobalKeyStroke(mods, key)
      else
        hs.eventtap.keyStroke(mods, key, nil, app)
      end
      return
    elseif result == COND_FAIL.WINDOW_FILTER_NOT_SATISFIED then
      if prevWindowCallback ~= nil then
        prevWindowCallback()
        return
      end
    elseif result == COND_FAIL.WEBSITE_FILTER_NOT_SATISFIED then
      if prevWebsiteCallback ~= nil then
        prevWebsiteCallback()
        return
      end
    elseif result == COND_FAIL.NOT_FRONTMOST_WINDOW then
      selectMenuItemOrKeyStroke(hs.window.frontmostWindow():application(), mods, key,
                                resendToSystem)
      return
    end
    -- most of the time, directly selecting menu item costs less time than key strokes
    selectMenuItemOrKeyStroke(app, mods, key, resendToSystem)
  end

  if windowFilter ~= nil and windowFilter ~= 'background' then
    -- multiple window-specified hotkeys may share a common keybinding
    -- they are cached in a linked list.
    -- each window filter will be tested until one matched target window
    if prevWindowCallbacks[appid] == nil then prevWindowCallbacks[appid] = {} end
    local hkIdx = hotkeyIdx(mods, key)
    if prevWindowCallbacks[appid][hkIdx] == nil then prevWindowCallbacks[appid][hkIdx] = { nil, nil } end
    prevWindowCallbacks[appid][hkIdx][mode] = fn
  end
  if websiteFilter ~= nil then
    -- multiple website-specified hotkeys may share a common keybinding
    -- they are cached in a linked list.
    -- each website filterParallels will be tested until one matched target tab
    if prevWebsiteCallbacks[appid] == nil then prevWebsiteCallbacks[appid] = {} end
    local hkIdx = hotkeyIdx(mods, key)
    if prevWebsiteCallbacks[appid][hkIdx] == nil then prevWebsiteCallbacks[appid][hkIdx] = { nil, nil } end
    prevWebsiteCallbacks[appid][hkIdx][mode] = fn
  end
  if (windowFilter ~= nil and windowFilter ~= 'background') or websiteFilter ~= nil then
    -- essential info are also cached in a linked list for showing keybindings by `HSKeybindings`
    wrapInfoChain(app, config, cond, mode)
  end
  return fn, cond
end

-- in current version of Hammerspoon, if a callback lasts kind of too long,
-- keeping pressing a hotkey may lead to unexpected repeated triggering of callback function
-- a workaround is to check if callback function is executing, if so, do nothing
-- note that this workaround may not work when the callback lasts really too long
local callBackExecuting = false
local function callBackExecutingWrapper(fn)
  return function()
    if callBackExecuting then return end
    hs.timer.doAfter(0, function()
      callBackExecuting = true
      fn()
      callBackExecuting = false
    end)
  end
end

local function bindAppWinImpl(app, config, ...)
  if config.spec ~= nil then
    config.mods = config.spec.mods
    config.key = config.spec.key
    config.spec = nil
  end
  local pressedfn, cond = wrapCondition(app, config, KEY_MODE.PRESS)
  if config.repeatedfn == nil
      and (config.condition ~= nil or config.windowFilter ~= nil or config.websiteFilter ~= nil) then
    -- if hotkey condition is not satisfied, holding event should be passed to the app
    -- so callback for holding event must always be registered
    config.repeatedfn = function() end
  end
  local repeatedfn = config.repeatedfn
  if repeatedfn ~= nil then
    repeatedfn = wrapCondition(app, config, KEY_MODE.REPEAT)
  end
  if config.condition ~= nil then  -- executing condition may take too much time
    pressedfn = callBackExecutingWrapper(pressedfn)
    if repeatedfn ~= nil then
      repeatedfn = callBackExecutingWrapper(repeatedfn)
    end
  end
  local hotkey = bindHotkeySpec(config, config.message, pressedfn, nil, repeatedfn, ...)
  hotkey.deleteOnDisable = config.deleteOnDisable
  return hotkey, cond
end

function AppBind(app, config, ...)
  local hotkey, cond = bindAppWinImpl(app, config, ...)
  hotkey.kind = HK.IN_APP
  if config.websiteFilter == nil then
    hotkey.condition = cond
    hotkey.subkind = HK.IN_APP_.APP
  else
    hotkey.subkind = HK.IN_APP_.WEBSITE
  end
  return hotkey
end

-- hotkeys for active app
local function registerInAppHotKeys(app)
  local appid = app:bundleID()
  if appHotKeyCallbacks[appid] == nil then return end
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}
  prevWebsiteCallbacks = {}

  if not inAppHotKeys[appid] then
    inAppHotKeys[appid] = {}
  end
  for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
    if type(hkID) == 'number' then break end
    if inAppHotKeys[appid][hkID] ~= nil then
      inAppHotKeys[appid][hkID]:enable()
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
      local isBackground = keybinding.background ~= nil and keybinding.background or cfg.background
      local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
      local isMenuBarMenu = keybinding.menubar ~= nil or cfg.menubar ~= nil
      local bindable = function()
        return cfg.bindCondition == nil or cfg.bindCondition(app)
      end
      if hasKey and not isBackground and not isForWindow and not isMenuBarMenu and bindable() then
        local msg = type(cfg.message) == 'string' and cfg.message or cfg.message(app)
        if msg ~= nil then
          local config = hs.fnutils.copy(cfg)
          config.mods = keybinding.mods
          config.key = keybinding.key
          config.message = msg
          config.websiteFilter = keybinding.websiteFilter or cfg.websiteFilter
          config.repeatable = keybinding.repeatable ~= nil and keybinding.repeatable or cfg.repeatable
          config.repeatedfn = config.repeatable and cfg.fn or nil
          inAppHotKeys[appid][hkID] = AppBind(app, config)
        end
      end
    end
  end
end

local function unregisterInAppHotKeys(appid, delete)
  if appHotKeyCallbacks[appid] == nil then return end

  if delete then
    for _, hotkey in pairs(inAppHotKeys[appid] or {}) do
      hotkey:delete()
    end
    inAppHotKeys[appid] = nil
  else
    local allDeleted = true
    for hkID, hotkey in pairs(inAppHotKeys[appid]) do
      hotkey:disable()
      if hotkey.deleteOnDisable then
        hotkey:delete()
        inAppHotKeys[appid][hkID] = nil
      else
        allDeleted = false
      end
    end
    if allDeleted then
      inAppHotKeys[appid] = nil
    end
  end
end

function AppWinBind(app, config, ...)
  local hotkey = bindAppWinImpl(app, config, ...)
  hotkey.kind = HK.IN_APP
  hotkey.subkind = HK.IN_APP_.WINDOW
  return hotkey
end

-- hotkeys for focused window of active app
local function registerInWinHotKeys(app)
  local appid = app:bundleID()
  if appHotKeyCallbacks[appid] == nil then return end
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}

  if not inWinHotKeys[appid] then
    inWinHotKeys[appid] = {}
  end
  for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
    if inWinHotKeys[appid][hkID] == nil then
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
      local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
      local isBackground = keybinding.background ~= nil and keybinding.background or cfg.background
      local bindable = function()
        return cfg.bindCondition == nil or cfg.bindCondition(app)
      end
      if hasKey and isForWindow and not isBackground and bindable() then  -- only consider windows of active app
        local msg = type(cfg.message) == 'string' and cfg.message or cfg.message(app)
        if msg ~= nil then
          local config = hs.fnutils.copy(cfg)
          config.mods = keybinding.mods
          config.key = keybinding.key
          config.message = msg
          config.windowFilter = keybinding.windowFilter or cfg.windowFilter
          config.repeatable = keybinding.repeatable ~= nil and keybinding.repeatable or cfg.repeatable
          config.repeatedfn = config.repeatable and cfg.fn or nil
          inWinHotKeys[appid][hkID] = AppWinBind(app, config)
        end
      end
    else
      inWinHotKeys[appid][hkID]:enable()
    end
  end
end

local function unregisterInWinHotKeys(appid, delete)
  if appHotKeyCallbacks[appid] == nil or inWinHotKeys[appid] == nil then return end

  local hasDeleteOnDisable = hs.fnutils.some(inWinHotKeys[appid], function(_, hotkey)
    return hotkey.deleteOnDisable
  end)
  if delete or hasDeleteOnDisable then
    for _, hotkey in pairs(inWinHotKeys[appid]) do
      hotkey:delete()
    end
    inWinHotKeys[appid] = nil
    prevWindowCallbacks[appid] = nil
    InWinHotkeyInfoChain[appid] = nil
  else
    for _, hotkey in pairs(inWinHotKeys[appid]) do
      hotkey:disable()
    end
  end
end

-- check if a window filter is the same as another
-- if a value is a list, the order of elements matters
local function sameFilter(a, b)
  if type(a) ~= "table" then return a == b end
  if a == b then return true end
  for k, av in pairs(a) do
    local bv = b[k]
    if type(av) == 'table' then
      if type(bv) ~= 'table' then return false end
      for i=1,#av do
        if av[i].equals then
          if not av[i]:equals(bv[i]) then return false end
        else
          if av[i] ~= bv[i] then return false end
        end
      end
    else
      if av.equals then
        if not av:equals(bv) then return false end
      else
        if av ~= bv then return false end
      end
    end
  end
  for k, _ in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

function WinBind(app, config, ...)
  config.windowFilter = 'background'
  local hotkey, cond = bindAppWinImpl(app, config, ...)
  hotkey.kind = HK.IN_WIN
  hotkey.condition = cond
  return hotkey
end

-- hotkeys for focused window belonging to daemon app
-- the window is frontmost unless specified "nonFrontmost"
local daemonAppFocusedWindowHotkeys = {}
DaemonAppFocusedWindowFilters = {}
local function registerDaemonAppInWinHotkeys(appid, filter, event)
  if daemonAppFocusedWindowHotkeys[appid] == nil then
    daemonAppFocusedWindowHotkeys[appid] = {}
  elseif event == hs.window.filter.windowFocused then
    return
  end
  for hkID, cfg in pairs(appHotKeyCallbacks[appid]) do
    local app = find(appid)
    local keybinding = get(KeybindingConfigs.hotkeys[appid], hkID) or cfg
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isBackground = keybinding.background ~= nil and keybinding.background or cfg.background
    local windowFilter = keybinding.windowFilter or cfg.windowFilter
    local isForWindow = windowFilter ~= nil
    local bindable = function()
      return cfg.bindCondition == nil or cfg.bindCondition(app)
    end
    if hasKey and isForWindow and isBackground and bindable() and sameFilter(windowFilter, filter) then
      local msg = type(cfg.message) == 'string' and cfg.message or cfg.message(app)
      if msg ~= nil then
        local config = hs.fnutils.copy(cfg)
        config.mods = keybinding.mods
        config.key = keybinding.key
        config.message = msg
        config.repeatable = keybinding.repeatable ~= nil and keybinding.repeatable or cfg.repeatable
        config.repeatedFn = config.repeatable and cfg.fn or nil
        config.nonFrontmost = keybinding.nonFrontmost ~= nil and keybinding.nonFrontmost or cfg.nonFrontmost
        local hotkey = WinBind(app, config)
        table.insert(daemonAppFocusedWindowHotkeys[appid], hotkey)
      end
    end
  end
end

local execOnQuit, stopOnQuit
local function registerSingleWinFilterForDaemonApp(app, filter)
  local appid = app:bundleID()
  if filter.allowSheet or filter.allowPopover or appid == "com.tencent.LemonMonitor" then
    local appUIObj = hs.axuielement.applicationElement(app)
    local observer = hs.axuielement.observer.new(app:pid())
    observer:addWatcher(
      appUIObj,
      hs.axuielement.observer.notifications.focusedWindowChanged
    )
    observer:callback(function(_, element, notification)
      registerDaemonAppInWinHotkeys(appid, filter)
      local closeObserver = hs.axuielement.observer.new(app:pid())
      closeObserver:addWatcher(
        element,
        hs.axuielement.observer.notifications.uIElementDestroyed
      )
      closeObserver:callback(function(obs)
        if daemonAppFocusedWindowHotkeys[appid] ~= nil then -- fix weird bug
          for i, hotkey in ipairs(daemonAppFocusedWindowHotkeys[appid]) do
            if hotkey.idx ~= nil then
              hotkey:delete()
              daemonAppFocusedWindowHotkeys[appid][i] = nil
            end
          end
          if #daemonAppFocusedWindowHotkeys[appid] == 0 then
            daemonAppFocusedWindowHotkeys[appid] = nil
          end
        end
        obs:stop()
        obs = nil
      end)
      closeObserver:start()
    end)
    observer:start()
    DaemonAppFocusedWindowFilters[appid][filter] = observer
    stopOnQuit(appid, observer, function()
      DaemonAppFocusedWindowFilters[appid][filter] = nil
    end)
    return
  end
  local windowFilter = hs.window.filter.new(false):setAppFilter(app:name(), filter)
      :subscribe({ hs.window.filter.windowCreated, hs.window.filter.windowFocused },
  function(win, appname, event)
    registerDaemonAppInWinHotkeys(appid, filter, event)
  end)
      :subscribe({  hs.window.filter.windowDestroyed, hs.window.filter.windowUnfocused },
  function(win, appname, event)
    if event == hs.window.filter.windowUnfocused
        and hs.window.frontmostWindow() ~= nil
        and hs.window.frontmostWindow():id() == win:id() then
      return
    end
    if daemonAppFocusedWindowHotkeys[appid] ~= nil then  -- fix weird bug
      for i, hotkey in ipairs(daemonAppFocusedWindowHotkeys[appid]) do
        if hotkey.idx ~= nil then
          hotkey:delete()
          daemonAppFocusedWindowHotkeys[appid][i] = nil
        end
      end
      daemonAppFocusedWindowHotkeys[appid] = nil
    end
  end)
  DaemonAppFocusedWindowFilters[appid][filter] = windowFilter
  execOnQuit(appid, function()
    if windowFilter ~= nil then
      windowFilter:unsubscribeAll()
      windowFilter = nil
    end
    DaemonAppFocusedWindowFilters[appid][filter] = nil
  end)
end

local function registerWinFiltersForDaemonApp(app, appConfig)
  local appid = app:bundleID()
  for hkID, cfg in pairs(appConfig) do
    local keybinding = get(KeybindingConfigs.hotkeys[appid], hkID) or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local isBackground = keybinding.background ~= nil and keybinding.background or cfg.background
    local bindable = function()
      return cfg.bindCondition == nil or cfg.bindCondition(app)
    end
    if hasKey and isForWindow and isBackground and bindable() then
      if DaemonAppFocusedWindowFilters[appid] == nil then
        DaemonAppFocusedWindowFilters[appid] = {}
      end
      local windowFilter = keybinding.windowFilter or cfg.windowFilter
      for f, _ in pairs(DaemonAppFocusedWindowFilters[appid]) do
        -- a window filter can be shared by multiple hotkeys
        if sameFilter(f, windowFilter) then
          goto L_CONTINUE
        end
      end
      registerSingleWinFilterForDaemonApp(app, windowFilter)
    end
    ::L_CONTINUE::
  end
end

-- hotkeys for menu belonging to menubar app
local menuBarMenuHotkeys = {}
local function registerInMenuHotkeys(appid, appConfig)
  if menuBarMenuHotkeys[appid] == nil then
    menuBarMenuHotkeys[appid] = {}
  end
  for hkID, cfg in pairs(appConfig) do
    local app = find(appid)
    local keybinding = get(KeybindingConfigs.hotkeys[appid], hkID) or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isMenuBarMenu = keybinding.menubar ~= nil and keybinding.menubar or cfg.menubar
    local bindable = function()
      return cfg.bindCondition == nil or cfg.bindCondition(app)
    end
    if hasKey and isMenuBarMenu and bindable() then
      local msg = type(cfg.message) == 'string' and cfg.message or cfg.message(app)
      if msg ~= nil then
        local config = hs.fnutils.copy(cfg)
        config.mods = keybinding.mods
        config.key = keybinding.key
        config.message = msg
        config.repeatable = keybinding.repeatable ~= nil and keybinding.repeatable or cfg.repeatable
        config.repeatedFn = config.repeatable and cfg.fn or nil
        config.menubar = true
        local hotkey, cond = bindAppWinImpl(app, config)
        hotkey.condition = cond
        hotkey.kind = HK.MENUBAR
        table.insert(menuBarMenuHotkeys[appid], hotkey)
      end
    end
  end
end

MenuBarMenuObservers = {}
local function registerObserversForMenuBarMenu(app, appConfig)
  local appid = app:bundleID()
  for hkID, cfg in pairs(appConfig) do
    local keybinding = get(KeybindingConfigs.hotkeys[appid], hkID) or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isMenuBarMenu = keybinding.menubar ~= nil and keybinding.menubar or cfg.menubar
    local bindable = function()
      return cfg.bindCondition == nil or cfg.bindCondition(app)
    end
    if hasKey and isMenuBarMenu and bindable() then
      local observer = MenuBarMenuObservers[appid]
      if observer == nil then
        local appUIObj = hs.axuielement.applicationElement(app)
        observer = hs.axuielement.observer.new(app:pid())
        observer:addWatcher(
          appUIObj,
          hs.axuielement.observer.notifications.menuOpened
        )
        observer:callback(function(_, element, notification)
          local mbItem = getc(appUIObj, "AXMenuBar", -1, "AXMenuBarItem", 1)
          if not mbItem.AXSelected then return end
          registerInMenuHotkeys(appid, appConfig)
          local closeObserver = hs.axuielement.observer.new(app:pid())
          closeObserver:addWatcher(
            element,
            hs.axuielement.observer.notifications.menuClosed
          )
          closeObserver:callback(function(obs)
            if menuBarMenuHotkeys[appid] ~= nil then
              for i, hotkey in ipairs(menuBarMenuHotkeys[appid]) do
                if hotkey.idx ~= nil then
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
          end)
          closeObserver:start()
        end)
      end
      observer:start()
      MenuBarMenuObservers[appid] = observer
      stopOnQuit(appid, observer, function()
        MenuBarMenuObservers[appid] = nil
      end)
      break
    end
  end
end

-- ## function utilities for process management on app switching

-- for apps whose launching can be detected by Hammerspoon
local processesOnLaunch = {}
local appsLaunchSilently = ApplicationConfigs["launchSilently"] or {}
local function execOnLaunch(appid, action, onlyFirstTime)
  if hs.fnutils.contains(appsLaunchSilently, appid) then
    ExecOnSilentLaunch(appid, action)
  end

  if processesOnLaunch[appid] == nil then
    processesOnLaunch[appid] = {}
  end

  if onlyFirstTime then
    local idx = #processesOnLaunch[appid] + 1
    local oldAction = action
    action = function(app)
      oldAction(app)
      table.remove(processesOnLaunch[appid], idx)
    end
  end

  table.insert(processesOnLaunch[appid], action)
end

local processesOnActivated = {}
local function execOnActivated(appid, action)
  if processesOnActivated[appid] == nil then
    processesOnActivated[appid] = {}
  end
  table.insert(processesOnActivated[appid], action)
end

local processesOnDeactivated = {}
local function execOnDeactivated(appid, action)
  if processesOnDeactivated[appid] == nil then
    processesOnDeactivated[appid] = {}
  end
  table.insert(processesOnDeactivated[appid], action)
end

local processesOnQuit = {}
function execOnQuit(appid, action)
  if hs.fnutils.contains(appsLaunchSilently, appid) then
    ExecOnSilentQuit(appid, action)
  end

  if processesOnQuit[appid] == nil then
    processesOnQuit[appid] = {}
  end
  table.insert(processesOnQuit[appid], action)
end

local observersStopOnDeactivated = {}
local function stopOnDeactivated(appid, observer, action)
  if observersStopOnDeactivated[appid] == nil then
    observersStopOnDeactivated[appid] = {}
  end
  table.insert(observersStopOnDeactivated[appid], { observer, action })
end

local observersStopOnQuit = {}
function stopOnQuit(appid, observer, action)
  if observersStopOnQuit[appid] == nil then
    observersStopOnQuit[appid] = {}
  end
  table.insert(observersStopOnQuit[appid], { observer, action })
end

local appLocales = {} -- if app locale changes, it may change its menu bar items, so need to rebind
local function updateAppLocale(appid)
  local appLocale = applicationLocale(appid)
  local oldAppLocale = appLocales[appid] or SYSTEM_LOCALE
  if oldAppLocale ~= appLocale then
    if getMatchedLocale(oldAppLocale, { appLocale }) ~= appLocale then
      resetLocalizationMap(appid)
      localizeCommonMenuItemTitles(appLocale, appid)
      unregisterRunningAppHotKeys(appid, true)
    end
  end
  appLocales[appid] = appLocale
end

local frontApp = hs.application.frontmostApplication()
if frontApp then
  local appid = frontApp:bundleID()
  appLocales[appid] = applicationLocale(appid)
end

for _, appid in ipairs(appsLaunchSilently) do
  ExecOnSilentLaunch(appid, hs.fnutils.partial(updateAppLocale, appid))
end

-- register hotkeys for background apps
for appid, appConfig in pairs(appHotKeyCallbacks) do
  registerRunningAppHotKeys(appid)
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}
  for hkID, cfg in pairs(appConfig) do
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isBackground = keybinding.background ~= nil and keybinding.background or cfg.background
    local isPersistent = keybinding.persist ~= nil and keybinding.persist or cfg.persist
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    if hasKey and not isForWindow and isBackground and not isPersistent then
      execOnLaunch(appid, hs.fnutils.partial(registerRunningAppHotKeys, appid))
      execOnQuit(appid, hs.fnutils.partial(unregisterRunningAppHotKeys, appid, false))
      break
    end
  end
end

-- register hotkeys for active app
if frontApp then
  registerInAppHotKeys(frontApp)
end

-- register hotkeys for focused window of active app
if frontApp then
  registerInWinHotKeys(frontApp)
end

-- register watchers for focused window belonging to daemon app
for appid, appConfig in pairs(appHotKeyCallbacks) do
  local app = find(appid)
  if app ~= nil then
    registerWinFiltersForDaemonApp(app, appConfig)
  end
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}
  for hkID, cfg in pairs(appConfig) do
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isForWindow = keybinding.windowFilter ~= nil or cfg.windowFilter ~= nil
    local isBackground = keybinding.background ~= nil and keybinding.background or cfg.background
    if hasKey and isForWindow and isBackground then
      execOnLaunch(appid, function(app)
        registerWinFiltersForDaemonApp(app, appConfig)
      end)
      break
    end
  end
end

-- register watchers for menu of menubar app
for appid, appConfig in pairs(appHotKeyCallbacks) do
  local app = find(appid)
  if app ~= nil then
    registerObserversForMenuBarMenu(app, appConfig)
  end
  local keybindings = KeybindingConfigs.hotkeys[appid] or {}
  for hkID, cfg in pairs(appConfig) do
    local keybinding = keybindings[hkID] or { mods = cfg.mods, key = cfg.key }
    local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
    local isMenuBarMenu = keybinding.menubar ~= nil and keybinding.menubar or cfg.menubar
    if hasKey and isMenuBarMenu then
      execOnLaunch(appid, function(app)
        registerObserversForMenuBarMenu(app, appConfig)
      end)
      break
    end
  end
end

-- register hotkeys for focused window belonging to daemon app
local frontWin = hs.window.frontmostWindow()
if frontWin ~= nil then
  local frontWinAppBid = frontWin:application():bundleID()
  if DaemonAppFocusedWindowFilters[frontWinAppBid] ~= nil then
    for filter, _ in pairs(DaemonAppFocusedWindowFilters[frontWinAppBid]) do
      local filterEnable = hs.window.filter.new(false):setAppFilter(frontWin:application():title(), filter)
      if filterEnable:isWindowAllowed(frontWin) then
        registerDaemonAppInWinHotkeys(frontWinAppBid, filter)
      end
    end
  end
end


-- ## hotkeys or configs shared by multiple apps
local frontAppMenuItems = frontApp and frontApp:getMenuItems() or nil

-- basically aims to remap ctrl+` to shift+ctrl+tab to make it more convenient for fingers
local remapPreviousTabHotkey
local function remapPreviousTab(app, menuItems)
  if remapPreviousTabHotkey then
    remapPreviousTabHotkey:delete()
    remapPreviousTabHotkey = nil
  end
  local appid = app:bundleID()
  local spec = get(KeybindingConfigs.hotkeys.shared, "remapPreviousTab")
  local specApp = get(appHotKeyCallbacks[appid], "remapPreviousTab")
  if specApp ~= nil or spec == nil or hs.fnutils.contains(spec.excluded or {}, appid) then
    return
  end
  local menuItemPath = findMenuItemByKeyBinding(app, '⇧⌃', '⇥', menuItems)
  if menuItemPath ~= nil then
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
  end
end

if frontApp then
  remapPreviousTab(frontApp, frontAppMenuItems)
end

-- register hotkey to open recent when it is available
local openRecentHotkey
local localizedOpenRecent
local function registerOpenRecent(app)
  if openRecentHotkey then
    openRecentHotkey:delete()
    openRecentHotkey = nil
  end
  local appid = app:bundleID()
  local spec = get(KeybindingConfigs.hotkeys.shared, "openRecent")
  local specApp = get(appHotKeyCallbacks[appid], "openRecent")
  if specApp ~= nil or spec == nil or hs.fnutils.contains(spec.excluded or {}, appid) then
    return
  end
  local localizedFile = 'File'
  if app:findMenuItem({ localizedFile }) == nil then
    localizedFile = localizedMenuBarItem("File", app:bundleID())
    if localizedFile == nil then return end
    if app:findMenuItem({ localizedFile }) == nil then return end
  end
  local appUIObj = hs.axuielement.applicationElement(app)
  local findMenu = getc(appUIObj, "AXMenuBar", 1, "AXMenuBarItem", localizedFile, "AXMenu", 1)
  if findMenu == nil then return end
  local extendableItems = hs.fnutils.ifilter(findMenu.AXChildren or {}, function(item)
    return #item.AXChildren > 0
  end)
  if #extendableItems == 0 then return end
  local menuItemPath = { 'File', 'Open Recent' }
  local menuItem = app:findMenuItem(menuItemPath)
  if menuItem == nil then
    if appid:sub(1, 10) == "com.apple." then
      if localizedOpenRecent == nil then
        local resourceDir = '/System/Library/Frameworks/AppKit.framework/Resources'
        local matchedLocale = getMatchedLocale(SYSTEM_LOCALE, resourceDir, 'lproj')
        localizedOpenRecent = localizeByLoctable('Open Recent', resourceDir, 'MenuCommands', matchedLocale, {})
      end
      menuItemPath = { localizedFile, localizedOpenRecent }
      menuItem = app:findMenuItem(menuItemPath)
      if menuItem == nil then
        local appLocale = applicationLocale(appid)
        if appLocale ~= SYSTEM_LOCALE and appLocale:sub(1, 2) ~= 'en' then
          local resourceDir = '/System/Library/Frameworks/AppKit.framework/Resources'
          local matchedLocale = getMatchedLocale(appLocale, resourceDir, 'lproj')
          local localized = localizeByLoctable('Open Recent', resourceDir, 'MenuCommands', matchedLocale, {})
          menuItemPath = { localizedFile, localized }
        end
      end
    else
      local localizedTitle = localizedMenuItem('Open Recent', appid)
      if localizedTitle == nil then return end
      menuItemPath = { localizedFile, localizedTitle }
      menuItem = app:findMenuItem(menuItemPath)
    end
  end
  if menuItem ~= nil then
    local fn = function() showMenuItem(menuItemPath, app) end
    local cond = function()
      local menuItemCond = app:findMenuItem(menuItemPath)
      return menuItemCond ~= nil and menuItemCond.enabled
    end
    openRecentHotkey = AppBind(app, {
      spec = spec, message = menuItemPath[2],
      fn = fn, condition = cond
    })
  end
end
if frontApp then
  registerOpenRecent(frontApp)
end

local zoomHotkeys = {}
local function registerZoomHotkeys(app)
  for _, hotkey in pairs(zoomHotkeys) do
    hotkey:delete()
  end
  zoomHotkeys = {}
  local appid = app:bundleID()
  local menuItemTitles = { 'Zoom', 'Zoom All' }
  for i, hkID in ipairs { 'zoom', 'zoomAll' } do
    local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
    local specApp = get(appHotKeyCallbacks[appid], hkID)
    if specApp ~= nil or spec == nil or hs.fnutils.contains(spec.excluded or {}, appid) then
      return
    end

    local title = menuItemTitles[i]
    local menuItemPath = { 'Window', title }
    local menuItem = app:findMenuItem(menuItemPath)
    if menuItem == nil then
      local localizedWindow = localizedMenuBarItem('Window', app:bundleID())
      local localizedTitle = localizedMenuItem(title, app:bundleID())
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
    end
  end
end
if frontApp then
  registerZoomHotkeys(frontApp)
end

-- bind hotkeys for open or save panel that are similar in `Finder`
-- & hotkey to confirm delete
local openSavePanelHotkeys = {}

-- special buttons for no saving in some apps
local specialConfirmFuncs = {
  ["com.kingsoft.wpsoffice.mac"] = function(winUIObj)
    if winUIObj.AXSubrole == "AXDialog" then
      local btnName = localizedMenuItem("Don't Save", "com.kingsoft.wpsoffice.mac")
      if btnName == nil then return end
      local buttons = getc(winUIObj, "AXButton")
      for _, button in ipairs(buttons) do
        if button.AXTitle == btnName then
          return button
        end
      end
    end
  end,

  ["JabRef"] = function(winUIObj)
    if winUIObj.AXTitle == "Save before closing" then
      local button = getc(winUIObj, "AXUnknown", 1, nil, 1, 'AXButton', 1)
      if button ~= nil and button.AXDescription == 'Discard changes' then
        return button
      end
    end
  end,

  ["re.rizin.cutter"] = function(winUIObj)
    if winUIObj.AXSubrole == "AXDialog" then
      local buttons = getc(winUIObj, "AXGroup", 1, "AXButton") or {}
      for _, button in ipairs(buttons) do
        if button.AXTitle == "Don't Save" then
          return button
        end
      end
    end
  end
}

local function registerForOpenSavePanel(app)
  if app:bundleID() == "com.apple.finder" then return end
  local appUIObj = hs.axuielement.applicationElement(app)
  if not appUIObj:isValid() then
    hs.timer.doAfter(0.1, function() registerForOpenSavePanel(app) end)
    return
  end

  local getUIObj = function(winUIObj)
    local windowIdent = winUIObj.AXIdentifier
    local dontSaveButton, sidebarCells = nil, {}
    if get(KeybindingConfigs.hotkeys, app:bundleID(), "confirmDelete") == nil then
      local specialConfirmFunc = specialConfirmFuncs[app:bundleID()]
      if specialConfirmFunc ~= nil then
        dontSaveButton = specialConfirmFunc(winUIObj)
      elseif windowIdent == "save-panel" then
        for _, button in ipairs(getc(winUIObj, "AXButton")) do
          if button.AXIdentifier == "DontSaveButton" then
            dontSaveButton = button
            break
          end
        end
      end
    end
    if windowIdent == "open-panel" or windowIdent == "save-panel" then
      local outlineUIObj = getc(winUIObj,
          "AXSplitGroup", 1, "AXScrollArea", 1, "AXOutline", 1)
      if outlineUIObj ~= nil then
        for _, rowUIObj in ipairs(getc(outlineUIObj, "AXRow")) do
          if rowUIObj.AXChildren == nil then hs.timer.usleep(0.3 * 1000000) end
          table.insert(sidebarCells, rowUIObj.AXChildren[1])
        end
      end
    end
    return dontSaveButton, sidebarCells
  end

  local windowFilter
  local actionFunc = function(winUIObj)
    local dontSaveButton, sidebarCells = getUIObj(winUIObj)
    local header
    local i = 1
    for _, cell in ipairs(sidebarCells) do
      if i > 10 then break end
      if getc(cell, "AXStaticText", 1).AXIdentifier ~= nil then
        header = getc(cell, "AXStaticText", 1).AXValue
      else
        local suffix
        if i == 1 then suffix = "st"
        elseif i == 2 then suffix = "nd"
        elseif i == 3 then suffix = "rd"
        else suffix = "th" end
        local hkID = "open" .. tostring(i) .. suffix .. "SidebarItemOnOpenSavePanel"
        local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
        if spec ~= nil then
          local folder = getc(cell, "AXStaticText", 1).AXValue
          local hotkey = AppWinBind(app, {
            spec = spec, message = header .. ' > ' .. folder,
            fn = function() cell:performAction("AXOpen") end,
          })
          table.insert(openSavePanelHotkeys, hotkey)
          i = i + 1
        end
      end
    end

    if windowFilter ~= nil then windowFilter:unsubscribeAll() end
    if #app:visibleWindows() == 1 then
      windowFilter = hs.window.filter.new(false):setAppFilter(app:name())
      windowFilter:subscribe(hs.window.filter.windowDestroyed, function(win, appname)
        for _, hotkey in ipairs(openSavePanelHotkeys) do
          hotkey:delete()
        end
        openSavePanelHotkeys = {}
        windowFilter:unsubscribeAll()
        windowFilter = nil
      end)
    end

    if dontSaveButton ~= nil then
      local spec = get(KeybindingConfigs.hotkeys.shared, "confirmDelete")
      if spec ~= nil then
        local hotkey = AppWinBind(app, {
          spec = spec,
          message = dontSaveButton.AXTitle or dontSaveButton.AXDescription,
          fn = function() dontSaveButton:performAction("AXPress") end,
        })
        table.insert(openSavePanelHotkeys, hotkey)
      end
    end
  end
  if app:focusedWindow() ~= nil then
    actionFunc(hs.axuielement.windowElement(app:focusedWindow()))
  end

  local observer = hs.axuielement.observer.new(app:pid())
  observer:addWatcher(
    hs.axuielement.applicationElement(app),
    hs.axuielement.observer.notifications.focusedWindowChanged
  )
  observer:callback(function(observer, element, notifications)
    for _, hotkey in ipairs(openSavePanelHotkeys) do
      hotkey:delete()
    end
    openSavePanelHotkeys = {}
    actionFunc(element)
  end)
  observer:start()
  stopOnDeactivated(app:bundleID(), observer, function()
    for _, hotkey in ipairs(openSavePanelHotkeys) do
      hotkey:delete()
    end
    openSavePanelHotkeys = {}
    if windowFilter ~= nil then
      windowFilter:unsubscribeAll()
      windowFilter = nil
    end
  end)
end
if frontApp then
  registerForOpenSavePanel(frontApp)
end

-- bind `alt+?` hotkeys to select left menu bar items
AltMenuBarItemHotkeys = {}

local function bindAltMenu(app, mods, key, message, fn)
  fn = showMenuItemWrapper(fn)
  local hotkey = AppBind(app, {
    mods = mods, key = key, message = message, fn = fn,
  })
  hotkey.subkind = HK.IN_APP_.MENU
  return hotkey
end

local function searchHotkeyByNth(itemTitles, alreadySetHotkeys, index)
  local notSetItems = {}
  for _, title in pairs(itemTitles) do
    if index == nil then
      index = string.find(title[2], " ")
      if index ~= nil then
        index = index + 1
      end
    end
    local hotkey
    if index ~= nil then
      hotkey = string.upper(string.sub(title[2], index, index))
    end

    if hotkey ~= nil and alreadySetHotkeys[hotkey] == nil then
        alreadySetHotkeys[hotkey] = title[1]
    else
      table.insert(notSetItems, title)
    end
  end
  return notSetItems, alreadySetHotkeys
end

local function altMenuBarItem(app, menuItems)
  -- delete previous hotkeys
  for _, hotkeyObject in ipairs(AltMenuBarItemHotkeys) do
    hotkeyObject:delete()
  end
  AltMenuBarItemHotkeys = {}

  if app:bundleID() == nil then return end
  -- check whether called by window filter (possibly with delay)
  if app:bundleID() ~= hs.application.frontmostApplication():bundleID() then
    return
  end

  local enableIndex = get(KeybindingConfigs.hotkeys, "menubar", "index", "enable")
  local enableLetter = get(KeybindingConfigs.hotkeys, "menubar", "letter", "enable")
  if enableIndex == nil then enableIndex = false end
  if enableLetter == nil then enableLetter = true end
  local excludedForLetter = get(KeybindingConfigs.hotkeys, "menubar", "letter", "exclude")
  if excludedForLetter ~= nil and hs.fnutils.contains(excludedForLetter,
                                                      app:bundleID()) then
    enableLetter = false
  end
  if enableIndex == false and enableLetter == false then return end

  local menuBarItemTitles
  local useWindowMenuBar
  if app:focusedWindow() ~= nil then
    local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
    if #getc(winUIObj, "AXMenuBar") > 0 then
      local menuObj = getc(winUIObj, "AXMenuBar", 1, "AXMenu")
      if #menuObj == 0 then
        menuObj = getc(winUIObj, "AXMenuBar", 1, "AXMenuBar")
      end
      if #menuObj > 0 then
        useWindowMenuBar = true
        menuBarItemTitles = hs.fnutils.map(menuObj, function(item)
          return item.AXTitle:gsub("[%c%s]+$", ""):gsub("^[%c%s]+", "")
        end)
        table.insert(menuBarItemTitles, 1, app:name())
      end
    end
  end
  local menuBarItemActualIndices = {}
  if menuBarItemTitles == nil then
    if menuItems == nil then
      menuItems = app:getMenuItems()
    end
    if menuItems == nil then return end
    local itemDict = {}
    menuBarItemTitles = {}
    for i, item in ipairs(menuItems) do
      if itemDict[item.AXTitle] then
        if item.AXTitle == app:name() then
          -- ordinary menu bar item share the same title with app menu
          -- e.t.c. "Barrier" menu in `Barrier`
          menuBarItemActualIndices[item.AXTitle] = i + 1
        elseif itemDict[item.AXTitle].AXChildren == nil then
          -- two ordinary menu bar items share the same title, but the former is invalid
          -- e.t.c. two "File" menus in `QQLive`
          local idx = hs.fnutils.indexOf(menuBarItemTitles, item.AXTitle)
          table.remove(menuBarItemTitles, idx)
          menuBarItemActualIndices[item.AXTitle] = i + 1
        elseif item.AXChildren == nil then
          -- two ordinary menu bar items share the same title, but the latter is invalid
          goto CHECK_MENU_ITEM_CONTINUE
        end
        -- assume at most two menu bar items share the same title
      end
      itemDict[item.AXTitle] = item
      table.insert(menuBarItemTitles, item.AXTitle)
      ::CHECK_MENU_ITEM_CONTINUE::
    end
    menuBarItemTitles = hs.fnutils.filter(menuBarItemTitles, function(item)
      return item ~= nil and item ~= ""
    end)
  end
  if menuBarItemTitles == nil or #menuBarItemTitles == 0 then return end

  local clickMenuCallback
  if useWindowMenuBar then
    clickMenuCallback = function(title)
      local winUIObj = hs.axuielement.windowElement(app:focusedWindow())
      local menuObj = getc(winUIObj, "AXMenuBar", 1, "AXMenu")
      if #menuObj == 0 then
        menuObj = getc(winUIObj, "AXMenuBar", 1, "AXMenuBar")
      end
      local targetMenuObj = hs.fnutils.find(menuObj, function(item)
        return item.AXTitle:gsub("[%c%s]+$", ""):gsub("^[%c%s]+", "") == title
      end)
      local actionNames = targetMenuObj:actionNames()
      if actionNames ~= nil and hs.fnutils.contains(actionNames, "AXPick") then
        targetMenuObj:performAction("AXPick")
      elseif actionNames ~= nil and hs.fnutils.contains(actionNames, "AXPress") then
        targetMenuObj:performAction("AXPress")
      else
        local position = { targetMenuObj.AXPosition.x + 5, targetMenuObj.AXPosition.y + 5 }
        leftClick(position, app:name())
      end
    end
  else
    clickMenuCallback = function(title)
      local index = menuBarItemActualIndices[title]
      if index then
        local appUIObj = hs.axuielement.applicationElement(app)
        local menubarItem = getc(appUIObj, "AXMenuBar", 1, "AXMenuBarItem", index)
        if menubarItem then
          menubarItem:performAction("AXPress")
        end
      else
        app:selectMenuItem({ title })
      end
    end
  end

  -- by initial or otherwise second letter in title
  local alreadySetHotkeys = {}
  if enableLetter == true then
    local itemTitles = {}
    for i=2,#menuBarItemTitles do
      local title, letter = menuBarItemTitles[i]:match("(.-)%s*%((.-)%)")
      if letter then
        alreadySetHotkeys[letter] = {menuBarItemTitles[i], title}
      else
        letter = menuBarItemTitles[i]:match("[^%s]-&(%a)")
        if letter ~= nil then
          title = menuBarItemTitles[i]:gsub('[^%s]-&(%a)', '%1')
          alreadySetHotkeys[letter] = { menuBarItemTitles[i], title }
        else
          table.insert(itemTitles, menuBarItemTitles[i])
        end
      end
    end

    -- process localized titles
    itemTitles = delocalizeMenuBarItems(itemTitles, app:bundleID())

    local notSetItems = {}
    for _, title in ipairs(itemTitles) do
      if hs.fnutils.contains({ 'File', 'Edit', 'View', 'Window', 'Help' }, title[2]) then
        local hotkey = string.sub(title[2], 1, 1)
        alreadySetHotkeys[hotkey] = title[1]
      else
        table.insert(notSetItems, title)
      end
    end
    notSetItems, alreadySetHotkeys = searchHotkeyByNth(notSetItems, alreadySetHotkeys, 1)
    -- if there are still items not set, set them by first letter of second word
    notSetItems, alreadySetHotkeys = searchHotkeyByNth(notSetItems, alreadySetHotkeys, nil)
    -- if there are still items not set, set them by second letter
    notSetItems, alreadySetHotkeys = searchHotkeyByNth(notSetItems, alreadySetHotkeys, 2)
    -- if there are still items not set, set them by third letter
    notSetItems, alreadySetHotkeys = searchHotkeyByNth(notSetItems, alreadySetHotkeys, 3)
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
        local fn = hs.fnutils.partial(clickMenuCallback, menuBarItemTitles[i])
        local hotkeyObject = bindAltMenu(app, "⌥", spec[1], spec[2], fn)
        table.insert(AltMenuBarItemHotkeys, hotkeyObject)
      end
    end
  end

  -- by index
  if enableIndex == true then
    local maxMenuBarItemHotkey = #menuBarItemTitles > 11 and 10 or (#menuBarItemTitles - 1)
    local hotkeyObject = bindAltMenu(app, "⌥", "`", menuBarItemTitles[1],
      function() app:selectMenuItem({ menuBarItemTitles[1] }) end)
    hotkeyObject.subkind = 0
    table.insert(AltMenuBarItemHotkeys, hotkeyObject)

    local itemTitles = {}
    for i=2,#menuBarItemTitles do
      local title, letter = menuBarItemTitles[i]:match("(.-)%s*%((.-)%)")
      if letter then
        table.insert(itemTitles, title)
      else
        letter = menuBarItemTitles[i]:match("[^%s]-&(%a)")
        if letter ~= nil then
          title = menuBarItemTitles[i]:gsub('[^%s]-&(%a)', '%1')
          table.insert(itemTitles, title)
        else
          table.insert(itemTitles, menuBarItemTitles[i])
        end
      end
    end
    for i=1,maxMenuBarItemHotkey do
      local fn = hs.fnutils.partial(clickMenuCallback, menuBarItemTitles[i + 1])
      hotkeyObject = bindAltMenu(app, "⌥", tostring(i % 10), itemTitles[i], fn)
      table.insert(AltMenuBarItemHotkeys, hotkeyObject)
    end
  end
end
if frontApp then
  altMenuBarItem(frontApp, frontAppMenuItems)
end

-- some apps may change their menu bar items irregularly
local appswatchMenuBarItems = get(ApplicationConfigs, "menuBarItems", 'changing') or {}
local appsMenuBarItemTitlesString = {}

local getMenuBarItemTitlesString = function(app, menuItems)
  if menuItems == nil then
    menuItems = app:getMenuItems()
  end
  if menuItems == nil or #menuItems == 0 then return "" end
  local menuBarItemTitles = {}
  for _, item in ipairs(menuItems) do
    table.insert(menuBarItemTitles, item.AXTitle)
  end
  return table.concat(menuBarItemTitles, "|")
end

local function watchMenuBarItems(app, menuItems)
  local appid = app:bundleID()
  appsMenuBarItemTitlesString[appid] = getMenuBarItemTitlesString(app, menuItems)
  local watcher = ExecContinuously(function()
    local app = find(appid)
    if app == nil then return end
    local menuItems = app:getMenuItems()
    local menuBarItemTitlesString = getMenuBarItemTitlesString(app, menuItems)
    if menuBarItemTitlesString ~= appsMenuBarItemTitlesString[appid] then
      appsMenuBarItemTitlesString[appid] = menuBarItemTitlesString
      altMenuBarItem(app, menuItems)
      remapPreviousTab(app, menuItems)
      registerOpenRecent(app)
      registerZoomHotkeys(app)
    end
  end)
  execOnDeactivated(appid, function()
    StopExecContinuously(watcher)
    appsMenuBarItemTitlesString[appid] = nil
  end)
end

-- some apps may change their menu bar items based on the focused window
local appsMayChangeMenuBar = get(ApplicationConfigs, "menuBarItems", 'changeOnWindow') or {}

local function appMenuBarChangeCallback(app)
  local menuItems = app:getMenuItems()
  local menuBarItemStr = getMenuBarItemTitlesString(app, menuItems)
  if menuBarItemStr == appsMenuBarItemTitlesString[app:bundleID()] then
    return
  end
  appsMenuBarItemTitlesString[app:bundleID()] = menuBarItemStr
  altMenuBarItem(app, menuItems)
  remapPreviousTab(app, menuItems)
  registerOpenRecent(app)
  registerZoomHotkeys(app)
  hs.timer.doAfter(1, function()
    if hs.application.frontmostApplication():bundleID() ~= app:bundleID() then
      return
    end
    local menuItems = app:getMenuItems()
    local newMenuBarItemTitlesString = getMenuBarItemTitlesString(app, menuItems)
    if newMenuBarItemTitlesString ~= menuBarItemStr then
      appsMenuBarItemTitlesString[app:bundleID()] = newMenuBarItemTitlesString
      altMenuBarItem(app, menuItems)
      remapPreviousTab(app, menuItems)
      registerOpenRecent(app)
      registerZoomHotkeys(app)
    end
  end)
end

local function registerObserverForMenuBarChange(app, menuItems)
  if app:bundleID() == nil then return end

  if hs.fnutils.contains(appswatchMenuBarItems, app:bundleID()) then
    watchMenuBarItems(app, menuItems)
  end

  if not hs.fnutils.contains(appsMayChangeMenuBar, app:bundleID()) then
    return
  end

  appsMenuBarItemTitlesString[app:bundleID()] =
      getMenuBarItemTitlesString(app, menuItems)

  local observer, windowFilter
  observer = hs.axuielement.observer.new(app:pid())
  observer:addWatcher(
    hs.axuielement.applicationElement(app),
    hs.axuielement.observer.notifications.focusedWindowChanged
  )
  observer:addWatcher(
    hs.axuielement.applicationElement(app),
    hs.axuielement.observer.notifications.windowMiniaturized
  )
  observer:callback(hs.fnutils.partial(appMenuBarChangeCallback, app))
  observer:start()

  windowFilter = hs.window.filter.new(app:name())
      :subscribe(hs.window.filter.windowDestroyed,
        function(win)
          if win == nil or win:application() == nil then return end
          appMenuBarChangeCallback(win:application())
        end)
  stopOnDeactivated(app:bundleID(), observer,
    function()
      if windowFilter ~= nil then
        windowFilter:unsubscribeAll()
        windowFilter = nil
      end
    end)
end
if frontApp then
  registerObserverForMenuBarChange(frontApp, frontAppMenuItems)
end

-- auto hide or quit apps with no windows (including pseudo windows suck as popover or sheet)
local appsAutoHideWithNoWindows = {}
local appsAutoQuitWithNoWindows = {}

local specialNoWindowsRules = {
  ["com.apple.finder"] = function(app)
    if #hs.window.visibleWindows() == 1
        and hs.window.visibleWindows()[1]:id() == hs.window.desktop():id() then
      return false
    end
    local windows = app:visibleWindows()
    return #hs.fnutils.ifilter(windows, function(win)
        return win:id() ~= hs.window.desktop():id() end) == 0
  end
}
local function processAppWithNoWindows(app, quit, delay)
  local fn = function()
    local defaultRule = function()
      local windowFilterRules = quit and appsAutoQuitWithNoWindows or appsAutoHideWithNoWindows
      local windowFilter = hs.window.filter.new(false):setAppFilter(
        app:bundleID(), windowFilterRules[app:bundleID()])
      return hs.fnutils.find(app:visibleWindows(), function(win)
        return windowFilter:isWindowAllowed(win)
      end) == nil
    end
    local specialRule = specialNoWindowsRules[app:bundleID()]
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
  if delay == nil then
    fn()
  else
    hs.timer.doAfter(delay, fn)
  end
end

local specialNoPseudoWindowsRules = {
  ["com.app.menubarx"] = function(app, defaultRule)
    if versionGreaterEqual("1.6.9")(app) then return false end
    return defaultRule()
  end
}
PseudoWindowDestroyObservers = {}
local function registerPseudoWindowDestroyObserver(app, roles, quit, delay)
  local observer = PseudoWindowDestroyObservers[app:bundleID()]
  local appUIObj = hs.axuielement.applicationElement(app)
  if observer ~= nil then observer:start() return end
  observer = hs.axuielement.observer.new(app:pid())
  observer:addWatcher(
    appUIObj,
    hs.axuielement.observer.notifications.focusedUIElementChanged
  )
  local windowFilterRules = quit and appsAutoQuitWithNoWindows or appsAutoHideWithNoWindows
  local windowFilter = hs.window.filter.new(false):setAppFilter(
      app:name(), windowFilterRules[app:bundleID()])
  local criterion = function(element) return hs.fnutils.contains(roles, element.AXRole) end
  local params = { count = 1, depth = 2 }
  local pseudoWindowObserver
  local observerCallback = function()
    appUIObj:elementSearch(function(msg, results, count)
      if count > 0 then
        if pseudoWindowObserver ~= nil then
          pseudoWindowObserver:stop()
          pseudoWindowObserver = nil
        end
        local role = results[1].AXRole
        pseudoWindowObserver = hs.axuielement.observer.new(app:pid())
        pseudoWindowObserver:addWatcher(
          results[1],
          hs.axuielement.observer.notifications.uIElementDestroyed
        )
        local pseudoWindowObserverCallback = function(obs)
          appUIObj:elementSearch(function(newMsg, newResults, newCount)
              if newCount == 0 then
                local defaultRule = function()
                  local noWindow = hs.fnutils.find(app:visibleWindows(), function(win)
                    return windowFilter:isWindowAllowed(win)
                  end) == nil
                  local noMenuFromPopover = true
                  if role == "AXPopover" then
                    local menuBarMenu = getc(appUIObj, "AXMenuBar", -1, "AXMenuBarItem", 1)
                    noMenuFromPopover = menuBarMenu.AXSelected == false
                  end
                  return noWindow and noMenuFromPopover
                end
                local specialRule = specialNoPseudoWindowsRules[app:bundleID()]
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
                  obs:stop()
                  obs = nil
                end
              end
            end,
            criterion, params)
        end
        if delay then
          pseudoWindowObserverCallback = function()
            hs.timer.doAfter(delay, pseudoWindowObserverCallback)
          end
        end
        pseudoWindowObserver:callback(pseudoWindowObserverCallback)
        pseudoWindowObserver:start()
        stopOnDeactivated(app:bundleID(), pseudoWindowObserver)
      end
    end,
    criterion, params)
  end
  observer:callback(observerCallback)
  observer:start()
  PseudoWindowDestroyObservers[app:bundleID()] = observer
  stopOnQuit(app:bundleID(), observer,
      function(appid) PseudoWindowDestroyObservers[appid] = nil end)
end

local appsAutoHideWithNoWindowsLoaded = ApplicationConfigs["autoHideWithNoWindow"] or {}
local appsAutoQuitWithNoWindowsLoaded = ApplicationConfigs["autoQuitWithNoWindow"] or {}
-- account for pseudo windows such as popover or sheet
local appsAutoHideWithNoPseudoWindows = {}
local appsAutoQuitWithNoPseudoWindows = {}
-- some apps may first close a window before create a targeted one, so delay is needed before checking
local appsWithNoWindowsDelay = {}
for _, item in ipairs(appsAutoHideWithNoWindowsLoaded) do
  if type(item) == 'string' then
    appsAutoHideWithNoWindows[item] = true
  else
    for appid, cfg in pairs(item) do
      local windowFilter
      for k, v in pairs(cfg) do
        if (k == "allowPopover" or k == "allowSheet") and v then
          appsAutoHideWithNoPseudoWindows[appid] = {}
          if k == "allowPopover" then
            table.insert(appsAutoHideWithNoPseudoWindows[appid], "AXPopover")
          end
          if k == "allowSheet" then
            table.insert(appsAutoHideWithNoPseudoWindows[appid], "AXSheet")
          end
        elseif k == "delay" then
          appsWithNoWindowsDelay[appid] = v
        else
          if windowFilter == nil then windowFilter = {} end
          windowFilter[k] = v
        end
      end
      appsAutoHideWithNoWindows[appid] = windowFilter or true
    end
  end
end
for _, item in ipairs(appsAutoQuitWithNoWindowsLoaded) do
  if type(item) == 'string' then
    appsAutoQuitWithNoWindows[item] = true
  else
    for appid, cfg in pairs(item) do
      local windowFilter
      for k, v in pairs(cfg) do
        if (k == "allowPopover" or k == "allowSheet") and v then
          appsAutoQuitWithNoPseudoWindows[appid] = {}
          if k == "allowPopover" then
            table.insert(appsAutoQuitWithNoPseudoWindows[appid], "AXPopover")
          end
          if k == "allowSheet" then
            table.insert(appsAutoQuitWithNoPseudoWindows[appid], "AXSheet")
          end
        elseif k == "delay" then
          appsWithNoWindowsDelay[appid] = v
        else
          if windowFilter == nil then windowFilter = {} end
          windowFilter[k] = v
        end
      end
      appsAutoQuitWithNoWindows[appid] = windowFilter or true
    end
  end
end

AutoHideWindowFilter = hs.window.filter.new(false)
    :setAppFilter("Hammerspoon", true)  -- Hammerspoon overlook itself by default, so add it here
for appid, cfg in pairs(appsAutoHideWithNoWindows) do
  local func = function(app)
    AutoHideWindowFilter:setAppFilter(app:name(), cfg)
  end
  local app = find(appid)
  if app ~= nil then
    func(app)
  else
    execOnLaunch(appid, func, true)
  end
end
AutoHideWindowFilter:subscribe(hs.window.filter.windowDestroyed,
  function(win)
    if win == nil or win:application() == nil then return end
    local appid = win:application():bundleID()
    processAppWithNoWindows(win:application(), false, appsWithNoWindowsDelay[appid])
  end)

AutoQuitWindowFilter = hs.window.filter.new(false)
for appid, cfg in pairs(appsAutoQuitWithNoWindows) do
  local func = function(app)
    AutoQuitWindowFilter:setAppFilter(app:name(), cfg)
  end
  local app = find(appid)
  if app ~= nil then
    func(app)
  else
    execOnLaunch(appid, func, true)
  end
end
AutoQuitWindowFilter:subscribe(hs.window.filter.windowDestroyed,
  function(win)
    if win == nil or win:application() == nil then return end
    local appid = win:application():bundleID()
    processAppWithNoWindows(win:application(), true, appsWithNoWindowsDelay[appid])
  end)

-- Hammerspoon only account standard windows, so add watchers for pseudo windows here
for appid, roles in pairs(appsAutoHideWithNoPseudoWindows) do
  local func = function(app)
    registerPseudoWindowDestroyObserver(app, roles, false, appsWithNoWindowsDelay[appid])
  end
  local app = find(appid)
  if app ~= nil then
    func(app)
  else
    execOnLaunch(appid, func, true)
  end
end
for appid, roles in pairs(appsAutoQuitWithNoPseudoWindows) do
  local func = function(app)
    registerPseudoWindowDestroyObserver(app, roles, true, appsWithNoWindowsDelay[appid])
  end
  local app = find(appid)
  if app ~= nil then
    func(app)
  else
    execOnLaunch(appid, func, true)
  end
end


-- ## configure specific apps

-- ### Mountain Duck
-- connect to servers on launch
local function connectMountainDuckEntries(app, connection)
  local appUIObj = hs.axuielement.applicationElement(app)
  local menuBar = getc(appUIObj, "AXMenuBar", -1, "AXMenu", 1)

  if type(connection) == 'string' then
    local menuItem = getc(menuBar, "AXMenuItem", connection, "AXMenu", 1, "AXMenuItem", 1)
    if menuItem ~= nil then
      menuItem:performAction("AXPress")
    end
  else
    local fullfilled = connection.condition(app)
    if fullfilled == nil then return end
    local connects = connection[connection.locations[fullfilled and 1 or 2]]
    local disconnects = connection[connection.locations[fullfilled and 2 or 1]]
    for _, item in ipairs(connects) do
      local menuItem = getc(menuBar, "AXMenuItem", item, "AXMenu", 1, "AXMenuItem", 1)
      if menuItem ~= nil then
        menuItem:performAction("AXPress")
      end
    end
    local disconnect = localizedString('Disconnect', app:bundleID())
    for _, item in ipairs(disconnects) do
      local menuItem = getc(menuBar, "AXMenuItem", item, "AXMenu", 1, "AXMenuItem", disconnect)
      if menuItem ~= nil then
        menuItem:performAction("AXPress")
      end
    end
  end
end
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
  execOnLaunch("io.mountainduck", function(app)
    for _, connection in ipairs(mountainDuckConfig.connections) do
      connectMountainDuckEntries(app, connection)
    end
  end)
  local mountainDuckObject = find("io.mountainduck")
  if mountainDuckObject ~= nil then
    for _, connection in ipairs(mountainDuckConfig.connections) do
      connectMountainDuckEntries(mountainDuckObject, connection)
    end
  end
end

-- ## Barrier
-- barrier window may not be focused when it is created, so focus it
BarrierFocusWindowFilter = nil
if hs.application.pathForBundleID("barrier") ~= nil
    and hs.application.pathForBundleID("barrier") ~= "" then
  local app = find("barrier")
  if app == nil then
    execOnLaunch("barrier", function(app)
      BarrierFocusWindowFilter = hs.window.filter.new(false):allowApp(app:name()):subscribe(
        hs.window.filter.windowCreated, function(win) win:focus() end
      )
    end)
  else
    BarrierFocusWindowFilter = hs.window.filter.new(false):allowApp(app:name()):subscribe(
      hs.window.filter.windowCreated, function(win) win:focus() end
    )
  end
end

-- ## remote desktop apps
-- remap modifier keys for specified windows of remote desktop apps
local remoteDesktopsMappingModifiers = get(KeybindingConfigs, 'remoteDesktopModifiers') or {}
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

MicrosoftRemoteDesktopWindowFilter = nil
if hs.application.nameForBundleID("com.microsoft.rdc.macos") == "Windows App" then
  MicrosoftRemoteDesktopWindowFilter = { rejectTitles = {} }
  local preLocalizeWindowsApp = function ()
    for _, title in ipairs { "Favorites", "Devices", "Apps",
      "Settings", "About", "Device View Options", "App View Options" } do
      local locTitle = "^" .. localizedString(title, "com.microsoft.rdc.macos") .. "$"
      if not hs.fnutils.contains(MicrosoftRemoteDesktopWindowFilter.rejectTitles, locTitle) then
        table.insert(MicrosoftRemoteDesktopWindowFilter.rejectTitles, locTitle)
      end
    end
  end
  if find("com.microsoft.rdc.macos") ~= nil then
    preLocalizeWindowsApp()
  end
  execOnActivated("com.microsoft.rdc.macos", preLocalizeWindowsApp)
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
    local winUIObj = hs.axuielement.windowElement(window)
    return hs.fnutils.find(getc(winUIObj, "AXButton"),
      function(child) return child.AXHelp == "Session information" end) ~= nil
  elseif appid == "com.microsoft.rdc.macos" then
    local wFilter = hs.window.filter.new(false):setAppFilter(
        window:application():name(), MicrosoftRemoteDesktopWindowFilter)
    local result = wFilter:isWindowAllowed(window)
    if result then
      local winUIObj = hs.axuielement.windowElement(window)
      local title = "Cancel"
      if window:application():name() == "Windows App" then
        title = localizedString(title, "com.microsoft.rdc.macos") or title
      end
      for _, bt in ipairs(getc(winUIObj, "AXButton")) do
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
    if win == nil or win:role() == "AXSheet" or win:role() == "AXPopover" then
      valid = r.type == 'restore'
    elseif r.condition == nil then
      local isRDW = isDefaultRemoteDesktopWindow(win)
      valid = (r.type == 'restore' and not isRDW) or (r.type ~= 'restore' and isRDW)
    else
      if r.condition.windowFilter ~= nil then  -- currently only support window filter
        local wFilter = hs.window.filter.new(false):setAppFilter(app:name(), r.condition.windowFilter)
        valid = wFilter:isWindowAllowed(win)
      end
    end
    if valid then
      return r
    end
  end
  return nil
end
local justModifiedRemoteDesktopModifiers = false
RemoteDesktopModifierTapper = hs.eventtap.new({
  hs.eventtap.event.types.flagsChanged, hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp},
function(ev)
  local rule = remoteDesktopWindowFilter(hs.application.frontmostApplication())
  if rule ~= nil then
    if not justModifiedRemoteDesktopModifiers then
      justModifiedRemoteDesktopModifiers = true
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
      justModifiedRemoteDesktopModifiers = false
    end
  end
  return false
end)

if frontApp and remoteDesktopsMappingModifiers[frontApp:bundleID()] then
  RemoteDesktopModifierTapper:start()
end
for appid, _ in pairs(remoteDesktopsMappingModifiers) do
  execOnActivated(appid, function()
    if not RemoteDesktopModifierTapper:isEnabled() then
      RemoteDesktopModifierTapper:start()
    end
  end)
end

local function suspendHotkeysInRemoteDesktop(app)
  local win = app:focusedWindow()
  if win ~= nil then
    if isDefaultRemoteDesktopWindow(win) then
      FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] = not FLAGS["SUSPEND"]
      FLAGS["SUSPEND"] = true
      return
    end
  end
  if FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] ~= nil then
    FLAGS["SUSPEND"] = not FLAGS["SUSPEND_IN_REMOTE_DESKTOP"]
    FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] = nil
  end
end

local remoteDesktopAppsRequireSuspendHotkeys = ApplicationConfigs["suspendHotkeysInRemoteDesktop"] or {}
for _, appid in ipairs(remoteDesktopAppsRequireSuspendHotkeys) do
  if frontApp and frontApp:bundleID() == appid then
    suspendHotkeysInRemoteDesktop(frontApp)
  end
  execOnActivated(appid, suspendHotkeysInRemoteDesktop)
end

RemoteDesktopObserver = nil
local function watchForRemoteDesktopWindow(app)
  local appUIObj = hs.axuielement.applicationElement(app)
  local observer = hs.axuielement.observer.new(app:pid())
  observer:addWatcher(
    appUIObj,
    hs.axuielement.observer.notifications.focusedWindowChanged
  )
  observer:callback(
      hs.fnutils.partial(suspendHotkeysInRemoteDesktop, app))
  observer:start()
  stopOnDeactivated(app:bundleID(), observer)
  stopOnQuit(app:bundleID(), observer)
  RemoteDesktopObserver = observer
end

for _, appid in ipairs(remoteDesktopAppsRequireSuspendHotkeys) do
  if frontApp and frontApp:bundleID() == appid then
    watchForRemoteDesktopWindow(frontApp)
  end
  execOnActivated(appid, watchForRemoteDesktopWindow)
end

-- ## iOS apps
-- disable cmd+w to close window for iOS apps because it will quit them
local iOSAppHotkey
local function deactivateCloseWindowForIOSApps(app)
  if app:bundleID() == nil then return end
  if hs.fs.attributes(hs.application.pathForBundleID(
      app:bundleID()) .. '/WrappedBundle') ~= nil then
    if iOSAppHotkey == nil then
      iOSAppHotkey = newHotkey("⌘", "w", "Cancel ⌘W", function() end)
      iOSAppHotkey.kind = HK.IN_APP
      iOSAppHotkey.subkind = HK.IN_APP_.APP
    end
    iOSAppHotkey:enable()
  elseif iOSAppHotkey ~= nil then
    iOSAppHotkey:disable()
  end
end
if frontApp then
  deactivateCloseWindowForIOSApps(frontApp)
end


-- # callbacks

-- ## application callbacks

-- specify input source for apps
local appsInputSourceMap = ApplicationConfigs["inputSource"] or {}
local function selectInputSourceInApp(app)
  local inputSource = appsInputSourceMap[app:bundleID()]
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
  ["com.microsoft.VSCode"] = function(app)
    return app:getMenuItems() ~= nil and #app:getMenuItems() > 1
  end,
  ["com.jetbrains.CLion"] = function(app)
    return app:getMenuItems() ~= nil and #app:getMenuItems() > 10
  end,
  ["com.jetbrains.CLion-EAP"] = function(app)
    return app:getMenuItems() ~= nil and #app:getMenuItems() > 10
  end,
  ["com.jetbrains.intellij"] = function(app)
    return app:getMenuItems() ~= nil and #app:getMenuItems() > 10
  end,
  ["com.jetbrains.pycharm"] = function(app)
    return app:getMenuItems() ~= nil and #app:getMenuItems() > 10
  end
}
local fullyLaunchCriterion, menuItemsPrepared

local function onLaunchedAndActivated(app)
  fullyLaunchCriterion = nil
  local menuItems = app:getMenuItems()
  altMenuBarItem(app, menuItems)
  registerInAppHotKeys(app)
  registerInWinHotKeys(app)
  remapPreviousTab(app, menuItems)
  registerOpenRecent(app)
  registerZoomHotkeys(app)
  registerObserverForMenuBarChange(app, menuItems)

  if HSKeybindings ~= nil and HSKeybindings.isShowing then
    local validOnly = HSKeybindings.validOnly
    local showHS = HSKeybindings.showHS
    local showApp = HSKeybindings.showApp
    HSKeybindings:reset()
    HSKeybindings:update(validOnly, showHS, showApp, true)
  end
  FLAGS["NO_RESHOW_KEYBINDING"] = false
  return menuItems ~= nil
end

function App_applicationCallback(appname, eventType, app)
  local appid = app:bundleID()
  if eventType == hs.application.watcher.launching then
    fullyLaunchCriterion = appsLaunchSlow[app:bundleID()]
  elseif eventType == hs.application.watcher.launched then
    local criterion = fullyLaunchCriterion
    if criterion ~= nil then
      if not criterion(app) then
        hs.timer.waitUntil(function() return criterion(app) end,
                           function() onLaunchedAndActivated(app) end,
                           0.01)
      else
        onLaunchedAndActivated(app)
      end
    elseif menuItemsPrepared == false then
      onLaunchedAndActivated(app)
    end
    menuItemsPrepared = nil
    for _, proc in ipairs(processesOnLaunch[appid] or {}) do
      proc(app)
    end
  elseif eventType == hs.application.watcher.activated then
    updateAppLocale(appid)
    WindowCreatedSince = {}
    if appid == nil then return end
    if RemoteDesktopObserver ~= nil then
      if FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] ~= nil then
        FLAGS["SUSPEND"] = not FLAGS["SUSPEND_IN_REMOTE_DESKTOP"]
        FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] = nil
      end
    end
    for _, proc in ipairs(processesOnActivated[appid] or {}) do
      proc(app)
    end
    deactivateCloseWindowForIOSApps(app)
    selectInputSourceInApp(app)
    FLAGS["NO_RESHOW_KEYBINDING"] = true
    hs.timer.doAfter(3, function()
      FLAGS["NO_RESHOW_KEYBINDING"] = false
    end)

    -- necesary for "registerForOpenSavePanel" for unknown reason
    hs.timer.doAfter(0, function()
      registerForOpenSavePanel(app)
      if fullyLaunchCriterion == nil then
        menuItemsPrepared = onLaunchedAndActivated(app)
      end
    end)
  elseif eventType == hs.application.watcher.deactivated and appname ~= nil then
    if appid then
      unregisterInAppHotKeys(appid)
      unregisterInWinHotKeys(appid)
      for _, proc in ipairs(processesOnDeactivated[appid] or {}) do
        proc(app)
      end
      for _, ob in ipairs(observersStopOnDeactivated[appid] or {}) do
        local observer, func = ob[1], ob[2]
        observer:stop()
        if func ~= nil then func(appid, observer) end
      end
      observersStopOnDeactivated[appid] = nil
    end
  elseif eventType == hs.application.watcher.deactivated
      or eventType == hs.application.watcher.terminated then
    for id, processes in pairs(processesOnDeactivated) do
      if find(id) == nil then
        for _, proc in ipairs(processes) do
          proc()
        end
      end
    end
    for id, processes in pairs(processesOnQuit) do
      if find(id) == nil then
        for _, proc in ipairs(processes) do
          proc()
        end
      end
    end
    for id, obs in pairs(observersStopOnDeactivated) do
      if find(id) == nil then
        for _, ob in ipairs(obs) do
          local observer, func = ob[1], ob[2]
          observer:stop()
          if func ~= nil then func(id, observer) end
        end
        observersStopOnDeactivated[id] = nil
      end
    end
    for id, obs in pairs(observersStopOnQuit) do
      if find(id) == nil then
        for _, ob in ipairs(obs) do
          local observer, func = ob[1], ob[2]
          observer:stop()
          if func ~= nil then func(id, observer) end
        end
        observersStopOnQuit[id] = nil
      end
    end
    for id, _ in pairs(inAppHotKeys) do
      if find(id) == nil then
        unregisterInAppHotKeys(id, true)
      end
    end
    for id, _ in pairs(inWinHotKeys) do
      if find(id) == nil then
        unregisterInWinHotKeys(id, true)
      end
    end
  end
  if eventType == hs.application.watcher.deactivated then
    if remoteDesktopsMappingModifiers[hs.application.frontmostApplication():bundleID()] == nil then
      if RemoteDesktopModifierTapper:isEnabled() then
        RemoteDesktopModifierTapper:stop()
      end
    end
  end
end

function App_applicationInstalledCallback(files, flagTables)
  for i, file in ipairs(files) do
    if flagTables[i].itemRemoved then
      local appid = hs.application.infoForBundlePath(file).CFBundleIdentifier
      for j, appkey in ipairs(appHotkeys) do
        if appkey.appid == appid or appkey.appPath == file then
          appkey:delete()
          table.remove(appHotkeys, j)
          break
        end
      end
    elseif flagTables[i].itemCreated then
      registerAppHotkeys()
      return
    end
  end
end

-- ## monitor callbacks

-- launch applications automatically when connected to an external monitor
local builtinMonitor = "Built-in Retina Display"

function App_monitorChangedCallback()
  local screens = hs.screen.allScreens()

  -- only for built-in monitor
  local builtinMonitorEnable = hs.fnutils.some(screens, function(screen)
    return screen:name() == builtinMonitor
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
