-- File synchronization utilities.
--
-- This section implements a lightweight file sync mechanism based on
-- filesystem watchers. It is primarily used to mirror selected files
-- or directories to target locations, with optional pre/post processing.
--
-- Design notes:
-- - Synchronization is event-driven via hs.pathwatcher
-- - Per-file hooks allow custom behavior without hardcoding logic
-- - Git repositories are intentionally ignored by default

-- Synchronize changed files from a watched directory to a target directory.
local function syncFiles(targetDir, watchedDir, changedPaths, beforeFunc, workFunc, afterFunc)
  local relativePaths = {}
  for i, path in ipairs(changedPaths) do
    relativePaths[i] = path:sub(hs.fs.pathToAbsolute(watchedDir):len() + 1)
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
      if not path:find("/.git/") then
        _, status = hs.execute(strfmt("cp -rp '%s' '%s'", path, targetDir .. "/" .. relativePaths[i]))
      end
    end

    if afterFunc ~= nil and status then
      afterFunc(targetDir, watchedDir, path)
    end

    print("[SYNC] " .. path)
  end
end

-- Compute a filesystem path with variable expansion.
--
-- Supports:
-- - ${VAR} and environment variables
-- - $(command) shell substitution
-- - ~/ home directory expansion
local function computePath(variables, path)
  local HOME_DIR = os.getenv("HOME")
  path = path:gsub("%${(.-)}", function(key)
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
  path = path:gsub("%$%((.-)%)", function(key)
    return hs.execute(key, true)
  end)
  if path:sub(1, 2) == "~/" then
    path = HOME_DIR .. path:sub(2)
  end
  return path
end

-- Extract the file name from a filesystem path.
local function getFileName(path)
  return path:match(".*/([^/]*)")
end

-- Post-process a synced file using a shell command.
--
-- The file is temporarily renamed to ensure atomic replacement
-- after post-processing completes.
local function postprocessAfterFunc(command, targetDir, watchedDir, path)
  local target = targetDir .. "/" .. getFileName(path)
  hs.execute(strfmt([[
mv "%s" "%s";

]] .. command .. [[ "%s" > "%s";

rm "%s"
]],
    target, target .. ".tmp",
    target .. ".tmp", target,
    target .. ".tmp"))
end

-- Load file synchronization configuration.
--
-- Configuration is read from config/sync.json and supports:
-- - Variable definitions for path computation
-- - File-to-target mappings
-- - Optional post-processing hooks
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
      spec[5] = bind(postprocessAfterFunc, v[2].post_process)
    end
  end
  tinsert(filesToSync, spec)
end

-- Register filesystem watchers for configured sync paths.
--
-- Each watcher reacts to file changes and triggers synchronization
-- according to the corresponding configuration entry.
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
  tinsert(SyncPathWatchers, watcher)
end


-- HTTP-based clipboard bridge.
--
-- This section exposes a simple HTTP server that allows other devices
-- on the local network to exchange clipboard contents with this machine.
--
-- Supported content types:
-- - Plain text
-- - Images (PNG / JPEG / TIFF)
-- - Files (saved to ~/Downloads)
--
-- GET requests return the current clipboard contents.
-- Non-GET requests push content into the local clipboard.

--- Handle incoming HTTP requests for clipboard synchronization.
local function handleRequest(method, path, headers, body)
  print("[LOG] Received " .. method .. " request for " .. path)
  print("[LOG] Headers: " .. hs.inspect.inspect(headers))

  if method == "GET" then
    local contentType, contentDisposition, content
    local types = hs.pasteboard.pasteboardTypes()

    if tcontain(types, "public.file-url") then
      contentType = "application/octet-stream"
      local filePath = hs.pasteboard.readURL().filePath
      contentDisposition = "attachment; filename=\"" .. hs.pasteboard.readString() .. "\""
      local file = io.open(filePath, "rb")
      assert(file)
      content = file:read("*all")
      file:close()
    elseif tcontain(types, "public.utf8-plain-text") then
      contentType = "text/plain"
      content = hs.pasteboard.readString()
    elseif tcontain(types, "public.png") then
      contentType = "image/png"
      content = hs.pasteboard.readImage():encodeAsURLString()
    elseif tcontain(types, "public.jpeg") then
      contentType = "image/jpeg"
      content = hs.pasteboard.readImage():encodeAsURLString()
    elseif tcontain(types, "public.tiff") then
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

  if headers["Content-Type"]:find("text/") then
    hs.pasteboard.setContents(body)
    print("[LOG] Copied text to clipboard: " .. body)
  elseif headers["Content-Type"]:find("image/") then
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
  elseif headers["Content-Type"]:find("application/") then
    local filename
    if headers["Content-Disposition"] ~= nil then
      local disposition = headers["Content-Disposition"]
      local pattern = "filename=\"(.-)\""
      filename = disposition:match(pattern)
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

-- Start the local HTTP server for clipboard sharing.
HTTPServer = hs.httpserver.new():setPort(8086):setCallback(handleRequest):start()
