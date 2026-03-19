require "utils"

local appsTmpDir = hs.fs.temporaryDirectory() .. hs.settings.bundleID .. "/application"

hs.application.enableSpotlightForNameSearches(true)

local LoadBuf = {}
LoadBuf.runningApplications = {}
foreach(hs.application.runningApplications(), function(app)
  local appid = app:bundleID() or app:name()
  if appid ~= "com.apple.WebKit.WebContent" then
    LoadBuf.runningApplications[appid] = app
  end
end)

local appEnv = setmetatable({
  appsTmpDir = appsTmpDir,
  LoadBuf = LoadBuf,
}, { __index = _G })

local function loadAppPart(part)
  local path = hs.configdir .. "/src/app/" .. part .. ".lua"
  local chunk, err = loadfile(path, "t", appEnv)
  if not chunk then
    error(err)
  end
  chunk()
end

loadAppPart("boot")
loadAppPart("main")
loadAppPart("lifecycle")

LoadBuf.runningApplications = nil
appEnv.LoadBuf = nil

App_monitorChangedCallback = appEnv.App_monitorChangedCallback
App_spaceChangedCallback = appEnv.App_spaceChangedCallback
App_usbChangedCallback = appEnv.App_usbChangedCallback
