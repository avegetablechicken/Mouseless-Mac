-- Activate a hidden status window without Cmd-dragging it. Dragging a status
-- item into view can leave it ordered on-screen even after its position returns.
local M = {}
local native, clickTimer, busy
local revealTimer

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
  -- Window order changes; prefer the host reporting expanded overflow.
  local window = tfind(getc(toappui(app), AX.Window), function(w)
    return tfind(getc(w, AX.Button) or {}, function(b)
      return b:attributeValue("AXDescription") == localizedString("menuBar.hideOverflowItemsAccessibilityLabel", app:bundleID(), "MenuBarCore")
    end)
  end) or getc(toappui(app), AX.Window, 2)
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
  local position = item.clickPoint or { x = item.x + item.w / 2, y = item.y + item.h / 2 }
  local mouse = item.restorePosition or hs.mouse.absolutePosition()
  local event, types = hs.eventtap.event, hs.eventtap.event.types
  busy = true
  hs.mouse.absolutePosition(position)
  -- Tested on: Snipaste 2.11.3; macOS 27.0.1. A zero click count is ignored.
  event.newMouseEvent(right and types.rightMouseDown or types.leftMouseDown, position, {})
      :setProperty(event.properties.mouseEventClickState, 1):post()
  clickTimer = hs.timer.doAfter(item.holdDelay or 0.05, function()
    event.newMouseEvent(right and types.rightMouseUp or types.leftMouseUp, position, {})
        :setProperty(event.properties.mouseEventClickState, 1):post()
    clickTimer = hs.timer.doAfter(0.1, function()
      hs.mouse.absolutePosition(mouse)
      -- A warp posts no mouseMoved, so Ping Island keeps capturing the notch
      -- area for about 0.5s after the overflow click.
      -- Tested on: Ping Island 0.32.1; macOS 27.0.1.
      event.newMouseEvent(types.mouseMoved, mouse, {}):post()
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
  local notch = find("com.wudanwu.PingIsland")
  local background = notch and getc(toappui(notch), AX.Window, 1, AX.Group, 1)
  -- Ping Island's transparent root spans the screen, beyond its visible content.
  -- It also reacts to hovering near the notch; never fall back toward it.
  -- Prefer an inset point on the far side; use its edge only as a last resort.
  -- Tested on: Ping Island 0.32.1; macOS 27.0.1.
  local full = screen:fullFrame()
  local right = p.x + size.w / 2 >= full.x + full.w / 2
  for _, dx in ipairs(right and { size.w * 3 / 4, size.w - 1 } or { size.w / 4, 1 }) do
    local point = { x = p.x + dx, y = p.y + size.h / 2 }
    local hit = hs.axuielement.systemElementAtPosition(point)
    local clear = hit and hit:pid() == button:pid()
    if background and hit == background then
      clear = not tfind(background.AXChildren, function(child)
        local cp, cs = child.AXPosition, child.AXSize
        return cp and cs and point.x >= cp.x and point.x < cp.x + cs.w
            and point.y >= cp.y and point.y < cp.y + cs.h
      end)
    end
    if clear then
      return M.clickGoldenGate({ x = p.x, y = p.y, w = size.w, h = size.h,
        clickPoint = point, holdDelay = 0.2 }), true
    end
  end
end

-- Source AX items retain collapsed coordinates; click the rendered host instead.
local function renderedItem(item, screen)
  local candidates = {}
  for _, visible in ipairs(M.visibleItems(screen)) do
    if visible.element == item then return visible end
    if visible.element and visible.element:pid() == item:pid() then
      candidates[#candidates + 1] = visible
    end
  end
  local app = hs.application.applicationForPID(item:pid())
  if not app then return end
  local _, preferred, sources = loadStatusItemsAutosaveName(app, true)
  if not sources or #sources ~= #candidates then return end
  local ordered = {}
  for index, source in ipairs(sources) do
    if not preferred[index] then return end
    ordered[#ordered + 1] = { source = source, position = preferred[index] }
  end
  table.sort(ordered, function(a, b) return a.position < b.position end)
  table.sort(candidates, function(a, b) return a.x > b.x end)
  for index, entry in ipairs(ordered) do
    if entry.source == item then return candidates[index] end
  end
end

M.renderedItem = renderedItem

function M.revealBeforeActivation(item, activate)
  if OS_VERSION < OS["Golden Gate"] then return false end
  local p = item.AXPosition
  if not p then return false end
  local screen = hs.screen.find({ x = p.x, y = p.y, w = 1, h = 1 })
  if not screen then return false end
  local _, button, expanded = goldenGateMenuBar(screen)
  if not button or p.x >= button.AXPosition.x + button.AXSize.w then return false end
  if revealTimer then return true end
  if not M.setOverflowExpanded(screen, true) then
    hs.alert.show("Cannot show hidden status items")
    return true
  end
  local attempts = 0
  local function ready()
    revealTimer = nil
    if not item:isValid() then return end
    local _, _, shown = goldenGateMenuBar(screen)
    local target = not busy and shown and renderedItem(item, screen)
    if target then
      activate(target)
      return
    end
    attempts = attempts + 1
    if attempts < 20 then
      revealTimer = hs.timer.doAfter(0.05, ready)
    else
      hs.alert.show("Cannot show hidden status items")
    end
  end
  revealTimer = hs.timer.doAfter(0.05, ready)
  return true
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
