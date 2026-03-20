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

local function enableOrDelete(appid, hkID, clear, usePattern)
  local hotkey = HotkeyRegistry.get(appid, hkID, usePattern)
  if usePattern then
    local enabled = false
    for matchedID, matchedHotkey in pairs(hotkey) do
      if clear then
        HotkeyRegistry.clearHotkey(appid, matchedID)
      else
        HotkeyRegistry.enableHotkey(matchedHotkey)
        enabled = true
      end
    end
    return enabled
  end
  if hotkey then
    if clear then
      HotkeyRegistry.clearHotkey(appid, hkID)
    else
      HotkeyRegistry.enableHotkey(hotkey)
      return true
    end
  end
  return false
end

-- Remap "previous tab" behavior for apps that support tab switching.
--
-- This globally remaps:
--   Ctrl + `  →  Shift + Ctrl + Tab
--
-- The hotkey is:
--   - skipped if app explicitly defines its own handler
--   - skipped for excluded apps
--   - dynamically rebuilt when menu items change
---@diagnostic disable-next-line: lowercase-global
function remapPreviousTab(app, force)
  local appid = app:bundleID() or app:name()
  local hkID = "remapPreviousTab"
  local enabled = enableOrDelete(appid, hkID, force)
  if enabled then return end

  local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
  local specApp = get(AppHotKeyCallbacks[appid], hkID)
  if specApp ~= nil or spec == nil or tcontain(spec.excluded or {}, appid) then
    return
  end

  -- Register a conditional hotkey that selects the resolved menu item
  -- only when the menu item exists and is enabled.
  RunCoroutine(function()
    local menuItemPath = findMenuItemByKeyBinding(app, '⇧⌃', '⇥')
    if menuItemPath == nil then return end
    local fn = function()
      app:selectMenuItem(menuItemPath)
    end
    local cond = function()
      local menuItemCond = app:findMenuItem(menuItemPath)
      return menuItemCond ~= nil and menuItemCond.enabled
    end
    local hotkey = AppBind(app, {
      spec = spec, message = menuItemPath[#menuItemPath],
      fn = fn, repeatedfn = fn, condition = cond
    })
    HotkeyRegistry.register(appid, hkID, hotkey)
  end)
end

-- Register a shared hotkey for "Open Recent" menu item.
--
-- The hotkey:
--   - is only registered if the menu exists and is enabled
--   - respects localization and app-specific menu naming
--   - is skipped if app defines its own implementation
---@diagnostic disable-next-line: lowercase-global
function registerOpenRecent(app, force)
  local appid = app:bundleID() or app:name()
  local hkID = "openRecent"
  local enabled = enableOrDelete(appid, hkID, force)
  if enabled then return end

  local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
  local specApp = get(AppHotKeyCallbacks[appid], hkID)
  if specApp ~= nil or spec == nil or tcontain(spec.excluded or {}, appid) then
    return
  end

  -- Resolve localized "File > Open Recent" menu path across:
  --   - Apple apps
  --   - third-party apps
  --   - mixed localization environments
  local localizedFile
  localizedFile = 'File'
  if app:findMenuItem{ localizedFile } == nil then
    localizedFile = localizedMenuBarItem("File", appid, { locale = A_AppLocale })
    if localizedFile == nil then return end
    if app:findMenuItem{ localizedFile } == nil then return end
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
        if A_AppLocale ~= SYSTEM_LOCALE and A_AppLocale:sub(1, 2) ~= 'en' then
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
    local hotkey = AppBind(app, {
      spec = spec, message = menuItemPath[2],
      fn = fn, condition = cond
    })
    HotkeyRegistry.register(appid, hkID, hotkey)
  end
end

-- Register shared window zoom hotkeys (Zoom / Zoom All).
--
-- These hotkeys are bound only when:
--   - the corresponding menu items exist
--   - the app does not override them
--   - the app is not excluded
---@diagnostic disable-next-line: lowercase-global
function registerZoomHotkeys(app, force)
  local appid = app:bundleID() or app:name()
  local allHKIDs = { 'zoom', 'zoomAll' }
  local allMenuItemTitles = { 'Zoom', 'Zoom All' }
  local hkIDs, menuItemTitles = {}, {}
  for i, hkID in ipairs(allHKIDs) do
    local enabled = enableOrDelete(appid, hkID, force)
    if not enabled then
      tinsert(menuItemTitles, allMenuItemTitles[i])
      tinsert(hkIDs, hkID)
    end
  end

  for i, hkID in ipairs(hkIDs) do
    local spec = get(KeybindingConfigs.hotkeys.shared, hkID)
    local specApp = get(AppHotKeyCallbacks[appid], hkID)
    if specApp ~= nil or spec == nil or tcontain(spec.excluded or {}, appid) then
      goto ZOOM_CONTINUE
    end

    local title = menuItemTitles[i]
    local menuItemPath = { 'Window', title }
    local menuItem = app:findMenuItem(menuItemPath)
    if menuItem == nil then
      local localizedWindow = localizedMenuBarItem('Window', appid,
                                                   { locale = A_AppLocale })
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
      local hotkey = AppBind(app, {
        spec = spec, message = menuItemPath[2],
        fn = fn, condition = cond
      })
      HotkeyRegistry.register(appid, hkID, hotkey)
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
---@diagnostic disable-next-line: lowercase-global
function registerResizeHotkeys(app)
  if OS_VERSION < OS.Sequoia then return end
  local menu, submenu = "Window", "Move & Resize"
  local menuItem = app:findMenuItem{ menu, submenu }
  if menuItem == nil then
    local localizedMenu = localizedMenuBarItem('Window', app:bundleID(),
                                               { locale = A_AppLocale })
    local localizedSubmenu = TC(submenu, app)
    if localizedSubmenu == submenu and SYSTEM_LOCALE:sub(1, 2) ~= 'en' then
      localizedSubmenu = TC(submenu, app, { locale = SYSTEM_LOCALE })
    end
    if localizedSubmenu ~= nil then
      menuItem = app:findMenuItem{ localizedMenu, localizedSubmenu }
    end
    if menuItem == nil then
      if localizedSubmenu ~= nil then
        menuItem = app:findMenuItem{ menu, localizedSubmenu }
      end
      if menuItem == nil then
        menuItem = app:findMenuItem{ localizedMenu, submenu }
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
end

local function getSettingsWindow(app)
  local win = app:focusedWindow()
  if win == nil then
    local apath = app:path()
    if apath == nil then
      apath = hs.execute(strfmt([[
          lsof -a -d txt -p %s 2>/dev/null
          | sed -n '2p' | awk '{print $NF}']], app:pid()))
      if apath == nil then apath = "" end
    end
    local parts = hs.fnutils.split(apath, "/")
    local apps = { app }
    -- Walk backwards to find all the enclosing `.app` bundle
    for i = #parts-1, 1, -1 do
      if parts[i]:sub(-4) == ".app" then
        local subPath = {}
        for j = 1, i do
            table.insert(subPath, parts[j])
        end
        local appPath = table.concat(subPath, "/")
        local info = hs.application.infoForBundlePath(appPath)
        if info and info.CFBundleIdentifier then
          local id = info.CFBundleIdentifier
          local a = find(id)
          if a then
            win = a:focusedWindow()
            if win then break end
            tinsert(apps, a)
          end
        end
      end
    end
    if win == nil then
      local totalDelay = 0
      repeat
        hs.timer.usleep(10000)
        totalDelay = totalDelay + 0.01
        for _, a in ipairs(apps) do
          win = a:focusedWindow()
          if win then break end
        end
      until totalDelay > 0.1
    end
  end
  if win == nil then
    local frontWin = hs.window.frontmostWindow()
    if frontWin then
      local frontAppId = frontWin:application():bundleID()
      local frontAppIdParts = strsplit(frontAppId or "", "%.")
      local appIdParts = strsplit(app:bundleID() or "", "%.")
      if frontAppIdParts[1] == appIdParts[1]
          and frontAppIdParts[2] == appIdParts[2] then
        win = frontWin
      end
    end
  end
  return win
end

-- Fetch toolbar buttons from a window UI hierarchy.
local function getToolbarButtons(winUI)
  local toolbar = getc(winUI, AX.Toolbar, 1)
  return getc(toolbar, AX.Button)
end

-- Fetch outline rows for apps that use sidebar to navigate
local function getSidebarRows(winUI)
  local splitgroup = getc(winUI, AX.SplitGroup, 1)
      or getc(winUI, AX.Group, 1, AX.SplitGroup, 1)
  local scrollarea = getc(splitgroup, AX.Group, 1, AX.ScrollArea, 1)
      or getc(splitgroup, AX.ScrollArea, 1)
  return getc(scrollarea, AX.Outline, 1, AX.Row)
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
    fn = fn or function(_winUI)
      local buttons, toClick = getSidebarRows(_winUI)
      if buttons == nil or #buttons == 0 then
        buttons, toClick = getToolbarButtons(_winUI)
      end
      return buttons, toClick
    end
    local buttons, toClick = fn(winUI)
    if buttons == nil or #buttons == 0 then
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
      until (buttons and #buttons > 0) or totalDelay > maxWaitTime
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
  ["com.Snipaste"] = function(winUI)
    return getc(winUI, AX.Group, 2, AX.RadioButton)
  end,
  ["com.lwouis.alt-tab-macos"] = function(winUI)
    if appVer(winUI) < "10" then
      return getToolbarButtons(winUI)
    end
    return getc(winUI, AX.SplitGroup, 1, AX.ScrollArea, 1,
        AX.Table, 1, AX.Row)
  end,
  ["app.remixdesign.LaunchOS"] = function(winUI)
    return getc(winUI, AX.Group, 1, AX.Image), true
  end,
  ["cn.better365.BetterAndBetter"] = function(winUI)
    return getc(winUI, AX.Group, 1, AX.Button)
  end,
  ["cn.better365.iShotPro"] = function(winUI)
    local buttons = getc(winUI, AX.Button)
    if buttons then
      table.sort(buttons, function(a, b)
        return a.AXPosition.y < b.AXPosition.y
      end)
      return buttons
    end
  end,
  ["com.torusknot.SourceTreeNotMAS"] = function(winUI)
    local fn = getToolbarButtons
    local buttons = fn(winUI)
    if buttons == nil or #buttons == 0 or tfind(buttons, function(bt)
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
      until (buttons and #buttons > 0 and tfind(buttons, function(bt)
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
    if appVer(winUI) < "4" then
      return getToolbarButtons(winUI)
    elseif appVer(winUI) >= "4.0.6" then
      return
    end
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
    if groups then
      return tmap(groups, function(g)
        return getc(g, AX.Group, 1, AX.StaticText, 1)
      end), true
    end
  end),
  ["com.tencent.meeting"] = function(winUI)
    return getc(winUI, AX.CheckBox), true
  end,
  ["com.netease.uuremote"] = waitForSettings(function(winUI)
    local toolbar = getc(winUI, AX.Toolbar, 1)
    return tmap(getc(toolbar, AX.Group) or {},
        function(g) return getc(g, AX.StaticText, 1) end), true
  end),
  ["com.charliemonroe.Permute-3"] = function(winUI)
    return getc(winUI, AX.ScrollArea, 1, AX.Table, 1, AX.Row)
  end,
  ["com.charliemonroe.Downie-4"] = function(winUI)
    return getc(winUI, AX.ScrollArea, 1, AX.Table, 1, AX.Row)
  end,
  ["com.colliderli.iina"] = function(winUI)
    return getc(winUI, AX.ScrollArea, 1, AX.Table, 1, AX.Row)
  end
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

---@diagnostic disable-next-line: lowercase-global
function reactivateValidSettingsToolbarHotkeys(observer)
  local focusedWin = hs.window.frontmostWindow()
  local focusedWinId = focusedWin and focusedWin:id() or nil
  local enabled = false
  for wid, hotkeys in pairs(settingsToolbarHotkeys) do
    local win = hs.window.get(wid)
    if win == nil then
      for _, hotkey in ipairs(settingsToolbarHotkeys[wid]) do
        HotkeyRegistry.deleteHotkey(hotkey)
      end
      settingsToolbarHotkeys[wid] = nil
      if observer then observer:stop() end
    elseif wid ~= focusedWinId then
      for _, hotkey in ipairs(hotkeys) do
        HotkeyRegistry.disableHotkey(hotkey)
      end
    else
      enabled = true
      for _, hotkey in ipairs(hotkeys) do
        HotkeyRegistry.enableHotkey(hotkey)
      end
    end
  end
  return enabled
end

---@diagnostic disable-next-line: lowercase-global
function registerNavigationForSettingsToolbar(app, retry)
  if retry == nil then retry = 0 end
  if (retry or 0) == 0 and reactivateValidSettingsToolbarHotkeys() then
    return
  end

  local win = getSettingsWindow(app)
  if win == nil then
    if retry and retry < 20 then
      hs.timer.doAfter(0.25, function()
        registerNavigationForSettingsToolbar(app, retry + 1)
      end)
    end
    return
  end
  app = win:application()
  local winUI = towinui(win)
  local appid = app:bundleID() or app:name()
  local buttons, toClick
  if specialToolbarButtons[appid] then
    buttons, toClick = specialToolbarButtons[appid](winUI)
  else
    buttons, toClick = getSidebarRows(winUI)
    if buttons == nil or #buttons == 0 then
      buttons, toClick = getToolbarButtons(winUI)
    end
  end
  if buttons == nil or #buttons == 0 then return end
  local elem = buttons[1]
  repeat
    elem = elem.AXParent
  until elem.AXRole == AX.Window
  winUI = elem
  win = winUI:asHSWindow()
  local wid = win:id()
  local callback
  if toClick then
    callback = Callback.Click
  elseif buttons[1].AXSubrole == AX.OutlineRow
      or buttons[1].AXSubrole == AX.TableRow then
    callback = function(row) row.AXSelected = true end
  else
    callback = Callback.Press
  end
  if hs.window.frontmostWindow() ~= win then
    win:focus()
  end
  local i = 1
  for _, button in ipairs(buttons) do
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
      elseif button.AXSubrole == AX.OutlineRow
          or button.AXSubrole == AX.TableRow then
        local ele = getc(button, AX.Cell, 1, AX.StaticText, 1)
        if ele then
          msg = ele.AXValue
        else
          ele = getc(button, AX.Cell, 1, AX.Unknown, 1)
          if ele then
            msg = ele.AXAttributedDescription:getString()
          end
        end
      else
        msg = button.AXTitle or button.AXDescription
      end
      if (msg == nil or msg == "") and button.AXAttributedDescription ~= nil then
        msg = button.AXAttributedDescription:getString()
      end
      if msg then
        i = i + 1
        local hotkey = AppWinBind(win, {
          spec = spec, message = msg,
          condition = condition, fn = bind(callback, button)
        })
        if settingsToolbarHotkeys[wid] == nil then
          settingsToolbarHotkeys[wid] = {}
        end
        tinsert(settingsToolbarHotkeys[wid], hotkey)
      end
    end
  end
  local closeObserver = uiobserver.new(app:pid())
  closeObserver:addWatcher(winUI, uinotifications.uIElementDestroyed)
  closeObserver:addWatcher(winUI, uinotifications.windowMiniaturized)
  closeObserver:addWatcher(toappui(app), uinotifications.focusedWindowChanged)
  closeObserver:callback(function(obs, ele, notification)
    if notification == uinotifications.uIElementDestroyed then
      obs:stop() obs = nil
      for _, hotkey in ipairs(settingsToolbarHotkeys[wid]) do
        HotkeyRegistry.deleteHotkey(hotkey)
      end
      settingsToolbarHotkeys[wid] = nil
    elseif notification == uinotifications.windowMiniaturized then
      closeObserver:addWatcher(ele, uinotifications.windowDeminiaturized)
      closeObserver:removeWatcher(ele, uinotifications.windowMiniaturized)
    elseif notification == uinotifications.windowDeminiaturized then
      closeObserver:addWatcher(ele, uinotifications.windowMiniaturized)
      closeObserver:removeWatcher(ele, uinotifications.windowDeminiaturized)
    end
    reactivateValidSettingsToolbarHotkeys(obs)
  end)
  closeObserver:start()
  return closeObserver
end

-- Observe selection of "Settings…" / "Preferences…" menu items.
--
-- When triggered, automatically registers toolbar navigation hotkeys
-- for the newly opened settings window.
---@diagnostic disable-next-line: lowercase-global
function registerObserverForSettingsMenuItem(app)
  local appUI = toappui(app)

  local getMenuItem = function(appMenu)
    appMenu = appMenu or getc(appUI, AX.MenuBar, 1, AX.MenuBarItem, 2)
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
          return title:find("Setting") or title:find("Preference")
        end
      end
      return false
    end)
    return settingsMenu
  end
  local menuBarItems = getBufferedMenuBarItems(app)
  if menuBarItems == nil or #menuBarItems == 0 then return end
  local settingsMenu = getMenuItem(menuBarItems[1])
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

---@diagnostic disable-next-line: lowercase-global
function registerObserverForRightMenuBarSettingsMenuItem(app, force)
  local appid = app:bundleID() or app:name()
---@diagnostic disable-next-line: undefined-global
  local observer = MenuBarMenuSelectedObservers[appid]
  if observer == nil then
    if force ~= true then return end
    observer = uiobserver.new(app:pid())
  end

  local oldCallback = observer:callback()
  local settingsMenu, menuClosedObservedBefore
  local callback = function(obs, elem, notification)
    if notification == uinotifications.menuOpened
        and elem.AXParent.AXRole == AX.MenuBar then
      settingsMenu = nil
      local menuItems = getc(elem, AX.MenuItem)
      local sets = TC("Settings…", app)
      local prefs = TC("Preferences…", app)
      settingsMenu = tfind(menuItems, function(item)
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
      settingsMenu = settingsMenu or tfind(menuItems, function(item)
        if item.AXMenuItemCmdChar == ','
            and item.AXMenuItemCmdModifiers == 0 then
          local title = delocalizedString(item.AXTitle, app)
          if type(title) == 'string' then
            return title:find("Setting") or title:find("Preference")
          end
        end
        return false
      end)
      local appCfg = AppHotKeyCallbacks[appid] or {}
      for hkID, cfg in pairs(appCfg) do
        local keybinding = getKeybinding(appid, hkID)
        local hasKey = keybinding.mods ~= nil and keybinding.key ~= nil
        local isMenuBarMenu = keybinding.menubarFilter ~= nil
            or cfg.menubarFilter ~= nil
        if hasKey and isMenuBarMenu
            and hotkeyIdx(keybinding.mods, keybinding.key) == '⌘,' then
          settingsMenu = true
        end
      end
      if settingsMenu then
        menuClosedObservedBefore = tindex(observer:watching(toappui(app)),
            uinotifications.menuClosed) ~= nil
        if not menuClosedObservedBefore then
          observer:addWatcher(toappui(app), uinotifications.menuClosed)
        end
      end
    elseif settingsMenu and notification == uinotifications.menuClosed
        and elem and (elem.AXParent == nil or elem.AXParent.AXRole == AX.Application) then
      settingsMenu, menuClosedObservedBefore = nil, nil
      registerNavigationForSettingsToolbar(app)
      if menuClosedObservedBefore == true and app:isRunning() then
        observer:removeWatcher(toappui(app), uinotifications.menuClosed)
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
  ["com.sublimetext.4"] = function(winUI)
    if winUI.AXRole == AX.Sheet then
      return getc(winUI, AX.Button, "Don't Save")
    end
  end,

  ["com.microsoft.VSCode"] = function(winUI)
    if winUI.AXRole == AX.Sheet then
      return getc(winUI, AX.Button, "Don't Save")
    end
  end,

  ["com.kingsoft.wpsoffice.mac"] = function(winUI)
    if winUI.AXSubrole == AX.Dialog then
      local btnName = T("Don't Save", winUI)
      return btnName and tfind(getc(winUI, AX.Button) or {}, function(button)
        return button.AXTitle and button.AXTitle:match('^'..btnName)
      end)
    end
  end,

  ["JabRef"] = function(winUI)
    if winUI.AXTitle == T("Save before closing", winUI) then
      local button = getc(winUI, AX.Unknown, 1, nil, 1, AX.Button, 1)
      if button and button.AXDescription == T("Discard changes", winUI) then
        return button
      end
    end
  end,

  ["re.rizin.cutter"] = function(winUI)
    if winUI.AXSubrole == AX.Dialog then
      return getc(winUI, AX.Group, 1, AX.Button, "Don't Save")
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
---@diagnostic disable-next-line: lowercase-global
function registerForOpenSavePanel(app, retry)
  for _, hotkey in ipairs(openSavePanelHotkeys) do
    HotkeyRegistry.deleteHotkey(hotkey)
  end
  openSavePanelHotkeys = {}

  local appid = app:bundleID() or app:name()
  if appid == "com.apple.finder" then return end
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
        dontSaveButton = getc(elem, AX.Button, "DontSaveButton")
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
      HotkeyRegistry.deleteHotkey(hotkey)
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
          if A_AppBuf.lastRowCountChangedTimer then
            A_AppBuf.lastRowCountChangedTimer:setNextTrigger(0.3)
            return
          end
          A_AppBuf.lastRowCountChangedTimer = hs.timer.doAfter(0.3, function()
            A_AppBuf.lastRowCountChangedTimer = nil
            for _, hotkey in ipairs(openSavePanelHotkeys) do
              HotkeyRegistry.deleteHotkey(hotkey)
            end
            openSavePanelHotkeys = {}
            actionFunc(winUI, true)
          end)
        end)
        observer:start()
        Evt.OnDestroy(winUI, function()
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
    Evt.OnDestroy(winUI,
      function()
        for _, hotkey in ipairs(openSavePanelHotkeys) do
          HotkeyRegistry.deleteHotkey(hotkey)
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

-- Applications typically use standard menu bar titles (e.g., "File", "Edit",
-- "View", "Window", "Help"). Because these titles are often localized by the OS,
-- we intentionally do not attempt to de-localize them through app bundle searches.
-- Note that some apps may still use uncommon English titles.
local specialLocalizedCommonMenuBarTitle = {
  ["com.tencent.yuanbao"] = { View = "Display" },
}
Evt.OnRunning("com.tencent.xinWeChat", function(app)
  local appid = app:bundleID()
  if applicationVersion(appid) >= "4" then
    specialLocalizedCommonMenuBarTitle[appid] = { View = "Show" }
  end
end)

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
      if focusedApp and (focusedApp ~= app
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
---@diagnostic disable-next-line: lowercase-global
function altMenuBarItem(app, force, reinvokeKey)
  local appid = app:bundleID() or app:name()
  local prefix = '__menubar__'
  local enabled = enableOrDelete(appid, "^" .. prefix, force, true)
  if enabled then return end

  -- check whether called by window filter (possibly with delay)
  if app ~= hs.application.frontmostApplication() then
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
    menuBarItems = getBufferedMenuBarItems(app) or {}
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

  local windowOnBindAltMenu
  if processInvalidAltMenu and app:focusedWindow() ~= nil then
    local win = app:focusedWindow()
    windowOnBindAltMenu = { id = win:id(), title = win:title() }
  end

  local clickMenuCallback
  if useWindowMenuBar then
    clickMenuCallback = function(title, k)
      local menuBarItem = tfind(menuBarItems, function(item)
        return item.AXTitle:gsub("[%c%s]+$", ""):gsub("^[%c%s]+", "") == title
      end)
      if menuBarItem == nil and processInvalidAltMenu then
        processInvalidAltMenu(app, k, windowOnBindAltMenu)
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
        local ok = app:selectMenuItem{ title }
        if ok then return end
      end
      if processInvalidAltMenu then
        processInvalidAltMenu(app, k, windowOnBindAltMenu)
      end
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
    local localeParams = { locale = A_AppLocale }
    local itemLocTitles = delocalizeMenuBarItems(itemTitles, appid, localeParams)
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
        local exBundleID = appVer(app) < "4"
            and "com.tencent.xinWeChat.WeChatAppEx" or "com.tencent.flue.WeChatAppEx"
        local newItemLocTitles = delocalizeMenuBarItems(itemTitles, exBundleID,
                                                        localeParams)
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
    local prefixL = prefix .. 'letter__'
    for i=2,#menuBarItemTitles do
      local spec = invMap[menuBarItemTitles[i]]
      if spec ~= nil then
        local fn = bind(clickMenuCallback, menuBarItemTitles[i], spec[1])
        local hotkey = bindAltMenu(app, modsLetter, spec[1], spec[2], fn)
        HotkeyRegistry.register(appid, prefixL..tostring(i-1), hotkey)
        if reinvokeKey == spec[1] then
          clickMenuCallback(menuBarItemTitles[i])
        end
      end
    end
  end

  -- by index
  if modsIndex then
    if app:focusedWindow() ~= nil then
      local win = app:focusedWindow()
      windowOnBindAltMenu = { id = win:id(), title = win:title() }
    end

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
    local prefixI = prefix .. 'index__'
    for i=1,math.min(10, #menuBarItemTitles - 1) do
      local fn = bind(clickMenuCallback, menuBarItemTitles[i + 1], i % 10)
      local hotkey = bindAltMenu(app, modsIndex, tostring(i % 10), itemTitles[i], fn)
      HotkeyRegistry.register(appid, prefixI..tostring(i), hotkey)
      if reinvokeKey == i % 10 then
        clickMenuCallback(menuBarItemTitles[i + 1])
      end
    end
  end

  -- app menu
  if specAppMenu and specAppMenu.key then
    local hotkey = bindAltMenu(app, specAppMenu.mods, specAppMenu.key,
        menuBarItemTitles[1],
        function() app:selectMenuItem{ menuBarItemTitles[1] } end)
    HotkeyRegistry.register(appid, prefix..'app', hotkey)
  end
end


-- ## callbacks

-- workspace callbacks
local function AppSharedHotkeys_spaceChangedCallback()
  registerResizeHotkeys(hs.application.frontmostApplication())
end

registerSpaceChangedCallback(AppSharedHotkeys_spaceChangedCallback)
