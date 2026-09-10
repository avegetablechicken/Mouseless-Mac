-- Local configuration editor. JSON stays in its original files; no web server.
local M = {}
local files = { "misc", "keybindings", "application", "proxy", "private-proxy", "sync", "localization" }
local allowed = {}
for _, name in ipairs(files) do allowed[name] = true end
local snapshots = {}
local function read(path)
  local file, err, code = io.open(path, "rb")
  if not file then return nil, err, code end
  local content = file:read("*a")
  file:close()
  return content
end
local function path(name) return hs.configdir .. "/config/" .. name .. ".json" end

-- Resolve display names once when loading, never during individual UI clicks.
function M.resolveAppNames(configs)
  local names, candidates = {}, {}
  if not hs.application then return names end
  local function collect(value)
    if type(value) == "string" and value:match("^[%w_-]+%.[%w_.-]+$") then
      candidates[value] = true
    elseif type(value) == "table" then
      for key, child in pairs(value) do collect(key); collect(child) end
    end
  end
  for _, file in pairs(configs) do
    local ok, value = pcall(hs.json.decode, file.raw or "")
    if ok then collect(value) end
  end
  for id in pairs(candidates) do
    local appName = hs.application.nameForBundleID(id)
    if appName then names[id] = appName end
  end
  for _, directory in ipairs({ "/Applications", os.getenv("HOME") .. "/Applications" }) do
    if hs.fs.attributes(directory, "mode") == "directory" then
      for entry in hs.fs.dir(directory) do
        local info = entry:sub(-4) == ".app" and hs.application.infoForBundlePath(directory .. "/" .. entry)
        if info and candidates[info.CFBundleIdentifier] and (not names[info.CFBundleIdentifier] or names[info.CFBundleIdentifier] == info.CFBundleIdentifier) then names[info.CFBundleIdentifier] = info.CFBundleDisplayName or info.CFBundleName end
      end
    end
  end
  return names
end

function M.load()
  local result = {}
  for _, name in ipairs(files) do
    local raw, err, code = read(path(name))
    if raw then
      snapshots[name] = raw
      result[name] = { raw = raw }
    elseif code == 2 then
      snapshots[name] = false
      result[name] = { raw = "{}", missing = true }
    else
      snapshots[name] = nil
      result[name] = { error = "Unable to read configuration: " .. tostring(err) }
    end
  end
  M.appNames = M.resolveAppNames(result)
  return result
end

function M.save(name, raw)
  if not allowed[name] or type(raw) ~= "string" then return nil, "Invalid configuration request" end
  local ok, decoded = pcall(hs.json.decode, raw)
  if not ok or type(decoded) ~= "table" or not raw:match("^%s*{") then
    return nil, "Configuration must be a valid JSON object"
  end
  if name == "misc" and decoded.pollingInterval ~= nil
      and (type(decoded.pollingInterval) ~= "number" or decoded.pollingInterval <= 0) then
    return nil, "Polling interval must be greater than 0"
  end
  if (name == "proxy" or name == "private-proxy") and type(decoded.v2rayN) == "table" then
    local client = decoded.v2rayN
    local function validPAC(spec)
      return type(spec) ~= "table" or spec.pac == nil or (type(spec.pac) == "table"
        and type(spec.pac.routing) == "string" and spec.pac.routing:match("%S") ~= nil)
    end
    if not validPAC(client) then return nil, "v2rayN PAC requires a non-empty routing value." end
    for _, location in ipairs(type(client.locations) == "table" and client.locations or {}) do
      if not validPAC(client[location]) then return nil, "v2rayN PAC requires a non-empty routing value." end
    end
  end
  local current, readError, readCode = read(path(name))
  if current == nil and readCode ~= 2 then return nil, "Unable to read configuration: " .. tostring(readError) end
  if snapshots[name] == nil or (current or false) ~= snapshots[name] then
    return nil, "This file changed externally. Refresh before editing again."
  end
  -- Keep a byte-for-byte backup, then replace atomically on the same volume.
  local written, closed, err
  if current then
    local backup
    backup, err = io.open(path(name) .. ".bak", "wb")
    if not backup then return nil, "Unable to create backup: " .. tostring(err) end
    written = backup:write(current)
    closed = backup:close()
    if not written or not closed then return nil, "Backup failed. Configuration was not saved." end
  elseif hs.fs then
    hs.fs.mkdir(hs.configdir .. "/config")
  end
  local temporary = path(name) .. ".tmp"
  local file
  file, err = io.open(temporary, "wb")
  if not file then return nil, "Unable to write configuration: " .. tostring(err) end
  written = file:write(raw)
  closed = file:close()
  if not written or not closed then os.remove(temporary); return nil, "Failed to write configuration" end
  ok, err = os.rename(temporary, path(name))
  if not ok then os.remove(temporary); return nil, "Unable to replace configuration: " .. tostring(err) end
  snapshots[name] = raw
  return true
end

-- Expand only named variables and ~; browsing must never execute shell expressions.
function M.resolveBrowsePath(value, variables)
  if type(value) ~= "string" or value == "" then return nil end
  if value:sub(1, 7) == "file://" then
    value = value:gsub("^file://localhost", ""):gsub("^file://", "")
      :gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  elseif value:find("://", 1, true) then return nil end
  for _ = 1, 12 do
    local expanded = value:gsub("%${([^}]+)}", function(key)
      return type(variables) == "table" and type(variables[key]) == "string" and variables[key] or "${" .. key .. "}"
    end)
    if expanded == value then break end
    value = expanded
  end
  if value:find("${", 1, true) or value:find("$(", 1, true) then return nil end
  if value == "~" or value:sub(1, 2) == "~/" then value = os.getenv("HOME") .. value:sub(2) end
  if value:sub(1, 1) ~= "/" then value = hs.configdir .. "/" .. value end
  return value
end

function M.choosePath(request)
  local function kind(value)
    local resolved = M.resolveBrowsePath(value, request.variables)
    local mode = resolved and hs.fs.attributes(resolved, "mode")
    return (mode == "file" or mode == "directory") and mode or nil
  end
  local required = request.requiredType == "directory" and "directory" or nil
  local initial = M.resolveBrowsePath(request.current, request.variables)
  if not initial or not hs.fs.attributes(initial) then
    initial = M.resolveBrowsePath("~/Downloads")
    if type(request.applicationID) == "string" then
      local app = hs.application.pathForBundleID(request.applicationID)
      if app then initial = app .. "/Contents/Resources" end
    end
  elseif request.parentDirectory then
    initial = initial:gsub("/+$", ""):match("^(.*)/[^/]+$") or "/"; if initial == "" then initial = "/" end
  end
  local message = required == "directory" and "Select a destination folder."
    or "Select a file or folder."
  local ok, selected = pcall(hs.dialog.chooseFileOrFolder, message, initial,
    required ~= "directory", required ~= "file", false)
  if not ok then return { action = "browsed", id = request.id, error = "Unable to open the path chooser." } end
  if type(selected) == "table" then selected = selected["1"] or selected[1] end
  if type(selected) ~= "string" or selected == "" then return { action = "browsed", id = request.id, cancelled = true } end
  local selectedKind = kind(selected)
  if not selectedKind or (required and selectedKind ~= required) then
    return { action = "browsed", id = request.id, error = "Destination must be a folder." }
  end
  return { action = "browsed", id = request.id, path = selected, kind = selectedKind }
end

function M.chooseApplication(request)
  local ok, selected = pcall(hs.dialog.chooseFileOrFolder,
    "Select an application.", "/Applications", true, true, false, { "app" })
  if not ok then return { action = "applicationBrowsed", id = request.id, error = "Unable to open the application chooser." } end
  if type(selected) == "table" then selected = selected["1"] or selected[1] end
  if type(selected) ~= "string" or selected == "" then
    return { action = "applicationBrowsed", id = request.id, cancelled = true }
  end
  local info = selected:lower():sub(-4) == ".app" and hs.application.infoForBundlePath(selected)
  local bundleID = info and info.CFBundleIdentifier
  if type(bundleID) ~= "string" or bundleID == "" then
    return { action = "applicationBrowsed", id = request.id, error = "The selected application has no bundle ID. Please enter it manually." }
  end
  local proxyName = ProxyAppConfigurationName and ProxyAppConfigurationName(bundleID)
    or info.CFBundleDisplayName or info.CFBundleName or selected:match("([^/]+)%.app$")
  return { action = "applicationBrowsed", id = request.id, bundleID = bundleID, proxyName = proxyName }
end

local function reply(value)
  if M.view then M.view:evaluateJavaScript("window.receive(" .. hs.json.encode(value) .. ")") end
end

function M.show()
  if M.view then M.view:show(); M.view:hswindow():focus(); return end
  local html, err = read(hs.configdir .. "/static/configuration/index.html")
  if not html then hs.alert.show(tostring(err)); return end
  local appIcon = hs.image.imageFromAppBundle(hs.settings.bundleID)
  if appIcon then
    local source = appIcon:setSize({ w = 64, h = 64 }):encodeAsURLString()
    html = html:gsub('<div class="logo">H</div>', function()
      return '<img class="logo app-logo" src="' .. source .. '" alt="Hammerspoon">'
    end)
  end
  M.controller = hs.webview.usercontent.new("configuration")
  M.controller:setCallback(function(message)
    local body = message.body
    if type(body) ~= "table" then return end
    if body.action == "load" then
      local configs = M.load()
      reply({ action = "loaded", files = configs, appNames = M.appNames,
        proxyApps = ProxyAppInstallationStatus and ProxyAppInstallationStatus() or {},
        appBindings = AppKeyInspector and AppKeyInspector.snapshot() or {} })
    elseif body.action == "save" then
      local ok, saveError = M.save(body.name, body.raw)
      reply({ action = "saved", name = body.name, raw = ok and body.raw or nil,
        error = saveError })
    elseif body.action == "browseApplication" then
      reply(M.chooseApplication(body))
    elseif body.action == "browsePath" then
      reply(M.choosePath(body))
    elseif body.action == "reload" then
      if M.reloading then return end
      M.reloading = true
      hs.settings.set("configuration.reopenAfterReload", true)
      M.reloadTimer = hs.timer.doAfter(0, hs.reload)
    end
  end)
  local frame = hs.screen.mainScreen():frame()
  local w, h = math.min(1080, frame.w - 60), math.min(780, frame.h - 60)
  M.view = hs.webview.new({ x = frame.x + (frame.w-w)/2, y = frame.y + (frame.h-h)/2, w = w, h = h },
    { privateBrowsing = true, javaScriptCanOpenWindowsAutomatically = false }, M.controller)
    :windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    :windowTitle("Configuration"):allowTextEntry(true):deleteOnClose(false)
  -- Closing hides the window, retaining drafts until the next configuration reload.
  M.view:html(html):show()
  M.view:hswindow():focus()
end

function M.start()
  hs.urlevent.bind("configuration", M.show)
  if hs.settings.get("configuration.reopenAfterReload") then
    M.reopenTimer = hs.timer.doAfter(0, function()
      hs.settings.clear("configuration.reopenAfterReload")
      M.show()
    end)
  end
  return M
end
return M
