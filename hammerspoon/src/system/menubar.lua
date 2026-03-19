-- Menu bar item search.
--
-- Provides a chooser-based interface to search and trigger
-- menu bar items across running applications.

local function registerSearchMenuBar()
  -- Collect menu bar items from all running applications.
  -- For each app, try to load autosaved status item identifiers
  -- and map them to accessibility menu bar elements if available.
  local menuBarItems, maps = {}, {}
  local apps = hs.application.runningApplications()
  if OS_VERSION >= OS.Tahoe then
    local allowedApps = getAllowedMenuBarAppsTahoe()
    apps = tifilter(apps, function(app)
      if app:kind() < 0 then return false end
      local appid = app:bundleID()
      local isAllowed = allowedApps[appid]
      local apath
      if isAllowed == nil and appid ~= "com.apple.WebKit.WebContent" then
        apath = app:path() or ""
        local pos = apath:sub(1, -4):find(".app/", 1, true)
        if pos then
          local appPath = apath:sub(1, pos + 3)
          local info = hs.application.infoForBundlePath(appPath)
          if info and info.CFBundleIdentifier then
            local id = info.CFBundleIdentifier
            isAllowed = allowedApps[id]
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
    local map, preferred = loadStatusItemsAutosaveName(app, true)
    if map and #map > 0 then
      assert(preferred)
      maps[appid] = map or {}
      if appid ~= 'com.apple.controlcenter' or OS_VERSION < OS.Tahoe then
        local appMenuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
        if appMenuBarItems then
          for i, item in ipairs(appMenuBarItems) do
            tinsert(menuBarItems, { item, i, preferred[i] })
          end
        else
          for i, item in ipairs(preferred) do
            tinsert(menuBarItems, { app, i, item })
          end
        end
      end
    end
  end
  if #menuBarItems == 0 then
    return
  end

  -- Sort menu bar items by their on-screen position (right to left),
  -- falling back to autosave name order when accessibility position
  -- is unavailable.
  table.sort(menuBarItems, function(a, b)
    if a[1].AXPosition and b[1].AXPosition then
      return a[1].AXPosition.x > b[1].AXPosition.x
    else
      return a[3] < b[3]
    end
  end)

  -- On Tahoe and newer macOS, Control Center hosts additional menu bar items
  -- (e.g. empty entries and Live Activities) that need to be excluded or
  -- merged into the global menu bar ordering
  if OS_VERSION >= OS.Tahoe then
    local appMenuBarItems = getValidControlCenterMenuBarItemsTahoe(
      SystemControlCenterApp
    )
    local items = {}
    for i, item in ipairs(appMenuBarItems) do
      tinsert(items, { item, i })
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
    local title, extraSearchPattern
    if #maps[appid] > 1 then
      local autosaveName = maps[appid][idx]
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
        else
          local parts = strsplit(item.AXIdentifier, "%.")
          extraSearchPattern = parts[#parts]
        end
        extraSearchPattern = { appname, extraSearchPattern }
        appname = item.AXDescription
      elseif autosaveName ~= "Item-0" or #tifilter(maps[appid],
          function(v) return v:sub(1, 5) == "Item-" end) > 1 then
        title = autosaveName
      end
    end

    -- Resolve icon and search metadata for menu bar items.
    --
    -- Prefer using the application's bundle ID to fetch its icon directly.
    -- However, some menu bar items are backed by helper processes or
    -- non-bundled executables, in which case `app:bundleID()` is nil.
    local image
    if app:bundleID() then
      image = hs.image.imageFromAppBundle(appid)
    else
      -- Fallback for processes without a bundle ID:
      -- Inspect the executable path via `lsof` to locate the enclosing `.app`
      -- bundle, then infer its bundle identifier manually.
      local pathStr, ok = hs.execute(strfmt([[
          lsof -a -d txt -p %s 2>/dev/null | sed -n '2p' | awk '{print $NF}']], app:pid()))
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
    hs.timer.doAfter(0, function()
      local item = menuBarItems[choice.id][1]
      if item.AXPosition == nil then
        local left, right = menuBarItems[choice.id+1][1], menuBarItems[choice.id-1][1]
        if left.AXPosition and right.AXPosition then
          local position = hs.geometry.point(
            (left.AXPosition.x + left.AXSize.w + right.AXPosition.x) / 2,
            left.AXPosition.y + left.AXSize.h / 2
          )
          if choice.appid == "at.obdev.littlesnitch.agent" then
            rightClickAndRestore(position)
          else
            leftClickAndRestore(position)
          end
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
          -- Special-case handling for Hammerspoon menu bar items
          -- (e.g. caffeine and proxy), which cannot always be triggered
          -- via accessibility actions.
          if choice.subText == SystemCaffeineMenubar:autosaveName() then
            SystemCaffeineClicked()
            return
          elseif choice.subText == SystemProxyMenubar:autosaveName() then
            local frame = SystemProxyMenubar:_frame()
            local screenFrame = hs.screen.mainScreen():frame()
            SystemProxyMenubar:popupMenu({
              x = frame.x,
              y = screenFrame.y + screenFrame.h - frame.y
            })
            return
          end
          -- fixme: hanging issue
          hs.alert.show("Cannot trigger Hammerspoon menu bar item", 2)
          return
        end
        menuBarItems[choice.id][1]:performAction(AX.Press)
      end
    end)
  end)
  chooser:choices(choices)

  -- Dynamic filtering:
  -- Match query against app name, bundle ID, item title,
  -- and additional extracted identifiers.
  chooser:queryChangedCallback(function(query)
    local newChoices = {}
    local loweredQuery = string.lower(query)
    for _, choice in ipairs(choices) do
      if choice.text:lower():find(loweredQuery, 1, true)
          or choice.appid:lower():find(loweredQuery, 1, true)
          or (choice.subText and choice.subText:lower()
              :find(loweredQuery, 1, true))
          or (type(choice.extraPattern) == 'string'
              and choice.extraPattern:lower():find(loweredQuery, 1, true))
          or (type(choice.extraPattern) == 'table'
              and tfind(choice.extraPattern, function(pattern)
                return pattern:lower():find(loweredQuery, 1, true)
              end)) then
        tinsert(newChoices, choice)
      end
    end
    chooser:choices(newChoices)
  end)
  hs.keycodes.currentSourceID("com.apple.keylayout.ABC")
  chooser:show()
end

local hotkeySearchMenuBar
local misc = KeybindingConfigs.hotkeys.global
if misc ~= nil and misc["searchMenuBar"] ~= nil then
  local menuBarManagers = {
    "com.surteesstudios.Bartender",
    "com.jordanbaird.Ice",
  }
  local onQuit = function()
    local anyRunning = tfind(menuBarManagers, function(appid)
      return find(appid) ~= nil
    end)
    if not anyRunning then
      if hotkeySearchMenuBar == nil then
        hotkeySearchMenuBar = bindHotkeySpec(misc["searchMenuBar"],
            'Search Menu Bar', registerSearchMenuBar)
        if hotkeySearchMenuBar == nil then return end
        hotkeySearchMenuBar.kind = HK.MENUBAR
      end
      hotkeySearchMenuBar:enable()
    end
  end
  local anyRunning = tfind(menuBarManagers, function(appid)
    return find(appid) ~= nil
  end)
  if not anyRunning then
    hotkeySearchMenuBar = bindHotkeySpec(misc["searchMenuBar"],
        'Search Menu Bar', registerSearchMenuBar)
    hotkeySearchMenuBar.kind = HK.MENUBAR
  else
    foreach(menuBarManagers, function(appid)
      if find(appid) then
        ExecOnSilentQuit(appid, onQuit)
      end
    end)
  end
  foreach(menuBarManagers, function(appid)
    ExecOnSilentLaunch(appid, function()
      if hotkeySearchMenuBar then
        hotkeySearchMenuBar:disable()
      end
      ExecOnSilentQuit(appid, onQuit)
    end)
  end)
end
