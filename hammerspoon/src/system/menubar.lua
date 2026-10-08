-- Menu bar item search.
--
-- Provides a chooser-based interface to search and trigger
-- menu bar items across running applications.

local menuBarReveal = require("utils.menubar_reveal")

local function scanSearchMenuBarItems()
  -- Collect menu bar items from all running applications.
  -- For each app, try to load autosaved status item identifiers
  -- and map them to accessibility menu bar elements if available.
  local menuBarItems, maps, unpositioned = {}, {}, {}
  local controlCenterMenuBarItems, controlCenterPreferred
  local apps = hs.application.runningApplications()
  if OS_VERSION >= OS.Tahoe then
    local allowedApps = getAllowedMenuBarAppsTahoe()
    apps = tifilter(apps, function(app)
      local appid = app:bundleID()
      if app:kind() < 0 and appid ~= "barrier"
          and appid ~= "cn.better365.iShotProHelper" then return false end
      local isAllowed = allowedApps and allowedApps[appid] or true
      local apath
      if isAllowed == nil and appid ~= "com.apple.WebKit.WebContent" then
        apath = app:path() or ""
        local pos = apath:sub(1, -4):find(".app/", 1, true)
        if pos then
          local appPath = apath:sub(1, pos + 3)
          local info = hs.application.infoForBundlePath(appPath)
          if info and info.CFBundleIdentifier then
            local id = info.CFBundleIdentifier
            isAllowed = allowedApps and allowedApps[id] or true
          else
            isAllowed = false
          end
        end
      end
      if isAllowed ~= nil or apath ~= "" then
        return isAllowed or false
      end
      return true
    end)
  end
  for _, app in ipairs(apps) do
    local appid = app:bundleID() or app:name()
    local map, preferred, appMenuBarItems = loadStatusItemsAutosaveName(app, true)
    if appid == 'com.apple.controlcenter' then
      controlCenterMenuBarItems = appMenuBarItems
      controlCenterPreferred = preferred
    end
    if map and #map > 0 then
      assert(preferred)
      maps[appid] = map
      if appid ~= 'com.apple.controlcenter' or OS_VERSION < OS.Tahoe then
        if appMenuBarItems then
          for i, item in ipairs(appMenuBarItems) do
            tinsert(menuBarItems, { item, i, preferred[i] })
          end
        else
          for i, item in ipairs(preferred) do
            tinsert(unpositioned, { app, i, item })
          end
        end
      end
    end
  end
  if #menuBarItems == 0 and #unpositioned == 0 then
    return
  end

  -- Sort menu bar items by their on-screen position (right to left),
  -- falling back to autosave name order when accessibility position
  -- is unavailable.
  for _, item in ipairs(menuBarItems) do item._position = item[1].AXPosition end
  table.sort(menuBarItems, function(a, b)
    if a._position and b._position then
      return a._position.x > b._position.x
    else
      return a[3] < b[3]
    end
  end)

  -- On Tahoe and newer macOS, Control Center hosts additional menu bar items
  -- (e.g. empty entries and Live Activities) that need to be excluded or
  -- merged into the global menu bar ordering
  if OS_VERSION >= OS.Tahoe then
    local appMenuBarItems = controlCenterMenuBarItems or getValidControlCenterMenuBarItemsTahoe(
      find("com.apple.controlcenter")
    )
    local items = {}
    for i, item in ipairs(appMenuBarItems) do
      tinsert(items, { item, i, controlCenterPreferred and controlCenterPreferred[i] })
    end
    table.sort(items, function(a, b)
      return a[1].AXPosition.x > b[1].AXPosition.x
    end)
    foreach(items, function(item)
      local position = item[1].AXPosition.x
      for i=1,#menuBarItems do
        if menuBarItems[i][1].AXPosition and menuBarItems[i][1].AXPosition.x < position then
          tinsert(menuBarItems, i, item)
          return
        end
      end
      tinsert(menuBarItems, #menuBarItems+1, item)
    end)
  end

  -- Trim menu bar items to only those to the right of Control Center.
  for i, pair in ipairs(menuBarItems) do
    local item = pair[1]
    local app
    if item.AXPosition then
      app = item.AXParent.AXParent:asHSApplication()
    else
      app = item
    end
    local appid = app:bundleID() or app:name()
    if appid == 'com.apple.controlcenter' then
      for j=i-1,1,-1 do
        tremove(menuBarItems, j)
      end
      break
    end
  end

  -- Insert items without AX coordinates after sorting and trimming real icons.
  -- Their saved positions must not affect the order of the real icons.
  for _, pair in ipairs(unpositioned) do
    local index = #menuBarItems + 1
    for i, item in ipairs(menuBarItems) do
      if item[3] and item[3] > pair[3] then index = i break end
    end
    tinsert(menuBarItems, index, pair)
  end

  return menuBarItems, maps
end

local function unpositionedMenuBarItemPosition(menuBarItems, index)
  local left, right = menuBarItems[index+1], menuBarItems[index-1]
  if not left or not right then return end
  left, right = left[1], right[1]
  if left.AXPosition and right.AXPosition then
    return hs.geometry.point(
      (left.AXPosition.x + left.AXSize.w + right.AXPosition.x) / 2,
      left.AXPosition.y + left.AXSize.h / 2
    )
  end
end

-- Shared by Search Menu Bar and the overflow bar. Only opening/refreshing a
-- view may rebuild this inventory; activation never scans running applications.
local menuBarInventory
local function invalidateMenuBarInventory()
  menuBarInventory = nil
end
registerApplicationCallback(function(_, event)
  if event == hs.application.watcher.launched or event == hs.application.watcher.terminated then
    invalidateMenuBarInventory()
  end
end)
registerMonitorChangedCallback(invalidateMenuBarInventory)
registerSpaceChangedCallback(invalidateMenuBarInventory)

local function menuBarSignature(windows)
  local records = {}
  for _, w in ipairs(windows) do
    records[#records + 1] = table.concat({ w.id, w.pid, w.x, w.y, w.w, w.h,
      tostring(w.visible), tostring(w.notch) }, ":")
  end
  table.sort(records)
  return table.concat(records, "|")
end

local function collectSearchMenuBarItems()
  local windows = menuBarReveal.items()
  local signature = menuBarSignature(windows)
  if menuBarInventory and menuBarInventory.signature == signature then
    return menuBarInventory.items, menuBarInventory.maps, menuBarInventory
  end
  local items, maps = scanSearchMenuBarItems()
  if not items then invalidateMenuBarInventory() return end
  -- AX collection may service events, so associate against fresh window geometry.
  windows = menuBarReveal.items()
  local inventory = { items = items, maps = maps, windows = windows,
    signature = menuBarSignature(windows), targets = {} }
  for index, pair in ipairs(items) do
    local element, position, app = pair[1]
    local p, size = element.AXPosition, element.AXSize
    if p and size and size.w > 0 and size.h > 0 then
      position = { x = p.x + size.w / 2, y = p.y + size.h / 2 }
      local parent = element.AXParent and element.AXParent.AXParent
      app = parent and parent:asHSApplication()
    elseif not p then
      app = element
      position = unpositionedMenuBarItemPosition(items, index)
    end
    if app and position then
      for _, w in ipairs(windows) do
        if position.x >= w.x and position.x < w.x + w.w
            and position.y >= w.y and position.y < w.y + w.h then
          local old = inventory.targets[w.id]
          if old then
            old.ambiguous = true
          else
            inventory.targets[w.id] = { items = items, element = element,
              hasAXPosition = p ~= nil, pid = app:pid(), hostPID = w.pid,
              choice = { id = index, appid = app:bundleID() or app:name(),
                extraPattern = { element.AXIdentifier or "" } } }
          end
        end
      end
    end
  end
  for id, target in pairs(inventory.targets) do
    if target.ambiguous then inventory.targets[id] = nil end
  end
  menuBarInventory = inventory
  return items, maps, inventory
end

local function activateSearchMenuBarChoice(menuBarItems, choice, right)
  if choice == nil then return end
  hs.timer.doAfter(0, function()
    local item = menuBarItems[choice.id][1]
    if item.AXPosition == nil then
      local position = unpositionedMenuBarItemPosition(menuBarItems, choice.id)
      if position then
        if right or choice.appid == "at.obdev.littlesnitch.agent" then
          rightClickAndRestore(position)
        else
          leftClickAndRestore(position)
        end
      end
      return
    end
    if right then
      if not rightClickAndRestore(item, find(choice.appid))
          and not menuBarReveal.show(item, true) then
        hs.alert.show("Cannot right-click this status item")
      end
      return
    end
    if choice.appid:sub(1, 10) == 'com.apple.' then
      if type(choice.extraPattern) ~= 'table'
          or tfind(choice.extraPattern, function(pattern)
                return pattern:sub(-13) == '.liveActivity'
              end) == nil then
        menuBarItems[choice.id][1]:performAction(AX.Press)
        return
      end
    end
    if not leftClickAndRestore(item, find(choice.appid)) then
      if choice.appid == hs.settings.bundleID then
        if require("utils.menubar").popupProxyMenu(item) then return end
        -- Avoid AX.Press on Hammerspoon's own menu; use the native click instead.
        if menuBarReveal.show(item) then return end
        hs.alert.show("Cannot trigger Hammerspoon menu bar item", 2)
        return
      end
      if menuBarReveal.show(item) then return end
      menuBarItems[choice.id][1]:performAction(AX.Press)
    end
  end)
end

local function registerSearchMenuBar()
  local menuBarItems, maps = collectSearchMenuBarItems()
  if not menuBarItems then return end
  -- Build chooser entries from collected menu bar items.
  -- Each entry includes display text, optional subtitle,
  -- application icon, and extra search patterns.
  local choices = {}
  local ccBentoBoxCnt = 0
  for _, pair in ipairs(menuBarItems) do
    local item, idx = pair[1], pair[2]
    local app
    if item.AXPosition then
      app = item.AXParent.AXParent:asHSApplication()
    else
      app = item
    end
    local appid = app:bundleID() or app:name()
    local appname = app:name()
    local title, extraSearchPattern, autosaveName
    if #maps[appid] > 1 then
      autosaveName = maps[appid][idx]
      if appid == 'com.apple.controlcenter' then
        -- Special handling for Control Center items:
        -- - Normalize BentoBox naming
        -- - Attach additional search patterns
        if autosaveName then
          extraSearchPattern = autosaveName
          if autosaveName:match('^BentoBox%-') then
            if ccBentoBoxCnt > 0 then
              title = "BentoBox-" .. tostring(ccBentoBoxCnt)
            end
            ccBentoBoxCnt = ccBentoBoxCnt + 1
          end
        elseif item.AXDescription:match('^'..appname) then
          if OS_VERSION < OS.Tahoe then
            extraSearchPattern = "BentoBox"
          else
            extraSearchPattern = "BentoBox-" .. tostring(ccBentoBoxCnt)
            if ccBentoBoxCnt > 0 then
              title = "BentoBox-" .. tostring(ccBentoBoxCnt)
            end
            ccBentoBoxCnt = ccBentoBoxCnt + 1
          end
        elseif item.AXIdentifier:sub(-13) == '.liveActivity' then
          extraSearchPattern = item.AXIdentifier
          appname = localizedString('Live Activity', appid)
          title = item.AXDescription
        else
          local parts = strsplit(item.AXIdentifier, "%.")
          extraSearchPattern = parts[#parts]
        end
        extraSearchPattern = { appname, extraSearchPattern }
        if item.AXIdentifier:sub(-13) ~= '.liveActivity' then
          appname = item.AXDescription
        end
      elseif autosaveName ~= "Item-0" or #tifilter(maps[appid],
          function(v) return v:sub(1, 5) == "Item-" end) > 1 then
        title = autosaveName
      end
      if appid ~= 'com.apple.controlcenter' then
        local axTitle = item.AXTitle
        if axTitle and axTitle ~= "" and axTitle ~= title then
          if title then
            title = title .. ' - ' .. axTitle
          end
          extraSearchPattern = axTitle
        end
      end
    end

    local image
    if appid == hs.settings.bundleID then
      image = require("utils.menubar").getIcon(autosaveName)
    end
    if image == nil and app:bundleID() then
      image = hs.image.imageFromAppBundle(appid)
    elseif image == nil then
      -- Use lsof's field output so enclosing app names may contain spaces.
      local pathStr, ok = hs.execute(strfmt([[
          lsof -a -d txt -Fn -p %s 2>/dev/null | sed -n 's/^n//p' | head -1]],
          app:pid()))
      if ok and pathStr ~= "" then
        local parts = hs.fnutils.split(pathStr, "/")

        -- Walk backwards to find the nearest enclosing `.app` bundle
        for i = #parts-1, 1, -1 do
          if parts[i]:sub(-4) == ".app" then
            local subPath = {}
            for j = 1, i do
              table.insert(subPath, parts[j])
            end
            local appPath = table.concat(subPath, "/")
            local info = hs.application.infoForBundlePath(appPath)
            if info and info.CFBundleIdentifier then
              extraSearchPattern = info.CFBundleIdentifier
              image = hs.image.imageFromAppBundle(info.CFBundleIdentifier)
              break
            end
          end
        end
      end
    end
    choices[#choices + 1] = {
      text = appname,
      subText = title,
      image = image,
      id = #choices + 1,
      appid = appid,
      extraPattern = extraSearchPattern
    }
  end
  -- Chooser callback:
  -- Trigger the selected menu bar item using the most reliable method
  -- (accessibility press or simulated mouse click), depending on the item.
  local chooser
  chooser = hs.chooser.new(function(choice)
    if choice == nil then return end
    activateSearchMenuBarChoice(menuBarItems, choice)
  end)

  chooser:searchSubText(true)
  chooser:choices(choices)
  hs.keycodes.currentSourceID("com.apple.keylayout.ABC")
  chooser:show()
end

local function registerWithoutMenuBarManagers(spec, message, callback, onSuspend)
  if spec == nil then return end
  local hotkey
  local menuBarManagers = require("utils.menubar").getManagerBundleIDs()
  local onQuit = function()
    local anyRunning = tfind(menuBarManagers, function(appid)
      return find(appid) ~= nil
    end)
    if not anyRunning then
      if hotkey == nil then
        hotkey = bindHotkeySpec(spec, message, callback)
        if hotkey == nil then return end
        hotkey.kind = HK.MENUBAR
      end
      hotkey:enable()
    end
  end
  local anyRunning = tfind(menuBarManagers, function(appid)
    return find(appid) ~= nil
  end)
  if not anyRunning then
    hotkey = bindHotkeySpec(spec, message, callback)
    if hotkey then hotkey.kind = HK.MENUBAR end
  else
    foreach(menuBarManagers, function(appid)
      if find(appid) then
        ExecOnSilentQuit(appid, onQuit)
      end
    end)
  end
  foreach(menuBarManagers, function(appid)
    ExecOnSilentLaunch(appid, function()
      if hotkey then
        hotkey:disable()
      end
      if onSuspend then onSuspend() end
      ExecOnSilentQuit(appid, onQuit)
    end)
  end)
end

local misc = KeybindingConfigs.hotkeys.global or {}
registerWithoutMenuBarManagers(misc.searchMenuBar, "Search Menu Bar", registerSearchMenuBar)

-- Keyboard selection of currently visible status icons, without revealing overflow.
local items, selected, screen, overlay, watcher, clickTimer
local mode = hs.hotkey.modal.new()

function mode:exited()
  if watcher then watcher:stop() watcher = nil end
  if overlay then overlay:delete() overlay = nil end
  items, selected, screen = nil, nil, nil
end

local function refresh()
  local id = items and items[selected] and items[selected].id
  local ok, current = pcall(menuBarReveal.visibleItems, screen)
  if not ok then mode:exit() return false end
  for i, item in ipairs(current) do
    if item.id == id then
      items, selected = current, i
      overlay:frame({ x = item.x, y = item.y, w = item.w, h = item.h })
      return true
    end
  end
  mode:exit()
  return false
end

local function move(delta)
  if not refresh() then return end
  selected = (selected - 1 + delta) % #items + 1
  local item = items[selected]
  overlay:frame({ x = item.x, y = item.y, w = item.w, h = item.h })
end

mode:bind({}, "left", function() move(-1) end, nil, function() move(-1) end)
mode:bind({}, "right", function() move(1) end, nil, function() move(1) end)
mode:bind({}, "escape", function() mode:exit() end)
-- Use the search menu's saved-order/neighbor mapping: Tahoe's window PID
-- belongs to Control Center and Little Snitch exposes no AX status item.
local function littleSnitchMenuBarItemPosition(item)
  if not find("at.obdev.littlesnitch.agent") then return false end
  local element = hs.axuielement.systemElementAtPosition(
    { x = item.x + item.w / 2, y = item.y + item.h / 2 })
  -- Ordinary icons expose AXMenuBarItem; Little Snitch hits the host menu bar.
  if not element or element.AXRole ~= AX.MenuBar then return false end
  local menuBarItems = collectSearchMenuBarItems() or {}
  for index, pair in ipairs(menuBarItems) do
    local app = pair[1]
    if app.AXPosition == nil and app:bundleID() == "at.obdev.littlesnitch.agent" then
      local position = unpositionedMenuBarItemPosition(menuBarItems, index)
      return position ~= nil
          and position.x >= item.x and position.x < item.x + item.w
          and position.y >= item.y and position.y < item.y + item.h and position
    end
  end
  return false
end

mode:bind({}, "return", function()
  if not refresh() then return end
  local item = items[selected]
  mode:exit()
  hs.timer.doAfter(0, function()
    local position = littleSnitchMenuBarItemPosition(item)
    if position then
      -- Keep the run loop servicing event taps between mouse down and up.
      local mouse = hs.mouse.absolutePosition()
      local event, types = hs.eventtap.event, hs.eventtap.event.types
      event.newMouseEvent(types.rightMouseDown, position, {}):post()
      clickTimer = hs.timer.doAfter(0.05, function()
        event.newMouseEvent(types.rightMouseUp, position, {}):post()
        hs.mouse.absolutePosition(mouse)
        clickTimer = nil
      end)
    else
      leftClickAndRestore({ x = item.x + item.w / 2, y = item.y + item.h / 2 })
    end
  end)
end)

local function moveFocusToStatusMenus()
  if overlay then mode:exit() return end
  screen = hs.mouse.getCurrentScreen()
  local ok, current = pcall(menuBarReveal.visibleItems, screen)
  if not ok or #current == 0 then
    screen = nil
    hs.alert.show("No visible menu bar items")
    return
  end
  items, selected = current, 1
  local item = items[1]
  overlay = hs.canvas.new({ x = item.x, y = item.y, w = item.w, h = item.h })
  overlay:appendElements({
    type = "rectangle", action = "fill",
    fillColor = { red = 0, green = 0.45, blue = 1, alpha = 0.4 },
  })
  overlay:level(hs.canvas.windowLevels.status + 1)
  overlay:behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
  overlay:show()
  mode:enter()
  local types = hs.eventtap.event.types
  watcher = hs.eventtap.new({ types.leftMouseDown, types.rightMouseDown,
    types.otherMouseDown }, function()
    mode:exit()
    return false
  end):start()
end

local spec = (KeybindingConfigs.hotkeys.global or {}).moveFocusToStatusMenus
if spec then
  local hotkey = bindHotkeySpec(spec, "Move Focus to Status Menus", moveFocusToStatusMenus)
  if hotkey then hotkey.kind = HK.MENUBAR end
end

-- A mirror of overflow status items. Capture explicit window IDs without moving
-- their real windows or changing their saved order in the system menu bar.
local hiddenBar, hiddenEntries, hiddenSelected, hiddenScreen
local validateHiddenReceiver
local hiddenMouseWatcher, hiddenScreenWatcher, hiddenSpaceWatcher
local hiddenAppWatcher, hiddenUpdateTimer
local hiddenMode = hs.hotkey.modal.new()

function hiddenMode:exited()
  for _, observer in pairs({ hiddenMouseWatcher,
      hiddenScreenWatcher, hiddenSpaceWatcher, hiddenAppWatcher, hiddenUpdateTimer }) do
    observer:stop()
  end
  hiddenMouseWatcher, hiddenScreenWatcher, hiddenSpaceWatcher = nil, nil, nil
  hiddenAppWatcher, hiddenUpdateTimer = nil, nil
  if hiddenBar then hiddenBar:delete() hiddenBar = nil end
  hiddenEntries, hiddenSelected, hiddenScreen = nil, nil, nil
end

local function selectHiddenItem(index)
  if not hiddenBar or #hiddenEntries == 0 then return end
  hiddenSelected = (index - 1) % #hiddenEntries + 1
  hiddenBar[2].frame = hiddenEntries[hiddenSelected].cell
end

local function activateHiddenItem(right)
  local entry = hiddenEntries and hiddenEntries[hiddenSelected]
  if not entry then return end
  hiddenMode:exit()
  hs.timer.doAfter(0, function()
    local ok, activated = pcall(function()
      local receiver = validateHiddenReceiver(entry)
      if not receiver then return false end
      activateSearchMenuBarChoice(receiver.items, receiver.choice, right)
      return true
    end)
    if not ok or not activated then hs.alert.show("Cannot activate this status item") end
  end)
end

hiddenMode:bind({}, "escape", function() hiddenMode:exit() end)
hiddenMode:bind({}, "left", function() selectHiddenItem(hiddenSelected - 1) end,
    nil, function() selectHiddenItem(hiddenSelected - 1) end)
hiddenMode:bind({}, "right", function() selectHiddenItem(hiddenSelected + 1) end,
    nil, function() selectHiddenItem(hiddenSelected + 1) end)
hiddenMode:bind({}, "return", function() activateHiddenItem(false) end)
hiddenMode:bind({ "alt" }, "return", function() activateHiddenItem(true) end)

-- Validate just the displayed target, retaining its identity if the bar moved.
validateHiddenReceiver = function(entry)
  local receiver = entry.receiver
  local current = menuBarReveal.windowForID(entry.window.id, entry.window.pid)
  if not receiver or not current or receiver.hostPID ~= current.pid then
    invalidateMenuBarInventory() return
  end
  local app = hs.application.applicationForPID(receiver.pid)
  if not app or (app:bundleID() or app:name()) ~= receiver.choice.appid then
    invalidateMenuBarInventory() return
  end
  local position
  if receiver.hasAXPosition then
    if not receiver.element:isValid() then invalidateMenuBarInventory() return end
    local p, size = receiver.element.AXPosition, receiver.element.AXSize
    if p and size then position = { x = p.x + size.w / 2, y = p.y + size.h / 2 } end
  else
    position = unpositionedMenuBarItemPosition(receiver.items, receiver.choice.id)
  end
  if not position or position.x < current.x or position.x >= current.x + current.w
      or position.y < current.y or position.y >= current.y + current.h then
    invalidateMenuBarInventory() return
  end
  return receiver
end

local function renderHiddenBar()
  local _, _, inventory = collectSearchMenuBarItems()
  if not inventory then hiddenMode:exit() return false end
  local windows = menuBarReveal.hiddenItems(hiddenScreen, inventory.windows)
  if #windows == 0 then hiddenMode:exit() return false end
  local previous = hiddenEntries and hiddenEntries[hiddenSelected].window.id
  local entries, cached = {}, {}
  for _, entry in ipairs(hiddenEntries or {}) do cached[entry.window.id] = entry end
  for _, window in ipairs(windows) do
    local old = cached[window.id]
    local image = old and old.window.pid == window.pid
        and old.window.w == window.w and old.window.h == window.h and old.image
    entries[#entries + 1] = { window = window, image = image or nil,
      receiver = inventory.targets[window.id] }
  end
  local display = hiddenScreen:fullFrame()
  local maxWidth, padding = display.w - 20, 5
  local rowHeight = windows[1].h
  local x, y, width = padding, 0, 0
  for _, entry in ipairs(entries) do
    local w = entry.window
    local cellWidth = math.min(w.w, maxWidth - padding * 2)
    if x + cellWidth + padding > maxWidth and x > padding then
      x, y = padding, y + rowHeight
    end
    entry.cell = { x = x, y = y, w = cellWidth, h = rowHeight }
    entry.image = entry.image or menuBarReveal.snapshot(w)
    x, width = x + cellWidth, math.max(width, x + cellWidth + padding)
  end
  local height = y + rowHeight
  -- Ice centers on its control item; our equivalent anchor is the overflow edge.
  local edge = windows[#windows]
  local anchor = edge.x + edge.w
  local originX = math.max(display.x, math.min(anchor - width / 2,
      display.x + display.w - width))
  local frame = { x = originX,
    y = display.y + windows[1].h + 1, w = width, h = height }
  hiddenEntries, hiddenSelected = entries, 1
  local elements = {
    { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = rowHeight / 5, yRadius = rowHeight / 5 },
      fillColor = { white = 0.1, alpha = 0.96 } },
    { type = "rectangle", action = "fill", frame = entries[1].cell,
      roundedRectRadii = { xRadius = 5, yRadius = 5 },
      fillColor = { red = 0, green = 0.45, blue = 1, alpha = 0.6 } },
  }
  for index, entry in ipairs(entries) do
    if entry.window.id == previous then hiddenSelected = index end
    local cell = entry.cell
    if entry.image then
      elements[#elements + 1] = { type = "image", image = entry.image,
        imageScaling = "scaleProportionally", frame = cell }
    else
      elements[#elements + 1] = { type = "text", text = "?", textSize = 18,
        textColor = { white = 1 }, textAlignment = "center", frame = cell }
    end
    elements[#elements + 1] = { type = "rectangle", action = "fill", frame = cell,
      fillColor = { alpha = 0 }, id = tostring(index),
      trackMouseUp = true, trackMouseEnterExit = true }
  end
  if not hiddenBar then
    hiddenBar = hs.canvas.new(frame):level(hs.canvas.windowLevels.popUpMenu)
        :behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
    hiddenBar:mouseCallback(function(_, message, id)
      local index = tonumber(id)
      if not index then return end
      if message == "mouseEnter" then selectHiddenItem(index) end
      if message == "mouseUp" then
        selectHiddenItem(index)
        activateHiddenItem(false)
      end
    end)
  else
    hiddenBar:frame(frame)
  end
  hiddenBar:replaceElements(table.unpack(elements))
  selectHiddenItem(hiddenSelected)
  hiddenBar:show()
  return true
end

-- Coalesce launch/exit bursts. A few bounded checks allow delayed status item
-- creation without polling or scanning application accessibility trees.
local function scheduleHiddenBarUpdate(_, event, app)
  local events = hs.application.watcher
  if event ~= events.launched and event ~= events.terminated then return end
  if not hiddenBar then return end
  if hiddenUpdateTimer then hiddenUpdateTimer:stop() end
  local delays, attempt = { 0.3, 1, 2 }, 0
  local function check()
    hiddenUpdateTimer = nil
    if not hiddenBar then return end
    local ok, err = pcall(function()
      local windows = menuBarReveal.hiddenItems(hiddenScreen)
      local changed = #windows ~= #hiddenEntries
      for index, window in ipairs(windows) do
        local old = hiddenEntries[index] and hiddenEntries[index].window
        if not old or window.id ~= old.id or window.pid ~= old.pid
            or window.x ~= old.x or window.y ~= old.y
            or window.w ~= old.w or window.h ~= old.h then changed = true break end
      end
      if changed then renderHiddenBar() end
    end)
    if not ok then
      hs.printf("Hidden status items update: %s", err)
      return
    end
    attempt = attempt + 1
    if hiddenBar and delays[attempt] then
      hiddenUpdateTimer = hs.timer.doAfter(delays[attempt], check)
    end
  end
  attempt = 1
  hiddenUpdateTimer = hs.timer.doAfter(delays[attempt], check)
end

local function showHiddenStatusItems()
  if hiddenBar then hiddenMode:exit() return end
  if overlay then mode:exit() end
  hiddenScreen = hs.mouse.getCurrentScreen()
  local ok, shown = pcall(renderHiddenBar)
  if not ok or not shown then
    hiddenMode:exit()
    hs.alert.show(ok and "No hidden status items" or "Cannot show hidden status items")
    if not ok then hs.printf("Hidden status items: %s", shown) end
    return
  end
  hiddenMode:enter()
  local types = hs.eventtap.event.types
  hiddenMouseWatcher = hs.eventtap.new({ types.leftMouseDown, types.rightMouseDown }, function(event)
    local p, f = event:location(), hiddenBar:frame()
    if p.x < f.x or p.x >= f.x + f.w or p.y < f.y or p.y >= f.y + f.h then
      hiddenMode:exit()
    elseif event:getType() == types.rightMouseDown then
      for index, entry in ipairs(hiddenEntries) do
        local cell = entry.cell
        if p.x >= f.x + cell.x and p.x < f.x + cell.x + cell.w
            and p.y >= f.y + cell.y and p.y < f.y + cell.y + cell.h then
          selectHiddenItem(index)
          activateHiddenItem(true)
          return true
        end
      end
    end
    return false
  end):start()
  hiddenScreenWatcher = hs.screen.watcher.new(function() hiddenMode:exit() end):start()
  hiddenSpaceWatcher = hs.spaces.watcher.new(function() hiddenMode:exit() end):start()
  hiddenAppWatcher = hs.application.watcher.new(scheduleHiddenBarUpdate):start()
end

registerWithoutMenuBarManagers(misc.showHiddenStatusItems,
    "Show Hidden Status Items", showHiddenStatusItems,
    function() if hiddenBar then hiddenMode:exit() end end)
