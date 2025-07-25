---@diagnostic disable: lowercase-global

function get(table, key, ...)
  if table == nil or key == nil then return table end
  return get(table[key], ...)
end

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

function exists(path)
  return hs.fs.attributes(path) ~= nil
end

function isfile(path)
  return hs.fs.attributes(path, 'mode') == 'file'
end

function isdir(path)
  return hs.fs.attributes(path, 'mode') == 'directory'
end

function mkdir(path)
  if not exists(path) then hs.fs.mkdir(path) end
end

function uioffset(point, offset)
  if point.AXPosition then
    point = point.AXPosition
  end
  return hs.geometry.point{
    (point.x or point[1]) + (offset.x or offset[1]),
    (point.y or point[2]) + (offset.y or offset[2]),
  }
end

function inFullscreenSpace()
  local focusedWindow = hs.application.frontmostApplication():focusedWindow()
  if focusedWindow ~= nil and focusedWindow:id() ~= 0 then
    local spaces = hs.spaces.windowSpaces(focusedWindow)
    if #spaces == 0 then
      hs.timer.usleep(0.1 * 1000000)
      spaces = hs.spaces.windowSpaces(focusedWindow)
    end
    return hs.spaces.spaceType(spaces[1]) ~= "user"
  end
  return false
end

function menuBarVisible()
  local frame = hs.screen.mainScreen():fullFrame()
  local elem = hs.axuielement.systemElementAtPosition(frame.x, frame.y)
  return elem.AXRole == AX.MenuBar
end

function getMenuBarItems(app, ignoreAppMenu, ignoreAppleMenu)
  if ignoreAppleMenu == nil then ignoreAppleMenu = true end
  local menuBarItems = getc(toappui(app), AX.MenuBar, 1, AX.MenuBarItem) or {}
  if ignoreAppMenu and #menuBarItems > 1 then
    tremove(menuBarItems, 2)
  end
  if ignoreAppleMenu and #menuBarItems > 0 then
    tremove(menuBarItems, 1)
  end
  return menuBarItems
end

function showMenuItemWrapper(fn)
  return function()
    if menuBarVisible() then
      fn()
    else
      hs.eventtap.keyStroke('fn⌃', 'F2')
      hs.timer.doAfter(0.1, fn)
    end
  end
end

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

function findMenuItem(app, menuItemTitle, params)
  local menuItem = app:findMenuItem(menuItemTitle)
  if menuItem ~= nil then return menuItem, menuItemTitle end
  local targetMenuItem = {}
  local locStr = localizedMenuBarItem(menuItemTitle[1], app:bundleID())
  tinsert(targetMenuItem, locStr or menuItemTitle[1])
  for i=2,#menuItemTitle do
    locStr = localizedString(menuItemTitle[i], app:bundleID(), params)
    if type(locStr) == 'table' then
      for _, s in ipairs(locStr) do
        tinsert(targetMenuItem, s)
        if app:findMenuItem(targetMenuItem) then break
        else targetMenuItem[#targetMenuItem] = nil end
      end
    else
      tinsert(targetMenuItem, locStr or menuItemTitle[i])
    end
  end
  return app:findMenuItem(targetMenuItem), targetMenuItem
end

function selectMenuItem(app, menuItemTitle, params, show)
  if type(params) == "boolean" then
    show = params params = nil
  end

  if show then
    local menuItem, targetMenuItem = findMenuItem(app, menuItemTitle, params)
    if menuItem ~= nil then
      showMenuItemWrapper(function()
        app:selectMenuItem({targetMenuItem[1]})
      end)()
      return app:selectMenuItem(targetMenuItem)
    end
  else
    if app:selectMenuItem(menuItemTitle) then return true end
    local targetMenuItem = {}
    local locStr = localizedMenuBarItem(menuItemTitle[1], app:bundleID())
    tinsert(targetMenuItem, locStr or menuItemTitle[1])
    for i=2,#menuItemTitle do
    locStr = localizedString(menuItemTitle[i], app:bundleID(), params)
    if type(locStr) == 'table' then
      for _, s in ipairs(locStr) do
        tinsert(targetMenuItem, s)
        if app:findMenuItem(targetMenuItem) then break
        else targetMenuItem[#targetMenuItem] = nil end
      end
    else
      tinsert(targetMenuItem, locStr or menuItemTitle[i])
    end
  end
    return app:selectMenuItem(targetMenuItem)
  end
end

local function findMenuItemByKeyBindingImpl(mods, key, menuItem)
  if menuItem.AXChildren == nil or #menuItem.AXChildren == 0 then return end
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

local modifierSymbolMap1 = {
  command = 1 << 3,
  control = 1 << 2,
  option = 1 << 1,
  shift = 1 << 0,
  cmd = 1 << 3,
  ctrl = 1 << 2,
  alt = 1 << 1,
  ["⌘"] = 1 << 3,
  ["⌃"] = 1 << 2,
  ["⌥"] = 1 << 1,
  ["⇧"] = 1 << 0
}

local modifierSymbolMap2 = {
  command = 'cmd',
  control = 'ctrl',
  option = 'alt',
  ["⌘"] = 'cmd',
  ["⌃"] = 'ctrl',
  ["⌥"] = 'alt',
  ["⇧"] = 'shift'
}

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
        local v = modifierSymbolMap1[mod]
        if mod == "⌘" then
          modsRepr = modsRepr &~ v
        else
          modsRepr = modsRepr | v
        end
      end
    else
      for _, mod in ipairs(mods) do
        local v = modifierSymbolMap1[mod]
        if mod == "command" or mod == 'cmd' then
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
        tinsert(newMods, modifierSymbolMap2[mod] or mod)
      end
    else
      for _, mod in ipairs(mods) do
        tinsert(newMods, modifierSymbolMap2[mod] or mod)
      end
    end
    return newMods
  end
end

function findMenuItemByKeyBinding(app, mods, key, likelyToFind, menuItems)
  if menuItems == nil then
    if likelyToFind then
      menuItems = getMenuBarItems(app)
    else
      menuItems = app:getMenuItems()
    end
    if menuItems == nil then return end
  end
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

local function filterParallels(apps)
  return tfind(apps, function(app)
    return app:bundleID() == nil
        or app:bundleID():find("com.parallels") == nil
        or app:bundleID() == "com.parallels.desktop.console"
  end)
end

function find(hint, exact)
  if exact == nil then exact = true end
  return filterParallels{hs.application.find(hint, exact)}
end

function quit(hint)
  local app = find(hint, true)
  if app ~= nil then
    app:kill()
    return true
  end
  return false
end

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
  version = strsplit(version, "%.")
  local major, minor, patch
  major = tonumber(version[1]:match("%d+"))
  minor = #version > 1 and tonumber(version[2]:match("%d+")) or 0
  patch = #version > 2 and tonumber(version[3]:match("%d+")) or 0
  return major, minor, patch
end

local localeTmpDir = hs.fs.temporaryDirectory()
    .. 'org.hammerspoon.Hammerspoon/locale/'

local locMap, delocMap = {}, {}
localizationMapLoaded = { menubar = {}, strings = {} }
local localizationFrameworks = {}
if exists("config/localization.json") then
  local json = hs.json.read("config/localization.json")
  localizationFrameworks = json['resources']
  json['resources'] = nil
  for appid, config in pairs(json) do
    if #config == 0 then
      localizationMapLoaded['menubar'][appid] = config
      localizationMapLoaded['strings'][appid] = {}
      local dict = localizationMapLoaded['strings'][appid]
      for k, v in pairs(config) do
        if dict[v] == nil then
          dict[v] = k
        elseif type(dict[v]) == 'string' then
          dict[v] = { dict[v], k }
        else
          tinsert(dict[v], k)
        end
      end
    else
      localizationMapLoaded['menubar'][appid] = config[1]
      localizationMapLoaded['strings'][appid] = config[2]
      local dict = localizationMapLoaded['strings'][appid]
      for k, v in pairs(config[1]) do
        if dict[v] == nil then
          dict[v] = k
        elseif type(dict[v]) == 'string' then
          dict[v] = { dict[v], k }
        else
          tinsert(dict[v], k)
        end
      end
    end
  end
  delocMap = tcopy(localizationMapLoaded['menubar'])
  locMap = tcopy(localizationMapLoaded['strings'])
end
function resetLocalizationMap(appid)
  if localizationMapLoaded[appid] ~= nil then
    delocMap[appid] = tcopy(localizationMapLoaded[appid]['menubar'])
    locMap[appid] = tcopy(localizationMapLoaded[appid]['strings'])
  else
    locMap[appid] = nil
    delocMap[appid] = nil
  end
end

delocMap.common = {}
locMap.common = {}

local function systemLocales()
  local plistPath = "/Library/Preferences/.GlobalPreferences.plist"
  local locales = hs.plist.read(plistPath).AppleLanguages
  return locales[1]
end
SYSTEM_LOCALE = systemLocales()

local electronLocale, javaLocale
function applicationLocale(appid)
  -- locale of `WeChat` and apps whose localization is enabled by Electron or Java
  -- cannot be aquired in preferences files
  if appid == "com.tencent.xinWeChat" then
    if applicationVersion(appid) >= 4 then
      local app = find(appid)
      if app then
        local file = getc(toappui(app),
            AX.MenuBar, 1, AX.MenuBarItem, 3)
        if file == nil then return SYSTEM_LOCALE end
        if file.AXTitle == "File" then return "en"
        elseif file.AXTitle == localizedString('File', {
          locale = 'zh_CN',
          localeFile = 'MenuCommands',
          framework = "AppKit.framework",
        }) then return "zh-Hans"
        else
          return 'zh-Hant'
        end
      else
        return SYSTEM_LOCALE
      end
    end
  elseif localizationFrameworks[appid] ~= nil then
    if localizationFrameworks[appid].electron then
      local locale
      local appContentPath = hs.application.pathForBundleID(appid) .. "/Contents"
      if exists(appContentPath .. "/Resources/app.asar") then
        local app = find(appid)
        if app then
          locale = electronLocale(app, localizationFrameworks[appid])
        end
      end
      return locale or SYSTEM_LOCALE
    elseif localizationFrameworks[appid].java then
      local locale
      local appContentPath = hs.application.pathForBundleID(appid) .. "/Contents"
      local jimage, status = hs.execute(strfmt([[
        find '%s' -type f -name jimage | tr -d '\n'
      ]], appContentPath))
      if status and jimage ~= "" then
        local app = find(appid)
        if app then
          resourceDir = jimage:sub(1, #jimage - #'/bin/jimage')
          locale = javaLocale(app, resourceDir, localizationFrameworks[appid])
        end
      end
      return locale or SYSTEM_LOCALE
    end
  end

  local errorReadingDefaults = false
  local plistPath = hs.fs.pathToAbsolute(strfmt(
      "~/Library/Containers/%s/Data/Library/Preferences/%s.plist", appid, appid))
  if plistPath ~= nil then
    local defaults = hs.plist.read(plistPath)
    if defaults then
      local locales = defaults.AppleLanguages
      if locales ~= nil then return locales[1] end
    else
      errorReadingDefaults = true
    end
  end
  plistPath = hs.fs.pathToAbsolute(strfmt(
      "~/Library/Preferences/%s.plist", appid))
  if plistPath ~= nil then
    local defaults = hs.plist.read(plistPath)
    if defaults then
      local locales = defaults.AppleLanguages
      if locales ~= nil then return locales[1] end
    else
      errorReadingDefaults = true
    end
  end
  if errorReadingDefaults then
    local locales = hs.execute(
        strfmt("defaults read %s AppleLanguages | tr -d '()\" \\n'", appid))
    if locales ~= "" then
      return strsplit(locales, ',')[1]
    end
  end
  return SYSTEM_LOCALE
end

local function dirNotExistOrEmpty(dir)
  if not exists(dir) then return true end
  for file in hs.fs.dir(dir) do
    if file:sub(1, 1) ~= '.' then return false end
  end
  return true
end

function getResourceDir(appid, frameworkName)
  if frameworkName == nil then
    frameworkName = localizationFrameworks[appid]
  end
  local resourceDir
  local framework = {}
  local appContentPath
  if appid ~= '__macos' then
    appContentPath = hs.application.pathForBundleID(appid) .. "/Contents"
  end
  if appContentPath and not exists(appContentPath) then
    resourceDir = hs.application.pathForBundleID(appid) .. "/WrappedBundle/.."
  elseif frameworkName ~= nil then
    local frameworkDir
    local frameworkNames = frameworkName
    if type(frameworkNames) == 'string' or #frameworkNames == 0 then
      frameworkNames = { frameworkNames }
    end
    for _, frameworkName in ipairs(frameworkNames) do
      if type(frameworkName) == 'string' and exists(frameworkName) then
        frameworkDir = frameworkName
      elseif appContentPath ~= nil then
        if type(frameworkName) == 'table'then
          if frameworkName.electron and
              exists(appContentPath .. "/Resources/app.asar") then
            resourceDir = appContentPath .. "/Resources"
            framework.electron = frameworkName.electron
            goto END_GET_RESOURCE_DIR
          elseif frameworkName.java then
            local jimage, status = hs.execute(strfmt([[
              find '%s' -type f -name jimage | tr -d '\n'
            ]], appContentPath))
            if status and jimage ~= "" then
              resourceDir = jimage:sub(1, #jimage - #'/bin/jimage')
              framework.java = frameworkName.java
              goto END_GET_RESOURCE_DIR
            end
          end
        else
          _, status = hs.execute(strfmt([[
            find '%s' -type f -path '%s/Resources/%s/*.properties' | tr -d '\n'
          ]], appContentPath, appContentPath, frameworkName))
          if status and _ ~= "" then
            resourceDir = appContentPath .. '/Resources/' .. frameworkName
            framework.properties = true
          end

          _, status = hs.execute(strfmt([[
            find '%s' -type f -path '%s/Resources/%s/*.dtd' | tr -d '\n'
          ]], appContentPath, appContentPath, frameworkName))
          if status and _ ~= "" then
            resourceDir = appContentPath .. '/Resources/' .. frameworkName
            framework.dtd = true
          end

          _, status = hs.execute(strfmt([[
            find '%s' -type f -path '%s/Resources/%s/*.ftl' | tr -d '\n'
          ]], appContentPath, appContentPath, frameworkName))
          if status and _ ~= "" then
            resourceDir = appContentPath .. '/Resources/' .. frameworkName
            framework.ftl = true
          end
          if resourceDir then goto END_GET_RESOURCE_DIR end

          frameworkDir = hs.execute(strfmt([[
            find '%s' -type d -name '%s' | head -n 1 | tr -d '\n'
          ]], appContentPath, frameworkName))
        end
      end
      if (frameworkDir == nil or frameworkDir == "")
          and type(frameworkName) == 'string' then
        for _, searchDir in ipairs {
          '/System/Library/Frameworks',
          '/System/Library/PrivateFrameworks',
          '/System/iOSSupport/System/Library/PrivateFrameworks',
        } do
          if exists(searchDir .. '/' .. frameworkName) then
            frameworkDir = searchDir .. '/' .. frameworkName
            break
          end
        end
      end
      if frameworkDir ~= nil and frameworkDir ~= "" then
        if not exists(frameworkDir .. "/Contents") then
          resourceDir = frameworkDir .. "/Resources"
        else
          resourceDir = frameworkDir .. "/Contents/Resources"
        end
        framework.user = true
        if frameworkDir:sub(-10) == ".framework" and exists(resourceDir) then
          local chromiumDirs, status = hs.execute(strfmt([[
            find '%s/' -type f -path '*/locale.pak'
          ]], resourceDir))
          if status and chromiumDirs:sub(1, -2) ~= "" then
            framework.chromium = true
            framework.user = nil
            goto END_GET_RESOURCE_DIR
          end
        end
      end
    end
  else
    if exists(appContentPath .. "/Frameworks") then
      local chromiumDirs, status = hs.execute(strfmt([[
        find '%s' -type f -path '*/Resources/*/locale.pak' \
        | awk -F'/Versions/' '{print $1}' | uniq
      ]], appContentPath .. "/Frameworks"))
      if status and chromiumDirs:sub(1, -2) ~= "" then
        chromiumDirs = strsplit(chromiumDirs:sub(1, -2), '\n')
        if #chromiumDirs == 1 then
          local prefix_len = (appContentPath .. "/Frameworks/"):len()
          if not chromiumDirs[1]:sub(prefix_len + 1):find('/') then
            resourceDir = chromiumDirs[1] .. "/Resources"
            framework.chromium = true
            goto END_GET_RESOURCE_DIR
          end
        end
      end
    end

    if exists(appContentPath .. "/Resources/qt.conf") then
      resourceDir = appContentPath .. "/Resources"
      framework.qt = true
      goto END_GET_RESOURCE_DIR
    end

    local monoLocaleDirs, status = hs.execute(strfmt([[
      find '%s' -type f -path '*/locale/*/LC_MESSAGES/*.mo' \
      | awk -F'/locale/' '{print $1}' | uniq
    ]], appContentPath))
    if status and monoLocaleDirs:sub(1, -2) ~= "" then
      monoLocaleDirs = strsplit(monoLocaleDirs:sub(1, -2), '\n')
      if #monoLocaleDirs == 1 then
        resourceDir = monoLocaleDirs[1] .. "/locale"
        framework.mono = true
        goto END_GET_RESOURCE_DIR
      end
    end
  end

  if resourceDir == nil then
    resourceDir = appContentPath .. "/Resources"
  end

  ::END_GET_RESOURCE_DIR::
  if not exists(resourceDir) then return nil, {} end
  return resourceDir, framework
end

local function getBestMatchedLocale(appLocale, locales, combineExtras, multiplePerfectMatch)
  local bestMatch, bestScore = nil, -1
  for _, locale in ipairs(locales) do
    if locale.scriptCode == appLocale.scriptCode
        and locale.countryCode == appLocale.countryCode then
      if not multiplePerfectMatch then
        bestMatch = locale
        break
      end
    end
    local score = 0
    if locale.scriptCode == appLocale.scriptCode then
      score = score + 1
      if locale.countryCode ~= nil and appLocale.countryCode ~= nil then
        score = score - 0.5
        if appLocale.scriptCode == nil then score = -1 end
      end
    elseif locale.countryCode == appLocale.countryCode then
      score = score + 1
    end
    if score > bestScore then
      bestScore = score
      bestMatch = locale
    elseif combineExtras and score == bestScore and bestMatch
        and locale.scriptCode == bestMatch.scriptCode
        and locale.countryCode == bestMatch.countryCode then
      if type(bestMatch.extra) == 'string' then
        bestMatch = tcopy(bestMatch)
        bestMatch.extra = { bestMatch.extra }
      end
      tinsert(bestMatch.extra, locale.extra)
    end
  end
  return bestMatch or {}
end

local function getDefaultMatchedLocale(appLocale, localeSource, dirExt)
  local localDetails = hs.host.locale.details(appLocale)
  local language = localDetails.languageCode
  local script = localDetails.scriptCode
  local country = localDetails.countryCode
  if script == nil then
    local localeItems = strsplit(appLocale, '-')
    if #localeItems == 3 or
        (#localeItems == 2 and localeItems[2]:upper() ~= country) then
      script = localeItems[2]
    end
  end
  if type(localeSource) == 'string' then
    local resourceDir = localeSource
    localeSource = {}
    for file in hs.fs.dir(resourceDir) do
      tinsert(localeSource, file)
    end
  end
  local matchedLocales = {}
  for _, loc in ipairs(localeSource) do
    if (dirExt and loc:sub(#loc - #dirExt) == "." .. dirExt)
        or dirExt == nil then
      local locale = dirExt and loc:sub(1, #loc - #dirExt - 1) or loc
      local newLocale = locale:gsub('_', '-')
      local thisLocale = hs.host.locale.details(newLocale)
      local thisLanguage = thisLocale.languageCode
      local thisScript = thisLocale.scriptCode
      local thisCountry = thisLocale.countryCode
      if thisScript == nil then
        local localeItems = strsplit(newLocale, '-')
        if #localeItems == 3 or
            (#localeItems == 2 and localeItems[2]:upper() ~= thisCountry) then
          thisScript = localeItems[2]
        end
      end
      if thisLanguage == 'zh' or thisLanguage == 'yue' then
        if thisCountry == 'HK' or thisCountry == 'MO'
            or thisCountry == 'TW' then
          if thisScript == nil then thisScript = 'Hant' end
        elseif thisCountry == 'CN' or thisCountry == 'SG' then
          if thisScript == nil then thisScript = 'Hans' end
        end
      end
      if thisLanguage == language
          and (script == nil or
               thisScript == nil or thisScript == script) then
        tinsert(matchedLocales, {
          scriptCode = thisScript,
          countryCode = thisCountry,
          extra = locale
        })
      end
    end
  end

  local bestMatch = getBestMatchedLocale(localDetails, matchedLocales)
  return bestMatch.extra
end

function matchLocale(locale, candicates)
  return getDefaultMatchedLocale(locale, candicates)
end

local function getQtMatchedLocale(appLocale, resourceDir)
  local localDetails = hs.host.locale.details(appLocale)
  local language = localDetails.languageCode
  local script = localDetails.scriptCode
  local country = localDetails.countryCode
  if script == nil then
    local localeItems = strsplit(appLocale, '-')
    if #localeItems == 3 or
        (#localeItems == 2 and localeItems[2]:upper() ~= country) then
      script = localeItems[2]
    end
  end
  local dirs = { resourceDir }
  for file in hs.fs.dir(resourceDir) do
    if isdir(resourceDir .. '/' .. file) then
      tinsert(dirs, resourceDir .. '/' .. file)
    end
  end
  local matchedLocales = {}
  for _, dir in ipairs(dirs) do
    for file in hs.fs.dir(dir) do
      if file:sub(-3) == '.qm' then
        local lowerFile = file:sub(1, -4):lower()
        local fileSplits = strsplit(lowerFile:gsub('_', '-'), '-')
        for i = #fileSplits, #fileSplits - 2, -1 do
          if fileSplits[i] == language then
            local thisCountry, thisScript
            if i + 2 == #fileSplits then
              thisCountry = fileSplits[i + 2]:upper()
              thisScript = fileSplits[i + 1]
            elseif i + 1 == #fileSplits then
              if fileSplits[i + 1]:upper() == country then
                thisCountry = country
              else
                thisScript = fileSplits[i + 1]
              end
            end
            local localeStartPos = 0
            for j = 1, i - 1 do
              localeStartPos = localeStartPos + #fileSplits[i - 1]
            end
            local locale = file:sub(localeStartPos, -4)
            if script == nil or thisScript == nil or thisScript == script then
              if language == 'zh' or language == 'yue' then
                if thisCountry == 'HK' or thisCountry == 'MO'
                    or thisCountry == 'TW' then
                  if thisScript == nil then thisScript = 'Hant' end
                elseif thisCountry == 'CN' or thisCountry == 'SG' then
                  if thisScript == nil then thisScript = 'Hans' end
                end
              end
              tinsert(matchedLocales, {
                scriptCode = thisScript,
                countryCode = thisCountry,
                extra = dir .. '/' .. file,
                locale = locale
              })
            end
          end
        end
      end
    end
  end

  if #matchedLocales == 0 then return end
  local bestMatch = getBestMatchedLocale(localDetails, matchedLocales, true, true)
  return bestMatch.locale, bestMatch.extra
end

local jimageLocales = {}
local function getJavaLocales(appid, javahome, path)
  if jimageLocales[appid] == nil then
    local tmpBaseDir = localeTmpDir .. appid
    local localesFile = tmpBaseDir .. '/locales.json'
    if exists(localesFile) then
      jimageLocales[appid] = hs.json.read(localesFile)
    else
      jimageLocales[appid] = {}
      local cmd = javahome .. '/bin/jimage'
      local modulePath = javahome .. '/lib/modules'
      local result, ok = hs.execute(strfmt([[
        %s list --include 'regex:.*%s/.*\.properties' '%s'
      ]], cmd, path, modulePath))
      if ok then
        local module
        for _, line in ipairs(strsplit(result, '\n')) do
          if line:sub(1, 8) == "Module: " then
            module = line:sub(9)
          elseif line == "" then
            module = nil
          elseif module then
            tinsert(jimageLocales[appid],
                module .. '/' .. line:sub(1, -12):gsub('%s', ''))
          end
        end
        mkdir(tmpBaseDir)
        hs.json.write(jimageLocales[appid], localesFile)
      else
        return
      end
    end
  end
  return jimageLocales[appid]
end

local function getJavaMatchedLocale(appid, appLocale, javahome, path)
  local localeFiles = getJavaLocales(appid, javahome, path)
  if localeFiles == nil then return end

  local localDetails = hs.host.locale.details(appLocale)
  local language = localDetails.languageCode
  local script = localDetails.scriptCode
  local country = localDetails.countryCode
  if script == nil then
    local localeItems = strsplit(appLocale, '-')
    if #localeItems == 3 or
        (#localeItems == 2 and localeItems[2]:upper() ~= country) then
      script = localeItems[2]
    end
  end
  local matchedLocales = {}
  for _, file in ipairs(localeFiles) do
    local pathSplits = strsplit(file, '/')
    local fileStem = pathSplits[#pathSplits]
    local fileSplits = strsplit(fileStem:gsub('-', '_'), '_')
    for i = #fileSplits, #fileSplits - 2, -1 do
      if fileSplits[i] == language then
        local thisCountry, thisScript
        if i + 1 <= #fileSplits then
          if fileSplits[i + 1]:upper() == fileSplits[i + 1] then
            thisCountry = fileSplits[i + 1]
            if i == #fileSplits - 2 then
              thisScript = fileSplits[i + 2]
            end
          else
            thisScript = fileSplits[i + 1]
          end
        end
        if script == nil or
            thisScript == nil or thisScript == script then
          if language == 'zh' or language == 'yue' then
            if thisCountry == 'HK' or thisCountry == 'MO'
                or thisCountry == 'TW' then
              if thisScript == nil then thisScript = 'Hant' end
            elseif thisCountry == 'CN' or thisCountry == 'SG' then
              if thisScript == nil then thisScript = 'Hans' end
            end
          end
          local locale = fileStem:match('_' .. language .. '$')
          if locale == nil then
            locale = fileStem:match('_' .. language .. '_.-$')
          end
          locale = locale:sub(2)
          tinsert(matchedLocales, {
            scriptCode = thisScript,
            countryCode = thisCountry,
            extra = locale
          })
        end
      end
    end
  end

  if #matchedLocales == 0 then return end
  local bestMatch = getBestMatchedLocale(localDetails, matchedLocales, true)
  local matchedLocale = bestMatch.extra
  local matchedFiles = tifilter(localeFiles, function(f)
    return f:sub(-#matchedLocale) == matchedLocale
  end)
  return matchedLocale, matchedFiles
end

local electronLocales = {}
local function getElectronLocales(appid, localesPath)
  if electronLocales[appid] == nil then
    local tmpBaseDir = localeTmpDir .. appid
    local localesFile = tmpBaseDir .. '/locales.json'
    if exists(localesFile) then
      electronLocales[appid] = hs.json.read(localesFile)
    else
      local path = hs.application.pathForBundleID(appid)
          .. '/Contents/Resources/app.asar'
      local result, ok = hs.execute(strfmt([[
        npx @electron/asar list "%s" | grep "^/%s/" | cut -c%d-
      ]], path, localesPath, #localesPath + 3), true)
      if ok then
        result = strsplit(result, '\n')
        result[#result] = nil
        local locales, localeFiles = {}, {}
        for _, p in ipairs(result) do
          if p:find('/') then
            if p:sub(-5) == '.json' then
              tinsert(localeFiles, p:sub(1, -6))
            end
          else
            tinsert(locales, p)
          end
        end
        electronLocales[appid] = { locale = locales, file = localeFiles }
        mkdir(tmpBaseDir)
        hs.json.write(electronLocales[appid], localesFile)
      else
        return
      end
    end
  end
  return electronLocales[appid]
end

local function getElectronMatchedLocale(appid, appLocale, localesPath)
  local localeInfo = getElectronLocales(appid, localesPath)
  if localeInfo == nil then return end
  local locales = localeInfo['locale']
  local localeFiles = localeInfo['file']
  local locale = matchLocale(appLocale, locales)
  if locale == nil then return end

  local matchedFiles = {}
  for _, file in ipairs(localeFiles) do
    if file:sub(1, #locale + 1) == locale .. '/' then
      tinsert(matchedFiles, file:sub(#locale + 2))
    end
  end
  return locale, matchedFiles
end

local function getMatchedLocale(appid, appLocale, resourceDir, framework, buffer)
  local locale, localeDir, dirExt

  if framework.electron then
    locale, localeDir = getElectronMatchedLocale(
        appid, appLocale, framework.electron)
    if locale == nil then return end
  elseif framework.java then
    locale, localeDir = getJavaMatchedLocale(
        appid, appLocale, resourceDir, framework.java)
    if locale == nil then return end
  end
  if not tindex(framework, true) or framework.user
      or framework.chromium or framework.qt then
    dirExt = 'lproj'
  end
  if locale == nil then
    locale = get(buffer, appid, appLocale)
    if locale == false then return end
    if locale ~= nil and localeDir == nil then
      localeDir = resourceDir .. "/" .. locale
      if dirExt then
        localeDir = localeDir .. "." .. dirExt
      end
      if not exists(localeDir) then
        locale = nil
        localeDir = nil
      end
    end
  end
  if locale == nil then
    locale = getDefaultMatchedLocale(appLocale, resourceDir, dirExt)
    if locale == nil and framework.qt then
      locale, localeDir = getQtMatchedLocale(appLocale, resourceDir)
    end
    if locale == nil then
      local fw = tindex(framework, true)
      if fw then
        resourceDir = hs.application.pathForBundleID(appid) .. "/Contents/Resources"
        if not exists(resourceDir) then return end
        dirExt = 'lproj'
        locale = getDefaultMatchedLocale(appLocale, resourceDir, dirExt)
        if locale then
          framework[fw] = nil
        end
      end
    end
    if locale == nil then return end
  end
  if localeDir == nil then
    localeDir = resourceDir .. "/" .. locale
    if dirExt then
      localeDir = localeDir .. "." .. dirExt
    end
  end
  if framework.qt and type(localeDir) == 'string'
      and not exists(localeDir) then
    _, localeDir = getQtMatchedLocale(appLocale, resourceDir)
  end

  return locale, localeDir, resourceDir, framework
end

-- assume base locale is English (not always the situation)
local baseLocales = {
  "Base", "en", "English"
}
local function getBaseLocaleDirs(resourceDir)
  local dirs = {}
  for _, locale in ipairs(baseLocales) do
    local localeDir = resourceDir .. '/' .. locale
    if exists(localeDir) then
      tinsert(dirs, localeDir)
    else
      localeDir = localeDir .. '.lproj'
      if exists(localeDir) then
        tinsert(dirs, localeDir)
      end
    end
  end
  if #dirs == 0 then tinsert(dirs, resourceDir) end
  return dirs
end

-- basically should only be called when base locale is English,
-- but actually it can't be guranteed
local extraEnglishLocales = {
  "en_US", "en_GB"
}
local function appendExtraEnglishLocaleDirs(resourceDir, baseDirs)
  local dirs = tcopy(baseDirs)
  for _, locale in ipairs(extraEnglishLocales) do
    local localeDir = resourceDir .. '/' .. locale
    if exists(localeDir) then
      tinsert(dirs, localeDir)
    else
      localeDir = localeDir .. '.lproj'
      if exists(localeDir) then
        tinsert(dirs, localeDir)
      end
    end
  end
  return dirs
end

local function collectLocaleFiles(localeDir, option)
  local localeFiles = {}
  if option == nil then
    option = { strings = true, nib = true, storyboardc = true }
  end
  for file in hs.fs.dir(localeDir or {}) do
    if option.strings and file:sub(-8) == ".strings" then
      tinsert(localeFiles, file:sub(1, -9))
    elseif option.strings and file:sub(-10) == ".strings.1" then
      tinsert(localeFiles, file:sub(1, -11))
    elseif option.loctable and file:sub(-9) == ".loctable" then
      tinsert(localeFiles, file:sub(1, -10))
    elseif option.nib and file:sub(-4) == ".nib" then
      tinsert(localeFiles, file:sub(1, -5))
    elseif option.storyboardc and file:sub(-12) == ".storyboardc" then
      tinsert(localeFiles, file:sub(1, -13))
    end
  end
  return localeFiles
end

local preferentialLocaleFilePatterns = {
  "(.-)MainMenu(.-)", "Menu", "MenuBar", "MenuItems",
  "Localizable", "(.-)Localizable", "Main", "MainWindow",
}

local function filterPreferentialLocaleFiles(localeFiles)
  local newStringsFiles, preferentialStringsFiles = {}, {}
  for _, p in ipairs(preferentialLocaleFilePatterns) do
    for _, file in ipairs(localeFiles) do
      if not tcontain(preferentialStringsFiles, file)
          and file:match('^' .. p .. '$') then
        tinsert(preferentialStringsFiles, file)
      end
    end
  end
  for _, file in ipairs(localeFiles) do
    if not tcontain(preferentialStringsFiles, file) then
      tinsert(newStringsFiles, file)
    end
  end
  return newStringsFiles, preferentialStringsFiles
end

local function parseStringsFile(file, keepOrder, keepAll)
  if keepOrder == nil then keepOrder = true end
  local jsonDict = hs.plist.read(file) or {}
  if keepOrder then return jsonDict end
  local localesDict = {}
  for k, v in pairs(jsonDict) do
    if localesDict[v] == nil then
      localesDict[v] = k
    elseif keepAll then
      if type(localesDict[v]) == 'string' then
        localesDict[v] = { localesDict[v], k }
      else
        tinsert(localesDict[v], k)
      end
    end
  end
  return localesDict
end

local function isBinarayPlist(file)
  local f = io.open(file, "rb")
  if f == nil then return false end
  local firstByte = f:read(1)
  f:close()
  return firstByte == "b"
end

local function parseBinaryPlistFile(file, keepOrder, keepAll)
  if keepOrder == nil then keepOrder = true end
  -- do not use "hs.plist.read" for performance reasons
  local jsonStr = hs.execute([[
    plutil -convert xml1 ']]..file..[[' -o /dev/stdout | \
    awk '
    BEGIN { printf("{"); first = 1 }
    /<string>.*\.(title|label)<\/string>/ {
      key = $0;
      sub("<string>", "", key);
      sub("</string>", "", key);
      gsub(/^[ \t]+/, "", key);
      gsub("%", "%%", key);
      gsub("\"", "\\\"", key);

      getline
      value = $0;
      if (value ~ /<string>.*<\/string>/) {
        sub("<string>", "", value);
        sub("</string>", "", value);
        gsub(/^[ \t]+/, "", value);
        gsub("%", "%%", value);
        gsub("\"", "\\\"", value);
        if (!first) printf(", ");
        printf "\"%s\": \"%s\"", key, value;
        first = 0;
      }
    }
    END { print "}" }']])
  local jsonDict = hs.json.decode(jsonStr)
  if keepOrder then return jsonDict end
  local localesDict = {}
  for k, v in pairs(jsonDict) do
    if localesDict[v] == nil then
      localesDict[v] = k
    elseif keepAll then
      if type(localesDict[v]) == 'string' then
        localesDict[v] = { localesDict[v], k }
      else
        tinsert(localesDict[v], k)
      end
    end
  end
  return localesDict
end

local function parseNIBArchive(file, keepOrder, keepAll)
  if keepOrder == nil then keepOrder = true end
  local jsonStr = hs.execute([[
    /usr/bin/python3 scripts/nib_parse.py \
        dump-json ']]..file..[[' -o /dev/stdout | \
    grep '"data": "' | sed 's/^.*"data": "//;s/"$//' | \
    awk 'BEGIN { printf("{"); first = 1 } /\.(title|label)$/ {
      key = $0;
      gsub("%", "%%", prev);
      if (!first) printf(", ");
      printf("\"" key "\": \"" prev "\"");
      first = 0;
    }
    { prev = $0 }
    END { print "}" }'
  ]])
  local jsonDict = hs.json.decode(jsonStr)
  if keepOrder then return jsonDict end
  local localesDict = {}
  for k, v in pairs(jsonDict) do
    if localesDict[v] == nil then
      localesDict[v] = k
    elseif keepAll then
      if type(localesDict[v]) == 'string' then
        localesDict[v] = { localesDict[v], k }
      else
        tinsert(localesDict[v], k)
      end
    end
  end
  return localesDict
end

local function parseNIBFile(file, keepOrder, keepAll)
  if isBinarayPlist(file) then
    return parseBinaryPlistFile(file, keepOrder, keepAll)
  else
    return parseNIBArchive(file, keepOrder, keepAll)
  end
end

local function localizeByLoctableImpl(str, filePath, locale, localesDict, baseNibFile)
  if localesDict[locale] == nil then
    local loctables = hs.plist.read(filePath)
    localesDict[locale] = loctables[locale]
    if localesDict[locale] == nil then return end
    if baseNibFile == nil then
      local enLocales = tconcat({ 'en', 'English', 'Base' }, extraEnglishLocales)
      for _, en in ipairs(enLocales) do
        localesDict[en] = loctables[en]
      end
    else
      localesDict['Base'] = parseNIBFile(baseNibFile)
    end
  end

  local result = localesDict[locale][str]
  if result ~= nil then return result end
  if locale == 'en' then
    local enLocales = tconcat({ 'English', 'Base' }, extraEnglishLocales)
    for _, en in ipairs(enLocales) do
      result = get(localesDict, en, str)
      if result ~= nil then return result end
    end
  end

  local enLocales = tconcat({ 'en', 'English', 'Base' }, extraEnglishLocales)
  for _, en in ipairs(enLocales) do
    if localesDict[en] ~= nil then
      local key = tindex(localesDict[en], str)
      if key ~= nil then
        return localesDict[locale][key]
      end
    end
  end
end

local function localizeByLoctable(str, resourceDir, localeFile, locale, localesDict)
  local loctableFiles = {}
  if localeFile ~= nil then
    if type(localeFile) == 'string' then
      localeFile = { localeFile }
    end
    for file in hs.fs.dir(resourceDir) do
      if file:sub(-9) == '.loctable' then
        for _, p in ipairs(localeFile) do
          if file:sub(1, -10):match('^' .. p .. '$') then
            tinsert(loctableFiles, file:sub(1, -10))
          end
        end
      end
    end
  else
    loctableFiles = collectLocaleFiles(resourceDir, { loctable = true })
    local preferentialLoctableFiles = {}
    if #loctableFiles > 10 then
      loctableFiles, preferentialLoctableFiles =
          filterPreferentialLocaleFiles(loctableFiles)
    end
    tconcat(preferentialLoctableFiles, loctableFiles)
    loctableFiles = preferentialLoctableFiles
  end
  if localesDict == nil then
    localesDict = {}
  end
  for _, file in ipairs(loctableFiles) do
    local fullPath = resourceDir .. '/' .. file .. '.loctable'
    if localesDict[file] == nil then
      localesDict[file] = {}
    end
    local baseNibFile
    for _, en in ipairs{'Base', 'en', 'English'} do
      local nibFile = resourceDir .. strfmt('/%s.lproj/%s.nib', en, file)
      if exists(nibFile) then
        baseNibFile = nibFile break
      end
    end
    local result = localizeByLoctableImpl(str, fullPath, locale, localesDict[file], baseNibFile)
    if result ~= nil then return result end
  end
end

-- situation 1: "str" is a key in a strings file of target locale
-- situation 2: both base and target locales use strings files
-- situation 3: both base variant (e.g. en_US) and target locales use strings files
-- situation 4: both base and target locales use "*.title"-style or "*.label"-style keys,
--              base locale uses NIB file (either NIB archive or binary plist)
--              & target locale uses strings files
local function localizeByStrings(str, localeDir, localeFile, localesDict, localesInvDict)
  local resourceDir = localeDir .. '/..'
  local searchFunc = function(str, files)
    if type(files) == 'string' then files = { files } end
    for _, fileStem in ipairs(files) do
      local jsonDict = localesDict[fileStem]
      if jsonDict == nil then
        if exists(localeDir .. '/' .. fileStem .. '.strings') then
          jsonDict = parseStringsFile(localeDir .. '/' .. fileStem .. '.strings')
        elseif exists(localeDir .. '/' .. fileStem .. '.strings.1') then
          jsonDict = parseStringsFile(localeDir .. '/' .. fileStem .. '.strings.1')
        end
      end
      if jsonDict ~= nil and jsonDict[str] ~= nil then
        localesDict[fileStem] = jsonDict
        return jsonDict[str]
      end
    end
  end

  local stringsFiles, preferentialStringsFiles = {}, {}
  if localeFile ~= nil then
    if type(localeFile) == 'string' then
      localeFile = { localeFile }
    end
    for file in hs.fs.dir(localeDir) do
      if file:sub(-8) == '.strings' then
        for _, p in ipairs(localeFile) do
          if file:sub(1, -9):match('^' .. p .. '$') then
            tinsert(preferentialStringsFiles, file:sub(1, -9))
          end
        end
      elseif file:sub(-10) == '.strings.1' then
        for _, p in ipairs(localeFile) do
          if file:sub(1, -11):match('^' .. p .. '$') then
            tinsert(preferentialStringsFiles, file:sub(1, -11))
          end
        end
      end
    end
  else
    stringsFiles = collectLocaleFiles(localeDir, { strings = true })
    if #stringsFiles > 10 then
      stringsFiles, preferentialStringsFiles =
          filterPreferentialLocaleFiles(stringsFiles)
    end
  end
  local result = searchFunc(str, preferentialStringsFiles)
  if result ~= nil then return result end

  local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
  local invSearchFunc = function(str, files)
    local dirs = appendExtraEnglishLocaleDirs(resourceDir, baseLocaleDirs)
    for _, baseLocaleDir in ipairs(dirs) do
      for _, fileStem in ipairs(files) do
        local invDict = localesInvDict[fileStem]
        if invDict == nil then
          if exists(baseLocaleDir .. '/' .. fileStem .. '.strings') then
            invDict = parseStringsFile(baseLocaleDir .. '/' .. fileStem .. '.strings',
                                       false, true)
          elseif exists(baseLocaleDir .. '/' .. fileStem .. '.strings.1') then
            invDict = parseStringsFile(baseLocaleDir .. '/' .. fileStem .. '.strings.1',
                                       false, true)
          elseif exists(baseLocaleDir .. '/' .. fileStem .. '.nib') then
            local fullPath = baseLocaleDir .. '/' .. fileStem .. '.nib'
            if isdir(fullPath) then
              if exists(fullPath .. '/keyedobjects.nib') then
                fullPath = fullPath .. '/keyedobjects.nib'
              else
                fullPath = hs.execute(strfmt([[
                  ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n'
                ]], fullPath))
                if fullPath == "" then return end
              end
            end
            invDict = parseNIBFile(fullPath, false, true)
            if not exists(localeDir .. '/' .. fileStem .. '.strings') then
              if invDict and invDict[str] then return str end
            end
          end
        end
        local searchFromDict = function(dict)
          if dict ~= nil and dict[str] ~= nil then
            local keys = dict[str]
            if type(keys) == 'string' then
              keys = { keys }
            end
            for _, key in ipairs(keys) do
              local result = searchFunc(key, fileStem)
              if result ~= nil then
                localesInvDict[fileStem] = dict
                return result
              end
            end
          end
        end
        local result = searchFromDict(invDict)
        if result ~= nil then return result end
        if exists(baseLocaleDir .. '/' .. fileStem .. '.storyboardc')
            and exists(localeDir .. '/' .. fileStem .. '.strings') then
          local fullPath = baseLocaleDir .. '/' .. fileStem .. '.storyboardc'
          for subFile in hs.fs.dir(fullPath) do
            if subFile:sub(-4) == '.nib' then
              invDict = parseNIBFile(fullPath .. '/' .. subFile, false, true)
              local result = searchFromDict(invDict)
              if result ~= nil then return result end
            end
          end
        end
      end
    end
  end

  local baseStringsFiles = {}
  if localeFile ~= nil then
    local result = invSearchFunc(str, preferentialStringsFiles)
    if result ~= nil then return result end
  else
    baseStringsFiles = collectLocaleFiles(baseLocaleDirs[1])
    for i=2, #baseLocaleDirs do
      if exists(baseLocaleDirs[i] .. '/Localizable.strings')
          or exists(baseLocaleDirs[i] .. '/Localizable.strings.1') then
        tinsert(baseStringsFiles, 'Localizable')
      end
    end
    local basePreferentialStringsFiles = {}
    if #baseStringsFiles > 10 then
      baseStringsFiles, basePreferentialStringsFiles =
          filterPreferentialLocaleFiles(baseStringsFiles)
    end
    local result = invSearchFunc(str, basePreferentialStringsFiles)
    if result ~= nil then return result end
  end

  local result = searchFunc(str, stringsFiles)
  if result ~= nil then return result end

  result = invSearchFunc(str, baseStringsFiles)
  if result ~= nil then return result end
end

local function localizeByNIB(str, localeDir, localeFile, appid)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  local baseLocaleDir = getBaseLocaleDirs(resourceDir)[1]
  local baseLocale = baseLocaleDir:match("^.*/(.*)%.lproj$")
  local compareNIBs = function(file)
    local NIBPath = localeDir .. '/' .. file .. '.nib'
    local baseNIBPath = baseLocaleDir .. '/' .. file .. '.nib'
    if not exists(NIBPath) or not exists(baseNIBPath) then return end
    if isdir(baseNIBPath) then
      if exists(baseNIBPath .. '/keyedobjects.nib') then
        baseNIBPath = baseNIBPath .. '/keyedobjects.nib'
      else
        baseNIBPath = hs.execute(strfmt([[
          ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n'
        ]], baseNIBPath))
        if baseNIBPath == "" then return end
      end
    end
    if isdir(NIBPath) then
      if exists(NIBPath .. '/keyedobjects.nib') then
        NIBPath = NIBPath .. '/keyedobjects.nib'
      else
        NIBPath = hs.execute(strfmt([[
          ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n'
        ]], NIBPath))
        if NIBPath == "" then return end
      end
    end

    local tmpBaseDir = localeTmpDir .. appid
    mkdir(tmpBaseDir)

    if isBinarayPlist(NIBPath) and isBinarayPlist(baseNIBPath) then
      -- do not use "hs.plist.read" for performance reasons
      local xmlDir = tmpBaseDir .. '/' .. locale
      local xmlPath = xmlDir .. '/' .. file .. '.xml'
      if not exists(xmlPath) then
        mkdir(xmlDir)
        local _, status = hs.execute(strfmt(
            "plutil -convert xml1 '%s' -o '%s'", NIBPath, xmlPath))
        if not status then return end
      end
      local baseXmlDir = tmpBaseDir .. '/' .. baseLocale
      local baseXmlPath = baseXmlDir .. '/' .. file .. '.xml'
      if not exists(baseXmlPath) then
        mkdir(baseXmlDir)
        local _, status = hs.execute(strfmt(
            "plutil -convert xml1 '%s' -o '%s'", baseNIBPath, baseXmlPath))
        if not status then return end
      end
      local diffDir = tmpBaseDir .. '/' .. baseLocale .. '-' .. locale
      local diffPath = diffDir .. '/' .. file .. '.diff'
      if not exists(diffPath) then
        mkdir(diffDir)
        hs.execute(strfmt("diff --suppress-common-lines '%s' '%s' > '%s'",
                          baseXmlPath, xmlPath, diffPath))
      end
      local result = hs.execute(strfmt([[
          cat '%s' | awk '/^<.*<string>%s<\/string>/ && !found {
            curline=$0; getline;
            if ($0 == curline) {getline}
            if ($0 ~ "---") {getline; print $0; found=1}
          }' | \
          sed 's/^>.*<string>//;s/<\/string>$//' | tr -d '\n']],
          diffPath, str))
      return result ~= "" and result or nil
    end

    local baseJsonDir = tmpBaseDir .. '/' .. baseLocale
    local baseJsonPath = baseJsonDir .. '/' .. file .. '.json'
    if not exists(baseJsonPath) then
      mkdir(baseJsonDir)
      local _, status = hs.execute(strfmt([[
        /usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'
      ]], baseNIBPath, baseJsonPath))
      if not status then return end
    end
    local jsonDir = tmpBaseDir .. '/' .. locale
    local jsonPath = jsonDir .. '/' .. file .. '.json'
    if not exists(jsonPath) then
      mkdir(jsonDir)
      local _, status = hs.execute(strfmt([[
        /usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'
      ]], NIBPath, jsonPath))
      if not status then return end
    end
    local diffDir = tmpBaseDir .. '/' .. baseLocale .. '-' .. locale
    local diffPath = diffDir .. '/' .. file .. '.diff'
    if not exists(diffPath) then
      mkdir(diffDir)
      hs.execute(strfmt("diff --suppress-common-lines '%s' '%s' > '%s'",
                        baseJsonPath, jsonPath, diffPath))
    end
    local result = hs.execute(strfmt([[
      cat '%s' | awk '/^<.*"data": "%s"/ && !found {
        getline;
        if ($0 ~ "---") {getline; print $0; found=1}
      }' | \
      sed 's/^>.*"data": "//;s/"$//' | tr -d '\n'
    ]], diffPath, str))
    return result ~= "" and result or nil
  end

  local nibFiles = {}
  if localeFile ~= nil then
    if type(localeFile) == 'string' then
      localeFile = { localeFile }
    end
    for file in hs.fs.dir(localeDir) do
      if file:sub(-4) == '.nib' then
        for _, p in ipairs(localeFile) do
          if file:sub(1, -5):match('^' .. p .. '$') then
            tinsert(nibFiles, file:sub(1, -5))
          end
        end
      end
    end
  else
    nibFiles = collectLocaleFiles(localeDir, { nib = true })
    if #nibFiles > 10 then
      _, nibFiles = filterPreferentialLocaleFiles(nibFiles)
    end
  end
  for _, file in ipairs(nibFiles) do
    local result = compareNIBs(file)
    if result ~= nil then return result end
  end
end

local function poIdToStr(str)
  return strfmt([[
    awk "
      /msgid \"%s\"/ {
        getline;
        sub(/^msgstr \"/, \"\");
        sub(/\"\$/, \"\");
        print \$0;
        exit
      }
    " | tr -d "\n"
  ]], str)
end

local function poStrToId(str)
  return strfmt([[
    awk "
      /msgstr \"%s\"/ {
        sub(/^msgid \"/, \"\", prevline);
        sub(/\"\$/, \"\", prevline);
        print prevline;
        exit
      }
      { prevline = \$0 }
    " | tr -d "\n"
  ]], str)
end

local function poCtxtToStr(str)
  return strfmt([[
    awk "
      /msgctxt \"%s\"/ {
        getline;
        getline;
        sub(/^msgstr \"/, \"\");
        sub(/\"\$/, \"\");
        print \$0;
        exit
      }
    " | tr -d "\n"
  ]], str:gsub('|', '\\|'))
end

local function poStrToCtxt(str)
  return strfmt([[
    awk "
      /msgstr \"%s\"/ {
        sub(/^msgctxt \"/, \"\", prev2);
        sub(/\"\$/, \"\", prev2);
        print prev2;
        exit
      }
      {
        prev2 = prev1;
        prev1 = \$0;
      }
    " | tr -d "\n"
  ]], str)
end

local function localizeByQtImpl(str, file)
  local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
  if cmd == nil then return end
  local output, status = hs.execute(strfmt(
    '%s -i "%s" -of po | %s', cmd, file, poIdToStr(str)))
  if status and output ~= "" then return output end
end

local function localizeByQt(str, localeDir)
  if type(localeDir) == 'table' then
    for _, file in ipairs(localeDir) do
      local result = localizeByQtImpl(str, file)
      if result ~= nil then return result end
    end
  elseif isfile(localeDir) then
    return localizeByQtImpl(str, localeDir)
  else
    for file in hs.fs.dir(localeDir) do
      if file:sub(-3) == ".qm" then
        local result = localizeByQtImpl(str, localeDir .. '/' .. file)
        if result ~= nil then return result end
      end
    end
  end
end

local function localizeByFTL(str, localeDir, baseLocale)
  local resourceDir = localeDir .. '/..'
  if baseLocale == nil then
    baseLocale = getDefaultMatchedLocale('en', resourceDir)
        or getDefaultMatchedLocale('English', resourceDir)
    if baseLocale == nil then return end
  end
  local baseLocaleDir = resourceDir .. '/' .. baseLocale

  local lines = hs.execute(strfmt([[
    find '%s' -type f -path '*.ftl' \
    | xargs -I{} grep -E '([^=]*?) = %s$' -H {}
  ]], baseLocaleDir, str))
  lines = strsplit(lines, '\n')
  lines[#lines] = nil
  if #lines == 0 then return end
  local firstColon = lines[1]:find(':')
  local filepath = lines[1]:sub(1, firstColon - 1)
  local pair = lines[1]:sub(firstColon + 1)
  local firstEqual = pair:find(' = ')
  local key = pair:sub(1, firstEqual - 1)
  local pathItems = strsplit(localeDir, '/')
  local locale = pathItems[#pathItems]
  baseLocale = baseLocale:gsub('%-', '%%-')
  local localeFile = filepath:gsub('/'..baseLocale..'/', '/'..locale..'/')
  if exists(localeFile) then
    local result, status = hs.execute(strfmt([[
      grep -E '^%s = (.*?)$' '%s'
    ]], key, localeFile))
    if status and result ~= "\n" then
      local line = strsplit(result, '\n')[1]
      local firstEqual = pair:find(' = ')
      return line:sub(firstEqual + 3)
    end
  end
end

local function localizeByProperties(str, localeDir, baseLocale)
  local resourceDir = localeDir .. '/..'
  if baseLocale == nil then
    baseLocale = getDefaultMatchedLocale('en', resourceDir)
        or getDefaultMatchedLocale('English', resourceDir)
    if baseLocale == nil then return end
  end
  local baseLocaleDir = resourceDir .. '/' .. baseLocale

  local lines = hs.execute(strfmt([[
    find '%s' -type f -path '*.properties' \
    | xargs -I{} grep -E '([^=\s]*?)(\s*?)=(\s*?)%s$' -H {}
  ]], baseLocaleDir, str))
  lines = strsplit(lines, '\n')
  lines[#lines] = nil
  if #lines == 0 then return end
  local firstColon = lines[1]:find(':')
  local filepath = lines[1]:sub(1, firstColon - 1)
  local pair = lines[1]:sub(firstColon + 1)
  local equalStart = pair:find('%s-=%s-')
  local key = pair:sub(1, equalStart - 1)
  local pathItems = strsplit(localeDir, '/')
  local locale = pathItems[#pathItems]
  baseLocale = baseLocale:gsub('%-', '%%-')
  local localeFile = filepath:gsub('/'..baseLocale..'/', '/'..locale..'/')
  if exists(localeFile) then
    local result, status = hs.execute(strfmt([[
      grep -E '^%s(\s*?)=(\s*?)([^\s]*?)$' '%s'
    ]], key, localeFile))
    if status and result ~= "\n" then
      local line = strsplit(result, '\n')[1]
      local _, equalEnd = line:find('%s-=%s-')
      return line:sub(equalEnd + 1)
    end
  end
end

local function localizeByDTD(str, localeDir, baseLocale)
  local resourceDir = localeDir .. '/..'
  if baseLocale == nil then
    baseLocale = getDefaultMatchedLocale('en', resourceDir)
        or getDefaultMatchedLocale('English', resourceDir)
    if baseLocale == nil then return end
  end
  local baseLocaleDir = resourceDir .. '/' .. baseLocale

  local lines = hs.execute(strfmt([[
    find '%s' -type f -path '*.dtd' \
    | xargs -I{} grep -E '^<!ENTITY.*"%s">' -H {}
  ]], baseLocaleDir, str))
  lines = strsplit(lines, '\n')
  lines[#lines] = nil
  if #lines == 0 then return end
  local firstColon = lines[1]:find(':')
  local filepath = lines[1]:sub(1, firstColon - 1)
  local pair = lines[1]:sub(firstColon + 1)
  local firstQuote = pair:find(' "')
  local key = pair:sub(10, firstQuote - 1)
  local pathItems = strsplit(localeDir, '/')
  local locale = pathItems[#pathItems]
  baseLocale = baseLocale:gsub('%-', '%%-')
  local localeFile = filepath:gsub('/'..baseLocale..'/', '/'..locale..'/')
  if exists(localeFile) then
    local result, status = hs.execute(strfmt([[
      grep -E '^<!ENTITY %s(\s*?)"(.*?)">' '%s'
    ]], key, localeFile))
    if status and result ~= "\n" then
      local line = strsplit(result, '\n')[1]
      return line:sub(9 + #key + 1):match('"(.-)"')
    end
  end
end

local function localizeByMono(str, localeDir)
  local cmd = hs.execute("which msgunfmt | tr -d '\\n'", true)
  if cmd == nil then return end
  for file in hs.fs.dir(localeDir .. '/LC_MESSAGES') do
    if file:sub(-3) == ".mo" then
      local output, status = hs.execute(strfmt(
        '%s "%s" -o - | %s',
        cmd, localeDir .. '/LC_MESSAGES/' .. file, poIdToStr(str)))
      if status and output ~= "" then return output end
    end
  end
end

local function localizeByChromium(str, localeDir, appid)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  for _, enLocale in ipairs{"en", "English", "Base", "en_US", "en_GB"} do
    if exists(resourceDir .. '/' .. enLocale .. '.lproj') then
      for file in hs.fs.dir(resourceDir .. '/' .. enLocale .. '.lproj') do
        if file:sub(-4) == ".pak" and exists(localeDir .. '/' .. file) then
          local fullPath = resourceDir .. '/' .. enLocale .. '.lproj/' .. file
          local fileStem = file:sub(1, -5)
          local baseDir = localeTmpDir .. appid
          mkdir(baseDir)
          local enTmpBaseDir = baseDir .. '/' .. enLocale
          local enTmpdir = enTmpBaseDir .. '/' .. fileStem
          if dirNotExistOrEmpty(enTmpdir) then
            mkdir(enTmpBaseDir)
            hs.execute(strfmt("scripts/pak -u '%s' '%s'",
                              fullPath, enTmpdir))
          end
          local output, status = hs.execute(strfmt([[
            grep -lrE '^%s$' '%s' | tr -d '\n'
          ]], str, enTmpdir))
          if status and output ~= "" then
            local matchFile = output:match("^.*/(.*)$")
            local tmpBaseDir = baseDir .. '/' .. locale
            local tmpdir = tmpBaseDir .. '/' .. fileStem
            if dirNotExistOrEmpty(tmpdir) then
              mkdir(tmpBaseDir)
              hs.execute(strfmt("scripts/pak -u '%s' '%s'",
                                localeDir .. '/' .. file, tmpdir))
            end
            local matchFullPath = tmpdir .. '/' .. matchFile
            if exists(matchFullPath) then
              local f = io.open(matchFullPath, "r")
              if f ~= nil then
                local content = f:read("*a")
                f:close()
                return content
              end
            end
          end
        end
      end
    end
  end
  return nil
end

local function localizeByElectron(str, appid, locale, localeFiles, localesPath)
  local baseDir = localeTmpDir .. appid
  local tmpdir = baseDir .. '/' .. locale
  if #localeFiles > 0 then
    for _, file in ipairs(localeFiles) do
      local tmpfile = tmpdir .. '/' .. file .. '.json'
      if not exists(tmpfile) then
        local path = hs.application.pathForBundleID(appid)
            .. '/Contents/Resources/app.asar'
        local localeFilePath = strfmt("%s/%s/%s.json",
            localesPath, locale, file)
        hs.execute(strfmt([[
          npx @electron/asar extract-file "%s" "%s"
        ]], path, localeFilePath), true)
        mkdir(baseDir)
        mkdir(tmpdir)
        hs.execute(strfmt("mv '%s' '%s'", file .. '.json', tmpdir))
      end
    end
  end
  for file in hs.fs.dir(tmpdir) do
    if file:sub(-5) == '.json' then
      local json = hs.json.read(tmpdir .. '/' .. file)
      if json[str] ~= nil then
        return json[str], locale
      end
    end
  end
  return nil, locale
end

local function localizeByJava(str, appid, localeFiles, javehome)
  for _, file in ipairs(localeFiles) do
    local tmpBaseDir = localeTmpDir .. appid
    local fullpath = tmpBaseDir .. '/' .. file .. ".properties"
    if not exists(fullpath) then
      local cmd = javehome .. '/bin/jimage'
      local modulePath = javehome .. '/lib/modules'
      hs.execute(cmd .. " extract"
          .. " --include regex:.*" .. file .. "\\.properties"
          .. " --dir " .. tmpBaseDir .. " " .. modulePath)
    end
    if exists(fullpath) then
      str = str:gsub(':', '\\:'):gsub(' ', '\\ ')
      local result, ok = hs.execute(strfmt(
          "cat '%s' | grep '^%s='", fullpath, str:gsub('\\','\\\\')))
      if ok then
        result = strsplit(result, '\n')
        return result[1]:sub(#str + 2)
      end
    end
  end
end

local function localizeQt(str, appid, appLocale)
  local appPath = hs.application.pathForBundleID(appid)
  local resourceDir = appPath .. "/../../share/qt/translations"
  if not exists(resourceDir) then
    resourceDir = appPath .. "/../Qt/translations"
  end
  if not exists(resourceDir) then return end
  local appname = appPath:match("^.*/([^/]+)%.app$")
  if appname == nil
      or not exists(resourceDir .. "/" .. appname:lower() .. "_en.qm")  then
    return
  end
  local locales = {}
  local prefix = appname:lower() .. '_'
  for file in hs.fs.dir(resourceDir) do
    if file:sub(-3) == ".qm" and file:sub(1, #prefix) == prefix then
      tinsert(locales, file:sub(#prefix + 1, -4))
    end
  end
  local locale = matchLocale(appLocale, locales)
  if locale == nil then return nil end
  if locale == 'en' then return str:gsub('[^%s]-&(%a)', '%1'), locale end
  local result = localizeByQtImpl(
      str, resourceDir .. '/' .. prefix .. locale .. '.qm')
  if result ~= nil then
    result = result:gsub("%(&%a%)", ""):gsub('[^%s]-&(%a)', '%1')
  end
  return result, locale
end

local function getSTRInQtKso(str, file)
  local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
  if cmd == nil then return end
  local output, status = hs.execute(strfmt(
    '%s -i "%s" -of po | %s', cmd, file, poCtxtToStr(str)))
  if status and output ~= "" then return output end
end

local function getCTXTInQtKso(str, file)
  local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
  if cmd == nil then return end
  local output, status = hs.execute(strfmt(
    '%s -i "%s" -of po | %s', cmd, file, poStrToCtxt(str)))
  if status and output ~= "" then return output end
end

local function localizeWPS(str, appLocale, localeFile)
  local resourceDir =
      hs.application.pathForBundleID("com.kingsoft.wpsoffice.mac")
      .. '/Contents/Resources/office6/mui'
  local locale = getDefaultMatchedLocale(appLocale, resourceDir)
  if type(localeFile) == 'string' then
    localeFile = { localeFile }
  end
  local localeDir = resourceDir .. '/' .. locale

  for file in hs.fs.dir(localeDir) do
    if file:sub(-3) == ".qm" then
      local valid = true
      if localeFile then
        valid = any(localeFile, function(p)
          return file:sub(1, -4):match('^' .. p .. '$')
        end)
      end
      if valid then
        local result = getSTRInQtKso(str, localeDir .. '/' .. file)
        if result ~= nil then return result end
      end
    end
  end
  if result ~= nil then return result, locale end

  local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
  local dirs = appendExtraEnglishLocaleDirs(resourceDir, baseLocaleDirs)
  local ctxt, matchedFile
  for _, dir in ipairs(dirs) do
    for file in hs.fs.dir(dir) do
      if file:sub(-3) == ".qm" then
        local valid = true
        if localeFile then
          valid = any(localeFile, function(p)
            return file:sub(1, -4):match('^' .. p .. '$')
          end)
        end
        if valid then
          ctxt = getCTXTInQtKso(str, dir .. '/' .. file)
          if ctxt ~= nil then
            matchedFile = file:sub(1, -4)
            goto END_OUTER_FOR_LOOP
          end
        end
      end
    end
  end
  ::END_OUTER_FOR_LOOP::
  if ctxt == nil then return nil, locale end

  if exists(localeDir .. '/' .. matchedFile .. '.qm') then
    return getSTRInQtKso(ctxt, localeDir .. '/' .. matchedFile .. '.qm')
  end
  if result ~= nil then return result, locale end
end

local function localizeZotero(str, appLocale)
  local resourceDir = hs.application.pathForBundleID("org.zotero.zotero")
                      .. "/Contents/Resources"
  local resourceFile = resourceDir .. '/zotero.jar'
  if not exists(resourceFile) then
    resourceDir = resourceDir .. '/app'
    resourceFile = resourceDir .. '/omni.ja'
  end
  local localePath = 'chrome/locale'
  local locales, status = hs.execute(strfmt([[
    unzip -l '%s' '%s/*' \
    | grep -Eo 'chrome/locale/[^/]*' \
    | grep -Eo '[a-zA-Z-]*$' \
    | uniq
  ]], resourceFile, localePath))
  if status ~= true then return end
  local locale = matchLocale(appLocale, strsplit(locales, '\n'))
  if locale == nil then return end
  local baseLocale = matchLocale('en_US', strsplit(locales, '\n'))
  if baseLocale == nil then return end
  local tmpdir = localeTmpDir .. "org.zotero.zotero"
  mkdir(tmpdir)
  if not exists(tmpdir .. '/' .. localePath .. '/' .. locale) then
    hs.execute(strfmt([[unzip '%s' %s/%s/* -d '%s']],
        resourceFile, localePath, locale, tmpdir))
  end
  if not exists(tmpdir .. '/' .. localePath .. '/' .. baseLocale) then
    hs.execute(strfmt([[unzip '%s' %s/%s/* -d '%s']],
        resourceFile, localePath, baseLocale, tmpdir))
  end
  local localeDir = tmpdir .. '/' .. localePath .. '/' .. locale
  local result = localizeByDTD(str, localeDir, baseLocale)
  if result then return result, locale end
  result = localizeByFTL(str, localeDir, baseLocale)
  if result then return result, locale end
  result = localizeByProperties(str, localeDir, baseLocale)
  return result, locale
end

local function localizeChatGPT(str, appLocale)
  local resourceDir = hs.application.pathForBundleID("com.openai.chat")
      .. "/Contents/Frameworks/Assets.framework/Resources"
      .. "/Assets_Assets.bundle/Contents/Resources/CompressedStrings"
  local localeSources = {}
  for file in hs.fs.dir(resourceDir) do
    if file:sub(-11) == ".json.lzfse" then
      local fileStem = file:sub(1, -12)
      tinsert(localeSources, fileStem)
    end
  end
  local locale = matchLocale(appLocale, localeSources)
  if locale == nil then return nil end
  local localeFile = resourceDir .. '/' .. locale .. '.json.lzfse'
  -- remove first 8 bytes of the file
  local tmp = os:tmpname()
  local _, status = hs.execute(
      strfmt("tail -c +9 '%s' > '%s'", localeFile, tmp))
  if not status then return nil, locale end
  local jsonStr = hs.execute(
      strfmt("lzfse -decode -i '%s' -o /dev/stdout", tmp), true)
  os.remove(tmp)
  local jsonDict = hs.json.decode(jsonStr)
  return jsonDict[str], locale
end

local function localizeSteam(str, appLocale, locale)
  if locale == nil then
    _, locale = hs.osascript.applescript(strfmt([[
      use framework "Foundation"
      set theLocale to current application's NSLocale's localeWithLocaleIdentifier:"en"
      set langName to theLocale's localizedStringForLanguageCode:"%s"
      return langName as text
    ]], strsplit(appLocale, '_')[1]))
    locale = locale:lower()
  end
  if locale == 'english' then return str, locale end
  if locale == 'chinese' then
    if appLocale == 'zh' or appLocale:find('Hans')
        or (not appLocale:find('Hant')
            and (appLocale:find('CN') or appLocale:find('SG'))) then
      locale = 's' .. locale
    else
      locale = 't' .. locale
    end
  end
  local resourceDir
  local app = find("com.valvesoftware.steam")
  if app then
    resourceDir = app:path() .. "/Contents/MacOS"
  else
    resourceDir = os.getenv("HOME") ..
        "/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
  end
  local suffix = '_english.txt'
  for fp in hs.fs.dir(resourceDir) do
    if fp:sub(1, 1) ~= '.' and isdir(resourceDir..'/'..fp) then
      for f in hs.fs.dir(resourceDir .. '/' .. fp) do
        if f:sub(-#suffix) == suffix then
          local key = hs.execute(strfmt([[
            awk -F'\t| ' '$2 ~ /"%s"/ {
              gsub(/"/, "", $1); print $1; exit
            }' '%s' | tr -d '\r\n'
          ]], str, resourceDir..'/'..fp..'/'..f))
          if key ~= "" then
            local enFile = f:gsub('english', locale)
            local result = hs.execute(strfmt([[
              awk -F'\t| ' '$1 ~ /"%s"/ {
                gsub(/"/, "", $2); print $2
              }' '%s' | tr -d '\r\n'
            ]], key, resourceDir..'/'..fp..'/'..enFile))
            if result ~= "" then return result, locale end
          end
        end
      end
    end
  end
  return nil, locale
end

local appLocaleDir = {}
local localeMatchTmpFile = localeTmpDir .. 'map.json'
if exists(localeMatchTmpFile) then
  appLocaleDir = hs.json.read(localeMatchTmpFile)
  for appid, locale in pairs(appLocaleDir) do
    appLocaleDir[appid] = tcopy(locale)
  end
end
local appLocaleMap = {}
local appLocaleAssetBuffer = {}
local appLocaleAssetBufferInverse = {}
local localeTmpFile = localeTmpDir .. 'strings.json'
if exists(localeTmpFile) then
  appLocaleMap = hs.json.read(localeTmpFile)
  for appid, map in pairs(appLocaleMap) do
    appLocaleMap[appid] = tcopy(map)
    for k, v in pairs(appLocaleMap[appid]) do
      appLocaleMap[appid][k] = tcopy(v)
    end
  end
end

local function localizedStringImpl(str, appid, params, force)
  local appLocale, localeFile, localeFramework
  if type(params) == "table" and #params == 0 then
    appLocale = params.locale
    localeFile = params.localeFile
    localeFramework = params.framework
  else
    localeFile = params
  end
  if force == nil then force = false end

  if locMap[appid] ~= nil then
    result = locMap[appid][str]
    if result ~= nil then return result end
  end

  if appLocale == nil then
    appLocale = appid ~= '__macos' and applicationLocale(appid)
        or SYSTEM_LOCALE
  end

  local result

  if not force then
    result = get(appLocaleMap, appid, appLocale, str)
    if result == false then return nil
    elseif result ~= nil then return result end
  end

  if appid ~= '__macos'
      and (hs.application.pathForBundleID(appid) == nil
           or hs.application.pathForBundleID(appid) == "") then
    return nil
  end

  if appid == "com.openai.chat" then
    result, locale = localizeChatGPT(str, appLocale)
    return result, appLocale, locale
  elseif appid:find("com.valvesoftware.steam") then
    locale = get(appLocaleDir, appid, appLocale)
    result, locale = localizeSteam(str, appLocale, locale)
    return result, appLocale, locale
  elseif appid == "org.zotero.zotero" then
    result, locale = localizeZotero(str, appLocale)
    return result, appLocale, locale
  elseif appid:find("org.qt%-project") ~= nil then
    result, locale = localizeQt(str, appid, appLocale)
    return result, appLocale, locale
  elseif appid == "com.kingsoft.wpsoffice.mac" then
    result, locale = localizeWPS(str, appLocale, localeFile)
    return result, appLocale, locale
  end

  local resourceDir, framework = getResourceDir(appid, localeFramework)
  if resourceDir == nil then return nil end
  if framework.chromium then
    if find(appid) then
      local menuBarItems = getMenuBarItems(find(appid), true)
      if #menuBarItems ~= 0 then
        for _, title in ipairs{ 'File', 'Edit', 'Window', 'Help' } do
          if tfind(menuBarItems,
              function(item)
                return item.AXTitle == title
              end) ~= nil then
            return str
          end
        end
      end
    end
  end

  local locale, localeDir
  locale, localeDir, resourceDir, framework =
      getMatchedLocale(appid, appLocale, resourceDir, framework, appLocaleDir)
  if locale == nil then return end
  assert(framework)
  if not framework.electron and not framework.java
      and (not framework.qt or (type(localeDir) ~= 'table' and isdir(localeDir))) then
    local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
    for _, dir in ipairs(baseLocaleDirs) do
      if exists(dir) and hs.fs.attributes(localeDir).ino
                         == hs.fs.attributes(dir).ino then
        return str
      end
    end
  end

  local setDefaultLocale = function()
    if appid == '__macos' then return false end
    local oldLocale = locale
    resourceDir = hs.application.pathForBundleID(appid) .. "/Contents/Resources"
    if not exists(resourceDir) then return false end
    locale = getDefaultMatchedLocale(appLocale, resourceDir, 'lproj')
    if locale == nil then
      locale = oldLocale
      return false
    end
    localeDir = resourceDir .. "/" .. locale .. ".lproj"
    return true
  end

  if framework.chromium then
    result = localizeByChromium(str, localeDir, appid)
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.ftl then
    result = localizeByFTL(str, localeDir)
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.dtd then
    result = localizeByDTD(str, localeDir)
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.properties then
    result = localizeByProperties(str, localeDir)
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.mono then
    result = localizeByMono(str, localeDir)
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.qt then
    result = localizeByQt(str, localeDir)
    return result, appLocale, locale
  end

  if framework.electron then
    result = localizeByElectron(str, appid, locale, localeDir,
                                framework.electron)
    return result, appLocale, locale
  end

  if framework.java then
    result = localizeByJava(str, appid, localeDir, resourceDir)
    return result, appLocale, locale
  end

  local defaultAction = function(emptyCache)
    if emptyCache or appLocaleAssetBuffer[appid] == nil
        or get(appLocaleDir, appid, appLocale) ~= locale then
      appLocaleAssetBuffer[appid] = {}
    end

    result = localizeByLoctable(str, resourceDir, localeFile, locale,
                                appLocaleAssetBuffer[appid])
    if result ~= nil then return result end

    if emptyCache or appLocaleAssetBufferInverse[appid] == nil
        or get(appLocaleDir, appid, appLocale) ~= locale then
      appLocaleAssetBufferInverse[appid] = {}
    end
    result = localizeByStrings(str, localeDir, localeFile,
                               appLocaleAssetBuffer[appid],
                               appLocaleAssetBufferInverse[appid])
    if result ~= nil then return result end

    result = localizeByNIB(str, localeDir, localeFile, appid)
    if result ~= nil then return result end
  end

  if framework.user then
    local userResourceDir = resourceDir
    local userLocale = locale
    local userLocaleDir = localeDir
    if setDefaultLocale() then
      result = defaultAction(true)
      if result ~= nil then return result, appLocale, locale end
    end

    resourceDir = userResourceDir
    locale = userLocale
    localeDir = userLocaleDir
  end
  result = defaultAction(framework.user)
  if result ~= nil then return result, appLocale, locale end

  if str:sub(-3) == "..." or str:sub(-3) == "…" then
    result, appLocale, locale =
        localizedStringImpl(str:sub(1, -4), appid, params)
    if result ~= nil then
      return result .. str:sub(-3), appLocale, locale
    end
  end

  return nil, appLocale, locale
end

function localizedString(str, appid, params, force)
  if type(appid) == 'table' then
    force = params params = appid appid = nil
  end
  if appid == nil and (type(params) ~= 'table' or params.framework == nil) then
    return
  end
  appid = appid or '__macos'
  local result, appLocale, locale =
      localizedStringImpl(str, appid, params, force)
  if appLocale == nil then return result end

  if appLocaleDir[appid] == nil then
    appLocaleDir[appid] = {}
  end
  if locale == nil then
    appLocaleDir[appid][appLocale] = false
    goto L_END_DUMP_LOCALIZED
  else
    appLocaleDir[appid][appLocale] = locale
  end

  if appLocaleMap[appid] == nil then
    appLocaleMap[appid] = {}
  end
  if appLocaleMap[appid][appLocale] == nil then
    appLocaleMap[appid][appLocale] = {}
  end
  if result ~= nil then
    appLocaleMap[appid][appLocale][str] = result
  else
    appLocaleMap[appid][appLocale][str] = false
  end

  ::L_END_DUMP_LOCALIZED::
  if not exists(localeTmpDir) then
    hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
  end
  hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
  hs.json.write(appLocaleMap, localeTmpFile, false, true)
  return result
end


local function delocalizeByLoctableImpl(str, filePath, locale, localesDict, baseNibFile)
  if localesDict[locale] == nil then
    local loctables = hs.plist.read(filePath)
    localesDict[locale] = loctables[locale]
    if localesDict[locale] == nil then return end
    if baseNibFile == nil then
      local enLocales = tconcat({ 'en', 'English', 'Base' }, extraEnglishLocales)
      for _, en in ipairs(enLocales) do
        localesDict[en] = loctables[en]
      end
    else
      localesDict['Base'] = parseNIBFile(baseNibFile)
    end
  end

  local key = tindex(localesDict[locale], str)
  if key == nil then return end
  local enLocales = tconcat({ 'en', 'English', 'Base' }, extraEnglishLocales)
  for _, en in ipairs(enLocales) do
    if localesDict[en] ~= nil then
      return localesDict[en][key]
    end
  end
end

local function delocalizeByLoctable(str, resourceDir, localeFile, locale, localesDict)
  local loctableFiles = {}
  if localeFile ~= nil then
    if type(localeFile) == 'string' then
      localeFile = { localeFile }
    end
    for file in hs.fs.dir(resourceDir) do
      if file:sub(-9) == '.loctable' then
        for _, p in ipairs(localeFile) do
          if file:sub(1, -10):match('^' .. p .. '$') then
            tinsert(loctableFiles, file:sub(1, -10))
          end
        end
      end
    end
  else
    loctableFiles = collectLocaleFiles(resourceDir, { loctable = true })
    local preferentialLoctableFiles = {}
    if #loctableFiles > 10 then
      loctableFiles, preferentialLoctableFiles =
          filterPreferentialLocaleFiles(loctableFiles)
    end
    tconcat(preferentialLoctableFiles, loctableFiles)
    loctableFiles = preferentialLoctableFiles
  end
  if localesDict == nil then
    localesDict = {}
  end
  for _, file in ipairs(loctableFiles) do
    local fullPath = resourceDir .. '/' .. file .. '.loctable'
    if localesDict[file] == nil then
      localesDict[file] = {}
    end
    local baseNibFile
    for _, en in ipairs{'Base', 'en', 'English'} do
      local nibFile = resourceDir .. strfmt('/%s.lproj/%s.nib', en, file)
      if exists(nibFile) then
        baseNibFile = nibFile break
      end
    end
    local result = delocalizeByLoctableImpl(str, fullPath, locale, localesDict[file], baseNibFile)
    if result ~= nil then return result end
  end
end

local function delocalizeByStrings(str, localeDir, localeFile, deLocalesInvDict)
  local resourceDir = localeDir .. '/..'
  local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
  local searchFunc = function(str, file)
    local dirs = appendExtraEnglishLocaleDirs(resourceDir, baseLocaleDirs)
    for _, baseLocaleDir in ipairs(dirs) do
      local jsonDict
      if exists(baseLocaleDir .. '/' .. file .. '.strings') then
        jsonDict = parseStringsFile(baseLocaleDir .. '/' .. file .. '.strings')
      elseif exists(baseLocaleDir .. '/' .. file .. '.strings.1') then
        jsonDict = parseStringsFile(baseLocaleDir .. '/' .. file .. '.strings.1')
      elseif exists(baseLocaleDir .. '/' .. file .. '.nib') then
        local fullPath = baseLocaleDir .. '/' .. file .. '.nib'
        if isdir(fullPath) then
          if exists(fullPath .. '/keyedobjects.nib') then
            fullPath = fullPath .. '/keyedobjects.nib'
          else
            fullPath = hs.execute(strfmt([[
              ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n'
            ]], fullPath))
            if fullPath == "" then return end
          end
        end
        jsonDict = parseNIBFile(fullPath)
      end
      if jsonDict ~= nil and jsonDict[str] ~= nil then
        return jsonDict[str]
      end
      if exists(baseLocaleDir .. '/' .. file .. '.storyboardc') then
        local fullPath = baseLocaleDir .. '/' .. file .. '.storyboardc'
        for subFile in hs.fs.dir(fullPath) do
          if subFile:sub(-4) == '.nib' then
            jsonDict = parseNIBFile(fullPath .. '/' .. subFile)
            if jsonDict ~= nil and jsonDict[str] ~= nil then
              return jsonDict[str]
            end
          end
        end
      end
    end
  end

  local invSearchFunc = function(str, files)
    for _, fileStem in ipairs(files) do
      local invDict = deLocalesInvDict[fileStem]
      if invDict == nil then
        if exists(localeDir .. '/' .. fileStem .. '.strings') then
          invDict = parseStringsFile(localeDir .. '/' .. fileStem .. '.strings',
                                     false, true)
        elseif exists(localeDir .. '/' .. fileStem .. '.strings.1') then
          invDict = parseStringsFile(localeDir .. '/' .. fileStem .. '.strings.1',
                                     false, true)
        end
      end
      if invDict ~= nil and invDict[str] ~= nil then
        local keys = invDict[str]
        if type(keys) == 'string' then keys = { keys } end
        for _, key in ipairs(keys) do
          local result = searchFunc(key, fileStem)
          if result ~= nil then
            deLocalesInvDict[fileStem] = invDict
            return result
          end
        end
        for _, key in ipairs(keys) do
          if not (key:match("[^%a ]")) then
            deLocalesInvDict[fileStem] = invDict
            return key
          end
        end
      end
    end
  end

  local stringsFiles = {}
  if localeFile ~= nil then
    if type(localeFile) == 'string' then
      localeFile = { localeFile }
    end
    for file in hs.fs.dir(localeDir) do
      if file:sub(-8) == '.strings' then
        for _, p in ipairs(localeFile) do
          if file:sub(1, -9):match('^' .. p .. '$') then
            tinsert(stringsFiles, file:sub(1, -9))
          end
        end
      elseif file:sub(-10) == '.strings.1' then
        for _, p in ipairs(localeFile) do
          if file:sub(1, -11):match('^' .. p .. '$') then
            tinsert(stringsFiles, file:sub(1, -11))
          end
        end
      end
    end
  else
    stringsFiles = collectLocaleFiles(localeDir, { strings = true })
    if #stringsFiles > 10 then
      _, stringsFiles = filterPreferentialLocaleFiles(stringsFiles)
    end
  end
  local result = invSearchFunc(str, stringsFiles)
  if result ~= nil then return result end
end

local function delocalizeByNIB(str, localeDir, localeFile, appid)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  local baseLocaleDir = getBaseLocaleDirs(resourceDir)[1]
  local baseLocale = baseLocaleDir:match("^.*/(.*)%.lproj$")
  local compareNIBs = function(file)
    local NIBPath = localeDir .. '/' .. file .. '.nib'
    local baseNIBPath = baseLocaleDir .. '/' .. file .. '.nib'
    if not exists(NIBPath) or not exists(baseNIBPath) then return end
    if isdir(NIBPath) then
      if exists(NIBPath .. '/keyedobjects.nib') then
        NIBPath = NIBPath .. '/keyedobjects.nib'
      else
        NIBPath = hs.execute(strfmt([[
          ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n']], NIBPath))
        if NIBPath == "" then return end
      end
    end
    if isdir(baseNIBPath) then
      if exists(baseNIBPath .. '/keyedobjects.nib') then
        baseNIBPath = baseNIBPath .. '/keyedobjects.nib'
      else
        baseNIBPath = hs.execute(strfmt([[
          ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n'
        ]], baseNIBPath))
        if baseNIBPath == "" then return end
      end
    end

    local tmpBaseDir = localeTmpDir .. appid
    mkdir(tmpBaseDir)

    if isBinarayPlist(NIBPath) and isBinarayPlist(baseNIBPath) then
      -- do not use "hs.plist.read" for performance reasons
      local xmlDir = tmpBaseDir .. '/' .. locale
      local xmlPath = xmlDir .. '/' .. file .. '.xml'
      if not exists(xmlPath) then
        mkdir(xmlDir)
        local _, status = hs.execute(strfmt(
            "plutil -convert xml1 '%s' -o '%s'", NIBPath, xmlPath))
        if not status then return end
      end
      local baseXmlDir = tmpBaseDir .. '/' .. baseLocale
      local baseXmlPath = baseXmlDir .. '/' .. file .. '.xml'
      if not exists(baseXmlPath) then
        mkdir(baseXmlDir)
        local _, status = hs.execute(strfmt(
            "plutil -convert xml1 '%s' -o '%s'", baseNIBPath, baseXmlPath))
        if not status then return end
      end
      local diffDir = tmpBaseDir .. '/' .. locale .. '-' .. baseLocale
      local diffPath = diffDir .. '/' .. file .. '.diff'
      if not exists(diffPath) then
        mkdir(diffDir)
        hs.execute(strfmt("diff --suppress-common-lines '%s' '%s' > '%s'",
                          xmlPath, baseXmlPath, diffPath))
      end
      local result = hs.execute(strfmt([[
          cat '%s' | awk '/^<.*<string>%s<\/string>/ && !found {
            curline=$0; getline;
            if ($0 == curline) {getline}
            if ($0 ~ "---") {getline; print $0}; found=1
          }' | \
          sed 's/^>.*<string>//;s/<\/string>$//' | tr -d '\n']],
          diffPath, str))
      return result ~= "" and result or nil
    end

    local jsonDir = tmpBaseDir .. '/' .. locale
    local jsonPath = jsonDir .. '/' .. file .. '.json'
    if not exists(jsonPath) then
      mkdir(jsonDir)
      local _, status = hs.execute(strfmt(
          "/usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'",
          NIBPath, jsonPath))
      if not status then return end
    end
    local baseJsonDir = tmpBaseDir .. '/' .. baseLocale
    local baseJsonPath = baseJsonDir .. '/' .. file .. '.json'
    if not exists(baseJsonPath) then
      mkdir(baseJsonDir)
      local _, status = hs.execute(strfmt(
          "/usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'",
          baseLocaleDir .. '/' .. file .. '.nib', baseJsonPath))
      if not status then return end
    end
    local diffDir = tmpBaseDir .. '/' .. locale .. '-' .. baseLocale
    local diffPath = diffDir .. '/' .. file .. '.diff'
    if not exists(diffPath) then
      mkdir(diffDir)
      hs.execute(strfmt("diff --suppress-common-lines '%s' '%s' > '%s'",
                        jsonPath, baseJsonPath, diffPath))
    end
    local result = hs.execute(strfmt([[
      cat '%s' | awk '/^<.*"data": "%s"/ && !found {
        getline;
        if ($0 ~ "---") {getline; print $0; found=1}
      }' | \
      sed 's/^>.*"data": "//;s/"$//' | tr -d '\n'
    ]], diffPath, str))
    return result ~= "" and result or nil
  end

  local nibFiles = {}
  if localeFile ~= nil then
    if type(localeFile) == 'string' then
      localeFile = { localeFile }
    end
    for file in hs.fs.dir(localeDir) do
      if file:sub(-4) == '.nib' then
        for _, p in ipairs(localeFile) do
          if file:sub(1, -5):match('^' .. p .. '$') then
            tinsert(nibFiles, file:sub(1, -5))
          end
        end
      end
    end
  else
    nibFiles = collectLocaleFiles(localeDir, { nib = true })
    if #nibFiles > 10 then
      _, nibFiles = filterPreferentialLocaleFiles(nibFiles)
    end
  end
  for _, file in ipairs(nibFiles) do
    local result = compareNIBs(file)
    if result ~= nil then return result end
  end
end

local function delocalizeByQtImpl(str, file)
  local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
  if cmd == nil then return end
  local output, status = hs.execute(strfmt(
    '%s -i "%s" -of po | %s', cmd, file, poStrToId(str)))
  if status and output ~= "" then return output end
end

local function delocalizeByQt(str, localeDir)
  if type(localeDir) == 'table' then
    for _, file in ipairs(localeDir) do
      local result = delocalizeByQtImpl(str, file)
      if result ~= nil then return result end
    end
  elseif isfile(localeDir) then
    return delocalizeByQtImpl(str, localeDir)
  else
    for file in hs.fs.dir(localeDir) do
      if file:sub(-3) == ".qm" then
        local result = delocalizeByQtImpl(str, localeDir .. '/' .. file)
        if result ~= "" then return result end
      end
    end
  end
end

local function delocalizeByFTL(str, localeDir, baseLocale)
  if baseLocale == nil then
    local resourceDir = localeDir .. '/..'
    baseLocale = getDefaultMatchedLocale('en', resourceDir)
        or getDefaultMatchedLocale('English', resourceDir)
    if baseLocale == nil then return end
  end

  local lines = hs.execute(strfmt([[
    find '%s' -type f -path '*.ftl' \
    | xargs -I{} grep -E '([^=]*?) = %s$' -H {}
  ]], localeDir, str))
  lines = strsplit(lines, '\n')
  lines[#lines] = nil
  if #lines == 0 then return end
  local firstColon = lines[1]:find(':')
  local filepath = lines[1]:sub(1, firstColon - 1)
  local pair = lines[1]:sub(firstColon + 1)
  local firstEqual = pair:find(' = ')
  local key = pair:sub(1, firstEqual - 1)
  local pathItems = strsplit(localeDir, '/')
  local locale = pathItems[#pathItems]:gsub('%-', '%%-')
  local baseLocaleFile = filepath:gsub('/'..locale..'/', '/'..baseLocale..'/')
  if exists(baseLocaleFile) then
    local result, status = hs.execute(strfmt([[
      grep -E '^%s = (.*?)$' '%s'
    ]], key, baseLocaleFile))
    if status and result ~= "\n" then
      local line = strsplit(result, '\n')[1]
      local firstEqual = pair:find(' = ')
      return line:sub(firstEqual + 3)
    end
  end
end

local function delocalizeByProperties(str, localeDir, baseLocale)
  if baseLocale == nil then
    local resourceDir = localeDir .. '/..'
    baseLocale = getDefaultMatchedLocale('en', resourceDir)
        or getDefaultMatchedLocale('English', resourceDir)
    if baseLocale == nil then return end
  end

  local lines = hs.execute(strfmt([[
    find '%s' -type f -path '*.properties' \
    | xargs -I{} grep -E '([^=\s]*?)(\s*?)=(\s*?)%s$' -H {}
  ]], localeDir, str))
  lines = strsplit(lines, '\n')
  lines[#lines] = nil
  if #lines == 0 then return end
  local firstColon = lines[1]:find(':')
  local filepath = lines[1]:sub(1, firstColon - 1)
  local pair = lines[1]:sub(firstColon + 1)
  local equalStart = pair:find('%s-=%s-')
  local key = pair:sub(1, equalStart - 1)
  local pathItems = strsplit(localeDir, '/')
  local locale = pathItems[#pathItems]:gsub('%-', '%%-')
  local baseLocaleFile = filepath:gsub('/'..locale..'/', '/'..baseLocale..'/')
  if exists(baseLocaleFile) then
    local result, status = hs.execute(strfmt([[
      grep -E '^%s\s+=\s+(.*?)$' '%s'
    ]], key, baseLocaleFile))
    if status and result ~= "\n" then
      local line = strsplit(result, '\n')[1]
      local _, equalEnd = line:find('%s-=%s-')
      return line:sub(equalEnd + 1)
    end
  end
end

local function delocalizeByDTD(str, localeDir, baseLocale)
  if baseLocale == nil then
    local resourceDir = localeDir .. '/..'
    baseLocale = getDefaultMatchedLocale('en', resourceDir)
        or getDefaultMatchedLocale('English', resourceDir)
    if baseLocale == nil then return end
  end

  local lines = hs.execute(strfmt([[
    find '%s' -type f -path '*.dtd' \
    | xargs -I{} grep -E '^<!ENTITY.*"%s">' -H {}
  ]], localeDir, str))
  lines = strsplit(lines, '\n')
  lines[#lines] = nil
  if #lines == 0 then return end
  local firstColon = lines[1]:find(':')
  local filepath = lines[1]:sub(1, firstColon - 1)
  local pair = lines[1]:sub(firstColon + 1)
  local firstQuote = pair:find(' "')
  local key = pair:sub(10, firstQuote - 1)
  local pathItems = strsplit(localeDir, '/')
  local locale = pathItems[#pathItems]:gsub('%-', '%%-')
  local baseLocaleFile = filepath:gsub('/'..locale..'/', '/'..baseLocale..'/')
  if exists(baseLocaleFile) then
    local result, status = hs.execute(strfmt([[
      grep -E '^<!ENTITY %s(\s*?)"(.*?)">' '%s'
    ]], key, baseLocaleFile))
    if status and result ~= "\n" then
      local line = strsplit(result, '\n')[1]
      return line:sub(9 + #key + 1):match('"(.-)"')
    end
  end
end

local function delocalizeByMono(str, localeDir)
  local cmd = hs.execute("which msgunfmt | tr -d '\\n'", true)
  if cmd == nil then return end
  for file in hs.fs.dir(localeDir .. '/LC_MESSAGES') do
    if file:sub(-3) == ".mo" then
      local output, status = hs.execute(strfmt(
        '%s "%s" -o - | %s',
        cmd, localeDir .. '/LC_MESSAGES/' .. file, poStrToId(str)))
      if status and output ~= "" then return output end
    end
  end
end

local function delocalizeByChromium(str, localeDir, appid)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  for file in hs.fs.dir(localeDir) do
    if file:sub(-4) == ".pak" then
      local fileStem = file:sub(1, -5)
      local baseDir = localeTmpDir .. appid
      mkdir(baseDir)
      local tmpBaseDir = baseDir .. '/' .. locale
      local tmpdir = tmpBaseDir .. '/' .. fileStem
      if dirNotExistOrEmpty(tmpdir) then
        mkdir(tmpBaseDir)
        hs.execute(strfmt("scripts/pak  -u '%s' '%s'",
                          localeDir .. '/' .. file, tmpdir))
      end
      local pattern = '^' .. str .. '$'
      local output, status = hs.execute(strfmt([[
        grep -lrE '%s' '%s' | tr -d '\n'
      ]], pattern, tmpdir))
      if status and output ~= "" then
        local matchFile = output:match("^.*/(.*)$")
        for _, enLocale in ipairs{"en", "English", "Base", "en_US", "en_GB"} do
          local fullPath = resourceDir .. '/' .. enLocale .. '.lproj/' .. file
          if exists(fullPath) then
            local enTmpBaseDir = baseDir .. '/' .. enLocale
            local enTmpdir = enTmpBaseDir .. '/' .. fileStem
            if dirNotExistOrEmpty(enTmpdir) then
              mkdir(enTmpBaseDir)
              hs.execute(strfmt("scripts/pak  -u '%s' '%s'", fullPath, enTmpdir))
            end
            local matchFullPath = enTmpdir .. '/' .. matchFile
            if exists(matchFullPath) then
              local f = io.open(matchFullPath, "r")
              if f ~= nil then
                local content = f:read("*a")
                f:close()
                return content
              end
            end
          end
        end
      end
    end
  end
end

local function delocalizeByElectron(str, appid, locale, localeFiles, localesPath)
  local tmpBaseDir = localeTmpDir .. appid
  local tmpdir = tmpBaseDir .. '/' .. locale
  if #localeFiles > 0 then
    for _, file in ipairs(localeFiles) do
      local tmpfile = tmpdir .. '/' .. file .. '.json'
      if not exists(tmpfile) then
        local path = hs.application.pathForBundleID(appid)
            .. '/Contents/Resources/app.asar'
        local localeFilePath = strfmt("%s/%s/%s.json",
            localesPath, locale, file)
        hs.execute(strfmt([[
          npx @electron/asar extract-file "%s" "%s"
        ]], path, localeFilePath), true)
        mkdir(tmpBaseDir)
        mkdir(tmpdir)
        hs.execute(strfmt("mv '%s' '%s'", file .. '.json', tmpdir))
      end
    end
  end
  for file in hs.fs.dir(tmpdir) do
    if file:sub(-5) == '.json' then
      local json = hs.json.read(tmpdir .. '/' .. file)
      local result = tindex(json, str)
      if result ~= nil then return result, locale end
    end
  end
  return nil, locale
end

local function delocalizeByJava(str, appid, localeFiles, javehome)
  for _, file in ipairs(localeFiles) do
    local tmpBaseDir = localeTmpDir .. appid
    local fullpath = tmpBaseDir .. '/' .. file .. ".properties"
    if not exists(fullpath) then
      local cmd = javehome .. '/bin/jimage'
      local modulePath = javehome .. '/lib/modules'
      hs.execute(cmd .. " extract"
          .. " --include regex:.*" .. file .. "\\.properties"
          .. " --dir " .. tmpBaseDir .. " " .. modulePath)
    end
    if exists(fullpath) then
      local result, ok = hs.execute(strfmt(
          "cat '%s' | grep '=%s$'", fullpath, str))
      if ok then
        result = strsplit(result, '\n')
        result = result[1]:sub(1, #result[1] - #str - 1)
        result = result:gsub('\\ ', ' '):gsub('\\:', ':')
        return result
      end
    end
  end
end

local function delocalizeQt(str, appid, appLocale)
  local appPath = hs.application.pathForBundleID(appid)
  local resourceDir = appPath .. "/../../share/qt/translations"
  if not exists(resourceDir) then
    resourceDir = appPath .. "/../Qt/translations"
  end
  if not exists(resourceDir) then return end
  local appname = appPath:match("^.*/([^/]+)%.app$")
  if appname == nil
      or not exists(resourceDir .. "/" .. appname:lower() .. "_en.qm") then
    return
  end
  local locales = {}
  local prefix = appname:lower() .. '_'
  for file in hs.fs.dir(resourceDir) do
    if file:sub(-3) == ".qm" and file:sub(1, #prefix) == prefix then
      tinsert(locales, file:sub(#prefix + 1, -4))
    end
  end
  local locale = matchLocale(appLocale, locales)
  if locale == nil then return end
  if locale == 'en' then return str, locale end
  local localeFile = resourceDir .. '/' .. prefix .. locale .. '.qm'
  local result = delocalizeByQtImpl(str .. '\\(&[A-Z]\\)', localeFile)
  if result ~= nil then
    return result, locale
  end
  result = delocalizeByQtImpl(str, localeFile)
  return result, locale
end

local function delocalizeWPS(str, appLocale, localeFile)
  local resourceDir =
      hs.application.pathForBundleID("com.kingsoft.wpsoffice.mac")
      .. '/Contents/Resources/office6/mui'
  local locale = getDefaultMatchedLocale(appLocale, resourceDir)
  if locale == nil then return end
  if type(localeFile) == 'string' then
    localeFile = { localeFile }
  end
  local localeDir = resourceDir .. '/' .. locale

  local ctxt, matchedFile
  for file in hs.fs.dir(localeDir) do
    if file:sub(-3) == ".qm" then
      local valid = true
      if localeFile then
        valid = any(localeFile, function(p)
          return file:sub(1, -4):match('^' .. p .. '$')
        end)
      end
      if valid then
        ctxt = getCTXTInQtKso(str, localeDir .. '/' .. file)
        if ctxt ~= nil then
          matchedFile = file:sub(1, -4)
          break
        end
      end
    end
  end
  if ctxt == nil then return nil, locale end

  local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
  local dirs = appendExtraEnglishLocaleDirs(resourceDir, baseLocaleDirs)
  for _, dir in ipairs(dirs) do
    if exists(dir .. '/' .. matchedFile .. '.qm') then
      local result = getSTRInQtKso(ctxt, dir .. '/' .. matchedFile .. '.qm')
      if result ~= nil then return result, locale end
    end
  end
  return nil, locale
end

local function delocalizeZotero(str, appLocale)
  local resourceDir = hs.application.pathForBundleID("org.zotero.zotero")
                      .. "/Contents/Resources"
  local resourceFile = resourceDir .. '/zotero.jar'
  if not exists(resourceFile) then
    resourceDir = resourceDir .. '/app'
    resourceFile = resourceDir .. '/omni.ja'
  end
  local localePath = 'chrome/locale'
  local locales, status = hs.execute(strfmt([[
    unzip -l '%s' '%s/*' \
    | grep -Eo 'chrome/locale/[^/]*' \
    | grep -Eo '[a-zA-Z-]*$' \
    | uniq
  ]], resourceFile, localePath))
  if status ~= true then return end
  local locale = matchLocale(appLocale, strsplit(locales, '\n'))
  if locale == nil then return end
  local baseLocale = matchLocale('en_US', strsplit(locales, '\n'))
  if baseLocale == nil then return end
  local tmpdir = localeTmpDir .. "org.zotero.zotero"
  mkdir(tmpdir)
  if not exists(tmpdir .. '/' .. localePath .. '/' .. locale) then
    hs.execute(strfmt([[unzip '%s' %s/%s/* -d '%s']],
        resourceFile, localePath, locale, tmpdir))
  end
  if not exists(tmpdir .. '/' .. localePath .. '/' .. baseLocale) then
    hs.execute(strfmt([[unzip '%s' %s/%s/* -d '%s']],
        resourceFile, localePath, baseLocale, tmpdir))
  end
  local localeDir = tmpdir .. '/' .. localePath .. '/' .. locale
  local result = delocalizeByDTD(str, localeDir, baseLocale)
  if result then return result, locale end
  result = delocalizeByFTL(str, localeDir, baseLocale)
  if result then return result, locale end
  result = delocalizeByProperties(str, localeDir, baseLocale)
  return result, locale
end

local function delocalizeChatGPT(str, appLocale)
  local resourceDir = hs.application.pathForBundleID("com.openai.chat")
      .. "/Contents/Frameworks/Assets.framework/Resources"
      .. "/Assets_Assets.bundle/Contents/Resources/CompressedStrings"
  local localeSources = {}
  for file in hs.fs.dir(resourceDir) do
    if file:sub(-11) == ".json.lzfse" then
      local fileStem = file:sub(1, -12)
      tinsert(localeSources, fileStem)
    end
  end
  local locale = matchLocale(appLocale, localeSources)
  if locale == nil then return nil end
  local localeFile = resourceDir .. '/' .. locale .. '.json.lzfse'
  -- remove first 8 bytes of the file
  local tmp = os:tmpname()
  local _, status = hs.execute(
      strfmt("tail -c +9 '%s' > '%s'", localeFile, tmp))
  if not status then return nil, locale end
  local jsonStr = hs.execute(
      strfmt("lzfse -decode -i '%s' -o /dev/stdout", tmp), true)
  os.remove(tmp)
  local jsonDict = hs.json.decode(jsonStr)
  return tindex(jsonDict, str), locale
end

local function delocalizeSteam(str, appLocale, locale)
  if locale == nil then
    _, locale = hs.osascript.applescript(strfmt([[
      use framework "Foundation"
      set theLocale to current application's NSLocale's localeWithLocaleIdentifier:"en"
      set langName to theLocale's localizedStringForLanguageCode:"%s"
      return langName as text
    ]], strsplit(appLocale, '_')[1]))
    locale = locale:lower()
  end
  if locale == 'english' then return str, locale end
  if locale == 'chinese' then
    if appLocale == 'zh' or appLocale:find('Hans')
        or (not appLocale:find('Hant')
            and (appLocale:find('CN') or appLocale:find('SG'))) then
      locale = 's' .. locale
    else
      locale = 't' .. locale
    end
  end
  local resourceDir
  local app = find("com.valvesoftware.steam")
  if app then
    resourceDir = app:path() .. "/Contents/MacOS"
  else
    resourceDir = os.getenv("HOME") ..
        "/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
  end
  local suffix = '_' .. locale .. '.txt'
  for fp in hs.fs.dir(resourceDir) do
    if fp:sub(1, 1) ~= '.' and isdir(resourceDir..'/'..fp) then
      for f in hs.fs.dir(resourceDir .. '/' .. fp) do
        if f:sub(-#suffix) == suffix then
          local key = hs.execute(strfmt([[
            awk -F'\t| ' '$2 ~ /"%s"/ {
              gsub(/"/, "", $1); print $1; exit
            }' '%s' | tr -d '\r\n'
          ]], str, resourceDir..'/'..fp..'/'..f))
          if key ~= "" then
            local enFile = f:gsub(locale, 'english')
            local result = hs.execute(strfmt([[
              awk -F'\t| ' '$1 ~ /"%s"/ {
                gsub(/"/, "", $2); print $2
              }' '%s' | tr -d '\r\n'
            ]], key, resourceDir..'/'..fp..'/'..enFile))
            if result ~= "" then return result, locale end
          end
        end
      end
    end
  end
  return nil, locale
end

local function delocalizeMATLABFigureMenu(str, appLocale)
  local resourceDir = hs.application.pathForBundleID("com.mathworks.matlab")
                      .. "/resources/MATLAB"
  local locale = getDefaultMatchedLocale(appLocale, resourceDir)
  if locale == nil then return end
  local localeFile = resourceDir .. '/' .. locale .. '/uistring/figuremenu.xml'
  local enLocaleFile = resourceDir .. '/en/uistring/figuremenu.xml'
  local shell_pattern = 'key="([^"]*?)">' .. str .. '\\(&amp;[A-Z]\\)</entry>'
  local key, status = hs.execute(strfmt([[
    grep -Eo '%s' '%s' | cut -d '"' -f 2 | tr -d '\n'
  ]], shell_pattern, localeFile))
  if status and key ~= "" then
    local inverse_pattern = 'key="' .. key .. '">&amp;([^<]*?)</entry>'
    local enValue, status = hs.execute(strfmt([[
      grep -Eo '%s' '%s' | cut -d ';' -f 2  | cut -d '<' -f 1 | tr -d '\n'
    ]], inverse_pattern, enLocaleFile))
    if status and enValue ~= "" then return enValue, locale end
  end
  return nil, locale
end

local deLocaleMap = {}
local deLocaleInversedMap = {}
local menuItemTmpFile = localeTmpDir .. 'menubar.json'
if exists(menuItemTmpFile) then
  deLocaleMap = hs.json.read(menuItemTmpFile)
  for appid, map in pairs(deLocaleMap) do
    deLocaleMap[appid] = tcopy(map)
    for k, v in pairs(deLocaleMap[appid]) do
      deLocaleMap[appid][k] = tcopy(v)
    end
  end
end

local function delocalizedStringImpl(str, appid, params, force)
  local appLocale, localeFile, localeFramework
  if type(params) == "table" and #params == 0 then
    appLocale = params.locale
    localeFile = params.localeFile
    localeFramework = params.framework
  else
    localeFile = params
  end
  if force == nil then force = false end

  if appLocale == nil then
    appLocale = applicationLocale(appid)
  end

  if not force then
    local result = get(deLocaleMap, appid, appLocale, str)
    if result == false then return nil
    elseif result ~= nil then return result end
  end
  if appid == "com.openai.chat" then
    result, locale = delocalizeChatGPT(str, appLocale)
    return result, appLocale, locale
  elseif appid:find("com.valvesoftware.steam") then
    locale = get(appLocaleDir, appid, appLocale)
    result, locale = delocalizeSteam(str, appLocale, locale)
    return result, appLocale, locale
  elseif appid == "org.zotero.zotero" then
    result, locale = delocalizeZotero(str, appLocale)
    return result, appLocale, locale
  elseif appid == "com.mathworks.matlab" then
    result, locale = delocalizeMATLABFigureMenu(str, appLocale)
    return result, appLocale, locale
  elseif appid:find("org.qt%-project") ~= nil then
    result, locale = delocalizeQt(str, appid, appLocale)
    return result, appLocale, locale
  elseif appid == "com.kingsoft.wpsoffice.mac" then
    result, locale = delocalizeWPS(str, appLocale, localeFile)
    return result, appLocale, locale
  end

  local resourceDir, framework = getResourceDir(appid, localeFramework)
  if resourceDir == nil then return nil end
  if framework.chromium then
    if find(appid) then
      local menuBarItems = getMenuBarItems(find(appid), true)
      if #menuBarItems ~= 0 then
        for _, title in ipairs{ 'File', 'Edit', 'Window', 'Help' } do
          if tfind(menuBarItems,
              function(item)
                return item.AXTitle == title
              end) ~= nil then
            return str
          end
        end
      end
    end
  end

  local locale, localeDir
  locale, localeDir, resourceDir, framework =
      getMatchedLocale(appid, appLocale, resourceDir, framework, appLocaleDir)
  if locale == nil then return end
  assert(framework)
  if not framework.electron and not framework.java then
    local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
    for _, dir in ipairs(baseLocaleDirs) do
      if exists(dir) and hs.fs.attributes(localeDir).ino
                         == hs.fs.attributes(dir).ino then
        return str
      end
    end
  end

  local setDefaultLocale = function()
    local oldLocale = locale
    resourceDir = hs.application.pathForBundleID(appid) .. "/Contents/Resources"
    if not exists(resourceDir) then return false end
    locale = getDefaultMatchedLocale(appLocale, resourceDir, 'lproj')
    if locale == nil then
      locale = oldLocale
      return false
    end
    localeDir = resourceDir .. "/" .. locale .. ".lproj"
    return true
  end

  if framework.chromium then
    result = delocalizeByChromium(str, localeDir, appid)
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.ftl then
    result = delocalizeByFTL(str, localeDir)
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.dtd then
    result = delocalizeByDTD(str, localeDir)
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.properties then
    result = delocalizeByProperties(str, localeDir)
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.mono then
    result = delocalizeByMono(str, localeDir)
    if result ~= nil then
      if appid == "com.microsoft.visual-studio" then
        result = result:gsub('_', '')
      end
    end
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.qt then
    result = delocalizeByQt(str, localeDir)
    return result, appLocale, locale
  end

  if framework.electron then
    result = delocalizeByElectron(str, appid, locale, localeDir,
                                  framework.electron)
    return result, appLocale, locale
  end

  if framework.java then
    result = delocalizeByJava(str, appid, localeDir, resourceDir)
    return result, appLocale, locale
  end

  local defaultAction = function(emptyCache)
    if emptyCache or appLocaleAssetBuffer[appid] == nil
        or get(appLocaleDir, appid, appLocale) ~= locale then
      appLocaleAssetBuffer[appid] = {}
    end
    result = delocalizeByLoctable(str, resourceDir, localeFile, locale,
                                  appLocaleAssetBuffer[appid])
    if result ~= nil then return result end

    if emptyCache or deLocaleInversedMap[appid] == nil
        or get(appLocaleDir, appid, appLocale) ~= locale then
      deLocaleInversedMap[appid] = {}
    end
    result = delocalizeByStrings(str, localeDir, localeFile,
                                 deLocaleInversedMap[appid])
    if result ~= nil then return result end

    result = delocalizeByNIB(str, localeDir, localeFile, appid)
    if result ~= nil then return result end
  end

  if framework.user then
    local userResourceDir = resourceDir
    local userLocale = locale
    local userLocaleDir = localeDir
    if setDefaultLocale() then
      result = defaultAction(true)
      if result ~= nil then return result, appLocale, locale end
    end

    resourceDir = userResourceDir
    locale = userLocale
    localeDir = userLocaleDir
  end
  result = defaultAction(framework.user)
  if result ~= nil then return result, appLocale, locale end

  if str:sub(-3) == "..." or str:sub(-3) == "…" then
    result, appLocale, locale =
        delocalizedStringImpl(str:sub(1, -4), appid, params)
    if result ~= nil then
      return result .. str:sub(-3), appLocale, locale
    end
  end

  return nil, appLocale, locale
end

function delocalizedString(str, appid, params, force)
  local result, appLocale, locale =
      delocalizedStringImpl(str, appid, params, force)
  if appLocale == nil then return result end

  if appLocaleDir[appid] == nil then
    appLocaleDir[appid] = {}
  end
  if locale == nil then
    appLocaleDir[appid][appLocale] = false
    goto L_END_DUMP_DELOCALIZED
  else
    appLocaleDir[appid][appLocale] = locale
  end

  if deLocaleMap[appid] == nil then
    deLocaleMap[appid] = {}
  end
  if deLocaleMap[appid][appLocale] == nil then
    deLocaleMap[appid][appLocale] = {}
  end
  if result ~= nil then
    deLocaleMap[appid][appLocale][str] = result
  else
    deLocaleMap[appid][appLocale][str] = false
  end

  ::L_END_DUMP_DELOCALIZED::
  if not exists(localeTmpDir) then
    hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
  end
  hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
  hs.json.write(deLocaleMap, menuItemTmpFile, false, true)
  return result
end

electronLocale = function(app, localesPath)
  local appid = app:bundleID()
  local menubar = getMenuBarItems(app, true)
  if #menubar == 0 then return end
  local item = tfind(menubar, function(item)
    return delocMap.common[item.AXTitle] == nil
        and tindex(delocMap.common, item.AXTitle) == nil
  end)
  if item == nil then
    item = menubar[math.min(3, #menubar)]
  end

  local localeInfo = getElectronLocales(appid, localesPath)
  if localeInfo == nil then return end
  local locales = localeInfo['locale']
  local localeFiles = localeInfo['file']
  for _, locale in ipairs(locales) do
    local result = get(deLocaleMap, appid, locale, item.AXTitle)
    if result ~= nil then return locale end
  end
  for _, locale in ipairs(locales) do
    local matchedFiles = {}
    for _, file in ipairs(localeFiles) do
      if file:sub(1, #locale + 1) == locale .. '/' then
        tinsert(matchedFiles, file:sub(#locale + 2))
      end
    end
    local result = delocalizeByElectron(
        item.AXTitle, appid, locale, matchedFiles, localesPath)
    if result ~= nil then
      if deLocaleMap[appid] == nil then
        deLocaleMap[appid] = {}
      end
      if deLocaleMap[appid][locale] == nil then
        deLocaleMap[appid][locale] = {}
      end
      deLocaleMap[appid][locale][item.AXTitle] = result
      if not exists(localeTmpDir) then
        hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
      end
      hs.json.write(deLocaleMap, menuItemTmpFile, false, true)
      return locale
    end
  end
end

javaLocale = function(app, javahome, localesPath)
  local appid = app:bundleID()
  local menubar = getMenuBarItems(app, true)
  if #menubar == 0 then return end
  local item = tfind(menubar, function(item)
    return delocMap.common[item.AXTitle] == nil
        and tindex(delocMap.common, item.AXTitle) == nil
  end)
  if item == nil then
    item = menubar[math.min(3, #menubar)]
  end

  local localeFiles = getJavaLocales(appid, javahome, localesPath.java)
  if localeFiles == nil then return end
  local locales = tmap(localeFiles, function(file)
    local paths = strsplit(file, '/')
    local filename = paths[#paths]:gsub('-', '_')
    local splits = strsplit(filename, '_')
    if splits[#splits]:upper() == splits[#splits] then
      return splits[#splits - 1] .. '_' .. splits[#splits]
    else
      return splits[#splits]
    end
  end)
  for _, locale in ipairs(locales) do
    local result = get(deLocaleMap, appid, locale, item.AXTitle)
    if result ~= nil then return locale end
  end
  for i, file in ipairs(localeFiles) do
    local result = delocalizeByJava(
        item.AXTitle, appid, { file }, javahome)
    if result ~= nil then
      local locale = locales[i]
      if deLocaleMap[appid] == nil then
        deLocaleMap[appid] = {}
      end
      if deLocaleMap[appid][locale] == nil then
        deLocaleMap[appid][locale] = {}
      end
      deLocaleMap[appid][locale][item.AXTitle] = result
      if not exists(localeTmpDir) then
        hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
      end
      hs.json.write(deLocaleMap, menuItemTmpFile, false, true)
      return locale
    end
  end
end

-- some menu items are managed by system framework
-- the localized strings of their titles are managed here
-- should be use when localizing / delocalizing menu bar items
-- and delocalizing menu items whose keybindings contain 'fn'
function localizeCommonMenuItemTitles(locale, appid)
  if locale == 'en' or locale == 'English'
      or locale:sub(1, 3) == 'en-' or locale:sub(1, 3) == 'en_' then
    return
  end
  if locale == SYSTEM_LOCALE and appid ~= nil then return end

  local key = '__macos'
  local resourceDir = '/System/Library/Frameworks/AppKit.framework/Resources'
  local matchedLocale = get(appLocaleDir, key, locale)
  if matchedLocale == nil then
    matchedLocale = getDefaultMatchedLocale(locale, resourceDir, 'lproj')
    if appLocaleDir[key] == nil then
      appLocaleDir[key] = {}
    end
    appLocaleDir[key][locale] = matchedLocale
    if not exists(localeTmpDir) then
      hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
    end
    hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
  end

  local shouldSave = false
  local cachedDelocMap = get(deLocaleMap, key, matchedLocale) or {}
  local cachedLocMap = get(appLocaleMap, key, matchedLocale) or {}

  local target = appid or 'common'
  if delocMap[target] == nil then
    delocMap[target] = {}
  end
  if locMap[target] == nil then
    locMap[target] = {}
  end
  local targetDelocMap = delocMap[target]
  local targetLocMap = locMap[target]
  if appLocaleAssetBuffer[target] == nil
      or get(appLocaleDir, target, matchedLocale) ~= locale then
    appLocaleAssetBuffer[target] = {}
  end
  local localesDict = appLocaleAssetBuffer[target]

  for _, title in ipairs { 'File', 'View', 'Window', 'Help' } do
    local localizedTitle = cachedLocMap[title] or localizeByLoctable(
      title, resourceDir, 'MenuCommands', matchedLocale, localesDict)
    if localizedTitle ~= nil then
      targetDelocMap[localizedTitle] = title
      targetLocMap[title] = localizedTitle
      if cachedLocMap[title] == nil then
        cachedDelocMap[localizedTitle] = title
        cachedLocMap[title] = localizedTitle
        shouldSave = true
      end
    end
  end
  local title = 'Edit'
  local localizedTitle = cachedLocMap[title] or localizeByLoctable(
    title, resourceDir, 'InputManager', matchedLocale, localesDict)
  if localizedTitle ~= nil then
    targetDelocMap[localizedTitle] = title
    targetLocMap[title] = localizedTitle
    if cachedLocMap[title] == nil then
      cachedDelocMap[localizedTitle] = title
      cachedLocMap[title] = localizedTitle
      shouldSave = true
    end
  end

  local titleList = {
    'Enter Full Screen', 'Exit Full Screen',
  }
  if OS_VERSION >= OS.Sequoia then
    titleList = tconcat(titleList, {
      'Fill', 'Center', 'Move & Resize', 'Return to Previous Size',
      'Left', 'Right', 'Top', 'Bottom',
      'Left & Right', 'Right & Left', 'Top & Bottom', 'Bottom & Top',
      'Left & Quarters', 'Right & Quarters', 'Top & Quarters', 'Bottom & Quarters',
    })
  end
  for _, title in ipairs(titleList) do
    local localizedTitle = tindex(cachedDelocMap, title) or localizeByLoctable(
      title, resourceDir, 'MenuCommands', matchedLocale, localesDict)
    if localizedTitle ~= nil then
      delocMap.common[localizedTitle] = title
      if cachedDelocMap[localizedTitle] == nil then
        cachedDelocMap[localizedTitle] = title
        shouldSave = true
      end
    end
  end
  title = 'Emoji & Symbols'
  local localizedTitle = tindex(cachedDelocMap, title) or localizeByLoctable(
    title, resourceDir, 'InputManager', matchedLocale, localesDict)
  if localizedTitle ~= nil then
    delocMap.common[localizedTitle] = title
    if cachedDelocMap[localizedTitle] == nil then
      cachedDelocMap[localizedTitle] = title
      shouldSave = true
    end
  end

  if shouldSave then
    if deLocaleMap[key] == nil then
      deLocaleMap[key] = {}
    end
    if deLocaleMap[key][matchedLocale] == nil then
      deLocaleMap[key][matchedLocale] = cachedDelocMap
    else
      deLocaleMap[key][matchedLocale] =
          tconcat(deLocaleMap[key][matchedLocale], cachedDelocMap)
    end
    if appLocaleMap[key] == nil then
      appLocaleMap[key] = {}
    end
    if appLocaleMap[key][matchedLocale] == nil then
      appLocaleMap[key][matchedLocale] = cachedLocMap
    else
      appLocaleMap[key][matchedLocale] =
          tconcat(appLocaleMap[key][matchedLocale], cachedLocMap)
    end
    if not exists(localeTmpDir) then
      hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
    end
    hs.json.write(appLocaleMap, localeTmpFile, false, true)
    hs.json.write(deLocaleMap, menuItemTmpFile, false, true)
  end
end
localizeCommonMenuItemTitles(SYSTEM_LOCALE)

local menuItemLocaleFilePatterns = {
  "(.-)MainMenu(.-)", "Menu", "MenuBar", "MenuItems",
}

function delocalizedMenuItem(title, appid, params, system)
  if type(params) == 'boolean' then
    system = params params = nil
  end
  local defaultTitleMap = delocMap.common
  local titleMap = delocMap[appid]
  if titleMap ~= nil then
    if titleMap[title] ~= nil then
      return titleMap[title]
    end
  end
  if defaultTitleMap ~= nil then
    if defaultTitleMap[title] ~= nil then
      if titleMap == nil then
        delocMap[appid] = {}
        titleMap = delocMap[appid]
      end
      titleMap[title] = defaultTitleMap[title]
      return titleMap[title]
    end
  end
  if system then return end

  local newTitle
  if params == nil then
    newTitle = delocalizedString(title, appid,
                                 menuItemLocaleFilePatterns)
  elseif (#params == 0 and params.localeFile == nil) then
    local p = tcopy(params)
    p.localeFile = menuItemLocaleFilePatterns
    newTitle = delocalizedString(title, appid, p)
  end
  if newTitle == nil then
    newTitle = delocalizedString(title, appid, params, true)
  end
  if newTitle ~= nil then
    if titleMap == nil then
      delocMap[appid] = {}
      titleMap = delocMap[appid]
    end
    titleMap[title] = newTitle
  end
  return newTitle
end

function delocalizeMenuBarItems(itemTitles, appid, localeFile)
  if delocMap[appid] == nil then
    delocMap[appid] = {}
  end
  local defaultTitleMap = delocMap.common
  local titleMap = delocMap[appid]
  local result = {}
  local isValid = function(t)
    local splits = strsplit(t, ' ')
    return t:byte(1) <= 127
        and (t:len() < 2 or t:byte(2) <= 127)
        and (t:len() < 3 or t:byte(3) <= 127)
        and (#splits == 1 or splits[2]:byte(1) <= 127)
  end
  for _, title in ipairs(itemTitles) do
    -- remove titles starting with non-ascii characters
    if isValid(title) then
      tinsert(result, { title, title })
    else
      local delocTitle
      if titleMap[title] ~= nil then
        delocTitle = titleMap[title]
      elseif defaultTitleMap ~= nil and defaultTitleMap[title] ~= nil then
        delocTitle = defaultTitleMap[title]
        titleMap[title] = delocTitle
      elseif localeFile == nil then
        delocTitle = delocalizedString(title, appid,
                                       menuItemLocaleFilePatterns)
        if delocTitle == nil then
          delocTitle = delocalizedString(title, appid, nil, true)
        end
        titleMap[title] = delocTitle
      else
        delocTitle = delocalizedString(title, appid, localeFile)
        titleMap[title] = delocTitle
      end
      if delocTitle ~= nil then
        if not isValid(delocTitle) then
          if titleMap[delocTitle] ~= nil then
            delocTitle = titleMap[delocTitle]
          elseif defaultTitleMap ~= nil
              and defaultTitleMap[delocTitle] ~= nil then
            delocTitle = defaultTitleMap[delocTitle]
          end
        end
        if isValid(delocTitle) then
          tinsert(result, { title, delocTitle })
        end
      end
    end
  end
  return result
end

function localizedMenuBarItem(title, appid, params)
  if locMap[appid] ~= nil then
    local locTitle = locMap[appid][title]
    if locTitle ~= nil then
      -- "View" may be localized to different strings in the same app (e.g. WeChat)
      if title == 'View' and find(appid) then
        if find(appid):findMenuItem({ locTitle }) ~= nil then
          return locTitle
        end
      elseif type(locTitle) == 'table' then
        local app = find(appid)
        for _, t in ipairs(locTitle) do
          if app:findMenuItem({ t }) ~= nil then
            return t
          end
        end
      else
        return locTitle
      end
    end
  end
  if delocMap[appid] ~= nil then
    local locTitle = tindex(delocMap[appid], title)
    if locTitle ~= nil then return locTitle end
  end
  -- the app may pretend being localized (e.g. Visual Studio Code)
  local appLocale = applicationLocale(appid)
  if find(appid) then
    if type(params) == 'table' and params.locale ~= nil
        and params.locale ==
            matchLocale(appLocale, { params.locale }) then
      if find(appid):findMenuItem({ title }) ~= nil then
        return title
      end
    end
  end
  if appLocale == matchLocale(SYSTEM_LOCALE, { appLocale }) then
    local locTitle = locMap.common[title]
    if locTitle ~= nil then
      if (title == 'View' or title == 'Edit') and find(appid) then
        if find(appid):findMenuItem({ locTitle }) ~= nil then
          return locTitle
        end
      else
        return locTitle
      end
    end
  end

  local locTitle
  if params == nil then
    locTitle = localizedString(title, appid,
                               menuItemLocaleFilePatterns)
  elseif (#params == 0 and params.localeFile == nil) then
    local p = tcopy(params)
    p.localeFile = menuItemLocaleFilePatterns
    locTitle = localizedString(title, appid, p)
  end
  if locTitle == nil then
    locTitle = localizedString(title, appid, params, true)
  end
  if locTitle ~= nil then
    if delocMap[appid] == nil then
      delocMap[appid] = {}
    end
    delocMap[appid][locTitle] = title
    if get(deLocaleMap[appid], appLocale, locTitle) ~= nil then
      deLocaleMap[appid][appLocale][locTitle] = title
      if not exists(localeTmpDir) then
        hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
      end
      hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
      hs.json.write(deLocaleMap, menuItemTmpFile, false, true)
    end
    return locTitle
  end
end

function applicationValidLocale(appid)
  local appLocale = applicationLocale(appid)
  local resourceDir, framework = getResourceDir(appid)
  local locale = getMatchedLocale(appid, appLocale,
      resourceDir, framework, appLocaleDir)
  return locale
end

function displayName(app)
  if app.name ~= nil then return app:name() end
  local appid = app  -- assume app is installed
  local basename = hs.application.nameForBundleID(appid)
  local appLocale = applicationLocale(appid)
  local appname = get(appLocaleMap, appid, appLocale, basename)
  if appname ~= nil then return appname end

  local resourceDir = hs.application.pathForBundleID(appid)
      .. "/Contents/Resources"
  local locale = get(appLocaleDir, appid, appLocale)
  if locale == false then return basename end
  if locale == nil or not exists(resourceDir .. "/" .. locale .. ".lproj") then
    local shouldSave = locale == nil
    locale = getDefaultMatchedLocale(appLocale, resourceDir, 'lproj')
    if shouldSave then
      if appLocaleDir[appid] == nil then
        appLocaleDir[appid] = {}
      end
      appLocaleDir[appid][appLocale] = locale or false
      if not exists(localeTmpDir) then
        hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
      end
      hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
    end
    if locale == nil then return basename end
  end
  if exists(resourceDir .. '/InfoPlist.loctable') then
    appname = localizeByLoctable('CFBundleDisplayName',
                                 resourceDir, 'InfoPlist', locale)
        or localizeByLoctable('CFBundleName',
                              resourceDir, 'InfoPlist', locale)
  else
    local localeDir = resourceDir .. "/" .. locale .. ".lproj"
    if exists(localeDir .. '/InfoPlist.strings') then
      jsonDict = parseStringsFile(localeDir .. '/InfoPlist.strings')
      appname = jsonDict['CFBundleDisplayName'] or jsonDict['CFBundleyName']
    end
  end

  if appname == nil then appname = basename end
  if appLocaleMap[appid] == nil then
    appLocaleMap[appid] = {}
  end
  if appLocaleMap[appid][appLocale] == nil then
    appLocaleMap[appid][appLocale] = {}
  end
  appLocaleMap[appid][appLocale][basename] = appname
  hs.json.write(appLocaleMap, localeTmpFile, false, true)

  return appname
end

-- helpers for click menubar to the right

function leftClick(point, obj)
  if point.AXPosition ~= nil then
    point = hs.geometry.point {
      point.AXPosition.x + point.AXSize.w / 2,
      point.AXPosition.y + point.AXSize.h / 2
    }
  elseif point.x == nil then
    point = hs.geometry.point(point)
  end
  if obj ~= nil then
    local appHere = hs.axuielement.systemElementAtPosition(point)
    while appHere ~= nil and appHere.AXParent ~= nil do
      appHere = appHere.AXParent
    end
    if appHere then
      local appid = appHere:asHSApplication():bundleID()
      local targetApp = obj.application and obj:application() or obj
      if appid ~= targetApp:bundleID() then return false end
    end
  end
  hs.eventtap.leftClick(point)
  return true
end

function leftClickAndRestore(point, obj, delay)
  if type(obj) == 'number' then
    delay = obj obj = nil
  end
  local mousePosition = hs.mouse.absolutePosition()
  if leftClick(point, obj) then
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

function rightClick(point, obj)
  if point.AXPosition ~= nil then
    point = hs.geometry.point {
      point.AXPosition.x + point.AXSize.w / 2,
      point.AXPosition.y + point.AXSize.h / 2
    }
  elseif point.x == nil then
    point = hs.geometry.point(point)
  end
  if obj ~= nil then
    local appHere = hs.axuielement.systemElementAtPosition(point)
    while appHere ~= nil and appHere.AXParent ~= nil do
      appHere = appHere.AXParent
    end
    if appHere then
      local appid = appHere:asHSApplication():bundleID()
      local targetApp = obj.application and obj:application() or obj
      if appid ~= targetApp:bundleID() then return false end
    end
  end
  hs.eventtap.rightClick(point)
  return true
end

function rightClickAndRestore(point, obj, delay)
  if type(obj) == 'number' then
    delay = obj obj = nil
  end
  local mousePosition = hs.mouse.absolutePosition()
  if rightClick(point, obj) then
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

function loadStatusItemsAutosaveName(app)
  local appid = app:bundleID()
  local preferredPositions = {}
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
          tinsert(preferredPositions, { k:sub(prefix_len + 1), tonumber(v) })
        end
      end
    else
      errorReadingDefaults = true
    end
  end
  if #preferredPositions == 0 then
    plistPath = hs.fs.pathToAbsolute(strfmt(
        "~/Library/Preferences/%s.plist", appid))
    if plistPath ~= nil then
      defaults = hs.plist.read(plistPath)
      if defaults then
        local prefix_len = #prefix
        for k, v in pairs(defaults) do
          if k:sub(1, prefix_len) == prefix then
            tinsert(preferredPositions, { k:sub(prefix_len + 1), tonumber(v) })
            found = true
          end
        end
      else
        errorReadingDefaults = true
      end
    end
  end
  if #preferredPositions == 0 and errorReadingDefaults then
    local records = hs.execute(strfmt([[
      defaults read %s | grep '"%s'
    ]], app:bundleID() or app:name(), prefix))
    records = strsplit(records, '\n')
    records[#records] = nil
    for _, r in ipairs(records) do
      r = r:sub(r:find('"') + 1)
      local items = strsplit(r, ' ')
      local name = items[4]:sub(1, #items[4] - 1)
      local position = tonumber(items[6]:sub(1, #items[6] - 1))
      tinsert(preferredPositions, { name, position })
    end
  end

  if app:bundleID() == 'com.apple.controlcenter' then
    local enabledItems = {}
    local visiblePrefix = "NSStatusItem Visible "
    local prefix_len = #visiblePrefix
    for k, v in pairs(defaults) do
      if v == true and k:sub(1, prefix_len) == visiblePrefix then
        tinsert(enabledItems, k:sub(prefix_len + 1))
      end
    end
    tinsert(preferredPositions, { "Clock", 1 })
    preferredPositions = tifilter(preferredPositions, function(p)
      return tcontain(enabledItems, p[1])
    end)
  end

  local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
  local positions = {}
  for i, item in ipairs(menuBarItems) do
    tinsert(positions, { i, item.AXPosition.x })
  end

  if #preferredPositions ~= #positions then return end
  table.sort(preferredPositions, function(r1, r2)
    return r1[2] < r2[2]
  end)
  table.sort(positions, function(r1, r2)
    return r1[2] > r2[2]
  end)

  local map = {}
  for i, r in ipairs(positions) do
    map[r[1]] = preferredPositions[i][1]
    map[preferredPositions[i][1]] = r[1]
  end
  return map
end

local function showHiddenMenuBarItems(manager)
  local icon = getc(toappui(manager), AX.MenuBar, -1, AX.MenuBarItem, 1)
  if icon then
    leftClickAndRestore(icon)
  end
  return false
end

local function activateMenuBarItem(menuBarItem, click)
  -- note: some apps do not react to AX.Press, you have to click them.
  if click == "right-click" then
    rightClickAndRestore(menuBarItem)
  elseif click then
    leftClickAndRestore(menuBarItem)
  else
    menuBarItem:performAction(AX.Press)
  end
end

MENUBAR_MANAGER_SHOW = {
  ["com.surteesstudios.Bartender"] = function(_, appid, index, map, click)
    if type(index) == 'number' then
      map = map or loadStatusItemsAutosaveName(find(appid))
      index = map and map[index] or "Item-" .. tostring(index - 1)
    end
    local rightClick = click == "right-click"
    hs.osascript.applescript(strfmt([[
      tell application id "com.surteesstudios.Bartender"
        activate "%s-%s" %s
      end
    ]], appid, index, rightClick and "with right click" or ""))
    return true
  end,

  ["com.HyperartFlow.Barbee"] = function(_, appid, index, map)
    if type(index) == 'number' then
      map = map or loadStatusItemsAutosaveName(find(appid))
      index = map and map[index] or "Item-" .. tostring(index - 1)
    end
    -- fixme: below script will force `Barbee` to kill itself
    hs.osascript.applescript(strfmt([[
      tell application id "com.HyperartFlow.Barbee"
        show item "%s-%s"
      end
    ]], appid, index))
    return true
  end,

  ["com.jordanbaird.Ice"] = function(manager, appid, index)
    local icon = getc(toappui(manager), AX.MenuBar, -1, AX.MenuBarItem, 1)
    if icon then
      leftClickAndRestore(icon)
    end

    local useIceBar = hs.execute(
      [[defaults read com.jordanbaird.Ice UseIceBar | tr -d '\n']])
    if useIceBar == "0" then
      return false
    end

    -- fixme: search and click
    return true
  end,

  ["cn.better365.iBar"] = function(manager, appid, index, map, click)
    local icon = getc(toappui(manager), AX.MenuBar, -1, AX.MenuBarItem, 1)
    if not icon then return end
    local app = find(appid)

    local isAdvancedMode = hs.execute(
      [[defaults read cn.better365.iBar advancedMode | tr -d '\n']])
    if isAdvancedMode ~= "1" then
      if type(index) == 'string' then
        map = map or loadStatusItemsAutosaveName(app)
        index = map and map[index]
        if index == nil then return true end
      end
      hs.eventtap.event.newMouseEvent(
          hs.eventtap.event.types.mouseMoved, uioffset(icon, {-10, 10})):post()
      hs.timer.doAfter(0.2, function()
        hs.eventtap.event.newMouseEvent(
            hs.eventtap.event.types.mouseMoved, uioffset(icon, {-20, 10})):post()
        hs.timer.doAfter(3, function()
          local menuBarItem = getc(toappui(app), AX.MenuBar, -1,
              AX.MenuBarItem, index or 1)
          if menuBarItem then
            hs.timer.doAfter(0, bind(activateMenuBarItem, menuBarItem, click))
          end
        end)
      end)
      return true
    end

    leftClickAndRestore(icon)
    if type(index) == 'number' then
      map = map or loadStatusItemsAutosaveName(find(appid))
      index = map and map[index] or "Item-" .. tostring(index - 1)
    end
    hs.timer.waitUntil(
      function()
        local win = manager:focusedWindow()
        return win ~= nil and win:title() == "iBarmenu"
            and win:subrole() == AX.SystemFloatingWindow
      end,
      function()
        local winUI = towinui(manager:focusedWindow())
        if index ~= nil then
          local itemRepr = index .. ' >>> ' .. appid
          for _, bt in ipairs(getc(winUI, AX.Button)) do
            if bt.AXIdentifier:sub(#bt.AXIdentifier - #itemRepr + 1)
                == itemRepr then
              bt:performAction(AX.Press)
              break
            end
          end
        else
          local appItems = {}
          for i, bt in ipairs(getc(winUI, AX.Button)) do
            if bt.AXIdentifier:find(appid) then
              tinsert(appItems, i)
            end
          end
          if #appItems == 1 then
            local bt = getc(winUI, AX.Button, appItems[1])
            bt:performAction(AX.Press)
          end
        end
      end
    )
    return true
  end,

  ["net.matthewpalmer.Vanilla"] = function(manager)
    local icon = tfind(getc(toappui(manager), AX.Window), function(win)
      return #win == 1 and win[1].AXRole == AX.Image
    end)
    if icon then
      leftClickAndRestore(icon)
    end
    return false
  end,

  "com.dwarvesv.minimalbar",
  "com.mortennn.Dozer",
}

local function getValidMenuBarManager()
  local leftmostHorizontal = 0
  foreach(hs.screen.allScreens(), function(screen)
    leftmostHorizontal = math.min(screen:fullFrame().x, leftmostHorizontal)
  end)
  for appid, fn in pairs(MENUBAR_MANAGER_SHOW) do
    if type(fn) == 'string' then
      appid = fn
    end
    local app = find(appid)
    if app then
      local maxX  -- incase it is hidden by other menu bar managers
      if appid == "net.matthewpalmer.Vanilla" then
        local icon = tfind(getc(toappui(app), AX.Window), function(win)
          return #win == 1 and win[1].AXRole == AX.Image
        end)
        maxX = icon.AXPosition.x
      else
        maxX = leftmostHorizontal - 1
        foreach(getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem),
            function(item) maxX = math.max(maxX, item.AXPosition.x) end)
      end
      if maxX > leftmostHorizontal then
        return app
      end
    end
  end
end

function hiddenByMenuBarManager(app, index, map)
  local manager = getValidMenuBarManager()
  if manager == nil then return false end
  if type(index) == 'string' then
    map = map or loadStatusItemsAutosaveName(app)
    index = map and map[index]
    if index == nil then return false end
  end
  local menuBarItem = getc(toappui(app), AX.MenuBar, -1,
      AX.MenuBarItem, index or 1)
  local leftmostHorizontal = 0
  foreach(hs.screen.allScreens(), function(screen)
    leftmostHorizontal = math.min(screen:fullFrame().x, leftmostHorizontal)
  end)
  return menuBarItem.AXPosition.x < leftmostHorizontal, manager, map
end

function clickRightMenuBarItem(appid, menuItemPath, show)
  local menuBarId, app
  if type(appid) == 'table' then
    menuBarId = appid[2] appid = appid[1]
  end
  if type(appid) == 'string' then
    app = find(appid)
    if app == nil then return false end
  else
    app = appid appid = app:bundleID()
  end

  if type(menuItemPath) ~= 'table' then
    menuItemPath = { menuItemPath }
  end
  if #menuItemPath == 0 and show == nil then
    show = true
  end

  local menuBarIdx = menuBarId
  local map
  if type(menuBarIdx) == 'string' then
    map = loadStatusItemsAutosaveName(app)
    menuBarIdx = map and map[menuBarIdx]
    if menuBarIdx == nil then return false end
  end
  local menuBarItem = getc(toappui(app), AX.MenuBar, -1,
      AX.MenuBarItem, menuBarIdx or 1)
  if menuBarItem == nil then return false end

  if show then
    local click = type(show) == "string" and show or false
    local hidden, manager
    hidden, manager, map = hiddenByMenuBarManager(app, menuBarId, map)
    if hidden then
      assert(manager)
      local showFunc = MENUBAR_MANAGER_SHOW[manager:bundleID()]
          or bind(showHiddenMenuBarItems, manager)
      local done = showFunc(manager, appid, menuBarId or 1, map, click)
      if not done then
        if menuBarItem then
          hs.timer.doAfter(0.2, function()
            activateMenuBarItem(menuBarItem, click)
          end)
        else
          return false
        end
      end
    elseif menuBarItem then
      activateMenuBarItem(menuBarItem, click)
    else
      return false
    end
  end
  if #menuItemPath == 0 then return true end

  local menu = menuBarItem
  for _, item in ipairs(menuItemPath) do
    local parent = menu
    menu = getc(parent, AX.Menu, 1, AX.MenuItem, item)
    if menu == nil and type(item) == 'string' then
      local locItem = localizedString(item, appid)
      if locItem ~= nil then
        menu = getc(parent, AX.Menu, 1, AX.MenuItem, locItem)
      end
    end
    if menu == nil then return false end
  end

  menu:performAction(AX.Press)
  return true
end
