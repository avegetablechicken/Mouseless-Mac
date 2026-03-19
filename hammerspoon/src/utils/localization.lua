---@diagnostic disable: lowercase-global

localeTmpDir = hs.fs.temporaryDirectory()
    .. hs.settings.bundleID .. '/locale/'

locMap, delocMap = {}, {}
localizationMapLoaded = { menubar = {}, strings = {} }
localizationFrameworks = {}
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
  if get(localizationMapLoaded, 'menubar', appid) ~= nil then
    delocMap[appid] = tcopy(localizationMapLoaded['menubar'][appid])
  else
    delocMap[appid] = nil
  end
  if get(localizationMapLoaded, 'strings', appid) ~= nil then
    locMap[appid] = tcopy(localizationMapLoaded['strings'][appid])
  else
    locMap[appid] = nil
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

function applicationLocale(appid)
  -- locale of apps whose localization is enabled by Qt, Electron or Java
  -- cannot be aquired in preferences files
  if appid == "com.tencent.xinWeChat" then
    if applicationVersion(appid) >= "4" then  -- Qt
      local app = find(appid)
      if app then
        local file = getc(toappui(app),
            AX.MenuBar, 1, AX.MenuBarItem, 3)
        if file == nil then return SYSTEM_LOCALE end
        if file.AXTitle == "File" then return "en", true
        elseif file.AXTitle == localizedString('File', {
          locale = 'zh_CN',
          localeFile = 'MenuCommands',
          framework = "AppKit.framework",
        }) then return "zh-Hans", true
        else
          return 'zh-Hant', true
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
      if locale then return locale, true
      else return SYSTEM_LOCALE end
    elseif localizationFrameworks[appid].java then
      local locale
      local appContentPath = hs.application.pathForBundleID(appid) .. "/Contents"
      local jimage, status = hs.execute(strfmt([[
        find '%s' -type f -name jimage | tr -d '\n'
      ]], appContentPath))
      if status and jimage ~= "" then
        local app = find(appid)
        if app then
          local resourceDir = jimage:sub(1, #jimage - #'/bin/jimage')
          locale = javaLocale(app, resourceDir, localizationFrameworks[appid])
        end
      end
      if locale then return locale, true
      else return SYSTEM_LOCALE end
    elseif localizationFrameworks[appid].qt then
      local app, locale = find(appid)
      if app then
        if appid == "barrier" then
          local menuBarMenuItems = getc(toappui(app),
              AX.MenuBar, -1, AX.MenuBarItem, 1, AX.Menu, 1, AX.MenuItem)
          local baseTitles = { "Start", "Stop", "Show Log", "Hide", "Show", "Quit" }
          local idx = 0
          for _, menu in ipairs(menuBarMenuItems or {}) do
            if menu.AXTitle ~= "" then
              idx = idx + 1
              if menu.AXTitle ~= baseTitles[idx] then
                locale = qtExecutableLocale(app, menu.AXTitle,
                    localizationFrameworks[appid].qt)
                break
              end
            end
          end
        end
      end
      if locale then return locale, true
      else return 'en' end
    end
  end

  local cached = getAppPreferenceCacheEntry(appid)
  if cached and cached.locale ~= nil then
    if cached.locale == false then
      return SYSTEM_LOCALE
    end
    return cached.locale
  end

  if FLAGS["APP_LAUNCHING"] then
    local locales = hs.execute(
        strfmt("defaults read %s AppleLanguages | tr -d '()\" \\n'", appid))
    if locales ~= "" then
      local locale = strsplit(locales, ',')[1]
      return setAppPreferenceCacheField(appid, "locale", locale)
    end
  end

  local errorReadingDefaults = false
  local containerPlistPath, plistPath = getAppPreferencePaths(appid)

  if containerPlistPath ~= nil then
    local defaults = hs.plist.read(containerPlistPath)
    if defaults then
      local locales = defaults.AppleLanguages
      if locales ~= nil then
        return setAppPreferenceCacheField(appid, "locale", locales[1])
      end
    else
      errorReadingDefaults = true
    end
  end
  if plistPath ~= nil then
    local defaults = hs.plist.read(plistPath)
    if defaults then
      local locales = defaults.AppleLanguages
      if locales ~= nil then
        return setAppPreferenceCacheField(appid, "locale", locales[1])
      end
    else
      errorReadingDefaults = true
    end
  end
  if errorReadingDefaults then
    local locales = hs.execute(
        strfmt("defaults read %s AppleLanguages | tr -d '()\" \\n'", appid))
    if locales ~= "" then
      local locale = strsplit(locales, ',')[1]
      return setAppPreferenceCacheField(appid, "locale", locale)
    end
  end
  setAppPreferenceCacheField(appid, "locale", false)
  return SYSTEM_LOCALE
end

function getResourceDir(appid, frameworkNames)
  if frameworkNames == nil then
    frameworkNames = localizationFrameworks[appid]
  end
  local resourceDirs = {}
  local frameworks = {}
  local appContentPath
  if appid ~= '__macos' then
    appContentPath = hs.application.pathForBundleID(appid) .. "/Contents"
  end
  if appContentPath and not exists(appContentPath) then
    resourceDirs = { hs.application.pathForBundleID(appid) .. "/WrappedBundle/.." }
    frameworks = {{}}
  elseif frameworkNames ~= nil then
    local frameworkDir
    if type(frameworkNames) == 'string' or #frameworkNames == 0 then
      frameworkNames = { frameworkNames }
    end
    for _, name in ipairs(frameworkNames) do
      local resourceDir
      local framework = {}
      if type(name) == 'string' and exists(name) then
        frameworkDir = name
      elseif appContentPath ~= nil then
        if type(name) == 'table'then
          if name.electron and
              exists(appContentPath .. "/Resources/app.asar") then
            resourceDir = appContentPath .. "/Resources"
            framework.electron = name.electron
          elseif name.java then
            local jimage, status = hs.execute(strfmt([[
              find '%s' -type f -name jimage | tr -d '\n'
            ]], appContentPath))
            if status and jimage ~= "" then
              resourceDir = jimage:sub(1, #jimage - #'/bin/jimage')
              framework.java = name.java
            end
          end
        else
          local _, status = hs.execute(strfmt([[
            find '%s' -type f -path '%s/Resources/%s/*.properties' | tr -d '\n'
          ]], appContentPath, appContentPath, name))
          if status and _ ~= "" then
            resourceDir = appContentPath .. '/Resources/' .. name
            framework.properties = true
          end

          _, status = hs.execute(strfmt([[
            find '%s' -type f -path '%s/Resources/%s/*.dtd' | tr -d '\n'
          ]], appContentPath, appContentPath, name))
          if status and _ ~= "" then
            resourceDir = appContentPath .. '/Resources/' .. name
            framework.dtd = true
          end

          _, status = hs.execute(strfmt([[
            find '%s' -type f -path '%s/Resources/%s/*.ftl' | tr -d '\n'
          ]], appContentPath, appContentPath, name))
          if status and _ ~= "" then
            resourceDir = appContentPath .. '/Resources/' .. name
            framework.ftl = true
          end

          if resourceDir == nil or resourceDir == "" then
            frameworkDir = hs.execute(strfmt([[
              find '%s' -type d -name '%s' | head -n 1 | tr -d '\n'
            ]], appContentPath, name))
          end
        end
      end
      if (resourceDir == nil or resourceDir == "")
          and (frameworkDir == nil or frameworkDir == "")
          and type(name) == 'string' then
        for _, searchDir in ipairs {
          '/System/Library/Frameworks',
          '/System/Library/PrivateFrameworks',
          '/System/iOSSupport/System/Library/PrivateFrameworks',
        } do
          if exists(searchDir .. '/' .. name) then
            frameworkDir = searchDir .. '/' .. name
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
          end
        end
      end
      if resourceDir ~= nil and resourceDir ~= "" then
        tinsert(resourceDirs, resourceDir)
        tinsert(frameworks, framework)
      end
    end
    goto END_GET_RESOURCE_DIR
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
            resourceDirs = { chromiumDirs[1] .. "/Resources" }
            frameworks = {{ chromium = true }}
            goto END_GET_RESOURCE_DIR
          end
        end
      end
    end

    if exists(appContentPath .. "/Resources/qt.conf") then
      resourceDirs = { appContentPath .. "/Resources" }
      frameworks = {{ qt = true }}
      goto END_GET_RESOURCE_DIR
    end

    local monoLocaleDirs, status = hs.execute(strfmt([[
      find '%s' -type f -path '*/locale/*/LC_MESSAGES/*.mo' \
      | awk -F'/locale/' '{print $1}' | uniq
    ]], appContentPath))
    if status and monoLocaleDirs:sub(1, -2) ~= "" then
      monoLocaleDirs = strsplit(monoLocaleDirs:sub(1, -2), '\n')
      if #monoLocaleDirs == 1 then
        resourceDirs = { monoLocaleDirs[1] .. "/locale" }
        frameworks = {{ mono = true }}
        goto END_GET_RESOURCE_DIR
      end
    end
  end

  if #resourceDirs == 0 then
    resourceDirs = { appContentPath .. "/Resources" }
    frameworks = {{}}
  end

  ::END_GET_RESOURCE_DIR::
  for i=#resourceDirs,1,-1 do
    if not exists(resourceDirs[i]) then
      tremove(resourceDirs, i)
      tremove(frameworks, i)
    end
  end
  return resourceDirs, frameworks
end

function getBestMatchedLocale(appLocale, locales, combineExtras, multiplePerfectMatch)
  local bestMatch, bestScore = nil, -1
  for _, locale in ipairs(locales) do
    if locale.scriptCode == appLocale.scriptCode
        and locale.countryCode == appLocale.countryCode then
      if not multiplePerfectMatch then
        bestMatch = locale
        break
      end
      bestMatch = bestMatch or locale
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

function getDefaultMatchedLocale(appLocale, localeSource, dirExt)
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

function getQtMatchedLocale(appLocale, resourceDir)
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
    if file ~= '.' and file ~= '..' then
      if isdir(resourceDir .. '/' .. file) then
        tinsert(dirs, resourceDir .. '/' .. file)
      end
    end
  end
  local matchedLocales = {}
  for _, dir in ipairs(dirs) do
    for file in hs.fs.dir(dir) do
      if file:sub(-3) == '.qm' then
        local lowerFile = file:sub(1, -4):lower()
        local fileSplits = strsplit(lowerFile:gsub('_', '-'), '-')
        for i = #fileSplits, math.max(1, #fileSplits - 2), -1 do
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
            local localeStartPos = 1
            for j = 1, i - 1 do
              localeStartPos = localeStartPos + #fileSplits[j] + 1
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

local qtExecutableLocales = {}
function getQtExecutableLocales(appid, executable, prefix)
  if qtExecutableLocales[appid] then
    return qtExecutableLocales[appid]
  end

  local tmpBaseDir = localeTmpDir .. appid
  local localesFile = tmpBaseDir .. '/locales.json'
  if exists(localesFile) then
    qtExecutableLocales[appid] = hs.json.read(localesFile)
  else
    local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
    if cmd == nil then return end
    local localesStr, ok = hs.execute(strfmt(
        [[/usr/bin/python3 scripts/qt_locales.py '%s' '%s']], executable, prefix))
    if ok then
      local localeFiles = strsplit(localesStr, "\n")
      localeFiles[#localeFiles] = nil
      qtExecutableLocales[appid] = localeFiles
      mkdir(tmpBaseDir)
      hs.json.write(qtExecutableLocales[appid], localesFile)
    end
  end
  return qtExecutableLocales[appid]
end

local jimageLocales = {}
function getJavaLocales(appid, javahome, path)
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

function getJavaMatchedLocale(appid, appLocale, javahome, path)
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
function getElectronLocales(appid, localesPath)
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

function getElectronMatchedLocale(appid, appLocale, localesPath)
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

function getMatchedLocale(appid, appLocale, resourceDir, framework, buffer)
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
baseLocales = {
  "Base", "en", "English"
}
function getBaseLocaleDirs(resourceDir)
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
extraEnglishLocales = {
  "en_US", "en_GB"
}
function appendExtraEnglishLocaleDirs(resourceDir, baseDirs)
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

function collectLocaleFiles(localeDir, option)
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

preferentialLocaleFilePatterns = {
  "(.-)MainMenu(.-)", "Menu", "MenuBar", "MenuItems",
  "Localizable", "(.-)Localizable", "Main", "MainWindow",
}

function filterPreferentialLocaleFiles(localeFiles)
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


local function loadLocalizationPart(part)
  local path = hs.configdir .. "/src/utils/localization/" .. part .. ".lua"
  local chunk, err = loadfile(path, "t", _ENV)
  if not chunk then
    error(err)
  end
  chunk()
end

loadLocalizationPart("common")
loadLocalizationPart("custom")

appLocaleDir = {}
localeMatchTmpFile = localeTmpDir .. 'map.json'
if exists(localeMatchTmpFile) then
  appLocaleDir = hs.json.read(localeMatchTmpFile)
  for appid, locale in pairs(appLocaleDir) do
    appLocaleDir[appid] = tcopy(locale)
  end
end
appLocaleMap = {}
appLocaleAssetBuffer = {}
appLocaleAssetBufferInverse = {}
localeTmpFile = localeTmpDir .. 'strings.json'
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
    local result = locMap[appid][str]
    if result ~= nil then return result end
  end

  if appLocale == nil then
    appLocale = appid ~= '__macos' and applicationLocale(appid)
        or SYSTEM_LOCALE
  end

  local result, locale

  if not force then
    locale = get(appLocaleDir, appid, appLocale)
    if locale then
      result = get(appLocaleMap, appid, locale, str)
      if result ~= nil then return result end
    end
  end

  if appid ~= '__macos' and not installed(appid) then
    return nil
  end

  if appid == "com.openai.chat" then
    result, locale = localizeChatGPT(str, appLocale)
    if result ~= nil then
      return result, appLocale, locale
    end
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
  elseif localizationFrameworks[appid] and localizationFrameworks[appid].qt then
    result, locale = localizeByQtExecutable(str, appid, appLocale,
                                            localizationFrameworks[appid].qt)
    return result, appLocale, locale
  elseif appid == "com.kingsoft.wpsoffice.mac" then
    result, locale = localizeWPS(str, appLocale, localeFile)
    return result, appLocale, locale
  elseif appid == "com.tencent.xinWeChat" and applicationVersion(appid) >= "4" then
    result, locale = localizeWeChat(str, appLocale)
    return result, appLocale, locale
  end

  local resourceDirs, frameworks = getResourceDir(appid, localeFramework)
  if resourceDirs == nil then return nil end
  if tfind(frameworks, function(f) return f.chromium end) then
    if find(appid) then
      local menuBarItems = getMenuBarItems(find(appid), true) or {}
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

  local maybeStrIsInBaseLocale = false
  for i=1,#resourceDirs do
  local resourceDir, framework = resourceDirs[i], frameworks[i]

  local localeDir
  locale, localeDir, resourceDir, framework =
      getMatchedLocale(appid, appLocale, resourceDir, framework, appLocaleDir)
  if locale == nil then return end
  assert(framework)

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
    if result == true then maybeStrIsInBaseLocale = true result = nil end
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

  end

  if str:sub(-3) == "..." or str:sub(-3) == "…" then
    result, appLocale, locale =
        localizedStringImpl(str:sub(1, -4), appid, params)
    if result ~= nil then
      return result .. str:sub(-3), appLocale, locale
    end
  end

  if result == nil then
    for i=1,#resourceDirs do
      local resourceDir, framework = resourceDirs[i], frameworks[i]
      local localeDir
      locale, localeDir, resourceDir, framework =
          getMatchedLocale(appid, appLocale, resourceDir, framework, appLocaleDir)
      if not framework.electron and not framework.java
          and (not framework.qt or (type(localeDir) ~= 'table' and isdir(localeDir))) then
        local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
        for _, dir in ipairs(baseLocaleDirs) do
          if exists(dir) and hs.fs.attributes(localeDir).ino
                            == hs.fs.attributes(dir).ino then
            if appid == "__macos" or appid:match("^com%.apple%.") then
              return str, appLocale, locale
            else
              return true, appLocale, locale
            end
          end
        end
      end
    end
  end

  return maybeStrIsInBaseLocale and str or nil, appLocale, locale
end

function localizedString(str, appid, params, force)
  if appid.bundleID then
    appid = appid:bundleID()
  elseif appid.application then
    appid = appid:application():bundleID()
  elseif type(appid) == 'table' then
    force = params params = appid appid = nil
  end
  if appid == nil and (type(params) ~= 'table' or params.framework == nil) then
    return
  end
  appid = appid or '__macos'
  local result, appLocale, locale =
      localizedStringImpl(str, appid, params, force)
  if appLocale == nil or (force and result == nil) then return result end

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
  if appLocaleMap[appid][locale] == nil then
    appLocaleMap[appid][locale] = {}
  end
  if result ~= nil then
    if result ~= true then
      appLocaleMap[appid][locale][str] = result
    end
  else
    appLocaleMap[appid][locale][str] = false
  end

  ::L_END_DUMP_LOCALIZED::
  if not exists(localeTmpDir) then
    hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
  end
  hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
  if result ~= true then
    hs.json.write(appLocaleMap, localeTmpFile, false, true)
    return result
  else
    return str
  end
end


deLocaleMap = {}
deLocaleInversedMap = {}
menuItemTmpFile = localeTmpDir .. 'menubar.json'
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

  local result, locale

  if not force then
    locale = get(appLocaleDir, appid, appLocale)
    if locale then
      result = get(deLocaleMap, appid, locale, str)
      if result ~= nil then return result end
    end
  end

  if appid ~= '__macos' and not installed(appid) then
    return nil
  end

  if appid == "com.openai.chat" then
    result, locale = delocalizeChatGPT(str, appLocale)
    if result ~= nil then
      return result, appLocale, locale
    end
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
  elseif localizationFrameworks[appid] and localizationFrameworks[appid].qt then
    result, locale = delocalizeByQtExecutable(str, appid, appLocale,
                                              localizationFrameworks[appid].qt)
    return result, appLocale, locale
  elseif appid == "com.kingsoft.wpsoffice.mac" then
    result, locale = delocalizeWPS(str, appLocale, localeFile)
    return result, appLocale, locale
  elseif appid == "com.tencent.xinWeChat" and applicationVersion(appid) >= "4" then
    result, locale = delocalizeWeChat(str, appLocale)
    return result, appLocale, locale
  end

  local resourceDirs, frameworks = getResourceDir(appid, localeFramework)
  if resourceDirs == nil then return nil end
  if tfind(frameworks, function(f) return f.chromium end) then
    if find(appid) then
      local menuBarItems = getMenuBarItems(find(appid), true) or {}
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

  for i=1,#resourceDirs do
  local resourceDir, framework = resourceDirs[i], frameworks[i]

  local localeDir
  locale, localeDir, resourceDir, framework =
      getMatchedLocale(appid, appLocale, resourceDir, framework, appLocaleDir)
  if locale == nil then return end
  assert(framework)

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

  end

  if str:sub(-3) == "..." or str:sub(-3) == "…" then
    result, appLocale, locale =
        delocalizedStringImpl(str:sub(1, -4), appid, params)
    if result ~= nil then
      return result .. str:sub(-3), appLocale, locale
    end
  end

  if result == nil then
    for i=1,#resourceDirs do
      local resourceDir, framework = resourceDirs[i], frameworks[i]
      local localeDir
      locale, localeDir, resourceDir, framework =
          getMatchedLocale(appid, appLocale, resourceDir, framework, appLocaleDir)
      if not framework.electron and not framework.java
          and (not framework.qt or (type(localeDir) ~= 'table' and isdir(localeDir))) then
        local baseLocaleDirs = getBaseLocaleDirs(resourceDir)
        for _, dir in ipairs(baseLocaleDirs) do
          if exists(dir) and hs.fs.attributes(localeDir).ino
                            == hs.fs.attributes(dir).ino then
            return true, appLocale, locale
          end
        end
      end
    end
  end

  return nil, appLocale, locale
end

function delocalizedString(str, appid, params, force)
  if appid.bundleID then
    appid = appid:bundleID()
  elseif appid.application then
    appid = appid:application():bundleID()
  elseif type(appid) == 'table' then
    force = params params = appid appid = nil
  end
  if appid == nil and (type(params) ~= 'table' or params.framework == nil) then
    return
  end
  appid = appid or '__macos'
  local result, appLocale, locale =
      delocalizedStringImpl(str, appid, params, force)
  if appLocale == nil or (force and result == nil) then return result end

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
  if deLocaleMap[appid][locale] == nil then
    deLocaleMap[appid][locale] = {}
  end
  if result ~= nil then
    if result ~= true then
      deLocaleMap[appid][locale][str] = result
    end
  else
    deLocaleMap[appid][locale][str] = false
  end

  ::L_END_DUMP_DELOCALIZED::
  if not exists(localeTmpDir) then
    hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
  end
  hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
  if result ~= true then
    hs.json.write(deLocaleMap, menuItemTmpFile, false, true)
    return result
  else
    return str
  end
end

function electronLocale(app, localesPath)
  local appid = app:bundleID()
  local menubar = getMenuBarItems(app, true) or {}
  if #menubar == 0 then return end
  local items = tifilter(menubar, function(item)
    return delocMap.common[item.AXTitle] == nil
        and tindex(delocMap.common, item.AXTitle) == nil
  end)
  if #items == 0 then
    for locale, dict in pairs(appLocaleMap['__macos'] or {}) do
      local allLocalized = all(menubar, function(item)
        return tindex(dict, item.AXTitle) ~= nil
      end)
      if allLocalized then return locale end
    end
    return
  end

  local localeInfo = getElectronLocales(appid, localesPath.electron)
  if localeInfo == nil then return end
  local locales = localeInfo['locale']
  local localeFiles = localeInfo['file']
  for _, locale in ipairs(locales) do
    local allLocalized = all(items, function(item)
      return get(deLocaleMap, appid, locale, item.AXTitle) ~= nil
    end)
    if allLocalized then return locale end
  end
  for _, locale in ipairs(locales) do
    local matchedFiles = {}
    for _, file in ipairs(localeFiles) do
      if file:sub(1, #locale + 1) == locale .. '/' then
        tinsert(matchedFiles, file:sub(#locale + 2))
      end
    end
    local allLocalized = all(items, function(item)
      local result = delocalizeByElectron(
        item.AXTitle, appid, locale, matchedFiles, localesPath.electron)
      if result == nil then return false end
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
      return true
    end)
    if allLocalized then return locale end
  end
end

function javaLocale(app, javahome, localesPath)
  local appid = app:bundleID()
  local menubar = getMenuBarItems(app, true) or {}
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

local availableLanguages = {}
foreach(hs.host.locale.availableLocales(), function(locale)
  local pos = locale:find('_')
  local lang = pos and locale:sub(1, pos - 1) or locale
  availableLanguages[lang] = true
end)
function qtExecutableLocale(app, str, prefix)
  local appid = app:bundleID()
  local executable = hs.application.infoForBundleID(appid).CFBundleExecutable
  executable = hs.application.pathForBundleID(appid)
      .. '/Contents/MacOS/' .. executable
  local localeFiles = getQtExecutableLocales(appid, executable, prefix)
  if localeFiles == nil then return end
  local tmpBaseDir = localeTmpDir .. appid
  mkdir(tmpBaseDir)
  if not exists(tmpBaseDir .. '/' .. localeFiles[1]:sub(1, -4) .. '.po') then
    extractQMSegments(executable, tmpBaseDir, localeFiles)
  end
  for _, file in ipairs(localeFiles) do
    local po = file:sub(1, -4) .. '.po'
    if exists(tmpBaseDir .. '/' .. po) then
      local _, ok = hs.execute(strfmt(
          [[cat '%s' | grep '%s' | grep '^msgstr ']], tmpBaseDir .. '/' .. po, str))
      if ok then
        local start = 1
        while start and start < #po do
          local tmp = po:gsub('-', '_')
          local pos = tmp:find('_', start)
          if pos == nil or availableLanguages[po:sub(start, pos - 1)] then
            return po:sub(start, #po - 3)
          else
            start = pos + 1
          end
        end
      end
    end
  end
end

-- some menu items are managed by system framework
-- the localized strings of their titles are managed here
-- should be use when localizing / delocalizing menu bar items
-- and delocalizing menu items whose keybindings contain 'fn'
function localizeCommonMenuItemTitles(locale, target)
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
    local localizedTitle
    if matchedLocale == 'en' then
      localizedTitle = title
    else
      localizedTitle = cachedLocMap[title] or localizeByLoctable(
        title, resourceDir, 'MenuCommands', matchedLocale, localesDict)
    end
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
  local localizedTitle
  if matchedLocale == 'en' then
    localizedTitle = title
  else
    localizedTitle = cachedLocMap[title] or localizeByLoctable(
        title, resourceDir, 'InputManager', matchedLocale, localesDict)
  end
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
    local localizedTitle
    if matchedLocale == 'en' then
      localizedTitle = title
    else
      localizedTitle = tindex(cachedDelocMap, title) or localizeByLoctable(
          title, resourceDir, 'MenuCommands', matchedLocale, localesDict)
    end
    if localizedTitle ~= nil then
      delocMap.common[localizedTitle] = title
      if cachedDelocMap[localizedTitle] == nil then
        cachedDelocMap[localizedTitle] = title
        shouldSave = true
      end
    end
  end
  local title = 'Emoji & Symbols'
  local localizedTitle
  if matchedLocale == 'en' then
    localizedTitle = title
  else
    localizedTitle = tindex(cachedDelocMap, title) or localizeByLoctable(
        title, resourceDir, 'InputManager', matchedLocale, localesDict)
  end
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
localizeCommonMenuItemTitles(SYSTEM_LOCALE, 'common')

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
  if newTitle == nil or newTitle == title then
    newTitle = delocalizedString(title, appid, params, true)
  end
  if newTitle then
    if titleMap == nil then
      delocMap[appid] = {}
      titleMap = delocMap[appid]
    end
    titleMap[title] = newTitle
  end
  return newTitle
end

function delocalizeMenuBarItems(itemTitles, appid, params)
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
      elseif params == nil or params.localeFile == nil then
        local paramsCopy = type(params) == 'table' and tcopy(params) or {}
        paramsCopy.localeFile = menuItemLocaleFilePatterns
        delocTitle = delocalizedString(title, appid, paramsCopy)
        if delocTitle == nil then
          delocTitle = delocalizedString(title, appid, params, true)
        end
        titleMap[title] = delocTitle
      else
        delocTitle = delocalizedString(title, appid, params)
        titleMap[title] = delocTitle
      end
      if not delocTitle then
        local params = {
          framework = "UIKitMacHelper.framework",
          localeFile = "MainMenu"
        }
        delocTitle = delocalizedString(title, params)
        titleMap[title] = delocTitle
      end
      if delocTitle then
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
    if locTitle then
      -- "View" may be localized to different strings in the same app (e.g. WeChat)
      if title == 'View' and find(appid) then
        if find(appid):findMenuItem{ locTitle } ~= nil then
          return locTitle
        end
      elseif type(locTitle) == 'table' then
        local app = find(appid)
        for _, t in ipairs(locTitle) do
          if app:findMenuItem{ t } ~= nil then
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

  local appLocale
  if type(params) == 'table' and params.locale ~= nil then
    appLocale = params.locale
  else
    appLocale = applicationLocale(appid)
    -- the app may pretend being localized (e.g. Visual Studio Code)
    if find(appid) and find(appid):findMenuItem{ title } ~= nil then
      return title
    end
  end

  if appLocale == matchLocale(SYSTEM_LOCALE, { appLocale }) then
    local locTitle = locMap.common[title]
    if locTitle then
      if (title == 'View' or title == 'Edit') and find(appid) then
        if find(appid):findMenuItem{ locTitle } ~= nil then
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
  if locTitle == nil or locTitle == title then
    locTitle = localizedString(title, appid, params, true)
  end
  if locTitle then
    if delocMap[appid] == nil then
      delocMap[appid] = {}
    end
    delocMap[appid][locTitle] = title
    local locale = get(appLocaleDir, appid, appLocale)
    if locale and get(deLocaleMap[appid], locale, locTitle) ~= nil then
      deLocaleMap[appid][locale][locTitle] = title
      if not exists(localeTmpDir) then
        hs.execute(strfmt("mkdir -p '%s'", localeTmpDir))
      end
      hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
      hs.json.write(deLocaleMap, menuItemTmpFile, false, true)
    end
    return locTitle
  end
end

function applicationValidLocale(appid, menuBarItems)
  local appLocale, valid = applicationLocale(appid)
  if valid then return appLocale end
  local resourceDirs, frameworks = getResourceDir(appid)
  if tfind(frameworks, function(f) return f.chromium end) then
    if find(appid) then
      if menuBarItems == nil then
        menuBarItems = getMenuBarItems(find(appid)) or {}
      end
      if #menuBarItems > 1 then
        for _, title in ipairs{ 'File', 'Edit', 'Window', 'Help' } do
          for i=2,#menuBarItems do
            if menuBarItems[i].AXTitle == title then
              return 'en'
            end
          end
        end
      end
    end
  end
  if resourceDirs == nil then return end
  for i=1,#resourceDirs do
    local locale = getMatchedLocale(appid, appLocale,
        resourceDirs[i], frameworks[i], appLocaleDir)
    if locale then
      if get(appLocaleDir, appid, appLocale) == nil then
        if appLocaleDir[appid] == nil then
          appLocaleDir[appid] = {}
        end
        appLocaleDir[appid][appLocale] = locale
        hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
      end
      return locale
    end
  end
end

function displayName(appid)
  local basename = hs.application.nameForBundleID(appid)
  local appLocale = applicationLocale(appid)
  local locale = get(appLocaleDir, appid, appLocale)
  local appname
  if locale then
    appname = get(appLocaleMap, appid, locale, basename)
  end
  if appname == nil then
    appname = get(appLocaleMap, appid, appLocale, basename)
  end
  if appname ~= nil then return appname end
  if locale == false then return basename end

  local resourceDir = hs.application.pathForBundleID(appid)
      .. "/Contents/Resources"
  if locale == nil or not exists(resourceDir .. "/" .. locale .. ".lproj") then
    locale = getDefaultMatchedLocale(appLocale, resourceDir, 'lproj')
  end

  if locale and exists(resourceDir .. '/InfoPlist.loctable') then
    appname = localizeByLoctable('CFBundleDisplayName',
                                 resourceDir, 'InfoPlist', locale)
        or localizeByLoctable('CFBundleName',
                              resourceDir, 'InfoPlist', locale)
  elseif locale then
    local localeDir = resourceDir .. "/" .. locale .. ".lproj"
    if exists(localeDir .. '/InfoPlist.strings') then
      local jsonDict = parseStringsFile(localeDir .. '/InfoPlist.strings')
      appname = jsonDict['CFBundleDisplayName'] or jsonDict['CFBundleyName']
    end
  end

  if appname == nil then appname = basename end
  if appLocaleMap[appid] == nil then
    appLocaleMap[appid] = {}
  end
  if locale and get(appLocaleDir, appid, appLocale) == nil then
    if appLocaleDir[appid] == nil then
      appLocaleDir[appid] = {}
    end
    appLocaleDir[appid][appLocale] = locale
    hs.json.write(appLocaleDir, localeMatchTmpFile, false, true)
  end
  if locale == nil then locale = appLocale end
  if appLocaleMap[appid][locale] == nil then
    appLocaleMap[appid][locale] = {}
  end
  appLocaleMap[appid][locale][basename] = appname
  hs.json.write(appLocaleMap, localeTmpFile, false, true)

  return appname
end
