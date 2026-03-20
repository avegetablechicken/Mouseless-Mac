-- System-level features and integrations.
--
-- This module is organized by feature under `system/`.

require "utils"

local function loadSystemPart(part)
  local path = hs.configdir .. "/src/system/" .. part .. ".lua"
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
