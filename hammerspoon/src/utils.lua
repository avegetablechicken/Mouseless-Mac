---@diagnostic disable: lowercase-global

-- # table / AX query helpers

-- Recursively access nested table fields with a variadic key path.
function get(table, key, ...)
  if table == nil or key == nil then return table end
  return get(table[key], ...)
end

-- Recursively query app preferences plist for a key path.
-- Handle both regular applications and sandboxed applications (which store preferences in a different location).
function getp(appid, key, ...)
  local plistPath = hs.fs.pathToAbsolute(strfmt(
      "~/Library/Containers/%s/Data/Library/Preferences/%s.plist", appid, appid))
  if plistPath ~= nil then
    local defaults = hs.plist.read(plistPath)
    return get(defaults, key, ...)
  end

  plistPath = hs.fs.pathToAbsolute(strfmt(
      "~/Library/Preferences/%s.plist", appid))
  if plistPath ~= nil then
    local defaults = hs.plist.read(plistPath)
    return get(defaults, key, ...)
  end
end

local appPreferencesCache = hs.settings.get("_app_preferences_cache") or {}

function getAppPreferencePaths(appid)
  return
    hs.fs.pathToAbsolute(strfmt(
        "~/Library/Containers/%s/Data/Library/Preferences/%s.plist", appid, appid)),
    hs.fs.pathToAbsolute(strfmt(
        "~/Library/Preferences/%s.plist", appid))
end

function getAppPreferenceMtime(path)
  if path == nil then return end
  return hs.fs.attributes(path, "modification")
end

function getAppPreferenceCacheEntry(appid)
  local cache = appPreferencesCache[appid]
  if cache == nil then return end

  local containerPlistPath, plistPath = getAppPreferencePaths(appid)
  local containerMtime = getAppPreferenceMtime(containerPlistPath)
  local plistMtime = getAppPreferenceMtime(plistPath)
  if cache.containerMtime == containerMtime and cache.plistMtime == plistMtime then
    return cache
  end
end

function setAppPreferenceCacheField(appid, key, value)
  local containerPlistPath, plistPath = getAppPreferencePaths(appid)
  if containerPlistPath or plistPath then
    appPreferencesCache[appid] = appPreferencesCache[appid] or {}
    appPreferencesCache[appid].containerMtime = getAppPreferenceMtime(containerPlistPath)
    appPreferencesCache[appid].plistMtime = getAppPreferenceMtime(plistPath)
    appPreferencesCache[appid][key] = value
    hs.settings.set("_app_preferences_cache", appPreferencesCache)
  end
  return value
end

-- Recursively traverse AXUIElement children by role, index or identifier.
-- Supports numeric index, negative index, AXIdentifier, AXTitle and AXValue.
function getc(element, role, index, ...)
  if element == nil or (role == nil and index == nil) then return element end
  local children, child
  if role == nil then
    children = element.AXChildren
  else
    children = element:childrenWithRole(role)
    if index == nil then return children end
  end
  if type(index) == 'number' then
    if index < 0 then index = #children + index + 1 end
    child = children[index]
  else
    child = tfind(children, function(c)
      if c.AXIdentifier == index then return true end
      local cRole = role or c.AXRole
      if cRole == AX.StaticText then
        return c.AXValue == index
      else
        return c.AXTitle == index
      end
    end)
  end
  return getc(child, ...)
end

-- # filesystem helpers

-- Check whether a filesystem path exists.
function exists(path)
  return hs.fs.attributes(path) ~= nil
end

-- Check whether a path points to a regular file.
function isfile(path)
  return hs.fs.attributes(path, 'mode') == 'file'
end

-- Check whether a path points to a directory.
function isdir(path)
  return hs.fs.attributes(path, 'mode') == 'directory'
end

-- Create a directory if it does not already exist.
function mkdir(path)
  if not exists(path) then hs.fs.mkdir(path) end
end

-- # geometry / UI helpers

-- Offset an AXPosition or point by a given vector.
function uioffset(point, offset)
  if point.AXPosition then
    point = point.AXPosition
  end
  return hs.geometry.point{
    (point.x or point[1]) + (offset.x or offset[1]),
    (point.y or point[2]) + (offset.y or offset[2]),
  }
end

-- Determine whether the focused window is in a fullscreen (non-user) space.
function inFullscreenSpace()
  local focusedWindow = hs.application.frontmostApplication():focusedWindow()
  if focusedWindow ~= nil and focusedWindow:id() ~= 0 then
    local spaces = hs.spaces.windowSpaces(focusedWindow)
    if #spaces == 0 then
      hs.timer.usleep(0.1 * 1000000)
      spaces = hs.spaces.windowSpaces(focusedWindow)
    end
    if spaces[1] then
      return hs.spaces.spaceType(spaces[1]) ~= "user"
    end
  end
  return false
end

-- Detect whether the menu bar is currently visible on the main screen.
function menuBarVisible()
  local frame = hs.screen.mainScreen():fullFrame()
  local elem = hs.axuielement.systemElementAtPosition(frame.x, frame.y)
  return elem.AXRole == AX.MenuBar
end

-- Get menu bar items of an application, optionally ignoring Apple and App menus.
function getMenuBarItems(app, ignoreAppMenu, ignoreAppleMenu)
  if ignoreAppleMenu == nil then ignoreAppleMenu = true end
  local menuBarItems = getc(toappui(app), AX.MenuBar, 1, AX.MenuBarItem)
  if menuBarItems == nil then return end
  if ignoreAppMenu and #menuBarItems > 1 then
    tremove(menuBarItems, 2)
  end
  if ignoreAppleMenu and #menuBarItems > 0 then
    tremove(menuBarItems, 1)
  end
  return menuBarItems
end

-- # menu item helpers

-- Mapping of special control characters to readable key symbols.
SPECIAL_KEY_SIMBOL_MAP = {
  ['\b'] = '⌫',
  ['\t'] = '⇥',
  ['\n'] = '↵',
  ['\r'] = '↵',
  ['\x1b'] = '⎋',
  [' '] = '␣',
  ['\xef\x9c\x80'] = '↑',
  ['\xef\x9c\x81'] = '↓',
  ['\xef\x9c\x82'] = '←',
  ['\xef\x9c\x83'] = '→',
  ['\xef\x9c\x84'] = 'F1',
  ['\xef\x9c\x85'] = 'F2',
  ['\xef\x9c\x86'] = 'F3',
  ['\xef\x9c\x87'] = 'F4',
  ['\xef\x9c\x88'] = 'F5',
  ['\xef\x9c\x89'] = 'F6',
  ['\xef\x9c\x8a'] = 'F7',
  ['\xef\x9c\x8b'] = 'F8',
  ['\xef\x9c\x8c'] = 'F9',
  ['\xef\x9c\x8d'] = 'F10',
  ['\xef\x9c\x8e'] = 'F11',
  ['\xef\x9c\x8f'] = 'F12',
  ['\xef\x9c\xa9'] = '↖',
  ['\xef\x9c\xab'] = '↘',
  ['\xef\x9c\xac'] = '⇞',
  ['\xef\x9c\xad'] = '⇟',
  ['\xf0\x9f\x8e\xa4'] = '🎤︎',
}

-- Find a menu item by title path, with localization fallback support.
function findMenuItem(app, menuItemTitle, params)
  local menuItem = app:findMenuItem(menuItemTitle)
  if menuItem ~= nil then return menuItem, menuItemTitle end
  local targetMenuItem = {}
  local appid = app:bundleID() or app:name()
  local locStr = localizedMenuBarItem(menuItemTitle[1], appid)
  tinsert(targetMenuItem, locStr or menuItemTitle[1])
  for i=2,#menuItemTitle do
    locStr = localizedString(menuItemTitle[i], appid, params)
    if type(locStr) == 'table' then
      for _, s in ipairs(locStr) do
        tinsert(targetMenuItem, s)
        if app:findMenuItem(targetMenuItem) then break
        else targetMenuItem[#targetMenuItem] = nil end
      end
      if #targetMenuItem ~= i then return end
    else
      tinsert(targetMenuItem, locStr or menuItemTitle[i])
    end
  end
  return app:findMenuItem(targetMenuItem), targetMenuItem
end

-- Internal recursive implementation for matching menu items by key binding.
local function findMenuItemByKeyBindingImpl(mods, key, menuItem)
  if menuItem.AXChildren == nil or #menuItem.AXChildren == 0 then return end
  -- werid bug in apps like `UPDF`! have to query this value once to make sure
  -- that next query will get a correct result
  local _ = #menuItem.AXChildren[1]
  for _, subItem in ipairs(menuItem.AXChildren[1]) do
    local cmdChar = subItem.AXMenuItemCmdChar
    if cmdChar and cmdChar ~= ""
        and (cmdChar:byte(1) <= 32 or cmdChar:byte(1) > 127) then
      cmdChar = SPECIAL_KEY_SIMBOL_MAP[key] or cmdChar
    end
    if (cmdChar == key
        or (subItem.AXMenuItemCmdGlyph ~= ""
            and hs.application.menuGlyphs[subItem.AXMenuItemCmdGlyph] == key)) then
      local match
      if type(mods) == 'number' then
        match = subItem.AXMenuItemCmdModifiers == mods
      else
        if #subItem.AXMenuItemCmdModifiers == #mods then
          match = true
          for _, mod in ipairs(mods) do
            if not tcontain(subItem.AXMenuItemCmdModifiers, mod) then
              match = false
              break
            end
          end
        end
      end
      if match then
        return { subItem.AXTitle }, subItem.AXEnabled
      end
    end
    local menuItemPath, enabled =
        findMenuItemByKeyBindingImpl(mods, key, subItem)
    if menuItemPath ~= nil then
      tinsert(menuItemPath, 1, subItem.AXTitle)
      return menuItemPath, enabled
    end
  end
end

-- Binary representation of modifier symbols for fast comparison.
local modifierBinary = {
  ["⌘"] = 1 << 3,
  ["⌃"] = 1 << 2,
  ["⌥"] = 1 << 1,
  ["⇧"] = 1 << 0
}

-- Normalize modifier representation for menu item matching.
-- Returns either a binary mask (likelyToFind=true) or modifier list.
local function getModsRepr(mods, likelyToFind)
  if mods == '' then mods = {} end
  if type(mods) == 'string' and mods:byte(1, 1) < 127 then
    mods = { mods }
  end
  if likelyToFind then
    local modsRepr = 1 << 3
    if type(mods) == 'string' then
      for i=1,utf8.len(mods) do
        local mod = mods:sub(i*3-2, i*3)
        local v = modifierBinary[tosymbol(mod)]
        if mod == '⌘' then
          modsRepr = modsRepr &~ v
        else
          modsRepr = modsRepr | v
        end
      end
    else
      for _, mod in ipairs(mods) do
        local v = modifierBinary[tosymbol(mod)]
        if mod == Mod.Cmd.Long or mod == Mod.Cmd.Short then
          modsRepr = modsRepr &~ v
        else
          modsRepr = modsRepr | v
        end
      end
    end
    return modsRepr
  else
    local newMods = {}
    if type(mods) == 'string' then
      for i = 1, utf8.len(mods) do
        local mod = mods:sub(i * 3 - 2, i * 3)
        tinsert(newMods, toshort(mod))
      end
    else
      for _, mod in ipairs(mods) do
        tinsert(newMods, toshort(mod))
      end
    end
    return newMods
  end
end

-- Find a menu item by its keyboard shortcut.
-- Supports synchronous lookup, async callback, and pre-filtered menu trees.
function findMenuItemByKeyBinding(app, mods, key, likelyToFind, menuItems)
  local fn = function(menuItems)
    if menuItems == nil then return end
    mods = getModsRepr(mods, likelyToFind)
    for i=#menuItems,1,-1 do
      local menuItem = menuItems[i]
      local menuItemPath, enabled =
          findMenuItemByKeyBindingImpl(mods, key, menuItem)
      if menuItemPath ~= nil then
        tinsert(menuItemPath, 1, menuItem.AXTitle)
        return menuItemPath, enabled
      end
    end
  end

  if type(likelyToFind) == 'function' then
    local callback = likelyToFind
    likelyToFind = false
    return app:getMenuItems(function(...)
      local menuItemPath = fn(...)
      if menuItemPath then
        callback(menuItemPath)
      end
    end)
  end

  if menuItems == nil and likelyToFind ~= nil
      and (type(likelyToFind) ~= 'boolean') then
    menuItems = likelyToFind
    likelyToFind = true
  end
  if menuItems == nil then
    if likelyToFind then
      menuItems = getMenuBarItems(app)
    else
      menuItems = app:getMenuItems()
    end
    if menuItems == nil then return end
  elseif type(menuItems) == 'string' then
    local title = localizedMenuBarItem(menuItems, app:bundleID() or app:name())
    menuItems = { getc(toappui(app), AX.MenuBar, 1, AX.MenuBarItem, title) }
  end
  return fn(menuItems)
end

-- # application helpers

-- Filter out Parallels helper processes from application lists.
local function filterParallels(apps)
  return tfind(apps, function(app)
    return app:bundleID() == nil
        or app:bundleID():find("com.parallels") == nil
        or app:bundleID() == "com.parallels.desktop.console"
  end)
end

-- Find an application by name or bundle id, excluding Parallels helpers.
function find(hint, exact)
  if exact == nil then exact = true end
  return filterParallels{hs.application.find(hint, exact)}
end

-- Quit an application by name or bundle id.
function quit(hint)
  local app = find(hint, true)
  if app ~= nil then
    app:kill()
    return true
  end
  return false
end

-- Check whether an application bundle is installed.
function installed(appid)
  local path = hs.application.pathForBundleID(appid)
  return path and path ~= ""
end

-- Retrieve application version as (major, minor, patch).
local Version = require("version")
function applicationVersion(appid)
  local appPath = hs.application.pathForBundleID(appid)
  if appPath == nil or appPath == "" then return end
  local version
  if exists(appPath .. '/Contents/Info.plist') then
    local info = hs.plist.read(appPath .. '/Contents/Info.plist')
    version = info.CFBundleShortVersionString or info.CFBundleVersion
  else
    version = hs.execute(strfmt("mdls -r -name kMDItemVersion '%s'", appPath))
  end
  return Version.new(version)
end

-- # mouse event helpers

-- Move mouse cursor to a screen position.
function mouseMove(position, modifiers)
  hs.eventtap.event.newMouseEvent(
    hs.eventtap.event.types.mouseMoved,
    position, modifiers
  ):post()
end

-- Simulate mouse button press at a position.
function mouseDown(position, modifiers)
  hs.eventtap.event.newMouseEvent(
    hs.eventtap.event.types.leftMouseDown,
    position, modifiers
  ):post()
end

-- Simulate mouse button release at a position.
function mouseUp(position, modifiers)
  hs.eventtap.event.newMouseEvent(
    hs.eventtap.event.types.leftMouseUp,
    position, modifiers
  ):post()
end

-- Simulate a mouse drag operation.
function mouseDrag(start_position, end_position, modifiers)
  mouseMove(start_position, modifiers)
  mouseDown(start_position, modifiers)
  hs.eventtap.event.newMouseEvent(
    hs.eventtap.event.types.leftMouseDragged,
    end_position, modifiers
  ):post()
  mouseUp(end_position, modifiers)
end

-- # network / Wi-Fi helpers

-- Get current Wi-Fi SSID with multiple fallbacks across macOS versions.
function getSSID(interface)
  local ssid = hs.wifi.currentNetwork()
  if ssid == nil then
    if hs.location.servicesEnabled() then
      hs.location.start()
      -- you may be prompted to authorise Hammerspoon to use Location Services
      if hs.location.get() then
        ssid = hs.wifi.currentNetwork()
      end
      hs.location.stop()
    end
  end
  if ssid == nil then
    local osv = hs.host.operatingSystemVersion()
    if osv.major < 15 or (osv.major == 15 and osv.minor < 6) then
      interface = interface or hs.network.primaryInterfaces()
      ssid = hs.execute(strfmt([[
        ipconfig getsummary %s | awk -F ' SSID : '  '/ SSID : / {print $2}' | tr -d '\n'
      ]], interface))
    end
  end
  return ssid
end

-- Low-level click helpers

-- Perform a left or right click at a given point or AX element.
-- Optionally verifies the target belongs to the specified application.
local function clickImpl(leftClick, point, obj)
  -- Normalize AX element to screen coordinates (center point)
  if point.AXPosition ~= nil then
    point = hs.geometry.point {
      point.AXPosition.x + point.AXSize.w / 2,
      point.AXPosition.y + point.AXSize.h / 2
    }
  elseif point.x == nil then
    point = hs.geometry.point(point)
  end

  -- Ensure the click target belongs to the expected application
  if obj ~= nil then
    local appHere = hs.axuielement.systemElementAtPosition(point)
    while appHere ~= nil and appHere.AXParent ~= nil do
      appHere = appHere.AXParent
    end
    if appHere then
      appHere = appHere:asHSApplication()
      local app = obj.application and obj:application() or obj
      if appHere ~= app then return false end
    else
      return false
    end
  end

  -- Dispatch actual mouse event
  if leftClick then
    hs.eventtap.leftClick(point)
  else
    hs.eventtap.rightClick(point)
  end
  return true
end

-- Click and restore the mouse position afterward.
local function clickAndRestoreImpl(leftClick, point, obj, delay)
  if type(obj) == 'number' then
    delay = obj obj = nil
  end
  local mousePosition = hs.mouse.absolutePosition()
  if clickImpl(leftClick, point, obj) then
    if delay then
      hs.timer.doAfter(delay, function()
        hs.mouse.absolutePosition(mousePosition)
      end)
    else
      hs.mouse.absolutePosition(mousePosition)
    end
    return true
  end
  return false
end

-- Left click a point.
function leftClick(point, obj)
  return clickImpl(true, point, obj)
end

-- Right click a point.
function rightClick(point, obj)
  return clickImpl(false, point, obj)
end

-- Left click and restore cursor position.
function leftClickAndRestore(point, obj, delay)
  return clickAndRestoreImpl(true, point, obj, delay)
end

-- Right click and restore cursor position.
function rightClickAndRestore(point, obj, delay)
  return clickAndRestoreImpl(false, point, obj, delay)
end


-- # other helpers

require("utils.menubar")

-- Load extracted utils parts into the shared global environment.
local function loadUtilsPart(part, env)
  local path = hs.configdir .. "/src/utils/" .. part .. ".lua"
  local chunk, err = loadfile(path, "t", env or _ENV)
  if not chunk then
    error(err)
  end
  chunk()
end

local localizationEnv = setmetatable({}, { __index = _G })
loadUtilsPart("localization", localizationEnv)
for _, name in ipairs({
  "SYSTEM_LOCALE",
  "applicationLocale",
  "applicationValidLocale",
  "displayName",
  "localizedString",
  "delocalizedString",
  "localizeCommonMenuItemTitles",
  "delocalizedMenuItem",
  "delocalizeMenuBarItems",
  "localizedMenuBarItem",
  "matchLocale",
  "resetLocalizationMap",
  "getResourceDir",
}) do
  _G[name] = localizationEnv[name]
end
