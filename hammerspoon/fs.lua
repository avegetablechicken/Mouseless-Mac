local function syncFiles(targetDir, watchedDir, changedPaths, beforeFunc, workFunc, afterFunc)
  local relativePaths = {}
  for i, path in ipairs(changedPaths) do
    relativePaths[i] = string.sub(path, string.len(hs.fs.pathToAbsolute(watchedDir)) + 1)
  end

  for i, path in ipairs(changedPaths) do
    local _, status

    if beforeFunc ~= nil then
      beforeFunc(targetDir, watchedDir, path)
    end
    if workFunc ~= nil then
      _, status = workFunc(targetDir, watchedDir, path)
    else
      -- ignore git repo
      if not string.find(path, "/.git/") then
        _, status = hs.execute(string.format("cp -rp '%s' '%s'", path, targetDir .. "/" .. relativePaths[i]))
      end
    end

    if afterFunc ~= nil and status then
      afterFunc(targetDir, watchedDir, path)
    end

    print("[SYNC] " .. path)
  end
end

local function computePath(variables, path)
  local HOME_DIR = os.getenv("HOME")
  path = string.gsub(path, "%${(.-)}", function(key)
    if variables[key] then
      return variables[key]
    else
      local val = os.getenv(key)
      if val then
        return val
      else
        return key
      end
    end
  end)
  path = string.gsub(path, "%$%((.-)%)", function(key)
    return hs.execute(key, true)
  end)
  if string.sub(path, 1, 2) == "~/" then
    path = HOME_DIR .. string.sub(path, 2)
  end
  return path
end


local function getFileName(path)
  return string.match(path, ".*/([^/]*)")
end

local function postprocessAfterFunc(command, targetDir, watchedDir, path)
  local target = targetDir .. "/" .. getFileName(path)
  hs.execute(string.format([[
mv "%s" "%s";

]] .. command .. [[ "%s" > "%s";

rm "%s"
]],
    target, target .. ".tmp",
    target .. ".tmp", target,
    target .. ".tmp"))
end

local config
if hs.fs.attributes("config/sync.json") ~= nil then
  config = hs.json.read("config/sync.json")
else
  config = { variable = {}, file = {} }
end
for k, v in pairs(config.variable or {}) do
  config.variable[k] = computePath(config.variable, v)
end
local filesToSync = {}
for k, v in pairs(config.file or {}) do
  local spec = {
    computePath(config.variable, k),
    computePath(config.variable, type(v) == "table" and v[1] or v),
    nil, nil, nil
  }
  if type(v) == "table" then
    if v[2].post_process ~= nil then
      spec[5] = hs.fnutils.partial(postprocessAfterFunc, v[2].post_process)
    end
  end
  table.insert(filesToSync, spec)
end

SyncPathWatchers = {}
for _, tuple in ipairs(filesToSync) do
  local beforeFunc
  local workFunc
  local afterFunc
  if #tuple >= 3 then
    beforeFunc = tuple[3]
  end
  if #tuple >= 4 then
    workFunc = tuple[4]
  end
  if #tuple >= 5 then
    afterFunc = tuple[5]
  end

  local watcher = hs.pathwatcher.new(tuple[1], function(paths)
    syncFiles(tuple[2], tuple[1], paths, beforeFunc, workFunc, afterFunc)
  end)
  watcher:start()
  table.insert(SyncPathWatchers, watcher)
end

function File_applicationInstalledCallback(files, flagTables)
  for i=1,#files do
    if string.match(files[i], "Google Docs")
      or string.match(files[i], "Google Sheets")
      or string.match(files[i], "Google Slides") then
      if flagTables[i].itemCreated then
        hs.execute(string.format("rm -rf \"%s\"", files[i]))
      end
    end
  end
end

-- listen to other devices on port 8086 and copy received text/image/file to clipboard
local function handleRequest(method, path, headers, body)
  print("[LOG] Received " .. method .. " request for " .. path)
  print("[LOG] Headers: " .. hs.inspect.inspect(headers))

  if method == "GET" then
    local contentType, contentDisposition, content
    local types = hs.pasteboard.pasteboardTypes()

    if hs.fnutils.contains(types, "public.file-url") then
      contentType = "application/octet-stream"
      local filePath = hs.pasteboard.readURL().filePath
      contentDisposition = "attachment; filename=\"" .. hs.pasteboard.readString() .. "\""
      local file = io.open(filePath, "rb")
      assert(file)
      content = file:read("*all")
      file:close()
    elseif hs.fnutils.contains(types, "public.utf8-plain-text") then
      contentType = "text/plain"
      content = hs.pasteboard.readString()
    elseif hs.fnutils.contains(types, "public.png") then
      contentType = "image/png"
      content = hs.pasteboard.readImage():encodeAsURLString()
    elseif hs.fnutils.contains(types, "public.jpeg") then
      contentType = "image/jpeg"
      content = hs.pasteboard.readImage():encodeAsURLString()
    elseif hs.fnutils.contains(types, "public.tiff") then
      contentType = "image/tiff"
      content = hs.pasteboard.readImage():encodeAsURLString()
    else
      return hs.httpserver.response.new(204)
    end

    local response = {
      status = 200,
      headers = {
          ["Content-Type"] = contentType,
      },
      body = content
    }
    if contentDisposition ~= nil then
      response.headers["Content-Disposition"] = contentDisposition
    end
    return response.body, response.status, response.headers
  end

  if string.find(headers["Content-Type"], "text/") then
    hs.pasteboard.setContents(body)
    print("[LOG] Copied text to clipboard: " .. body)
  elseif string.find(headers["Content-Type"], "image/") then
    local file, tmpname
    while file == nil do
      tmpname = os.tmpname()
      file = io.open(tmpname, "wb")
    end
    file:write(body)
    local image = hs.image.imageFromPath(tmpname)
    os.remove(tmpname)
    hs.pasteboard.writeObjects(image)
    print("[LOG] Copied image to clipboard: " .. path)
  elseif string.find(headers["Content-Type"], "application/") then
    local filename
    if headers["Content-Disposition"] ~= nil then
      local disposition = headers["Content-Disposition"]
      local pattern = "filename=\"(.-)\""
      filename = string.match(disposition, pattern)
      if filename == nil then pattern = "filename=(.-)" end
    end

    local path
    local dir = os.getenv("HOME") .. "/Downloads/"
    if filename ~= nil then
      path = dir .. filename
      -- if file already exists, append a number to the filename
      local i = 1
      while hs.fs.attributes(path) ~= nil do
        path = dir .. filename:gsub("^(.-)(%..-)$", "%1_" .. i .. "%2")
        i = i + 1
      end
    else
      path = os.tmpname():gsub("^/tmp/", dir)
      -- if file already exists, regenerate a new filename
      while hs.fs.attributes(path) ~= nil do
        path = os.tmpname():gsub("^/tmp/", dir)
      end
    end
    local file = io.open(path, "wb")
    assert(file)
    file:write(body)
    file:close()
    hs.pasteboard.writeObjects(path)
    print("[LOG] Copied file to clipboard: " .. path)
  end

  local response = {
    status = 200,
    headers = {
        ["Content-Type"] = "text/plain"
    },
    body = "Received " .. method .. " request for " .. path
  }
  return response.body, response.status, response.headers
end

HTTPServer = hs.httpserver.new():setPort(8086):setCallback(handleRequest):start()
