-- Fill missing chooser icons while preserving explicit and application icons.
local cache = {}
local function load(slug)
  if cache[slug] == nil then
    local path = hs.configdir .. "/static/hotkeys/" .. slug .. ".svg"
    cache[slug] = hs.fs.attributes(path, "mode") == "file"
        and hs.image.imageFromPath(path) or false
  end
  return cache[slug] or nil
end

return function(entry, image)
  if entry.icon ~= nil then return entry.icon end
  local windowOperation = entry.kind == HK.WIN_OP
      or entry.subkind == HK.WIN_OP_.SPACE_SCREEN
  if image ~= nil and not windowOperation and entry.kind ~= HK.PRIVELLEGE then return image end
  local label = (entry.msg or ""):match(": (.+)$") or entry.msg or ""
  local slug = label:lower():gsub("[^%w]+", "-"):gsub("-$", "")
  local specific = load(slug)
  if specific then return specific end
  if entry.kind == HK.WIN_OP and entry.subkind == HK.WIN_OP_.STAGE_MANAGER then
    local index = label:match("(%d+)$")
    return (index and load("stage-manager-window-" .. index)) or load("stage-manager")
  end
  if image ~= nil then return image end
  local categories = {
    [HK.PRIVELLEGE] = "hotkey", [HK.QUICK_NAVIGATION] = "navigation",
    [HK.IN_APP] = "application", [HK.IN_WIN] = "window",
    [HK.APPKEY] = "application", [HK.BACKGROUND] = "background-action",
    [HK.MENUBAR] = "menu-bar", [HK.WIN_OP] = "window",
  }
  return load(categories[entry.kind] or "hotkey")
end
