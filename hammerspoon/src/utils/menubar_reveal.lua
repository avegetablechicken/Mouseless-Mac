-- Activate a hidden status window without Cmd-dragging it. Dragging a status
-- item into view can leave it ordered on-screen even after its position returns.
local M = {}
local native, clickTimer, busy

local function bridge()
  if native then return native end
  local source = hs.configdir .. '/src/utils/menubar_native.m'
  local file = assert(io.open(source, 'r'))
  local content = file:read('*a') file:close()
  local binary = hs.fs.temporaryDirectory() .. 'hammerspoon-menubar-'
      .. hs.hash.SHA256(content) .. '.so'
  if not hs.fs.attributes(binary) then
    local quote = function(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    local output, ok = hs.execute('/usr/bin/clang -shared -fPIC -fobjc-arc'
        .. ' -undefined dynamic_lookup -framework Cocoa ' .. quote(source)
        .. ' -o ' .. quote(binary) .. ' 2>&1')
    assert(ok, output)
  end
  native = assert(package.loadlib(binary, 'luaopen_menubar_native'))()
  return native
end

local function identify(item, windows)
  local p, s = item and item.AXPosition, item and item.AXSize
  if not p or not s then return end
  local x, y, found = p.x + s.w / 2, p.y + s.h / 2
  for _, w in ipairs(windows) do
    if x >= w.x and x < w.x + w.w and y >= w.y and y < w.y + w.h then
      if found then return end -- overlapping displays/Spaces are ambiguous
      found = w
    end
  end
  return found
end

-- The native click is addressed to the status window, so a notch/overflow
-- does not redirect the click to the menu bar background or another app.
function M.show(item)
  if busy then return true end
  if not item:isValid()
      or (hs.caffeinate.sessionProperties() or {}).CGSSessionScreenIsLocked then
    return false
  end
  local ok, windows = pcall(function() return bridge().list() end)
  if not ok then hs.printf('Menu bar activation: %s', windows) return false end
  local window = identify(item, windows)
  if not window then return false end
  local parent = item.AXParent and item.AXParent.AXParent
  local owner = parent and parent:asHSApplication()
  if not owner then return false end
  local pid = owner:pid() -- Tahoe's host window belongs to Control Center, not the receiver.
  local mouse = hs.mouse.absolutePosition()
  local x, y = window.x + window.w / 2, window.y + window.h / 2
  busy = true
  local pressed = native.send(1, x, y, window.id, pid)
  if not pressed then
    native.send(2, x, y, window.id, pid)
    hs.mouse.absolutePosition(mouse)
    busy = false
    return false
  end
  clickTimer = hs.timer.doAfter(0.05, function()
    local released = native.send(2, x, y, window.id, pid)
    hs.mouse.absolutePosition(mouse)
    busy, clickTimer = false, nil
    if not released then hs.alert.show('Could not finish menu bar click') end
  end)
  return true
end

return M
