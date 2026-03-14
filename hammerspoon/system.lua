-- System-level features and integrations.
--
-- This module is organized by feature under `system/`.

require "utils"

local function loadSystemPart(part)
  local path = hs.configdir .. "/system/" .. part .. ".lua"
  local chunk, err = loadfile(path, "t", _ENV)
  if not chunk then
    error(err)
  end
  chunk()
end

loadSystemPart("proxy")
loadSystemPart("controlcenter")
loadSystemPart("menubar")
loadSystemPart("misc")

-- forward callbacks to respective modules

function System_applicationInstalledCallback(files, flagTables)
  SystemProxy_applicationInstalledCallback(files, flagTables)
end

function System_monitorChangedCallback()
  SystemMisc_monitorChangedCallback()
end

function System_networkChangedCallback(storeObj, changedKeys)
  SystemProxy_networkChangedCallback(storeObj, changedKeys)
end

function System_batteryChangedCallback()
  SystemMisc_batteryChangedCallback()
end
