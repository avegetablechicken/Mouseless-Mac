---@diagnostic disable: lowercase-global

OS = {
  Cheetah = "10.00",
  Puma = "10.01",
  Jaguar = "10.02",
  Panther = "10.03",
  Tiger = "10.04",
  Leopard = "10.05",
  ["Snow Leopard"] = "10.06",
  Lion = "10.07",
  ["Mountain Lion"] = "10.08",
  Mavericks = "10.09",
  Yosemite = "10.10",
  ["El Capitan"] = "10.11",
  Sierra = "10.12",
  ["High Sierra"] = "10.13",
  Mojave = "10.14",
  Catalina = "10.15",
  ["Big Sur"] = "11",
  Monterey = "12",
  Ventura = "13",
  Sonoma = "14",
  Sequoia = "15",
}

function getOSVersion()
  local osVersion = hs.host.operatingSystemVersion()
  local v = osVersion.major
  if v < 11 then
    local vminor = (osVersion.minor < 10 and "0" or "") .. tostring(osVersion.minor)
    return tostring(v) .. "." .. tostring(vminor)
  else
    return tostring(v)
  end
end

function get(table, key, ...)
  if table == nil or key == nil then return table end
  return get(table[key], ...)
end

function getAXChildren(element, role, index, ...)
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
  else
    child = hs.fnutils.find(children, function(c)
      return c.AXTitle == index
    end)
  end
  return getAXChildren(child, ...)
end

function inFullscreenWindow()
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
  if inFullscreenWindow() then
    local cnt = #hs.application.frontmostApplication():visibleWindows()
    if hs.application.frontmostApplication():bundleID() == "com.apple.finder" then
      cnt = cnt - 1
    end
    return cnt
  else
    return 1
  end
end

function aWinFor(bundleID_or_appObject)
  local bundleID
  if type(bundleID_or_appObject) == 'string' then bundleID = bundleID_or_appObject
  else bundleID = bundleID_or_appObject:bundleID() end
  return string.format(
      'window %d of (first application process whose bundle identifier is "%s")\n',
      activatedWindowIndex(), bundleID)
end

function menuBarVisible()
  if inFullscreenWindow() then
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

function findMenuItem(appObject, menuItemTitle, params)
  local menuItem = appObject:findMenuItem(menuItemTitle)
  if menuItem ~= nil then return menuItem, menuItemTitle end
  local targetMenuItem = {}
  local locStr = localizedMenuBarItem(menuItemTitle[1], appObject:bundleID())
  table.insert(targetMenuItem, locStr or menuItemTitle[1])
  for i=#menuItemTitle,2,-1 do
    locStr = localizedMenuItem(menuItemTitle[i], appObject:bundleID(), params)
    table.insert(targetMenuItem, 2, locStr or menuItemTitle[i])
  end
  return appObject:findMenuItem(targetMenuItem), targetMenuItem
end

function selectMenuItem(appObject, menuItemTitle, params, show)
  if type(params) == "boolean" then
    show = params params = nil
  end

  if show then
    local menuItem, targetMenuItem = findMenuItem(appObject, menuItemTitle, params)
    if menuItem ~= nil then
      showMenuItemWrapper(function()
        appObject:selectMenuItem({targetMenuItem[1]})
      end)()
      return appObject:selectMenuItem(targetMenuItem)
    end
  else
    if appObject:selectMenuItem(menuItemTitle) then return true end
    local targetMenuItem = {}
    local locStr = localizedMenuBarItem(menuItemTitle[1], appObject:bundleID())
    table.insert(targetMenuItem, locStr or menuItemTitle[1])
    for i=#menuItemTitle,2,-1 do
      locStr = localizedMenuItem(menuItemTitle[i], appObject:bundleID(), params)
      table.insert(targetMenuItem, 2, locStr or menuItemTitle[i])
    end
    return appObject:selectMenuItem(targetMenuItem)
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

function findMenuItemByKeyBinding(appObject, mods, key, menuItems)
  if menuItems == nil then
    menuItems = appObject:getMenuItems()
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

local function filterParallels(appObjects)
  return hs.fnutils.find(appObjects, function(app)
    return string.find(app:bundleID(), "com.parallels") == nil
  end)
end

function findApplication(hint, exact)
  if exact == nil then exact = true end
  return filterParallels{hs.application.find(hint, exact)}
end

function quitApplication(app)
  local appObject = findApplication(app, true)
  if appObject ~= nil then
    appObject:kill()
    return true
  end
  return false
end

local localeTmpDir = hs.fs.temporaryDirectory() .. 'org.hammerspoon.Hammerspoon/locale/'

localizationMap = {}
localizationMapLoaded = {}
local localizationFrameworks = {}
if hs.fs.attributes("config/localization.json") ~= nil then
  localizationMap = hs.json.read("config/localization.json")
  localizationFrameworks = localizationMap['resources']
  localizationMap['resources'] = nil
  localizationMapLoaded = hs.fnutils.copy(localizationMap)
end
function resetLocalizationMap(bundleID)
  if localizationMapLoaded[bundleID] ~= nil then
    localizationMap[bundleID] = hs.fnutils.copy(localizationMapLoaded[bundleID])
  else
    localizationMap[bundleID] = nil
  end
end

localizationMap.common = {}

local function systemLocales()
  local locales, ok = hs.execute("defaults read -globalDomain AppleLanguages | tr -d '()\" \\n'")
  return hs.fnutils.split(locales, ',')
end

function applicationLocales(bundleID)
  local locales, ok = hs.execute(
      string.format("(defaults read %s AppleLanguages || defaults read -globalDomain AppleLanguages) | tr -d '()\" \\n'", bundleID))
  return hs.fnutils.split(locales, ',')
end

local function getResourceDir(bundleID, frameworkName)
  if frameworkName == nil then
    frameworkName = localizationFrameworks[bundleID]
  end
  local resourceDir
  local framework = {}
  local appContentPath = hs.application.pathForBundleID(bundleID) .. "/Contents"
  if hs.fs.attributes(appContentPath) == nil then
    resourceDir = hs.application.pathForBundleID(bundleID) .. "/WrappedBundle/.."
  elseif frameworkName ~= nil then
    local frameworkDir
    if hs.fs.attributes(frameworkName) ~= nil then
      frameworkDir = frameworkName
    else
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

function getQtMatchedLocale(appLocale, resourceDir)
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

  local bestMatch = getBestMatchedLocale(localDetails, matchedLocales, true)
  local matchedLocale = language
  if bestMatch.script ~= nil then matchedLocale = matchedLocale .. '_' .. bestMatch.script end
  if bestMatch.country ~= nil then matchedLocale = matchedLocale .. '_' .. bestMatch.country end
  return matchedLocale, bestMatch.extra
end

local baseLocales = {
  "Base", "en", "English"
}
local function baseLocaleDirs(resourceDir)
  local dirs = {}
  for _, locale in ipairs(baseLocales) do
    local localeDir = resourceDir .. '/' .. locale .. '.lproj'
    if hs.fs.attributes(localeDir) ~= nil then
      table.insert(dirs, localeDir)
    end
  end
  if #dirs == 0 then table.insert(dirs, resourceDir) end
  return dirs
end

local extraEnglishLocales = {
  "en_US", "en_GB"
}
local function appendExtraEnglishLocaleDirs(resourceDir, baseDirs)
  local dirs = hs.fnutils.copy(baseDirs)
  for _, locale in ipairs(extraEnglishLocales) do
    local localeDir = resourceDir .. '/' .. locale .. '.lproj'
    if hs.fs.attributes(localeDir) ~= nil then
      table.insert(dirs, localeDir)
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

function localizeByLoctable(str, resourceDir, localeFile, loc, localesDict)
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
    /<string>.*\.title<\/string>/ {
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
    awk 'BEGIN { printf("{"); first = 1 } /\.title$/ {
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

  local enLocaleDirs = baseLocaleDirs(resourceDir)
  local invSearchFunc = function(str, files)
    if type(files) == 'string' then files = { files } end
    local dirs = appendExtraEnglishLocaleDirs(resourceDir, enLocaleDirs)
    for _, enLocaleDir in ipairs(dirs) do
      for _, fileStem in ipairs(files) do
        local invDict = localesInvDict[fileStem]
        if invDict == nil then
          if hs.fs.attributes(enLocaleDir .. '/' .. fileStem .. '.strings') ~= nil then
            invDict = parseStringsFile(enLocaleDir .. '/' .. fileStem .. '.strings', false, true)
          elseif hs.fs.attributes(enLocaleDir .. '/' .. fileStem .. '.nib') ~= nil
              and hs.fs.attributes(localeDir .. '/' .. fileStem .. '.strings') ~= nil then
            local fullPath = enLocaleDir .. '/' .. fileStem .. '.nib'
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
        if hs.fs.attributes(enLocaleDir .. '/' .. fileStem .. '.storyboardc') ~= nil
            and hs.fs.attributes(localeDir .. '/' .. fileStem .. '.strings') ~= nil then
          local fullPath = enLocaleDir .. '/' .. fileStem .. '.storyboardc'
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

  local enStringsFiles = {}
  if localeFile ~= nil then
    local result = invSearchFunc(str, localeFile)
    if result ~= nil then return result end
  else
    enStringsFiles = collectLocaleFiles(enLocaleDirs[1])
    for i=2, #enLocaleDirs do
      if hs.fs.attributes(enLocaleDirs[i] .. '/Localizable.strings') ~= nil then
        table.insert(enStringsFiles, 'Localizable')
      end
    end
    local enPreferentialStringsFiles = {}
    if #enStringsFiles > 10 then
      enStringsFiles, enPreferentialStringsFiles = filterPreferentialLocaleFiles(enStringsFiles)
    end
    local result = invSearchFunc(str, enPreferentialStringsFiles)
    if result ~= nil then return result end
  end

  local result = searchFunc(str, stringsFiles)
  if result ~= nil then return result end

  result = invSearchFunc(str, enStringsFiles)
  if result ~= nil then return result end
end

local function localizeByNIB(str, localeDir, localeFile, bundleID)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  local enLocaleDir = baseLocaleDirs(resourceDir)[1]
  local enLocale = enLocaleDir:match("^.*/(.*)%.lproj$")
  local compareNIBs = function(file)
    local NIBPath = localeDir .. '/' .. file .. '.nib'
    local enNIBPath = enLocaleDir .. '/' .. file .. '.nib'
    if hs.fs.attributes(NIBPath) == nil or hs.fs.attributes(enNIBPath) == nil then return end
    if hs.fs.attributes(enNIBPath, 'mode') == 'directory' then
      if hs.fs.attributes(enNIBPath .. '/keyedobjects.nib') ~= nil then
        enNIBPath = enNIBPath .. '/keyedobjects.nib'
      else
        enNIBPath = hs.execute(string.format([[ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n']], enNIBPath))
        if enNIBPath == "" then return end
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

    if isBinarayPlist(NIBPath) and isBinarayPlist(enNIBPath) then
      local xmlDir = localeTmpDir .. bundleID .. '/' .. locale
      local xmlPath = xmlDir .. '/' .. file .. '.xml'
      if hs.fs.attributes(xmlPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", xmlDir))
        local _, status = hs.execute(string.format(
            "plutil -convert xml1 '%s' -o '%s'", NIBPath, xmlPath))
        if not status then return end
      end
      local enXmlDir = localeTmpDir .. bundleID .. '/' .. enLocale
      local enXmlPath = enXmlDir .. '/' .. file .. '.xml'
      if hs.fs.attributes(enXmlPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", enXmlDir))
        local _, status = hs.execute(string.format(
            "plutil -convert xml1 '%s' -o '%s'", enNIBPath, enXmlPath))
        if not status then return end
      end
      local diffDir = localeTmpDir .. bundleID .. '/' .. enLocale .. '-' .. locale
      local diffPath = diffDir .. '/' .. file .. '.diff'
      if hs.fs.attributes(diffPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", diffDir))
        hs.execute(string.format(
                  "diff --suppress-common-lines '%s' '%s' > '%s'", enXmlPath, xmlPath, diffPath))
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

    local enJsonDir = localeTmpDir .. bundleID .. '/' .. enLocale
    local enJsonPath = enJsonDir .. '/' .. file .. '.json'
    if hs.fs.attributes(enJsonPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", enJsonDir))
      local _, status = hs.execute(string.format("/usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'",
                                   enNIBPath, enJsonPath))
      if not status then return end
    end
    local jsonDir = localeTmpDir .. bundleID .. '/' .. locale
    local jsonPath = jsonDir .. '/' .. file .. '.json'
    if hs.fs.attributes(jsonPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", jsonDir))
      local _, status = hs.execute(string.format("/usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'",
                                   NIBPath, jsonPath))
      if not status then return end
    end
    local diffDir = localeTmpDir .. bundleID .. '/' .. enLocale .. '-' .. locale
    local diffPath = diffDir .. '/' .. file .. '.diff'
    if hs.fs.attributes(diffPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", diffDir))
      hs.execute(string.format("diff --suppress-common-lines '%s' '%s' > '%s'",
                               enJsonPath, jsonPath, diffPath))
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

local function localizeByQtImpl(str, file)
  local output, status = hs.execute(string.format(
      "zsh scripts/qm_localize.sh '%s' '%s'", file, str))
  if status and output ~= "" then return output end
end

local function localizeByQt(str, localeDir, localesDict)
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
  for file in hs.fs.dir(localeDir .. '/LC_MESSAGES') do
    if file:sub(-3) == ".mo" then
      local output, status = hs.execute(string.format(
        "zsh scripts/mono_localize.sh '%s' '%s'",
        localeDir .. '/LC_MESSAGES/' .. file, str))
      if status and output ~= "" then return output end
    end
  end
end

local function dirNotExistOrEmpty(dir)
  if hs.fs.attributes(dir) == nil then return true end
  for file in hs.fs.dir(dir) do
    if string.sub(file, 1, 1) ~= '.' then return false end
  end
  return true
end

local function localizeByChromium(str, localeDir, bundleID)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  for _, enLocale in ipairs{"en", "English", "Base", "en_US", "en_GB"} do
    if hs.fs.attributes(resourceDir .. '/' .. enLocale .. '.lproj') ~= nil then
      for file in hs.fs.dir(resourceDir .. '/' .. enLocale .. '.lproj') do
        if file:sub(-4) == ".pak" then
          local fullPath = resourceDir .. '/' .. enLocale .. '.lproj/' .. file
          local fileStem = file:sub(1, -5)
          local enTmpBaseDir = string.format(localeTmpDir .. '%s/%s', bundleID, enLocale)
          local enTmpdir = enTmpBaseDir .. '/' .. fileStem
          if dirNotExistOrEmpty(enTmpdir) then
            hs.execute(string.format("mkdir -p '%s'", enTmpBaseDir))
            hs.execute(string.format(
                "scripts/pak -u '%s' '%s'", fullPath, enTmpdir))
          end
          local output, status = hs.execute("grep -lrE '^" .. str .. "$' '" .. enTmpdir .. "' | tr -d '\\n'")
          if status and output ~= "" then
            if hs.fs.attributes(localeDir .. '/' .. file) then
              local matchFile = output:match("^.*/(.*)$")
              local tmpBaseDir = string.format(localeTmpDir .. '%s/%s', bundleID, locale)
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
  end
  return nil
end

local function localizeQt(str, bundleID, appLocale)
  local appPath = hs.application.pathForBundleID(bundleID)
  local resourceDir = appPath .. "/../../share/qt/translations"
  if hs.fs.attributes(resourceDir) == nil then return end
  local appName = appPath:match("^.*/([^/]+)%.app$")
  if appName == nil
      or hs.fs.attributes(resourceDir .. "/" .. appName:lower() .. "_en.qm") == nil then
    return
  end
  local locales = {}
  local prefix = appName:lower() .. '_'
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
    return result, locale
  end
end

local function localizeChatGPT(str, appLocale)
  local cmd
  for _, dir in ipairs { "/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin" } do
    if hs.fs.attributes(dir .. '/lzfse') ~= nil then
      cmd = dir .. '/lzfse'
      break
    end
  end
  if cmd == nil then
    hs.alert.show("lzfse not found, cannot localize ChatGPT.")
    return
  end
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
  if not status then return nil end
  local jsonStr = hs.execute(
      string.format("'%s' -decode -i '%s' -o /dev/stdout", cmd, tmp))
  os.remove(tmp)
  local jsonDict = hs.json.decode(jsonStr)
  return jsonDict[str], locale
end

local appLocaleDir = {}
local localeMatchTmpFile = localeTmpDir .. 'map.json'
if hs.fs.attributes(localeMatchTmpFile) ~= nil then
  appLocaleDir = hs.json.read(localeMatchTmpFile)
  for bundleID, locale in pairs(appLocaleDir) do
    appLocaleDir[bundleID] = hs.fnutils.copy(locale)
  end
end
local appLocaleMap = {}
local appLocaleAssetBuffer = {}
local appLocaleAssetBufferInverse = {}
local localeTmpFile = localeTmpDir .. 'strings.json'
if hs.fs.attributes(localeTmpFile) ~= nil then
  appLocaleMap = hs.json.read(localeTmpFile)
  for bundleID, map in pairs(appLocaleMap) do
    appLocaleMap[bundleID] = hs.fnutils.copy(map)
    for k, v in pairs(appLocaleMap[bundleID]) do
      appLocaleMap[bundleID][k] = hs.fnutils.copy(v)
    end
  end
end

local function localizedStringImpl(str, bundleID, params, force)
  local appLocale, localeFile, localeFramework
  if type(params) == "table" then
    appLocale = params.locale
    localeFile = params.localeFile
    localeFramework = params.framework
  else
    localeFile = params
  end
  if force == nil then force = false end

  if appLocale == nil then
    local locales = applicationLocales(bundleID)
    appLocale = locales[1]
  end

  local result

  if not force then
    result = get(appLocaleMap, bundleID, appLocale, str)
    if result == false then return nil
    elseif result ~= nil then return result end
  end

  if localizationMap[bundleID] ~= nil then
    result = hs.fnutils.indexOf(localizationMap[bundleID], str)
    if result ~= nil then return result end
  end

  if hs.application.pathForBundleID(bundleID) == nil
      or hs.application.pathForBundleID(bundleID) == "" then
    return nil
  end

  local resourceDir, framework = getResourceDir(bundleID, localeFramework)
  if resourceDir == nil then return nil end
  if framework.chromium then
    if findApplication(bundleID) then
      local menuItems = findApplication(bundleID):getMenuItems()
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

  if bundleID == "com.openai.chat" then
    result, locale = localizeChatGPT(str, appLocale)
    return result, appLocale, locale
  elseif bundleID:find("org.qt%-project") ~= nil then
    result, locale = localizeQt(str, bundleID, appLocale)
    return result, appLocale, locale
  end

  local setDefaultLocale = function()
    resourceDir = hs.application.pathForBundleID(bundleID) .. "/Contents/Resources"
    framework = {}
    if hs.fs.attributes(resourceDir) == nil then return false end
    mode = 'lproj'
    locale = getMatchedLocale(appLocale, resourceDir, mode)
    if locale == nil then return false end
    localeDir = resourceDir .. "/" .. locale .. ".lproj"
    return true
  end

  if not framework.mono then mode = 'lproj' end
  if locale == nil then
    locale = get(appLocaleDir, bundleID, appLocale)
    if locale == false then return nil end
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
  local enLocaleDirs = baseLocaleDirs(resourceDir)
  for _, dir in ipairs(enLocaleDirs) do
    if hs.fs.attributes(dir) ~= nil
        and hs.fs.attributes(localeDir).ino == hs.fs.attributes(dir).ino then
      return str
    end
  end

  if appLocaleAssetBuffer[bundleID] == nil
      or get(appLocaleDir, bundleID, appLocale) ~= locale then
    appLocaleAssetBuffer[bundleID] = {}
  end
  local localesDict = appLocaleAssetBuffer[bundleID]

  if framework.chromium then
    result = localizeByChromium(str, localeDir, bundleID)
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

  local defaultAction = function(emptyCache)
    result = localizeByLoctable(str, resourceDir, localeFile, locale, localesDict)
    if result ~= nil then return result end

    if emptyCache or appLocaleAssetBufferInverse[bundleID] == nil
        or get(appLocaleDir, bundleID, appLocale) ~= locale then
      appLocaleAssetBufferInverse[bundleID] = {}
    end
    result = localizeByStrings(str, localeDir, localeFile, localesDict,
                               appLocaleAssetBufferInverse[bundleID])
    if result ~= nil then return result end

    result = localizeByNIB(str, localeDir, localeFile, bundleID)
    if result ~= nil then return result end

    if string.sub(str, -3) == "..." or string.sub(str, -3) == "…" then
      result, appLocale, locale = localizedStringImpl(string.sub(str, 1, -4), bundleID, params)
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

function localizedString(str, bundleID, params, force)
  local result, appLocale, locale = localizedStringImpl(str, bundleID, params, force)
  if appLocale == nil then return result end

  if appLocaleDir[bundleID] == nil then
    appLocaleDir[bundleID] = {}
  end
  if locale == nil then
    appLocaleDir[bundleID][appLocale] = false
    goto L_END_DUMP_LOCALIZED
  else
    appLocaleDir[bundleID][appLocale] = locale
  end

  if appLocaleMap[bundleID] == nil then
    appLocaleMap[bundleID] = {}
  end
  if appLocaleMap[bundleID][appLocale] == nil then
    appLocaleMap[bundleID][appLocale] = {}
  end
  if result ~= nil then
    appLocaleMap[bundleID][appLocale][str] = result
  else
    appLocaleMap[bundleID][appLocale][str] = false
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
  local enLocaleDirs = baseLocaleDirs(resourceDir)
  local searchFunc = function(str, file)
    local dirs = appendExtraEnglishLocaleDirs(resourceDir, enLocaleDirs)
    for _, enLocaleDir in ipairs(dirs) do
      local jsonDict
      if hs.fs.attributes(enLocaleDir .. '/' .. file .. '.strings') ~= nil then
        jsonDict = parseStringsFile(enLocaleDir .. '/' .. file .. '.strings')
      elseif hs.fs.attributes(enLocaleDir .. '/' .. file .. '.nib') ~= nil then
        local fullPath = enLocaleDir .. '/' .. file .. '.nib'
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
      if hs.fs.attributes(enLocaleDir .. '/' .. file .. '.storyboardc') ~= nil then
        local fullPath = enLocaleDir .. '/' .. file .. '.storyboardc'
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

local function delocalizeByNIB(str, localeDir, localeFile, bundleID)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  local enLocaleDir = baseLocaleDirs(resourceDir)[1]
  local enLocale = enLocaleDir:match("^.*/(.*)%.lproj$")
  local compareNIBs = function(file)
    local NIBPath = localeDir .. '/' .. file .. '.nib'
    local enNIBPath = enLocaleDir .. '/' .. file .. '.nib'
    if hs.fs.attributes(NIBPath) == nil or hs.fs.attributes(enNIBPath) == nil then return end
    if hs.fs.attributes(NIBPath, 'mode') == 'directory' then
      if hs.fs.attributes(NIBPath .. '/keyedobjects.nib') ~= nil then
        NIBPath = NIBPath .. '/keyedobjects.nib'
      else
        NIBPath = hs.execute(string.format([[ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n']], NIBPath))
        if NIBPath == "" then return end
      end
    end
    if hs.fs.attributes(enNIBPath, 'mode') == 'directory' then
      if hs.fs.attributes(enNIBPath .. '/keyedobjects.nib') ~= nil then
        enNIBPath = enNIBPath .. '/keyedobjects.nib'
      else
        enNIBPath = hs.execute(string.format([[ls '%s'/keyedobjects* | tail -n 1 | tr -d '\n']], enNIBPath))
        if enNIBPath == "" then return end
      end
    end

    if isBinarayPlist(NIBPath) and isBinarayPlist(enNIBPath) then
      local xmlDir = localeTmpDir .. bundleID .. '/' .. locale
      local xmlPath = xmlDir .. '/' .. file .. '.xml'
      if hs.fs.attributes(xmlPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", xmlDir))
        local _, status = hs.execute(string.format(
            "plutil -convert xml1 '%s' -o '%s'", NIBPath, xmlPath))
        if not status then return end
      end
      local enXmlDir = localeTmpDir .. bundleID .. '/' .. enLocale
      local enXmlPath = enXmlDir .. '/' .. file .. '.xml'
      if hs.fs.attributes(enXmlPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", enXmlDir))
        local _, status = hs.execute(string.format(
            "plutil -convert xml1 '%s' -o '%s'", enNIBPath, enXmlPath))
        if not status then return end
      end
      local diffDir = localeTmpDir .. bundleID .. '/' .. locale .. '-' .. enLocale
      local diffPath = diffDir .. '/' .. file .. '.diff'
      if hs.fs.attributes(diffPath) == nil then
        hs.execute(string.format("mkdir -p '%s'", diffDir))
        hs.execute(string.format("diff --suppress-common-lines '%s' '%s' > '%s'",
                                 xmlPath, enXmlPath, diffPath))
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

    local jsonDir = localeTmpDir .. bundleID .. '/' .. locale
    local jsonPath = jsonDir .. '/' .. file .. '.json'
    if hs.fs.attributes(jsonPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", jsonDir))
      local _, status = hs.execute(string.format("/usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'",
                                   NIBPath, jsonPath))
      if not status then return end
    end
    local enJsonDir = localeTmpDir .. bundleID .. '/' .. enLocale
    local enJsonPath = enJsonDir .. '/' .. file .. '.json'
      if hs.fs.attributes(enJsonPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", enJsonDir))
      local _, status = hs.execute(string.format("/usr/bin/python3 scripts/nib_parse.py dump-json '%s' -o '%s'",
                                   enLocaleDir .. '/' .. file .. '.nib', enJsonPath))
      if not status then return end
    end
    local diffDir = localeTmpDir .. bundleID .. '/' .. locale .. '-' .. enLocale
    local diffPath = diffDir .. '/' .. file .. '.diff'
    if hs.fs.attributes(diffPath) == nil then
      hs.execute(string.format("mkdir -p '%s'", diffDir))
      hs.execute(string.format("diff --suppress-common-lines '%s' '%s' > '%s'",
                               jsonPath, enJsonPath, diffPath))
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
  local output, status = hs.execute(string.format(
      "zsh scripts/qm_delocalize.sh '%s' '%s'", file, str))
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
  for file in hs.fs.dir(localeDir .. '/LC_MESSAGES') do
    if file:sub(-3) == ".mo" then
      local output, status = hs.execute(string.format(
          "zsh scripts/mono_delocalize.sh '%s' '%s'",
          localeDir .. '/LC_MESSAGES/' .. file, str))
      if status and output ~= "" then return output end
    end
  end
end

local function delocalizeByChromium(str, localeDir, bundleID)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  for file in hs.fs.dir(localeDir) do
    if file:sub(-4) == ".pak" then
      local fileStem = file:sub(1, -5)
      local tmpBaseDir = string.format(localeTmpDir .. '%s/%s', bundleID, locale)
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
            local enTmpBaseDir = string.format(localeTmpDir .. '%s/%s', bundleID, enLocale)
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
      end
    end
  end
  return nil
end

local function delocalizeQt(str, bundleID, appLocale)
  local appPath = hs.application.pathForBundleID(bundleID)
  local resourceDir = appPath .. "/../../share/qt/translations"
  if hs.fs.attributes(resourceDir) == nil then return end
  local appName = appPath:match("^.*/([^/]+)%.app$")
  if appName == nil
      or hs.fs.attributes(resourceDir .. "/" .. appName:lower() .. "_en.qm") == nil then
    return
  end
  local locales = {}
  local prefix = appName:lower() .. '_'
  for file in hs.fs.dir(resourceDir) do
    if file:sub(-3) == ".qm" and file:sub(1, #prefix) == prefix then
      table.insert(locales, file:sub(#prefix + 1, -4))
    end
  end
  local locale = getMatchedLocale(appLocale, locales)
  if locale == nil then return nil end
  if locale == 'en' then return str, locale end
  local localeFile = resourceDir .. '/' .. prefix .. locale .. '.qm'
  local result = delocalizeByQtImpl(str .. '\\(&[A-Z]\\)', localeFile)
  if result ~= nil then
    result = result:gsub('[^%s]-&(%a)', '%1')
    return result, locale
  end
  result = delocalizeByQtImpl(str, localeFile)
  if result ~= nil then return result, locale end
end

local function delocalizeZoteroMenu(str, appLocale)
  local resourceDir = hs.application.pathForBundleID("org.zotero.zotero") .. "/Contents/Resources"
  local locales, status = hs.execute("unzip -l \"" .. resourceDir .. "/zotero.jar\" 'chrome/locale/*/' | grep -Eo 'chrome/locale/[^/]*' | grep -Eo '[a-zA-Z-]*$' | uniq")
  if status ~= true then return nil end
  local locale = getMatchedLocale(appLocale, hs.fnutils.split(locales, '\n'))
  if locale == nil then return nil end
  local localeFile = 'chrome/locale/' .. locale .. '/zotero/standalone.dtd'
  local enLocaleFile = 'chrome/locale/en-US/zotero/standalone.dtd'
  local key, status = hs.execute("unzip -p \"" .. resourceDir .. "/zotero.jar\" \"" .. localeFile .. "\""
      .. " | awk '/<!ENTITY .* \"" .. str .. "\">/ { gsub(/<!ENTITY | \"" .. str .. "\">/, \"\"); printf \"%s\", $0 }'")
  if status ~= true then return nil end
  local enValue, status = hs.execute("unzip -p \"" .. resourceDir .. "/zotero.jar\" \"" .. enLocaleFile .. "\""
      .. " | grep '" .. key .. "' | cut -d '\"' -f 2 | tr -d '\\n'")
  if status ~= true then return nil end

  return enValue, locale
end

local function delocalizeMATLABFigureMenu(str, appLocale)
  local resourceDir = hs.application.pathForBundleID("com.mathworks.matlab") .. "/resources/MATLAB"
  local locale = getMatchedLocale(appLocale, resourceDir)
  if locale == nil then return nil end
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
  return nil
end

local deLocaleMap = {}
local deLocaleInversedMap = {}
local menuItemTmpFile = localeTmpDir .. 'menuitems.json'
if hs.fs.attributes(menuItemTmpFile) ~= nil then
  deLocaleMap = hs.json.read(menuItemTmpFile)
  for bundleID, map in pairs(deLocaleMap) do
    deLocaleMap[bundleID] = hs.fnutils.copy(map)
    for k, v in pairs(deLocaleMap[bundleID]) do
      deLocaleMap[bundleID][k] = hs.fnutils.copy(v)
    end
  end
end

local function delocalizedStringImpl(str, bundleID, params)
  local appLocale, localeFile, localeFramework
  if type(params) == "table" then
    appLocale = params.locale
    localeFile = params.localeFile
    localeFramework = params.framework
  else
    localeFile = params
  end

  if appLocale == nil then
    local locales = applicationLocales(bundleID)
    appLocale = locales[1]
  end

  local result = get(deLocaleMap, bundleID, appLocale, str)
  if result == false then return nil
  elseif result ~= nil then return result end

  local resourceDir, framework = getResourceDir(bundleID, localeFramework)
  if resourceDir == nil then return nil end
  if framework.chromium then
    if findApplication(bundleID) then
      local menuItems = findApplication(bundleID):getMenuItems()
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

  if bundleID == "org.zotero.zotero" then
    result, locale = delocalizeZoteroMenu(str, appLocale)
    return result, appLocale, locale
  elseif bundleID == "com.mathworks.matlab" then
    result, locale = delocalizeMATLABFigureMenu(str, appLocale)
    return result, appLocale, locale
  elseif bundleID:find("org.qt%-project") ~= nil then
    result, locale = delocalizeQt(str, bundleID, appLocale)
    return result, appLocale, locale
  end

  if not framework.mono then mode = 'lproj' end
  if locale == nil then
    locale = get(appLocaleDir, bundleID, appLocale)
    if locale == false then return nil end
  end
  if locale == nil then
    locale = getMatchedLocale(appLocale, resourceDir, mode)
    if locale == nil and framework.qt then
      locale, localeDir = getQtMatchedLocale(appLocale, resourceDir)
    end
    if locale == nil then return result, appLocale, locale end
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
  local enLocaleDirs = baseLocaleDirs(resourceDir)
  for _, dir in ipairs(enLocaleDirs) do
    if hs.fs.attributes(dir) ~= nil
        and hs.fs.attributes(localeDir).ino == hs.fs.attributes(dir).ino then
      return str
    end
  end

  local setDefaultLocale = function()
    resourceDir = hs.application.pathForBundleID(bundleID) .. "/Contents/Resources"
    if hs.fs.attributes(resourceDir) == nil then return false end
    mode = 'lproj'
    locale = getMatchedLocale(appLocale, resourceDir, mode)
    if locale == nil then return false end
    localeDir = resourceDir .. "/" .. locale .. ".lproj"
    return true
  end

  if framework.chromium then
    result = delocalizeByChromium(str, localeDir, bundleID)
    if result ~= nil or not setDefaultLocale() then
      return result, appLocale, locale
    end
  end

  if framework.mono then
    result = delocalizeByMono(str, localeDir)
    if result ~= nil then
      if bundleID == "com.microsoft.visual-studio" then
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

  local defaultAction = function(emptyCache)
    result = delocalizeByLoctable(str, resourceDir, localeFile, locale)
    if result ~= nil then return result end

    if emptyCache or deLocaleInversedMap[bundleID] == nil
        or get(appLocaleDir, bundleID, appLocale) ~= locale then
      deLocaleInversedMap[bundleID] = {}
    end
    result = delocalizeByStrings(str, localeDir, localeFile, deLocaleInversedMap[bundleID])
    if result ~= nil then return result end

    result = delocalizeByNIB(str, localeDir, localeFile, bundleID)
    if result ~= nil then return result end

    if string.sub(str, -3) == "..." or string.sub(str, -3) == "…" then
      result, appLocale, locale = delocalizedStringImpl(string.sub(str, 1, -4), bundleID, params)
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

function delocalizedString(str, bundleID, params)
  local result, appLocale, locale = delocalizedStringImpl(str, bundleID, params)
  if appLocale == nil then return result end

  if appLocaleDir[bundleID] == nil then
    appLocaleDir[bundleID] = {}
  end
  if locale == nil then
    appLocaleDir[bundleID][appLocale] = false
    return
  else
    appLocaleDir[bundleID][appLocale] = locale
  end

  if deLocaleMap[bundleID] == nil then
    deLocaleMap[bundleID] = {}
  end
  if deLocaleMap[bundleID][appLocale] == nil then
    deLocaleMap[bundleID][appLocale] = {}
  end
  if result ~= nil then
    deLocaleMap[bundleID][appLocale][str] = result
  else
    deLocaleMap[bundleID][appLocale][str] = false
  end
  return result
end

function localizeCommonMenuItemTitles(locale, bundleID)
  if locale == SYSTEM_LOCALE and bundleID ~= nil then return end

  local resourceDir = '/System/Library/Frameworks/AppKit.framework/Resources'
  local matchedLocale = getMatchedLocale(locale, resourceDir, 'lproj')
  local titleList = {
    'Preferences', 'Preferences…', 'Settings…',
    'Zoom', 'Zoom All',
    'Enter Full Screen', 'Exit Full Screen',
  }
  if locale == SYSTEM_LOCALE then
    titleList = hs.fnutils.concat({
      'File', 'View', 'Window', 'Help',
    }, titleList)
  end
  if getOSVersion() >= OS.Sequoia then
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
      localizationMap.common[localizedTitle] = title
    end
  end
  titleList = { 'Emoji & Symbols' }
  if locale == SYSTEM_LOCALE then
    table.insert(titleList, 'Edit')
  end
  for _, title in ipairs(titleList) do
    local localizedTitle = localizeByLoctable(title, resourceDir, 'InputManager', matchedLocale, {})
    if localizedTitle ~= nil then
      localizationMap.common[localizedTitle] = title
    end
  end

  if locale ~= SYSTEM_LOCALE then
    if localizationMap[bundleID] == nil then
      localizationMap[bundleID] = {}
    end
    for _, title in ipairs { 'File', 'View', 'Window', 'Help' } do
      local localizedTitle = localizeByLoctable(title, resourceDir, 'MenuCommands', matchedLocale, {})
      if localizedTitle ~= nil then
        localizationMap[bundleID][localizedTitle] = title
      end
    end
    local title = 'Edit'
    local localizedTitle = localizeByLoctable(title, resourceDir, 'InputManager', matchedLocale, {})
    if localizedTitle ~= nil then
      localizationMap[bundleID][localizedTitle] = title
    end
  end
end

SYSTEM_LOCALE = systemLocales()[1]
localizeCommonMenuItemTitles(SYSTEM_LOCALE)

function delocalizedMenuItem(title, bundleID, params)
  local defaultTitleMap = localizationMap.common
  local titleMap = localizationMap[bundleID]
  if titleMap ~= nil then
    if titleMap[title] ~= nil then
      return titleMap[title]
    end
  end
  if defaultTitleMap ~= nil then
    if defaultTitleMap[title] ~= nil then
      if titleMap == nil then
        localizationMap[bundleID] = {}
        titleMap = localizationMap[bundleID]
      end
      titleMap[title] = defaultTitleMap[title]
      return titleMap[title]
    end
  end
  local newTitle = delocalizedString(title, bundleID, params)
  if newTitle ~= nil then
    if titleMap == nil then
      localizationMap[bundleID] = {}
      titleMap = localizationMap[bundleID]
    end
    titleMap[title] = newTitle
    if hs.fs.attributes(localeTmpDir) == nil then
      hs.execute(string.format("mkdir -p '%s'", localeTmpDir))
    end
    hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
    hs.json.write(deLocaleMap, menuItemTmpFile, false, true)
  end
  return newTitle
end

function delocalizeMenuBarItems(itemTitles, bundleID, localeFile)
  if localizationMap[bundleID] == nil then
    localizationMap[bundleID] = {}
  end
  local defaultTitleMap = localizationMap.common
  local titleMap = localizationMap[bundleID]
  local result = {}
  local shouldWrite = false
  for _, title in ipairs(itemTitles) do
    -- remove titles starting with non-ascii characters
    local splits = hs.fnutils.split(title, ' ')
    if string.byte(title, 1) <= 127
        and (string.len(title) < 2 or string.byte(title, 2) <= 127)
        and (string.len(title) < 3 or string.byte(title, 3) <= 127)
        and (#splits == 1 or string.byte(splits[2], 1) <= 127) then
      table.insert(result, { title, title })
    else
      if titleMap[title] ~= nil then
        table.insert(result, { title, titleMap[title] })
        goto L_CONTINUE
      end
      if defaultTitleMap ~= nil then
        if defaultTitleMap[title] ~= nil then
          table.insert(result, { title, defaultTitleMap[title] })
          titleMap[title] = defaultTitleMap[title]
          goto L_CONTINUE
        end
      end
      local newTitle = delocalizedString(title, bundleID, localeFile)
      if newTitle ~= nil then
        table.insert(result, { title, newTitle })
        titleMap[title] = newTitle
        shouldWrite = true
      end
      ::L_CONTINUE::
    end
  end
  if shouldWrite then
    if hs.fs.attributes(localeTmpDir) == nil then
      hs.execute(string.format("mkdir -p '%s'", localeTmpDir))
    end
    hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
    hs.json.write(deLocaleMap, menuItemTmpFile, false, true)
  end
  return result
end

function localizedMenuBarItem(title, bundleID, params)
  local appLocale = applicationLocales(bundleID)[1]
  local locTitle = hs.fnutils.indexOf(localizationMap[bundleID] or {}, title)
  if locTitle ~= nil then
    -- "View" may be localized to different strings in the same app (e.g. WeChat)
    if title == 'View' and findApplication(bundleID) then
      if findApplication(bundleID):findMenuItem({ locTitle }) ~= nil then
        return locTitle
      end
    else
      return locTitle
    end
  end
  -- the app may pretend being localized (e.g. Visual Studio Code)
  if findApplication(bundleID) then
    if type(params) == 'table' and params.locale ~= nil
        and params.locale == getMatchedLocale(appLocale, { params.locale }) then
      if findApplication(bundleID):findMenuItem({ title }) ~= nil then
        return title
      end
    end
  end
  if appLocale == getMatchedLocale(SYSTEM_LOCALE, { appLocale }) then
    locTitle = hs.fnutils.indexOf(localizationMap.common, title)
    if locTitle ~= nil then return locTitle end
  end
  locTitle = localizedString(title, bundleID, params)
  if locTitle ~= nil then
    if localizationMap[bundleID] == nil then
      localizationMap[bundleID] = {}
    end
    localizationMap[bundleID][locTitle] = title
    if get(deLocaleMap[bundleID], appLocale, locTitle) ~= nil then
      deLocaleMap[bundleID][appLocale][locTitle] = title
      if hs.fs.attributes(localeTmpDir) == nil then
        hs.execute(string.format("mkdir -p '%s'", localeTmpDir))
      end
      hs.json.write(appLocaleDir, localeMatchTmpFile, true, true)
      hs.json.write(deLocaleMap, menuItemTmpFile, true, true)
    end
    return locTitle
  end
end

function localizedMenuItem(title, bundleID, params)
  local appLocale = applicationLocales(bundleID)[1]
  local locTitle = hs.fnutils.indexOf(localizationMap[bundleID] or {}, title)
  if locTitle ~= nil then
    return locTitle
  end
  if appLocale == getMatchedLocale(SYSTEM_LOCALE, { appLocale }) then
    locTitle = hs.fnutils.indexOf(localizationMap.common, title)
    if locTitle ~= nil then return locTitle end
  end
  locTitle = localizedString(title, bundleID, params)
  if locTitle ~= nil then
    if localizationMap[bundleID] == nil then
      localizationMap[bundleID] = {}
    end
    localizationMap[bundleID][locTitle] = title
    return locTitle
  end
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
  if findApplication("com.surteesstudios.Bartender") == nil then
    return false
  end
  local ok, hiddenItems = hs.osascript.applescript([[
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

function leftClick(position, appName)
  if position.x == nil then position = hs.geometry.point(position) end
  if appName ~= nil then
    local appHere = hs.axuielement.systemElementAtPosition(position)
    while appHere ~= nil and appHere.AXParent ~= nil do
      appHere = appHere.AXParent
    end
    if appHere.AXTitle ~= appName then return false end
  end
  hs.eventtap.leftClick(position)
  return true
end

function leftClickAndRestore(position, appName)
  local mousePosition = hs.mouse.absolutePosition()
  if leftClick(position, appName) then
    hs.mouse.absolutePosition(mousePosition)
    return true
  end
  return false
end

function rightClick(position, appName)
  if position.x == nil then position = hs.geometry.point(position) end
  if appName ~= nil then
    local appHere = hs.axuielement.systemElementAtPosition(position)
    while appHere.AXParent ~= nil do
      appHere = appHere.AXParent
    end
    if appHere.AXTitle ~= appName then return false end
  end
  hs.eventtap.rightClick(position)
  return true
end

function rightClickAndRestore(position, appName)
  local mousePosition = hs.mouse.absolutePosition()
  if rightClick(position, appName) then
    hs.mouse.absolutePosition(mousePosition)
    return true
  end
  return false
end

function clickAppRightMenuBarItem(bundleID, menuItemPath, show)
  local appObject = findApplication(bundleID)
  if appObject == nil then return false end
  local appUIObject = hs.axuielement.applicationElement(appObject)
  local menuBarMenu = getAXChildren(appUIObject, "AXMenuBar", -1, "AXMenuBarItem", 1)

  if type(menuItemPath) ~= 'table' then
    menuItemPath = { menuItemPath }
  end
  if #menuItemPath == 0 and show == nil then
    show = true
  end

  if show then
    if hiddenByBartender(bundleID) then
      hs.osascript.applescript([[
        tell application id "com.surteesstudios.Bartender" to activate "]] .. bundleID .. [[-Item-0"
      ]])
    else
      menuBarMenu:performAction("AXPress")
    end
  end
  if #menuItemPath == 0 then return true end

  local menu = menuBarMenu
  for _, item in ipairs(menuItemPath) do
    local parent = menu
    menu = getAXChildren(parent, "AXMenu", 1, "AXMenuItem", item)
    if menu == nil and type(item) == 'string' then
      local locItem = localizedString(item, bundleID)
      if locItem ~= nil then
        menu = getAXChildren(parent, "AXMenu", 1, "AXMenuItem", locItem)
      end
    end
    if menu == nil then return false end
  end

  menu:performAction("AXPress")
  return true
end

local controlCenterIdentifiers = hs.json.read("static/controlcenter-identifies.json")
local controlCenterMenuBarItemIdentifiers = controlCenterIdentifiers.menubar
function clickControlCenterMenuBarItemSinceBigSur(menuItem)
  if controlCenterMenuBarItemIdentifiers[menuItem] == nil then return false end
  local appUIObject = hs.axuielement.applicationElement(findApplication("com.apple.controlcenter"))
  local menuBarItems = getAXChildren(appUIObject, "AXMenuBar", -1):childrenWithRole("AXMenuBarItem")
  for _, item in ipairs(menuBarItems) do
    if item.AXIdentifier:find(controlCenterMenuBarItemIdentifiers[menuItem]) ~= nil then
      item:performAction("AXPress")
      return true
    end
  end
  return false
end

function clickControlCenterMenuBarItem(menuItem)
  local osVersion = getOSVersion()
  if osVersion >= OS["Big Sur"] then
    return clickControlCenterMenuBarItemSinceBigSur(menuItem)
  end
  return false
end

function controlCenterLocalized(panel, key)
  if key == nil then
    key = panel
  end
  if panel == "Users" and key == "Users" then
    key = "User"
  end
  panel = panel:gsub(" ", ""):gsub("‑", "")
  local result = localizedString(key, "com.apple.controlcenter", panel)
  if result == nil and panel == "Focus" then
    result = localizedString(key, "com.apple.controlcenter",
        { framework = "DoNotDisturb.framework" }, true)
    if result == nil then
      result = localizedString(key, "com.apple.controlcenter",
          { framework = "DoNotDisturbKit.framework" }, true)
    end
  end
  return result
end

function clickRightMenuBarItem(menuBarName, menuItemPath, show)
  if menuBarName == "Control Center" then
    return clickControlCenterMenuBarItem(menuBarName)
  end
  local resourceDir = findApplication("com.apple.controlcenter"):path() .. "/Contents/Resources"
  local newName = menuBarName:gsub(" ", ""):gsub("‑", "")
  if hs.fs.attributes(resourceDir .. '/' .. newName .. '.loctable') ~= nil
      or hs.fs.attributes(resourceDir .. '/en.lproj/' .. newName .. '.strings') ~= nil then
    return clickControlCenterMenuBarItem(menuBarName)
  end
  return clickAppRightMenuBarItem(menuBarName, menuItemPath, show)
end
