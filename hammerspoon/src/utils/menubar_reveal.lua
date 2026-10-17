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

-- Visible status windows also cover apps which expose no AX menu bar items.
function M.items()
  return bridge().list()
end

local function goldenGateMenuBar(screen)
  local app = find("com.apple.MenuBarAgent")
  if not app then return end
  -- The second host window exposes the rendered buttons; the first exposes
  -- application proxies whose hidden-item coordinates overlap.
  local window = getc(toappui(app), AX.Window, 2)
  if not window then return end
  local p, size, frame = window.AXPosition, window.AXSize, screen:fullFrame()
  if not p or not size or p.x ~= frame.x or p.y ~= frame.y then return end
  local show = localizedString("menuBar.showOverflowItemsAccessibilityLabel",
      app:bundleID(), "MenuBarCore")
  local hide = localizedString("menuBar.hideOverflowItemsAccessibilityLabel",
      app:bundleID(), "MenuBarCore")
  local button = tfind(getc(window, AX.Button), function(item)
    local label = item:attributeValue("AXDescription")
    return label ~= nil and (label == show or label == hide)
  end)
  return window, button, button and button:attributeValue("AXDescription") == hide
end

function M.clickGoldenGate(item, right)
  if busy then return false end
  local position = { x = item.x + item.w / 2, y = item.y + item.h / 2 }
  local mouse = hs.mouse.absolutePosition()
  local event, types = hs.eventtap.event, hs.eventtap.event.types
  busy = true
  hs.mouse.absolutePosition(position)
  event.newMouseEvent(right and types.rightMouseDown or types.leftMouseDown, position, {}):post()
  clickTimer = hs.timer.doAfter(0.05, function()
    event.newMouseEvent(right and types.rightMouseUp or types.leftMouseUp, position, {}):post()
    clickTimer = hs.timer.doAfter(0.1, function()
      hs.mouse.absolutePosition(mouse)
      busy, clickTimer = false, nil
    end)
  end)
  return true
end

function M.setOverflowExpanded(screen, expanded)
  local _, button, current = goldenGateMenuBar(screen)
  if not button then return false end
  if expanded == nil then expanded = not current end
  if current == expanded then return true, false end
  -- This system button advertises no AX actions; use its verified hit region.
  local p, size = button.AXPosition, button.AXSize
  return M.clickGoldenGate({ x = p.x, y = p.y, w = size.w, h = size.h }), true
end

local function goldenGateItems(screen)
  local window, button, expanded = goldenGateMenuBar(screen)
  if not window then return {} end
  local edge = button and button.AXPosition.x + button.AXSize.w
  local frame, items = screen:fullFrame(), {}
  for _, host in ipairs(window.AXChildren) do
    if host ~= button then
      local p, size = host.AXPosition, host.AXSize
      local hidden = p and edge and p.x < edge
      local revealed = hidden and expanded and size and p.x + size.w <= button.AXPosition.x
      -- Collapsed overflow elements still exist, stacked beneath the arrow.
      if p and size and size.w > 1 and size.h > 0
          and p.x >= frame.x and p.x + size.w <= frame.x + frame.w
          and (not hidden or revealed) then
        local element = getc(host, nil, 1)
        if element and element.AXRole == AX.Group then element = getc(element, AX.MenuBarItem, 1) end
        items[#items + 1] = { id = host, x = p.x, y = p.y,
          w = size.w, h = size.h, element = element }
      end
    end
  end
  table.sort(items, function(a, b) return a.x < b.x end)
  return items
end

function M.visibleItems(screen)
  if OS_VERSION >= OS["Golden Gate"] then return goldenGateItems(screen) end
  local frame = screen:fullFrame()
  local items = {}
  for _, w in ipairs(bridge().list()) do
    if w.visible and not w.notch and w.w > 1 and w.h > 0
        and w.x >= frame.x and w.x < frame.x + frame.w
        and w.y >= frame.y and w.y < frame.y + w.h
        and w.y + w.h <= frame.y + frame.h then
      w.w = math.min(w.w, frame.x + frame.w - w.x)
      items[#items + 1] = w
    end
  end
  table.sort(items, function(a, b) return a.x < b.x end)
  return items
end

function M.hiddenItems(screen, windows)
  local frame, items = screen:fullFrame(), {}
  for _, w in ipairs(windows or bridge().list()) do
    if w.w > 1 and w.h > 0 and w.y >= frame.y and w.y < frame.y + w.h
        and w.x < frame.x + frame.w
        and (not w.visible or w.notch or w.x < frame.x) then
      items[#items + 1] = w
    end
  end
  table.sort(items, function(a, b) return a.x < b.x end)
  return items
end

function M.windowForID(id, pid)
  for _, window in ipairs(bridge().list()) do
    if window.id == id and window.pid == pid then return window end
  end
end

function M.snapshot(window)
  local url = bridge().snapshot(window.id)
  return url and hs.image.imageFromURL(url) or nil
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

local function pressWindow(window, pid, right)
  local down, up = right and 3 or 1, right and 4 or 2
  local mouse = hs.mouse.absolutePosition()
  local x, y = window.x + window.w / 2, window.y + window.h / 2
  busy = true
  local pressed = native.send(down, x, y, window.id, pid)
  if not pressed then
    native.send(up, x, y, window.id, pid)
    hs.mouse.absolutePosition(mouse)
    busy = false
    return false
  end
  clickTimer = hs.timer.doAfter(0.05, function()
    local released = native.send(up, x, y, window.id, pid)
    hs.mouse.absolutePosition(mouse)
    busy, clickTimer = false, nil
    if not released then hs.alert.show('Could not finish menu bar click') end
  end)
  return true
end

-- The native click is addressed to the status window, so a notch/overflow
-- does not redirect the click to the menu bar background or another app.
function M.show(item, right)
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
  return pressWindow(window, pid, right)
end

return M
