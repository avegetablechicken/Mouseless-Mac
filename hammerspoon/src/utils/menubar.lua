---@diagnostic disable: lowercase-global

-- helpers for clicking menu bar items on the right side
-- these utilities simulate mouse interactions on menu bar items,
-- and are mainly used to work around limitations of AX.Press
-- and menu bar managers (Bartender / Ice / iBar / etc.)

------------------------------------------------------------
-- Load applications allowed to show in menu bar on macOS Tahoe+.
------------------------------------------------------------
local plistPath = os.getenv("HOME") .. "/Library/Group Containers"
    .. "/group.com.apple.controlcenter/Library/Preferences"
    .. "/group.com.apple.controlcenter.plist"

function getAllowedMenuBarAppsTahoe()
  local plist = hs.plist.read(plistPath)
  if plist == nil then return {} end

  local tracked = plist.trackedApplications
  -- In many cases this is nested plist data.
  if tracked and type(tracked) ~= "table" then
    tracked = hs.plist.readString(tracked, true)
  end

  local dict = {}
  for i=2,#tracked,2 do
    local isAllowed = tracked[i].isAllowed
    local appid = get(tracked[i-1], 'bundle', '_0')
    if appid then
      dict[appid] = isAllowed
    end
  end

  dict["com.apple.controlcenter"] = true  -- Control Center items are always allowed
  dict["com.apple.Spotlight"] = plist.showSpotlight
  dict["com.apple.weather"] = plist.showWeather
  return dict
end

------------------------------------------------------------
-- Load menu bar autosave names and preferred positions
-- Used to map menu bar item indices <-> persistent identifiers
------------------------------------------------------------

function getValidControlCenterMenuBarItemsTahoe(app)
  local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
  menuBarItems = tifilter(menuBarItems, function(item)
    return item.AXIdentifier
        and (item.AXIdentifier:sub(1, 20) == 'com.apple.menuextra.'
          or item.AXIdentifier:sub(-13) == '.liveActivity')
  end)
  return menuBarItems
end

-- Load autosave names for Control Center menu bar items on macOS Tahoe+.
-- Control Center uses a different persistence model starting from Tahoe.
local function loadStatusItemsAutosaveNameControlCenterTahoe(app, requirePreferredPosition)
  local appid = app:bundleID() or app:name()
  local enabledItems, preferredPositions = {}, {}

  -- Read Control Center visibility settings
  local plistPath = hs.fs.pathToAbsolute(strfmt(
      "~/Library/Preferences/%s.plist", appid))
  if plistPath ~= nil then
    local defaults = hs.plist.read(plistPath)
    if defaults then
      local visiblePrefix = "NSStatusItem VisibleCC "
      local prefix_len = #visiblePrefix
      for k, v in pairs(defaults) do
        if v == true and k:sub(1, prefix_len) == visiblePrefix then
          tinsert(enabledItems, k:sub(prefix_len + 1))
        end
      end
    end

    -- Load preferred ordering if requested
    if requirePreferredPosition == true then
      local prefix = "NSStatusItem Preferred Position "
      local prefix_len = #prefix
      for k, v in pairs(defaults) do
        if k:sub(1, prefix_len) == prefix then
          tinsert(preferredPositions, { k:sub(prefix_len + 1), tonumber(v) })
        end
      end
      if tfind(preferredPositions, function(r) return r[1] == "Clock" end) == nil then
        tinsert(preferredPositions, { "Clock", 1 })
      end
      preferredPositions = tifilter(preferredPositions, function(p)
        return tcontain(enabledItems, p[1])
      end)
    end
  end

  -- Collect menu bar items that belong to Control Center
  local menuBarItems = getValidControlCenterMenuBarItemsTahoe(app)

  -- Sort by on-screen position (right to left)
  local positions = {}
  for i, item in ipairs(menuBarItems) do
    tinsert(positions, { i, item })
  end
  table.sort(preferredPositions, function(a, b)
    return a[2] < b[2]
  end)
  table.sort(positions, function(a, b)
    return a[2].AXPosition.x > b[2].AXPosition.x
  end)

  -- Build bidirectional mapping: index <-> autosave name
  local map, preferred = {}, {}
  local ccBentoBoxCnt = 0
  foreach(positions, function(r)
    local item = r[2]
    local autosaveName

    -- BentoBox items are unnamed; assign synthetic identifiers
    if item.AXDescription:match('^'..app:name()) then
      autosaveName = "BentoBox-" .. tostring(ccBentoBoxCnt)
      ccBentoBoxCnt = ccBentoBoxCnt + 1
    else
      local ident = strsplit(item.AXIdentifier, '%.')[4]
      autosaveName = tfind(enabledItems, function(name)
        return name:lower():find(ident)
      end)
      if autosaveName == nil
          and item.AXIdentifier:sub(-13) ~= '.liveActivity' then
        local name = delocalizedString(item.AXDescription, appid)
        if type(name) == 'string' then
          name = name:gsub(" ", ""):gsub("‑", "")
          autosaveName = tfind(enabledItems, function(item)
            return item == name
          end)
        end
      end
    end
    if autosaveName then
      map[r[1]] = autosaveName
      map[autosaveName] = r[1]
      if requirePreferredPosition == true then
        local matched = tfind(preferredPositions, function(a)
          return a[1] == autosaveName
        end)
        if matched then
          preferred[r[1]] = matched[2]
          preferred[autosaveName] = matched[2]
        end
      end
    end
  end)

  if requirePreferredPosition == true then
    return map, preferred
  else
    return map
  end
end

-- Build a stable mapping between "visual index" and "autosave name"
-- so we can address menu bar items reliably across reorders.
function loadStatusItemsAutosaveName(app, requirePreferredPosition)
  local appid = app:bundleID() or app:name()

  -- Special case: Control Center on Tahoe+ has different persistence keys.
  if appid == 'com.apple.controlcenter' and OS_VERSION >= OS.Tahoe then
    return loadStatusItemsAutosaveNameControlCenterTahoe(app, requirePreferredPosition)
  end

  ----------------------------------------------------------
  -- Phase 1: read preferred positions from app preference plists
  ----------------------------------------------------------

  local preferredPositions = {}
  local defaults, errorReadingDefaults = readAppPreferencesPlist(appid)
  local prefix = "NSStatusItem Preferred Position "
  local prefix_len = #prefix

  if defaults ~= nil then
    for k, v in pairs(defaults) do
      if k:sub(1, prefix_len) == prefix then
        tinsert(preferredPositions, { k:sub(prefix_len + 1), tonumber(v) })
      end
    end
  end
  -- Last resort: shell `defaults read` text parsing (when plist read fails)
  if #preferredPositions == 0 and errorReadingDefaults then
    local records = hs.execute(strfmt([[
      defaults read %s | grep '"%s'
    ]], appid, prefix))
    records = strsplit(records, '\n')
    records[#records] = nil
    for _, r in ipairs(records) do
      r = r:sub(r:find('"') + 1)
      local items = strsplit(r, ' ')
      local name = items[4]:sub(1, #items[4] - 1)
      local position = tonumber(items[6]:sub(1, #items[6] - 1))
      tinsert(preferredPositions, { name, position })
    end
  end

  -- Control Center (pre-Tahoe) needs filtering by visibility
  -- because preferences can include items not currently shown.
  if appid == 'com.apple.controlcenter' and defaults then
    local enabledItems = {}
    local visiblePrefix = OS_VERSION >= OS.Tahoe
        and "NSStatusItem VisibleCC " or "NSStatusItem Visible "
    local prefix_len = #visiblePrefix
    for k, v in pairs(defaults) do
      if v == true and k:sub(1, prefix_len) == visiblePrefix then
        tinsert(enabledItems, k:sub(prefix_len + 1))
      end
    end
    if tfind(preferredPositions, function(r) return r[1] == "Clock" end) == nil then
      tinsert(preferredPositions, { "Clock", 1 })
    end
    preferredPositions = tifilter(preferredPositions, function(p)
      return tcontain(enabledItems, p[1])
    end)
  end

  if #preferredPositions == 0 then return end

  ----------------------------------------------------------
  -- Phase 2: map preferred positions to actual AX MenuBarItem indices
  -- We require counts to match to avoid bad mappings.
  ----------------------------------------------------------

  local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
  if menuBarItems == nil then
    -- Special case: Little Snitch exposes no AX menubar item list,
    -- but the defaults still contain one persistent status item.
    if appid == "at.obdev.littlesnitch.agent" then
      local autosaveName = preferredPositions[1][1]
      local preferredPosition = preferredPositions[1][2]
      local map = { autosaveName, [autosaveName] = 1 }
      if requirePreferredPosition == true then
        return map, { preferredPosition, [autosaveName] = preferredPosition }
      else
        return map
      end
    end
    return
  end

  -- Collect menu bar positions (x coordinate) to align with preferred ordering
  local positions = {}
  for i, item in ipairs(menuBarItems) do
    tinsert(positions, { i, item.AXPosition.x })
  end

  if #preferredPositions ~= #positions then return end
  -- Sort preferred positions (ascending) and actual items (right-to-left)
  -- fixme: if two icons are arranged on either side of the notch,
  -- macOS may adjust their positions. Thus incorrect matching may occur.
  table.sort(preferredPositions, function(r1, r2)
    return r1[2] < r2[2]
  end)
  table.sort(positions, function(r1, r2)
    return r1[2] > r2[2]
  end)

  -- Build bidirectional map: index -> autosaveName and autosaveName -> index
  local map, preferred = {}, {}
  for i, r in ipairs(positions) do
    map[r[1]] = preferredPositions[i][1]
    map[preferredPositions[i][1]] = r[1]
    if requirePreferredPosition == true then
      preferred[r[1]] = preferredPositions[i][2]
      preferred[preferredPositions[i][1]] = preferredPositions[i][2]
    end
  end
  if requirePreferredPosition == true then
    return map, preferred
  else
    return map
  end
end

------------------------------------------------------------
-- Helpers used when menu bar items are hidden by a manager
------------------------------------------------------------

-- Show hidden items panel for managers that expose a single "reveal" icon.
local function showHiddenMenuBarItems(manager)
  local icon = getc(toappui(manager), AX.MenuBar, -1, AX.MenuBarItem, 1)
  if icon then
    leftClickAndRestore(icon)
  end
  return false
end

-- Activate a menu bar item by AX.Press or by mouse click.
-- Some apps do not respond to AX.Press reliably, so click fallback exists.
local function activateMenuBarItem(menuBarItem, click)
  if click == "right-click" then
    rightClickAndRestore(menuBarItem)
  elseif click then
    leftClickAndRestore(menuBarItem)
  else
    menuBarItem:performAction(AX.Press)
  end
end

------------------------------------------------------------
-- MENUBAR_MANAGER_SHOW
-- Adaptation table: how to reveal / click items hidden by a manager.
-- Each entry either:
--   - is a function(manager, appid, index, map, click) -> boolean done?
--   - or is a string appid meaning "use showHiddenMenuBarItems"
------------------------------------------------------------

MENUBAR_MANAGER_SHOW = {
  ----------------------------------------------------------
  -- Bartender
  -- Strategy:
  --   - Most releases: use Bartender AppleScript "activate <appid-index>"
  --   - Early Bartener 6 releases: open Bartender Bar window,
  --     then locate the correct icon inside the bar and click it.
  ----------------------------------------------------------
  ["com.surteesstudios.Bartender"] = function(manager, appid, index, map, click)
    if type(index) == 'number' then
      map = map or loadStatusItemsAutosaveName(find(appid))
      index = map and map[index] or "Item-" .. tostring(index - 1)
    end

    -- Prefer AppleScript for stable Bartender versions (more direct).
    local version = applicationVersion(manager:bundleID())
    if version < "6" or version > "6.1.0" then
      local clickMode = click == "right-click" and " with right click" or ""
      hs.osascript.applescript(strfmt([[
        tell application id "%s" to activate "%s-%s"%s
      ]], manager:bundleID(), appid, index, clickMode))
      return true
    end

    -- Early Bartener 6 releases: open Bartender menu bar item (must exist).
    local icon = getc(toappui(manager), AX.MenuBar, -1, AX.MenuBarItem, "Bartender")
    if icon == nil then return end

    -- If not using Bartender Bar, simply toggling icon shows items.
    local useBartenderBar = getp(manager:bundleID(), "UseBartenderBar")
    if useBartenderBar ~= true and useBartenderBar ~= 1 then
      leftClickAndRestore(icon)
      return false
    end

    local app = find(appid)
    if type(index) == 'string' then
      map = map or loadStatusItemsAutosaveName(app)
      index = map and map[index]
      if index == nil then return true end
    end

    -- Compute the "order inside hidden bar" for the target icon:
    -- we count sibling items with same relative position class.
    local menuBarItems
    if appid == 'com.apple.controlcenter' and OS_VERSION >= OS.Tahoe then
      menuBarItems = getValidControlCenterMenuBarItemsTahoe(app)
    else
      menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
    end
    local menuBarItem = menuBarItems[index]
    local indicesForHidden = {}
    local iconAllwaysHiddenPosition = -7000
    for i=1,#menuBarItems do
      if i ~= index then
        if (menuBarItem.AXPosition.x > iconAllwaysHiddenPosition
                and menuBarItems[i].AXPosition.x > iconAllwaysHiddenPosition)
            or (menuBarItem.AXPosition.x < iconAllwaysHiddenPosition
                and menuBarItems[i].AXPosition.x < iconAllwaysHiddenPosition) then
          tinsert(indicesForHidden, menuBarItems[i].AXPosition.x)
        end
      end
    end
    local indexInHidden = #indicesForHidden + 1
    table.sort(indicesForHidden)
    for i, x in ipairs(indicesForHidden) do
      if x > menuBarItem.AXPosition.x then
        indexInHidden = i
        break
      end
    end

    -- Watch for "Bartender Bar" window creation, then click the icon.
    local observer = uiobserver.new(manager:pid())
    observer:addWatcher(toappui(manager), uinotifications.windowCreated)
    observer:callback(function(obs, elem)
      if not elem:isValid() then return end
      if elem.AXTitle == "Bartender Bar" then
        local icons = getc(elem, AX.ScrollArea, 1, AX.List, 1, AX.List, 1)
        local appnames = tmap(getc(icons, AX.Group), function(g)
          return getc(g, AX.Image, 1).AXDescription
        end)
        local count = 0
        for i, title in ipairs(appnames) do
          if title == hs.application.nameForBundleID(appid)
              or title == app:name()
              or (appid == "com.apple.Passwords.MenuBarExtra"
                  and title == "Passwords") then
            count = count + 1
            if count == indexInHidden then
              if click == "right-click" then
                rightClickAndRestore(getc(icons, AX.Group, i), elem:asHSWindow(), 0.1)
              else
                leftClickAndRestore(getc(icons, AX.Group, i), elem:asHSWindow(), 0.1)
              end
              break
            end
          end
        end
      end
      obs:stop() obs = nil
    end)
    observer:start()

    -- If the item is in normal visible region, a normal click opens bar;
    -- otherwise alt-click trick to reveal hidden section.
    if menuBarItem.AXPosition.x > iconAllwaysHiddenPosition then
      leftClickAndRestore(icon)
    else
      local oldPos = hs.mouse.absolutePosition()
      local point = hs.geometry.point {
        icon.AXPosition.x + icon.AXSize.w / 2,
        icon.AXPosition.y + icon.AXSize.h / 2
      }
      hs.mouse.absolutePosition(point)

      mouseDown(point, {Mod.Alt.Short})
      hs.timer.usleep(0.05 * 1000000)
      mouseUp(point, {Mod.Alt.Short})

      hs.mouse.absolutePosition(oldPos)
    end

    return true
  end,

  ----------------------------------------------------------
  -- Barbee
  -- Strategy: ask Barbee to show item via AppleScript.
  -- Note: it may kill itself (known issue).
  ----------------------------------------------------------
  ["com.HyperartFlow.Barbee"] = function(manager, appid, index, map)
    if type(index) == 'number' then
      map = map or loadStatusItemsAutosaveName(find(appid))
      index = map and map[index] or "Item-" .. tostring(index - 1)
    end
    -- fixme: below script will force `Barbee` to kill itself
    hs.osascript.applescript(strfmt([[
      tell application id "%s" to show item "%s-%s"
    ]], manager:bundleID(), appid, index))
    return true
  end,

  ----------------------------------------------------------
  -- Ice
  -- Strategy:
  --   - If Ice Bar is disabled, clicking the icon is enough.
  --   - If Ice Bar is enabled, open Ice Bar window and click the Nth icon
  --     for the target app (supports right-click).
  ----------------------------------------------------------
  ["com.jordanbaird.Ice"] = function(manager, appid, index, map, click)
    local icon = getc(toappui(manager), AX.MenuBar, -1, AX.MenuBarItem, 1)
    if icon == nil then return end

    -- If Ice Bar is not used, toggling icon reveals hidden items.
    local useIceBar = getp(manager:bundleID(), "UseIceBar")
    if useIceBar ~= true and useIceBar ~= 1 then
      leftClickAndRestore(icon)
      return false
    end

    local app = find(appid)
    if type(index) == 'string' then
      map = map or loadStatusItemsAutosaveName(app)
      index = map and map[index]
      if index == nil then return true end
    end

    -- Determine Nth occurrence among this app's items (multiple items possible)
    local menuBarItems
    if appid == 'com.apple.controlcenter' and OS_VERSION >= OS.Tahoe then
      menuBarItems = getValidControlCenterMenuBarItemsTahoe(app)
    else
      menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
    end
    local menuBarItem = menuBarItems[index]
    local iconAllwaysHidden = getc(toappui(manager), AX.MenuBar, -1, AX.MenuBarItem, 3)
    local indicesForHidden = {}
    for i=1,#menuBarItems do
      if i ~= index then
        if iconAllwaysHidden == nil
            or (menuBarItem.AXPosition.x > iconAllwaysHidden.AXPosition.x
                and menuBarItems[i].AXPosition.x > iconAllwaysHidden.AXPosition.x)
            or (menuBarItem.AXPosition.x < iconAllwaysHidden.AXPosition.x
                and menuBarItems[i].AXPosition.x < iconAllwaysHidden.AXPosition.x) then
          tinsert(indicesForHidden, menuBarItems[i].AXPosition.x)
        end
      end
    end
    local indexInHidden = #indicesForHidden + 1
    table.sort(indicesForHidden)
    for i, x in ipairs(indicesForHidden) do
      if x > menuBarItem.AXPosition.x then
        indexInHidden = i
        break
      end
    end

    -- Watch for "Ice Bar" window and click the correct icon.
    local observer = uiobserver.new(manager:pid())
    observer:addWatcher(toappui(manager), uinotifications.windowCreated)
    observer:callback(function(obs, elem)
      if not elem:isValid() then return end
      if elem.AXTitle == "Ice Bar" then
        local count = 0
        for _, button in ipairs(getc(elem, AX.Group, 1,
            AX.ScrollArea, 1, AX.Image)) do
          local title = button.AXAttributedDescription:getString()
          if title == hs.application.nameForBundleID(appid)
              or title == app:name()
              -- `Ice` renames "com.apple.Passwords.MenuBarExtra" to "Passwords"
              -- (see in https://github.com/jordanbaird/Ice/blob/main
              -- /Ice/MenuBar/MenuBarItems/MenuBarItem.swift)
              or (appid == "com.apple.Passwords.MenuBarExtra"
                  and title == "Passwords") then
            count = count + 1
            if count == indexInHidden then
              if click == "right-click" then
                rightClickAndRestore(button, elem:asHSWindow(), 0.1)
              else
                leftClickAndRestore(button, elem:asHSWindow(), 0.1)
              end
              break
            end
          end
        end
      end
      obs:stop() obs = nil
    end)
    observer:start()

    -- Open Ice Bar (normal or via alt-trick if icon is itself hidden)
    if iconAllwaysHidden == nil
        or (menuBarItem.AXPosition.x > iconAllwaysHidden.AXPosition.x) then
      leftClickAndRestore(icon)
    else
      local oldPos = hs.mouse.absolutePosition()
      local point = hs.geometry.point {
        icon.AXPosition.x + icon.AXSize.w / 2,
        icon.AXPosition.y + icon.AXSize.h / 2
      }
      hs.mouse.absolutePosition(point)

      mouseDown(point, {Mod.Alt.Short})
      hs.timer.usleep(0.05 * 1000000)
      mouseUp(point, {Mod.Alt.Short})

      hs.mouse.absolutePosition(oldPos)
    end

    return true
  end,

  ----------------------------------------------------------
  -- iBar
  -- Strategy:
  --   - If not advancedMode: hover-move to trigger UI, then click target.
  --   - If advancedMode: open iBarmenu window and click entry by identifier.
  ----------------------------------------------------------
  ["cn.better365.iBar"] = function(manager, appid, index, map, click)
    local icon = getc(toappui(manager), AX.MenuBar, -1, AX.MenuBarItem, 1)
    if not icon then return end
    local app = find(appid)

    local isAdvancedMode = getp(manager:bundleID(), "advancedMode")
    if isAdvancedMode ~= true and isAdvancedMode ~= 1 then
      if type(index) == 'string' then
        map = map or loadStatusItemsAutosaveName(app)
        index = map and map[index]
        if index == nil then return true end
      end

      -- iBar (non-advanced) relies on cursor hover gestures to reveal hidden icons.
      mouseMove(uioffset(icon, {-10, 10}))
      hs.timer.doAfter(0.2, function()
        mouseMove(uioffset(icon, {-20, 10}))
        hs.timer.doAfter(3, function()
          local menuBarItems
          if appid == 'com.apple.controlcenter' and OS_VERSION >= OS.Tahoe then
            menuBarItems = getValidControlCenterMenuBarItemsTahoe(app)
          else
            menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
          end
          local menuBarItem = menuBarItems[index or 1]
          if menuBarItem then
            hs.timer.doAfter(0, bind(activateMenuBarItem, menuBarItem, click))
          end
        end)
      end)
      return true
    end

    -- Advanced mode: open iBarmenu panel and click target entry.
    leftClickAndRestore(icon)

    if type(index) == 'number' then
      map = map or loadStatusItemsAutosaveName(find(appid))
      index = map and map[index] or "Item-" .. tostring(index - 1)
    end
    hs.timer.waitUntil(
      function()
        local win = manager:focusedWindow()
        return win ~= nil and win:title() == "iBarmenu"
            and win:subrole() == AX.SystemFloatingWindow
      end,
      function()
        local winUI = towinui(manager:focusedWindow())
        -- If index specified: click exact entry matching "<index> >>> <appid>"
        if index ~= nil then
          local itemRepr = index .. ' >>> ' .. appid
          for _, bt in ipairs(getc(winUI, AX.Button)) do
            if bt.AXIdentifier:sub(#bt.AXIdentifier - #itemRepr + 1)
                == itemRepr then
              bt:performAction(AX.Press)
              break
            end
          end
        else
          -- If index omitted: if only one item for app exists, click it.
          local appItems = {}
          for i, bt in ipairs(getc(winUI, AX.Button)) do
            if bt.AXIdentifier:find(appid) then
              tinsert(appItems, i)
            end
          end
          if #appItems == 1 then
            local bt = getc(winUI, AX.Button, appItems[1])
            bt:performAction(AX.Press)
          end
        end
      end
    )
    return true
  end,

  ----------------------------------------------------------
  -- Vanilla
  -- Strategy: find its icon-like window and click it to reveal.
  ----------------------------------------------------------
  ["net.matthewpalmer.Vanilla"] = function(manager)
    local icon = tfind(getc(toappui(manager), AX.Window), function(win)
      return #win == 1 and win[1].AXRole == AX.Image
    end)
    if icon then
      leftClickAndRestore(icon)
    end
    return false
  end,

  -- Managers that can be handled by generic "click first menu bar item" reveal
  "com.dwarvesv.minimalbar",
  "com.mortennn.Dozer",
}

-- Detect which menu bar manager is actually active/visible
local function getValidMenuBarManager()
  -- Leftmost screen x coordinate: used to decide if an item is "hidden"
  local leftmostHorizontal = 0
  foreach(hs.screen.allScreens(), function(screen)
    leftmostHorizontal = math.min(screen:fullFrame().x, leftmostHorizontal)
  end)

  -- Pick the first manager that has a visible UI on the menu bar area.
  for appid, fn in pairs(MENUBAR_MANAGER_SHOW) do
    local managerAppId = type(fn) == 'string' and fn or appid
    local app = find(managerAppId)
    if app then
      local maxX  -- used to avoid false positives if the manager is itself hidden
      if managerAppId == "net.matthewpalmer.Vanilla" then
        local icon = tfind(getc(toappui(app), AX.Window), function(win)
          return #win == 1 and win[1].AXRole == AX.Image
        end)
        maxX = icon.AXPosition.x
      else
        maxX = leftmostHorizontal - 1
        foreach(getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem),
            function(item) maxX = math.max(maxX, item.AXPosition.x) end)
      end
      if maxX > leftmostHorizontal then
        return app
      end
    end
  end
end

-- Check whether a menu bar item is hidden by a manager
function hiddenByMenuBarManager(app, index, map)
  local manager = getValidMenuBarManager()
  if manager == nil then return false end
  if type(index) == 'string' then
    map = map or loadStatusItemsAutosaveName(app)
    index = map and map[index]
    if index == nil then return false end
  end
  local menuBarItems
  if app:bundleID() == 'com.apple.controlcenter' and OS_VERSION >= OS.Tahoe then
    menuBarItems = getValidControlCenterMenuBarItemsTahoe(app)
  else
    menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
  end
  local menuBarItem = menuBarItems[index or 1]
  -- Any item with x < leftmost screen x is considered "off-screen hidden".
  local leftmostHorizontal = 0
  foreach(hs.screen.allScreens(), function(screen)
    leftmostHorizontal = math.min(screen:fullFrame().x, leftmostHorizontal)
  end)
  return menuBarItem.AXPosition.x < leftmostHorizontal, manager, map
end

-- Open a menu bar item, then navigate submenus and finally press the leaf menu item.
function clickRightMenuBarItem(appid, menuItemPath, show)
  local menuBarId, app
  -- Support passing {appid, menubarIndex} as appid argument.
  if type(appid) == 'table' then
    menuBarId = appid[2] appid = appid[1]
  end
  if type(appid) == 'string' then
    app = find(appid)
    if app == nil then return false end
  else
    app = appid appid = app:bundleID() or app:name()
  end

  if type(menuItemPath) ~= 'table' then
    menuItemPath = { menuItemPath }
  end
  -- If no submenu path is provided, default to showing the menu.
  if #menuItemPath == 0 and show == nil then
    show = true
  end

  -- Resolve menu bar index:
  --   - numeric index: direct
  --   - string autosaveName: translate via loadStatusItemsAutosaveName

  local menuBarIdx = menuBarId
  local map
  if type(menuBarIdx) == 'string' then
    map = loadStatusItemsAutosaveName(app)
    menuBarIdx = map and map[menuBarIdx]
    if menuBarIdx == nil then return false end
  end
  local menuBarItems
  if appid == 'com.apple.controlcenter' and OS_VERSION >= OS.Tahoe then
    menuBarItems = getValidControlCenterMenuBarItemsTahoe(app)
  else
    menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
  end
  local menuBarItem = menuBarItems[menuBarIdx or 1]
  if menuBarItem == nil then return false end

  -- Rnsure the menu bar item is actually visible
  -- If it's hidden by a manager, ask that manager to reveal it.

  if show then
    local click = type(show) == "string" and show or false
    local hidden, manager
    hidden, manager, map = hiddenByMenuBarManager(app, menuBarId, map)
    if hidden then
      assert(manager)
      -- Use manager-specific reveal strategy if available, else generic.
      local showFunc = MENUBAR_MANAGER_SHOW[manager:bundleID()]
          or bind(showHiddenMenuBarItems, manager)
      -- `done=false` means: manager reveals panel; we need delayed activation.
      local done = showFunc(manager, appid, menuBarId or 1, map, click)
      if not done then
        if menuBarItem then
          hs.timer.doAfter(0.2, function()
            activateMenuBarItem(menuBarItem, click)
          end)
        else
          return false
        end
      end
    elseif menuBarItem then
      -- Not hidden: just activate directly.
      activateMenuBarItem(menuBarItem, click)
    else
      return false
    end
  end
  if #menuItemPath == 0 then return true end

  -- Traverse submenu path and press the final item.
  -- Each step expects an AX.Menu(1) under current node.

  local menu = menuBarItem
  for _, item in ipairs(menuItemPath) do
    local parent = menu
    menu = getc(parent, AX.Menu, 1, AX.MenuItem, item)
    if menu == nil and type(item) == 'string' then
      local locItem = localizedString(item, appid)
      if locItem then
        menu = getc(parent, AX.Menu, 1, AX.MenuItem, locItem)
      end
    end
    if menu == nil then return false end
  end

  menu:performAction(AX.Press)
  return true
end
