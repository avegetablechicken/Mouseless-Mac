local function loadMainPart(part)
  local path = hs.configdir .. "/src/app/main/" .. part .. ".lua"
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

-- forward callbacks to respective modules

-- monitor callbacks
function App_monitorChangedCallback()
  AppBehavior_monitorChangedCallback()
end

-- workspace callbacks
function App_spaceChangedCallback()
  AppSharedHotkeys_spaceChangedCallback()
end

-- usb callbacks
function App_usbChangedCallback(device)
  AppBehavior_usbChangedCallback(device)
end
