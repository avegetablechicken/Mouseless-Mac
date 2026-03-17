------------------------------------------------------------
-- Parsing and emitting key bindings stored in plist files
------------------------------------------------------------

-- Parse a key binding encoded in macOS plist format.
--
-- Some applications store their key bindings in plist files,
-- where modifiers and keys are represented as bit masks.
local function parsePlistKeyBinding(mods, key)
  mods = tonumber(mods) key = tonumber(key)
  if mods == nil or key == nil then return end
  key = hs.keycodes.map[key]
  local modList = {}
  if mods >= (1 << 17) then
    if mods >= (1 << 23) then tinsert(modList, Mod.Fn) end
    if (mods % (1 << 23)) >= (1 << 20) then tinsert(modList, Mod.Cmd.Long) end
    if (mods % (1 << 20)) >= (1 << 19) then tinsert(modList, Mod.Alt.Long) end
    if (mods % (1 << 19)) >= (1 << 18) then tinsert(modList, Mod.Ctrl.Long) end
    if (mods % (1 << 18)) >= (1 << 17) then tinsert(modList, Mod.Shift.Long) end
  else
    if mods >= (1 << 12) then tinsert(modList, Mod.Ctrl.Long) end
    if (mods % (1 << 12)) >= (1 << 11) then tinsert(modList, Mod.Alt.Long) end
    if (mods % (1 << 11)) >= (1 << 9) then tinsert(modList, Mod.Shift.Long) end
    if (mods % (1 << 9)) >= (1 << 8) then tinsert(modList, Mod.Cmd.Long) end
  end
  return modList, key
end

-- Dump a key binding into plist-compatible encoded values.

local function dumpPlistKeyBinding(mode, mods, key)
  local modIdx = 0
  if mode == 1 then
    if tcontain(mods, Mod.Cmd.Long) then modIdx = (1 << 8) end
    if tcontain(mods, Mod.Alt.Long) then modIdx = modIdx + (1 << 11) end
    if tcontain(mods, Mod.Ctrl.Long) then modIdx = modIdx + (1 << 12) end
    if tcontain(mods, Mod.Shift.Long) then modIdx = modIdx + (1 << 9) end
  elseif mode == 2 then
    if key:lower():match("^f(%d+)$") then modIdx = 1 << 23 end
    if tcontain(mods, Mod.Cmd.Long) then modIdx = modIdx + (1 << 20) end
    if tcontain(mods, Mod.Alt.Long) then modIdx = modIdx + (1 << 19) end
    if tcontain(mods, Mod.Ctrl.Long) then modIdx = modIdx + (1 << 18) end
    if tcontain(mods, Mod.Shift.Long) then modIdx = modIdx + (1 << 17) end
  end
  key = hs.keycodes.map[key]
  return modIdx, key
end


----------------------------------------------------------------------
-- Hotkeys in specific applications
--
-- This section defines:
--   1. Window / application classifiers (WF: Window Filter)
--   2. Title providers for hotkey display
--   3. Action callbacks bound to specific UI elements
--
-- Design principles:
--   - Hotkeys are registered dynamically per application/window
--   - A hotkey exists ONLY when its target window matches WF rules
--   - Titles are computed lazily and may depend on UI structure
--
-- Core concepts:
--   - WF (Window Filter): describes *where* a hotkey is valid
--   - Callback: describes *what* the hotkey does
--   - Title function: describes *how the hotkey is shown*
----------------------------------------------------------------------

-- ### Finder
local Finder = {}
Finder.sidebarItemTitle = function(idx)
  return function(win)
    local outline = getc(towinui(win), AX.SplitGroup, 1,
        AX.ScrollArea, 1, AX.Outline, 1)
    if outline == nil then return end
    local header
    local cnt = 0
    for _, row in ipairs(getc(outline, AX.Row)) do
      if #row == 0 then hs.timer.usleep(0.3 * 1000000) end
      local titleElem = getc(row, AX.Cell, 1, AX.StaticText, 1)
      if titleElem and titleElem.AXIdentifier ~= nil then
        header = titleElem.AXValue
      elseif titleElem then
        cnt = cnt + 1
        if cnt == idx then
          local itemTitle = titleElem.AXValue
          if A_AppBuf.finderSidebarItemObserver == nil then
            local app = win:application()
            local observer = uiobserver.new(app:pid())
            observer:addWatcher(outline, uinotifications.rowCountChanged)
            observer:callback(function()
              if A_AppBuf.lastRowCountChangedTimer then
                A_AppBuf.lastRowCountChangedTimer:setNextTrigger(0.1)
                return
              end
              A_AppBuf.lastRowCountChangedTimer = hs.timer.doAfter(0.1, function()
                A_AppBuf.lastRowCountChangedTimer = nil
                HotkeyRegistry.deleteWindowHotkeys(app, function(_, hkID)
                  return hkID:match('^open(.-)SidebarItem$') ~= nil
                end)
                for hkID, cfg in pairs(AppHotKeyCallbacks[app:bundleID()]) do
                  if hkID:match('^open(.-)SidebarItem$') then
                    registerInWinHotKeys(app:focusedWindow(), cfg.windowFilter)
                    break
                  end
                end
              end)
            end)
            observer:start()
            A_AppBuf.finderSidebarItemObserver = observer
            Evt.StopOnDeactivated(app, A_AppBuf.finderSidebarItemObserver)
          end
          return header .. ' > ' .. itemTitle
        end
      end
    end
  end
end

Finder.getSidebarItem = function(idx)
  return function(win)
    local outline = getc(towinui(win), AX.SplitGroup, 1,
        AX.ScrollArea, 1, AX.Outline, 1)
    if outline == nil then return false end
    local cnt = 0
    for _, row in ipairs(getc(outline, AX.Row)) do
      local titleElem = getc(row, AX.Cell, 1, AX.StaticText, 1)
      if titleElem and titleElem.AXIdentifier == nil then
        cnt = cnt + 1
      end
      if cnt == idx then
        return true, getc(row, AX.Cell, 1)
      end
    end
    return false
  end
end

Finder.openSidebarItem = function(cell, win)
  local app = win:application()
  local go = T("Go", app)
  local itemTitle = getc(cell, AX.StaticText, 1).AXValue
  if app:findMenuItem{ go, itemTitle } ~= nil then
    app:selectMenuItem{ go, itemTitle }
  else
    local flags = hs.eventtap.checkKeyboardModifiers()
    if not (flags[Mod.Cmd.Short] or flags[Mod.Alt.Short] or flags[Mod.Ctrl.Short]) then
      cell:performAction(AX.Open)
    else
      local tapper
      tapper = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged },
      function(event)
        tapper:stop()
        hs.timer.doAfter(0.01, function()
          local newFlags = hs.eventtap.checkKeyboardModifiers()
          if newFlags[Mod.Cmd.Short] or newFlags[Mod.Alt.Short] or newFlags[Mod.Ctrl.Short] then
            event:setFlags{}:post()
            hs.timer.doAfter(0.01, function()
              cell:performAction(AX.Open)
            end)
          else
            cell:performAction(AX.Open)
          end
        end)
        return false
      end):start()
      local event = hs.eventtap.event.newEvent()
      event:setType(hs.eventtap.event.types.flagsChanged)
      event:setFlags{}:post()
    end
  end
end

-- ### Messages
local Messages = {}
Messages.deleteSelected = function(app)
  if app:focusedWindow() == nil then return end
  local winUI = towinui(app:focusedWindow())
  local button
  if OS_VERSION >= OS.Tahoe:withMinor(2) then
    button = getc(winUI, AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Button, 2)
  elseif OS_VERSION >= OS.Tahoe then
    button = getc(winUI, AX.Group, 1, AX.Group, 1,
        AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Button, 2)
  else
    button = getc(winUI, AX.Group, 1, AX.Group, 1,
        AX.Group, 2, AX.Group, 1, AX.Button, 2)
  end
  if button ~= nil then
    Callback.Press(button)
    hs.timer.doAfter(0.2, function()
      if not app:isRunning() then return end
      if app:focusedWindow():role() == AX.Sheet then
        local sheet = towinui(app:focusedWindow())
        local delete = getc(sheet, AX.Button, 2)
        Callback.Press(delete)
      end
    end)
    return
  end

  local _, menuItem = findMenuItem(app, {
    OS_VERSION < OS.Ventura and "File" or "Conversation",
    "Delete Conversation…"
  })
  app:selectMenuItem(menuItem)
  local title = T("Delete", app)
  hs.timer.doAfter(0.2, function()
    if not app:isRunning() then return end
    if app:focusedWindow():role() == AX.Sheet then
      local sheet = towinui(app:focusedWindow())
      local delete = getc(sheet, AX.Button, title)
      if delete == nil then
        local totalDelay = 0
        repeat
          hs.timer.usleep(0.05 * 1000000)
          totalDelay = totalDelay + 0.05
          delete = getc(sheet, AX.Button, title)
        until delete or totalDelay >= 0.5
        if delete == nil then return end
      end
      Callback.Press(delete)
    end
  end)
end

Messages.messageItems = function(app)
  local appUI = toappui(app)
  if OS_VERSION >= OS.Tahoe:withMinor(2) then
    return getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 2, AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.StaticText)
  elseif OS_VERSION >= OS.Tahoe then
    return getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
        AX.StaticText)
  else
    return getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.StaticText)
  end
end

Messages.deletable = function(app)
  local messageItems = Messages.messageItems(app)
  if messageItems == nil or #messageItems == 0 then
    return false
  end
  local desc = T('New Message', app)
  if messageItems[1].AXDescription == nil
      or messageItems[1].AXDescription:sub(4) == desc
      or messageItems[1].AXValue ~= nil then
    tremove(messageItems, 1)
  end
  return #messageItems > 0, messageItems
end

Messages.deleteAll = function(messageItems, app)
  local cnt = #messageItems
  local firstMsg, lastMsg = messageItems[1], messageItems[cnt]
  local frame = app:focusedWindow():frame()
  while frame.y + frame.h < lastMsg.AXPosition.y + lastMsg.AXSize.h do
    cnt = cnt - 1
    lastMsg = messageItems[cnt]
  end

  local firstSelected = firstMsg.AXSelected
  if not firstSelected then
    hs.timer.doAfter(0.1, bind(Callback.Press, firstMsg))
  end
  if #messageItems == 1
      or (#messageItems == 2 and lastMsg.AXSelected) then
    if firstSelected then
      Messages.deleteSelected(app)
    else
      hs.timer.doAfter(0.3, bind(Messages.deleteSelected, app))
    end
    return
  end

  hs.timer.doAfter(0.5, function()
    for i=2,#messageItems do
      messageItems[i].AXSelected = false
    end
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, true):post()
    hs.timer.doAfter(1, function()
      Callback.Press(lastMsg)
      hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, false):post()
      Messages.deleteSelected(app)

      hs.timer.doAfter(2, function()
        if not app:isFrontmost() then return end
        local continue
        continue, messageItems = Messages.deletable(app)
        if continue then
          Messages.deleteAll(messageItems, app)
        end
      end)
    end)
  end)
end

-- ### Phone
local Phone = {}
Phone.WF = {}
Phone.WF.Main = {}
if OS_VERSION >= OS.Tahoe then
  Evt.OnRunning("com.apple.mobilephone", function(app)
    Phone.WF.Main.allowTitles = '^' .. app:name() .. '$'
  end)
end

local function PhoneShowViewMenu(winUI)
  local button = getc(winUI, AX.Toolbar, 1,
      AX.Group, 2, AX.Group, 1, AX.MenuButton, 1)
  if button then
    Callback.Press(button) return true
  end
  return false
end

Phone.hoveringOverCall = function(win)
  local appUI = towinui(win).AXParent
  local elemHoveredOver = appUI:elementAtPosition(hs.mouse.absolutePosition())
  if elemHoveredOver.AXRole ~= AX.Button then return false end
  local collection = elemHoveredOver.AXParent
  if OS_VERSION >= OS.Tahoe then
    collection = collection.AXParent
  end
  return collection.AXDescription == T("Recents", win)
end

Phone.hasCall = function(win)
  local collection, section
  if OS_VERSION < OS.Tahoe:withMinor(2) then
    collection = getc(towinui(win), AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 1)
  else
    collection = getc(towinui(win), AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1)
  end
  if collection and collection.AXDescription == T("Recents", win) then
    section = getc(collection, AX.Group, 1, AX.Button, 1)
  end
  return section ~= nil, section
end

Phone.deleteAll = function(section, win)
  local app = win:application()
  if section.AXDescription == T("Clear All", win) then
    Callback.Press(section)
    local title = section.AXDescription
    hs.timer.doAfter(0.2, function()
      if not app:isRunning() then return end
      if app:focusedWindow():role() == AX.Sheet then
        local sheet = towinui(app:focusedWindow())
        local delete = getc(sheet, AX.Button, title)
        if delete == nil then
          local totalDelay = 0
          repeat
            hs.timer.usleep(0.05 * 1000000)
            totalDelay = totalDelay + 0.05
            delete = getc(sheet, AX.Button, title)
          until delete or totalDelay >= 0.5
          if delete == nil then return end
        end
        Callback.Press(delete)
      end
    end)
    return
  end

  if not rightClick(section, app) then
    return
  end

  local winUI = towinui(win)
  local popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
  local maxTime, time = 0.5, 0
  while popup == nil and time < maxTime do
    hs.timer.usleep(0.01 * 1000000)
    time = time + 0.01
    popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
  end
  if popup == nil then
    if not rightClick(section, app) then
      return
    end
    popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
    time = 0
    while popup == nil and time < maxTime do
      hs.timer.usleep(0.01 * 1000000)
      time = time + 0.01
      popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
    end
    if popup == nil then return end
  end
  local locTitle = T("Delete", app)
  local menuItem = getc(popup, AX.MenuItem, locTitle)
  if menuItem ~= nil then
    Callback.Press(menuItem)
  end
  hs.timer.usleep(0.1 * 1000000)
  Phone.deleteAll(section, win)
end

Phone.selectView = function(index)
  return function(win)
    local winUI  = towinui(win)
    if not PhoneShowViewMenu(winUI) then return end
    local menu
    repeat
      hs.timer.usleep(0.01 * 1000000)
      menu = getc(winUI, AX.Toolbar, 1, AX.Group, 2, AX.Menu, 1)
    until menu or not winUI:isValid()
    local menuItem = getc(menu, AX.MenuItem, index)
    if menuItem then Callback.Press(menuItem) end
  end
end

-- ### FaceTime
local FaceTime = {}
FaceTime.WF = {}
FaceTime.WF.Main = {}
Evt.OnRunning("com.apple.FaceTime", function(app)
  FaceTime.WF.Main.allowTitles = '^' .. app:name() .. '$'
end)

FaceTime.hoveringOverCall = function(win)
  local appUI = towinui(win).AXParent
  local elemHoveredOver = appUI:elementAtPosition(hs.mouse.absolutePosition())
  if elemHoveredOver.AXRole ~= AX.Button then return false end
  local collection = elemHoveredOver.AXParent
  if OS_VERSION >= OS.Tahoe then
    collection = collection.AXParent
  end
  return collection.AXDescription == T("Recent Calls", win)
end

FaceTime.deleteMousePositionCall = function(win)
  local app = win:application()
  local winUI = towinui(win)

  if not rightClick(hs.mouse.absolutePosition(), app) then
    return
  end
  local popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
  local maxTime, time = 0.5, 0
  while popup == nil and time < maxTime do
    hs.timer.usleep(0.01 * 1000000)
    time = time + 0.01
    popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
  end
  if popup == nil then
    if not rightClick(hs.mouse.absolutePosition(), app) then
      return
    end
    popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
    time = 0
    while popup == nil and time < maxTime do
      hs.timer.usleep(0.01 * 1000000)
      time = time + 0.01
      popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
    end
    if popup == nil then return end
  end
  local title = app:bundleID() == "com.apple.mobilephone"
      and "Delete" or "Remove from Recents"
  local locTitle = T(title, app)
  local menuItem = getc(popup, AX.MenuItem, locTitle)
  if menuItem ~= nil then
    Callback.Press(menuItem)
  end
end

FaceTime.hasCall = function(win)
  local section
  if OS_VERSION >= OS.Tahoe then
    local collection
    if OS_VERSION >= OS.Tahoe:withMinor(2) then
      collection = getc(towinui(win), AX.Group, 1, AX.Group, 1,
          AX.Group, 2, AX.Group, 1, AX.Group, 1)
    else
      collection = getc(towinui(win), AX.Group, 1, AX.Group, 1,
          AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
          AX.Group, 1)
    end
    if collection and collection.AXDescription == T("Recent Calls", win) then
      section = getc(collection, AX.Group, 1, AX.Button, 1)
    end
  else
    local collection = getc(towinui(win), AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 2)
    if collection and collection.AXDescription == T("Recent Calls", win) then
      section = getc(collection, AX.Button, 1)
    end
  end
  return section ~= nil, section
end

FaceTime.deleteAll = function(section, win)
  local app = win:application()
  if OS_VERSION < OS.Tahoe then
    local menuItem, menuItemPath = findMenuItem(app, { "FaceTime", "Remove All Recents" })
    if Callback.Enabled(menuItem) then
      app:selectMenuItem(menuItemPath)
      return
    end
  end

  if not rightClick(section, app) then
    return
  end

  local winUI = towinui(win)
  local popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
  local maxTime, time = 0.5, 0
  while popup == nil and time < maxTime do
    hs.timer.usleep(0.01 * 1000000)
    time = time + 0.01
    popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
  end
  if popup == nil then
    if not rightClick(section, app) then
      return
    end
    popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
    time = 0
    while popup == nil and time < maxTime do
      hs.timer.usleep(0.01 * 1000000)
      time = time + 0.01
      popup = getc(winUI, AX.Group, 1, AX.Menu, 1)
    end
    if popup == nil then return end
  end
  local locTitle = T("Remove from Recents", app)
  local menuItem = getc(popup, AX.MenuItem, locTitle)
  if menuItem ~= nil then
    Callback.Press(menuItem)
  end
  hs.timer.usleep(0.1 * 1000000)
  if OS_VERSION >= OS.Tahoe then
    local sheet = getc(winUI, AX.Sheet, 1)
    time, maxTime = 0, 0.2
    while sheet == nil and time < maxTime do
      hs.timer.usleep(0.01 * 1000000)
      time = time + 0.01
      sheet = getc(winUI, AX.Sheet, 1)
    end
    if sheet then
      Callback.Press(getc(sheet, AX.Button, -1))
    end
  end
  FaceTime.deleteAll(section, win)
end

local function FaceTimeShowViewMenu(win)
  local button
  if OS_VERSION < OS.Tahoe:withMinor(2) then
    button = getc(towinui(win), AX.Group, 1, AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
        AX.Button, 1)
  else
    button = getc(towinui(win), AX.Group, 1, AX.Group, 1,
        AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Button, 1)
  end
  if button then
    Callback.Press(button) return true
  end
  return false
end

FaceTime.selectView = function(index)
  return function(win)
    if not FaceTimeShowViewMenu(win) then return end
    local winUI  = towinui(win)
    local menu
    repeat
      hs.timer.usleep(0.01 * 1000000)
      menu = getc(winUI, AX.Group, 1, AX.Menu, 1)
    until menu or not winUI:isValid()
    local menuItem = getc(menu, AX.MenuItem, index)
    if menuItem then Callback.Press(menuItem) end
  end
end

-- ### Music
local Music = {}
Music.WF = {}
Music.WF.Main = {
  fn = function(win)
    local rows = getc(towinui(win), AX.SplitGroup, 1,
        AX.ScrollArea, 1, AX.Outline, 1, AX.Row)
    return rows and #rows > 0
  end
}

Music.viewTitle = function(index)
  return function(win)
    local rows = A_WinBuf:get("mainWindowViews", function()
      local outline = getc(towinui(win), AX.SplitGroup, 1,
          AX.ScrollArea, 1, AX.Outline, 1)
      if outline == nil then return end
      local rows, sum = getc(outline, AX.Row), 0
      for _, r in ipairs(rows) do sum = sum + r.AXSize.h end
      local mean = sum / #rows
      rows = tifilter(rows, function(r)
        return r.AXSize.h > mean and getc(r, AX.Cell, 1, AX.StaticText, 1) ~= nil
      end)
      if rows[1] then
        local image = getc(rows[1], AX.Cell, 1, AX.Image, 1)
        if image.AXDescription == TG("magnifyingglass", win) then
          tremove(rows, 1)
        end
      end
      local app = win:application()
      local observer = uiobserver.new(app:pid())
      observer:addWatcher(outline, uinotifications.rowCountChanged)
      observer:callback(A_WinHotkeyWrapper(function()
        if A_WinBuf.lastRowCountChangedTimer then
          A_WinBuf.lastRowCountChangedTimer:setNextTrigger(0.1)
          return
        end
        A_WinBuf.lastRowCountChangedTimer =
            hs.timer.doAfter(0.1, A_WinHotkeyWrapper(function()
          A_WinBuf.mainWindowViews = nil
          A_WinBuf.lastRowCountChangedTimer = nil
          HotkeyRegistry.deleteWindowHotkeys(app, function(_, hkID)
            return hkID:match('^view(%d-)$') ~= nil
          end)
          for hkID, cfg in pairs(AppHotKeyCallbacks[app:bundleID()]) do
            if hkID:match('^view(%d-)$') then
              registerInWinHotKeys(app:focusedWindow(), cfg.windowFilter)
              break
            end
          end
        end))
      end))
      observer:start()
      A_WinBuf.musicSidebarItemObserver = observer
      Evt.StopOnDeactivated(app, A_WinBuf.musicSidebarItemObserver)
      return rows
    end)
    local text = getc(rows[index], AX.Cell, 1, AX.StaticText, 1)
    return text and text.AXValue
  end
end

Music.selectView = function(index)
  return function()
    local row = A_WinBuf.mainWindowViews[index]
    if row then
      row.AXSelected = true
    end
  end
end

-- ### Games
local Games = {}
Games.WF = {}
Games.WF.Main = {
  fn = function(win)
    return getc(towinui(win), AX.Toolbar, 1) ~= nil
  end
}

--- ### Weather
local Weather = {}
Weather.getLocationList = function(app)
  local win = app:focusedWindow()
  if win == nil then return end
  local list
  if OS_VERSION >= OS.Tahoe:withMinor(2) then
    list = getc(towinui(win), AX.Group, 1,
        AX.Group, 1, AX.Group, 2, AX.Group, 2, AX.Group, 1, AX.Group, 1)
  else
    list = getc(towinui(win), AX.Group, 1,
        AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1)
    if OS_VERSION >= OS.Tahoe then list = getc(list, AX.Group, 1) end
  end
  if list and list.AXDescription == T("Location List", app) then
    return tifilter(list.AXChildren or {}, function(elem)
      return #elem > 0 and elem[1].AXRole == AX.Button
    end)
  end
end

-- ### Visual Studio Code
local VSCode = {}
VSCode.WF = {}
VSCode.WF.Main = {
  fn = function(win)
    local winUI = towinui(win)
    return winUI.AXIdentifier ~= "open-panel"
  end
}

VSCode.toggleSideBarSection = function(win, sidebar, section)
  local pressfn
  if appVer(win) < "1.101" then
    pressfn = Callback.Press
  else
    if A_AppBuf.VSCodeTabClicked then return end
    A_AppBuf.VSCodeTabClicked = false
    pressfn = function(button)
      leftClickAndRestore(button, win)
    end
  end

  local winUI = towinui(win)
  local ancestor = getc(winUI,
      nil, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
      nil, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
      AX.Group, 2, AX.Group, 2, AX.Group, 1, AX.Group, 2)
  if ancestor == nil then
    ancestor = getc(winUI,
        nil, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
        AX.Group, 2, AX.Group, 2, AX.Group, 1, AX.Group, 2)
  end

  local elem = getc(ancestor, AX.Group, 2, AX.Heading, 1)
      or getc(ancestor, AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Heading, 1)
  if elem and elem.AXTitle:sub(1, #sidebar) == sidebar then
    local sections = getc(ancestor, AX.Group, 2, AX.Group, 2,
          AX.Group, 1, AX.Group, 2, AX.Group)
        or getc(ancestor, AX.Group, 2, AX.Group, 1,
          AX.Group, 1, AX.Group, 2, AX.Group)
    for _, sec in ipairs(sections) do
      local button = getc(sec, AX.Button, 1)
          or getc(sec, AX.Group, 1, AX.Button, 1)
      if button[2].AXTitle == section then
        pressfn(button)
        break
      end
    end
  else
    local tabs = getc(ancestor, AX.Group, 1,
        AX.Group, 1, AX.TabGroup, 1, AX.RadioButton)
    local tab = tfind(tabs, function(t)
      return t.AXTitle:upper():sub(1, #sidebar) == sidebar
          or t.AXDescription:upper():sub(1, #sidebar) == sidebar
    end)
    if appVer(win) >= "1.101" then
      A_AppBuf.VSCodeTabClicked = true
      hs.timer.doAfter(2, function()
        A_AppBuf.VSCodeTabClicked = nil
      end)
    end
    pressfn(tab)

    local sections
    local totalDelay = 0
    repeat
      sections = getc(ancestor, AX.Group, 2, AX.Group, 1,
                      AX.Group, 1, AX.Group, 2, AX.Group)
          or getc(ancestor, AX.Group, 2, AX.Group, 2,
                  AX.Group, 1, AX.Group, 2, AX.Group)
      if sections then break end
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
    until totalDelay > 0.2
    if sections == nil then
      leftClickAndRestore(tab, winUI:asHSWindow())
      repeat
        sections = getc(ancestor, AX.Group, 2, AX.Group, 1,
                        AX.Group, 1, AX.Group, 2, AX.Group)
            or getc(ancestor, AX.Group, 2, AX.Group, 2,
                    AX.Group, 1, AX.Group, 2, AX.Group)
        if sections then break end
          hs.timer.usleep(0.05 * 1000000)
          totalDelay = totalDelay + 0.05
      until totalDelay > 2.0
      if sections == nil then return end
    end
    for _, sec in ipairs(sections) do
      local button = getc(sec, AX.Button, 1)
          or getc(sec, AX.Group, 1, AX.Button, 1)
      if button[2].AXTitle == section then
        local records = getc(sec, AX.Group, 1, AX.Outline, 1, AX.Group, 1)
            or getc(sec, AX.Group, 1)
        if records == nil or #records == 1 then
          pressfn(button)
          break
        end
      end
    end
  end
end

-- ### WPS Office
local WPS = {}
WPS.WF = {}

WPS.WF.Home = {}
WPS.WF.NonHome = {}
Evt.OnRunning("com.kingsoft.wpsoffice.mac", function(app)
  local title = T("Home", app)
  WPS.WF.Home.allowTitles = '^'..title..'$'
  WPS.WF.NonHome.rejectTitles = WPS.WF.Home.allowTitles
end)

WPS.WF.Settings = {
  allowRoles = AX.Dialog,
  fn = function(win)
    local winUI = towinui(win)
    return getc(winUI, AX.Button, "Prev") ~= nil
        and getc(winUI, AX.Button, "Next") ~= nil
  end
}

WPS.WF.WPS_WPP = {
  allowTitles = "",
  fn = function(win)
    local appid = win:application():bundleID()
    local menuBarItems = getc(toappui(win:application()),
        AX.MenuBar, 1, AX.MenuBarItem)
    local params = { locale = A_AppLocale }
    return tfind(menuBarItems, function(item)
      return item.AXTitle == localizedMenuBarItem("Tables", appid, params)
          or item.AXTitle == localizedMenuBarItem("Slide Show", appid, params)
    end) ~= nil
  end
}

WPS.WF.WPS_WPP_ET = {
  allowTitles = "",
  fn = function(win)
    local appid = win:application():bundleID()
    local menuBarItems = getc(toappui(win:application()),
        AX.MenuBar, 1, AX.MenuBarItem)
    local params = { locale = A_AppLocale }
    return tfind(menuBarItems, function(item)
      return item.AXTitle == localizedMenuBarItem("Tables", appid, params)
          or item.AXTitle == localizedMenuBarItem("Slide Show", appid, params)
          or item.AXTitle == localizedMenuBarItem("Data", appid, params)
    end) ~= nil
  end
}

WPS.WF.PDF = {
  allowTitles = "",
  fn = function(win)
    local appid = win:application():bundleID()
    local params = { locale = A_AppLocale }
    local locTitle = localizedMenuBarItem("Comment", appid, params)
    local menuBarItem = getc(toappui(win:application()),
        AX.MenuBar, 1, AX.MenuBarItem, locTitle)
    return menuBarItem ~= nil
  end
}

-- ### JabRef
local JabRef = {}

JabRef.WF = {}
JabRef.WF.numberLibraries = function(idx)
  return {
    allowTitles = "",
    fn = function(win)
      local winUI = towinui(win)
      local bts = getc(winUI, AX.TabGroup, 1, AX.RadioButton)
      return bts and #bts >= idx
    end
  }
end

JabRef.showLibraryByIndex = function(idx)
  return function(win)
    local tab = getc(towinui(win), AX.TabGroup, 1, AX.RadioButton, idx)
    return Callback.Clickable(tab, { 10, 10 })
  end
end

-- ### App Cleaner & Uninstaller
local AppCleanerUninstaller = {}
AppCleanerUninstaller.buttonValid = function(title)
  return function(app)
    local winUI = towinui(app:focusedWindow())
    local sg = getc(winUI, AX.SplitGroup, 1)
    if sg == nil then return false end
    local locTitle = T(title, app)
    local button = tfind(getc(sg, AX.Button), function(bt)
      return bt.AXIdentifier == "uaid:RemoveSelectedItemsButton"
          and bt.AXTitle == locTitle and bt.AXEnabled
    end)
    return button ~= nil, button
  end
end

AppCleanerUninstaller.confirmButtonValid = function(title)
  return function(app)
    local winUI = towinui(app:focusedWindow())
    local cancel = tfind(getc(winUI, AX.Button), function(bt)
      return bt.AXIdentifier == "uaid:RemoveDialogSecondButton" and bt.AXEnabled
    end)
    if cancel == nil then return false end
    local locTitle = T(title, app)
    local button = getc(winUI, AX.StaticText, locTitle)
    return Callback.Clickable(button)
  end
end

--- ## WeChat
local WeChat = {}
WeChat.WF = {
  Main = {
    fn = function(win)
      if appVer(win) >= "4" then
        local view1 = getc(towinui(win), AX.Group, 1, AX.Button, 1)
        return view1 and view1.AXTitle == win:title()
      else
        local view1 = getc(towinui(win), AX.RadioButton, 1)
        return view1 and view1.AXDescription == T("Tabbar.Chats", win)
      end
    end
  },
  Moments = {
    fn = function(win)
      local app = win:application()
      local title = win:title()
      if title:find(app:name()) == nil then
        if appVer(app) >= "4.0.6" then
          local moments = findMenuItemByKeyBinding(app, "⌘", "4", "Window")
          return moments and title == moments[2]
        elseif appVer(app) >= "4" then
          return title == T("Moments", win)
        else
          local album = T("Album_WindowTitle", win)
          local moments = T("SNS_Feed_Window_Title", win)
          local detail = T("SNS_Feed_Detail_Title", win)
          return title:find(album .. '-') == 1
              or title == moments .. '-' .. detail
        end
      end
    end
  },
  Preview = { },
  PreviewEditable = { },
  PhotoEditor = { },
  AppEx = {
    fn = function(win)
      local app = win:application()
      local exBundleID = "com.tencent.flue.WeChatAppEx"
      local params = { locale = A_AppLocale }
      local menuItemPath = {
        localizedMenuBarItem("Window", exBundleID, params),
        localizedString("Select Previous Tab", exBundleID, params)
      }
      if menuItemPath[2] then
        local menuItem = app:findMenuItem(menuItemPath)
        if menuItem then
          A_WinBuf.selectMenuItemPath = menuItemPath
        end
        return menuItem ~= nil
      end
    end
  },
  AppExWeb = {
    fn = function(win)
      if appVer(win) < "4" then
        local g = getc(towinui(win), AX.Group, 1)
        return g ~= nil and g.AXDOMClassList ~= nil
      else
        local bt = getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Group, 1, AX.Group, 1, nil, 1)
        A_WinBuf.closeWebButton = bt
        return bt ~= nil
            and (bt.AXRole == AX.Button or bt.AXRole == AX.PopUpButton)
      end
    end
  },
  AppExSingleTab = {
    fn = function(win)
      local exBundleID = "com.tencent.flue.WeChatAppEx"
      local params = { locale = A_AppLocale }
      local menuItemPath = {
        localizedMenuBarItem('File', exBundleID, params),
        localizedString('Close All Tabs', exBundleID, params)
      }
      if menuItemPath[2] then
        local menuItem = win:application():findMenuItem(menuItemPath)
        if not Callback.Enabled(menuItem) then return false end
      end
      local menuItemPath2 = {
        menuItemPath[1],
        localizedString('Close Tab', exBundleID, params)
      }
      if menuItemPath2[2] then
        local menuItem = win:application():findMenuItem(menuItemPath2)
        if menuItem then
          A_WinBuf.closeWindowMenuItemPath = menuItemPath
        end
        return menuItem and not menuItem.enabled
      end
    end
  },
  Confirm = {
    allowSheet = true,
    fn = function(win)
      local winUI = towinui(win)
      if #winUI == 4 then
        if winUI[1].AXRole == AX.StaticText
            and winUI[3].AXRole == AX.Button
            and winUI[4].AXRole == AX.Button
            and winUI[4].AXEnabled then
          A_WinBuf.confirmButton = winUI[4]
          return true
        end
      elseif #winUI == 3 then
        if winUI[1].AXRole == AX.StaticText
            and winUI[2].AXRole == AX.StaticText
            and winUI[3].AXRole == AX.Button
            and winUI[3].AXEnabled then
          A_WinBuf.confirmButton = winUI[3]
          return true
        end
      elseif #winUI == 1 then
        repeat
          winUI = winUI[1]
        until #winUI ~= 1
        if #winUI == 3
            and winUI[1].AXRole == AX.StaticText
            and winUI[2].AXRole == AX.Button
            and winUI[3].AXRole == AX.Button
            and winUI[3].AXEnabled then
          A_WinBuf.confirmButton = winUI[2]
          return true
        end
      else
        local title = localizedString("Send To", win)
        if type(title) ~= 'table' then
          title = { title }
        end
        for _, t in ipairs(title) do
          local text = getc(winUI, AX.StaticText, 1)
          if text and text.AXValue == t
              and winUI[#winUI].AXRole == AX.Button then
            A_WinBuf.confirmButton = winUI[#winUI]
            return true
          end
        end
        return false
      end
    end
  },
  ConfirmDefault = { allowSheet = true },
  SelectContacts = {
    allowSheet = true,
    fn = function(win)
      local title = T("Select contacts to add", win)
      return getc(towinui(win), AX.List, title) ~= nil
    end
  }
}
Evt.OnRunning("com.tencent.xinWeChat", function(app)
  if appVer(app) < "4" then
    if WeChat.WF.Preview.fn == nil then
      WeChat.WF.Preview.fn = function(win)
        local rotate = T("Rotate", app)
        local buttons = getc(towinui(win), AX.Button)
        local button = tfind(buttons, function(bt)
          return bt.AXHelp == rotate
        end)
        A_WinBuf.buttons = buttons
        return button ~= nil
      end
    end

    if WeChat.WF.PreviewEditable.fn == nil then
      WeChat.WF.PreviewEditable.fn = function(win)
        local edit = T("Edit", app)
        local buttons = getc(towinui(win), AX.Button)
        local button = tfind(buttons, function(bt)
          return bt.AXHelp == edit
        end)
        A_WinBuf.buttons = buttons
        return button ~= nil
      end
    end

    local title = T("Window", app)
    WeChat.WF.PhotoEditor.allowTitles = '^' .. title .. '$'
    if WeChat.WF.PhotoEditor.fn == nil then
      WeChat.WF.PhotoEditor.fn = function(win)
        local crop = T("Crop", app)
        local buttons = getc(towinui(win), AX.Button)
        local button = tfind(buttons, function(bt)
          return bt.AXHelp == crop
        end)
        A_WinBuf.buttons = buttons
        return button ~= nil
      end
    end
  elseif appVer(app) < "4.0.6" then
    local title = T("Preview", app)
    WeChat.WF.Preview.allowTitles = '^' .. title .. '$'
    WeChat.WF.PreviewEditable.allowTitles = '^' .. title .. '$'
    title = T("Photo Editor", app)
    WeChat.WF.PhotoEditor.allowTitles = '^' .. title .. '$'
  end
end)

--- ### QQLive
local QQLive = {}
QQLive.WF = {}
QQLive.WF.Main = {
  fn = function(win)
    local winUI = towinui(win)
    local text = getc(winUI, AX.Group, 2, nil, -1)
    A_WinBuf.lastRow = text
    return text and text.AXValue == "全部频道"
  end
}
QQLive.channelName = function(index)
  return function(win)
    local _, _, channelNames = A_WinBuf:get("channelList", "rowCount", "channelNames",
    function()
      local list = getc(towinui(win), AX.Group, 2)
      if list == nil or #list == 0 then return end
      local rowCnt = #list
      local start = A_WinBuf:get("channelStartIndex", function()
        local start = 1
        local verticalOffset, verticalOffsetChangeIdx
        for i=2,math.min(10, rowCnt) do
          local offset = list[i].AXPosition.y - list[i-1].AXPosition.y
          if offset ~= verticalOffset then
            verticalOffset = offset
            verticalOffsetChangeIdx = i - 1
          elseif i - verticalOffsetChangeIdx >= 3 then
            start = verticalOffsetChangeIdx
            break
          end
        end
        if start == 1 then
          for i=2,math.min(10, rowCnt) do
            if list[i].AXValue == "VIP会员" and i < rowCnt then
              local offset = list[i].AXPosition.y - list[i-1].AXPosition.y
              for j=i+1,math.min(rowCnt) do
                if list[j].AXPosition.y - list[j-1].AXPosition.y == offset then
                  start = j
                  break
                end
              end
              break
            end
          end
        end
        return start
      end)
      local channelNames = {}
      for i = 1, 10 do
        if rowCnt - 2 >= start + i - 1 then
          local row = list[start + i - 1]
          tinsert(channelNames, row.AXValue)
        end
      end
      return list, rowCnt, channelNames
    end)
    return channelNames[index]
  end
end

QQLive.getChannel = function(index)
  return function()
    local start = A_WinBuf.channelStartIndex
    local list = A_WinBuf.channelList
    local rowCnt = A_WinBuf.rowCount
    local lastRow = A_WinBuf.lastRow
    if rowCnt - 2 >= start + index - 1 then
      local row = list[start + index - 1]
      lastRow = lastRow or list[rowCnt]
      if row.AXPosition.y > list.AXPosition.y
          and row.AXPosition.y + row.AXSize.h < lastRow.AXPosition.y - 15 then
        return Callback.Clickable(row)
      elseif row.AXPosition.y <= list.AXPosition.y
          and row.AXPosition.y + row.AXSize.h > list.AXPosition.y then
        return Callback.Clickable(row, { row.AXSize.w / 2, row.AXSize.h })
      elseif row.AXPosition.y + row.AXSize.h >= lastRow.AXPosition.y - 15
          and row.AXPosition.y < lastRow.AXPosition.y - 15 then
        return Callback.Clickable(row, { row.AXSize.w / 2, 0 })
      end
    end
    return false
  end
end

--- ### Yuanbao
local Yuanbao = {}
Yuanbao.WF = {}
Yuanbao.WF.Main = {}
Evt.OnRunning("com.tencent.yuanbao", function(app)
  local title
  title = appVer(app) < "2.48" and "Tencent Yuanbao" or "Yuanbao"
  title = T(title, app)
  Yuanbao.WF.Main.allowTitles = '^' .. title .. '$'
end)

--- ### EuDic
local EuDic = {}
EuDic.WF = {}
EuDic.WF.Main = { allowRoles = AX.StandardWindow }
Evt.OnRunning("com.eusoft.freeeudic", function(app)
  local title = T("欧路词典", app)
  EuDic.WF.Main.allowTitles = '^' .. title .. '$'
end)

--- ### Parallels Desktop
local Parallels = {}
Parallels.WF = {}
Parallels.WF.ControlCenter = {}
Evt.OnRunning("com.parallels.desktop.console", function(app)
  local title = T("Control Center", app)
  Parallels.WF.ControlCenter.allowTitles = '^' .. title .. '$'
end)

--- ### Barrier
local Barrier = {}
Barrier.localizedMessage = function(message, params)
  return function(app)
    local str = T(message, app, params)
    assert(type(str) == 'string')
    if message:find('&') then
      str = str:gsub("%(&%a%)", ""):gsub('&', '')
    end
    if message:sub(#message) == ':' then
      local len = utf8.len(str)
      if len then
        local lastChar = str:sub(utf8.offset(str, len))
        if lastChar == ':' or lastChar == '：' then
          str = str:sub(1, utf8.offset(str, len) - 1)
        end
      end
    end
    return str
  end
end

Barrier.localizedString = function(message, app, params)
  local str = T(message, app, params)
  assert(type(str) == 'string')
  if message:find('&') then
    str = str:gsub('&', "")
  end
  return str
end

-- ### Bartender
local Bartender = {}
Bartender.WF = {}
Bartender.WF.Bar = { allowTitles = "^Bartender Bar$" }
Bartender.barItemTitle = function(index, rightClick)
  return function(win)
    local itemNames, _ = A_WinBuf:get("itemNames", "itemIDs", function()
      local winUI = towinui(win)
      local icons = getc(winUI, AX.ScrollArea, 1, AX.List, 1, AX.List, 1)
      local appnames = tmap(getc(icons, AX.Group), function(g)
        return getc(g, AX.Image, 1).AXDescription
      end)
      if #appnames == 0 then return {}, {} end
      local app = win:application()

      local itemNames, itemIDs = {}, {}
      if appVer(app) < "6" or appVer(app) >= "6.1.1" then
        local appid = app:bundleID()
        local _, items = hs.osascript.applescript(strfmt([[
          tell application id "%s" to list menu bar items
        ]], appid))
        local itemList = strsplit(items, "\n")
        local splitterIndex = tindex(itemList, appid .. "-statusItem")
        local barSplitterIndex = tindex(appnames, app:name())
        if barSplitterIndex ~= nil then
          splitterIndex = splitterIndex - (#appnames - (barSplitterIndex - 1))
        end
        local missedItemCnt = 0
        if appVer(app) < "5.5" then
          local plistPath = hs.fs.pathToAbsolute(strfmt(
              "~/Library/Preferences/%s.plist", appid))
          if plistPath ~= nil then
            local plist = hs.plist.read(plistPath)
            local allwaysHidden = get(plist, "ProfileSettings",
                "activeProfile", "AlwaysHide")
            local itemIDIdx = splitterIndex + #appnames
            while tcontain(allwaysHidden, itemList[itemIDIdx])
                and itemIDIdx > splitterIndex do
              itemIDIdx = itemIDIdx - 1
            end
            missedItemCnt = #appnames - (itemIDIdx - splitterIndex)
          end
        end
        if missedItemCnt == 0 then
          for i = 1, #appnames do
            local appname = appnames[i]
            local itemID
            if appVer(app) < "5.5" then
              itemID = itemList[splitterIndex + 1 + #appnames - i]
            else
              itemID = itemList[splitterIndex - 1 - #appnames + i]
            end
            local id, idx = itemID:match("(.-)%-Item%-(%d+)$")
            if id ~= nil then
              if idx == "0" then
                tinsert(itemNames, appname)
              else
                tinsert(itemNames, strfmt("%s (Item %s)", appname, idx))
              end
              tinsert(itemIDs, itemID)
            else
              local appByName = find(appname)
              if appByName == nil or
                  appByName:bundleID() ~= itemID:sub(1, #appByName:bundleID()) then
                tinsert(itemNames, appname)
                tinsert(itemIDs, itemID)
              elseif appByName ~= nil then
                local itemShortName = itemID:sub(#appByName:bundleID() + 2)
                tinsert(itemNames, strfmt("%s (%s)", appname, itemShortName))
                tinsert(itemIDs, itemID)
              end
            end
          end
        else
          for i = 1, #appnames do
            tinsert(itemNames, appnames[i])
            tinsert(itemIDs, i)
          end
        end
      elseif #appnames > 0 then
        local alwaysHiddenBar = false
        for _, appname in ipairs(appnames) do
          local hint = appname
          if hint == "Passwords" then
            hint = "com.apple.Passwords.MenuBarExtra"
          end
          local app = find(hint, true)
          if app then
            local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
            local iconAlwaysHiddenPosition = -7000
            local alWaysHiddenMenuBarItems = tifilter(menuBarItems, function(item)
              return item.AXPosition.x < iconAlwaysHiddenPosition
            end)
            if #alWaysHiddenMenuBarItems == #menuBarItems then
              alwaysHiddenBar = true
              break
            end
          end
        end
        for i, appname in ipairs(appnames) do
          local msg = appname
          local hint = appname
          if hint == "Passwords" then
            hint = "com.apple.Passwords.MenuBarExtra"
          end
          local app = find(hint, true)
          if app then
            msg = app:name()
            local indicesForHidden = {}
            for j, name in ipairs(appnames) do
              if name == appname then
                tinsert(indicesForHidden, j)
              end
            end
            local thisIndex = tindex(indicesForHidden, i)
            local map = loadStatusItemsAutosaveName(app)
            if map then
              local iconAlwaysHiddenPosition = -7000
              local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
              if not alwaysHiddenBar then
                local alWaysHiddenMenuBarItems = tifilter(menuBarItems, function(item)
                  return item.AXPosition.x < iconAlwaysHiddenPosition
                end)
                thisIndex = thisIndex + #alWaysHiddenMenuBarItems
              end
              local autosaveName = map[thisIndex]
              if not (autosaveName == "Item-0" and #menuBarItems == 1) then
                msg = msg..'-'..autosaveName
              end
            end
            tinsert(itemNames, msg)
            tinsert(itemIDs, i)
          end
        end
      end
      return itemNames, itemIDs
    end)
    if index <= #itemNames then
      return (rightClick and "Right-click " or "Click ") .. itemNames[index]
    end
  end
end

Bartender.clickBarItem = function(index, rightClick)
  return function(win)
    local appid = win:application():bundleID()
    local itemID = A_WinBuf.itemIDs[index]
    if type(itemID) == 'string' then
      local script = strfmt('tell application id "%s" to activate "%s"',
          appid, A_WinBuf.itemIDs[index])
      if rightClick then
        script = script .. " with right click"
      end
      hs.osascript.applescript(script)
      hs.timer.doAfter(0.1, function()
        hs.osascript.applescript(strfmt([[
          tell application id "%s" to toggle bartender
        ]], appid))
      end)
    else
      local winUI = towinui(find(appid):focusedWindow())
      local icon = getc(winUI, AX.ScrollArea, 1, AX.List, 1,
          AX.List, 1, AX.Group, itemID, AX.Image, 1)
      if icon ~= nil then
        local fn = rightClick and rightClickAndRestore or leftClickAndRestore
        fn(icon, win)
      end
    end
  end
end

Bartender.WF.Main = {}
Evt.OnRunning("com.surteesstudios.Bartender", function(app)
  if appVer(app) < "6" then
    Bartender.WF.Main.allowTitles = app:name()
  else
    Bartender.WF.Main.fn = function(win)
      return getc(towinui(win), AX.Group, 1, AX.SplitGroup, 1,
          AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1) ~= nil
    end
  end
end)

Bartender.sidebarItemTitle = function(index)
  return function(win)
    local winUI = towinui(win)
    if appVer(win) < "6" then
      local rows = A_WinBuf:get("sidebarRows", function()
        return getc(winUI, AX.SplitGroup, 1, AX.ScrollArea, 1,
            AX.Outline, 1, AX.Row) or {}
      end)
      local row = getc(rows[index], AX.Cell, 1, AX.StaticText, 1)
      if row ~= nil then
        return row.AXValue
      end
    else
      local rows = A_WinBuf:get("sidebarRows", function()
        return getc(winUI, AX.Group, 1, AX.SplitGroup, 1,
            AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1, AX.Row) or {}
      end)
      local row = getc(rows[index], AX.Cell, 1, AX.Unknown, 1)
      if row ~= nil then
        return row.AXAttributedDescription:getString()
      end
    end
  end
end

Bartender.clickSidebarItem = function(index)
  return function()
    local row = A_WinBuf.sidebarRows[index]
    if row then row.AXSelected = true end
  end
end

-- ### Barbee
local Barbee = {}
Barbee.WF = {}
Barbee.WF.Bar = {
  allowRoles = AX.SystemDialog,
  allowTitles = "^$",
  fn = function(win)
    local winUI = towinui(win)
    if #winUI == 1 and winUI[1].AXRole == AX.Group
        and #winUI[1] == #(getc(winUI[1], AX.Button) or {}) then
      return true
    end
    return false
  end
}
Barbee.barItemTitle = function(index)
  return function(win)
    local itemNames = A_WinBuf:get("itemNames", function()
      local winUI = towinui(win)
      local buttons = getc(winUI, AX.Group, 1, AX.Button)
      return tmap(buttons, function(bt)
        return bt.AXHelp
      end)
    end)
    if index <= #itemNames then
      return "Click " .. itemNames[#itemNames + 1 - index]
    end
  end
end

Barbee.clickBarItem = function(index)
  return function(win)
    local button = getc(towinui(win), AX.Group, 1, AX.Button, -index)
    if button then Callback.Press(button) end
  end
end

-- ### Ice
local Ice = {}
Ice.WF = {}
Ice.WF.Bar = { allowTitles = "^Ice Bar$" }
Ice.barItemTitle = function(index)
  return function(win)
    local itemNames = A_WinBuf:get("itemNames", function()
      local winUI = towinui(win)
      local itemNames = {}
      local buttons = getc(winUI, AX.Group, 1,
          AX.ScrollArea, 1, AX.Image) or {}
      local alwaysHiddenBar = false
      for _, button in ipairs(buttons) do
        local appname = button.AXAttributedDescription:getString()
        local hint = appname
        if hint == "Passwords" then
          hint = "com.apple.Passwords.MenuBarExtra"
        end
        local app = find(hint, true)
        if app then
          local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
          local alWaysHiddenMenuBarItems = {}
          local iconAlwaysHidden = getc(toappui(win:application()),
              AX.MenuBar, -1, AX.MenuBarItem, 3)
          if iconAlwaysHidden then
            alWaysHiddenMenuBarItems = tifilter(menuBarItems, function(item)
              return item.AXPosition.x < iconAlwaysHidden.AXPosition.x
            end)
          end
          if #alWaysHiddenMenuBarItems == #menuBarItems then
            alwaysHiddenBar = true
            break
          end
        end
      end
      for i, button in ipairs(buttons) do
        local appname = button.AXAttributedDescription:getString()
        local hint = appname
        if hint == "Passwords" then
          hint = "com.apple.Passwords.MenuBarExtra"
        end
        local msg = appname
        local app = find(hint, true)
        if app then
          msg = app:name()
          local indicesForHidden = {}
          for j, bt in ipairs(buttons) do
            if bt.AXAttributedDescription:getString() == appname then
              tinsert(indicesForHidden, j)
            end
          end
          local thisIndex = tindex(indicesForHidden, i)
          local map = loadStatusItemsAutosaveName(app)
          if map then
            local iconAlwaysHidden = getc(toappui(win:application()),
                AX.MenuBar, -1, AX.MenuBarItem, 3)
            local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
            if iconAlwaysHidden and not alwaysHiddenBar then
              local alWaysHiddenMenuBarItems = tifilter(menuBarItems, function(item)
                return item.AXPosition.x < iconAlwaysHidden.AXPosition.x
              end)
              thisIndex = thisIndex + #alWaysHiddenMenuBarItems
            end
            local autosaveName = map[thisIndex]
            if not (autosaveName == "Item-0" and #menuBarItems == 1) then
              msg = msg..'-'..autosaveName
            end
          end
        end
        tinsert(itemNames, msg)
      end
      return itemNames
    end)
    return itemNames[index]
  end
end

Ice.clickBarItem = function(index)
  return function(win)
    local button = getc(towinui(win), AX.Group, 1,
        AX.ScrollArea, 1, AX.Image, index)
    if button then
      leftClickAndRestore(button, win, 0.1)
    end
  end
end

Ice.WF.Main = {
  fn = function(win)
    return towinui(win).AXIdentifier == "SettingsWindow"
  end
}
Ice.sidebarItemTitle = function(index)
  return function(win)
    local rows = A_WinBuf:get("sidebarRows", function()
      local rows = getc(towinui(win), AX.Group, 1, AX.SplitGroup, 1,
          AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1, AX.Row) or {}
      tremove(rows, 1)
      return rows
    end)
    local row = getc(rows[index], AX.Cell, 1, AX.StaticText, 1)
    if row ~= nil then
      return row.AXValue
    end
  end
end

Ice.clickSidebarItem = function(index)
  return function()
    local row = A_WinBuf.sidebarRows[index]
    if row then row.AXSelected = true end
  end
end

-- ### iBar
local iBar = {}
iBar.WF = {}
iBar.WF.Bar = {
  allowRoles = AX.SystemFloatingWindow,
  allowTitles = "^iBarmenu$"
}
iBar.barItemTitle = function(index)
  return function(win)
    local buttons = getc(towinui(win), AX.Button)
    if buttons and #buttons >= index then
      local ident = buttons[index].AXIdentifier
      local items = strsplit(ident, '/')
      local info = items[#items]
      items = strsplit(info, ' >>> ')
      local itemIdx, appid = items[1], items[2]
      local msg = find(appid):name()
      if itemIdx ~= "Item-0" then
        msg = msg .. ' (' .. itemIdx .. ')'
      end
      return "Click " .. msg
    end
  end
end

iBar.clickBarItem = function(index)
  return function(win)
    local button = getc(towinui(win), AX.Button, index)
    if button then
      Callback.Press(button)
    end
  end
end

-- ### PasswordsMenuBarExtra
local PasswordsMenuBarExtra = {}
PasswordsMenuBarExtra.WF = {
  allowRoles = AX.SystemDialog,
  allowTitles = "^$"
}

PasswordsMenuBarExtra.recordPosition = function(index)
  return function(win)
    local winUI = towinui(win)
    local searchField = getc(winUI, AX.Group, 1, AX.TextField, 1)
    if searchField ~= nil then
      local row
      if OS_VERSION >= OS.Tahoe then
        row = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
            AX.ScrollArea, 1, AX.Outline, 1, AX.Row, index)
      else
        row = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
            AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1, AX.Row, index)
      end
      return Callback.Clickable(row)
    end
    return false
  end
end

PasswordsMenuBarExtra.recordField = function(fieldTitle)
  return function(win)
    local winUI = towinui(win)

    if OS_VERSION >= OS.Tahoe:withMinor(1) then
      local fieldValues = getc(winUI, AX.Group, 1,
          AX.ScrollArea, 1, AX.Group, 1, AX.StaticText)
      if fieldValues == nil then return false end
      local title = T(fieldTitle, win)
      for i=1,#fieldValues,2 do
        local titleElem = fieldValues[i]
        if titleElem.AXValue == title then
          return Callback.Clickable(fieldValues[i + 1])
        end
      end
      return false
    end

    local outline
    if OS_VERSION >= OS.Tahoe then
      outline = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
          AX.ScrollArea, 1, AX.Outline, 1)
    else
      outline = getc(winUI, AX.Group, 1, AX.ScrollArea, 1,
          AX.Group, 1, AX.ScrollArea, 1, AX.Outline, 1)
    end
    if outline == nil then return false end
    local title = T(fieldTitle, win)
    for _, row in ipairs(getc(outline, AX.Row)) do
      local cell = getc(row, AX.Cell, 1)
      local titleElem = getc(cell, AX.StaticText, 1)
      if titleElem and titleElem.AXValue == title then
        return Callback.Clickable(getc(cell, AX.StaticText, 2))
      end
    end
    return false
  end
end

-- ### iCopy
local iCopy = {}

iCopy.selectHotkeyRemap = function(idx)
  return function(win)
    local iCopyMod = appVer(win) < "1.1.1" and "" or "⌃"
    hs.eventtap.keyStroke(iCopyMod, tostring(idx), nil, win:application())
  end
end

iCopy.WF = {}
iCopy.WF.Main = {
  allowRegions = {
    hs.geometry.rect(
        0, hs.screen.mainScreen():fullFrame().y
           + hs.screen.mainScreen():fullFrame().h - 400,
        hs.screen.mainScreen():fullFrame().w, 400)
  }
}

-- ### browsers
local Web = {}

local function getTabSource(app)
  local ok, source
  if app:bundleID() == "com.apple.Safari" then
    ok, source = hs.osascript.applescript([[
      tell application id "com.apple.Safari"
        do JavaScript "document.body.innerHTML" in front document
      end tell
    ]])
  else  -- assume chromium-based browsers
    ok, source = hs.osascript.applescript(strfmt([[
      tell application id "%s"
        execute active tab of front window ¬
            javascript "document.documentElement.outerHTML"
      end tell
    ]], app:bundleID()))
  end
  if ok then return source end
end

local function setTabUrl(app, url)
  if app:bundleID() == "com.apple.Safari" then
    hs.osascript.applescript(strfmt([[
      tell application id "com.apple.Safari"
        set URL of front document to "%s"
      end tell
    ]], url))
  else  -- assume chromium-based browsers
    hs.osascript.applescript(strfmt([[
      tell application id "%s"
        set URL of active tab of front window to "%s"
      end tell
    ]], app:bundleID(), url))
  end
end

Web.Weibo = {}
Web.Weibo.sideBarTitle = function(idx, isCommon)
  return function(win)
    if isCommon and A_WinBuf.sideBarCommonGroupTitles then
      return A_WinBuf.sideBarCommonGroupTitles[idx]
    elseif not isCommon and A_WinBuf.sideBarCustomGroupTitles then
      return A_WinBuf.sideBarCustomGroupTitles[idx]
    end
    local sideBarTitles, sideBarURLs = {}, {}
    local app = win:application()
    local source = getTabSource(app)
    if source == nil then return end
    local start, stop
    if isCommon then
      local header = [[<h2 class="[^>]-_title_[^>]-">首页</h2>]]
      local tailer = [[<div class="[^>]-woo%-divider%-[^>]-">]]
      _, start = source:find(header)
      if start == nil then
        hs.timer.usleep(1 * 1000000)
        source = getTabSource(app)
        if source == nil then return end
        _, start = source:find(header)
      end
      if start == nil then return end
      stop = source:find(tailer, start + 1) or source:len()
    else
      local header = [[<h3 class="[^>]-_title_[^>]-">自定义分组</h3>]]
      local tailers = {
        [[<span class="[^>]-">展开</span></span></button>]],
        [[<span class="[^>]-">收起</span></span></button>]]
      }
      _, start = source:find(header)
      if start == nil then
        hs.timer.usleep(1 * 1000000)
        source = getTabSource(app)
        if source == nil then return end
        _, start = source:find(header)
      end
      if start == nil then return end
      stop = source:find(tailers[1], start + 1) or
          source:find(tailers[2], start + 1) or source:len()
    end
    source = source:sub(start + 1, stop - 1)
    if isCommon then
      local url, title = source:match(
          [[<a href="/(.-)"[^>]-><div role="link" title="(.-)"]])
      tinsert(sideBarTitles, title)
      tinsert(sideBarURLs, url)
    end
    for url, title in source:gmatch(
        [[<a href="/(mygroups.-)"[^>]-><div role="link" title="(.-)"]]) do
      tinsert(sideBarTitles, title)
      tinsert(sideBarURLs, url)
    end
    if isCommon then
      A_WinBuf.sideBarCommonGroupTitles = sideBarTitles
      A_WinBuf.sideBarCommonGroupURLs = sideBarURLs
    else
      A_WinBuf.sideBarCustomGroupTitles = sideBarTitles
      A_WinBuf.sideBarCustomGroupURLs = sideBarURLs
    end
    return sideBarTitles[idx]
  end
end

Web.Weibo.navigateToSideBarCondition = function(idx, isCommon)
  return function()
    if isCommon and A_WinBuf.sideBarCommonGroupURLs
        and #A_WinBuf.sideBarCommonGroupURLs >= idx then
      return true, A_WinBuf.sideBarCommonGroupURLs[idx]
    elseif not isCommon and A_WinBuf.sideBarCustomGroupURLs
        and #A_WinBuf.sideBarCustomGroupURLs >= idx then
      return true, A_WinBuf.sideBarCustomGroupURLs[idx]
    end
    return false
  end
end

Web.Weibo.navigateToSideBar = function(url, result, win)
  local schemeEnd = url:find("//")
  local domainEnd = url:find("/", schemeEnd + 2)
  local fullUrl = url:sub(1, domainEnd) .. result
  setTabUrl(win:application(), fullUrl)
end

Web.Douyin = {}
Web.Douyin.tabTitle = function(idx)
  return function(win)
    local tabTitles, _ = A_WinBuf:get("tabTitles", "tabURLs", function()
      local tabTitles, tabURLs = {}, {}
      local app = win:application()
      local source = getTabSource(app)
      if source then
        local lastURL = ""
        for url, title in source:gmatch(
            [[<div class="tab\-[^>]-><a href="(.-)".-<span class=".-">(.-)</span>]]) do
          if url ~= lastURL then
            tinsert(tabTitles, title)
            tinsert(tabURLs, url)
          end
          lastURL = url
        end
      end
      return tabTitles, tabURLs
    end)
    return tabTitles[idx]
  end
end

Web.Douyin.navigateToTabCondition = function(idx)
  return function()
    if A_WinBuf.tabURLs and #A_WinBuf.tabURLs >= idx then
      return true, A_WinBuf.tabURLs[idx]
    end
    return false
  end
end

Web.Douyin.navigateToTab = function(url, result, win)
  local fullUrl
  if result:sub(1, 2) == '//' then
    local schemeEnd = url:find("//")
    fullUrl = url:sub(1, schemeEnd - 1) .. result
  else
    fullUrl = result
  end
  setTabUrl(win:application(), fullUrl)
end

-- ## functin utilities for hotkey configs

-- Fetch menu item title as a hotkey message by key binding.
--
-- This helper is mainly used to:
--   - Derive user-facing hotkey descriptions from menu key bindings
--   - Keep displayed messages consistent with the application's menu
MenuItem = {}
-- fetch title of menu item as hotkey message by key binding
MenuItem.message = function(mods, key, titleIndex, menuBarItemTitle)
  return function(app)
    if type(titleIndex) == 'string' then
      menuBarItemTitle = titleIndex
      titleIndex = nil
    end
    local menuItem = findMenuItemByKeyBinding(app, mods, key, menuBarItemTitle)
    if menuItem == nil then return end
    if type(titleIndex) == 'number' then
      return menuItem[titleIndex]
    elseif type(titleIndex) == 'table' then
      local str = menuItem[titleIndex[1]]
      for i=2,#titleIndex do
        str = str .. ' > ' .. menuItem[titleIndex[i]]
      end
    else
      local str = menuItem[2]
      for i=3,#menuItem do
        str = str .. ' > ' .. menuItem[i]
      end
      return str
    end
  end
end

-- Check whether a specified menu item path is currently enabled.
--
-- This function is commonly used as a hotkey condition:
--   - It tests menu availability at runtime
--   - It does NOT trigger the menu item
--
-- If an enabled menu item is found:
--   returns true, localizedMenuPath
-- Otherwise:
--   returns false
MenuItem.isEnabled = function(menuItemTitle, params, ...)
  local args = { menuItemTitle, params, ... }
  params = nil
  if #args > 0 and (type(args[#args]) == 'string' or #args[#args] == 0) then
    params = args[#args]
    args[#args] = nil
  end
  return function(app)
    if app.application then app = app:application() end
    for _, title in ipairs(args) do
      local menuItem, locTitle = findMenuItem(app, title, params)
      if Callback.Enabled(menuItem) then
        return true, locTitle
      end
    end
    return false
  end
end

-- possible reasons for failure of hotkey condition-- Possible reasons for hotkey condition failure.
--
CF = {
  noMenuItemMatchKeybinding = 0,
  uIElementNotFocused       = 1,
  rightMenubarItemSelected  = 2,
  leftMenubarItemSelected   = 3,
  nonEmptyTextFieldFocused  = 4,
  userConditionFail         = 5,
}

-- Check whether a menu item associated with a specific key binding
-- is currently enabled.
--
-- This differs from MenuItem.isEnabled in that:
--   - The menu item is identified by its key binding
--   - The check is closer to the actual shortcut behavior
MenuItem.keybindingEnabled = function(mods, key, menuBarItemTitle)
  return function(app)
    local menuItem, enabled = findMenuItemByKeyBinding(app, mods, key, menuBarItemTitle)
    if menuItem ~= nil and enabled then
      return true, menuItem
    else
      return false, CF.noMenuItemMatchKeybinding
    end
  end
end

-- Select a menu item path returned by a hotkey condition.
--
-- This function is designed to be used directly as a hotkey callback.
-- It ensures:
--   - The correct menu bar item is activated if necessary
--   - The final menu item is selected reliably
--
-- The input menuItemTitle must be a valid menu path,
-- typically returned by MenuItem.isEnabled or MenuItem.keybindingEnabled.
Callback.Select = function(menuItemTitle, app)
  if app.application then app = app:application() end
  if #menuItemTitle == 0 then
    app:selectMenuItem(menuItemTitle)
    return
  end
  local menuBarItem = getc(toappui(app), AX.MenuBar, 1,
      AX.MenuBarItem, menuItemTitle[1])
  local menuItem = menuBarItem
  for i=2,#menuItemTitle do
    menuItem = getc(menuItem, AX.Menu, 1, AX.MenuItem, menuItemTitle[i])
  end
  if #menuItem ~= 0 and menuBarItem.AXSelected == false then
    app:selectMenuItem{ menuItemTitle[1] }
  end
  app:selectMenuItem(menuItemTitle)
end


-- ## hotkey configs for apps

-- hotkey configs that cound be used in various application
specialCommonHotkeyConfigs = {
  ["closeWindow"] = {
    mods = "⌘", key = "W",
    message = TC("Close Window"),
    condition = function(app)
      local win = app:focusedWindow()
      return win ~= nil and win:role() == AX.Window, win
    end,
    repeatable = true,
    fn = function(win) win:close() end
  },
  ["minimize"] = {
    mods = "⌘", key = "M",
    message = TC("Minimize"),
    condition = function(app)
      local win = app:focusedWindow()
      return win ~= nil and win:role() == AX.Window, win
    end,
    repeatable = true,
    fn = function(win) win:minimize() end
  },
  ["hide"] = {
    mods = "⌘", key = "H",
    message = TC("Hide"),
    fn = function(app) app:hide() end
  },
  ["quit"] = {
    mods = "⌘", key = "Q",
    message = TC("Quit"),
    fn = function(app) app:kill() end
  },
  ["showPrevTab"] = {
    mods = "⇧⌘", key = "[",
    message = MenuItem.message('⇧⌃', "⇥"),
    condition = MenuItem.keybindingEnabled('⇧⌃', "⇥"),
    repeatable = true,
    fn = Callback.Select
  },
  ["showNextTab"] = {
    mods = "⇧⌘", key = "]",
    message = MenuItem.message('⌃', "⇥"),
    condition = MenuItem.keybindingEnabled('⌃', "⇥"),
    repeatable = true,
    fn = Callback.Select
  },
}

local function specialCommonHotkeyConfigUpdated(hkID, newConfig)
  local config = tcopy(specialCommonHotkeyConfigs[hkID])
  for k, v in pairs(newConfig) do
    config[k] = v
  end
  return config
end

AppHotKeyCallbacks = {
  ["com.apple.finder"] =
  {
    ["openRecent"] = {
      message = T("Recent Folders"),
      condition = MenuItem.isEnabled{ "Go", "Recent Folders" },
      fn = Callback.Select
    },
    ["open1stSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open1stSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open1stSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(1),
      windowFilter = true,
      condition = Finder.getSidebarItem(1),
      fn = Finder.openSidebarItem
    },
    ["open2ndSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open2ndSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open2ndSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(2),
      windowFilter = true,
      condition = Finder.getSidebarItem(2),
      fn = Finder.openSidebarItem
    },
    ["open3rdSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open3rdSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open3rdSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(3),
      windowFilter = true,
      condition = Finder.getSidebarItem(3),
      fn = Finder.openSidebarItem
    },
    ["open4thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open4thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open4thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(4),
      windowFilter = true,
      condition = Finder.getSidebarItem(4),
      fn = Finder.openSidebarItem
    },
    ["open5thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open5thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open5thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(5),
      windowFilter = true,
      condition = Finder.getSidebarItem(5),
      fn = Finder.openSidebarItem
    },
    ["open6thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open6thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open6thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(6),
      windowFilter = true,
      condition = Finder.getSidebarItem(6),
      fn = Finder.openSidebarItem
    },
    ["open7thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open7thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open7thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(7),
      windowFilter = true,
      condition = Finder.getSidebarItem(7),
      fn = Finder.openSidebarItem
    },
    ["open8thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open8thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open8thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(8),
      windowFilter = true,
      condition = Finder.getSidebarItem(8),
      fn = Finder.openSidebarItem
    },
    ["open9thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open9thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open9thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(9),
      windowFilter = true,
      condition = Finder.getSidebarItem(9),
      fn = Finder.openSidebarItem
    },
    ["open10thSidebarItem"] = {
      mods = get(KeybindingConfigs.hotkeys.shared,
                 "open10thSidebarItemOnOpenSavePanel", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared,
                "open10thSidebarItemOnOpenSavePanel", "key"),
      message = Finder.sidebarItemTitle(10),
      windowFilter = true,
      condition = Finder.getSidebarItem(10),
      fn = Finder.openSidebarItem
    }
  },

  ["com.apple.ActivityMonitor"] =
  {
    ["search"] = {
      message = TC("Search"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUI = towinui(app:focusedWindow())
        local searchField = getc(winUI, AX.Toolbar, 1, AX.Group, 2, AX.TextField, 1)
        return Callback.Clickable(searchField, { 10, 2 })
      end,
      fn = Callback.Click
    }
  },

  ["com.apple.MobileSMS"] =
  {
    ["deleteConversation"] = {
      message = T("Delete Conversation…"),
      condition = function(app)
        local messageItems = Messages.messageItems(app)
        local desc = T('New Message', app)
        return tfind(messageItems or {}, function(msg)
          return msg.AXSelected == true and msg.AXDescription:sub(4) ~= desc
        end) ~= nil
      end,
      fn = function(app)
        local appUI = toappui(app)
        local button
        if OS_VERSION >= OS.Tahoe:withMinor(2) then
          button = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 1, AX.Button, 2)
        elseif OS_VERSION >= OS.Tahoe then
          button = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
              AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Button, 2)
        else
          button = getc(appUI, AX.Window, 1, AX.Group, 1, AX.Group, 1,
              AX.Group, 2, AX.Group, 1, AX.Button, 2)
        end
        if button then
          Callback.Press(button)
        else
          local _, menuItem = findMenuItem(app, {
            OS_VERSION < OS.Ventura and "File" or "Conversation",
            "Delete Conversation…"
          })
          app:selectMenuItem(menuItem)
        end
      end
    },
    ["deleteAllConversations"] = {
      message = T("Delete All"),
      condition = Messages.deletable,
      fn = Messages.deleteAll
    },
    ["goToPreviousConversation"] = {
      message = MenuItem.message('⇧⌃', "⇥", "Window"),
      condition = function(app)
        local messageItems = Messages.messageItems(app)
        local desc = T('New Message', app)
        if messageItems == nil or #messageItems == 0
            or (#messageItems == 1 and (messageItems[1].AXDescription == nil
              or messageItems[1].AXDescription:sub(4) == desc)
              or messageItems[1].AXValue ~= nil) then
          return false
        end
        if #messageItems == 1 and messageItems[1].AXSelected then
          return false
        end
        for i=1,#messageItems do
          if messageItems[i].AXSelected then
            local prevIdx = i == 1 and #messageItems or (i - 1)
            return true, messageItems[prevIdx]
          end
        end
        return true, messageItems[#messageItems]
      end,
      repeatable = true,
      fn = Callback.Press
    },
    ["goToNextConversation"] = {
      message = MenuItem.message('⌃', "⇥", "Window"),
      condition = function(app)
        local messageItems = Messages.messageItems(app)
        local desc = T('New Message', app)
        if messageItems == nil or #messageItems == 0
            or (#messageItems == 1 and (messageItems[1].AXDescription == nil
              or messageItems[1].AXDescription:sub(4) == desc)
              or messageItems[1].AXValue ~= nil) then
          return false
        end
        if #messageItems == 1 and messageItems[1].AXSelected then
          return false
        end
        for i=1,#messageItems do
          if messageItems[i].AXSelected then
            local nextIdx = i == #messageItems and 1 or (i + 1)
            return true, messageItems[nextIdx]
          end
        end
        return true, messageItems[1]
      end,
      repeatable = true,
      fn = Callback.Press
    }
  },

  ["com.apple.mobilephone"] = {
    ["removeFromRecents"] = {
      message = T("Remove from Recents"),
      windowFilter = Phone.WF.Main,
      condition = Phone.hoveringOverCall,
      fn = FaceTime.deleteMousePositionCall
    },
    ["removeAllRecents"] = {
      message = T("Remove All Recents"),
      windowFilter = Phone.WF.Main,
      condition = Phone.hasCall,
      fn = Phone.deleteAll
    },
    ["newCall"] = {
      message = T("New Call"),
      windowFilter = Phone.WF.Main,
      fn = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 3, AX.Group, 1, AX.Button, 1)
        if button then Callback.Press(button) end
      end
    },
    ["view1"] = {
      message = T("Calls"),
      windowFilter = Phone.WF.Main,
      fn = Phone.selectView(1)
    },
    ["view2"] = {
      message = T("Missed"),
      windowFilter = Phone.WF.Main,
      fn = Phone.selectView(2)
    },
    ["view3"] = {
      message = T("Voicemail"),
      windowFilter = Phone.WF.Main,
      fn = Phone.selectView(3)
    }
  },

  ["com.apple.FaceTime"] = {
    ["removeFromRecents"] = {
      message = T("Remove from Recents"),
      windowFilter = FaceTime.WF.Main,
      condition = FaceTime.hoveringOverCall,
      fn = FaceTime.deleteMousePositionCall
    },
    ["removeAllRecents"] = {
      message = T("Remove All Recents"),
      windowFilter = FaceTime.WF.Main,
      condition = FaceTime.hasCall,
      fn = FaceTime.deleteAll
    },
    ["newFaceTime"] = {
      message = T("New FaceTime"),
      windowFilter = FaceTime.WF.Main,
      condition = function(win)
        local button
        if OS_VERSION < OS.Tahoe then
          button = getc(towinui(win), AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 1, AX.Button, 2)
        elseif OS_VERSION < OS.Tahoe:withMinor(2) then
          button = getc(towinui(win), AX.Group, 1, AX.Group, 1,
              AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.Group, 1,
              AX.Button, 2)
        else
          button = getc(towinui(win), AX.Group, 1, AX.Group, 1,
              AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Button, 2)
        end
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["addPeopleWhenNewFaceTime"] = {
      message = T("Add People"),
      windowFilter = {
        allowSheet = true,
        fn = function(win)
          local heading = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.Group, 1, AX.Heading, 1)
          return heading and heading.AXDescription == T("New FaceTime", win)
        end,
      },
      fn = function(win)
        local button = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.Group, 2, AX.Group, 1, AX.Group, 1, AX.Button, 1)
        if button then Callback.Press(button) end
      end
    },
    ["view1"] = {
      message = T("Calls"),
      enabled = OS_VERSION >= OS.Tahoe,
      windowFilter = FaceTime.WF.Main,
      fn = FaceTime.selectView(1)
    },
    ["view2"] = {
      message = T("Missed"),
      enabled = OS_VERSION >= OS.Tahoe,
      windowFilter = FaceTime.WF.Main,
      fn = FaceTime.selectView(2)
    },
    ["view3"] = {
      message = T("Video"),
      enabled = OS_VERSION >= OS.Tahoe,
      windowFilter = FaceTime.WF.Main,
      fn = FaceTime.selectView(3)
    },
    ["view4"] = {
      message = T("Voicemail"),
      enabled = OS_VERSION >= OS.Tahoe,
      windowFilter = FaceTime.WF.Main,
      fn = FaceTime.selectView(4)
    },
    ["view5"] = {
      message = T("Spam"),
      enabled = OS_VERSION >= OS.Tahoe,
      windowFilter = FaceTime.WF.Main,
      fn = FaceTime.selectView(5)
    }
  },

  ["com.apple.Photos"] = {
    ["view1"] = {
      message = MenuItem.message('⌃', '1', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '1', 'View'),
      fn = Callback.Select
    },
    ["view2"] = {
      message = MenuItem.message('⌃', '2', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '2', 'View'),
      fn = Callback.Select
    },
    ["view3"] = {
      message = MenuItem.message('⌃', '3', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '3', 'View'),
      fn = Callback.Select
    },
    ["view4"] = {
      message = MenuItem.message('⌃', '4', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '4', 'View'),
      fn = Callback.Select
    },
    ["view5"] = {
      message = MenuItem.message('⌃', '5', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '5', 'View'),
      fn = Callback.Select
    },
    ["view6"] = {
      message = MenuItem.message('⌃', '6', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '6', 'View'),
      fn = Callback.Select
    },
    ["view7"] = {
      message = MenuItem.message('⌃', '7', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '7', 'View'),
      fn = Callback.Select
    },
    ["view8"] = {
      message = MenuItem.message('⌃', '8', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '8', 'View'),
      fn = Callback.Select
    },
    ["view9"] = {
      message = MenuItem.message('⌃', '9', 'View'),
      condition = MenuItem.keybindingEnabled('⌃', '9', 'View'),
      fn = Callback.Select
    }
  },

  ["com.apple.Notes"] = {
    ["toggleFolders"] = {
      message = T("Show Folders"),
      enabled = OS_VERSION < OS.Tahoe,
      condition = MenuItem.isEnabled({ "View", "Show Folders" },
                                     { "View", "Hide Folders" }),
      fn = Callback.Select
    }
  },

  ["com.apple.iCal"] =
  {
    ["toggleCalendarList"] = {
      message = T("Show Calendar List"),
      condition = MenuItem.isEnabled({ "View", "Show Calendar List" },
                                     { "View", "Hide Calendar List" }),
      fn = Callback.Select
    }
  },

  ["com.apple.helpviewer"] = {
    ["back"] = {
      message = TC("Back"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local toolbar = getc(towinui(app:focusedWindow()), AX.Toolbar, 1)
        local button
        if toolbar and toolbar[1].AXRole == AX.Button then
          button = getc(toolbar, AX.Group, 1, AX.Group, 1, AX.Button, 1)
        else
          button = getc(toolbar, AX.Group, 2, AX.Group, 1, AX.Button, 1)
        end
        return Callback.Enabled(button)
      end,
      fn = Callback.Press
    },
    ["forward"] = {
      message = TC("Forward"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local toolbar = getc(towinui(app:focusedWindow()), AX.Toolbar, 1)
        local button
        if toolbar and toolbar[1].AXRole == AX.Button then
          button = getc(toolbar, AX.Group, 1, AX.Group, 1, AX.Button, 2)
        else
          button = getc(toolbar, AX.Group, 2, AX.Group, 1, AX.Button, 2)
        end
        return Callback.Enabled(button)
      end,
      fn = Callback.Press
    },
    ["home"] = {
      message = TG("house"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local toolbar = getc(towinui(app:focusedWindow()), AX.Toolbar, 1)
        local buttons
        if OS_VERSION >= OS.Tahoe then
          if toolbar and toolbar[1].AXRole == AX.Button then
            buttons = getc(toolbar, AX.Group, 2, AX.Group, 1, AX.Button)
          else
            buttons = getc(toolbar, AX.Group, 3, AX.Group, 1, AX.Button)
          end
        else
          buttons = getc(toolbar, AX.Button)
        end
        local button = tfind(buttons or {}, function(bt)
          return bt.AXDescription == A_Message
        end)
        return Callback.Enabled(button)
      end,
      fn = Callback.Press
    }
  },

  ["com.apple.Music"] = {
    ["playCurrent"] = {
      message = T("Play"),
      windowFilter = Music.WF.Main,
      condition = function(win)
        local g = getc(towinui(win), AX.SplitGroup, 1,
            AX.ScrollArea, 2, AX.List, 1, AX.List, 1, AX.Unknown, 1)
            or getc(towinui(win), AX.SplitGroup, 1,
                AX.ScrollArea, 2, AX.Group, 1)
        local button = getc(g, AX.Button, A_Message)
            or getc(g, AX.Button, "Play")
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["view1"] = {
      message = Music.viewTitle(1),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(1)
    },
    ["view2"] = {
      message = Music.viewTitle(2),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(2)
    },
    ["view3"] = {
      message = Music.viewTitle(3),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(3)
    },
    ["view4"] = {
      message = Music.viewTitle(4),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(4)
    },
    ["view5"] = {
      message = Music.viewTitle(5),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(5)
    },
    ["view6"] = {
      message = Music.viewTitle(6),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(6)
    },
    ["view7"] = {
      message = Music.viewTitle(7),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(7)
    },
    ["view8"] = {
      message = Music.viewTitle(8),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(8)
    },
    ["view9"] = {
      message = Music.viewTitle(9),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(9)
    },
    ["view10"] = {
      message = Music.viewTitle(10),
      windowFilter = Music.WF.Main,
      fn = Music.selectView(10)
    }
  },

  ["com.apple.games"] = {
    ["back"] = {
      message = TC("Back"),
      windowFilter = Games.WF.Main,
      condition = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1, AX.Button)
        local button = tfind(buttons or {}, function(bt)
          return bt.AXDescription == A_Message
        end)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["view1"] = {
      message = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 1 then
          return buttons[1].AXDescription
        end
      end,
      windowFilter = Games.WF.Main,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 1 then
          Callback.Press(buttons[1])
        end
      end
    },
    ["view2"] = {
      message = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 2 then
          return buttons[2].AXDescription
        end
      end,
      windowFilter = Games.WF.Main,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 2 then
          Callback.Press(buttons[2])
        end
      end
    },
    ["view3"] = {
      message = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 3 then
          return buttons[3].AXDescription
        end
      end,
      windowFilter = Games.WF.Main,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        if buttons and #buttons >= 3 then
          Callback.Press(buttons[3])
        end
      end
    },
    ["search"] = {
      message = TC("Search"),
      windowFilter = Games.WF.Main,
      fn = function(win)
        local buttons = getc(towinui(win), AX.Toolbar, 1,
            AX.Group, 1, AX.RadioGroup, 1, AX.RadioButton)
        local button = tfind(buttons or {}, function(bt)
          return bt.AXDescription == A_Message
        end)
        if button then Callback.Press(button) end
      end
    }
  },

  ["com.apple.weather"] = {
    ["toggleSidebar"] = {
      message = TC("Show Sidebar"),
      enabled = OS_VERSION <= OS.Tahoe:withMinor(0),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local toolbar = getc(towinui(app:focusedWindow()), AX.Toolbar, 1)
        if OS_VERSION >= OS.Tahoe then
          if toolbar and #toolbar == 1 and toolbar[1].AXRole == AX.Button then
            return true, toolbar[1]
          end
        else
          if toolbar and #toolbar == 2 and toolbar[1].AXRole == AX.Button
              and toolbar[2].AXSubrole == AX.SearchField then
            return true, toolbar[1]
          end
        end
        return false
      end,
      fn = Callback.Press
    },
    ["previousLocation"] = {
      message = "Previous Location",
      condition = function(app)
        local list = Weather.getLocationList(app)
        if list and #list > 1 then
          local winTitle = app:focusedWindow():title()
          for i = 1, #list do
            local desc = list[i][1].AXDescription
            if (OS_VERSION < OS.Tahoe and list[i].AXSelected)
                or (desc:match('^'..winTitle..', ')
                    or desc:match('^'..winTitle..'、')) then
              return true, list[(i - 2) % #list + 1][1]
            end
          end
        end
        return false
      end,
      fn = Callback.Press
    },
    ["nextLocation"] = {
      message = "Next Location",
      condition = function(app)
        local list = Weather.getLocationList(app)
        if list and #list > 1 then
          local winTitle = app:focusedWindow():title()
          for i = 1, #list do
            local desc = list[i][1].AXDescription
            if (OS_VERSION < OS.Tahoe and list[i].AXSelected)
                or (desc:match('^'..winTitle..', ')
                    or desc:match('^'..winTitle..'、')) then
              return true, list[i % #list + 1][1]
            end
          end
        end
        return false
      end,
      fn = Callback.Press
    },
    ["deleteLocation"] = {
      message = T("Delete"),
      condition = function(app)
        local list = Weather.getLocationList(app)
        if list then
          local winTitle = app:focusedWindow():title()
          local selected = tfind(list, function(item)
            local desc = item[1].AXDescription
            return (OS_VERSION < OS.Tahoe and item.AXSelected)
                or (desc:match('^'..winTitle..', ')
                    or desc:match('^'..winTitle..'、'))
          end)
          return selected ~= nil, selected
        end
        return false
      end,
      fn = function(selected, app)
        selected:performAction(AX.ShowMenu)
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(toappui(app), uinotifications.menuOpened)
        observer:callback(A_HotkeyWrapper(function(obs, menu)
          local delete = getc(menu, AX.MenuItem, A_Message)
          if delete then
            Callback.Press(delete) obs:stop() obs = nil
          end
        end))
        observer:start()
        Evt.StopOnDeactivated(app, observer)
      end
    }
  },

  ["com.apple.AppStore"] =
  {
    ["back"] = {
      message = T("Back"),
      enabled = OS_VERSION < OS.Tahoe,
      condition = function(app)
        local menuItem, menuItemTitle = findMenuItem(app, { "Store", "Back" })
        if Callback.Enabled(menuItem) then
          return true, menuItemTitle
        else
          if app:focusedWindow() == nil then return false end
          local winUI = towinui(app:focusedWindow())
          local button
          button = getc(winUI, AX.SplitGroup, 1, AX.Group, 2, AX.Button, 1)
          if button ~= nil then return true, button end
          local g = getc(winUI, AX.Group, 1)
          if g == nil then return false end
          button = getc(g, AX.Button, "UIA.AppStore.NavigationBackButton")
              or getc(g, AX.Button, "AppStore.backButton")
          return button ~= nil, button
        end
      end,
      repeatable = true,
      fn = function(result, app)
        if type(result) == 'table' then
          app:selectMenuItem(result)
        else
          local button = result
          Callback.Press(button)
        end
      end
    }
  },

  ["com.apple.Safari"] =
  {
    ["toggleSidebar"] = {
      message = T("Show Sidebar"),
      condition = MenuItem.isEnabled({ "View", "Show Sidebar" },
                                     { "View", "Hide Sidebar" }),
      fn = Callback.Select
    },
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      windowFilter = { allowURLs = "^file://" },
      fn = function(url)
        hs.execute('open -R "' .. url .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    },
    ["openRecent"] = {
      message = T("Recently Closed"),
      condition = MenuItem.isEnabled{ "History", "Recently Closed" },
      fn = Callback.Select
    }
  },

  ["com.apple.Preview"] =
  {
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    }
  },

  ["com.google.Chrome"] =
  {
    ["openRecent"] = {
      message = T("Search Tabs…"),
      condition = MenuItem.isEnabled{ "Tab", "Search Tabs…" },
      fn = Callback.Select
    },
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      windowFilter = { allowURLs = "^file://" },
      fn = function(url)
        hs.execute('open -R "' .. url .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    }
  },

  ["com.microsoft.VSCode"] =
  {
    ["view:toggleOutline"] = {
      message = "View: Toggle Outline",
      windowFilter = VSCode.WF.Main,
      repeatable = true,
      fn = function(win)
        VSCode.toggleSideBarSection(win, "EXPLORER", "OUTLINE")
      end
    },
    ["view:toggleTimeline"] = {
      message = "View: Toggle Timeline",
      windowFilter = VSCode.WF.Main,
      repeatable = true,
      fn = function(win)
        VSCode.toggleSideBarSection(win, "EXPLORER", "TIMELINE")
      end
    },
    ["toggleSearchEditorWholeWord"] = {
      message = "Search Editor: Toggle Match Whole Word",
      windowFilter = VSCode.WF.Main,
      repeatable = true,
      fn = function(win) hs.eventtap.keyStroke("⌘⌥", "W", nil, win:application()) end
    },
    ["openRecent"] = {
      message = "Open Recent",
      condition = MenuItem.isEnabled({ "File", "Open Recent", "More…" },
                                     { "File", "Open Recent" }),
      fn = Callback.Select
    }
  },

  ["com.sublimetext.4"] =
  {
    ["toggleSearchEditorWholeWord"] = {
      message = "Search Editor: Toggle Match Whole Word",
      condition = function(app)
        if app:focusedWindow() == nil then
          return false
        else
          local winUI = towinui(app:focusedWindow())
          return winUI.AXIdentifier ~= "open-panel"
        end
      end,
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke("⌘⌥", "W", nil, app) end
    },
  },

  ["com.renfei.SnippetsLab"] =
  {
    ["showMainWindow"] = {
      message = T("Show Main Window"),
      condition = MenuItem.isEnabled{ "Window", "Show Main Window" },
      fn = Callback.Select
    },
    ["moveFocusToSidebar"] = {
      message = T("Move Focus to Sidebar"),
      condition = MenuItem.isEnabled{ "View", "Move Focus to Sidebar" },
      fn = Callback.Select
    },
    ["moveFocusToSnippetsList"] = {
      message = T("Move Focus to Snippets List"),
      condition = MenuItem.isEnabled{ "View", "Move Focus to Snippets List" },
      fn = Callback.Select
    },
    ["moveFocusToEditor"] = {
      message = T("Move Focus to Editor"),
      condition = MenuItem.isEnabled{ "View", "Move Focus to Editor" },
      fn = Callback.Select
    },
    ["moveFocusToPreview"] = {
      message = T("Move Focus to Preview"),
      condition = MenuItem.isEnabled{ "View", "Move Focus to Preview" },
      fn = Callback.Select
    }
  },

  ["com.readdle.PDFExpert-Mac"] =
  {
    ["showInFinder"] = {
      message = T("Show in Finder"),
      condition = MenuItem.isEnabled{ "File", "Show in Finder" },
      fn = Callback.Select
    },
    ["remapPreviousTab"] = {
      message = T("Go to Previous Tab"),
      condition = MenuItem.isEnabled{ "Window", "Go to Previous Tab" },
      repeatable = true,
      fn = Callback.Select
    }
  },

  ["com.vallettaventures.Texpad"] =
  {
    ["toggleOutline"] = {
      message = T("Toggle Outline"),
      condition = MenuItem.isEnabled{ "Workspace", "Toggle Outline" },
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = T("Recent Documents"),
      condition = MenuItem.isEnabled{ "File", "Recent Documents" },
      fn = Callback.Select
    }
  },

  ["abnerworks.Typora"] =
  {
    ["openFileLocation"] = {
      message = T("Open File Location"),
      condition = MenuItem.isEnabled{ "File", "Open File Location" },
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = T("Open Recent"),
      condition = MenuItem.isEnabled({ "File", "Open Quickly…" },
                                     { "File", "Open Recent" }),
      fn = Callback.Select
    }
  },

  ["com.superace.updf.mac"] =
  {
    ["goToHome"] = {
      message = T("Home"),
      windowFilter = {
        allowTitles = "",
        fn = function(win)
          local title = T("Home", win)
          if title == win:title() then return false end
          local image = getc(towinui(win), AX.TabGroup, 1,
              AX.Button, 1, AX.Image, 1)
          return image ~= nil
        end
      },
      fn = function(win)
        local button = getc(towinui(win), AX.TabGroup, 1, AX.Button, 1)
        if button then leftClickAndRestore(button, win) end
      end
    },
    ["toggleSidebar"] = {
      message = TC("Show Sidebar"),
      condition = function(app)
        local title = T("View", app)
        local menuItems = getc(toappui(app), AX.MenuBar, 1,
            AX.MenuBarItem, title, AX.Menu, 1, AX.MenuItem)
        local firstSidebarMenuItem
        for _, item in ipairs(menuItems or {}) do
          if item.AXTitle == "" then break end
          if #item == 0 then
            if item.AXMenuItemMarkChar then
              return Callback.Enabled(item)
            end
            firstSidebarMenuItem = firstSidebarMenuItem or item
          end
        end
        return Callback.Enabled(firstSidebarMenuItem)
      end,
      fn = Callback.Press
    },
    ["showPrevTab"] = specialCommonHotkeyConfigs["showPrevTab"],
    ["showNextTab"] = specialCommonHotkeyConfigs["showNextTab"],
    ["showInFinder"] = {
      message = T("Show in Finder"),
      condition = MenuItem.isEnabled{ "File", "Show in Finder" },
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = T("Open Quickly…"),
      condition = MenuItem.isEnabled{ "File", "Open Quickly…" },
      fn = Callback.Select
    },
    ["openRecentFromMB"] = {
      message = TMB("Open Recent"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    },
    ["confirmDelete"] = {
      message = T("Don't Save"),
      condition = function(app)
        local win = app:focusedWindow()
        if win == nil then return false end
        local winUI = towinui(win)
        local button = getc(winUI, AX.Buttonm, A_Message)
            or getc(winUI, AX.Window, 1, AX.Button, A_Message)
        return button ~= nil, button
      end,
      fn = Callback.Press
    }
  },

  ["com.kingsoft.wpsoffice.mac"] =
  {
    ["previousWindow"] = specialCommonHotkeyConfigs["showPrevTab"],
    ["nextWindow"] = specialCommonHotkeyConfigs["showNextTab"],
    ["goToFileTop"] = {
      mods = "", key = "Home",
      message = "Cursor to Top",
      windowFilter = WPS.WF.NonHome,
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke("⌘", "Home", nil, app) end
    },
    ["goToFileBottom"] = {
      mods = "", key = "End",
      message = "Cursor to Bottom",
      windowFilter = WPS.WF.NonHome,
      fn = function(app) hs.eventtap.keyStroke("⌘", "End", nil, app) end
    },
    ["selectToFileTop"] = {
      mods = "⇧", key = "Home",
      message = "Select to Top",
      windowFilter = WPS.WF.NonHome,
      fn = function(app) hs.eventtap.keyStroke("⇧⌘", "Home", nil, app) end
    },
    ["selectToFileBottom"] = {
      mods = "⇧", key = "End",
      message = "Select to Bottom",
      windowFilter = WPS.WF.NonHome,
      fn = function(app) hs.eventtap.keyStroke("⇧⌘", "End", nil, app) end
    },
    ["properties"] = {
      message = T("Properties..."),
      windowFilter = WPS.WF.NonHome,
      condition = MenuItem.isEnabled{ "File", "Properties..." },
      fn = Callback.Select
    },
    ["exportToPDF"] = {
      message = T("Export to PDF..."),
      windowFilter = WPS.WF.WPS_WPP_ET,
      condition = MenuItem.isEnabled{ "File", "Export to PDF..." },
      fn = Callback.Select
    },
    ["insertTextBox"] = {
      message = T{"Insert", "Text Box"},
      windowFilter = WPS.WF.WPS_WPP,
      condition = MenuItem.isEnabled{ "Insert", "Text Box", "Horizontal Text Box" },
      fn = Callback.Select
    },
    ["insertEquation"] = {
      message = T{"Insert", "LaTeXEquation..."},
      windowFilter = WPS.WF.WPS_WPP_ET,
      condition = MenuItem.isEnabled{ "Insert", "LaTeXEquation..." },
      fn = Callback.Select
    },
    ["pdfHightlight"] = {
      message = T("Highlight"),
      windowFilter = WPS.WF.PDF,
      condition = MenuItem.isEnabled{ "Comment", "Highlight" },
      fn = Callback.Select
    },
    ["pdfUnderline"] = {
      message = T("Underline"),
      windowFilter = WPS.WF.PDF,
      condition = MenuItem.isEnabled{ "Comment", "Underline" },
      fn = Callback.Select
    },
    ["pdfStrikethrough"] = {
      message = T("Strikethrough"),
      windowFilter = WPS.WF.PDF,
      condition = MenuItem.isEnabled{ "Comment", "Strikethrough" },
      fn = Callback.Select
    },
    ["goToHome"] = {
      message = T("Home"),
      windowFilter = WPS.WF.NonHome,
      fn = function(win)
        local winUI = towinui(win)
        local buttons = getc(winUI, AX.Button)
        local maxX = buttons[#buttons].AXPosition.x
        maxX = math.max(maxX, buttons[#buttons - 1].AXPosition.x)
        maxX = math.max(maxX, buttons[#buttons - 2].AXPosition.x)
        leftClickAndRestore({ maxX + 100, buttons[#buttons].AXPosition.y }, win)
      end
    },
    ["openRecent"] = {
      message = T("Recent"),
      fn = function(app)
        if app:focusedWindow() == nil then return end
        local home = T("Home", app)
        local winUI = towinui(app:focusedWindow())
        if app:focusedWindow():title() ~= home then
          local buttons = getc(winUI, AX.Button)
          local maxX = buttons[#buttons].AXPosition.x
          maxX = math.max(maxX, buttons[#buttons - 1].AXPosition.x)
          maxX = math.max(maxX, buttons[#buttons - 2].AXPosition.x)
          local mousePosition = hs.mouse.absolutePosition()
          local position = hs.geometry.point{ maxX + 100, buttons[#buttons].AXPosition.y }
          mouseDown(position)
          mouseUp(position)
          mouseMove(mousePosition)
          hs.timer.usleep(1000000)
        end
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine
        for i, g in ipairs(groups or {}) do
          if g.AXSize.h == 16 then
            firstSplitLine = i
            break
          end
        end
        if firstSplitLine == 4 then
          leftClickAndRestore(groups[1], app)
        end
      end,
    },
    ["goToShare"] = {
      message = T("Share"),
      windowFilter = WPS.WF.Home,
      condition = function(win)
        local winUI = towinui(win)
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine
        for i, g in ipairs(groups) do
          if g.AXSize.h == 16 then
            firstSplitLine = i
            break
          end
        end
        if firstSplitLine == 4 then
          return Callback.Clickable(groups[3])
        end
        return false
      end,
      fn = Callback.Click
    },
    ["goToMyCloudDocuments"] = {
      message = T("My Cloud Documents"),
      windowFilter = WPS.WF.Home,
      condition = function(win)
        local winUI = towinui(win)
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine, secondSplitLine
        for i, g in ipairs(groups) do
          if g.AXSize.h == 16 then
            if firstSplitLine == nil then
              firstSplitLine = i
            elseif secondSplitLine == nil then
              secondSplitLine = i
              break
            end
          end
        end
        if secondSplitLine == nil or (secondSplitLine - firstSplitLine > 2) then
          return Callback.Clickable(groups[firstSplitLine + 2])
        end
        return false
      end,
      fn = Callback.Click
    },
    ["goToMyDesktop"] = {
      message = T("My Desktop"),
      windowFilter = WPS.WF.Home,
      condition = function(win)
        local winUI = towinui(win)
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine, secondSplitLine, thirdSplitLine
        for i, g in ipairs(groups) do
          if g.AXSize.h == 16 then
            if firstSplitLine == nil then
              firstSplitLine = i
            elseif secondSplitLine == nil then
              secondSplitLine = i
            elseif thirdSplitLine == nil then
              thirdSplitLine = i
              break
            end
          end
        end
        if thirdSplitLine ~= nil and thirdSplitLine - secondSplitLine > 2 then
          return Callback.Clickable(groups[secondSplitLine + 2])
        end
        return false
      end,
      fn = Callback.Click
    },
    ["goToDocuments"] = {
      message = T("Documents"),
      windowFilter = WPS.WF.Home,
      condition = function(win)
        local winUI = towinui(win)
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine, secondSplitLine, thirdSplitLine
        for i, g in ipairs(groups) do
          if g.AXSize.h == 16 then
            if firstSplitLine == nil then
              firstSplitLine = i
            elseif secondSplitLine == nil then
              secondSplitLine = i
            elseif thirdSplitLine == nil then
              thirdSplitLine = i
              break
            end
          end
        end
        if thirdSplitLine ~= nil and thirdSplitLine - secondSplitLine > 3 then
          return Callback.Clickable(groups[secondSplitLine + 3])
        end
        return false
      end,
      fn = Callback.Click
    },
    ["goToDownloads"] = {
      message = T("Downloads"),
      windowFilter = WPS.WF.Home,
      condition = function(win)
        local winUI = towinui(win)
        local groups = getc(winUI, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
            or getc(winUI, AX.SplitGroup, 1, AX.SplitGroup, 1, AX.Group, 4, AX.Group)
        local firstSplitLine, secondSplitLine, thirdSplitLine
        for i, g in ipairs(groups) do
          if g.AXSize.h == 16 then
            if firstSplitLine == nil then
              firstSplitLine = i
            elseif secondSplitLine == nil then
              secondSplitLine = i
            elseif thirdSplitLine == nil then
              thirdSplitLine = i
              break
            end
          end
        end
        if thirdSplitLine ~= nil and thirdSplitLine - secondSplitLine > 4 then
          return Callback.Clickable(groups[secondSplitLine + 4])
        end
        return false
      end,
      fn = Callback.Click
    },
    ["openFileLocation"] = {
      message = T("Open File Location"),
      windowFilter = WPS.WF.NonHome,
      condition = function(win)
        local winUI = towinui(win)
        for i=1,#winUI - 1 do
          if winUI[i].AXRole == AX.Button
              and winUI[i + 1].AXRole == AX.Group then
            return true, winUI[i].AXPosition
          end
        end
        return false
      end,
      fn = function(position, win)
        local app = win:application()
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(toappui(app), uinotifications.created)
        observer:callback(A_WinHotkeyWrapper(function(obs)
          for _, elem in ipairs(toappui(app)) do
            local menuItem = getc(elem, AX.Menu, 1, AX.MenuItem, A_Message)
            if menuItem then
              Callback.Press(menuItem)
              if app:isFrontmost() then
                hs.eventtap.keyStroke("", "Escape", nil, app)
              end
              obs:stop()
              obs = nil
            end
          end
        end))
        observer:start()
        local clicked = rightClickAndRestore(position, app)
        if clicked then
          hs.timer.doAfter(2, function()
            if observer ~= nil then
              observer:stop()
              observer = nil
            end
          end)
        else
          observer:stop()
          observer = nil
        end
      end
    },
    ["prevInSettings"] = {
      message = TC("Back"),
      windowFilter = WPS.WF.Settings,
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, "Prev")
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["nextInSettings"] = {
      message = TC("Forward"),
      windowFilter = WPS.WF.Settings,
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, "Next")
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
  },

  ["cn.wps.yunboxtool"] = {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.iWork.Keynote"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = T{"Export To", "PDF…"},
      condition = MenuItem.isEnabled{ "File", "Export To", "PDF…" },
      fn = Callback.Select
    },
    ["exportToPPT"] = {  -- File > Export To > PowerPoint…
      message = T{"Export To", "PowerPoint…"},
      condition = MenuItem.isEnabled{ "File", "Export To", "PowerPoint…" },
      fn = Callback.Select
    },
    ["pasteAndMatchStyle"] = {  -- Edit > Paste and Match Style
      message = T("Paste and Match Style"),
      condition = MenuItem.isEnabled{ "Edit", "Paste and Match Style" },
      repeatable = true,
      fn = Callback.Select
    },
    ["paste"] = {  -- Edit > Paste
      message = T("Paste"),
      condition = MenuItem.isEnabled{ "Edit", "Paste" },
      repeatable = true,
      fn = Callback.Select
    },
    ["toggleSlideOnly"] = {
      message = T("Slide Only"),
      condition = function(app)
        local menuItem, menuItemPath = findMenuItem(app, { "View", "Slide Only" })
        if menuItem and menuItem.ticked then
          menuItem, menuItemPath = findMenuItem(app, { "View", "Navigator"})
        end
        return menuItem and menuItem.enabled, menuItemPath
      end,
      fn = Callback.Select
    },
    ["showBuildOrder"] = {  -- View > Show Build Order
      message = T("Show Build Order"),
      condition = MenuItem.isEnabled{ "View", "Show Build Order" },
      fn = function(menuItemTitle, app)
        app:selectMenuItem(menuItemTitle)
        local winTitle = T("Build Order", app)
        hs.timer.doAfter(0.5, function()
          local window = tifilter(app:visibleWindows(), function(win)
            return win:title() == winTitle
          end)
          if #window ~= 0 then window[1]:raise() end
        end)
      end
    },
    ["toggleFormatInspector"] = {  -- View > Inspector > Format
      message = T{"Inspector", "Format"},
      condition = MenuItem.isEnabled{ "View", "Inspector", "Format" },
      fn = Callback.Select
    },
    ["play"] = {  -- Play > Play Slideshow
      message = T("Play Slideshow"),
      condition = MenuItem.isEnabled{ "Play", "Play Slideshow" },
      fn = Callback.Select
    },
    ["insertTextBox"] = {  -- Insert > Text Box
      message = T{"Insert", "Text Box"},
      condition = MenuItem.isEnabled{ "Insert", "Text Box" },
      fn = Callback.Select
    },
    ["insertShape"] = {  -- Insert > Shape
      message = T{"Insert", "Shape"},
      condition = MenuItem.isEnabled{ "Insert", "Shape" },
      fn = Callback.Select
    },
    ["insertLine"] = {  -- Insert > Line
      message = T{"Insert", "Line"},
      condition = MenuItem.isEnabled{ "Insert", "Line" },
      fn = Callback.Select
    },
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    },
  },

  ["com.apple.iWork.Pages"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = T{"Export To", "PDF…"},
      condition = MenuItem.isEnabled{ "File", "Export To", "PDF…" },
      fn = Callback.Select
    },
    ["exportToWord"] = {  -- File > Export To > Word…
      message = T{"Export To", "Word…"},
      condition = MenuItem.isEnabled{ "File", "Export To", "Word…" },
      fn = Callback.Select
    },
    ["pasteAndMatchStyle"] = {  -- Edit > Paste and Match Style
      message = T("Paste and Match Style"),
      condition = MenuItem.isEnabled{ "Edit", "Paste and Match Style" },
      repeatable = true,
      fn = Callback.Select
    },
    ["paste"] = {  -- Edit > Paste
      message = T("Paste"),
      condition = MenuItem.isEnabled{ "Edit", "Paste" },
      repeatable = true,
      fn = Callback.Select
    },
    ["toggleFormatInspector"] = {  -- View > Inspector > Format
      message = T{"Inspector", "Format"},
      condition = MenuItem.isEnabled{ "View", "Inspector", "Format" },
      fn = Callback.Select
    },
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    },
  },

  ["com.apple.iWork.Numbers"] =
  {
    ["exportToPDF"] = {  -- File > Export To > PDF…
      message = T{"Export To", "PDF…"},
      condition = MenuItem.isEnabled{ "File", "Export To", "PDF…" },
      fn = Callback.Select
    },
    ["exportToExcel"] = {  -- File > Export To > Excel…
      message = T{"Export To", "Excel…"},
      condition = MenuItem.isEnabled{ "File", "Export To", "Excel…" },
      fn = Callback.Select
    },
    ["pasteAndMatchStyle"] = {  -- Edit > Paste and Match Style
      message = T("Paste and Match Style"),
      condition = MenuItem.isEnabled{ "Edit", "Paste and Match Style" },
      repeatable = true,
      fn = Callback.Select
    },
    ["paste"] = {  -- Edit > Paste
      message = T("Paste"),
      condition = MenuItem.isEnabled{ "Edit", "Paste" },
      repeatable = true,
      fn = Callback.Select
    },
    ["toggleFormatInspector"] = {  -- View > Inspector > Format
      message = T{"Inspector", "Format"},
      condition = MenuItem.isEnabled{ "View", "Inspector", "Format" },
      fn = Callback.Select
    },
    ["showInFinder"] = {
      message = TC("Show in Finder"),
      condition = function(app)
        if app:mainWindow() == nil then return end
        local doc = towinui(app:mainWindow()).AXDocument
        return doc ~= nil, doc
      end,
      fn = function(doc)
        hs.execute('open -R "' .. doc .. '"')
        if OS_VERSION >= OS.Tahoe then
          find("com.apple.finder"):activate()
        end
      end
    },
  },

  ["net.xmind.vana.app"] =
  {
    ["exportToPDF"] = {
      message = T{"Export", "PDF"},
      condition = MenuItem.isEnabled{ "File", "Export", "PDF" },
      fn = Callback.Select
    },
    ["insertEquation"] = {
      message = T{"Insert", "Equation"},
      condition = MenuItem.isEnabled{ "Insert", "Equation" },
      fn = Callback.Select
    }
  },

  ["com.eusoft.freeeudic"] =
  {
    ["function1"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 1)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = MenuItem.isEnabled{ "功能", "返回首页" },
      fn = Callback.Select
    },
    ["function2"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 2)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 2)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["function3"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 3)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 3)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["function4"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 4)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 4)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["function5"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 5)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 5)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["function6"] = {
      message = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 6)
        if button then return button.AXTitle end
      end,
      windowFilter = EuDic.WF.Main,
      condition = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1, AX.Button, 6)
        return button ~= nil, button
      end,
      fn = Callback.Press
    }
  },

  ["com.eusoft.freeeudic.LightPeek"] =
  {
    ["preferencesFromMB"] = {
      message = TMB("com.eusoft.freeeudic", "偏好设置..."),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["com.openai.codex"] = {
    ["toggleSidebar"] = {
      message = "Toggle Sidebar",
      condition = MenuItem.isEnabled{ "View", "Toggle Sidebar" },
      fn = Callback.Select
    }
  },

  ["com.openai.chat"] =
  {
    ["toggleSidebar"] = {
      message = T("Toggle Sidebar"),
      enabled = Version.LessEqual("1.2024.332"),
      condition = MenuItem.isEnabled{ "View", "Toggle Sidebar" },
      fn = Callback.Select
    },
    ["back"] = {
      message = T("Back"),
      windowFilter = {
        allowTitles = "",
        fn = function(win)
          if towinui(win).AXIdentifier == "ChatGPTSettingsAppWindow" then
            local button = getc(towinui(win), AX.Toolbar, 1,
                AX.Button, 1, AX.Button, 1)
            return button ~= nil
          end
        end
      },
      fn = function(win)
        local button = getc(towinui(win), AX.Toolbar, 1,
            AX.Button, 1, AX.Button, 1)
        if Callback.Enabled(button) then Callback.Press(button) end
      end
    },
    ["openLink"] = {
      message = T("Open link"),
      windowFilter = {
        allowSheet = true,
        fn = function(win)
          local title = T("Open link", win)
          local button = tfind(getc(towinui(win), AX.Group, 1,
              AX.Group, 1, AX.Button) or {}, function(bt)
            return bt.AXAttributedDescription:getString()
                and bt.AXAttributedDescription:getString() == title
          end)
          return button ~= nil
        end
      },
      fn = function(win)
        local button = tfind(getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Button) or {}, function(bt)
          return bt.AXAttributedDescription:getString()
              and bt.AXAttributedDescription:getString() == A_Message
        end)
        if button ~= nil then Callback.Press(button) end
      end
    },
    ["toggleChatBar"] = {
      message = TB("Open Chat Bar"),
      background = true,
      fn = function(app)
        local output, status = hs.execute(strfmt([[
          defaults read '%s' KeyboardShortcuts_toggleLauncher | tr -d '\n'
        ]], app:bundleID()))
        if status and output ~= "0" then
          local json = hs.json.decode(output)
          local mods, key = parsePlistKeyBinding(
              json["carbonModifiers"], json["carbonKeyCode"])
          if mods == nil or key == nil then return end
          safeGlobalKeyStroke(mods, key)
        else
          clickRightMenuBarItem("ChatGPTHelper", {}, "click")
        end
      end,
      onLaunch = function(app)
        local retry = 0
        while app:focusedWindow() == nil do
          hs.timer.usleep(10000)
          retry = retry + 1
          if retry == 100 then return end
        end
        app:focusedWindow():close()
        app:hide()
        hs.timer.usleep(1000000)
        A_CommonCallback(app)
      end
    }
  },

  ["com.tencent.yuanbao"] =
  {
    ["settings"] = {
      message = T("Settings"),
      condition = function(app)
        local win = app:focusedWindow()
        if win == nil then
          return appVer(app) >= "2"
        end
        if win:title() == T("Yuanbao Setting", app)
            or win:title() == T("Tencent Yuanbao Setting", app) then
          return false
        end

        local winUI = towinui(win)
        local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
          AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        local menu = getc(webarea, AX.Group, 8, AX.Group, 2, AX.Group, 1)

        if menu then
          local menuItem = getc(menu, AX.StaticText, A_Message)
          return Callback.Clickable(menuItem)
        end

        local button = tfind(getc(webarea, AX.Group), function(b)
          return tfind(b.AXDOMClassList or {}, function(c)
            return c:find("side%-bar_nickName") ~= nil
                or c:find("side%-bar_name") ~= nil
          end) ~= nil
        end)
        if button ~= nil and button.AXPosition.x ~= winUI.AXPosition.x then
          local ok, position = Callback.Clickable(button)
          if ok then
            local bt = getc(webarea, AX.StaticText, "\xee\x83\xbe")
            if bt ~= nil then
              return ok, { position, button }
            end
          end
        end

        return appVer(app) >= "2"
      end,
      fn = function(button, app)
        if app ~= nil then
          if #button == 0 then
            Callback.Click(button) return
          end
          Callback.Click(button[1]) button = button[2]

          if tfind(button.AXDOMClassList or {}, function(c)
            return c:find("nickName") ~= nil
          end) ~= nil then
            local menuItem
            local timer = hs.timer.waitUntil(A_HotkeyWrapper(function()
              local winUI = towinui(app:focusedWindow())
              local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
                  AX.ScrollArea, 1, AX.WebArea, 1)
              local menu = getc(webarea, AX.Group, 8, AX.Group, 2, AX.Group, 1)
              if menu then
                menuItem = getc(menu, AX.StaticText, A_Message)
                return true
              end
            end),
            function() leftClickAndRestore(menuItem, app) end)
            Evt.StopOnDeactivated(app, timer)
          end
          return
        end

        app = button
        local observer = uiobserver.new(app:pid())
        observer:addWatcher(toappui(app), uinotifications.windowCreated)
        observer:callback(A_HotkeyWrapper(function(obs, winUI)
          local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
              AX.ScrollArea, 1, AX.WebArea, 1)
          if webarea then
            for _, g in ipairs(getc(webarea, AX.Group)) do
              if g[1] and g[1].AXValue == A_Message then
                leftClickAndRestore(g[1], app)
                obs:stop() obs = nil
                return
              end
            end
            winUI:asHSWindow():close()
          end
        end))
        observer:start()
        local clicked = clickRightMenuBarItem(app, {}, "right-click")
        if clicked then
          hs.timer.doAfter(5, function()
            if observer ~= nil then
              observer:stop()
              observer = nil
            end
          end)
        else
          observer:stop()
          observer = nil
        end
      end
    },
    ["newChat"] = {
      message = T("New Chat"),
      enabled = Version.LessThan("1.6.0"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUI = towinui(app:focusedWindow())
        local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        local button = tfind(getc(webarea, AX.Group), function(b)
          return tfind(b.AXDOMClassList or {}, function(c)
            return c:find("chat_new%-chat%-close") ~= nil
                or c:find("side%-bar_newChatIcon") ~= nil
          end) ~= nil
        end)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["enterTemporaryChat"] = {
      message = T("Enter Temporary Chat"),
      windowFilter = Yuanbao.WF.Main,
      condition = function(win)
        local webarea = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        local button = getc(webarea, AX.StaticText, "\xee\x84\x83")
        if button == nil then
          button = getc(webarea, AX.StaticText, "\xee\x82\xa8")
        end
        return Callback.Clickable(button)
      end,
      fn = Callback.Click
    },
    ["toggleSidebar"] = {
      message = T("Show Sidebar"),
      windowFilter = Yuanbao.WF.Main,
      condition = function(win)
        local webarea = getc(towinui(win), AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        if appVer(win) < "1.15.0" then
          local button = tfind(getc(webarea, AX.Group), function(b)
            return tfind(b.AXDOMClassList or {}, function(c)
              return c:find("folder_foldIcon") ~= nil
            end) ~= nil
          end)
          return button ~= nil, button
        else
          local button = getc(webarea, AX.StaticText, "\xee\x84\x82")
          return Callback.Clickable(button)
        end
      end,
      fn = Callback.PressClick
    },
    ["maximize"] = {
      mods = get(KeybindingConfigs.hotkeys.shared, "zoom", "mods"),
      key = get(KeybindingConfigs.hotkeys.shared, "zoom", "key"),
      message = T("Maximize"),
      windowFilter = Yuanbao.WF.Main,
      condition = MenuItem.isEnabled{ "Window", "Maximize" },
      fn = Callback.Select
    },
    ["back"] = {
      message = TC("Back"),
      enabled = Version.LessThan("2"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local winUI = towinui(app:focusedWindow())
        local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
            AX.ScrollArea, 1, AX.WebArea, 1)
        if webarea == nil then return false end
        local button = tfind(getc(webarea, AX.Group), function(b)
          return tfind(b.AXDOMClassList or {}, function(c)
            return c:find("setting_arrowLeft") ~= nil
          end) ~= nil
        end)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["toggleMiniChat"] = {
      message = TB("Open Mini Chat"),
      background = true,
      fn = function(app)
        if appVer(app) < "2" then
          -- false invoke when menubar manager try to show or hide menubar icon
          -- always show the icon to workaround it
          clickRightMenuBarItem(app, {}, "click")
        else
          local observer = uiobserver.new(app:pid())
          observer:addWatcher(toappui(app), uinotifications.windowCreated)
          observer:callback(A_HotkeyWrapper(function(obs, winUI)
            -- false invoke when menubar manager try to show or hide menubar icon
            -- in early edition
            if winUI.AXSubrole == AX.StandardWindow then return end

            local webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
              AX.ScrollArea, 1, AX.WebArea, 1)
            if webarea then
              local title = strsplit(A_Message, " > ")[2]
              for _, g in ipairs(getc(webarea, AX.Group)) do
                if g[1] and g[1].AXValue == title then
                  leftClickAndRestore(g[1], app)
                  break
                end
              end
              obs:stop()
              obs = nil
            end
          end))
          observer:start()
          local clicked = clickRightMenuBarItem(app, {}, "right-click")
          if clicked then
            hs.timer.doAfter(5, function()
              if observer ~= nil then
                observer:stop()
                observer = nil
              end
            end)
          else
            observer:stop()
            observer = nil
          end
        end
      end,
      onLaunch = function(app)
        local retry = 0
        while app:focusedWindow() == nil do
          hs.timer.usleep(10000)
          retry = retry + 1
          if retry == 100 then return end
        end
        app:focusedWindow():close()
        app:hide()
        hs.timer.usleep(1000000)
        A_CommonCallback(app)
      end
    },
    ["showMainWindowFromMB"] = {
      message = T("Open Yuanbao"),
      windowFilter = {
        allowRoles = AX.SystemDialog
      },
      background = true,
      fn = function(win)
        hs.application.launchOrFocusByBundleID(win:application():bundleID())
      end
    }
  },

  ["JabRef"] =
  {
    ["preferences"] = {
      message = T("Preferences"),
      condition = MenuItem.isEnabled{ "File", "Preferences" },
      fn = Callback.Select
    },
    ["newLibrary"] = {
      message = T("New library"),
      condition = MenuItem.isEnabled{ "File", "New library" },
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = T("Recent libraries"),
      condition = MenuItem.isEnabled{ "File", "Recent libraries" },
      fn = Callback.Select
    },
    ["revealLibrayInFinder"] = {
      message = T("Reveal in file explorer"),
      windowFilter = JabRef.WF.numberLibraries(1),
      condition = function(win)
        local tab = tfind(getc(towinui(win), AX.TabGroup, 1, AX.RadioButton) or {},
          function(rb) return rb.AXValue == true
              and rb.AXTitle ~= T("untitled", win)
        end)
        return tab ~= nil, tab
      end,
      fn = function(tab, win)
        tab:performAction(AX.ShowMenu)
        hs.timer.doAfter(0.1, A_WinHotkeyWrapper(function()
          local app = win:application()
          local item = getc(toappui(app), AX.Menu, 1, AX.MenuItem, A_Message)
          if item then Callback.Press(item) end
        end))
      end
    },
    ["openRecordFile"] = {
      message = T("Open file"),
      windowFilter = JabRef.WF.numberLibraries(1),
      condition = function(win)
        local row = tfind(getc(towinui(win), AX.TabGroup, 1, AX.Table, 1, AX.Row) or {},
          function(r) return r.AXFocused
        end)
        if row then
          local cell = tfind(getc(row, AX.Cell), function(c)
            local text = getc(c, AX.StaticText, 1)
            return text ~= nil and text.AXValue == "\xf3\xb0\x88\xa5"
          end)
          return Callback.Clickable(cell)
        end
      end,
      fn = Callback.Click
    },
    ["remapPreviousTab"] = {
      message = T("Previous library"),
      windowFilter = JabRef.WF.numberLibraries(2),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⇧⌃', 'Tab', nil, app) end
    },
    ["showPrevLibrary"] = {
      mods = specialCommonHotkeyConfigs["showPrevTab"].mods,
      key = specialCommonHotkeyConfigs["showPrevTab"].key,
      message = T("Previous library"),
      windowFilter = JabRef.WF.numberLibraries(2),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⇧⌃', 'Tab', nil, app) end
    },
    ["showNextLibrary"] = {
      mods = specialCommonHotkeyConfigs["showNextTab"].mods,
      key = specialCommonHotkeyConfigs["showNextTab"].key,
      message = T("Next library"),
      windowFilter = JabRef.WF.numberLibraries(2),
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⌃', 'Tab', nil, app) end
    },
    ["1stLibrary"] = {
      message = "First Library",
      windowFilter = JabRef.WF.numberLibraries(1),
      condition = JabRef.showLibraryByIndex(1),
      fn = Callback.Click
    },
    ["2ndLibrary"] = {
      message = "Second Library",
      windowFilter = JabRef.WF.numberLibraries(2),
      condition = JabRef.showLibraryByIndex(2),
      fn = Callback.Click
    },
    ["3rdLibrary"] = {
      message = "Third Library",
      windowFilter = JabRef.WF.numberLibraries(3),
      condition = JabRef.showLibraryByIndex(3),
      fn = Callback.Click
    },
    ["4thLibrary"] = {
      message = "Forth Library",
      windowFilter = JabRef.WF.numberLibraries(4),
      condition = JabRef.showLibraryByIndex(4),
      fn = Callback.Click
    },
    ["5thLibrary"] = {
      message = "Fifth Library",
      windowFilter = JabRef.WF.numberLibraries(5),
      condition = JabRef.showLibraryByIndex(5),
      fn = Callback.Click
    },
    ["6thLibrary"] = {
      message = "Sixth Library",
      windowFilter = JabRef.WF.numberLibraries(6),
      condition = JabRef.showLibraryByIndex(6),
      fn = Callback.Click
    },
    ["7thLibrary"] = {
      message = "Seventh Library",
      windowFilter = JabRef.WF.numberLibraries(7),
      condition = JabRef.showLibraryByIndex(7),
      fn = Callback.Click
    },
    ["8thLibrary"] = {
      message = "Eighth Library",
      windowFilter = JabRef.WF.numberLibraries(8),
      condition = JabRef.showLibraryByIndex(8),
      fn = Callback.Click
    },
    ["9thLibrary"] = {
      message = "Nineth Library",
      windowFilter = JabRef.WF.numberLibraries(9),
      condition = JabRef.showLibraryByIndex(9),
      fn = Callback.Click
    },
    ["10thLibrary"] = {
      message = "Tenth Library",
      windowFilter = JabRef.WF.numberLibraries(10),
      condition = JabRef.showLibraryByIndex(10),
      fn = Callback.Click
    },
    ["minimize"] = specialCommonHotkeyConfigs["minimize"]
  },

  ["org.zotero.zotero"] = {
    ["newCollection"] = {
      message = T("New Collection…"),
      condition = MenuItem.isEnabled{ "File", "New Collection…" },
      fn = Callback.Select
    }
  },

  ["org.klatexformula.klatexformula"] =
  {
    ["render"] = {
      message = "Render",
      windowFilter = {
        allowTitles = "^KLatexFormula$"
      },
      condition = function(win)
        local g = getc(towinui(win), AX.SplitGroup, 1)
        local ta = getc(g, AX.TextArea, 1)
        return ta ~= nil and ta.AXValue ~= "", getc(g, AX.Button, 2)
      end,
      fn = Callback.Press
    },
    ["renderClipboardInKlatexformula"] = {
      message = "Render Clipboard in klatexformula",
      fn = function(app)
        app:mainWindow():focus()
        app:selectMenuItem{ "Shortcuts", "Activate Editor and Select All" }
        hs.eventtap.keyStroke("⌘", "V", nil, app)

        local winUI = towinui(app:mainWindow())
        local button = getc(winUI, AX.SplitGroup, 1, AX.Button, 2)
        if button ~= nil then
          Callback.Press(button)
        end
      end
    },
    ["copy"] = {
      message = "Copy",
      windowFilter = {
        allowTitles = "^KLatexFormula$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.SplitGroup, 1, AX.Button, "COPY")
        return Callback.Enabled(button)
      end,
      fn = Callback.Press
    },
    ["clear"] = {
      message = "Clear",
      windowFilter = {
        allowTitles = "^KLatexFormula$"
      },
      fn = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.SplitGroup, 1, AX.Button, 1)
        if button ~= nil then
          Callback.Press(button)
        end
      end
    },
    ["save"] = {
      message = "Save",
      windowFilter = {
        allowTitles = "^KLatexFormula$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.SplitGroup, 1, AX.Button, "SAVE")
        return Callback.Enabled(button)
      end,
      fn = Callback.Press
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"]
  },

  ["com.apple.iMovieApp"] =
  {
    ["export"] = {
      message = T{"Share", "File…"},
      condition = MenuItem.isEnabled{ "File", "Share", "File…" },
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = T("Open Library"),
      condition = MenuItem.isEnabled{ "File", "Open Library" },
      fn = Callback.Select
    }
  },

  ["com.tdesktop.Telegram"] =
  {
    ["remapPreviousTab"] = {
      message = "Go to Previous Chat",
      repeatable = true,
      fn = function(app) hs.eventtap.keyStroke('⇧⌃', 'Tab', nil, app) end
    }
  },

  ["com.tencent.xinWeChat"] =
  {
    ["backFromMinizedGroups"] = {
      message = function(win)
        return T("Minimized Groups", win) .. ' > ' .. TC("Back", win)
      end,
      enabled = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.Main,
      condition = function(win)
        local title = strsplit(A_Message, ' > ')[2]
        local bt = getc(towinui(win), AX.Group, 1,
            AX.SplitGroup, 1, AX.Button, title)
        return Callback.Clickable(bt)
      end,
      fn = Callback.Click
    },
    ["backInOfficialAccounts"] = {
      message = T{ "Tabbar.OA", "Common.Navigation.Back" },
      enabled = Version.LessThan("4"),
      windowFilter = WeChat.WF.Main,
      condition = function(win)
        local g = getc(towinui(win), AX.SplitGroup, 1, AX.SplitGroup, 1)
        if g ~= nil then
          local title = strsplit(A_Message, ' > ')[2]
          for _, bt in ipairs(getc(g, AX.Button)) do
            if bt.AXTitle == title then
              return true, bt
            end
          end
        end
      end,
      fn = Callback.Press
    },
    ["backInMoments"] = {
      message = TC("Back"),
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.Moments,
      condition = function(win)
        local button
        if appVer(win) < "4" then
          button = tfind(getc(towinui(win), AX.Button) or {},
              function(bt) return bt.AXDescription == A_Message end)
        else
          button = getc(towinui(win), AX.Button, A_Message)
        end
        return Callback.Clickable(button)
      end,
      fn = Callback.Click
    },
    ["hideChat"] = {
      message = function(win)
        if appVer(win) < "4" then
          local title = T("Chats.Menu.Hide", win)
          local chats = getc(towinui(win), AX.SplitGroup, 1,
              AX.ScrollArea, 1, AX.Table, 1)
          if chats and chats.AXDescription then
            return chats.AXDescription .. ' > ' .. title
          else
            return title
          end
        else
          local title = localizedString("Hide", win)
          if type(title) == 'table' then title = title[#title] end
          local chats = getc(towinui(win), AX.Group, 1,
              AX.SplitGroup, 1, AX.List, -1)
          if chats and chats.AXTitle then
            return chats.AXTitle .. ' > ' .. title
          else
            return title
          end
        end
      end,
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.Main,
      condition = function(win)
        local winUI = towinui(win)
        if appVer(win) < "4" then
          local chats = getc(winUI, AX.SplitGroup, 1,
              AX.ScrollArea, 1, AX.Table, 1, AX.Row)
          if chats == nil then return end
          local curChatTitle = getc(winUI, AX.SplitGroup, 1,
              AX.SplitGroup, 1, AX.StaticText, 1)
              or getc(winUI, AX.SplitGroup, 1, AX.StaticText, 1)
          if curChatTitle and curChatTitle.AXSize.h <= 5 then
            return false
          end
          if curChatTitle == nil then
            local curChat = tfind(chats, function(row)
              return row.AXFocused
            end)
            return curChat ~= nil, curChat
          end
          local title = curChatTitle.AXValue
          local curChat = tfind(chats, function(c)
            local row = getc(c, AX.Cell, 1, AX.Row, 1)
            return row ~= nil and (row.AXTitle == title
                or row.AXTitle:sub(1, #title + 1) == title .. ",")
          end)
          return curChat ~= nil, getc(curChat, AX.Cell, 1)
        else
          local chats = getc(winUI, AX.Group, 1,
              AX.SplitGroup, 1, AX.List, -1, AX.StaticText)
          if chats == nil then return end
          local curChatTitle = getc(winUI, AX.Group, 1,
              AX.SplitGroup, 1, AX.StaticText, -1)
          if curChatTitle == nil then
            local curChat = tfind(chats, function(row)
              return row.AXFocused
            end)
            return curChat ~= nil, curChat
          end
          if #curChatTitle > 0 then
            curChatTitle = getc(curChatTitle, AX.StaticText, 1)
          end
          local title = curChatTitle.AXValue
          local curChat = tfind(chats, function(row)
            return row.AXTitle == title
                or row.AXTitle:sub(1, #title + 1) == title .. " "
          end)
          return curChat ~= nil, curChat
        end
      end,
      fn = function(chat, win)
        chat:performAction(AX.ShowMenu)
        if chat.AXRole == AX.Cell then
          local menu = getc(chat, AX.Row, 1, AX.Menu, 1)
          if menu then
            local hide = getc(menu, AX.MenuItem, "contextMenuHide:")
            if hide then Callback.Press(hide) end
          end
        else
          hs.timer.doAfter(0.5, A_WinHotkeyWrapper(function()
            local app = win:application()
            local menu = toappui(app):elementAtPosition(
                uioffset(chat.AXPosition, { 1, 1 }))
            if menu and menu.AXRole == AX.Menu then
              local title = strsplit(A_Message, ' > ')[2]
              local hide = getc(menu, AX.MenuItem, title)
              if hide then leftClickAndRestore(hide, app) end
            end
          end))
        end
      end
    },
    ["showChatProfile"] = {
      message = function(win)
        local title = T("Chats.Menu.Profile", win)
        local chats = getc(towinui(win), AX.SplitGroup, 1,
            AX.ScrollArea, 1, AX.Table, 1)
        if chats and chats.AXDescription then
          return chats.AXDescription .. ' > ' .. title
        else
          return title
        end
      end,
      enabled = Version.LessThan("4"),
      windowFilter = WeChat.WF.Main,
      condition = function(win)
        local winUI = towinui(win)
        local curChatTitle = getc(winUI, AX.SplitGroup, 1,
            AX.SplitGroup, 1, AX.StaticText, 1)
        if curChatTitle == nil then return false end
        local btTitle = T("ComposeBar.VideoTooltip", win)
        local bt = getc(winUI, AX.SplitGroup, 1,
            AX.SplitGroup, 1, AX.Button, btTitle)
        return bt ~= nil, curChatTitle.AXValue
      end,
      fn = function(title, win)
        local winUI = towinui(win)
        local chats = getc(winUI, AX.SplitGroup, 1,
            AX.ScrollArea, 1, AX.Table, 1, AX.Row)
        local curChat = tfind(chats, function(c)
          local row = getc(c, AX.Cell, 1, AX.Row, 1)
          return row ~= nil and (row.AXTitle == title
              or row.AXTitle:sub(1, #title + 1) == title .. ",")
        end)
        if curChat ~= nil then
          getc(curChat, AX.Cell, 1):performAction(AX.ShowMenu)
          local menu = getc(curChat, AX.Cell, 1,
              AX.Row, 1, AX.Menu, 1)
          if menu then
            local profile = getc(menu, AX.MenuItem, "contextMenuProfile:")
            if profile then Callback.Press(profile) end
          end
        end
      end
    },
    ["previewPreview"] = {
      message = T("Preview"),
      enabled = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        local button = getc(towinui(win), AX.Button, A_Message)
        if Callback.Enabled(button) then
          return Callback.Clickable(getc(button, AX.Button, 1))
        end
      end,
      fn = Callback.Click
    },
    ["previewImageSize"] = {
      message = function(win)
        if appVer(win) < "4" then
          return T("Actual size", win) .. ' / ' .. T("Window Size", win)
        else
          return T("Original image size", win) .. ' / ' .. T("Fit to Window", win)
        end
      end,
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        local titles = strsplit(A_Message, ' / ')
        if appVer(win) < "4" then
          local buttons = A_WinBuf.buttons
          local button = tfind(buttons, function(bt)
            return bt.AXHelp == titles[1] or bt.AXHelp == titles[2]
          end)
          return Callback.Enabled(button)
        else
          local button = getc(towinui(win), AX.Button, titles[1])
              or getc(towinui(win), AX.Button, titles[2])
          if Callback.Enabled(button) then
            return Callback.Clickable(getc(button, AX.Button, 1))
          end
        end
      end,
      fn = Callback.PressClick
    },
    ["previewRotate"] = {
      message = T("Rotate"),
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        if appVer(win) < "4" then
          local buttons = A_WinBuf.buttons
          local button = tfind(buttons, function(bt)
            return bt.AXHelp == A_Message
          end)
          return Callback.Enabled(button)
        else
          local button = getc(towinui(win), AX.Button, A_Message)
          if Callback.Enabled(button) then
            return Callback.Clickable(getc(button, AX.Button, 1))
          end
        end
      end,
      fn = Callback.PressClick
    },
    ["previewEdit"] = {
      message = T("Edit"),
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.PreviewEditable,
      condition = function(win)
        if appVer(win) < "4" then
          local buttons = A_WinBuf.buttons
          local button = tfind(buttons, function(bt)
            return bt.AXHelp == A_Message
          end)
          return Callback.Enabled(button)
        else
          local button = getc(towinui(win), AX.Button, A_Message)
          if Callback.Enabled(button) then
            return Callback.Clickable(getc(button, AX.Button, 1))
          end
        end
      end,
      fn = Callback.PressClick
    },
    ["previewTranslate"] = {
      message = T("Translate"),
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        if appVer(win) < "4" then
          local buttons = A_WinBuf.buttons
          local button = tfind(buttons, function(bt)
            return bt.AXHelp == A_Message
          end)
          return Callback.Enabled(button)
        else
          local button = getc(towinui(win), AX.Button, A_Message)
          if Callback.Enabled(button) then
            return Callback.Clickable(getc(button, AX.Button, 1))
          end
        end
      end,
      fn = Callback.PressClick
    },
    ["previewExtractText"] = {
      message = T("Extract Text"),
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.Preview,
      condition = function(win)
        if appVer(win) < "4" then
          local buttons = A_WinBuf.buttons
          local button = tfind(buttons, function(bt)
            return bt.AXHelp == A_Message
          end)
          return Callback.Enabled(button)
        else
          local button = getc(towinui(win), AX.Button, A_Message)
          if Callback.Enabled(button) then
            return Callback.Clickable(getc(button, AX.Button, 1))
          end
        end
      end,
      fn = Callback.PressClick
    },
    ["photoEditorInsertRectangle"] = {
      message = function(win)
        local title = appVer(win) < "4"
            and "Rectangle" or "Rectangle Tool"
        return T(title, win)
      end,
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.PhotoEditor,
      condition = function(win)
        if appVer(win) < "4" then
          local buttons = A_WinBuf.buttons
          local button = tfind(buttons, function(bt)
            return bt.AXHelp == A_Message
          end)
          return Callback.Enabled(button)
        else
          local button = getc(towinui(win), AX.Button, A_Message)
          if Callback.Enabled(button) then
            return Callback.Clickable(getc(button, AX.Button, 1))
          end
        end
      end,
      fn = Callback.PressClick
    },
    ["photoEditorInsertEllipse"] = {
      message = function(win)
        local title = appVer(win) < "4"
            and "Circle" or "Ellipse Tool"
        return T(title, win)
      end,
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.PhotoEditor,
      condition = function(win)
        if appVer(win) < "4" then
          local buttons = A_WinBuf.buttons
          local button = tfind(buttons, function(bt)
            return bt.AXHelp == A_Message
          end)
          return Callback.Enabled(button)
        else
          local button = getc(towinui(win), AX.Button, A_Message)
          if Callback.Enabled(button) then
            return Callback.Clickable(getc(button, AX.Button, 1))
          end
        end
      end,
      fn = Callback.PressClick
    },
    ["photoEditorInsertMosaic"] = {
      message = function(win)
        local title = appVer(win) < "4"
            and "Pixelate" or "Mosaic"
        return T(title, win)
      end,
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.PhotoEditor,
      condition = function(win)
        if appVer(win) < "4" then
          local buttons = A_WinBuf.buttons
          local button = tfind(buttons, function(bt)
            return bt.AXHelp == A_Message
          end)
          return Callback.Enabled(button)
        else
          local button = getc(towinui(win), AX.Button, A_Message)
          if Callback.Enabled(button) then
            return Callback.Clickable(getc(button, AX.Button, 1))
          end
        end
      end,
      fn = Callback.PressClick
    },
    ["photoEditorInsertText"] = {
      message = function(win)
        local title = localizedString("Text", win)
        if type(title) ~= 'table' then return title end
        local buttons = getc(towinui(win), AX.Button)
        local button = tfind(buttons or {}, function(bt)
          return tfind(title, function(t) return bt.AXTitle == t end) ~= nil
        end)
        if button then return button.AXTitle end
      end,
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.PhotoEditor,
      condition = function(win)
        if appVer(win) < "4" then
          local buttons = A_WinBuf.buttons
          local button = tfind(buttons, function(bt)
            return bt.AXHelp == A_Message
          end)
          return Callback.Enabled(button)
        else
          local button = getc(towinui(win), AX.Button, A_Message)
          if Callback.Enabled(button) then
            return Callback.Clickable(getc(button, AX.Button, 1))
          end
        end
      end,
      fn = Callback.PressClick
    },
    ["photoEditorCrop"] = {
      message = T("Crop"),
      enabled = Version.LessThan("4"),
      windowFilter = WeChat.WF.PhotoEditor,
      condition = function()
        local buttons = A_WinBuf.buttons
        local button = tfind(buttons, function(bt)
          return bt.AXHelp == A_Message
        end)
        return Callback.Enabled(button)
      end,
      fn = Callback.Press
    },
    ["photoEditorSavePhoto"] = {
      message = function(win)
        local title = localizedString("Save", win)
        if type(title) ~= 'table' then return title end
        local buttons = getc(towinui(win), AX.Button)
        local button = tfind(buttons or {}, function(bt)
          return tfind(title, function(t) return bt.AXTitle == t end) ~= nil
        end)
        if button then return button.AXTitle end
      end,
      enabled = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.PhotoEditor,
      condition = function(win)
        local button = getc(towinui(win), AX.Button, A_Message)
        if Callback.Enabled(button) then
          return Callback.Clickable(getc(button, AX.Button, 1))
        end
      end,
      fn = Callback.Click
    },
    ["photoEditorSendToChat"] = {
      message = T("Send to Chat"),
      enabled = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.PhotoEditor,
      condition = function(win)
        local button = getc(towinui(win), AX.Button, A_Message)
        if Callback.Enabled(button) then
          return Callback.Clickable(getc(button, AX.Button, 1))
        end
      end,
      fn = Callback.Click
    },
    ["photoEditorDone"] = {
      message = T("Done"),
      enabled = Version.LessThan("4.0.6"),
      windowFilter = WeChat.WF.PhotoEditor,
      condition = function(win)
        if appVer(win) < "4" then
          local buttons = A_WinBuf.buttons
          local button = tfind(buttons, function(bt)
            return bt.AXDescription == A_Message
          end)
          return Callback.Enabled(button)
        else
          local button = getc(towinui(win), AX.Button, A_Message)
          if Callback.Enabled(button) then
            return Callback.Clickable(getc(button, AX.Button, 1))
          end
        end
      end,
      fn = Callback.PressClick
    },
    ["openInDefaultBrowser"] = {
      message = function(win)
        if appVer(win) < "4" then
          return T("Open in Default Browser", win)
        else
          local exBundleID = "com.tencent.flue.WeChatAppEx"
          return localizedString("Open in default browser", exBundleID,
                                 { locale = A_AppLocale })
        end
      end,
      windowFilter = WeChat.WF.AppExWeb,
      condition = function(win)
        local app = win:application()
        if appVer(app) < "4" then return true end
        local button = A_WinBuf.closeWebButton
        if button.AXRole == AX.PopUpButton then
          local tabs = getc(towinui(win), AX.Group, 1,
              AX.Group, 1, AX.Group, 1, AX.Group, 2,
              AX.TabGroup, 1, AX.ScrollArea, 1,  AX.RadioButton)
          local tab = tfind(tabs or {}, function(rb) return rb.AXValue == true end)
          if tab then
            local exBundleID = "com.tencent.flue.WeChatAppEx"
            if tab.AXDescription
                == localizedString("Mini-Program", exBundleID,
                                   { locale = 'zh-Hans' }) then
              return false
            end
          end
        end
        return true, button
      end,
      fn = function(button, win)
        if win == nil then
          win = button
          local frame = win:frame()
          local position = uioffset(frame, { frame.w - 60, 23 })
          leftClickAndRestore(position, win)
          return
        end

        Callback.Press(button)
        if button and button.AXRole == AX.PopUpButton then
          local menuWin, totalDelay = nil, 0
          repeat
            menuWin = tfind(getc(toappui(win:application()), AX.Window), function(win)
              return #win ==  1 and #win[1] == 1 and win[1][1].AXRole == AX.Menu
            end)
            if menuWin == nil then
              hs.timer.usleep(0.05 * 1000000)
              totalDelay = totalDelay + 0.05
            end
          until menuWin or totalDelay > 1
          local menuItems = getc(menuWin, AX.Group, 1, AX.Menu, 1, AX.MenuItem)
          if menuItems and #menuItems > 0 then
            local menuItem = tfind(menuItems, function(item)
              return item.AXDescription == A_Message
            end)
            if menuItem then
              Callback.Press(menuItem)
            else
              hs.eventtap.keyStroke('', 'escape', nil, win:application())
            end
          end
        end
      end
    },
    ["remapPreviousTab"] = {
      message = function()
        local exBundleID = "com.tencent.flue.WeChatAppEx"
        local params = { locale = A_AppLocale }
        return localizedString("Select Previous Tab", exBundleID, params)
      end,
      enabled = Version.GreaterEqual("4"),
      windowFilter = WeChat.WF.AppEx,
      condition = function(win)
        local menuItemPath = A_WinBuf.selectMenuItemPath
        local menuItem = win:application():findMenuItem(menuItemPath)
        if Callback.Enabled(menuItem) then
          return true, menuItemPath
        end
      end,
      repeatable = true,
      fn = Callback.Select
    },
    ["closeWindow"] = {
      message = TC('Close Window'),
      enabled = Version.GreaterEqual("4"),
      windowFilter = WeChat.WF.AppExSingleTab,
      condition = function(win)
        local menuItemPath = A_WinBuf.closeWindowMenuItemPath
        local menuItem = win:application():findMenuItem(menuItemPath)
        return menuItem ~= nil and menuItem.enabled, menuItemPath
      end,
      fn = Callback.Select
    },
    ["confirm"] = {
      message = function()
        local bt = A_WinBuf.confirmButton
        return bt.AXTitle ~= "" and bt.AXTitle or bt.AXDescription
      end,
      enabled = Version.Between("4", "4.0.6"),
      deleteOnDisable = true,
      windowFilter = WeChat.WF.Confirm,
      condition = function()
        return Callback.Clickable(A_WinBuf.confirmButton)
      end,
      fn = Callback.Click
    },
    ["confirmSelectingContacts"] = {
      message = function(win)
        local winUI = towinui(win)
        local listFound = false
        for i=#winUI,1,-1 do
          if not listFound then
            listFound = winUI[i].AXRole == AX.List
          elseif winUI[i].AXRole == AX.Button then
            A_WinBuf.confirmButton = winUI[i]
            return winUI[i].AXTitle
          end
        end
      end,
      enabled = Version.Between("4", "4.0.6"),
      windowFilter = WeChat.WF.SelectContacts,
      condition = function(win)
        local bt = A_WinBuf.confirmButton
        if Callback.Enabled(bt) then
          -- `WeChat` accessibility bug
          local winUI = towinui(win)
          local ref = getc(winUI, AX.List, 1)
          if ref.AXPosition.x < winUI.AXPosition.x then
            return Callback.Clickable(winUI, {
              bt.AXPosition.x - ref.AXPosition.x + bt.AXSize.w / 2,
              winUI.AXSize.h - 13 - bt.AXSize.h / 2
                  - (ref.AXPosition.y + ref.AXSize.h - bt.AXPosition.y - bt.AXSize.h)
            })
          else
            return Callback.Clickable(bt)
          end
        end
      end,
      fn = Callback.Click
    },
    ["confirmAll"] = {
      message = TC("Confirm"),
      enabled = Version.GreaterEqual("4.0.6"),
      windowFilter = WeChat.WF.ConfirmDefault,
      condition = function(win)
        local frame = win:frame()
        return Callback.Clickable(towinui(win), { frame.w - 80, frame.h - 47 })
      end,
      fn = Callback.Click
    }
  },

  ["com.tencent.qq"] = {
    ["switchUIMode"] = {
      message = "切换界面模式",
      enabled = Version.GreaterEqual("6.9.82"),
      windowFilter = { allowTitles = "^QQ$" },
      condition = function(win)
        local webarea = getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Group, 1, AX.Group, 1, AX.WebArea, 1)
        local image = getc(webarea, AX.Group, 1,
            AX.Group, 2, AX.Group, 1, nil, 1, AX.Image, 1)
        if appVer(win) >= "6.9.83" then
          return Callback.Clickable(image)
        else
          return image ~= nil, image
        end
      end,
      fn = Callback.PressClick
    }
  },

  ["com.tencent.QQMusicMac"] =
  {
    ["back"] = {
      message = "后退",
      windowFilter = {
        allowRoles = AX.StandardWindow,
        allowTitles = "^$"
      },
      condition = function(win)
        local titleBar
        if appVer(win) < "10.3.0" then
          local appUI = toappui(win:application())
          local frame = win:frame()
          titleBar = appUI:elementAtPosition(uioffset(frame, { 100, 10 }))
        else
          titleBar = getc(towinui(win), AX.Unknown, 3)
          if titleBar == nil then return false end
        end
        for _, button in ipairs(titleBar) do
          if button.AXHelp == A_Message then
            return Callback.Clickable(button)
          end
        end
        return false
      end,
      repeatable = true,
      fn = Callback.ClickAndHold(0.1)
    },
    ["forward"] = {
      message = "前进",
      windowFilter = {
        allowRoles = AX.StandardWindow,
        allowTitles = "^$"
      },
      condition = function(win)
        local titleBar
        if appVer(win) < "10.3.0" then
          local appUI = toappui(win:application())
          local frame = win:frame()
          titleBar = appUI:elementAtPosition(uioffset(frame, { 100, 10 }))
        else
          titleBar = getc(towinui(win), AX.Unknown, 3)
          if titleBar == nil then return false end
        end
        for _, button in ipairs(titleBar) do
          if button.AXHelp == A_Message then
            return Callback.Clickable(button)
          end
        end
        return false
      end,
      repeatable = true,
      fn = Callback.ClickAndHold(0.1)
    },
    ["refresh"] = {
      message = "刷新",
      windowFilter = {
        allowRoles = AX.StandardWindow,
        allowTitles = "^$"
      },
      condition = function(win)
        local titleBar
        if appVer(win) < "10.3.0" then
          local appUI = toappui(win:application())
          local frame = win:frame()
          titleBar = appUI:elementAtPosition(uioffset(frame, { 100, 10 }))
        else
          titleBar = getc(towinui(win), AX.Unknown, 3)
          if titleBar == nil then return false end
        end
        local refreshButton, searchButton
        for _, button in ipairs(titleBar) do
          if button.AXHelp == A_Message then
            refreshButton = button
          elseif button.AXHelp == nil then
            searchButton = button
          end
        end
        if refreshButton ~= nil and searchButton ~= nil
            and refreshButton.AXPosition.x ~= searchButton.AXPosition.x then
          return Callback.Clickable(refreshButton)
        end
      end,
      fn = Callback.ClickAndHold(0.1)
    },
    ["playBarCloseSingleSong"] = {
      message = TC("Close Window"),
      windowFilter = {
        allowRoles = AX.Unknown,
        fn = function(win)
          local mWin = win:application():mainWindow()
          local fFrame, mFrame = win:frame(), mWin:frame()
          return win:id() ~= mWin:id()
              and fFrame.x == mFrame.x and fFrame.y == mFrame.y
              and fFrame.w == mFrame.w and fFrame.h == mFrame.h
        end
      },
      fn = function(win)
        local buttons = getc(towinui(win), AX.Button)
        buttons[#buttons - 2]:performAction(AX.Press)
      end
    }
  },

  ["com.tencent.tenvideo"] =
  {
    ["openRecent"] = {
      message = "最近打开",
      fn = function(app)
        -- in early version of macOS there was a duplicated menu bar item '文件'
        -- which does not have menu items. So we have to manually filter it out
        local menuBarItems = getBufferedMenuBarItems(app) or {}
        local menuBarItem = tfind(menuBarItems, function(item)
          return #item > 0 and item.AXTitle == '文件'
        end)
        local menuItem = getc(menuBarItem, AX.Menu, 1, AX.MenuItem, A_Message)
        if menuItem ~= nil then
          Callback.Press(menuBarItem)
          Callback.Press(menuItem)
        end
      end
    },
    ["channel1"] = {
      message = QQLive.channelName(1),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(1),
      fn = Callback.Click
    },
    ["channel2"] = {
      message = QQLive.channelName(2),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(2),
      fn = Callback.Click
    },
    ["channel3"] = {
      message = QQLive.channelName(3),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(3),
      fn = Callback.Click
    },
    ["channel4"] = {
      message = QQLive.channelName(4),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(4),
      fn = Callback.Click
    },
    ["channel5"] = {
      message = QQLive.channelName(5),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(5),
      fn = Callback.Click
    },
    ["channel6"] = {
      message = QQLive.channelName(6),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(6),
      fn = Callback.Click
    },
    ["channel7"] = {
      message = QQLive.channelName(7),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(7),
      fn = Callback.Click
    },
    ["channel8"] = {
      message = QQLive.channelName(8),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(8),
      fn = Callback.Click
    },
    ["channel9"] = {
      message = QQLive.channelName(9),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(9),
      fn = Callback.Click
    },
    ["channel10"] = {
      message = QQLive.channelName(10),
      windowFilter = QQLive.WF.Main,
      condition = QQLive.getChannel(10),
      fn = Callback.Click
    }
  },

  ["com.tencent.meeting"] =
  {
    ["preferences"] = {
      message = T("Preferences"),
      fn = function(app)
        app:selectMenuItem{ app:name(), A_Message }
        local observer = registerNavigationForSettingsToolbar(app, false)
        if observer == nil then return end
        local win = app:focusedWindow()
        if win == nil then return end
        local wid = win:id()
        local key
        key = ExecContinuouslyQuick(function()
          local w = hs.window.get(wid)
          if w == nil or win:application() ~= app then
            StopExecContinuously(key)
            local callback = observer:callback()
            callback(observer, towinui(win), uinotifications.uIElementDestroyed)
          end
        end)
      end
    }
  },

  ["com.bytedance.douyin.desktop"] =
  {
    ["settings"] = {
      message = "设置",
      fn = function(app)
        app:selectMenuItem{ app:name(), A_Message }
      end
    },
    ["showMainWindow"] = {
      message = "抖音窗口",
      fn = function(app)
        app:selectMenuItem{ "窗口", A_Message }
      end
    }
  },

  ["com.tencent.LemonMonitor"] =
  {
    ["closeWindow"] = {
      mods = "", key = "Escape",
      message = TC("Close Window"),
      windowFilter = {
        allowRoles = AX.Unknown
      },
      background = true,
      nonFrontmost = true,
      fn = function(win)
        clickRightMenuBarItem(win:application(), {}, "click")
      end
    }
  },

  ["com.nektony.App-Cleaner-SIII"] =
  {
    ["uninstall"] = {
      message = T('Uninstall'),
      condition = AppCleanerUninstaller.buttonValid('Uninstall'),
      fn = Callback.Press
    },
    ["remove"] = {
      message = T('Remove'),
      condition = AppCleanerUninstaller.buttonValid('Remove'),
      fn = Callback.Press
    },
    ["enable"] = {
      message = T('Enable'),
      condition = AppCleanerUninstaller.buttonValid('Enable'),
      fn = Callback.Press
    },
    ["disable"] = {
      message = T('Disable'),
      condition = AppCleanerUninstaller.buttonValid('Disable'),
      fn = Callback.Press
    },
    ["update"] = {
      message = T('Update'),
      condition = AppCleanerUninstaller.buttonValid('Update'),
      fn = Callback.Press
    },
    ["launchApp"] = {
      message = T('Launch App'),
      enabled = Version.GreaterEqual("8.6"),
      condition = AppCleanerUninstaller.buttonValid('Launch App'),
      fn = Callback.Press
    },
    ["confirmRemove"] = {
      message = T('Remove'),
      condition = AppCleanerUninstaller.confirmButtonValid('Remove'),
      fn = Callback.DoubleClick
    },
    ["confirmUpdate"] = {
      message = T('Update'),
      condition = AppCleanerUninstaller.confirmButtonValid('Update'),
      fn = Callback.DoubleClick
    },
    ["confirmRetry"] = {
      message = T('Retry'),
      condition = AppCleanerUninstaller.confirmButtonValid('Retry'),
      fn = Callback.DoubleClick
    }
  },

  ["com.nektony.App-Cleaner-SIIICn"] =
  {
    ["remove"] = {
      message = T('Remove_Button_Title'),
      condition = AppCleanerUninstaller.buttonValid('Remove_Button_Title'),
      fn = Callback.Press
    },
    ["enable"] = {
      message = T('EnableMenuItemTitle'),
      condition = AppCleanerUninstaller.buttonValid('EnableMenuItemTitle'),
      fn = Callback.Press
    },
    ["disable"] = {
      message = T('DisableMenuItemTitle'),
      condition = AppCleanerUninstaller.buttonValid('DisableMenuItemTitle'),
      fn = Callback.Press
    },
    ["update"] = {
      message = T('UpdateButtonTitle'),
      condition = AppCleanerUninstaller.buttonValid('UpdateButtonTitle'),
      fn = Callback.Press
    },
    ["launchApp"] = {
      message = T('LaunchAppButtonTitle'),
      enabled = Version.GreaterEqual("8.6"),
      condition = AppCleanerUninstaller.buttonValid('LaunchAppButtonTitle'),
      fn = Callback.Press
    },
    ["confirmRemove"] = {
      message = T('PartialRemove_Remove'),
      condition = AppCleanerUninstaller.confirmButtonValid('PartialRemove_Remove'),
      fn = Callback.DoubleClick
    },
    ["confirmUpdate"] = {
      message = T('UpdateButtonTitle'),
      condition = AppCleanerUninstaller.confirmButtonValid('UpdateButtonTitle'),
      fn = Callback.DoubleClick
    },
    ["confirmRetry"] = {
      message = T('PartialRemove_Retry'),
      condition = AppCleanerUninstaller.confirmButtonValid('PartialRemove_Retry'),
      fn = Callback.DoubleClick
    }
  },

  ["com.charliemonroe.Downie-4"] =
  {
    ["openRecent"] = {
      message = T("Show History"),
      condition = MenuItem.isEnabled{ "Window", "Show History" },
      fn = Callback.Select
    }
  },

  ["barrier"] =
  {
    ["toggleBarrier"] = {
      message = "Toggle Barrier",
      background = true,
      fn = function(app)
        local appUI = toappui(app)
        local menu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1, AX.Menu, 1)
        if menu == nil then
          local invoked = clickRightMenuBarItem(app)
          if not invoked then return end
          menu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1, AX.Menu, 1)
        end
        local locale = applicationLocale(app:bundleID())
        local title = T("&Start", app, { locale = locale })
        assert(type(title) == 'string')
        title = title:gsub("%(&%a%)", ""):gsub("&", "")
        local start = getc(menu, AX.MenuItem, title)
        if start == nil then return end
        if start.AXEnabled then
          Callback.Press(start)
          hs.alert("Barrier started")
        else
          title = T("S&top", app, { locale = locale })
          assert(type(title) == 'string')
          title = title:gsub("%(&%a%)", ""):gsub("&", "")
          local stop = getc(menu, AX.MenuItem, title)
          if stop == nil then return end
          Callback.Press(stop)
          hs.alert("Barrier stopped")
        end
      end,
      onLaunch = function(app)
        if app:focusedWindow() == nil then
          hs.alert("Error occurred")
        else
          local winUI = towinui(app:focusedWindow())
          local title = Barrier.localizedString("&Start", app)
          local start = getc(winUI, AX.Button, title)
          if start == nil then return end
          Callback.Press(start)
          hs.alert("Barrier started")
          hs.timer.doAfter(0.5, function()
            local close = getc(winUI, AX.Button, 4)
            if close == nil then return end
            Callback.Press(close)
          end)
        end
      end
    },
    ["changeSettings"] = {
      message = Barrier.localizedMessage("Change &Settings"),
      condition = function(app)
        local menuBarItems = getMenuBarItems(app, true) or {}
        local menuBarItem = tfind(menuBarItems, function(item)
          return item.AXTitle == "Barrier"
        end)
        local menuItem = getc(menuBarItem, AX.Menu, 1, AX.MenuItem, A_Message)
        return Callback.Enabled(menuItem)
      end,
      fn = Callback.Press
    },
    ["reload"] = {
      message = Barrier.localizedMessage("&Reload"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Reload", win)
        local reload = getc(winUI, AX.Button, title)
        return reload ~= nil and #reload:actionNames() > 0, reload
      end,
      fn = Callback.Press
    },
    ["start"] = {
      message = Barrier.localizedMessage("&Start"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Start", win)
        local start = getc(winUI, AX.Button, title)
        return start ~= nil and #start:actionNames() > 0, start
      end,
      fn = Callback.Press
    },
    ["stop"] = {
      message = Barrier.localizedMessage("&Stop"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Stop", win)
        local stop = getc(winUI, AX.Button, title)
        return stop ~= nil and #stop:actionNames() > 0, stop
      end,
      fn = Callback.Press
    },
    ["serverMode"] = {
      message = Barrier.localizedMessage("&Server (share this computer's mouse and keyboard)"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      fn = function(win)
        local winUI = towinui(win)
        local server = getc(winUI, AX.CheckBox, 1)
        if server then Callback.Press(server) end
      end
    },
    ["clientMode"] = {
      message = Barrier.localizedMessage("&Client (use another computer's mouse and keyboard):"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      fn = function(win)
        local winUI = towinui(win)
        local client = getc(winUI, AX.CheckBox, 2)
        if client then Callback.Press(client) end
      end
    },
    ["configureInteractively"] = {
      message = Barrier.localizedMessage("Configure interactively:"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("Configure interactively:", win)
        local configure = getc(winUI, AX.CheckBox, 1, AX.RadioButton, title)
        return configure ~= nil and #configure:actionNames() > 0, configure
      end,
      fn = Callback.Press
    },
    ["useExistingConfiguration"] = {
      message = Barrier.localizedMessage("Use existing configuration:"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("Use existing configuration:", win)
        local configure = getc(winUI, AX.CheckBox, 1, AX.RadioButton, title)
        return configure ~= nil and #configure:actionNames() > 0, configure
      end,
      fn = Callback.Press
    },
    ["configureServer"] = {
      message = Barrier.localizedMessage("&Configure Server..."),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Configure Server...", win)
        local configure = getc(winUI, AX.CheckBox, 1, AX.Button, title)
        return configure ~= nil and #configure:actionNames() > 0, configure
      end,
      fn = Callback.Press
    },
    ["configurationFile"] = {
      message = Barrier.localizedMessage("&Configuration file:"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Configuration file:", win)
        local textField = getc(winUI, AX.CheckBox, 1, AX.TextField, title)
        return textField ~= nil and #textField:actionNames() > 0, textField
      end,
      fn = function(textField)
        textField:performAction(AX.Raise)
      end
    },
    ["browse"] = {
      message = Barrier.localizedMessage("&Browse..."),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local title = Barrier.localizedString("&Browse...", win)
        local browse = getc(winUI, AX.CheckBox, 1, AX.Button, title)
        return browse ~= nil and #browse:actionNames() > 0, browse
      end,
      fn = Callback.Press
    },
    ["autoConfig"] = {
      message = Barrier.localizedMessage("Auto config"),
      windowFilter = {
        allowTitles = "^Barrier$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local autoconfig = getc(winUI, AX.CheckBox, 2, AX.CheckBox, A_Message)
        return autoconfig ~= nil and #autoconfig:actionNames() > 0, autoconfig
      end,
      fn = function(checkbox, win)
        local toSpecify = checkbox.AXValue == 1
        Callback.Press(checkbox)
        if toSpecify then
          local title = Barrier.localizedString("&Server IP:", win)
          local textField = getc(towinui(win), AX.CheckBox, 2, AX.TextField, title)
          if textField then
            textField:performAction(AX.Raise)
          end
        end
      end
    },
    ["showMainWindowFromMB"] = {
      message = TMB("Show"),
      menubarFilter = { allowIndices =  1 },
      condition = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        return Callback.Enabled(menuItem)
      end,
      fn = Callback.Press
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
  },

  ["com.objective-see.lulu.app"] =
  {
    ["allowConnection"] = {
      message = "Allow Connection",
      enabled = Version.LessThan("2.9.1"),
      windowFilter = {
        allowTitles = "^LuLu Alert$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, "Allow")
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["blockConnection"] = {
      message = "Block Connection",
      enabled = Version.LessThan("2.9.1"),
      windowFilter = {
        allowTitles = "^LuLu Alert$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, "Block")
        return button ~= nil, button
      end,
      fn = Callback.Press
    }
  },

  ["com.runningwithcrayons.Alfred-Preferences"] =
  {
    ["saveInSheet"] = {
      message = "Save",
      windowFilter = {
        allowSheet = true,
        fn = function(win)
          local winUI = towinui(win)
          local button = getc(winUI, AX.Button, "Save")
          return button ~= nil
        end,
      },
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, A_Message)
        return Callback.Enabled(button)
      end,
      fn = Callback.Press
    }
  },

  ["com.surteesstudios.Bartender"] =
  {
    ["toggleMenuBar"] = {
      message = T("Show menu bar item"),
      enabled = function(app)
        local appVersion = appVer(app)
        return appVersion < "6" or appVersion >= "6.1.1"
      end,
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        hs.osascript.applescript(strfmt([[
          tell application id "%s" to toggle bartender
        ]], app:bundleID()))
      end
    },
    ["click1stBartenderBarItem"] = {
      message = Bartender.barItemTitle(1),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(1)
    },
    ["rightClick1stBartenderBarItem"] = {
      message = Bartender.barItemTitle(1, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(1, true)
    },
    ["click2ndBartenderBarItem"] = {
      message = Bartender.barItemTitle(2),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(2)
    },
    ["rightClick2ndBartenderBarItem"] = {
      message = Bartender.barItemTitle(2, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(2, true)
    },
    ["click3rdBartenderBarItem"] = {
      message = Bartender.barItemTitle(3),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(3)
    },
    ["rightClick3rdBartenderBarItem"] = {
      message = Bartender.barItemTitle(3, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(3, true)
    },
    ["click4thBartenderBarItem"] = {
      message = Bartender.barItemTitle(4),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(4)
    },
    ["rightClick4thBartenderBarItem"] = {
      message = Bartender.barItemTitle(4, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(4, true)
    },
    ["click5thBartenderBarItem"] = {
      message = Bartender.barItemTitle(5),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(5)
    },
    ["rightClick5thBartenderBarItem"] = {
      message = Bartender.barItemTitle(5, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(5, true)
    },
    ["click6thBartenderBarItem"] = {
      message = Bartender.barItemTitle(6),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(6)
    },
    ["rightClick6thBartenderBarItem"] = {
      message = Bartender.barItemTitle(6, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(6, true)
    },
    ["click7thBartenderBarItem"] = {
      message = Bartender.barItemTitle(7),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(7)
    },
    ["rightClick7thBartenderBarItem"] = {
      message = Bartender.barItemTitle(7, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(7, true)
    },
    ["click8thBartenderBarItem"] = {
      message = Bartender.barItemTitle(8),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(8)
    },
    ["rightClick8thBartenderBarItem"] = {
      message = Bartender.barItemTitle(8, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(8, true)
    },
    ["click9thBartenderBarItem"] = {
      message = Bartender.barItemTitle(9),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(9)
    },
    ["rightClick9thBartenderBarItem"] = {
      message = Bartender.barItemTitle(9, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(9, true)
    },
    ["click10thBartenderBarItem"] = {
      message = Bartender.barItemTitle(10),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(10)
    },
    ["rightClick10thBartenderBarItem"] = {
      message = Bartender.barItemTitle(10, true),
      windowFilter = Bartender.WF.Bar,
      background = true,
      fn = Bartender.clickBarItem(10, true)
    },
    ["searchMenuBar"] = {
      message = "Search Menu Bar",
      enabled = function(app)
        local appVersion = appVer(app)
        return appVersion < "6" or appVersion >= "6.1.1"
      end,
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        hs.osascript.applescript(strfmt([[
          tell application id "%s" to quick search
        ]], app:bundleID()))
      end
    },
    ["keyboardNavigate"] = {
      message = "Navigate Menu Bar",
      kind = HK.MENUBAR,
      background = true,
      enabled = function(app)
        if appVer(app) >= "6" then return false end
        -- the property update in command line is not working
        local _, ok = hs.execute(strfmt(
            "defaults read '%s' hotkeyKeyboardNav", app:bundleID()))
        return ok
      end,
      fn = function(app)
        local output = hs.execute(strfmt(
            "defaults read '%s' hotkeyKeyboardNav", app:bundleID()))
        local spec = strsplit(output, "\n")
        local mods = spec[4]:match("modifierFlags = (%d+)")
        local key = spec[3]:match("keyCode = (%d+)")
        mods, key = parsePlistKeyBinding(mods, key)
        safeGlobalKeyStroke(mods, key)
      end
    },
    ["toggleSidebar"] = {
      message = TC("Show Sidebar"),
      enabled = Version.GreaterEqual("6"),
      condition = function(app)
        return app:focusedWindow() ~= nil, app:focusedWindow()
      end,
      fn = function(win)
        local button = getc(towinui(win),
            AX.Toolbar, 1, AX.Button, 1, AX.Button, 1)
        if button then Callback.Press(button) end
      end
    },
    ["view1"] =
    {
      message = Bartender.sidebarItemTitle(1),
      windowFilter = Bartender.WF.Main,
      fn = Bartender.clickSidebarItem(1)
    },
    ["view2"] =
    {
      message = Bartender.sidebarItemTitle(2),
      windowFilter = Bartender.WF.Main,
      fn = Bartender.clickSidebarItem(2)
    },
    ["view3"] =
    {
      message = Bartender.sidebarItemTitle(3),
      windowFilter = Bartender.WF.Main,
      fn = Bartender.clickSidebarItem(3)
    },
    ["view4"] =
    {
      message = Bartender.sidebarItemTitle(4),
      windowFilter = Bartender.WF.Main,
      fn = Bartender.clickSidebarItem(4)
    },
    ["view5"] =
    {
      message = Bartender.sidebarItemTitle(5),
      windowFilter = Bartender.WF.Main,
      fn = Bartender.clickSidebarItem(5)
    },
    ["view6"] =
    {
      message = Bartender.sidebarItemTitle(6),
      windowFilter = Bartender.WF.Main,
      fn = Bartender.clickSidebarItem(6)
    },
    ["view7"] =
    {
      message = Bartender.sidebarItemTitle(7),
      windowFilter = Bartender.WF.Main,
      fn = Bartender.clickSidebarItem(7)
    },
    ["view8"] =
    {
      message = Bartender.sidebarItemTitle(8),
      windowFilter = Bartender.WF.Main,
      fn = Bartender.clickSidebarItem(8)
    },
    ["view9"] =
    {
      message = Bartender.sidebarItemTitle(9),
      windowFilter = Bartender.WF.Main,
      fn = Bartender.clickSidebarItem(9)
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigUpdated("minimize",
        { enabled = Version.LessThan("6") }),
    ["quit"] = specialCommonHotkeyConfigs["quit"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
  },

  ["com.HyperartFlow.Barbee"] =
  {
    ["toggleMenuBar"] = {
      message = "Toggle Menu Bar",
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        local barShown = false
        for _, e in ipairs(getc(toappui(app), AX.Window)) do
          if #e == 1 and e[1].AXRole == AX.Group
              and #e[1] == #(getc(e[1], AX.Button) or {}) then
            barShown = true
          end
        end
        if barShown then
          hs.osascript.applescript(strfmt([[
            tell application id "%s" to hide items
          ]], app:bundleID()))
        else
          hs.osascript.applescript(strfmt([[
            tell application id "%s" to show items
          ]], app:bundleID()))
        end
      end
    },
    ["toggleSidebar"] = {
      message = TC("Show Sidebar"),
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local button = tfind(getc(towinui(app:focusedWindow()),
                                  AX.Toolbar, 1, AX.Button) or {},
            function(bt) return bt.AXDescription == "Sidebar" end)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
    ["click1stBarbeeBarItem"] = {
      message = Barbee.barItemTitle(1),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(1)
    },
    ["click2ndBarbeeBarItem"] = {
      message = Barbee.barItemTitle(2),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(2)
    },
    ["click3rdBarbeeBarItem"] = {
      message = Barbee.barItemTitle(3),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(3)
    },
    ["click4thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(4),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(4)
    },
    ["click5thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(5),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(5)
    },
    ["click6thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(6),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(6)
    },
    ["click7thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(7),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(7)
    },
    ["click8thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(8),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(8)
    },
    ["click9thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(9),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(9)
    },
    ["click10thBarbeeBarItem"] = {
      message = Barbee.barItemTitle(10),
      windowFilter = Barbee.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Barbee.clickBarItem(10)
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["quit"] = specialCommonHotkeyConfigs["quit"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
  },

  ["com.jordanbaird.Ice"] =
  {
    ["click1stIceBarItem"] = {
      message = Ice.barItemTitle(1),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(1)
    },
    ["click2ndIceBarItem"] = {
      message = Ice.barItemTitle(2),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(2)
    },
    ["click3rdIceBarItem"] = {
      message = Ice.barItemTitle(3),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(3)
    },
    ["click4thIceBarItem"] = {
      message = Ice.barItemTitle(4),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(4)
    },
    ["click5thIceBarItem"] = {
      message = Ice.barItemTitle(5),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(5)
    },
    ["click6thIceBarItem"] = {
      message = Ice.barItemTitle(6),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(6)
    },
    ["click7thIceBarItem"] = {
      message = Ice.barItemTitle(7),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(7)
    },
    ["click8thIceBarItem"] = {
      message = Ice.barItemTitle(8),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(8)
    },
    ["click9thIceBarItem"] = {
      message = Ice.barItemTitle(9),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(9)
    },
    ["click10thIceBarItem"] = {
      message = Ice.barItemTitle(10),
      windowFilter = Ice.WF.Bar,
      background = true,
      nonFrontmost = true,
      fn = Ice.clickBarItem(10)
    },
    ["view1"] = {
      message = Ice.sidebarItemTitle(1),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(1)
    },
    ["view2"] = {
      message = Ice.sidebarItemTitle(2),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(2)
    },
    ["view3"] = {
      message = Ice.sidebarItemTitle(3),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(3)
    },
    ["view4"] = {
      message = Ice.sidebarItemTitle(4),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(4)
    },
    ["view5"] = {
      message = Ice.sidebarItemTitle(5),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(5)
    },
    ["view6"] = {
      message = Ice.sidebarItemTitle(6),
      windowFilter = Ice.WF.Main,
      fn = Ice.clickSidebarItem(6)
    }
  },

  ["cn.better365.iBar"] =
  {
    ["toggleMenuBar"] = {
      message = "Toggle Menu Bar",
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        local icon = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem, 1)
        local isAdvancedMode = hs.execute(strfmt([[
          defaults read "%s" advancedMode | tr -d '\n'
        ]], app:bundleID()))
        if isAdvancedMode ~= "1" then
          local position = hs.mouse.absolutePosition()
          mouseMove(uioffset(icon, {-10, 10}))
          hs.timer.doAfter(0.2, function()
            mouseMove(uioffset(icon, {-20, 10}))
            hs.timer.doAfter(0.2, function()
              mouseMove(position)
            end)
          end)
        else
          leftClickAndRestore(icon, app)
        end
      end
    },
    ["click1stiBarItem"] = {
      message = iBar.barItemTitle(1),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(1)
    },
    ["click2ndiBarItem"] = {
      message = iBar.barItemTitle(2),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(2)
    },
    ["click3rdiBarItem"] = {
      message = iBar.barItemTitle(3),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(3)
    },
    ["click4thiBarItem"] = {
      message = iBar.barItemTitle(4),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(4)
    },
    ["click5thiBarItem"] = {
      message = iBar.barItemTitle(5),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(5)
    },
    ["click6thiBarItem"] = {
      message = iBar.barItemTitle(6),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(6)
    },
    ["click7thiBarItem"] = {
      message = iBar.barItemTitle(7),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(7)
    },
    ["click8thiBarItem"] = {
      message = iBar.barItemTitle(8),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(8)
    },
    ["click9thiBarItem"] = {
      message = iBar.barItemTitle(9),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(9)
    },
    ["click10thiBarItem"] = {
      message = iBar.barItemTitle(10),
      windowFilter = iBar.WF.Bar,
      background = true,
      fn = iBar.clickBarItem(10)
    }
  },

  ["com.app.menubarx"] =
  {
    ["toggleMenuBarX"] = {
      message = function(app)
        return T("Toggle MenubarX:", app):gsub(":", ""):gsub("：", "")
      end,
      kind = HK.MENUBAR,
      background = true,
      fn = function(app)
        local appid = app:bundleID()
        local output = hs.execute(strfmt([[
          defaults read '%s' KeyboardShortcuts_toggleX | tr -d '\n'
        ]], appid))
        if output == "0" then
          local spec = KeybindingConfigs.hotkeys[appid]["toggleMenuBarX"]
          local mods, key = dumpPlistKeyBinding(1, spec.mods, spec.key)
          hs.execute(strfmt([[
            defaults write '%s' KeyboardShortcuts_toggleX -string \
            '{"carbonKeyCode":%d,"carbonModifiers":%d}'
          ]], appid, key, mods))
          app:kill()
          hs.timer.doAfter(1, function()
            hs.execute(strfmt("open -g -b '%s'", appid))
            hs.timer.doAfter(1, function()
              safeGlobalKeyStroke(spec.mods, spec.key)
            end)
          end)
        else
          local json = hs.json.decode(output)
          local mods, key = parsePlistKeyBinding(
              json["carbonModifiers"], json["carbonKeyCode"])
          if mods == nil or key == nil then return end
          safeGlobalKeyStroke(mods, key)
        end
      end
    }
  },

  ["com.gaosun.eul"] =
  {
    ["showSystemStatus"] = {
      message = "Show System Status",
      kind = HK.MENUBAR,
      background = true,
      fn = clickRightMenuBarItem
    },
    ["preferencesFromMB"] = {
      message = TMB("Preferences"),
      menubarFilter = { allowTitles = 'eul' },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local button = getc(menu, AX.MenuItem, 1, AX.Group, 1,
            AX.StaticText, title)
        local app = getAppFromDescendantElement(menu)
        leftClickAndRestore(button, app, 0.2)
      end
    }
  },

  ["whbalzac.Dongtaizhuomian"] =
  {
    ["invokeInAppScreenSaver"] = {
      message = T("In-app Screensaver", { localeFile = "HotkeyWindowController" }),
      background = true,
      fn = function(app)
        clickRightMenuBarItem(app, A_Message)
      end
    },
    ["preferencesFromMB"] = {
      message = TMB("Preferences..."),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["pl.maketheweb.TopNotch"] =
  {
    ["toggleTopNotch"] = {
      message = "Toggle Top Notch",
      background = true,
      fn = function(app)
        local invoked = clickRightMenuBarItem(app)
        if not invoked then return end
        local appUI = toappui(app)
        hs.timer.doAfter(1, function()
          local switch = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1,
              AX.Popover, 1, AX.Group, 3, AX.Button, 1)
          if switch == nil then
            hs.timer.usleep(0.1 * 1000000)
            switch = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1,
                AX.Popover, 1, AX.Group, 3, AX.Button, 2)
          end
          local state = switch.AXValue
          Callback.Press(switch)
          if state == 'off' then
            hs.eventtap.keyStroke("", "Escape", nil, app)
          else
            hs.timer.doAfter(0.1, function()
              hs.eventtap.keyStroke("", "Space", nil, app)
            end)
          end
        end)
      end
    }
  },

  ["com.jetbrains.toolbox"] =
  {
    ["toggleJetbrainsToolbox"] = {
      message = "Toggle Jetbrains Toolbox",
      background = true,
      fn = focusOrHide
    }
  },

  ["com.mathpix.snipping-tool-noappstore"] =
  {
    ["OCRForLatex"] = {
      message = "OCR for LaTeX",
      background = true,
      fn = function(app)
        local appid = app:bundleID()
        local mods = hs.execute(strfmt(
            "defaults read '%s' getLatexHotKeyModifiersKey | tr -d '\\n'", appid))
        local key = hs.execute(strfmt(
            "defaults read '%s' getLatexHotKeyKey | tr -d '\\n'", appid))
        mods, key = parsePlistKeyBinding(mods, key)
        -- the property update in command line is overridden when app quits
        if mods == nil or key == nil then return end
        local enabled = hs.execute(strfmt(
            "defaults read '%s' getLatexShortcutEnabledKey | tr -d '\\n'", appid))
        if enabled == "0" then
          hs.execute(strfmt(
              "defaults write '%s' getLatexShortcutEnabledKey 1", appid))
          app:kill()
          hs.timer.doAfter(1, function()
            hs.execute(strfmt("open -g -b '%s'", appid))
            hs.timer.doAfter(1, function()
              safeGlobalKeyStroke(mods, key)
            end)
          end)
        end
        safeGlobalKeyStroke(mods, key)
      end
    },
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["hidePopover"] = {
      mods = "", key = "Escape",
      message = "Hide Popover",
      windowFilter = {
        allowPopover = true
      },
      fn = function(win)
        clickRightMenuBarItem(win:application())
      end
    }
  },

  ["com.apple.TextInputMenuAgent"] =
  {
    ["openKeyboardSettingsFromMB"] = {
      message = function(menu)
        local menuItem = getc(menu, AX.MenuItem, -1)
        if menuItem then
          return displayName("com.apple.TextInputMenuAgent")
              .. ' >' .. getc(menu, AX.MenuItem, -1).AXTitle
        end
      end,
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local menuItem = getc(menu, AX.MenuItem, -1)
        Callback.Press(menuItem)
      end
    }
  },

  ["com.apple.Passwords"] = {
    ["search"] = {
      message = T("Search"),
      enabled = OS_VERSION >= OS.Tahoe,
      condition = function(app)
        if app:focusedWindow() == nil then return false end
        local searchButton = getc(towinui(app:focusedWindow()),
            AX.Toolbar, 1, AX.Group, -1, AX.TextField, 1, AX.Button, 1)
        return Callback.Clickable(searchButton)
      end,
      fn = Callback.Click
    }
  },

  ["com.apple.Passwords.MenuBarExtra"] =
  {
    ["showPasswordsDialog"] = {
      message = TB("com.apple.Passwords", "Show"),
      background = true,
      fn = clickRightMenuBarItem
    },
    ["newPassword"] = {
      message = T("New Password"),
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Group, 1, AX.Button, 'plus')
        return button ~= nil, button
      end,
      background = true,
      fn = Callback.Press
    },
    ["showAllPasswordsFromMB"] = {
      message = T("Show all passwords"),
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Group, 1, AX.Button, 'macwindow')
        return button ~= nil, button
      end,
      background = true,
      fn = Callback.Press
    },
    ["back"] = {
      message = T("Back"),
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = function(win)
        local winUI = towinui(win)
        local elem = getc(winUI, AX.Group, 1)[1]
        return elem.AXRole == AX.Button, elem
      end,
      background = true,
      fn = Callback.Press
    },
    ["copyUserName"] = {
      message = T("Copy User Name"),
      windowFilter = PasswordsMenuBarExtra.WF,
      background = true,
      condition = PasswordsMenuBarExtra.recordField("User Name"),
      fn = function(field, win)
        Callback.Click(field)
        clickRightMenuBarItem(win:application())
      end
    },
    ["copyPassword"] = {
      message = T("Copy Password"),
      windowFilter = PasswordsMenuBarExtra.WF,
      background = true,
      condition = PasswordsMenuBarExtra.recordField("Password"),
      fn = function(field, win)
        Callback.Click(field)
        clickRightMenuBarItem(win:application())
      end
    },
    ["copyVerificationCode"] = {
      message = function(win)
        local title = OS_VERSION >= OS.Tahoe and "Copy Code"
            or "Copy Verification Code"
        return T(title, win)
      end,
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordField(
          OS_VERSION >= OS.Tahoe and "Code" or "Verification Code"),
      background = true,
      fn = function(field, win)
        Callback.Click(field)
        clickRightMenuBarItem(win:application())
      end
    },
    ["copyWebsite"] = {
      message = T("Copy Website"),
      windowFilter = PasswordsMenuBarExtra.WF,
      background = true,
      condition = function(win)
        local fieldTitle = "Website"
        local winUI = towinui(win)

        if OS_VERSION >= OS.Tahoe:withMinor(1) then
          local fieldValues = getc(winUI, AX.Group, 1,
              AX.ScrollArea, 1, AX.Group, 1, AX.Button)
          if fieldValues == nil or #fieldValues == 0 then return false end
          local title = T(fieldTitle, win)
          for _, field in ipairs(fieldValues) do
            local desc = field.AXAttributedDescription
                and field.AXAttributedDescription:getString()
            if desc and desc:sub(1, #title) == title then
              if desc:sub(#title + 1, #title + 2) == ", " then
                return true, desc:sub(#title + 3)
              elseif desc:sub(#title + 1, #title + 3) == "、" then
                return true, desc:sub(#title + 4)
              end
            end
          end
          return false
        end
      end,
      fn = function(url, win)
        hs.pasteboard.setContents(url)
        clickRightMenuBarItem(win:application())
      end
    },
    ["record1"] = {
      message = "Record 1",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(1),
      background = true,
      fn = Callback.Click
    },
    ["record2"] = {
      message = "Record 2",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(2),
      background = true,
      fn = Callback.Click
    },
    ["record3"] = {
      message = "Record 3",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(3),
      background = true,
      fn = Callback.Click
    },
    ["record4"] = {
      message = "Record 4",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(4),
      background = true,
      fn = Callback.Click
    },
    ["record5"] = {
      message = "Record 5",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(5),
      background = true,
      fn = Callback.Click
    },
    ["record6"] = {
      message = "Record 6",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(6),
      background = true,
      fn = Callback.Click
    },
    ["record7"] = {
      message = "Record 7",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(7),
      background = true,
      fn = Callback.Click
    },
    ["record8"] = {
      message = "Record 8",
      windowFilter = PasswordsMenuBarExtra.WF,
      condition = PasswordsMenuBarExtra.recordPosition(8),
      background = true,
      fn = Callback.Click
    }
  },

  ["com.apple.weather.menu"] = {
    ["openWeatherFromMB"] = {
      message = T("Open Weather"),
      windowFilter = {
        allowRoles = AX.SystemDialog
      },
      background = true,
      fn = function(win)
        local button = getc(towinui(win), AX.Group, 1,
            AX.Group, 1, AX.Button, -1)
        if button then Callback.Press(button) end
      end
    },
    ["closeWindow"] = {
      mods = "", key = "Escape",
      message = TC("Close Window"),
      enabled = OS_VERSION < OS.Tahoe,
      windowFilter = {
        allowRoles = AX.SystemDialog
      },
      background = true,
      fn = function(win)
        local menuBarItem = getc(toappui(win:application()),
            AX.MenuBar, -1, AX.MenuBarItem, 1)
        if menuBarItem then
          Callback.Press(menuBarItem)
        end
      end
    }
  },

  ["com.macosgame.iwallpaper"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"]
  },

  ["org.pqrs.Karabiner-Elements.Settings"] =
  {
    ["toggleSidebar"] = {
      message = "Toggle Sidebar",
      condition = function(app)
        if app:focusedWindow() == nil then return end
        local button = getc(towinui(app:focusedWindow()), AX.Toolbar, 1, AX.Button, 1)
        if button == nil then return end
        local msg = button.AXDescription
        if msg == "Show Sidebar" or msg == "Hide Sidebar" then
          return true, button
        end
      end,
      fn = Callback.Press
    }
  },

  ["org.pqrs.Karabiner-Menu"] =
  {
    ["settingsFromMB"] = {
      message = TMB("org.pqrs.Karabiner-Elements.Settings", "Settings..."),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["org.pqrs.Karabiner-EventViewer"] =
  {
    ["toggleSidebar"] = {
      message = "Toggle Sidebar",
      condition = function(app)
        if app:focusedWindow() == nil then return end
        local button = getc(towinui(app:focusedWindow()), AX.Toolbar, 1, AX.Button, 1)
        if button == nil then return end
        local msg = button.AXDescription
        if msg == "Show Sidebar" or msg == "Hide Sidebar" then
          return true, button
        end
      end,
      fn = Callback.Press
    },
    ["closeWindow"] = specialCommonHotkeyConfigUpdated("closeWindow",
      { enabled = Version.LessThan("15.4") }
    ),
    ["minimize"] = specialCommonHotkeyConfigUpdated("minimize",
      { enabled = Version.LessThan("15.4") }
    ),
    ["hide"] = specialCommonHotkeyConfigUpdated("hide",
      { enabled = Version.LessThan("15.4") }
    ),
  },

  ["me.guillaumeb.MonitorControl"] =
  {
    ["preferencesFromMB"] = {
      message = TMB("Preferences…"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["com.pigigaldi.pock"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
    ["quit"] = specialCommonHotkeyConfigs["quit"]
  },

  ["com.mac.utility.screen.recorder"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
  },

  ["com.tencent.LemonUpdate"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"]
  },

  ["com.ameba.SwiftBar"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
    ["quit"] = specialCommonHotkeyConfigs["quit"]
  },

  ["com.apple.controlcenter"] =
  {
    ["closeWindow"] = {
      mods = "", key = "Escape",
      message = TC("Close Window"),
      enabled = OS_VERSION >= OS.Tahoe,
      windowFilter = {
        allowTitles = "^$",
        allowRoles = AX.SystemDialog,
        fn = function(win)
          local g = getc(towinui(win), AX.Group, 1, AX.Group, 1)
          return g and g.AXIdentifier
              and g.AXIdentifier:find('.liveActivity') ~= nil
        end
      },
      background = true,
      nonFrontmost = true,
      condition = function(win)
        local g = getc(towinui(win), AX.Group, 1, AX.Group, 1)
        if g == nil or g.AXIdentifier == nil then
          return false
        end
        local ident = g.AXIdentifier
        local s, e = ident:find('.liveActivity')
        if s == nil then return false end
        local prefix = ident:sub(1, e)
        local menuBarItems = getc(toappui(win:application()),
            AX.MenuBar, -1, AX.MenuBarItem)
        local menuBarItem = tfind(menuBarItems, function(item)
          return item.AXIdentifier and item.AXIdentifier:sub(1, e) == prefix
        end)
        return Callback.Clickable(menuBarItem)
      end,
      fn = Callback.Click
    }
  },

  ["com.apple.Image_Capture"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.VoiceOverUtility"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.DigitalColorMeter"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.CaptiveNetworkAssistant"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.CertificateAssistant"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.displaycalibrator"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"]
  },

  ["com.apple.DeskCam"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.apple.Chess"] =
  {
    ["openRecent"] = {
      message = T("Open Recent"),
      condition = MenuItem.isEnabled{ "Game", "Open Recent" },
      fn = Callback.Select
    },
  },

  ["com.apple.clock"] = {
    ["openRecent"] = {
      message = T("Start Recent Timer"),
      condition = MenuItem.isEnabled{ "File", "Start Recent Timer" },
      fn = Callback.Select
    },
  },

  ["com.apple.ScreenSharing"] =
  {
    ["openRecent"] = {
      message = T("Open Recent"),
      condition = MenuItem.isEnabled{ "Connect", "Open Recent" },
      fn = Callback.Select
    },
  },

  ["com.microsoft.rdc.macos"] = {
    ["toggleSidebar"] = {
      message = TC("Show Sidebar"),
      condition = function(app)
        if app:focusedWindow() == nil then return end
        local buttons = getc(towinui(app:focusedWindow()), AX.Toolbar, 1, AX.Button)
        if buttons == nil then return end
        local btTitle = T("Sidebar", app)
        local button = tfind(buttons, function(bt)
          return bt.AXDescription == btTitle
        end)
        return button ~= nil, button
      end,
      fn = Callback.Press
    },
  },

  ["com.realvnc.vncviewer"] = {
    ["search"] = {
      message = "Search",
      windowFilter = {
        allowTitles = "^(Real)VNC Viewer$"
      },
      condition = function(win)
        local winUI = towinui(win)
        local searchField = getc(winUI, AX.TextField, 1)
        return Callback.Clickable(searchField, { 5, 5 })
      end,
      fn = Callback.Click
    },
    ["toggleSidebar"] = {
      message = "Toggle sidebar",
      condition = MenuItem.isEnabled{ "View", "Show sidebar" },
      fn = Callback.Select
    },
    ["toggleStatusBar"] = {
      message = "Toggle status bar",
      condition = MenuItem.isEnabled{ "View", "Show status bar" },
      fn = Callback.Select
    },
    ["viewIcons"] = {
      message = "View > Icons",
      condition = MenuItem.isEnabled{ "View", "Icons" },
      fn = Callback.Select
    },
    ["viewDetails"] = {
      message = "View > Details",
      condition = MenuItem.isEnabled{ "View", "Details" },
      fn = Callback.Select
    }
  },

  ["com.parallels.desktop.console"] =
  {
    ["new..."] = {
      mods = "⌘", key = "N",
      message = T("New..."),
      condition = MenuItem.isEnabled{ "File", "New..." },
      fn = Callback.Select
    },
    ["open..."] = {
      mods = "⌘", key = "O",
      message = T("Open..."),
      condition = MenuItem.isEnabled{ "File", "Open..." },
      fn = Callback.Select
    },
    ["showControlCenter"] = {
      message = T("Control Center"),
      condition = MenuItem.isEnabled{ "Window", "Control Center" },
      fn = Callback.Select
    },
    ["expandedView"] = {
      message = T("Expanded View"),
      windowFilter = Parallels.WF.ControlCenter,
      condition = MenuItem.isEnabled{ "View", "Expanded View" },
      fn = Callback.Select
    },
    ["compactView"] = {
      message = T("Compact View"),
      windowFilter = Parallels.WF.ControlCenter,
      condition = MenuItem.isEnabled{ "View", "Compact View" },
      fn = Callback.Select
    },
    ["minimize"] = {
      message = T("Minimize"),
      condition = MenuItem.isEnabled{ "Window", "Minimize" },
      fn = Callback.Select
    },
    ["closeWindow"] = {
      message = T("Close Window"),
      condition = function(app)
        local menuItem, menuItemTitle =
            findMenuItem(app, { "File", "Close Window" })
        if Callback.Enabled(menuItem) then
          return true, menuItemTitle
        elseif app:focusedWindow() ~= nil then
          return true, app:focusedWindow()
        else
          return false
        end
      end,
      repeatable = true,
      fn = function(result, app)
        if type(result) == 'table' then
          app:selectMenuItem(result)
        else
          result:close()
        end
      end
    }
  },

  ["2dust.v2rayN"] = {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"]
  },

  ["org.wireshark.Wireshark"] =
  {
    ["closeWindow"] = {
      message = T("Close"),
      condition = function(app)
        local menuItem, menuItemTitle =
            findMenuItem(app, { "File", "Close" })
        if Callback.Enabled(menuItem) then
          return true, menuItemTitle
        else
          local win = app:focusedWindow()
          return win ~= nil and win:role() == AX.Window, win
        end
      end,
      fn = function(result, app)
        if type(result) == 'table' then
          app:selectMenuItem(result)
        else
          result:close()
        end
      end
    }
  },

  ["re.rizin.cutter"] =
  {
    ["preferences"] = {
      message = T("Preferences"),
      condition = MenuItem.isEnabled{ "Edit", "Preferences" },
      fn = Callback.Select
    },
    ["quit"] = {
      message = T("Quit"),
      condition = MenuItem.isEnabled{ "File", "Quit" },
      fn = Callback.Select
    }
  },

  ["com.apple.Terminal"] =
  {
    ["tmuxPreviousPane"] = {
      -- previous pane
      message = "Previous Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "o", nil, win:application())
      end
    },
    ["tmuxNextPane"] = {
      -- next pane
      message = "Next Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", ";", nil, win:application())
      end
    },
    ["tmuxAbovePane"] = {
      -- above pane
      message = "Above Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "Up", nil, win:application())
      end
    },
    ["tmuxBelowPane"] = {
      -- below pane
      message = "Below Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "Down", nil, win:application())
      end
    },
    ["tmuxLeftPane"] = {
      -- left pane
      message = "Left Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "Left", nil, win:application())
      end
    },
    ["tmuxRightPane"] = {
      -- right pane
      message = "Right Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "Right", nil, win:application())
      end
    },
    ["tmuxNewHorizontalPane"] = {
      -- new pane (horizontal)
      message = "New Pane (Horizontal)",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("⇧", "5", nil, win:application())  -- %
      end
    },
    ["tmuxNewVerticalPane"] = {
      -- new pane (vertical)
      message = "New Pane (Vertical)",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("⇧", "'", nil, win:application())  -- "
      end
    },
    ["tmuxClosePane"] = {
      -- close pane
      message = "Close Pane",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "x", nil, win:application())
      end
    },
    ["tmuxPreviousWindow"] = {
      -- previous window
      message = "Previous Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "p", nil, win:application())
      end
    },
    ["tmuxNextWindow"] = {
      -- next window
      message = "Next Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "n", nil, win:application())
      end
    },
    ["tmuxWindow0"] = {
      -- 0th window
      message = "0th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "0", nil, win:application())
      end
    },
    ["tmuxWindow1"] = {
      -- 1st window
      message = "1st Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "1", nil, win:application())
      end
    },
    ["tmuxWindow2"] = {
      -- 2nd window
      message = "2nd Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "2", nil, win:application())
      end
    },
    ["tmuxWindow3"] = {
      -- 3rd window
      message = "3rd Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "3", nil, win:application())
      end
    },
    ["tmuxWindow4"] = {
      -- 4th window
      message = "4th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "4", nil, win:application())
      end
    },
    ["tmuxWindow5"] = {
      -- 5th window
      message = "5th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "5", nil, win:application())
      end
    },
    ["tmuxWindow6"] = {
      -- 6th window
      message = "6th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "6", nil, win:application())
      end
    },
    ["tmuxWindow7"] = {
      -- 7th window
      message = "7th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "7", nil, win:application())
      end
    },
    ["tmuxWindow8"] = {
      -- 8th window
      message = "8th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "8", nil, win:application())
      end
    },
    ["tmuxWindow9"] = {
      -- 9th window
      message = "9th Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "9", nil, win:application())
      end
    },
    ["tmuxNewWindow"] = {
      message = "New Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "c", nil, win:application())
      end
    },
    ["tmuxCloseWindow"] = {
      message = "Close Window",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("⇧", "7", nil, win:application())  -- &
      end
    },
    ["tmuxDetachSession"] = {
      message = "Detach Session",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "D", nil, win:application())
      end
    },
    ["tmuxEnterCopyMode"] = {
      message = "Copy Mode",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "[", nil, win:application())
      end
    },
    ["tmuxSearch"] = {
      message = "Search",
      fn = function(win)
        hs.eventtap.keyStroke("⌃", "B", nil, win:application())
        hs.eventtap.keyStroke("", "[", nil, win:application())
        hs.eventtap.keyStroke("⌃", "s", nil, win:application())  -- emacs mode
      end
    }
  },

  ["com.torusknot.SourceTreeNotMAS"] =
  {
    ["showInFinder"] = {
      message = T("Show In Finder"),
      condition = MenuItem.isEnabled{ "Actions", "Show In Finder" },
      fn = Callback.Select
    }
  },

  ["com.apple.dt.Xcode"] =
  {
    ["showInFinder"] = {
      message = "Show in Finder",
      condition = MenuItem.isEnabled{ "File", "Show in Finder" },
      fn = Callback.Select
    }
  },

  ["com.jetbrains.CLion"] =
  {
    ["newProject"] = {
      message = "New Project",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = function(win)
        local menuItemPath = {"File", "New", "Project…"}
        local ok = win:application():findMenuItem(menuItemPath)
        if ok then return ok, menuItemPath end
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1)
          if #button > 0 then
            button = button[1]
          end
        end
        return Callback.Clickable(button)
      end,
      fn = function(menuItemOrButton, win)
        if menuItemOrButton.AXPosition then
          Callback.Click(menuItemOrButton)
        else
          Callback.Select(menuItemOrButton, win)
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = MenuItem.isEnabled({"File", "Open..."}, {"File", "Open…"}),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = "Recent Projects",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = MenuItem.isEnabled{ "File", "Recent Projects" },
      fn = Callback.Select
    }
  },

  ["com.jetbrains.CLion-EAP"] =
  {
    ["newProject"] = {
      message = "New Project",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = function(win)
        local menuItemPath = {"File", "New", "Project…"}
        local ok = win:application():findMenuItem(menuItemPath)
        if ok then return ok, menuItemPath end
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1)
          if #button > 0 then
            button = button[1]
          end
        end
        return Callback.Clickable(button)
      end,
      fn = function(menuItemOrButton, win)
        if menuItemOrButton.AXPosition then
          Callback.Click(menuItemOrButton)
        else
          Callback.Select(menuItemOrButton, win)
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = MenuItem.isEnabled({"File", "Open..."}, {"File", "Open…"}),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = "Recent Projects",
      windowFilter = {
        allowTitles = "Welcome to CLion"
      },
      condition = MenuItem.isEnabled{ "File", "Recent Projects" },
      fn = Callback.Select
    }
  },

  ["com.jetbrains.intellij"] =
  {
    ["newProject"] = {
      message = "New Project",
      windowFilter = {
        allowTitles = "Welcome to IntelliJ IDEA"
      },
      condition = function(win)
        local menuItemPath = {"File", "New", "Project…"}
        local ok = win:application():findMenuItem(menuItemPath)
        if ok then return ok, menuItemPath end
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1)
          if #button > 0 then
            button = button[1]
          end
        end
        return Callback.Clickable(button)
      end,
      fn = function(menuItemOrButton, win)
        if menuItemOrButton.AXPosition then
          Callback.Click(menuItemOrButton)
        else
          Callback.Select(menuItemOrButton, win)
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to IntelliJ IDEA"
      },
      condition = MenuItem.isEnabled({"File", "Open..."}, {"File", "Open…"}),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = "Recent Projects",
      windowFilter = {
        allowTitles = "Welcome to IntelliJ IDEA"
      },
      condition = MenuItem.isEnabled{ "File", "Recent Projects" },
      fn = Callback.Select
    }
  },

  ["com.jetbrains.pycharm"] =
  {
    ["newProject"] = {
      message = "New Project",
      windowFilter = {
        allowTitles = "Welcome to PyCharm"
      },
      condition = function(win)
        local menuItemPath = {"File", "New", "Project…"}
        local ok = win:application():findMenuItem(menuItemPath)
        if ok then return ok, menuItemPath end
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 2, AX.Button, 1)
        if button == nil then
          button = getc(winUI, AX.Group, 2, AX.Button, 1)
          if #button > 0 then
            button = button[1]
          end
        end
        return Callback.Clickable(button)
      end,
      fn = function(menuItemOrButton, win)
        if menuItemOrButton.AXPosition then
          Callback.Click(menuItemOrButton)
        else
          Callback.Select(menuItemOrButton, win)
        end
      end
    },
    ["open..."] = {
      message = "Open...",
      windowFilter = {
        allowTitles = "Welcome to PyCharm"
      },
      condition = MenuItem.isEnabled({"File", "Open..."}, {"File", "Open…"}),
      fn = Callback.Select
    },
    ["openRecent"] = {
      message = "Recent Projects",
      windowFilter = {
        allowTitles = "Welcome to PyCharm"
      },
      condition = MenuItem.isEnabled{ "File", "Recent Projects" },
      fn = Callback.Select
    }
  },

  ["org.qt-project.Designer"] =
  {
    ["openRecent"] = {
      message = T("&Recent Forms"),
      condition = MenuItem.isEnabled{ "File", "&Recent Forms" },
      fn = Callback.Select
    }
  },

  ["org.qt-project.Linguist"] =
  {
    ["openRecent"] = {
      message = T("Recently Opened &Files"),
      condition = MenuItem.isEnabled{ "File", "Recently Opened &Files" },
      fn = Callback.Select
    }
  },

  ["io.mountainduck"] =
  {
    ["preferencesFromMB"] = {
      message = TMB("Preferences…"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    },
    ["openConnectionFromMB"] = {
      message = TMB("Open Connection…"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    },
    ["historyFromMB"] = {
      message = TMB("History"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then
          Callback.Press(menu.AXParent)
          mouseMove(uioffset(menuItem, { 20, 5 }))
          hs.timer.doAfter(0.1, function()
            mouseMove(uioffset(menuItem, { 10, 5 }))
          end)
        end
      end
    },
    ["quitFromMB"] = {
      message = function(menu)
        local app = getAppFromDescendantElement(menu)
        local quit = T("Quit", menu)
        return quit .. ' ' .. app:name()
      end,
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local menuItem = getc(menu, AX.MenuItem, A_Message)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["org.adblockplus.adblockplussafarimac"] = {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"]
  },

  ["com.better365.BetterAndBetterHelper"] = {
    ["preferencesFromMB"] = {
      message = TMB("cn.better365.BetterAndBetter", "Preferences"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["cn.better365.iShotProHelper"] =
  {
    ["OCR"] = {
      message = "OCR",
      background = true,
      enabled = function(appid)
        -- the property update in command line is overridden when app quits
        local _, ok = hs.execute(strfmt(
            "defaults read '%s' dicOfShortCutKey | grep OCRRecorder", appid))
        return ok
      end,
      fn = function(app)
        local output = hs.execute(strfmt(
            "defaults read '%s' dicOfShortCutKey | grep OCRRecorder -A4",
            app:bundleID()))
        local spec = strsplit(output, "\n")
        local mods = spec[5]:match("modifierFlags = (%d+);")
        local key = spec[4]:match("keyCode = (%d+);")
        mods, key = parsePlistKeyBinding(mods, key)
        if mods == nil or key == nil then return end
        safeGlobalKeyStroke(mods, key)
      end
    },
    ["preferencesFromMB"] = {
      message = TMB("cn.better365.iShotPro", "Preferences"),
      menubarFilter = { allowIndices = 1 },
      fn = function(menu)
        local title = strsplit(A_Message, " > ")[2]
        local menuItem = getc(menu, AX.MenuItem, title)
        if menuItem then Callback.Press(menuItem) end
      end
    }
  },

  ["cn.better365.Cleaner"] =
  {
    ["closeWindow"] = specialCommonHotkeyConfigs["closeWindow"],
    ["minimize"] = specialCommonHotkeyConfigs["minimize"],
    ["hide"] = specialCommonHotkeyConfigs["hide"],
    ["quit"] = specialCommonHotkeyConfigs["quit"]
  },

  ["cn.better365.iCopy"] =
  {
    ["setting"] = {
      message = T("Setting"),
      windowFilter = iCopy.WF.Main,
      fn = function(win)
        local winUI = towinui(win)
        local button = getc(winUI, AX.Button, 1)
        if button ~= nil then Callback.Press(button) end
      end
    },
    ["select1stItem"] = {
      mods = "⌘", key = "1",
      message = "Select 1st Item",
      enabled = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(1)
    },
    ["select2ndItem"] = {
      mods = "⌘", key = "2",
      message = "Select 2nd Item",
      enabled = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(2)
    },
    ["select3rdItem"] = {
      mods = "⌘", key = "3",
      message = "Select 3rd Item",
      enabled = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(3)
    },
    ["select4thItem"] = {
      mods = "⌘", key = "4",
      message = "Select 4th Item",
      enabled = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(4)
    },
    ["select5thItem"] = {
      mods = "⌘", key = "5",
      message = "Select 5th Item",
      enabled = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(5)
    },
    ["select6thItem"] = {
      mods = "⌘", key = "6",
      message = "Select 6th Item",
      enabled = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(6)
    },
    ["select7thItem"] = {
      mods = "⌘", key = "7",
      message = "Select 7th Item",
      enabled = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(7)
    },
    ["select8thItem"] = {
      mods = "⌘", key = "8",
      message = "Select 8th Item",
      enabled = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(8)
    },
    ["select9thItem"] = {
      mods = "⌘", key = "9",
      message = "Select 9th Item",
      enabled = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(9)
    },
    ["select10thItem"] = {
      mods = "⌘", key = "0",
      message = "Select 10th Item",
      enabled = Version.LessThan("1.1.3"),
      windowFilter = iCopy.WF.Main,
      fn = iCopy.selectHotkeyRemap(10)
    },
    ["previousItem"] = {
      mods = "", key = "Left",
      message = "Previous Item",
      windowFilter = iCopy.WF.Main,
      repeatable = true,
      fn = function(win)
        hs.eventtap.keyStroke("", "Up", nil, win:application())
      end
    },
    ["nextItem"] = {
      mods = "", key = "Right",
      message = "Next Item",
      windowFilter = iCopy.WF.Main,
      repeatable = true,
      fn = function(win)
        hs.eventtap.keyStroke("", "Down", nil, win:application())
      end
    },
    ["cancelUp"] = {
      mods = "", key = "Up",
      message = "Cancel Up",
      windowFilter = iCopy.WF.Main,
      fn = function() end
    },
    ["cancelDown"] = {
      mods = "", key = "Down",
      message = "Cancel Down",
      windowFilter = iCopy.WF.Main,
      fn = function() end
    },
    ["cancelTap"] = {
      mods = "", key = "Tab",
      message = "Cancel Tab",
      windowFilter = iCopy.WF.Main,
      fn = function() end
    }
  }
}

for _, iWork in ipairs{ "Keynote", "Pages", "Numbers" } do
  local oldAppid = "com.apple.iWork." .. iWork
  local appid = "com.apple." .. iWork
  AppHotKeyCallbacks[appid] = AppHotKeyCallbacks[oldAppid]
end

local browserTabHotKeyCallbacks = {
  ["weiboNavigate1stCommonGroup"] = {
    message = Web.Weibo.sideBarTitle(1, true),
    condition = Web.Weibo.navigateToSideBarCondition(1, true),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate2ndCommonGroup"] = {
    message = Web.Weibo.sideBarTitle(2, true),
    condition = Web.Weibo.navigateToSideBarCondition(2, true),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate3rdCommonGroup"] = {
    message = Web.Weibo.sideBarTitle(3, true),
    condition = Web.Weibo.navigateToSideBarCondition(3, true),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate4thCommonGroup"] = {
    message = Web.Weibo.sideBarTitle(4, true),
    condition = Web.Weibo.navigateToSideBarCondition(4, true),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate1stCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(1),
    condition = Web.Weibo.navigateToSideBarCondition(1),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate2ndCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(2),
    condition = Web.Weibo.navigateToSideBarCondition(2),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate3rdCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(3),
    condition = Web.Weibo.navigateToSideBarCondition(3),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate4thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(4),
    condition = Web.Weibo.navigateToSideBarCondition(4),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate5thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(5),
    condition = Web.Weibo.navigateToSideBarCondition(5),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate6thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(6),
    condition = Web.Weibo.navigateToSideBarCondition(6),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate7thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(7),
    condition = Web.Weibo.navigateToSideBarCondition(7),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate8thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(8),
    condition = Web.Weibo.navigateToSideBarCondition(8),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate9thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(9),
    condition = Web.Weibo.navigateToSideBarCondition(9),
    fn = Web.Weibo.navigateToSideBar
  },
  ["weiboNavigate10thCustomGroup"] = {
    message = Web.Weibo.sideBarTitle(10),
    condition = Web.Weibo.navigateToSideBarCondition(10),
    fn = Web.Weibo.navigateToSideBar
  },

  ["douyinNavigate1stTab"] = {
    message = Web.Douyin.tabTitle(1),
    condition = Web.Douyin.navigateToTabCondition(1),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate2ndTab"] = {
    message = Web.Douyin.tabTitle(2),
    condition = Web.Douyin.navigateToTabCondition(2),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate3rdTab"] = {
    message = Web.Douyin.tabTitle(3),
    condition = Web.Douyin.navigateToTabCondition(3),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate4thTab"] = {
    message = Web.Douyin.tabTitle(4),
    condition = Web.Douyin.navigateToTabCondition(4),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate5thTab"] = {
    message = Web.Douyin.tabTitle(5),
    condition = Web.Douyin.navigateToTabCondition(5),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate6thTab"] = {
    message = Web.Douyin.tabTitle(6),
    condition = Web.Douyin.navigateToTabCondition(6),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate7thTab"] = {
    message = Web.Douyin.tabTitle(7),
    condition = Web.Douyin.navigateToTabCondition(7),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate8thTab"] = {
    message = Web.Douyin.tabTitle(8),
    condition = Web.Douyin.navigateToTabCondition(8),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate9thTab"] = {
    message = Web.Douyin.tabTitle(9),
    condition = Web.Douyin.navigateToTabCondition(9),
    fn = Web.Douyin.navigateToTab
  },
  ["douyinNavigate10thTab"] = {
    message = Web.Douyin.tabTitle(10),
    condition = Web.Douyin.navigateToTabCondition(10),
    fn = Web.Douyin.navigateToTab
  }
}
for _, appid in ipairs{
  "com.apple.Safari", "com.google.Chrome",
  "com.microsoft.edgemac", "com.microsoft.edgemac.Dev"
} do
  if AppHotKeyCallbacks[appid] == nil then
    AppHotKeyCallbacks[appid] = {}
  end
  for k, v in pairs(browserTabHotKeyCallbacks) do
    AppHotKeyCallbacks[appid][k] = v
  end
  if KeybindingConfigs.hotkeys[appid] == nil then
    KeybindingConfigs.hotkeys[appid] = {}
  end
  for k, v in pairs(KeybindingConfigs.hotkeys.browsers or {}) do
    KeybindingConfigs.hotkeys[appid][k] = v
  end
end
