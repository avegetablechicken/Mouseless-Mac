require "utils"

local appsTmpDir = hs.fs.temporaryDirectory() .. hs.settings.bundleID .. "/application"

hs.application.enableSpotlightForNameSearches(true)

local runningAppsOnLoading = {}
foreach(hs.application.runningApplications(), function(app)
  runningAppsOnLoading[app:bundleID() or app:name()] = app
end)

local appEnv = setmetatable({
  appsTmpDir = appsTmpDir,
  runningAppsOnLoading = runningAppsOnLoading,
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

runningAppsOnLoading = nil
appEnv.runningAppsOnLoading = nil

App_monitorChangedCallback = appEnv.App_monitorChangedCallback
App_spaceChangedCallback = appEnv.App_spaceChangedCallback
App_usbChangedCallback = appEnv.App_usbChangedCallback
