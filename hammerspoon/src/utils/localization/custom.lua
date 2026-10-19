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

local rustI18nTranslations = {}

local function loadRustI18nTranslations(appid)
  if rustI18nTranslations[appid] ~= nil then return rustI18nTranslations[appid] end
  local appPath = hs.application.pathForBundleID(appid)
  local info = hs.application.infoForBundleID(appid)
  if appPath == nil or info == nil or info.CFBundleExecutable == nil then return end
  local executable = appPath .. "/Contents/MacOS/" .. info.CFBundleExecutable
  local script = hs.configdir .. "/scripts/rust_i18n_macho.py"
  local output, ok = hs.execute(strfmt("/usr/bin/python3 %q %q", script, executable))
  if not ok then return end
  rustI18nTranslations[appid] = hs.json.decode(output)
  return rustI18nTranslations[appid]
end

local function rustI18nLocaleMap(appid, appLocale)
  local translations = loadRustI18nTranslations(appid)
  if translations == nil then return end
  local locales = {}
  for locale in pairs(translations) do tinsert(locales, locale) end
  local locale = matchLocale(appLocale, locales)
  return translations, locale
end

function localizeRustI18n(str, appid, appLocale)
  local translations, locale = rustI18nLocaleMap(appid, appLocale)
  if translations == nil or locale == nil or translations.en == nil then return end
  local key = tindex(translations.en, str)
  return key and translations[locale][key], locale
end

function delocalizeRustI18n(str, appid, appLocale)
  local translations, locale = rustI18nLocaleMap(appid, appLocale)
  if translations == nil or locale == nil or translations.en == nil then return end
  local key = tindex(translations[locale], str)
  return key and translations.en[key], locale
end

function clashVergeAppLocale(appid)
  local file = io.open(os.getenv("HOME") .. "/Library/Application Support/"
      .. appid .. "/verge.yaml", "r")
  if file == nil then return SYSTEM_LOCALE end
  for line in file:lines() do
    local locale = line:match("^language:%s*['\"]?([^'\"%s]+)")
    if locale ~= nil then
      file:close()
      return locale ~= "null" and locale or SYSTEM_LOCALE, true
    end
  end
  file:close()
  return SYSTEM_LOCALE, true
end

local v2rayNTranslationsCache

local function addV2rayNTranslation(map, source, target)
  if map[source] == nil then
    map[source] = target
  elseif map[source] ~= target then
    map[source] = false -- Ambiguous text requires the resource key for localization.
  end
end

local function v2rayNTranslations()
  local appid = "2dust.v2rayN"
  local appPath = hs.application.pathForBundleID(appid)
  local info = hs.application.infoForBundleID(appid)
  if appPath == nil or info == nil or info.CFBundleExecutable == nil then return end
  local binary = appPath .. "/Contents/MacOS/" .. info.CFBundleExecutable
  local attributes = hs.fs.attributes(binary)
  if attributes == nil then return end
  local identity = table.concat({binary, tostring(attributes.modification),
      tostring(attributes.change), tostring(attributes.size), tostring(attributes.ino)}, "|")
  if v2rayNTranslationsCache and v2rayNTranslationsCache.identity == identity then
    return v2rayNTranslationsCache
  end

  local script = hs.configdir .. "/scripts/dotnet_resources.py"
  local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
  local output, ok = hs.execute("/usr/bin/python3 " .. quote(script) .. " " .. quote(binary))
  if not ok then return end
  local decoded, translations = pcall(hs.json.decode, output)
  if not decoded or type(translations) ~= "table" or type(translations.en) ~= "table" then
    return
  end
  local cache = {identity = identity, translations = translations, locales = {}, maps = {}}
  for locale, dictionary in pairs(translations) do
    local forward, reverse = {}, {}
    for key, english in pairs(translations.en) do
      local translated = dictionary[key] or english
      addV2rayNTranslation(forward, english, translated)
      addV2rayNTranslation(reverse, translated, english)
    end
    tinsert(cache.locales, locale)
    cache.maps[locale] = {forward = forward, reverse = reverse}
  end
  table.sort(cache.locales)
  v2rayNTranslationsCache = cache
  return cache
end

function localizeV2rayN(str, appLocale)
  local cache = v2rayNTranslations()
  if cache == nil then return end
  local locale = matchLocale(appLocale, cache.locales) or "en"
  local result
  if cache.translations.en[str] ~= nil then
    result = cache.translations[locale][str] or cache.translations.en[str]
  else
    result = cache.maps[locale].forward[str]
  end
  return result or nil, locale
end

function delocalizeV2rayN(str, appLocale)
  local cache = v2rayNTranslations()
  if cache == nil then return end
  local locale = matchLocale(appLocale, cache.locales) or "en"
  return cache.maps[locale].reverse[str] or nil, locale
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

local function zoteroLocaleDirectory(appLocale)
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
  return localeDir, locale, baseLocale
end

function localizeZotero(str, appLocale)
  local localeDir, locale, baseLocale = zoteroLocaleDirectory(appLocale)
  if localeDir == nil then return end
  local result = localizeByDTD(str, localeDir, baseLocale)
  if result then return result, locale end
  result = localizeByFTL(str, localeDir, baseLocale)
  if result then return result, locale end
  result = localizeByProperties(str, localeDir, baseLocale)
  return result, locale
end

local function chatGPTCompressedStringsDir()
  local appPath = hs.application.pathForBundleID("com.openai.chat")
  if appPath == nil or appPath == "" then return end
  local assetBundle = appPath .. "/Contents/Frameworks/Assets.framework/Resources"
      .. "/Assets_Assets.bundle"
  for _, suffix in ipairs {
    "/CompressedStrings",
    "/Contents/Resources/CompressedStrings",
  } do
    local resourceDir = assetBundle .. suffix
    if exists(resourceDir) then return resourceDir end
  end
end

local function chatGPTTranslations(appLocale)
  local resourceDir = chatGPTCompressedStringsDir()
  if resourceDir == nil then return nil end
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
  return jsonDict, locale
end

function localizeChatGPT(str, appLocale)
  local jsonDict, locale = chatGPTTranslations(appLocale)
  if jsonDict == nil then return nil, locale end
  return jsonDict[str], locale
end

local function normalizeCodexLocale(locale)
  if type(locale) ~= "string" then return end
  locale = locale:match("^%s*(.-)%s*$")
  if locale == "" then return end

  local normalized = locale:lower()
  if normalized == "auto" or normalized == "null" then return end
  return locale
end

local function codexLocaleOverride(configPath)
  local file = io.open(configPath, "r")
  if file == nil then return end

  local content = file:read("*a")
  file:close()
  if content == nil then return end

  local section = ""
  local fallback
  for line in content:gmatch("[^\r\n]+") do
    local sectionName = line:match("^%s*%[([^%[%]]+)%]%s*$")
    if sectionName ~= nil then section = sectionName end

    local value = line:match('^%s*localeOverride%s*=%s*"([^"]*)"')
        or line:match("^%s*localeOverride%s*=%s*'([^']*)'")
        or line:match("^%s*localeOverride%s*=%s*([^%s#]+)")
    value = normalizeCodexLocale(value)
    if value ~= nil then
      if section == "desktop" then return value end
      if section == "" and fallback == nil then fallback = value end
    end
  end
  return fallback
end

local function codexProfileLocale(preferencesPath)
  if not exists(preferencesPath) then return end

  local preferences = hs.json.read(preferencesPath)
  local selectedLanguages = get(preferences, "intl", "selected_languages")
  if type(selectedLanguages) ~= "string" then return end

  return normalizeCodexLocale(strsplit(selectedLanguages, ",")[1])
end

function codexAppLocale()
  local homeDir = os.getenv("HOME")
  if homeDir == nil then return end

  local configPath = homeDir .. "/.codex/config.toml"
  local preferencesPath = homeDir ..
      "/Library/Application Support/Codex/Default/Preferences"

  local locale = codexLocaleOverride(configPath)
  if locale == nil then
    locale = codexProfileLocale(preferencesPath)
  end
  return locale
end

local codexElectronKeysCache
function codexElectronKeys()
  if codexElectronKeysCache == nil then
    local appPath = hs.application.pathForBundleID("com.openai.codex")
    if appPath == nil then return {} end
    local archive = appPath .. "/Contents/Resources/app.asar"
    local files, ok = hs.execute(strfmt([[
      npx --prefer-offline @electron/asar list "%s" | grep '^/\.vite/build/src-.*\.js$'
    ]], archive), true)
    if not ok then return {} end
    codexElectronKeysCache = {}

    local tmpdir = localeTmpDir .. "com.openai.codex/electron-keys"
    mkdir(tmpdir)
    for archivePath in files:gmatch("[^\r\n]+") do
      local file = archivePath:gsub("^/", "")
      local fileName = file:match("[^/]+$")
      local tmpfile = tmpdir .. "/" .. fileName
      if not exists(tmpfile) then
        hs.execute(strfmt([[
          cd "%s" && npx --prefer-offline @electron/asar extract-file "%s" "%s"
        ]], tmpdir, archive, file), true)
      end
      local handle = io.open(tmpfile, "r")
      local content = handle and handle:read("*a")
      if handle then handle:close() end
      for title, id in (content or ""):gmatch(
          'menuTitle:`([^`]*)`,menuTitleIntlId:`([^`]*)`') do
        codexElectronKeysCache[title] = id
      end
    end
  end
  return codexElectronKeysCache
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
local function weChatICULocale(samples)
  local script = [[
ObjC.import("Foundation");
const samples = ]] .. hs.json.encode(samples) .. [[;
(function() {
  for (const value of samples) {
    const s = $(value);
    const hans = ObjC.unwrap(s.stringByApplyingTransformReverse(
        $("Traditional-Simplified"), false));
    const hant = ObjC.unwrap(s.stringByApplyingTransformReverse(
        $("Simplified-Traditional"), false));
    if (hans === value && hant !== value) return "zh_CN";
    if (hant === value && hans !== value) return "zh_TW";
  }
  return "";
})();
]]
  local ok, result = hs.osascript.javascript(script)
  if ok and type(result) == 'string' and result ~= "" then
    return result
  end
end

local nonASCIIPattern = "[" .. string.char(128) .. "-" .. string.char(255) .. "]"

-- WeChat 4 stores each locale as an offset table with a header
-- { count, 0, offsets pointer, strings pointer } in __DATA,__data of the
-- main executable (checked since v4.0.3), of Frameworks/wechat.dylib since
-- v4.1.8, and of Resources/wechat.dylib since v4.1.9. Entries share indices
-- across locales; each entry holds two offsets for the Weixin and WeChat
-- brandings.
local function weChatStringTables()
  local appid = 'com.tencent.xinWeChat'
  local appPath = hs.application.pathForBundleID(appid)
  if appPath == nil or appPath == "" then return end
  local version, path = applicationVersion(appid)
  if version >= "4.1.9" then
    path = appPath .. '/Contents/Resources/wechat.dylib'
  elseif version >= "4.1.8" then
    path = appPath .. '/Contents/Frameworks/wechat.dylib'
  else
    local info = hs.application.infoForBundleID(appid)
    path = appPath .. '/Contents/MacOS/' .. get(info, 'CFBundleExecutable')
  end
  local file = io.open(path, "rb")
  if file == nil then return end

  local base = 0
  if string.unpack('>I4', file:read(4)) == 0xcafebabe then
    local nArch = string.unpack('>I4', file:read(4))
    for i = 1, nArch do
      local cpuType, _, offset = string.unpack('>I4I4I4', file:read(20))
      if i == 1 or cpuType == 0x0100000C then base = offset end
    end
  end
  file:seek("set", base)
  local header = file:read(32)
  local magic, _, _, _, _, sizeOfCmds = string.unpack('<I4I4I4I4I4I4', header)
  if magic ~= 0xfeedfacf then file:close() return end
  local cmds = file:read(sizeOfCmds)
  local addr, size, offset
  local pos = 1
  while pos < #cmds and addr == nil do
    local cmd, cmdSize = string.unpack('<I4I4', cmds, pos)
    if cmd == 0x19 then  -- LC_SEGMENT_64
      local nSects = string.unpack('<I4', cmds, pos + 64)
      for i = 0, nSects - 1 do
        local s = pos + 72 + i * 80
        local sectName = cmds:sub(s, s + 15):match('^[^%z]*')
        local segName = cmds:sub(s + 16, s + 31):match('^[^%z]*')
        if segName == '__DATA' and sectName == '__data' then
          addr, size, offset = string.unpack('<I8I8I4', cmds, s + 32)
          break
        end
      end
    end
    pos = pos + cmdSize
  end
  if addr == nil then file:close() return end
  file:seek("set", base + offset)
  local data = file:read(size)
  file:close()

  local mask = 0xfffffffff  -- strip chained fixup bits from pointers
  local headers = {}
  for p = 1 + (8 - addr % 8) % 8, #data - 23, 8 do
    local count, zero, tp, sp = string.unpack('<I4I4I8I8', data, p)
    if count > 0 and zero == 0 then
      tp, sp = tp & mask, sp & mask
      -- strings follow the offsets, padded to at most 16-byte alignment
      if sp - tp >= 8 * count and sp - tp < 8 * count + 16
          and tp >= addr and sp < addr + size then
        headers[count] = headers[count] or {}
        tinsert(headers[count], { tp - addr + 1, sp - addr + 1 })
      end
    end
  end
  local count, group = 0
  for c, candidates in pairs(headers) do
    if #candidates > 1 and c > count then count, group = c, candidates end
  end
  if group == nil then return end

  local tables = {}
  for _, h in ipairs(group) do
    local variants, nonASCII, samples = { {}, {} }, 0, {}
    for i = 0, count - 1 do
      local a, b = string.unpack('<I4I4', data, h[1] + 8 * i)
      for k, o in ipairs{ a, b } do
        variants[k][i + 1] = o ~= 0xffffffff
            and string.unpack('z', data, h[2] + o) or false
      end
      local s = variants[1][i + 1]
      if s and s:find(nonASCIIPattern) then
        nonASCII = nonASCII + 1
        if #samples < 80 then tinsert(samples, s) end
      end
    end
    local locale = nonASCII * 2 < count and 'en' or weChatICULocale(samples)
    if locale then tables[locale] = variants end
  end
  return tables
end

local weChatTables

-- Pair strings by their shared table index instead of known translations.
local function weChatTableLookup(str, from, to)
  if weChatTables == nil then
    local ok, tables = pcall(weChatStringTables)
    weChatTables = ok and tables or false
  end
  if not weChatTables or weChatTables[from] == nil
      or weChatTables[to] == nil then
    return
  end
  local results = {}
  for i = 1, #weChatTables[from][1] do
    for k = 1, 2 do
      local result = weChatTables[to][k][i]
      if weChatTables[from][k][i] == str and result
          and not tcontain(results, result) then
        tinsert(results, result)
      end
    end
  end
  if #results <= 1 then return results[1] end
  return results
end

function localizeWeChat(str, appLocale)
  local locale = matchLocale(appLocale, WeChatLocales)
  if locale == 'en' then return str, locale end
  return weChatTableLookup(str, 'en', locale), locale
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

-- ── Yuanbao (com.tencent.yuanbao) ───────────────────────────────────────
-- Base locale is zh-CN: Next.js chunks ship Chinese source strings as
-- \u-escaped JS keys, with parallel value tables for English (en) and
-- Traditional Chinese (zh-HK).  scripts/yuanbao_pkg_parse.py extracts
-- those plus the .ftl menu strings and InfoPlist.strings into one map.

local yuanbaoLocCache = nil

local function ensureYuanbaoLocCache()
  if yuanbaoLocCache ~= nil then return yuanbaoLocCache end
  local appid = "com.tencent.yuanbao"
  local appPath = hs.application.pathForBundleID(appid)
  if appPath == nil then return nil end
  if not exists(appPath .. '/Contents/Resources/content.pkg')
      and not exists(appPath .. '/Contents/Resources/locales') then
    return nil
  end

  local cacheDir = localeTmpDir .. appid
  local cacheFile = cacheDir .. '/map.json'
  local pkgPath = appPath .. '/Contents/Resources/content.pkg'
  local stale = false
  if exists(cacheFile) and exists(pkgPath) then
    local pkgM = hs.fs.attributes(pkgPath, 'modification')
    local cacheM = hs.fs.attributes(cacheFile, 'modification')
    if pkgM and cacheM and pkgM > cacheM then stale = true end
  end

  if not exists(cacheFile) or stale then
    mkdir(cacheDir)
    hs.execute(strfmt(
        "/usr/bin/python3 scripts/yuanbao_pkg_parse.py '%s' '%s'",
        appPath, cacheFile))
  end

  local data = hs.json.read(cacheFile)
  if data == nil or data.by_locale == nil then return nil end

  -- loc[locale][zhCN]  = localized      (forward, used by localizeYuanbao)
  -- deloc[locale][loc] = zhCN           (reverse, used by delocalizeYuanbao)
  local loc = data.by_locale
  local deloc = data.by_locale_reverse
  if deloc == nil then
    -- Older cache lacking reverse map: build it now (priority undefined
    -- on collision; rebuild the cache file to refresh).
    deloc = {}
    for locale, table_ in pairs(loc) do
      local inv = {}
      for zh, v in pairs(table_) do
        if inv[v] == nil then inv[v] = zh end
      end
      deloc[locale] = inv
    end
  end
  yuanbaoLocCache = { loc = loc, deloc = deloc }
  return yuanbaoLocCache
end

-- map an arbitrary appLocale ("zh-Hans-CN", "en-US", "zh-TW", ...) to one
-- of the three buckets the parser produces: 'en', 'zh-cn', 'zh-hk'.
local function yuanbaoLocaleBucket(appLocale)
  local matched = matchLocale(appLocale, { "zh-CN", "zh-HK", "zh-TW", "en-US" })
  if matched == nil then return nil, nil end
  if matched:sub(1, 2) == 'en' then return 'en', matched end
  if matched == 'zh-CN' then return 'zh-cn', matched end
  return 'zh-hk', matched
end

-- Resolve an input string (in any of the three locales) to its zh-CN
-- canonical form.  Returns nil when the string isn't found in any map.
local function yuanbaoToBaseZH(cache, str)
  if cache.loc['zh-cn'] and cache.loc['zh-cn'][str] ~= nil then
    return str
  end
  for _, fromBucket in ipairs{ 'en', 'zh-hk' } do
    local rev = cache.deloc[fromBucket]
    if rev and rev[str] ~= nil then return rev[str] end
  end
  return nil
end

function localizeYuanbao(str, appLocale)
  local bucket, locale = yuanbaoLocaleBucket(appLocale)
  if bucket == nil then return nil end
  local cache = ensureYuanbaoLocCache()
  if cache == nil then
    -- Without a cache we can only honor the identity case.
    if bucket == 'zh-cn' then return str, locale end
    return nil, locale
  end
  local zhCN = yuanbaoToBaseZH(cache, str)
  if zhCN == nil then return nil, locale end
  if bucket == 'zh-cn' then return zhCN, locale end
  local table_ = cache.loc[bucket]
  if table_ == nil then return nil, locale end
  return table_[zhCN], locale
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
  local localeDir, locale, baseLocale = zoteroLocaleDirectory(appLocale)
  if localeDir == nil then return end
  local result = delocalizeByDTD(str, localeDir, baseLocale)
  if result then return result, locale end
  result = delocalizeByFTL(str, localeDir, baseLocale)
  if result then return result, locale end
  result = delocalizeByProperties(str, localeDir, baseLocale)
  return result, locale
end

function delocalizeChatGPT(str, appLocale)
  local jsonDict, locale = chatGPTTranslations(appLocale)
  if jsonDict == nil then return nil, locale end
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

function delocalizeWeChat(str, appLocale)
  local locale = matchLocale(appLocale, WeChatLocales)
  if locale == 'en' then return str end
  return weChatTableLookup(str, locale, 'en'), locale
end

function delocalizeQQ(str, appLocale)
  local locale = matchLocale(appLocale, { "zh-CN", "zh-TW", "zh-HK", "en-US" })
  if locale == nil then return nil end
  if locale == "en-US" then return str, locale end
  local cache = ensureQQLocCache()
  if cache == nil then return nil, locale end
  return cache.deloc[str], locale
end

function delocalizeYuanbao(str, appLocale)
  local bucket, locale = yuanbaoLocaleBucket(appLocale)
  if bucket == nil then return nil end
  -- The framework's canonical is English: delocalize returns the en form
  -- of the displayed string.  When the app is already shown in English,
  -- the input itself is canonical.
  if bucket == 'en' then return str, locale end
  local cache = ensureYuanbaoLocCache()
  if cache == nil then return nil, locale end
  local zhCN = yuanbaoToBaseZH(cache, str)
  if zhCN == nil then return nil, locale end
  if cache.loc['en'] == nil then return nil, locale end
  return cache.loc['en'][zhCN], locale
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
