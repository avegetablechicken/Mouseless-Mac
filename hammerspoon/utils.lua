---@diagnostic disable: lowercase-global

function get(table, key, ...)
  if table == nil or key == nil then return table end
  return get(table[key], ...)
end

function getc(element, role, index, ...)
  if element == nil or (role == nil and index == nil) then return element end
  local children, child
  if role == nil and element.AXChildren ~= nil then
    children = element.AXChildren
  else
    children = element:childrenWithRole(role)
  end
  if index == nil then return children
  elseif type(index) == 'number' then
    if index < 0 then index = #children + index + 1 end
    child = children[index]
  elseif role == AX.StaticText or role == AX.TextField then
    child = hs.fnutils.find(children, function(c)
      return c.AXValue == index
    end)
  else
    child = hs.fnutils.find(children, function(c)
      return c.AXTitle == index
    end)
  end
  return getc(child, ...)
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

function activatedWindowIndex()
  if inFullscreenSpace() then
    local cnt = #hs.application.frontmostApplication():visibleWindows()
    if hs.application.frontmostApplication():bundleID() == "com.apple.finder" then
      cnt = cnt - 1
    end
    return cnt
  else
    return 1
  end
end

function aWinFor(app)
  local appid
  if type(app) == 'string' then appid = app
  else appid = app:bundleID() end
  return string.format(
      'window %d of (first application process whose bundle identifier is "%s")\n',
      activatedWindowIndex(), appid)
end

function menuBarVisible()
  if inFullscreenSpace() then
    local thisAppAutohide = hs.execute("defaults read "
        .. hs.application.frontmostApplication():bundleID() .. " AppleMenuBarVisibleInFullscreen | tr -d '\\n'")
    if thisAppAutohide == "0" then
      return false
    elseif thisAppAutohide == "" then
      local autohide = hs.execute("defaults read -globalDomain AppleMenuBarVisibleInFullscreen | tr -d '\\n'")
      if autohide == "0" then
        return false
      end
    end
  end
  return true
end

function showMenuItemWrapper(fn)
  return function()
    if menuBarVisible() then
      fn()
    else
      hs.eventtap.keyStroke('fn⌃', 'F2')
      hs.timer.doAfter(0.1, function() fn() end)
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
  table.insert(targetMenuItem, locStr or menuItemTitle[1])
  for i=2,#menuItemTitle do
    locStr = localizedString(menuItemTitle[i], app:bundleID(), params)
    if type(locStr) == 'table' then
      for _, s in ipairs(locStr) do
        table.insert(targetMenuItem, s)
        if app:findMenuItem(targetMenuItem) then break
        else targetMenuItem[#targetMenuItem] = nil end
      end
    else
      table.insert(targetMenuItem, locStr or menuItemTitle[i])
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
    table.insert(targetMenuItem, locStr or menuItemTitle[1])
    for i=2,#menuItemTitle do
    locStr = localizedString(menuItemTitle[i], app:bundleID(), params)
    if type(locStr) == 'table' then
      for _, s in ipairs(locStr) do
        table.insert(targetMenuItem, s)
        if app:findMenuItem(targetMenuItem) then break
        else targetMenuItem[#targetMenuItem] = nil end
      end
    else
      table.insert(targetMenuItem, locStr or menuItemTitle[i])
    end
  end
    return app:selectMenuItem(targetMenuItem)
  end
end

local function findMenuItemByKeyBindingImpl(mods, key, menuItem)
  if menuItem.AXChildren == nil then return end
  for _, subItem in ipairs(menuItem.AXChildren[1]) do
    local cmdChar = subItem.AXMenuItemCmdChar
    if cmdChar ~= "" and (string.byte(cmdChar, 1) <= 32 or string.byte(cmdChar, 1) > 127) then
      cmdChar = SPECIAL_KEY_SIMBOL_MAP[key] or cmdChar
    end
    if (cmdChar == key
        or (subItem.AXMenuItemCmdGlyph ~= "" and hs.application.menuGlyphs[subItem.AXMenuItemCmdGlyph] == key))
        and #subItem.AXMenuItemCmdModifiers == #mods then
      local match = true
      for _, mod in ipairs(mods) do
        if not hs.fnutils.contains(subItem.AXMenuItemCmdModifiers, mod) then
          match = false
          break
        end
      end
      if match then
        return { subItem.AXTitle }, subItem.AXEnabled
      end
    end
    local menuItemPath, enabled = findMenuItemByKeyBindingImpl(mods, key, subItem)
    if menuItemPath ~= nil then
      table.insert(menuItemPath, 1, subItem.AXTitle)
      return menuItemPath, enabled
    end
  end
end

local modifierSymbolMap = {
  command = 'cmd',
  control = 'ctrl',
  option = 'alt',
  ["⌘"] = 'cmd',
  ["⌃"] = 'ctrl',
  ["⌥"] = 'alt',
  ["⇧"] = 'shift'
}

function findMenuItemByKeyBinding(app, mods, key, menuItems)
  if menuItems == nil then
    menuItems = app:getMenuItems()
  end
  if menuItems == nil then return end
  if mods == '' then mods = {} end
  if type(mods) == 'string' and string.byte(mods, 1, 1) < 127 then
    mods = { mods }
  end
  local newMods = {}
  if type(mods) == 'string' then
    for i=1,utf8.len(mods) do
      local mod = string.sub(mods, i*3-2, i*3)
      table.insert(newMods, modifierSymbolMap[mod] or mod)
    end
  else
    for _, mod in ipairs(mods) do
      table.insert(newMods, modifierSymbolMap[mod] or mod)
    end
  end
  for i=#menuItems,1,-1 do
    local menuItem = menuItems[i]
    local menuItemPath, enabled = findMenuItemByKeyBindingImpl(newMods, key, menuItem)
    if menuItemPath ~= nil then
      table.insert(menuItemPath, 1, menuItem.AXTitle)
      return menuItemPath, enabled
    end
  end
end

local function filterParallels(apps)
  return hs.fnutils.find(apps, function(app)
    return string.find(app:bundleID(), "com.parallels") == nil
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

local localeTmpDir = hs.fs.temporaryDirectory() .. 'org.hammerspoon.Hammerspoon/locale/'

local locMap, delocMap = {}, {}
localizationMapLoaded = { menubar = {}, strings = {} }
local localizationFrameworks = {}
if hs.fs.attributes("config/localization.json") ~= nil then
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
          table.insert(dict[v], k)
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
          table.insert(dict[v], k)
        end
      end
    end
  end
  delocMap = hs.fnutils.copy(localizationMapLoaded['menubar'])
  locMap = hs.fnutils.copy(localizationMapLoaded['strings'])
end
function resetLocalizationMap(appid)
  if localizationMapLoaded[appid] ~= nil then
    delocMap[appid] = hs.fnutils.copy(localizationMapLoaded[appid]['menubar'])
    locMap[appid] = hs.fnutils.copy(localizationMapLoaded[appid]['strings'])
  else
    locMap[appid] = nil
    delocMap[appid] = nil
  end
end

delocMap.common = {}
locMap.common = {}

local function systemLocales()
  local locales, ok = hs.execute("defaults read -globalDomain AppleLanguages | tr -d '()\" \\n'")
  return hs.fnutils.split(locales, ',')
end
SYSTEM_LOCALE = systemLocales()[1]

function applicationLocale(appid)
  local locales = hs.execute(
      string.format("defaults read %s AppleLanguages | tr -d '()\" \\n'", appid))
  if locales ~= "" then
    return hs.fnutils.split(locales, ',')[1]
  else
    return SYSTEM_LOCALE
  end
end

local function dirNotExistOrEmpty(dir)
  if hs.fs.attributes(dir) == nil then return true end
  for file in hs.fs.dir(dir) do
    if string.sub(file, 1, 1) ~= '.' then return false end
  end
  return true
end

local function getResourceDir(appid, frameworkName)
  if frameworkName == nil then
    frameworkName = localizationFrameworks[appid]
  end
  local resourceDir
  local framework = {}
  local appContentPath
  if appid ~= '__macos' then
    appContentPath = hs.application.pathForBundleID(appid) .. "/Contents"
  end
  if appContentPath and hs.fs.attributes(appContentPath) == nil then
    resourceDir = hs.application.pathForBundleID(appid) .. "/WrappedBundle/.."
  elseif frameworkName ~= nil then
    local frameworkDir
    if hs.fs.attributes(frameworkName) ~= nil then
      frameworkDir = frameworkName
    else
      if appContentPath ~= nil
          and hs.fs.attributes(appContentPath .. "/Resources/app.asar") ~= nil then
        resourceDir = appContentPath .. "/Resources"
        framework.electron = frameworkName
        goto END_GET_RESOURCE_DIR
      end

      local jimage, status = hs.execute(string.format(
        "find '%s' -type f -name jimage | tr -d '\\n'", appContentPath))
      if status and jimage ~= "" then
        resourceDir = jimage:sub(1, #jimage - #'/bin/jimage')
        framework.java = frameworkName
        goto END_GET_RESOURCE_DIR
      end

      frameworkDir = hs.execute(string.format(
          "find '%s' -type d -name '%s' | head -n 1 | tr -d '\\n'", appContentPath, frameworkName))
      if frameworkDir == "" then
        for _, searchDir in ipairs {
          '/System/Library/Frameworks',
          '/System/Library/PrivateFrameworks',
          '/System/iOSSupport/System/Library/PrivateFrameworks',
        } do
          if hs.fs.attributes(searchDir .. '/' .. frameworkName) ~= nil then
            frameworkDir = searchDir .. '/' .. frameworkName
            break
          end
        end
      end
      if frameworkDir == "" then return nil, {} end
    end
    if hs.fs.attributes(frameworkDir .. "/Contents") == nil then
      resourceDir = frameworkDir .. "/Resources"
    else
      resourceDir = frameworkDir .. "/Contents/Resources"
    end
    framework.user = true
  else
    if hs.fs.attributes(appContentPath .. "/Frameworks") ~= nil then
      local chromiumDirs, status = hs.execute(string.format(
        "find '%s' -type f -path '*/Resources/*/locale.pak'" ..
        " | awk -F'/Versions/' '{print $1}' | uniq",
        appContentPath .. "/Frameworks"))
      if status and chromiumDirs:sub(1, -2) ~= "" then
        chromiumDirs = hs.fnutils.split(chromiumDirs:sub(1, -2), '\n')
        if #chromiumDirs == 1 then
          local prefix_len = string.len(appContentPath .. "/Frameworks/")
          if not chromiumDirs[1]:sub(prefix_len + 1):find('/') then
            resourceDir = chromiumDirs[1] .. "/Resources"
            framework.chromium = true
            goto END_GET_RESOURCE_DIR
          end
        end
      end
    end

    if hs.fs.attributes(appContentPath .. "/Resources/qt.conf") ~= nil then
      resourceDir = appContentPath .. "/Resources"
      framework.qt = true
      goto END_GET_RESOURCE_DIR
    end

    local monoLocaleDirs, status = hs.execute(string.format(
        "find '%s' -type f -path '*/locale/*/LC_MESSAGES/*.mo'" ..
        " | awk -F'/locale/' '{print $1}' | uniq", appContentPath))
    if status and monoLocaleDirs:sub(1, -2) ~= "" then
      monoLocaleDirs = hs.fnutils.split(monoLocaleDirs:sub(1, -2), '\n')
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
  if hs.fs.attributes(resourceDir) == nil then return nil, {} end
  return resourceDir, framework
end

local function getBestMatchedLocale(appLocale, locales, combineExtras)
  local bestMatch, bestScore = {}, -1
  for _, locale in ipairs(locales) do
    if locale.scriptCode == appLocale.scriptCode
        and locale.countryCode == appLocale.countryCode then
      bestMatch = locale
      break
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
    elseif combineExtras and score == bestScore
        and locale.scriptCode == bestMatch.scriptCode
        and locale.countryCode == bestMatch.countryCode then
      if type(bestMatch.extra) == 'string' then
        bestMatch.extra = { bestMatch.extra }
      end
      table.insert(bestMatch.extra, locale.extra)
    end
  end
  return bestMatch
end

function getMatchedLocale(appLocale, localeSource, mode)
  local localDetails = hs.host.locale.details(appLocale)
  local language = localDetails.languageCode
  local script = localDetails.scriptCode
  local country = localDetails.countryCode
  if script == nil then
    local localeItems = hs.fnutils.split(appLocale, '-')
    if #localeItems == 3 or (#localeItems == 2 and localeItems[2] ~= country) then
      script = localeItems[2]
    end
  end
  if type(localeSource) == 'string' then
    local resourceDir = localeSource
    localeSource = {}
    for file in hs.fs.dir(resourceDir) do
      table.insert(localeSource, file)
    end
  end
  local matchedLocales = {}
  for _, loc in ipairs(localeSource) do
    if (mode == 'lproj' and loc:sub(-6) == ".lproj")
        or mode == nil then
      local locale = mode and loc:sub(1, -7) or loc
      local newLocale = string.gsub(locale, '_', '-')
      local thisLocale = hs.host.locale.details(newLocale)
      local thisLanguage = thisLocale.languageCode
      local thisScript = thisLocale.scriptCode
      local thisCountry = thisLocale.countryCode
      if thisScript == nil then
        local localeItems = hs.fnutils.split(newLocale, '-')
        if #localeItems == 3 or (#localeItems == 2 and localeItems[2] ~= thisCountry) then
          thisScript = localeItems[2]
        end
      end
      if thisLanguage == 'zh' or thisLanguage == 'yue' then
        if thisCountry == 'HK' or thisCountry == 'MO' or thisCountry == 'TW' then
          if thisScript == nil then thisScript = 'Hant' end
        elseif thisCountry == 'CN' or thisCountry == 'SG' then
          if thisScript == nil then thisScript = 'Hans' end
        end
      end
      if thisLanguage == language
          and (script == nil or thisScript == nil or thisScript == script) then
        table.insert(matchedLocales, {
          scriptCode = thisScript, countryCode = thisCountry, extra = locale
        })
      end
    end
  end

  local bestMatch = getBestMatchedLocale(localDetails, matchedLocales)
  return bestMatch.extra
end

local function getQtMatchedLocale(appLocale, resourceDir)
  local localDetails = hs.host.locale.details(appLocale)
  local language = localDetails.languageCode
  local script = localDetails.scriptCode
  local country = localDetails.countryCode
  if script == nil then
    local localeItems = hs.fnutils.split(appLocale, '-')
    if #localeItems == 3 or (#localeItems == 2 and localeItems[2] ~= country) then
      script = localeItems[2]
    end
  end
  local dirs = { resourceDir }
  for file in hs.fs.dir(resourceDir) do
    if hs.fs.attributes(resourceDir .. '/' .. file, 'mode') == 'directory' then
      table.insert(dirs, resourceDir .. '/' .. file)
    end
  end
  local matchedLocales = {}
  for _, dir in ipairs(dirs) do
    for file in hs.fs.dir(dir) do
      if file:sub(-3) == '.qm' then
        local lowerFile = file:sub(1, -4):lower()
        local fileSplits = hs.fnutils.split(lowerFile:gsub('_', '-'), '-')
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
            if script == nil or thisScript == nil or thisScript == script then
              if language == 'zh' or language == 'yue' then
                if thisCountry == 'HK' or thisCountry == 'MO' or thisCountry == 'TW' then
                  if thisScript == nil then thisScript = 'Hant' end
                elseif thisCountry == 'CN' or thisCountry == 'SG' then
                  if thisScript == nil then thisScript = 'Hans' end
                end
              end
              table.insert(matchedLocales, {
                scriptCode = thisScript, countryCode = thisCountry, extra = dir .. '/' .. file,
              })
            end
          end
        end
      end
    end
  end

  if #matchedLocales == 0 then return end
  local bestMatch = getBestMatchedLocale(localDetails, matchedLocales, true)
  local matchedLocale = language
  if bestMatch.script ~= nil then matchedLocale = matchedLocale .. '_' .. bestMatch.script end
  if bestMatch.country ~= nil then matchedLocale = matchedLocale .. '_' .. bestMatch.country end
  return matchedLocale, bestMatch.extra
end

local jimageLocales = {}
local function getJavaMatchedLocale(appid, appLocale, javehome, path)
  local tmpBaseDir = localeTmpDir .. appid
  local cmd = javehome .. '/bin/jimage'
  local modulePath = javehome .. '/lib/modules'
  local localeFiles = jimageLocales[appid]
  if localeFiles == nil then
    localeFiles = {}
    local localesFile = tmpBaseDir .. '/locales.json'
    if hs.fs.attributes(localesFile) ~= nil then
      localeFiles = hs.json.read(localesFile)
    else
      local result, ok = hs.execute(string.format(
        [[%s list --include 'regex:.*%s/.*\.properties' '%s']],
        cmd, path, modulePath))
      if ok then
        local module
        for _, line in ipairs(hs.fnutils.split(result, '\n')) do
          if line:sub(1, 8) == "Module: " then
            module = line:sub(9)
          elseif line == "" then
            module = nil
          elseif module then
            table.insert(localeFiles, module .. '/' .. line:sub(1, -12):gsub('%s', ''))
          end
        end
        if dirNotExistOrEmpty(tmpBaseDir) then
          hs.execute(string.format("mkdir '%s'", tmpBaseDir))
        end
        hs.json.write(localeFiles, localesFile)
      else
        return
      end
    end
    jimageLocales[appid] = localeFiles
  end

  local localDetails = hs.host.locale.details(appLocale)
  local language = localDetails.languageCode
  local script = localDetails.scriptCode
  local country = localDetails.countryCode
  if script == nil then
    local localeItems = hs.fnutils.split(appLocale, '-')
    if #localeItems == 3 or (#localeItems == 2 and localeItems[2] ~= country) then
      script = localeItems[2]
    end
  end
  local matchedLocales = {}
  for _, file in ipairs(localeFiles) do
    local pathSplits = hs.fnutils.split(file, '/')
    local fileStem = pathSplits[#pathSplits]
    local fileSplits = hs.fnutils.split(fileStem:gsub('-', '_'), '_')
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
        if script == nil or thisScript == nil or thisScript == script then
          if language == 'zh' or language == 'yue' then
            if thisCountry == 'HK' or thisCountry == 'MO' or thisCountry == 'TW' then
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
          table.insert(matchedLocales, {
            scriptCode = thisScript, countryCode = thisCountry, extra = locale
          })
        end
      end
    end
  end

  if #matchedLocales == 0 then return end
  local bestMatch = getBestMatchedLocale(localDetails, matchedLocales, true)
  local matchedLocale = bestMatch.extra
  local matchedFiles = hs.fnutils.ifilter(localeFiles, function(f)
    return f:sub(-#matchedLocale) == matchedLocale
  end)
  return matchedLocale, matchedFiles
end

local electronLocales = {}
local function getElectronMatchedLocale(appid, appLocale, localesPath)
  local locales, localeFiles = {}, {}
  if electronLocales[appid] == nil then
    local tmpBaseDir = localeTmpDir .. appid
    local localesFile = tmpBaseDir .. '/locales.json'
    if hs.fs.attributes(localesFile) ~= nil then
      electronLocales[appid] = hs.json.read(localesFile)
    else
      local path = hs.application.pathForBundleID(appid)
          .. '/Contents/Resources/app.asar'
      local result, ok = hs.execute(string.format(
        [[npx @electron/asar list "%s" | grep "^/%s/" | cut -c%d-]],
        path, localesPath, #localesPath + 3),
      true)
      if ok then
        result = hs.fnutils.split(result, '\n')
        result[#result] = nil
        for _, p in ipairs(result) do
          if p:find('/') then
            if p:sub(-5) == '.json' then
              table.insert(localeFiles, p:sub(1, -6))
            end
          else
            table.insert(locales, p)
          end
        end
        electronLocales[appid] = { locale = locales, file = localeFiles }
        if dirNotExistOrEmpty(tmpBaseDir) then
          hs.execute(string.format("mkdir '%s'", tmpBaseDir))
        end
        hs.json.write(electronLocales[appid], localesFile)
      else
        return
      end
    end
  end
  locales = electronLocales[appid]['locale']
  localeFiles = electronLocales[appid]['file']
  local locale = getMatchedLocale(appLocale, locales)
  if locale == nil then return end

  local matchedFiles = {}
  for _, file in ipairs(localeFiles) do
    if file:sub(1, #locale + 1) == locale .. '/' then
      table.insert(matchedFiles, file:sub(#locale + 2))
    end
  end
  return locale, matchedFiles
end

-- assume base locale is English (not always the situation)
local baseLocales = {
  "Base", "en", "English"
}
local function getBaseLocaleDirs(resourceDir)
  local dirs = {}
  for _, locale in ipairs(baseLocales) do
    local localeDir = resourceDir .. '/' .. locale
    if hs.fs.attributes(localeDir) ~= nil then
      table.insert(dirs, localeDir)
    else
      localeDir = localeDir .. '.lproj'
      if hs.fs.attributes(localeDir) ~= nil then
        table.insert(dirs, localeDir)
      end
    end
  end
  if #dirs == 0 then table.insert(dirs, resourceDir) end
  return dirs
end

-- basically should only be called when base locale is English,
-- but actually it can't be guranteed
local extraEnglishLocales = {
  "en_US", "en_GB"
}
local function appendExtraEnglishLocaleDirs(resourceDir, baseDirs)
  local dirs = hs.fnutils.copy(baseDirs)
  for _, locale in ipairs(extraEnglishLocales) do
    local localeDir = resourceDir .. '/' .. locale
    if hs.fs.attributes(localeDir) ~= nil then
      table.insert(dirs, localeDir)
    else
      localeDir = localeDir .. '.lproj'
      if hs.fs.attributes(localeDir) ~= nil then
        table.insert(dirs, localeDir)
      end
    end
  end
  return dirs
end

local function collectLocaleFiles(localeDir, option)
  local localeFiles = {}
  if option == nil then option = { strings = true, nib = true, storyboardc = true } end
  for file in hs.fs.dir(localeDir or {}) do
    if option.strings and file:sub(-8) == ".strings" then
      table.insert(localeFiles, file:sub(1, -9))
    elseif option.loctable and file:sub(-9) == ".loctable" then
      table.insert(localeFiles, file:sub(1, -10))
    elseif option.nib and file:sub(-4) == ".nib" then
      table.insert(localeFiles, file:sub(1, -5))
    elseif option.storyboardc and file:sub(-12) == ".storyboardc" then
      table.insert(localeFiles, file:sub(1, -13))
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
      if not hs.fnutils.contains(preferentialStringsFiles, file)
          and string.match(file, '^' .. p .. '$') then
        table.insert(preferentialStringsFiles, file)
      end
    end
  end
  for _, file in ipairs(localeFiles) do
    if not hs.fnutils.contains(preferentialStringsFiles, file) then
      table.insert(newStringsFiles, file)
    end
  end
  return newStringsFiles, preferentialStringsFiles
end

local function parseStringsFile(file, keepOrder, keepAll)
  if keepOrder == nil then keepOrder = true end
  local jsonStr = hs.execute(string.format("plutil -convert json -o - '%s'", file))
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
        table.insert(localesDict[v], k)
      end
    end
  end
  return localesDict
end

local function localizeByLoctableImpl(str, filePath, fileStem, locale, localesDict)
  if localesDict[fileStem] == nil then localesDict[fileStem] = {} end
  if localesDict[fileStem][str] ~= nil then
    return localesDict[fileStem][str]
  end

  local output, status = hs.execute(string.format(
      "/usr/bin/python3 scripts/loctable_localize.py '%s' '%s' %s",
      filePath, str, locale))
  if status and output ~= "" then
    localesDict[fileStem][str] = output
    return output
  end
end

local function localizeByLoctable(str, resourceDir, localeFile, loc, localesDict)
  if localeFile ~= nil then
    local fullPath = resourceDir .. '/' .. localeFile .. '.loctable'
    if hs.fs.attributes(fullPath) ~= nil then
      return localizeByLoctableImpl(str, fullPath, localeFile, loc, localesDict)
    end
  else
    local loctableFiles = collectLocaleFiles(resourceDir, { loctable = true })
    local preferentialLoctableFiles = {}
    if #loctableFiles > 10 then
      loctableFiles, preferentialLoctableFiles = filterPreferentialLocaleFiles(loctableFiles)
    end
    for _, file in ipairs(preferentialLoctableFiles) do
      local fullPath = resourceDir .. '/' .. file .. '.loctable'
      local result = localizeByLoctableImpl(str, fullPath, file, loc, localesDict)
      if result ~= nil then return result end
    end
    for _, file in ipairs(loctableFiles) do
      local fullPath = resourceDir .. '/' .. file .. '.loctable'
      local result = localizeByLoctableImpl(str, fullPath, file, loc, localesDict)
      if result ~= nil then return result end
    end
  end
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
  local jsonStr = hs.execute([[
    plutil -convert xml1 ']] .. file .. [[' -o /dev/stdout | \
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
        table.insert(localesDict[v], k)
      end
    end
  end
  return localesDict
end

local function parseNibFile(file, keepOrder, keepAll)
  if keepOrder == nil then keepOrder = true end
  local jsonStr = hs.execute([[
    /usr/bin/python3 scripts/nib_parse.py dump-json ']] .. file .. [[' -o /dev/stdout | \
    grep '"data": "' | sed 's/^.*"data": "//;s/"$//' | \
    awk 'BEGIN { printf("{"); first = 1 } /\.(title|label)$/ {
      key = $0;
      gsub("%", "%%", prev);
      if (!first) printf(", ");
      printf("\"" key "\": \"" prev "\"");
      first = 0;
    }
    { prev = $0 }
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
        table.insert(localesDict[v], k)
      end
    end
  end
  return localesDict
end

-- situation 1: "str" is a key in a strings file of target locale
-- situation 2: both base and target locales use strings files
-- situation 3: both base variant (e.g. en_US) and target locales use strings files
-- situation 4: both base and target locales use "*.title"-style keys, base locale uses NIB file & target locale uses strings files
-- situation 5: both base and target locales use "*.title"-style keys, base locale uses binary plist file & target locale uses strings files
local function localizeByStrings(str, localeDir, localeFile, localesDict, localesInvDict)
  local resourceDir = localeDir .. '/..'
  local searchFunc = function(str, files)
    if type(files) == 'string' then files = { files } end
    for _, fileStem in ipairs(files) do
      local jsonDict = localesDict[fileStem]
      if jsonDict == nil then
        if hs.fs.attributes(localeDir .. '/' .. fileStem .. '.strings') ~= nil then
          jsonDict = parseStringsFile(localeDir .. '/' .. fileStem .. '.strings')
        end
      end
      if jsonDict ~= nil and jsonDict[str] ~= nil then
        localesDict[fileStem] = jsonDict
        return jsonDict[str]
      end
    end
  end

  local stringsFiles = {}
  if localeFile ~= nil then
    local result = searchFunc(str, localeFile)
    if result ~= nil then return result end
  else
    stringsFiles = collectLocaleFiles(localeDir, { strings = true })
    local preferentialStringsFiles = {}
    if #stringsFiles > 10 then
      stringsFiles, preferentialStringsFiles = filterPreferentialLocaleFiles(stringsFiles)
    end
    local result = searchFunc(str, preferentialStringsFiles)
    if result ~= nil then return result end
  end

  local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
  local invSearchFunc = function(str, files)
    if type(files) == 'string' then files = { files } end
    local dirs = appendExtraEnglishLocaleDirs(resourceDir, baseLocaleDirs)
    for _, baseLocaleDir in ipairs(dirs) do
      for _, fileStem in ipairs(files) do
        local invDict = localesInvDict[fileStem]
        if invDict == nil then
          if hs.fs.attributes(baseLocaleDir .. '/' .. fileStem .. '.strings') ~= nil then
            invDict = parseStringsFile(baseLocaleDir .. '/' .. fileStem .. '.strings', false, true)
          elseif hs.fs.attributes(baseLocaleDir .. '/' .. fileStem .. '.nib') ~= nil
              and hs.fs.attributes(localeDir .. '/' .. fileStem .. '.strings') ~= nil then
            local fullPath = baseLocaleDir .. '/' .. fileStem .. '.nib'
            if hs.fs.attributes(fullPath, 'mode') == 'directory' then
              if hs.fs.attributes(fullPath .. '/keyedobjects.nib') ~= nil then
                fullPath = fullPath .. '/keyedobjects.nib'
              else
                fullPath = hs.execute(string.format([[ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n']], fullPath))
                if fullPath == "" then return end
              end
            end
            if isBinarayPlist(fullPath) then
              invDict = parseBinaryPlistFile(fullPath, false, true)
            else
              invDict = parseNibFile(fullPath, false, true)
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
        if hs.fs.attributes(baseLocaleDir .. '/' .. fileStem .. '.storyboardc') ~= nil
            and hs.fs.attributes(localeDir .. '/' .. fileStem .. '.strings') ~= nil then
          local fullPath = baseLocaleDir .. '/' .. fileStem .. '.storyboardc'
          for subFile in hs.fs.dir(fullPath) do
            if subFile:sub(-4) == '.nib' then
              invDict = parseNibFile(fullPath .. '/' .. subFile, false, true)
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
    local result = invSearchFunc(str, localeFile)
    if result ~= nil then return result end
  else
    baseStringsFiles = collectLocaleFiles(baseLocaleDirs[1])
    for i=2, #baseLocaleDirs do
      if hs.fs.attributes(baseLocaleDirs[i] .. '/Localizable.strings') ~= nil then
        table.insert(baseStringsFiles, 'Localizable')
      end
    end
    local basePreferentialStringsFiles = {}
    if #baseStringsFiles > 10 then
      baseStringsFiles, basePreferentialStringsFiles = filterPreferentialLocaleFiles(baseStringsFiles)
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
    if hs.fs.attributes(NIBPath) == nil or hs.fs.attributes(baseNIBPath) == nil then return end
    if hs.fs.attributes(baseNIBPath, 'mode') == 'directory' then
      if hs.fs.attributes(baseNIBPath .. '/keyedobjects.nib') ~= nil then
        baseNIBPath = baseNIBPath .. '/keyedobjects.nib'
      else
        baseNIBPath = hs.execute(string.format([[ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n']], baseNIBPath))
        if baseNIBPath == "" then return end
      end
    end
    if hs.fs.attributes(NIBPath, 'mode') == 'directory' then
      if hs.fs.attributes(NIBPath .. '/keyedobjects.nib') ~= nil then
        NIBPath = NIBPath .. '/keyedobjects.nib'
      else
        NIBPath = hs.execute(string.format([[ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n']], NIBPath))
        if NIBPath == "" then return end
      end
    end

    if isBinarayPlist(NIBPath) and isBinarayPlist(baseNIBPath) then
      local xmlDir = localeTmpDir .. appid .. '/' .. locale
      local xmlPath = xmlDir .. '/' .. file .. '.xml'
      if hs.fs.attributes(xmlPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", xmlDir))
        local _, status = hs.execute(string.format(
            "plutil -convert xml1 '%s' -o '%s'", NIBPath, xmlPath))
        if not status then return end
      end
      local baseXmlDir = localeTmpDir .. appid .. '/' .. baseLocale
      local baseXmlPath = baseXmlDir .. '/' .. file .. '.xml'
      if hs.fs.attributes(baseXmlPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", baseXmlDir))
        local _, status = hs.execute(string.format(
            "plutil -convert xml1 '%s' -o '%s'", baseNIBPath, baseXmlPath))
        if not status then return end
      end
      local diffDir = localeTmpDir .. appid .. '/' .. baseLocale .. '-' .. locale
      local diffPath = diffDir .. '/' .. file .. '.diff'
      if hs.fs.attributes(diffPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", diffDir))
        hs.execute(string.format(
                  "diff --suppress-common-lines '%s' '%s' > '%s'", baseXmlPath, xmlPath, diffPath))
      end
      local result = hs.execute(string.format([[
          cat '%s' | awk '/^<.*<string>%s<\/string>/ && !found {
            curline=$0; getline;
            if ($0 == curline) {getline}
            if ($0 ~ "---") {getline; print $0; found=1}
          }' | \
          sed 's/^>.*<string>//;s/<\/string>$//' | tr -d '\n']],
          diffPath, str))
      return result ~= "" and result or nil
    end

    local baseJsonDir = localeTmpDir .. appid .. '/' .. baseLocale
    local baseJsonPath = baseJsonDir .. '/' .. file .. '.json'
    if hs.fs.attributes(baseJsonPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", baseJsonDir))
      local _, status = hs.execute(string.format("/usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'",
                                   baseNIBPath, baseJsonPath))
      if not status then return end
    end
    local jsonDir = localeTmpDir .. appid .. '/' .. locale
    local jsonPath = jsonDir .. '/' .. file .. '.json'
    if hs.fs.attributes(jsonPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", jsonDir))
      local _, status = hs.execute(string.format("/usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'",
                                   NIBPath, jsonPath))
      if not status then return end
    end
    local diffDir = localeTmpDir .. appid .. '/' .. baseLocale .. '-' .. locale
    local diffPath = diffDir .. '/' .. file .. '.diff'
    if hs.fs.attributes(diffPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", diffDir))
      hs.execute(string.format("diff --suppress-common-lines '%s' '%s' > '%s'",
                               baseJsonPath, jsonPath, diffPath))
    end
    local result = hs.execute(string.format(
        [[cat '%s' | awk '/^<.*"data": "%s"/ && !found {getline; if ($0 ~ "---") {getline; print $0; found=1}}' | \
          sed 's/^>.*"data": "//;s/"$//' | tr -d '\n']],
        diffPath, str))
    return result ~= "" and result or nil
  end

  if localeFile ~= nil then
    local result = compareNIBs(localeFile)
    if result ~= nil then return result end
  else
    local nibFiles = collectLocaleFiles(localeDir, { nib = true })
    if #nibFiles > 10 then
      _, nibFiles = filterPreferentialLocaleFiles(nibFiles)
    end
    for _, file in ipairs(nibFiles) do
      local result = compareNIBs(file)
      if result ~= nil then return result end
    end
  end
end

local function poIdToStr(str)
  return string.format([[
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
  return string.format([[
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
  return string.format([[
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
  return string.format([[
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
  local output, status = hs.execute(string.format(
    '%s -i "%s" -of po | %s', cmd, file, poIdToStr(str)))
  if status and output ~= "" then return output end
end

local function localizeByQt(str, localeDir)
  if type(localeDir) == 'table' then
    for _, file in ipairs(localeDir) do
      local result = localizeByQtImpl(str, file)
      if result ~= nil then return result end
    end
  elseif hs.fs.attributes(localeDir, 'mode') == 'file' then
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

local function localizeByMono(str, localeDir)
  local cmd = hs.execute("which msgunfmt | tr -d '\\n'", true)
  if cmd == nil then return end
  for file in hs.fs.dir(localeDir .. '/LC_MESSAGES') do
    if file:sub(-3) == ".mo" then
      local output, status = hs.execute(string.format(
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
    if hs.fs.attributes(resourceDir .. '/' .. enLocale .. '.lproj') ~= nil then
      for file in hs.fs.dir(resourceDir .. '/' .. enLocale .. '.lproj') do
        if file:sub(-4) == ".pak" and hs.fs.attributes(localeDir .. '/' .. file) then
          local fullPath = resourceDir .. '/' .. enLocale .. '.lproj/' .. file
          local fileStem = file:sub(1, -5)
          local enTmpBaseDir = string.format(localeTmpDir .. '%s/%s', appid, enLocale)
          local enTmpdir = enTmpBaseDir .. '/' .. fileStem
          if dirNotExistOrEmpty(enTmpdir) then
            hs.execute(string.format("mkdir -p '%s'", enTmpBaseDir))
            hs.execute(string.format(
                "scripts/pak -u '%s' '%s'", fullPath, enTmpdir))
          end
          local output, status = hs.execute("grep -lrE '^" .. str .. "$' '" .. enTmpdir .. "' | tr -d '\\n'")
          if not (status and output ~= "") then
            -- base locale of `Google Chrome` misses the 13515th item, which is supposed to be "Tab"
            -- note "Tab" has multiple translations, all overridden by 13515
            if str == "Tab" and appid == "com.google.Chrome" then
              output = "13515" status = true
            end
          end
          if status and output ~= "" then
            local matchFile = output:match("^.*/(.*)$")
            local tmpBaseDir = string.format(localeTmpDir .. '%s/%s', appid, locale)
            local tmpdir = tmpBaseDir .. '/' .. fileStem
            if dirNotExistOrEmpty(tmpdir) then
              hs.execute(string.format("mkdir -p '%s'", tmpBaseDir))
              hs.execute(string.format(
                  "scripts/pak -u '%s' '%s'", localeDir .. '/' .. file, tmpdir))
            end
            local matchFullPath = tmpdir .. '/' .. matchFile
            if hs.fs.attributes(matchFullPath) ~= nil then
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
  local tmpdir = string.format(localeTmpDir .. '%s/%s', appid, locale)
  if #localeFiles > 0 then
    for _, file in ipairs(localeFiles) do
      local tmpfile = tmpdir .. '/' .. file .. '.json'
      if hs.fs.attributes(tmpfile) == nil then
        local path = hs.application.pathForBundleID(appid)
            .. '/Contents/Resources/app.asar'
        local localeFilePath = string.format("%s/%s/%s.json",
            localesPath, locale, file)
        hs.execute(string.format(
          [[npx @electron/asar extract-file "%s" "%s"]], path, localeFilePath),
        true)
        if dirNotExistOrEmpty(tmpdir) then
          hs.execute(string.format("mkdir -p '%s'", tmpdir))
        end
        hs.execute(string.format("mv '%s' '%s'", file .. '.json', tmpdir))
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
    if hs.fs.attributes(fullpath) == nil then
      local cmd = javehome .. '/bin/jimage'
      local modulePath = javehome .. '/lib/modules'
      hs.execute(cmd .. " extract"
          .. " --include regex:.*" .. file .. "\\.properties"
          .. " --dir " .. tmpBaseDir .. " " .. modulePath)
    end
    if hs.fs.attributes(fullpath) ~= nil then
      str = str:gsub(':', '\\:'):gsub(' ', '\\ ')
      local result, ok = hs.execute(string.format(
          "cat '%s' | grep '^%s='", fullpath, str:gsub('\\','\\\\')))
      if ok then
        result = hs.fnutils.split(result, '\n')
        return result[1]:sub(#str + 2)
      end
    end
  end
end

local function localizeQt(str, appid, appLocale)
  local appPath = hs.application.pathForBundleID(appid)
  local resourceDir = appPath .. "/../../share/qt/translations"
  if hs.fs.attributes(resourceDir) == nil then
    resourceDir = appPath .. "/../Qt/translations"
  end
  if hs.fs.attributes(resourceDir) == nil then return end
  local appname = appPath:match("^.*/([^/]+)%.app$")
  if appname == nil
      or hs.fs.attributes(resourceDir .. "/" .. appname:lower() .. "_en.qm") == nil then
    return
  end
  local locales = {}
  local prefix = appname:lower() .. '_'
  for file in hs.fs.dir(resourceDir) do
    if file:sub(-3) == ".qm" and file:sub(1, #prefix) == prefix then
      table.insert(locales, file:sub(#prefix + 1, -4))
    end
  end
  local locale = getMatchedLocale(appLocale, locales)
  if locale == nil then return nil end
  if locale == 'en' then return str:gsub('[^%s]-&(%a)', '%1'), locale end
  local result = localizeByQtImpl(str, resourceDir .. '/' .. prefix .. locale .. '.qm')
  if result ~= nil then
    result = result:gsub("%(&%a%)", ""):gsub('[^%s]-&(%a)', '%1')
  end
  return result, locale
end

local function getSTRInQtKso(str, file)
  local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
  if cmd == nil then return end
  local output, status = hs.execute(string.format(
    '%s -i "%s" -of po | %s', cmd, file, poCtxtToStr(str)))
  if status and output ~= "" then return output end
end

local function getCTXTInQtKso(str, file)
  local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
  if cmd == nil then return end
  local output, status = hs.execute(string.format(
    '%s -i "%s" -of po | %s', cmd, file, poStrToCtxt(str)))
  if status and output ~= "" then return output end
end

local function localizeWPS(str, appLocale, localeFile)
  local resourceDir = hs.application.pathForBundleID("com.kingsoft.wpsoffice.mac")
      .. '/Contents/Resources/office6/mui'
  local locale = getMatchedLocale(appLocale, resourceDir)
  local localeDir = resourceDir .. '/' .. locale

  local searchFunc = function(str)
    if localeFile then
      if hs.fs.attributes(localeDir .. '/' .. localeFile .. '.qm') ~= nil then
        return getSTRInQtKso(str, localeDir .. '/' .. localeFile .. '.qm')
      end
    else
      for file in hs.fs.dir(localeDir) do
        if file:sub(-3) == ".qm" then
          local result = getSTRInQtKso(str, localeDir .. '/' .. file)
          if result ~= nil then return result end
        end
      end
    end
  end
  local result = searchFunc(str)
  if result ~= nil then return result, locale end

  local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
  local dirs = appendExtraEnglishLocaleDirs(resourceDir, baseLocaleDirs)
  local ctxt
  for _, dir in ipairs(dirs) do
    if localeFile then
      if hs.fs.attributes(dir .. '/' .. localeFile .. '.qm') ~= nil then
        ctxt = getCTXTInQtKso(str, dir .. '/' .. localeFile .. '.qm')
      end
    else
      for file in hs.fs.dir(dir) do
        if file:sub(-3) == ".qm" then
          ctxt = getCTXTInQtKso(str, dir .. '/' .. file)
          if ctxt ~= nil then
            localeFile = file:sub(-3)
          end
        end
      end
    end
  end
  result = searchFunc(ctxt)
  if result ~= nil then return result, locale end
end

local function localizeChatGPT(str, appLocale)
  local resourceDir = hs.application.pathForBundleID("com.openai.chat")
      .. "/Contents/Frameworks/Assets.framework/Resources"
      .. "/Assets_Assets.bundle/Contents/Resources/CompressedStrings"
  local localeSources = {}
  for file in hs.fs.dir(resourceDir) do
    if file:sub(-11) == ".json.lzfse" then
      local fileStem = file:sub(1, -12)
      table.insert(localeSources, fileStem)
    end
  end
  local locale = getMatchedLocale(appLocale, localeSources)
  if locale == nil then return nil end
  local localeFile = resourceDir .. '/' .. locale .. '.json.lzfse'
  -- remove first 8 bytes of the file
  local tmp = os:tmpname()
  local _, status = hs.execute(
      string.format("tail -c +9 '%s' > '%s'", localeFile, tmp))
  if not status then return nil, locale end
  local jsonStr = hs.execute(
      string.format("lzfse -decode -i '%s' -o /dev/stdout", tmp), true)
  os.remove(tmp)
  local jsonDict = hs.json.decode(jsonStr)
  return jsonDict[str], locale
end

local appLocaleDir = {}
local localeMatchTmpFile = localeTmpDir .. 'map.json'
if hs.fs.attributes(localeMatchTmpFile) ~= nil then
  appLocaleDir = hs.json.read(localeMatchTmpFile)
  for appid, locale in pairs(appLocaleDir) do
    appLocaleDir[appid] = hs.fnutils.copy(locale)
  end
end
local appLocaleMap = {}
local appLocaleAssetBuffer = {}
local appLocaleAssetBufferInverse = {}
local localeTmpFile = localeTmpDir .. 'strings.json'
if hs.fs.attributes(localeTmpFile) ~= nil then
  appLocaleMap = hs.json.read(localeTmpFile)
  for appid, map in pairs(appLocaleMap) do
    appLocaleMap[appid] = hs.fnutils.copy(map)
    for k, v in pairs(appLocaleMap[appid]) do
      appLocaleMap[appid][k] = hs.fnutils.copy(v)
    end
  end
end

local function localizedStringImpl(str, appid, params, force)
  local appLocale, localeFile, localeFramework
  if type(params) == "table" then
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
    appLocale = appid ~= '__macos' and applicationLocale(appid) or SYSTEM_LOCALE
  end

  local result

  if not force then
    result = get(appLocaleMap, appid, appLocale, str)
    if result == false then return nil
    elseif result ~= nil then return result end
  end

  if appid ~= '__macos' and (hs.application.pathForBundleID(appid) == nil
      or hs.application.pathForBundleID(appid) == "") then
    return nil
  end

  if appid == "com.openai.chat" then
    result, locale = localizeChatGPT(str, appLocale)
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
      local menuItems = find(appid):getMenuItems()
      if menuItems ~= nil then
        table.remove(menuItems, 1)
        for _, title in ipairs{ 'File', 'Edit', 'Window', 'Help' } do
          if hs.fnutils.find(menuItems, function(item) return item.AXTitle == title end) ~= nil then
            return str
          end
        end
      end
    end
  end

  local locale, localeDir, mode

  local setDefaultLocale = function()
    if appid == '__macos' then return false end
    local oldLocale = locale
    resourceDir = hs.application.pathForBundleID(appid) .. "/Contents/Resources"
    framework = {}
    if hs.fs.attributes(resourceDir) == nil then return false end
    mode = 'lproj'
    locale = getMatchedLocale(appLocale, resourceDir, mode)
    if locale == nil then
      locale = oldLocale
      return false
    end
    localeDir = resourceDir .. "/" .. locale .. ".lproj"
    return true
  end

  if framework.electron then
    locale, localeDir = getElectronMatchedLocale(appid, appLocale, framework.electron)
    if locale == nil then return end
  elseif framework.java then
    locale, localeDir = getJavaMatchedLocale(appid, appLocale, resourceDir, framework.java)
    if locale == nil then return end
  end
  if not framework.mono then
    mode = 'lproj'
  end
  if locale == nil then
    locale = get(appLocaleDir, appid, appLocale)
    if locale == false then return end
    if locale ~= nil and localeDir == nil then
      if mode == 'lproj' then
        localeDir = resourceDir .. "/" .. locale .. ".lproj"
      else
        localeDir = resourceDir .. "/" .. locale
      end
      if hs.fs.attributes(localeDir) == nil then
        locale = nil
      end
    end
  end
  if locale == nil then
    locale = getMatchedLocale(appLocale, resourceDir, mode)
    if locale == nil and framework.qt then
      locale, localeDir = getQtMatchedLocale(appLocale, resourceDir)
    end
    if locale == nil and hs.fnutils.find(framework,
        function (v) return v == true end) and not setDefaultLocale() then
      return result, appLocale, locale
    end
    if locale == nil then return end
  end
  if localeDir == nil then
    if mode == 'lproj' then
      localeDir = resourceDir .. "/" .. locale .. ".lproj"
    else
      localeDir = resourceDir .. "/" .. locale
    end
  end
  if framework.qt and type(localeDir) == 'string'
      and hs.fs.attributes(localeDir) == nil then
    _, localeDir = getQtMatchedLocale(appLocale, resourceDir)
  end
  if not framework.electron and not framework.java then
    local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
    for _, dir in ipairs(baseLocaleDirs) do
      if hs.fs.attributes(dir) ~= nil
          and hs.fs.attributes(localeDir).ino == hs.fs.attributes(dir).ino then
        return str
      end
    end
  end

  if appLocaleAssetBuffer[appid] == nil
      or get(appLocaleDir, appid, appLocale) ~= locale then
    appLocaleAssetBuffer[appid] = {}
  end
  local localesDict = appLocaleAssetBuffer[appid]

  if framework.chromium then
    result = localizeByChromium(str, localeDir, appid)
    if result ~= nil or not setDefaultLocale() then return result, appLocale, locale end
  end

  if framework.mono then
    result = localizeByMono(str, localeDir)
    if result ~= nil or not setDefaultLocale() then return result, appLocale, locale end
  end

  if framework.qt then
    result = localizeByQt(str, localeDir)
    return result, appLocale, locale
  end

  if framework.electron then
    result = localizeByElectron(str, appid, locale, localeDir, framework.electron)
    return result, appLocale, locale
  end

  if framework.java then
    result = localizeByJava(str, appid, localeDir, resourceDir)
    return result, appLocale, locale
  end

  local defaultAction = function(emptyCache)
    result = localizeByLoctable(str, resourceDir, localeFile, locale, localesDict)
    if result ~= nil then return result end

    if emptyCache or appLocaleAssetBufferInverse[appid] == nil
        or get(appLocaleDir, appid, appLocale) ~= locale then
      appLocaleAssetBufferInverse[appid] = {}
    end
    result = localizeByStrings(str, localeDir, localeFile, localesDict,
                               appLocaleAssetBufferInverse[appid])
    if result ~= nil then return result end

    result = localizeByNIB(str, localeDir, localeFile, appid)
    if result ~= nil then return result end

    if string.sub(str, -3) == "..." or string.sub(str, -3) == "…" then
      result, appLocale, locale = localizedStringImpl(string.sub(str, 1, -4), appid, params)
      if result ~= nil then
        return result .. string.sub(str, -3), appLocale, locale
      end
    end
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
  return result, appLocale, locale
end

function localizedString(str, appid, params, force)
  if type(appid) == 'table' then
    force = params params = appid appid = nil
  end
  if appid == nil and (type(params) ~= 'table' or params.framework == nil) then
    return
  end
  appid = appid or '__macos'
  local result, appLocale, locale = localizedStringImpl(str, appid, params, force)
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
  if hs.fs.attributes(localeTmpDir) == nil then
    hs.execute(string.format("mkdir -p '%s'", localeTmpDir))
  end
  hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
  hs.json.write(appLocaleMap, localeTmpFile, false, true)
  return result
end


local function delocalizeByLoctableImpl(str, filePath, locale)
  local output, status = hs.execute(string.format(
      "/usr/bin/python3 scripts/loctable_delocalize.py '%s' '%s' %s",
      filePath, str, locale))
  if status and output ~= "" then return output end
end

local function delocalizeByLoctable(str, resourceDir, localeFile, locale)
  if localeFile ~= nil then
    local fullPath = resourceDir .. '/' .. localeFile .. '.loctable'
    if hs.fs.attributes(fullPath) ~= nil then
      return delocalizeByLoctableImpl(str, fullPath, locale)
    end
  else
    local loctableFiles = collectLocaleFiles(resourceDir, { loctable = true })
    local preferentialLoctableFiles = {}
    if #loctableFiles > 10 then
      loctableFiles, preferentialLoctableFiles = filterPreferentialLocaleFiles(loctableFiles)
    end
    for _, file in ipairs(preferentialLoctableFiles) do
      local result = delocalizeByLoctableImpl(str, resourceDir .. '/' .. file .. '.loctable', locale)
      if result ~= nil then return result end
    end
    for _, file in ipairs(loctableFiles) do
      local result = delocalizeByLoctableImpl(str, resourceDir .. '/' .. file .. '.loctable', locale)
      if result ~= nil then return result end
    end
  end
end

local function delocalizeByStrings(str, localeDir, localeFile, deLocalesInvDict)
  local resourceDir = localeDir .. '/..'
  local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
  local searchFunc = function(str, file)
    local dirs = appendExtraEnglishLocaleDirs(resourceDir, baseLocaleDirs)
    for _, baseLocaleDir in ipairs(dirs) do
      local jsonDict
      if hs.fs.attributes(baseLocaleDir .. '/' .. file .. '.strings') ~= nil then
        jsonDict = parseStringsFile(baseLocaleDir .. '/' .. file .. '.strings')
      elseif hs.fs.attributes(baseLocaleDir .. '/' .. file .. '.nib') ~= nil then
        local fullPath = baseLocaleDir .. '/' .. file .. '.nib'
        if hs.fs.attributes(fullPath, 'mode') == 'directory' then
          if hs.fs.attributes(fullPath .. '/keyedobjects.nib') ~= nil then
            fullPath = fullPath .. '/keyedobjects.nib'
          else
            fullPath = hs.execute(string.format([[ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n']], fullPath))
            if fullPath == "" then return end
          end
        end
        if isBinarayPlist(fullPath) then
          jsonDict = parseBinaryPlistFile(fullPath)
        else
          jsonDict = parseNibFile(fullPath)
        end
      end
      if jsonDict ~= nil and jsonDict[str] ~= nil then
        return jsonDict[str]
      end
      if hs.fs.attributes(baseLocaleDir .. '/' .. file .. '.storyboardc') ~= nil then
        local fullPath = baseLocaleDir .. '/' .. file .. '.storyboardc'
        for subFile in hs.fs.dir(fullPath) do
          if subFile:sub(-4) == '.nib' then
            jsonDict = parseNibFile(fullPath .. '/' .. subFile)
            if jsonDict ~= nil and jsonDict[str] ~= nil then
              return jsonDict[str]
            end
          end
        end
      end
    end
  end

  local invSearchFunc = function(str, files)
    if type(files) == 'string' then files = { files } end
    for _, fileStem in ipairs(files) do
      local invDict = deLocalesInvDict[fileStem]
      if invDict == nil then
        if hs.fs.attributes(localeDir .. '/' .. fileStem .. '.strings') ~= nil then
          invDict = parseStringsFile(localeDir .. '/' .. fileStem .. '.strings', false, true)
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
          if not (string.match(key, "[^%a ]")) then
            deLocalesInvDict[fileStem] = invDict
            return key
          end
        end
      end
    end
  end

  if localeFile ~= nil then
    local result = invSearchFunc(str, localeFile)
    if result ~= nil then return result end
  else
    local stringsFiles = collectLocaleFiles(localeDir, { strings = true })
    if #stringsFiles > 10 then
      _, stringsFiles = filterPreferentialLocaleFiles(stringsFiles)
    end
    local result = invSearchFunc(str, stringsFiles)
    if result ~= nil then return result end
  end
end

local function delocalizeByNIB(str, localeDir, localeFile, appid)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  local baseLocaleDir = getBaseLocaleDirs(resourceDir)[1]
  local baseLocale = baseLocaleDir:match("^.*/(.*)%.lproj$")
  local compareNIBs = function(file)
    local NIBPath = localeDir .. '/' .. file .. '.nib'
    local baseNIBPath = baseLocaleDir .. '/' .. file .. '.nib'
    if hs.fs.attributes(NIBPath) == nil or hs.fs.attributes(baseNIBPath) == nil then return end
    if hs.fs.attributes(NIBPath, 'mode') == 'directory' then
      if hs.fs.attributes(NIBPath .. '/keyedobjects.nib') ~= nil then
        NIBPath = NIBPath .. '/keyedobjects.nib'
      else
        NIBPath = hs.execute(string.format([[ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n']], NIBPath))
        if NIBPath == "" then return end
      end
    end
    if hs.fs.attributes(baseNIBPath, 'mode') == 'directory' then
      if hs.fs.attributes(baseNIBPath .. '/keyedobjects.nib') ~= nil then
        baseNIBPath = baseNIBPath .. '/keyedobjects.nib'
      else
        baseNIBPath = hs.execute(string.format([[ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n']], baseNIBPath))
        if baseNIBPath == "" then return end
      end
    end

    if isBinarayPlist(NIBPath) and isBinarayPlist(baseNIBPath) then
      local xmlDir = localeTmpDir .. appid .. '/' .. locale
      local xmlPath = xmlDir .. '/' .. file .. '.xml'
      if hs.fs.attributes(xmlPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", xmlDir))
        local _, status = hs.execute(string.format(
            "plutil -convert xml1 '%s' -o '%s'", NIBPath, xmlPath))
        if not status then return end
      end
      local baseXmlDir = localeTmpDir .. appid .. '/' .. baseLocale
      local baseXmlPath = baseXmlDir .. '/' .. file .. '.xml'
      if hs.fs.attributes(baseXmlPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", baseXmlDir))
        local _, status = hs.execute(string.format(
            "plutil -convert xml1 '%s' -o '%s'", baseNIBPath, baseXmlPath))
        if not status then return end
      end
      local diffDir = localeTmpDir .. appid .. '/' .. locale .. '-' .. baseLocale
      local diffPath = diffDir .. '/' .. file .. '.diff'
      if hs.fs.attributes(diffPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", diffDir))
        hs.execute(string.format("diff --suppress-common-lines '%s' '%s' > '%s'",
                                 xmlPath, baseXmlPath, diffPath))
      end
      local result = hs.execute(string.format([[
          cat '%s' | awk '/^<.*<string>%s<\/string>/ && !found {
            curline=$0; getline;
            if ($0 == curline) {getline}
            if ($0 ~ "---") {getline; print $0}; found=1
          }' | \
          sed 's/^>.*<string>//;s/<\/string>$//' | tr -d '\n']],
          diffPath, str))
      return result ~= "" and result or nil
    end

    local jsonDir = localeTmpDir .. appid .. '/' .. locale
    local jsonPath = jsonDir .. '/' .. file .. '.json'
    if hs.fs.attributes(jsonPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", jsonDir))
      local _, status = hs.execute(string.format("/usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'",
                                   NIBPath, jsonPath))
      if not status then return end
    end
    local baseJsonDir = localeTmpDir .. appid .. '/' .. baseLocale
    local baseJsonPath = baseJsonDir .. '/' .. file .. '.json'
      if hs.fs.attributes(baseJsonPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", baseJsonDir))
      local _, status = hs.execute(string.format("/usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'",
                                   baseLocaleDir .. '/' .. file .. '.nib', baseJsonPath))
      if not status then return end
    end
    local diffDir = localeTmpDir .. appid .. '/' .. locale .. '-' .. baseLocale
    local diffPath = diffDir .. '/' .. file .. '.diff'
    if hs.fs.attributes(diffPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", diffDir))
      hs.execute(string.format("diff --suppress-common-lines '%s' '%s' > '%s'",
                               jsonPath, baseJsonPath, diffPath))
    end
    local result = hs.execute(string.format(
        [[cat '%s' | awk '/^<.*"data": "%s"/ && !found {getline; if ($0 ~ "---") {getline; print $0; found=1}}' | \
          sed 's/^>.*"data": "//;s/"$//' | tr -d '\n']],
        diffPath, str))
    return result ~= "" and result or nil
  end

  if localeFile ~= nil then
    local result = compareNIBs(localeFile)
    if result ~= nil then return result end
  else
    local nibFiles = collectLocaleFiles(localeDir, { nib = true })
    if #nibFiles > 10 then
      _, nibFiles = filterPreferentialLocaleFiles(nibFiles)
    end
    for _, file in ipairs(nibFiles) do
      local result = compareNIBs(file)
      if result ~= nil then return result end
    end
  end
end

local function delocalizeByQtImpl(str, file)
  local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
  if cmd == nil then return end
  local output, status = hs.execute(string.format(
    '%s -i "%s" -of po | %s', cmd, file, poStrToId(str)))
  if status and output ~= "" then return output end
end

local function delocalizeByQt(str, localeDir)
  if type(localeDir) == 'table' then
    for _, file in ipairs(localeDir) do
      local result = delocalizeByQtImpl(str, file)
      if result ~= nil then return result end
    end
  elseif hs.fs.attributes(localeDir, 'mode') == 'file' then
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

local function delocalizeByMono(str, localeDir)
  local cmd = hs.execute("which msgunfmt | tr -d '\\n'", true)
  if cmd == nil then return end
  for file in hs.fs.dir(localeDir .. '/LC_MESSAGES') do
    if file:sub(-3) == ".mo" then
      local output, status = hs.execute(string.format(
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
      local tmpBaseDir = string.format(localeTmpDir .. '%s/%s', appid, locale)
      local tmpdir = tmpBaseDir .. '/' .. fileStem
      if dirNotExistOrEmpty(tmpdir) then
        hs.execute(string.format("mkdir -p '%s'", tmpBaseDir))
        hs.execute(string.format(
          "scripts/pak  -u '%s' '%s'", localeDir .. '/' .. file, tmpdir))
      end
      local pattern = '^' .. str .. '$'
      local output, status = hs.execute(string.format(
            "grep -lrE '%s' '%s' | tr -d '\\n'", pattern, tmpdir))
      if status and output ~= "" then
        local matchFile = output:match("^.*/(.*)$")
        for _, enLocale in ipairs{"en", "English", "Base", "en_US", "en_GB"} do
          local fullPath = resourceDir .. '/' .. enLocale .. '.lproj/' .. file
          if hs.fs.attributes(fullPath) ~= nil then
            local enTmpBaseDir = string.format(localeTmpDir .. '%s/%s', appid, enLocale)
            local enTmpdir = enTmpBaseDir .. '/' .. fileStem
            if dirNotExistOrEmpty(enTmpdir) then
              hs.execute(string.format("mkdir -p '%s'", enTmpBaseDir))
              hs.execute(string.format(
                "scripts/pak  -u '%s' '%s'", fullPath, enTmpdir))
            end
            local matchFullPath = enTmpdir .. '/' .. matchFile
            if hs.fs.attributes(matchFullPath) ~= nil then
              local f = io.open(matchFullPath, "r")
              if f ~= nil then
                local content = f:read("*a")
                f:close()
                return content
              end
            end
          end
        end
        if matchFile == "13515" and appid == "com.google.Chrome" then
          return "Tab"
        end
      end
    end
  end
end

local function delocalizeByElectron(str, appid, locale, localeFiles, localesPath)
  local tmpdir = string.format(localeTmpDir .. '%s/%s', appid, locale)
  if #localeFiles > 0 then
    for _, file in ipairs(localeFiles) do
      local tmpfile = tmpdir .. '/' .. file .. '.json'
      if hs.fs.attributes(tmpfile) == nil then
        local path = hs.application.pathForBundleID(appid)
            .. '/Contents/Resources/app.asar'
        local localeFilePath = string.format("%s/%s/%s.json",
            localesPath, locale, file)
        hs.execute(string.format(
          [[npx @electron/asar extract-file "%s" "%s"]], path, localeFilePath),
        true)
        if dirNotExistOrEmpty(tmpdir) then
          hs.execute(string.format("mkdir -p '%s'", tmpdir))
        end
        hs.execute(string.format("mv '%s' '%s'", file .. '.json', tmpdir))
      end
    end
  end
  for file in hs.fs.dir(tmpdir) do
    if file:sub(-5) == '.json' then
      local json = hs.json.read(tmpdir .. '/' .. file)
      local result = hs.fnutils.indexOf(json, str)
      if result ~= nil then return result, locale end
    end
  end
  return nil, locale
end

local function delocalizeByJava(str, appid, localeFiles, javehome)
  for _, file in ipairs(localeFiles) do
    local tmpBaseDir = localeTmpDir .. appid
    local fullpath = tmpBaseDir .. '/' .. file .. ".properties"
    if hs.fs.attributes(fullpath) == nil then
      local cmd = javehome .. '/bin/jimage'
      local modulePath = javehome .. '/lib/modules'
      hs.execute(cmd .. " extract"
          .. " --include regex:.*" .. file .. "\\.properties"
          .. " --dir " .. tmpBaseDir .. " " .. modulePath)
    end
    if hs.fs.attributes(fullpath) ~= nil then
      local result, ok = hs.execute(string.format(
          "cat '%s' | grep '=%s$'", fullpath, str))
      if ok then
        result = hs.fnutils.split(result, '\n')
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
  if hs.fs.attributes(resourceDir) == nil then
    resourceDir = appPath .. "/../Qt/translations"
  end
  if hs.fs.attributes(resourceDir) == nil then return end
  local appname = appPath:match("^.*/([^/]+)%.app$")
  if appname == nil
      or hs.fs.attributes(resourceDir .. "/" .. appname:lower() .. "_en.qm") == nil then
    return
  end
  local locales = {}
  local prefix = appname:lower() .. '_'
  for file in hs.fs.dir(resourceDir) do
    if file:sub(-3) == ".qm" and file:sub(1, #prefix) == prefix then
      table.insert(locales, file:sub(#prefix + 1, -4))
    end
  end
  local locale = getMatchedLocale(appLocale, locales)
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
  local resourceDir = hs.application.pathForBundleID("com.kingsoft.wpsoffice.mac")
      .. '/Contents/Resources/office6/mui'
  local locale = getMatchedLocale(appLocale, resourceDir)
  if locale == nil then return end
  local localeDir = resourceDir .. '/' .. locale

  local ctxt
  if localeFile then
    if hs.fs.attributes(localeDir .. '/' .. localeFile .. '.qm') ~= nil then
      ctxt = getCTXTInQtKso(str, localeDir .. '/' .. localeFile .. '.qm')
    end
  else
    for file in hs.fs.dir(localeDir) do
      if file:sub(-3) == ".qm" then
        ctxt = getCTXTInQtKso(str, localeDir .. '/' .. file)
        if ctxt ~= nil then
          localeFile = file:sub(-3)
          break
        end
      end
    end
  end
  if ctxt == nil then return nil, locale end

  local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
  local dirs = appendExtraEnglishLocaleDirs(resourceDir, baseLocaleDirs)
  for _, dir in ipairs(dirs) do
    if hs.fs.attributes(dir .. '/' .. localeFile .. '.qm') ~= nil then
      local result = getSTRInQtKso(ctxt, dir .. '/' .. localeFile .. '.qm')
      if result ~= nil then return result, locale end
    end
  end
  return nil, locale
end

local function delocalizeZoteroMenu(str, appLocale)
  local resourceDir = hs.application.pathForBundleID("org.zotero.zotero") .. "/Contents/Resources"
  local locales, status = hs.execute("unzip -l \"" .. resourceDir .. "/zotero.jar\" 'chrome/locale/*/' | grep -Eo 'chrome/locale/[^/]*' | grep -Eo '[a-zA-Z-]*$' | uniq")
  if status ~= true then return end
  local locale = getMatchedLocale(appLocale, hs.fnutils.split(locales, '\n'))
  if locale == nil then return end
  local localeFile = 'chrome/locale/' .. locale .. '/zotero/standalone.dtd'
  local enLocaleFile = 'chrome/locale/en-US/zotero/standalone.dtd'
  local key
  key, status = hs.execute("unzip -p \"" .. resourceDir .. "/zotero.jar\" \"" .. localeFile .. "\""
      .. " | awk '/<!ENTITY .* \"" .. str .. "\">/ { gsub(/<!ENTITY | \"" .. str .. "\">/, \"\"); printf \"%s\", $0 }'")
  if status ~= true then return nil end
  local enValue = hs.execute("unzip -p \"" .. resourceDir .. "/zotero.jar\" \"" .. enLocaleFile .. "\""
      .. " | grep '" .. key .. "' | cut -d '\"' -f 2 | tr -d '\\n'")
  return enValue, locale
end

local function delocalizeMATLABFigureMenu(str, appLocale)
  local resourceDir = hs.application.pathForBundleID("com.mathworks.matlab") .. "/resources/MATLAB"
  local locale = getMatchedLocale(appLocale, resourceDir)
  if locale == nil then return end
  local localeFile = resourceDir .. '/' .. locale .. '/uistring/figuremenu.xml'
  local enLocaleFile = resourceDir .. '/en/uistring/figuremenu.xml'
  local shell_pattern = 'key="([^"]*?)">' .. str .. '\\(&amp;[A-Z]\\)</entry>'
  local key, status = hs.execute(string.format(
      "grep -Eo '%s' '%s' | cut -d '\"' -f 2 | tr -d '\\n'", shell_pattern, localeFile))
  if status and key ~= "" then
    local inverse_pattern = 'key="' .. key .. '">&amp;([^<]*?)</entry>'
    local enValue, status = hs.execute(string.format(
        "grep -Eo '%s' '%s' | cut -d ';' -f 2  | cut -d '<' -f 1 | tr -d '\\n'", inverse_pattern, enLocaleFile))
    if status and enValue ~= "" then return enValue, locale end
  end
  return nil, locale
end

local deLocaleMap = {}
local deLocaleInversedMap = {}
local menuItemTmpFile = localeTmpDir .. 'menubar.json'
if hs.fs.attributes(menuItemTmpFile) ~= nil then
  deLocaleMap = hs.json.read(menuItemTmpFile)
  for appid, map in pairs(deLocaleMap) do
    deLocaleMap[appid] = hs.fnutils.copy(map)
    for k, v in pairs(deLocaleMap[appid]) do
      deLocaleMap[appid][k] = hs.fnutils.copy(v)
    end
  end
end

local function delocalizedStringImpl(str, appid, params)
  local appLocale, localeFile, localeFramework
  if type(params) == "table" then
    appLocale = params.locale
    localeFile = params.localeFile
    localeFramework = params.framework
  else
    localeFile = params
  end

  if appLocale == nil then
    appLocale = applicationLocale(appid)
  end

  local result = get(deLocaleMap, appid, appLocale, str)
  if result == false then return nil
  elseif result ~= nil then return result end

  if appid == "org.zotero.zotero" then
    result, locale = delocalizeZoteroMenu(str, appLocale)
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
      local menuItems = find(appid):getMenuItems()
      if menuItems ~= nil then
        table.remove(menuItems, 1)
        for _, title in ipairs{ 'File', 'Edit', 'Window', 'Help' } do
          if hs.fnutils.find(menuItems, function(item) return item.AXTitle == title end) ~= nil then
            return str
          end
        end
      end
    end
  end

  local locale, localeDir, mode

  if framework.electron then
    locale, localeDir = getElectronMatchedLocale(appid, appLocale, framework.electron)
    if locale == nil then return end
  elseif framework.java then
    locale, localeDir = getJavaMatchedLocale(appid, appLocale, resourceDir, framework.java)
    if locale == nil then return end
  end
  if not framework.mono then
    mode = 'lproj'
  end
  if locale == nil then
    locale = get(appLocaleDir, appid, appLocale)
    if locale == false then return end
  end
  if locale == nil then
    locale = getMatchedLocale(appLocale, resourceDir, mode)
    if locale == nil and framework.qt then
      locale, localeDir = getQtMatchedLocale(appLocale, resourceDir)
    end
    if locale == nil then return end
  end
  if localeDir == nil then
    if mode == 'lproj' then
      localeDir = resourceDir .. "/" .. locale .. ".lproj"
    else
      localeDir = resourceDir .. "/" .. locale
    end
  end
  if framework.qt and type(localeDir) == 'string'
      and hs.fs.attributes(localeDir) == nil then
    _, localeDir = getQtMatchedLocale(appLocale, resourceDir)
  end
  if not framework.electron and not framework.java then
    local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
    for _, dir in ipairs(baseLocaleDirs) do
      if hs.fs.attributes(dir) ~= nil
          and hs.fs.attributes(localeDir).ino == hs.fs.attributes(dir).ino then
        return str
      end
    end
  end

  local setDefaultLocale = function()
    local oldLocale = locale
    resourceDir = hs.application.pathForBundleID(appid) .. "/Contents/Resources"
    if hs.fs.attributes(resourceDir) == nil then return false end
    mode = 'lproj'
    locale = getMatchedLocale(appLocale, resourceDir, mode)
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
    result = delocalizeByElectron(str, appid, locale, localeDir, framework.electron)
    return result, appLocale, locale
  end

  if framework.java then
    result = delocalizeByJava(str, appid, localeDir, resourceDir)
    return result, appLocale, locale
  end

  local defaultAction = function(emptyCache)
    result = delocalizeByLoctable(str, resourceDir, localeFile, locale)
    if result ~= nil then return result end

    if emptyCache or deLocaleInversedMap[appid] == nil
        or get(appLocaleDir, appid, appLocale) ~= locale then
      deLocaleInversedMap[appid] = {}
    end
    result = delocalizeByStrings(str, localeDir, localeFile, deLocaleInversedMap[appid])
    if result ~= nil then return result end

    result = delocalizeByNIB(str, localeDir, localeFile, appid)
    if result ~= nil then return result end

    if string.sub(str, -3) == "..." or string.sub(str, -3) == "…" then
      result, appLocale, locale = delocalizedStringImpl(string.sub(str, 1, -4), appid, params)
      if result ~= nil then
        return result .. string.sub(str, -3), appLocale, locale
      end
    end
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
  return result, appLocale, locale
end

function delocalizedString(str, appid, params)
  local result, appLocale, locale = delocalizedStringImpl(str, appid, params)
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
  if hs.fs.attributes(localeTmpDir) == nil then
    hs.execute(string.format("mkdir -p '%s'", localeTmpDir))
  end
  hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
  hs.json.write(deLocaleMap, menuItemTmpFile, false, true)
  return result
end

-- some menu items are managed by system framework
-- the localized strings of their titles are manged here
-- should be use when localizing / delocalizing menu bar items
-- and delocalizing menu items whose keybindings contain 'fn'
function localizeCommonMenuItemTitles(locale, appid)
  if locale == 'en' or locale:find('en_') or locale == 'English' then return end
  if locale == SYSTEM_LOCALE and appid ~= nil then return end

  local resourceDir = '/System/Library/Frameworks/AppKit.framework/Resources'
  local matchedLocale = getMatchedLocale(locale, resourceDir, 'lproj')

  local target = appid or 'common'
  if delocMap[target] == nil then
    delocMap[target] = {}
  end
  if locMap[target] == nil then
    locMap[target] = {}
  end
  local targetDelocMap = delocMap[target]
  local targetLocMap = locMap[target]
  for _, title in ipairs { 'File', 'View', 'Window', 'Help' } do
    local escapedTitle = title:gsub('…', '\\U2026'):gsub('“', '\\U201C'):gsub('”', '\\U201D')
    local localizedTitle = localizeByLoctable(escapedTitle, resourceDir, 'MenuCommands', matchedLocale, {})
    if localizedTitle ~= nil then
      targetDelocMap[localizedTitle] = title
      targetLocMap[title] = localizedTitle
    end
  end
  local localizedTitle = localizeByLoctable('Edit', resourceDir, 'InputManager', matchedLocale, {})
  if localizedTitle ~= nil then
    targetDelocMap[localizedTitle] = 'Edit'
    targetLocMap['Edit'] = localizedTitle
  end

  local titleList = {
    'Enter Full Screen', 'Exit Full Screen',
  }
  if OS_VERSION >= OS.Sequoia then
    titleList = hs.fnutils.concat(titleList, {
      'Fill', 'Center', 'Move & Resize', 'Return to Previous Size',
      'Left', 'Right', 'Top', 'Bottom',
      'Left & Right', 'Right & Left', 'Top & Bottom', 'Bottom & Top',
      'Left & Quarters', 'Right & Quarters', 'Top & Quarters', 'Bottom & Quarters',
    })
  end
  for _, title in ipairs(titleList) do
    local escapedTitle = title:gsub('…', '\\U2026'):gsub('“', '\\U201C'):gsub('”', '\\U201D')
    local localizedTitle = localizeByLoctable(escapedTitle, resourceDir, 'MenuCommands', matchedLocale, {})
    if localizedTitle ~= nil then
      delocMap.common[localizedTitle] = title
    end
  end
  local localizedTitle = localizeByLoctable('Emoji & Symbols', resourceDir, 'InputManager', matchedLocale, {})
  if localizedTitle ~= nil then
    delocMap.common[localizedTitle] = 'Emoji & Symbols'
  end
end

localizeCommonMenuItemTitles(SYSTEM_LOCALE)

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
  local newTitle = delocalizedString(title, appid, params)
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
    local splits = hs.fnutils.split(t, ' ')
    return string.byte(t, 1) <= 127
        and (string.len(t) < 2 or string.byte(t, 2) <= 127)
        and (string.len(t) < 3 or string.byte(t, 3) <= 127)
        and (#splits == 1 or string.byte(splits[2], 1) <= 127)
  end
  for _, title in ipairs(itemTitles) do
    -- remove titles starting with non-ascii characters
    if isValid(title) then
      table.insert(result, { title, title })
    else
      local delocTitle
      if titleMap[title] ~= nil then
        delocTitle = titleMap[title]
      elseif defaultTitleMap ~= nil and defaultTitleMap[title] ~= nil then
        delocTitle = defaultTitleMap[title]
        titleMap[title] = delocTitle
      else
        delocTitle = delocalizedString(title, appid, localeFile)
        titleMap[title] = delocTitle
      end
      if delocTitle ~= nil then
        if not isValid(delocTitle) then
          if titleMap[delocTitle] ~= nil then
            delocTitle = titleMap[delocTitle]
          elseif defaultTitleMap ~= nil and defaultTitleMap[delocTitle] ~= nil then
            delocTitle = defaultTitleMap[delocTitle]
          end
        end
        if isValid(delocTitle) then
          table.insert(result, { title, delocTitle })
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
  -- the app may pretend being localized (e.g. Visual Studio Code)
  local appLocale = applicationLocale(appid)
  if find(appid) then
    if type(params) == 'table' and params.locale ~= nil
        and params.locale == getMatchedLocale(appLocale, { params.locale }) then
      if find(appid):findMenuItem({ title }) ~= nil then
        return title
      end
    end
  end
  if appLocale == getMatchedLocale(SYSTEM_LOCALE, { appLocale }) then
    local locTitle = locMap.common[title]
    if locTitle ~= nil then return locTitle end
  end
  local locTitle = localizedString(title, appid, params)
  if locTitle ~= nil then
    if delocMap[appid] == nil then
      delocMap[appid] = {}
    end
    delocMap[appid][locTitle] = title
    if get(deLocaleMap[appid], appLocale, locTitle) ~= nil then
      deLocaleMap[appid][appLocale][locTitle] = title
      if hs.fs.attributes(localeTmpDir) == nil then
        hs.execute(string.format("mkdir -p '%s'", localeTmpDir))
      end
      hs.json.write(appLocaleDir, localeMatchTmpFile, true, true)
      hs.json.write(deLocaleMap, menuItemTmpFile, true, true)
    end
    return locTitle
  end
end

function applicationValidLocale(appid)
  local appLocale = applicationLocale(appid)
  local resourceDir, framework = getResourceDir(appid)
  local locale, mode
  if framework.electron then
    locale = getElectronMatchedLocale(appid, appLocale, framework.electron)
    if locale == nil then return end
  elseif framework.java then
    locale = getJavaMatchedLocale(appid, appLocale, resourceDir, framework.java)
    if locale == nil then return end
  end
  if not framework.mono then
    mode = 'lproj'
  end
  if locale == nil then
    locale = get(appLocaleDir, appid, appLocale)
    if locale == false then return nil end
    if locale ~= nil then
      local localeDir
      if mode == 'lproj' then
        localeDir = resourceDir .. "/" .. locale .. ".lproj"
      else
        localeDir = resourceDir .. "/" .. locale
      end
      if hs.fs.attributes(localeDir) == nil then
        locale = nil
      end
    end
  end
  if locale == nil then
    locale = getMatchedLocale(appLocale, resourceDir, mode)
    if locale == nil and framework.qt then
      locale = getQtMatchedLocale(appLocale, resourceDir)
    end
  end
  return locale
end

function displayName(app)
  if app.name ~= nil then return app:name() end
  local appid = app  -- assume app is installed
  local basename = hs.application.nameForBundleID(appid)
  local appLocale = applicationLocale(appid)
  local appname = get(appLocaleMap, appid, appLocale, basename)
  if appname ~= nil then return appname end

  local resourceDir = hs.application.pathForBundleID(appid) .. "/Contents/Resources"
  local locale = get(appLocaleDir, appid, appLocale)
  if locale == false then return basename end
  if locale == nil then
    locale = getMatchedLocale(appLocale, resourceDir, 'lproj')
    if locale == nil then return basename end
  end
  if hs.fs.attributes(resourceDir .. '/InfoPlist.loctable') ~= nil then
    appname = localizeByLoctable('CFBundleDisplayName',
        resourceDir, 'InfoPlist', locale, {})
    if appname == nil then
      appname = localizeByLoctable('CFBundleName',
          resourceDir, 'InfoPlist', locale, {})
    end
  else
    local localeDir = resourceDir .. "/" .. locale .. ".lproj"
    if hs.fs.attributes(localeDir .. '/InfoPlist.strings') ~= nil then
      jsonDict = parseStringsFile(localeDir .. '/InfoPlist.strings')
      appname = jsonDict['CFBundleDisplayName']
      if appname == nil then appname = jsonDict['CFBundleyName'] end
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
  if hs.fs.attributes(localeTmpDir) == nil then
    hs.execute(string.format("mkdir -p '%s'", localeTmpDir))
  end
  hs.json.write(appLocaleMap, localeTmpFile, false, true)

  return appname
end

-- helpers for click menubar to the right

function hasTopNotch(screen)
  if screen:name() == "Built-in Retina Display" then
    local displaySize = screen:fullFrame()
    if displaySize.w * 10 < displaySize.h * 16 then
      return true
    end
  end
  return false
end

function hiddenByBartender(id)
  if find("com.surteesstudios.Bartender") == nil then
    return false
  end
  local _, hiddenItems = hs.osascript.applescript([[
    tell application id "com.surteesstudios.Bartender" to list menu bar items
  ]])
  local hiddenItemList = hs.fnutils.split(hiddenItems, "\n")
  for _, item in ipairs(hiddenItemList) do
    if string.sub(item, 1, string.len(id)) == id then
      return false
    elseif item == "com.surteesstudios.Bartender-statusItem" then
      return true
    end
  end
end

function leftClick(position, appname)
  if position.x == nil then position = hs.geometry.point(position) end
  if appname ~= nil then
    local appHere = hs.axuielement.systemElementAtPosition(position)
    while appHere ~= nil and appHere.AXParent ~= nil do
      appHere = appHere.AXParent
    end
    if appHere.AXTitle ~= appname then return false end
  end
  hs.eventtap.leftClick(position)
  return true
end

function leftClickAndRestore(position, appname, delay)
  if type(appname) == 'number' then
    delay = appname appname = nil
  end
  local mousePosition = hs.mouse.absolutePosition()
  if leftClick(position, appname) then
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

function rightClick(position, appname)
  if position.x == nil then position = hs.geometry.point(position) end
  if appname ~= nil then
    local appHere = hs.axuielement.systemElementAtPosition(position)
    while appHere.AXParent ~= nil do
      appHere = appHere.AXParent
    end
    if appHere.AXTitle ~= appname then return false end
  end
  hs.eventtap.rightClick(position)
  return true
end

function rightClickAndRestore(position, appname, delay)
  if type(appname) == 'number' then
    delay = appname appname = nil
  end
  local mousePosition = hs.mouse.absolutePosition()
  if rightClick(position, appname) then
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

function clickRightMenuBarItem(appid, menuItemPath, show)
  local menuBarIdx, app = 1, nil
  if type(appid) == 'table' then
    menuBarIdx = appid[2] appid = appid[1]
  end
  if type(appid) == 'string' then
    app = find(appid)
    if app == nil then return false end
  else
    app = appid appid = app:bundleID()
  end
  local appUI = hs.axuielement.applicationElement(app)
  local menuBarMenu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, menuBarIdx)

  if type(menuItemPath) ~= 'table' then
    menuItemPath = { menuItemPath }
  end
  if #menuItemPath == 0 and show == nil then
    show = true
  end

  if show then
    if hiddenByBartender(appid) then
      hs.osascript.applescript([[
        tell application id "com.surteesstudios.Bartender" to activate "]] .. appid .. [[-Item-0"
      ]])
    else
      -- note: some apps do not react to AX.Press, you have to click them.
      menuBarMenu:performAction(AX.Press)
    end
  end
  if #menuItemPath == 0 then return true end

  local menu = menuBarMenu
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
