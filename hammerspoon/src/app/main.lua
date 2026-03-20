local mainNamespace = {}

local function loadMainPart(part)
  local path = hs.configdir .. "/src/app/main/" .. part .. ".lua"
  local partEnv = setmetatable({
    exportMainSymbol = function(name, value)
      mainNamespace[name] = value
    end,
  }, {
    __index = function(_, key)
      local value = mainNamespace[key]
      if value ~= nil then
        return value
      end
      return _ENV[key]
    end,
    __newindex = _ENV,
  })
  local chunk, err = loadfile(path, "t", partEnv)
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
