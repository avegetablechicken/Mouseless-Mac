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

function localizeChatGPT(str, appLocale)
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
local weChatDictCache = {}
local weChatReverseDictCache = {}

-- Manual overrides for zh_CN (CN block ordering differs from EN/TW)
-- These cover critical menu/UI strings used in Hammerspoon automation
local weChatCNOverrides = {
  ["Chats"] = "聊天",
  ["File"] = "文件",
  ["Edit"] = "编辑",
  ["View"] = "视图",
  ["Window"] = "窗口",
  ["Help"] = "帮助",
  ["Contacts"] = "通讯录",
  ["Discover"] = "发现",
  ["Moments"] = "朋友圈",
  ["Settings"] = "设置",
  ["Send"] = "发送",
  ["Cancel"] = "取消",
  ["Save"] = "保存",
  ["Copy"] = "复制",
  ["Paste"] = "粘贴",
  ["Delete"] = "删除",
  ["Close"] = "关闭",
  ["Add"] = "添加",
  ["Remove"] = "移除",
  ["Login"] = "登录",
  ["Scan"] = "扫一扫",
  ["Search"] = "搜索",
  ["Select All"] = "全选",
  ["Quit"] = "退出",
  ["Minimize"] = "最小化",
  ["Zoom"] = "缩放",
  ["Show All"] = "显示全部",
  ["Hide"] = "隐藏",
  ["New"] = "新建",
  ["Open"] = "打开",
  ["Print"] = "打印",
  ["Undo"] = "撤销",
  ["Redo"] = "重做",
  ["Cut"] = "剪切",
  ["Select"] = "选择",
  ["Back"] = "返回",
  ["Next"] = "下一步",
  ["Done"] = "完成",
  ["OK"] = "确定",
  ["Yes"] = "是",
  ["No"] = "否",
  ["Stop"] = "停止",
  ["Start"] = "开始",
  ["Pause"] = "暂停",
  ["Resume"] = "继续",
  ["Export"] = "导出",
  ["Import"] = "导入",
  ["Refresh"] = "刷新",
  ["Reload"] = "重新加载",
  ["Reset"] = "重置",
  ["Clear"] = "清除",
  ["Clear All"] = "全部清除",
  ["More"] = "更多",
  ["Share"] = "分享",
  ["Forward"] = "转发",
  ["Reply"] = "回复",
  ["Mute"] = "静音",
  ["Unmute"] = "取消静音",
  ["Pin"] = "置顶",
  ["Unpin"] = "取消置顶",
  ["Block"] = "拉黑",
  ["Report"] = "举报",
  ["Preview"] = "预览",
  ["Edit Profile"] = "编辑资料",
  ["Sign Out"] = "退出登录",
  ["About"] = "关于",
  ["Check for Updates"] = "检查更新",
  ["Preferences"] = "偏好设置",
  ["Services"] = "服务",
  ["Hide Others"] = "隐藏其他",
  ["Bring All to Front"] = "全部前置",
  ["Enter Full Screen"] = "进入全屏",
  ["Exit Full Screen"] = "退出全屏",
  ["Minimize All"] = "全部最小化",
  ["Arrange"] = "排列",
  ["Sort"] = "排序",
  ["Filter"] = "筛选",
  ["Download"] = "下载",
  ["Upload"] = "上传",
  ["Install"] = "安装",
  ["Uninstall"] = "卸载",
  ["Restart"] = "重启",
  ["Shutdown"] = "关机",
  ["Lock"] = "锁定",
  ["Unlock"] = "解锁",
  ["Verify"] = "验证",
  ["Authorize"] = "授权",
  ["Reject"] = "拒绝",
  ["Accept"] = "接受",
  ["Ignore"] = "忽略",
  ["Retry"] = "重试",
  ["Skip"] = "跳过",
  ["Dismiss"] = "忽略",
  ["Subscribe"] = "订阅",
  ["Unsubscribe"] = "取消订阅",
  ["Activate"] = "激活",
  ["Deactivate"] = "停用",
  ["Enable"] = "启用",
  ["Disable"] = "禁用",
  ["Show"] = "显示",
  ["Hide Sidebar"] = "隐藏侧边栏",
  ["Show Sidebar"] = "显示侧边栏",
  ["Show Toolbar"] = "显示工具栏",
  ["Hide Toolbar"] = "隐藏工具栏",
  ["Show Tab Bar"] = "显示标签栏",
  ["Hide Tab Bar"] = "隐藏标签栏",
  ["Show Status Bar"] = "显示状态栏",
  ["Hide Status Bar"] = "隐藏状态栏",
  ["Enter"] = "进入",
  ["Exit"] = "退出",
  ["Open Recent"] = "打开最近",
  ["Clear Menu"] = "清除菜单",
  ["Today"] = "今天",
  ["Yesterday"] = "昨天",
  ["Tomorrow"] = "明天",
  ["Later"] = "稍后",
  ["Always"] = "总是",
  ["Never"] = "从不",
  ["Daily"] = "每天",
  ["Weekly"] = "每周",
  ["Monthly"] = "每月",
  ["Yearly"] = "每年",
}

-- Build reverse CN overrides
local weChatCNReverseOverrides = {}
for en, cn in pairs(weChatCNOverrides) do
  weChatCNReverseOverrides[cn] = en
end

local function loadWeChatDict(locale)
  if weChatDictCache[locale] ~= nil then
    if weChatDictCache[locale] == false then return nil end
    return weChatDictCache[locale]
  end
  local appid = 'com.tencent.xinWeChat'
  local dictFile = localeTmpDir .. appid .. '/en_' .. locale .. '.json'
  if exists(dictFile) then
    local ok, dict = pcall(hs.json.read, dictFile)
    if ok and type(dict) == 'table' then
      weChatDictCache[locale] = dict
      return dict
    end
  end
  weChatDictCache[locale] = false
  return nil
end

local function loadWeChatReverseDict(locale)
  if weChatReverseDictCache[locale] ~= nil then
    if weChatReverseDictCache[locale] == false then return nil end
    return weChatReverseDictCache[locale]
  end
  local appid = 'com.tencent.xinWeChat'
  local dictFile = localeTmpDir .. appid .. '/' .. locale .. '_en.json'
  if exists(dictFile) then
    local ok, dict = pcall(hs.json.read, dictFile)
    if ok and type(dict) == 'table' then
      weChatReverseDictCache[locale] = dict
      return dict
    end
  end
  weChatReverseDictCache[locale] = false
  return nil
end

local function weChatExecutablePath()
  -- WeChat v4.x stores localization strings in wechat.dylib, not the main executable
  local appid = 'com.tencent.xinWeChat'
  local appPath = hs.application.pathForBundleID(appid)
  if appPath == nil or appPath == "" then return end
  local dylibPath = appPath .. '/Contents/Resources/wechat.dylib'
  if exists(dylibPath) then return dylibPath end
  -- Fallback for older versions: use the main executable
  local info = hs.application.infoForBundleID(appid)
  local executable = get(info, 'CFBundleExecutable') or 'WeChat'
  return appPath .. '/Contents/MacOS/' .. executable
end

local function weChatJSON(value)
  if hs.json.encode then return hs.json.encode(value) end
  if type(value) == 'table' then
    local items = {}
    for _, v in ipairs(value) do
      tinsert(items, weChatJSON(v))
    end
    return '[' .. table.concat(items, ',') .. ']'
  end
  return '"' .. value:gsub("\\", "\\\\")
      :gsub('"', '\\"')
      :gsub("\n", "\\n")
      :gsub("\r", "\\r")
      :gsub("\t", "\\t") .. '"'
end

local function weChatICULocale(samples)
  local script = [[
ObjC.import("Foundation");
const samples = ]] .. weChatJSON(samples) .. [[;
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

local badControlPattern = "[" .. string.char(1) .. "-" .. string.char(8)
    .. string.char(11) .. string.char(12)
    .. string.char(14) .. "-" .. string.char(31)
    .. string.char(127) .. "]"
local nonASCIIPattern = "[" .. string.char(128) .. "-" .. string.char(255) .. "]"

-- Classify Chinese script via ICU transforms instead of anchoring on words.
local function weChatSegmentLocale(chunk, firstString)
  if firstString == nil then return end
  if not firstString:find(nonASCIIPattern) then return 'en' end

  local samples = {}
  for part in chunk:gmatch("[^%z]+") do
    if part:find(nonASCIIPattern) then
      tinsert(samples, part)
      if #samples >= 80 then break end
    end
  end
  return weChatICULocale(samples)
end

local function weChatSegmentStats(chunk)
  local parts, bad, long, formatCount = 0, 0, 0, 0
  local totalBytes = 0
  local firstString
  for part in chunk:gmatch("[^%z]+") do
    firstString = firstString or part
    parts = parts + 1
    totalBytes = totalBytes + #part
    if part:find(badControlPattern) then bad = bad + 1 end
    if #part > 600 then long = long + 1 end
    if part:find("%", 1, true) then formatCount = formatCount + 1 end
  end
  if parts < 1500 or bad > 3 or long > 20 or formatCount < 80 then return end

  local avgBytes = totalBytes / parts
  if avgBytes < 3 or avgBytes > 45 then return end

  local locale = weChatSegmentLocale(chunk, firstString)
  if locale == nil then return end

  local targetAvg = locale == 'en' and 24 or 26
  local score = parts + formatCount * 2
      - long * 100 - math.abs(avgBytes - targetAvg) * 10
  return {
    locale = locale,
    parts = parts,
    score = score,
  }
end

local function writeWeChatSegment(cacheDir, locale, chunk)
  local localeFile = cacheDir .. '/' .. locale .. '.txt'
  local f = io.open(localeFile, "w")
  if f then
    f:write(chunk:gsub('%z', '\n'))
    f:close()
    return true
  end
end

function extractWeChatSegments(cacheDir)
  mkdir(cacheDir)
  local executable = weChatExecutablePath()
  if executable == nil then return false end
  local file = io.open(executable, "rb")
  if not file then return false end
  local data = file:read("*all")
  file:close()

  local candidates = {}
  local pos = 1
  while true do
    local s = data:find("\0\0", pos, true)
    if s == nil then break end
    local e = data:find("\0\0", s + 2, true)
    if e == nil then break end
    local len = e - s - 2
    if len >= 20000 and len <= 200000 then
      local chunk = data:sub(s + 2, e - 1)
      local stats = weChatSegmentStats(chunk)
      if stats then
        local prev = candidates[stats.locale]
        if prev == nil or stats.score > prev.score then
          candidates[stats.locale] = {
            chunk = chunk,
            score = stats.score,
            parts = stats.parts,
          }
        end
      end
    end
    pos = s + 2  -- advance by 2 to handle overlapping \0\0 patterns
  end

  local count = 0
  for locale, candidate in pairs(candidates) do
    if writeWeChatSegment(cacheDir, locale, candidate.chunk) then
      count = count + 1
    end
  end
  return count == #WeChatLocales
end

local function ensureWeChatSegments(cacheDir)
  -- Check if JSON dicts exist (new format, more reliable)
  local hasDicts = exists(cacheDir .. '/en_zh_TW.json')
  local hasTxt = true
  for _, locale in ipairs(WeChatLocales) do
    hasTxt = hasTxt and exists(cacheDir .. '/' .. locale .. '.txt')
  end
  if hasDicts and hasTxt then return true end

  -- Try Python script first (handles both .txt and .json generation)
  local dylibPath = weChatExecutablePath()
  if dylibPath and exists(dylibPath) then
    local scriptPath = hs.configdir .. '/scripts/wechat_extract.py'
    if exists(scriptPath) then
      local result, ok = hs.execute(strfmt(
        "/usr/bin/python3 '%s' '%s' '%s' 2>&1",
        scriptPath, dylibPath, cacheDir), true)
      -- Re-check after script
      hasDicts = exists(cacheDir .. '/en_zh_TW.json')
      for _, locale in ipairs(WeChatLocales) do
        hasTxt = hasTxt and exists(cacheDir .. '/' .. locale .. '.txt')
      end
      if hasDicts and hasTxt then return true end
    end
  end

  -- Fall back to old extraction method
  return extractWeChatSegments(cacheDir)
end

function localizeWeChat(str, appLocale)
  local appid = 'com.tencent.xinWeChat'
  local locale = matchLocale(appLocale, WeChatLocales)
  if locale == 'en' then return str, locale end

  -- Check manual CN overrides (most reliable for Simplified Chinese)
  if locale == 'zh_CN' and weChatCNOverrides[str] then
    return weChatCNOverrides[str], locale
  end

  -- Try JSON dict first (works well for TW)
  local dict = loadWeChatDict(locale)
  if dict and dict[str] then
    return dict[str], locale
  end

  -- Fall back to simple position-based lookup
  local tmpBaseDir = localeTmpDir .. appid
  local localeFile = tmpBaseDir .. '/' .. locale .. '.txt'
  local enLocaleFile = tmpBaseDir .. '/en.txt'
  if not ensureWeChatSegments(tmpBaseDir)
      and (not exists(localeFile) or not exists(enLocaleFile)) then
    return nil, locale
  end
  local file = io.open(localeFile, "r")
  if not file then return nil, locale end
  local data = file:read("*all")
  file:close()
  local strings = strsplit(data, '\n')
  local enFile = io.open(enLocaleFile, "r")
  if not enFile then return nil, locale end
  local enData = enFile:read("*all")
  enFile:close()
  local enStrings = strsplit(enData, '\n')
  -- Simple position-based lookup
  for i, s in ipairs(enStrings) do
    if s == str then
      if i <= #strings then
        return strings[i], locale
      end
      break
    end
  end
  return nil, locale
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
  local appid = 'com.tencent.xinWeChat'
  local locale = matchLocale(appLocale, WeChatLocales)
  if locale == 'en' then return str, locale end

  -- Check manual CN reverse overrides
  if locale == 'zh_CN' and weChatCNReverseOverrides[str] then
    return weChatCNReverseOverrides[str], locale
  end

  -- Try JSON reverse dict first (works well for TW)
  local dict = loadWeChatReverseDict(locale)
  if dict and dict[str] then
    return dict[str], locale
  end

  -- Fall back to simple position-based reverse lookup
  local tmpBaseDir = localeTmpDir .. appid
  local localeFile = tmpBaseDir .. '/' .. locale .. '.txt'
  local enLocaleFile = tmpBaseDir .. '/en.txt'
  if not ensureWeChatSegments(tmpBaseDir)
      and (not exists(localeFile) or not exists(enLocaleFile)) then
    return nil, locale
  end
  local file = io.open(localeFile, "r")
  if not file then return nil, locale end
  local data = file:read("*all")
  file:close()
  local strings = strsplit(data, '\n')
  local enFile = io.open(enLocaleFile, "r")
  if not enFile then return nil, locale end
  local enData = enFile:read("*all")
  enFile:close()
  local enStrings = strsplit(enData, '\n')
  -- Simple position-based reverse lookup
  for i, s in ipairs(strings) do
    if s == str then
      if i <= #enStrings then
        return enStrings[i], locale
      end
      break
    end
  end
  return nil, locale
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
