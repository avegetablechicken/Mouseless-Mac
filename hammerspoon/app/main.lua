local function loadMainPart(part)
  local path = hs.configdir .. "/app/main/" .. part .. ".lua"
  local chunk, err = loadfile(path, "t", _ENV)
  if not chunk then
    error(err)
  end
  chunk()
end

loadMainPart("hotkey_utils")
loadMainPart("app_hotkeys")
loadMainPart("shared_hotkeys")
loadMainPart("registration")

loadMainPart("shared_behaviors")
loadMainPart("app_behaviors")
