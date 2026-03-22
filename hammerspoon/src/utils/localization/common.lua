---@diagnostic disable: lowercase-global

function parseStringsFile(file, keepOrder, keepAll)
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

function isBinarayPlist(file)
  local f = io.open(file, "rb")
  if f == nil then return false end
  local firstByte = f:read(1)
  f:close()
  return firstByte == "b"
end

function parseBinaryPlistFile(file, keepOrder, keepAll)
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

function parseNIBArchive(file, keepOrder, keepAll)
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

function parseNIBFile(file, keepOrder, keepAll)
  if isBinarayPlist(file) then
    return parseBinaryPlistFile(file, keepOrder, keepAll)
  else
    return parseNIBArchive(file, keepOrder, keepAll)
  end
end

function localizeByLoctableImpl(str, filePath, locale, localesDict, baseNibFile)
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

function localizeByLoctable(str, resourceDir, localeFile, locale, localesDict)
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
function localizeByStrings(str, localeDir, localeFile, localesDict, localesInvDict)
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

  local maybeStrIsInBaseLocale = false
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
              if invDict and invDict[str] then
                maybeStrIsInBaseLocale = true
                return
              end
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

  if maybeStrIsInBaseLocale then return true end
end

function localizeByNIB(str, localeDir, localeFile, appid)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  local baseLocaleDir = getBaseLocaleDirs(resourceDir)[1]
  local baseLocale = baseLocaleDir:match("^.*/(.*)%.lproj$")
  if locale == baseLocale then return str end
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

function poIdToStr(str)
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

function poStrToId(str)
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

function poCtxtToStr(str)
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

function poStrToCtxt(str)
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

function localizeByQtImpl(str, file)
  str = str:gsub('%(', '\\('):gsub('%)', '\\)')
  if file:sub(-3) == '.qm' then
    local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
    if cmd == nil then return end
    local output, status = hs.execute(strfmt(
      '%s -i "%s" -of po | %s', cmd, file, poIdToStr(str)))
    if status and output ~= "" then return output end
  else
    local output, status = hs.execute(strfmt(
      'cat "%s" | %s', file, poIdToStr(str)))
    if status and output ~= "" then return output end
  end
end

function localizeByQt(str, localeDir)
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

local QM_MAGIC_NUMBER = string.char(
  0x3C, 0xB8, 0x64, 0x18, 0xCA, 0xEF, 0x9C, 0x95,
  0xCD, 0x21, 0x1C, 0xBF, 0x60, 0xA1, 0xBD, 0xDD
)
function extractQMSegments(input_path, cacheDir, cacheFileNames)
  local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
  if cmd == nil then return end

  local file = io.open(input_path, "rb")
  if not file then return end
  local data = file:read("*all")
  file:close()

  local positions = {}
  local start = 1
  while true do
    local found = data:find(QM_MAGIC_NUMBER, start, true)
    if not found then break end
    table.insert(positions, found)
    start = found + #QM_MAGIC_NUMBER
  end
  if #positions < 2 then return end

  local count = 0
  for i = 1, #positions - 1 do
    local startIdx = positions[i]
    local endIdx = positions[i + 1] - 1
    local chunk = data:sub(startIdx, endIdx)

    if #chunk > 0 then
      local qmFile = cacheDir .. '/' .. cacheFileNames[i]
      local f = io.open(qmFile, "wb")
      if f then
        f:write(chunk)
        f:close()
        hs.execute(strfmt(
            '%s -i "%s" -of po -o "%s"', cmd, qmFile, qmFile:sub(1, -4)..'.po'))
        count = count + 1
      end
    end
  end
end

function localizeByQtExecutable(str, appid, appLocale, prefix)
  local executable = hs.application.infoForBundleID(appid).CFBundleExecutable
  executable = hs.application.pathForBundleID(appid)
      .. '/Contents/MacOS/' .. executable
  local localeFiles = getQtExecutableLocales(appid, executable, prefix)
  if localeFiles == nil or #localeFiles == 0 then return end
  local tmpBaseDir = localeTmpDir .. appid
  if not exists(tmpBaseDir .. '/' .. localeFiles[1]:sub(1, -4) .. '.po') then
    extractQMSegments(executable, tmpBaseDir, localeFiles)
  end
  local locale, extra = getQtMatchedLocale(appLocale, tmpBaseDir)
  if locale == nil or locale == 'en' then return str, 'en' end
  if type(extra) == 'string' then
    local file = extra
    local result = localizeByQtImpl(str, file:sub(1, -4) .. '.po')
    if result then return result, locale end
  elseif type(extra) == 'table' then
    for _, file in ipairs(extra) do
      local result = localizeByQtImpl(str, file:sub(1, -4) .. '.po')
      if result then return result, locale end
    end
  end
end

function localizeByFTL(str, localeDir, baseLocale)
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

function localizeByProperties(str, localeDir, baseLocale)
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

function localizeByDTD(str, localeDir, baseLocale)
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

function localizeByMono(str, localeDir)
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

function localizeByChromium(str, localeDir, appid)
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
          if not exists(enTmpdir) then
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
            if not exists(tmpdir) then
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

function localizeByElectron(str, appid, locale, localeFiles, localesPath)
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

function localizeByJava(str, appid, localeFiles, javehome)
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


function delocalizeByLoctableImpl(str, filePath, locale, localesDict, baseNibFile)
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
    if localesDict[en] and localesDict[en][key] then
      return localesDict[en][key]
    end
  end
  return key
end

function delocalizeByLoctable(str, resourceDir, localeFile, locale, localesDict)
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

function delocalizeByStrings(str, localeDir, localeFile, deLocalesInvDict)
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

function delocalizeByNIB(str, localeDir, localeFile, appid)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  local baseLocaleDir = getBaseLocaleDirs(resourceDir)[1]
  local baseLocale = baseLocaleDir:match("^.*/(.*)%.lproj$")
  if locale == baseLocale then return str end
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

function delocalizeByQtImpl(str, file)
  str = str:gsub('%(', '\\('):gsub('%)', '\\)')
  if file:sub(-3) == '.qm' then
    local cmd = hs.execute("which lconvert | tr -d '\\n'", true)
    if cmd == nil then return end
    local output, status = hs.execute(strfmt(
      '%s -i "%s" -of po | %s', cmd, file, poStrToId(str)))
    if status and output ~= "" then return output end
  else
    local output, status = hs.execute(strfmt(
      'cat "%s" | %s', file, poStrToId(str)))
    if status and output ~= "" then return output end
  end
end

function delocalizeByQt(str, localeDir)
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

function delocalizeByQtExecutable(str, appid, appLocale, prefix)
  local executable = hs.application.infoForBundleID(appid).CFBundleExecutable
  executable = hs.application.pathForBundleID(appid)
      .. '/Contents/MacOS/' .. executable
  local localeFiles = getQtExecutableLocales(appid, executable, prefix)
  if localeFiles == nil then return end
  local tmpBaseDir = localeTmpDir .. appid
  if not exists(tmpBaseDir .. '/' .. localeFiles[1]:sub(1, -4) .. '.po') then
    extractQMSegments(executable, tmpBaseDir, localeFiles)
  end
  local locale, extra = getQtMatchedLocale(appLocale, tmpBaseDir)
  if locale == nil then return end
  if locale == 'en' then return str:gsub('[^%s]-&(%a)', '%1'), locale end
  if type(extra) == 'string' then
    local file = extra
    local result = delocalizeByQtImpl(str, file:sub(1, -4) .. '.po')
    if result then return result, locale end
  elseif type(extra) == 'table' then
    for _, file in ipairs(extra) do
      local result = delocalizeByQtImpl(str, file:sub(1, -4) .. '.po')
      if result then return result, locale end
    end
  end
end

function delocalizeByFTL(str, localeDir, baseLocale)
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

function delocalizeByProperties(str, localeDir, baseLocale)
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

function delocalizeByDTD(str, localeDir, baseLocale)
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

function delocalizeByMono(str, localeDir)
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

function delocalizeByChromium(str, localeDir, appid)
  local resourceDir = localeDir .. '/..'
  local locale = localeDir:match("^.*/(.*)%.lproj$")
  for file in hs.fs.dir(localeDir) do
    if file:sub(-4) == ".pak" then
      local fileStem = file:sub(1, -5)
      local baseDir = localeTmpDir .. appid
      mkdir(baseDir)
      local tmpBaseDir = baseDir .. '/' .. locale
      local tmpdir = tmpBaseDir .. '/' .. fileStem
      if not exists(tmpdir) then
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
            if not exists(enTmpdir) then
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

function delocalizeByElectron(str, appid, locale, localeFiles, localesPath)
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

function delocalizeByJava(str, appid, localeFiles, javehome)
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
