---@diagnostic disable: lowercase-global

function localizeQt(str, appid, appLocale)
  local appPath = hs.application.pathForBundleID(appid)
  local resourceDir = appPath .. "/../../translations"
  if not exists(resourceDir) then
    resourceDir = appPath .. "/../Qt/translations"
  end
  if not exists(resourceDir) then
    resourceDir = appPath .. "/../../share/qt/translations"
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

local wpsLocCache = {}
local function ensureWpsCache(resourceDir, locale)
  local key = resourceDir .. '/' .. locale
  if wpsLocCache[key] ~= nil then return wpsLocCache[key] end
  local cacheDir = localeTmpDir .. "com.kingsoft.wpsoffice.mac/" .. locale
  local enDir = resourceDir .. "/en_US"
  local tgtDir = resourceDir .. "/" .. locale
  -- Check if cache already exists by looking for any _loc.json file
  local cacheExists = false
  if exists(cacheDir) then
    for file in hs.fs.dir(cacheDir) do
      if file:sub(-9) == "_loc.json" then cacheExists = true; break end
    end
  end
  if not cacheExists then
    mkdir(localeTmpDir .. "com.kingsoft.wpsoffice.mac")
    mkdir(cacheDir)
    hs.execute(strfmt(
      [[/usr/bin/python3 scripts/wps_qm_parse.py cache-wps '%s' '%s' -o '%s']],
      enDir, tgtDir, cacheDir))
  end
  -- Load all cached maps for this locale
  local maps = { loc = {}, deloc = {} }
  if exists(cacheDir) then
    for file in hs.fs.dir(cacheDir) do
      if file:sub(-9) == "_loc.json" then
        local name = file:sub(1, -10)
        maps.loc[name] = hs.json.read(cacheDir .. '/' .. file)
      elseif file:sub(-11) == "_deloc.json" then
        local name = file:sub(1, -12)
        maps.deloc[name] = hs.json.read(cacheDir .. '/' .. file)
      end
    end
  end
  wpsLocCache[key] = maps
  return maps
end


function localizeWPS(str, appLocale, localeFile)
  if appLocale:sub(1, 2) == 'en' then
    return str, 'en_US'
  end
  local resourceDir =
      hs.application.pathForBundleID("com.kingsoft.wpsoffice.mac")
      .. '/Contents/Resources/office6/mui'
  local locale = getDefaultMatchedLocale(appLocale, resourceDir)
  if type(localeFile) == 'string' then
    localeFile = { localeFile }
  end
  local maps = ensureWpsCache(resourceDir, locale)
  if maps and maps.loc then
    local results = {}
    local seen = {}
    for name, locMap in pairs(maps.loc) do
      local valid = true
      if localeFile then
        valid = any(localeFile, function(p) return name:match('^' .. p .. '$') end)
      end
      if valid then
        local r
        if locMap[str] then
          r = locMap[str]
        elseif str:sub(-3) == '...' and locMap[str:sub(1, -4)] then
          r = locMap[str:sub(1, -4)] .. '...'
        end
        if r and not seen[r] then
          seen[r] = true
          tinsert(results, r)
        end
      end
    end
    if #results == 1 then
      return results[1], locale
    elseif #results > 1 then
      return results, locale
    end
  end
  return nil, locale
end

function localizeZotero(str, appLocale)
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

function localizeChatGPT(str, appLocale)
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

function localizeSteam(str, appLocale, locale)
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

local WeChatLocales = { "en", "zh_CN", "zh_TW" }
function extractWeChatSegments(cacheDir)
  local appid = 'com.tencent.xinWeChat'
  mkdir(cacheDir)
  local executable = hs.application.infoForBundleID(appid).CFBundleExecutable
  executable = hs.application.pathForBundleID(appid)
      .. '/Contents/MacOS/' .. executable
  local file = io.open(executable, "rb")
  if not file then return end
  local data = file:read("*all")
  file:close()
  local pos = 0
  for _=1,#WeChatLocales do
    pos = data:find('Copyright © 2011%-2025 Tencent%. All Rights Reserved%.', pos + 1)
    if pos then
      local s, e
      for i=pos-1,2,-1 do
        if data:sub(i-1,i-1):match('%c') ~= nil and data:sub(i-1,i-1):match('%s') == nil
            and data:sub(i,i):match('%c') ~= nil and data:sub(i,i):match('%s') == nil then
          s = i + 1
          break
        end
      end
      for i=pos+1,data:len()-1 do
        if data:sub(i,i):match('%c') ~= nil and data:sub(i,i):match('%s') == nil
            and data:sub(i+1,i+1):match('%c') ~= nil and data:sub(i+1,i+1):match('%s') == nil then
          e = i - 1
          break
        end
      end
      if s and e then
        local chunk = data:sub(s, e):gsub('%z', '\n')
        local locale
        if chunk:find('騰訊') then locale = 'zh_TW'
        elseif chunk:find('腾讯') then locale = 'zh_CN'
        else locale = 'en' end
        local localeFile = cacheDir .. '/' .. locale .. '.txt'
        local f = io.open(localeFile, "w")
        if f then
          f:write(chunk)
          f:close()
        end
      end
    end
  end
end

-- seems it only works before edition 4.1
function localizeWeChat(str, appLocale)
  local appid = 'com.tencent.xinWeChat'
  local tmpBaseDir = localeTmpDir .. appid
  local locale = matchLocale(appLocale, WeChatLocales)
  if locale == 'en' then return str, locale end
  local localeFile = tmpBaseDir .. '/' .. locale .. '.txt'
  local enLocaleFile = tmpBaseDir .. '/en.txt'
  if not exists(localeFile) or not exists(enLocaleFile) then
    extractWeChatSegments(tmpBaseDir)
  end
  local file = io.open(localeFile, "r")
  if not file then return end
  local data = file:read("*all")
  file:close()
  local strings = strsplit(data, '\n')
  local indices = {}
  for i, s in ipairs(strings) do
    if s:find('%%d') then
      tinsert(indices, i)
    end
  end
  local enFile = io.open(enLocaleFile, "r")
  if not enFile then return end
  local enData = enFile:read("*all")
  enFile:close()
  local enStrings = strsplit(enData, '\n')
  local enIndices = {}
  for i, s in ipairs(enStrings) do
    if s:find('%%d') then
      tinsert(enIndices, i)
    end
  end
  if #indices ~= #enIndices then return end
  local localized = {}
  for i, s in ipairs(enStrings) do
    if s == str then
      local gIndex = #enIndices
      for k, ind in ipairs(enIndices) do
        if ind > i then
          gIndex = k - 1
          break
        end
      end

      local newIndices = {}
      for j=indices[gIndex] or 1,indices[gIndex+1] or #strings do
        if strings[j]:find('%%s') then
          tinsert(newIndices, j)
        end
      end
      local newEnIndices = {}
      for j=enIndices[gIndex] or 1,enIndices[gIndex+1] or #enStrings do
        if enStrings[j]:find('%%s') then
          tinsert(newEnIndices, j)
        end
      end
      if #newIndices ~= #newEnIndices or #newIndices == 0 then
        local start = enIndices[gIndex] or 1
        local end_ = enIndices[gIndex+1] or #enStrings
        if i*2 > start + end_ then
          tinsert(localized, strings[(indices[gIndex+1] or #strings) + i - end_])
        else
          tinsert(localized, strings[(indices[gIndex] or 1) + i - start])
        end
      else
        local newGIndex = #newEnIndices
        for k, ind in ipairs(newEnIndices) do
          if ind > i then
            newGIndex = k - 1
            break
          end
        end

        local start = newEnIndices[newGIndex] or enIndices[gIndex] or 1
        local end_ = newEnIndices[newGIndex+1] or enIndices[gIndex+1] or #enStrings
        if i*2 > start + end_ then
          tinsert(localized,
              strings[(newIndices[newGIndex+1] or indices[gIndex+1] or #strings) + i - end_])
        else
          tinsert(localized,
              strings[(newIndices[newGIndex] or indices[gIndex] or 1) + i - start])
        end
      end
    end
  end
  if #localized <= 1 then
    return localized[1], locale
  else
    return localized, locale
  end
end

local qqLocCache = nil  -- { loc = {zh→en}, deloc = {en→zh} }

local function ensureQQLocCache()
  if qqLocCache ~= nil then return qqLocCache end
  local appid = "com.tencent.qq"
  local cacheDir = localeTmpDir .. appid
  local cacheFile = cacheDir .. '/map.json'
  local appPath = hs.application.pathForBundleID(appid)
  if appPath == nil then return nil end
  local majorNode = appPath .. '/Contents/Resources/app/major.node'
  if not exists(majorNode) then return nil end

  -- rebuild cache if missing or stale
  if not exists(cacheFile) then
    mkdir(cacheDir)
    hs.execute(strfmt(
        "/usr/bin/python3 scripts/qq_node_parse.py '%s' '%s'",
        majorNode, cacheFile))
  end

  local data = hs.json.read(cacheFile)
  if data == nil or data.locale_map == nil then return nil end

  local loc, deloc = {}, {}
  for _, entry in ipairs(data.locale_map) do
    if entry.zh and entry.en then
      loc[entry.en] = entry.zh
      deloc[entry.zh] = entry.en
    end
  end
  qqLocCache = { loc = loc, deloc = deloc }
  return qqLocCache
end

function localizeQQ(str, appLocale)
  local locale = matchLocale(appLocale, { "zh-CN", "zh-TW", "zh-HK", "en-US" })
  if locale == nil then return nil end
  if locale == "en-US" then return str, locale end
  local cache = ensureQQLocCache()
  if cache == nil then return nil, locale end
  return cache.loc[str], locale
end

function delocalizeQt(str, appid, appLocale)
  local appPath = hs.application.pathForBundleID(appid)
  local resourceDir = appPath .. "/../../translations"
  if not exists(resourceDir) then
    resourceDir = appPath .. "/../Qt/translations"
  end
  if not exists(resourceDir) then
    resourceDir = appPath .. "/../../share/qt/translations"
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

function delocalizeWPS(str, appLocale, localeFile)
  if appLocale:sub(1, 2) == 'en' then
    return str, 'en_US'
  end
  local resourceDir =
      hs.application.pathForBundleID("com.kingsoft.wpsoffice.mac")
      .. '/Contents/Resources/office6/mui'
  local locale = getDefaultMatchedLocale(appLocale, resourceDir)
  if locale == nil then return end
  if type(localeFile) == 'string' then
    localeFile = { localeFile }
  end
  local maps = ensureWpsCache(resourceDir, locale)
  if maps and maps.deloc then
    local results = {}
    local seen = {}
    for name, delocMap in pairs(maps.deloc) do
      local valid = true
      if localeFile then
        valid = any(localeFile, function(p) return name:match('^' .. p .. '$') end)
      end
      if valid and delocMap[str] and not seen[delocMap[str]] then
        seen[delocMap[str]] = true
        tinsert(results, delocMap[str])
      end
    end
    if #results == 1 then
      return results[1], locale
    elseif #results > 1 then
      return results, locale
    end
  end
  return nil, locale
end

function delocalizeZotero(str, appLocale)
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

function delocalizeChatGPT(str, appLocale)
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

function delocalizeSteam(str, appLocale, locale)
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

-- seems it only works before edition 4.1
function delocalizeWeChat(str, appLocale)
  local appid = 'com.tencent.xinWeChat'
  local tmpBaseDir = localeTmpDir .. appid
  local locale = matchLocale(appLocale, WeChatLocales)
  if locale == 'en' then return str end
  local localeFile = tmpBaseDir .. '/' .. locale .. '.txt'
  local enLocaleFile = tmpBaseDir .. '/en.txt'
  if not exists(localeFile) or not exists(enLocaleFile) then
    extractWeChatSegments(tmpBaseDir)
  end
  local file = io.open(localeFile, "r")
  if not file then return end
  local data = file:read("*all")
  file:close()
  local strings = strsplit(data, '\n')
  local indices = {}
  for i, s in ipairs(strings) do
    if s:find('%%d') then
      tinsert(indices, i)
    end
  end
  local enFile = io.open(enLocaleFile, "r")
  if not enFile then return end
  local enData = enFile:read("*all")
  enFile:close()
  local enStrings = strsplit(enData, '\n')
  local enIndices = {}
  for i, s in ipairs(enStrings) do
    if s:find('%%d') then
      tinsert(enIndices, i)
    end
  end
  if #indices ~= #enIndices then return end
  local delocalized = {}
  for i, s in ipairs(strings) do
    if s == str then
      local gIndex = #indices
      for k, ind in ipairs(indices) do
        if ind > i then
          gIndex = k - 1
          break
        end
      end

      local newIndices = {}
      for j=indices[gIndex] or 1,indices[gIndex+1] or #strings do
        if strings[j]:find('%%s') then
          tinsert(newIndices, j)
        end
      end
      local newEnIndices = {}
      for j=enIndices[gIndex] or 1,enIndices[gIndex+1] or #enStrings do
        if enStrings[j]:find('%%s') then
          tinsert(newEnIndices, j)
        end
      end
      if #newIndices ~= #newEnIndices or #newIndices == 0 then
        local start = indices[gIndex] or 1
        local end_ = indices[gIndex+1] or #strings
        if i*2 > start + end_ then
          tinsert(delocalized, enStrings[(enIndices[gIndex+1] or #enStrings) + i - end_])
        else
          tinsert(delocalized, enStrings[(enIndices[gIndex] or 1) + i - start])
        end
      else
        local newGIndex = #newIndices
        for k, ind in ipairs(newIndices) do
          if ind > i then
            newGIndex = k - 1
            break
          end
        end

        local start = newIndices[newGIndex] or indices[gIndex] or 1
        local end_ = newIndices[newGIndex+1] or indices[gIndex+1] or #strings
        if i*2 > start + end_ then
          tinsert(delocalized,
              enStrings[(newEnIndices[newGIndex+1] or enIndices[gIndex+1] or #enStrings) + i - end_])
        else
          tinsert(delocalized,
              enStrings[(newEnIndices[newGIndex] or enIndices[gIndex] or 1) + i - start])
        end
      end
    end
  end
  if #delocalized <= 1 then
    return delocalized[1], locale
  else
    return delocalized, locale
  end
end

function delocalizeQQ(str, appLocale)
  local locale = matchLocale(appLocale, { "zh-CN", "zh-TW", "zh-HK", "en-US" })
  if locale == nil then return nil end
  if locale == "en-US" then return str, locale end
  local cache = ensureQQLocCache()
  if cache == nil then return nil, locale end
  return cache.deloc[str], locale
end

function delocalizeMATLABFigureMenu(str, appLocale)
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
    local enValue, ok = hs.execute(strfmt([[
      grep -Eo '%s' '%s' | cut -d ';' -f 2 | cut -d '<' -f 1 | tr -d '\n'
    ]], inverse_pattern, enLocaleFile))
    if ok and enValue ~= "" then return enValue, locale end
  end
  return nil, locale
end
