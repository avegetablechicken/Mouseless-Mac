require "utils"

local appsTmpDir = hs.fs.temporaryDirectory() .. hs.settings.bundleID .. "/application"

-- Off: the live Spotlight query converted every update's results with
-- synchronous calls to mds on the main thread, stalling input.
hs.application.enableSpotlightForNameSearches(false)

LoadBuf.runningApplications = {}
foreach(hs.application.runningApplications(), function(app)
  local appid = app:bundleID() or app:name()
  if appid and appid ~= "com.apple.WebKit.WebContent" then
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
