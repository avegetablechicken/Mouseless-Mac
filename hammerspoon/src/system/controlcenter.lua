-- Control Center automation.
--
-- This section provides deep automation for macOS Control Center,
-- including:
-- - Opening specific panels
-- - Registering panel-specific hotkeys
-- - Handling UI differences across macOS versions
--
-- Implementation relies heavily on Accessibility APIs and
-- version-specific UI heuristics.

-- assume `Control Center` window is always frontmost

local CC = {
  AXShortcuts       = "Accessibility Shortcuts",
  AirDrop           = "AirDrop",
  Battery           = "Battery",
  Bluetooth         = "Bluetooth",
  Display           = "Display",
  Focus             = "Focus",
  Hearing           = "Hearing",
  KbBrightness      = "Keyboard Brightness",
  MusicRecognition  = "Music Recognition",
  NowPlaying        = "Now Playing",
  ScreenMirror      = "Screen Mirroring",
  Sound             = "Sound",
  StageManager      = "Stage Manager",
  User              = "User",
  WiFi              = "Wi‑Fi",
}
if OS_VERSION >= OS.Tahoe then
  CC.MusicRecognition = "Recognize Music"
end

-- Control Center hotkey bindings.
--
-- Hotkeys registered here are contextual and only active
-- while Control Center UI is present.

local controlCenterLocalized

-- Create a Control Center specific hotkey
local function newControlCenter(...)
  local hotkey = newHotkey(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.MENUBAR
  hotkey.subkind = HK.MENUBAR_.CONTROL_CENTER
  return hotkey
end

-- Bind a Control Center hotkey using hotkey spec
local function bindControlCenter(...)
  local hotkey = bindHotkeySpec(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.MENUBAR
  hotkey.subkind = HK.MENUBAR_.CONTROL_CENTER
  return hotkey
end

-- Bind hotkey to open a specific Control Center panel
local function bindControlCenterPanel(spec, panel, func)
  local locAppName = displayName("com.apple.controlcenter")
  local locPanel = controlCenterLocalized(panel)
  local message = locAppName..' > '..locPanel
  return bindControlCenter(spec, message, func)
end

-- Register URL event handler for Control Center panel switching
local controlCenterPanelFuncs = {}
local function bindURLEventForControlCenter()
  hs.urlevent.bind("controlcenter", function(eventName, params)
    if params["panel"] == "Music Recognition" or params["panel"] == "Recognize Music" then
      params["panel"] = CC.MusicRecognition
    end
    local fn = controlCenterPanelFuncs[params["panel"]]
    if fn then fn() end
  end)
end

-- Register URL-based Control Center panel trigger
local function bindControlCenterPanelURL(panel, func)
  controlCenterPanelFuncs[panel] = func

  local locAppName = displayName("com.apple.controlcenter")
  local locPanel = controlCenterLocalized(panel)
  registerURLHotkeyMessage('controlcenter', 'panel', panel,
                           locAppName..' > '..locPanel)
  if OS_VERSION < OS.Tahoe and panel == CC.MusicRecognition then
    registerURLHotkeyMessage('controlcenter', 'panel', "Recognize Music",
                            locAppName..' > '..locPanel)
  end
end

controlCenterLocalized = function(panel, key)
  if key == nil then
    key = panel
  end

  local localeFile
  if panel == CC.User then
    localeFile = "Users"
  elseif panel == CC.MusicRecognition then
    localeFile = "Music Recognition"
  else
    localeFile = panel
  end
  localeFile = localeFile:gsub(" ", ""):gsub("‑", "")
  local params
  if panel == CC.StageManager then
    params = {
      localeFile = localeFile,
      locale = applicationLocale('com.apple.WindowManager')
    }
  else
    params = localeFile
  end

  local result = localizedString(key, "com.apple.controlcenter", params)
  if not result and panel == CC.Focus then
    result = localizedString(key, "com.apple.controlcenter",
        { framework = "DoNotDisturb.framework" }, true)
    if not result then
      result = localizedString(key, "com.apple.controlcenter",
          { framework = "DoNotDisturbKit.framework" }, true)
    end
  end
  return result
end

local function testAlready(panel, pane, role)
  if panel == CC.StageManager then return false end
  local locPanel = controlCenterLocalized(panel)

  if role == nil then
    if tcontain({ CC.WiFi, CC.Focus, CC.Bluetooth, CC.AirDrop,
                  CC.KbBrightness, CC.ScreenMirror,
                  CC.AXShortcuts, CC.Battery,
                  CC.Sound, CC.Hearing }, panel) then
      local elem = getc(pane, AX.StaticText, 1)
      return elem and elem.AXValue == locPanel
    elseif panel == CC.Display then
      local str = controlCenterLocalized(panel, "Display Settings…")
      local buttons = getc(pane, AX.Button)
      for i = #buttons, 1, -1 do
        local title = OS_VERSION < OS.Ventura and buttons[i].AXTitle
            or buttons[i].AXAttributedDescription:getString()
        if title == str then
          return true
        end
      end
      return false
    elseif panel == CC.MusicRecognition then
      local elem = getc(pane, AX.Group, 1, AX.Group, 1, AX.CheckBox, 1)
      local title
      if elem and elem.AXTitle then
        title = elem.AXTitle
      elseif elem and elem.AXAttributedDescription then
        title = elem.AXAttributedDescription:getString()
      end
      return elem and title:match('^'..locPanel)
    elseif panel == CC.NowPlaying then
      if OS_VERSION < OS.Ventura then
        local mayLocalize = bind(controlCenterLocalized, panel)
        return getc(pane, AX.Button, mayLocalize("rewind")) ~= nil
            or getc(pane, AX.Button, mayLocalize("previous")) ~= nil
            or (#getc(pane, AX.Button, mayLocalize("play"))
              + #getc(pane, AX.Button, mayLocalize("pause"))) > 1
      else
        if OS_VERSION >= OS.Tahoe then pane = getc(pane, AX.Group, 1) end
        return pane and #getc(pane, AX.Button) > 1
            and (#getc(pane, AX.Image) > 0 or pane[1].AXRole == AX.Unknown)
      end
    elseif panel == CC.User then
      local elem = pane[#pane]
      local title
      if elem and elem.AXTitle then
        title = elem.AXTitle
      elseif elem and elem.AXAttributedDescription then
        title = elem.AXAttributedDescription:getString()
      end
      return title == controlCenterLocalized(panel, "Users & Groups Settings…")
    end
  end

  return tfind(getc(pane, role) or {}, function(elem)
    return elem.AXTitle == locPanel
        or elem.AXAttributedDescription:getString():match('^'..locPanel)
  end) ~= nil
end

local function getBluetoothDevices()
  local output, status = hs.execute("system_profiler SPBluetoothDataType")
  if not status then
    hs.alert.show("Failed to run system_profiler for Bluetooth")
    return {}
  end

  local devices = {}
  local currentName = nil

  for line in output:gmatch("[^\r\n]+") do
    local nameMatch = line:match("^%s+(.+):%s*$")
    if nameMatch and not line:match("^%s+Address:") then
      currentName = nameMatch
    end

    local addrMatch = line:match("^%s+Address:%s*([0-9A-F:]+)%s*$")
    if addrMatch and currentName then
      devices[addrMatch] = currentName
      currentName = nil
    end
  end

  return devices
end

-- Open or switch to a specific Control Center sub-panel
local function popupControlCenterSubPanel(panel, allowReentry)
  -- Phase 1: detect current Control Center window and UI container
  -- Phase 2: locate panel entry point based on OS version
  -- Phase 3: perform UI action to enter panel
  -- Phase 4: register panel-specific hotkeys

  local app = find("com.apple.controlcenter")
  local appUI = toappui(app)
  local pane

  local function enterPanel()  -- assume in BentoBox-0 since macOS Tahoe
    local role, locPanel
    if tcontain({ CC.WiFi, CC.Focus, CC.Bluetooth, CC.AirDrop,
                  CC.MusicRecognition }, panel) then
      role = AX.CheckBox
    elseif panel == CC.ScreenMirror then
      if OS_VERSION >= OS.Ventura and OS_VERSION <= OS.Sequoia then
        role = AX.Button
      else
        role = AX.CheckBox
      end
    elseif panel == CC.StageManager then
      if OS_VERSION >= OS.Tahoe then
        role = AX.CheckBox
      else
        role = AX.Button
      end
    elseif panel == CC.Display then
      if OS_VERSION >= OS.Ventura and OS_VERSION <= OS.Sequoia then
        role = AX.Group
      elseif OS_VERSION >= OS.Tahoe:withMinor(1) then
        role = AX.Button
      else
        role = AX.StaticText
      end
    elseif panel == CC.KbBrightness then
      if OS_VERSION <= OS.Sequoia then
        role = AX.Button
      elseif OS_VERSION >= OS.Tahoe:withMinor(1) then
        role = AX.Button
        locPanel = controlCenterLocalized(panel, "Keyboard")
      else
        role = AX.StaticText
      end
    elseif panel == CC.Sound then
      if OS_VERSION >= OS.Tahoe:withMinor(1) then
        role = AX.Button
      else
        role = AX.StaticText
      end
    elseif tcontain({ CC.Battery, CC.Hearing }, panel) then
      role = AX.Button
    elseif tcontain({ CC.AXShortcuts, CC.User }, panel) then
      if OS_VERSION >= OS.Tahoe:withMinor(1) then
        role = AX.CheckBox
        if panel == CC.AXShortcuts then
          locPanel = controlCenterLocalized(panel, "Accessibility")
        end
      else
        role = AX.Button
      end
    elseif panel == CC.NowPlaying then
      local ele
      local totalDelay = 0
      repeat
        if OS_VERSION >= OS.Tahoe then
          ele = tfind(getc(pane, AX.Group), function(g)
            local bts = getc(g, AX.Button)
            return #bts == 3 and bts[1].AXIdentifier:find("backward")
              and bts[3].AXIdentifier:find("forward")
              and (bts[2].AXIdentifier:find("play") or bts[2].AXIdentifier:find("pause"))
          end)
        else
          ele = getc(pane, AX.Image, -1)
        end
        if ele == nil then
          hs.timer.usleep(0.05 * 1000000)
          totalDelay = totalDelay + 0.05
        end
      until ele or totalDelay > 3 or not pane:isValid()
      if ele then
        local actions = ele:actionNames()
        ele:performAction(actions[#actions])
        return true
      end
      return false
    end

    local ele
    local totalDelay = 0
    locPanel = locPanel or controlCenterLocalized(panel)
    repeat
      ele = tfind(getc(pane, role), function(e)
        if panel == CC.Focus then
          return e.AXIdentifier == "controlcenter-focus-modes"
        end
        if role == AX.Group then
          local elem = getc(e, AX.StaticText, 1)
          return elem and elem.AXValue == locPanel
        elseif role == AX.StaticText then
          return e.AXValue == locPanel
        else
          return e.AXTitle == locPanel or (e.AXAttributedDescription
              and e.AXAttributedDescription:getString():match('^'..locPanel))
        end
      end)
      if ele == nil then
        hs.timer.usleep(0.05 * 1000000)
        totalDelay = totalDelay + 0.05
      end
    until ele or totalDelay > 0.9 or not pane:isValid()
    if ele then
      local actions = ele:actionNames()
      local ret = ele:performAction(actions[#actions])
      if ret and panel == CC.StageManager then
        local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
        local menuBarItem = tfind(menuBarItems,
          function(item)
            return item.AXIdentifier == "com.apple.menuextra.controlcenter"
          end)
        menuBarItem:performAction(AX.Press)
      end
      return true
    end
    return false
  end

  if app:mainWindow() then
    pane = getc(appUI, AX.Window, 1)
    if OS_VERSION >= OS.Ventura then
      pane = getc(pane, AX.Group, 1)
    end
    if panel == CC.Hearing then
      if #pane == 1 and pane[1].AXRole == AX.ScrollArea then
        pane = pane[1]
      end
    end
    if testAlready(CC.WiFi, pane, AX.CheckBox)
        and testAlready(CC.Bluetooth, pane, AX.CheckBox) then
      if enterPanel() then
        registerControlCenterHotKeys(panel)
      end
      return
    elseif testAlready(panel, pane) and not allowReentry then
      return
    end
  end

  local locPanel = controlCenterLocalized(panel)
  local menuBarItems
  if OS_VERSION >= OS.Tahoe then
    menuBarItems = getValidControlCenterMenuBarItemsTahoe(app)
  else
    menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
  end
  local index
  for i, elem in ipairs(menuBarItems) do
    if elem.AXDescription and elem.AXDescription:find(locPanel) then
      index = i break
    end
  end
  if index then
    clickRightMenuBarItem({'com.apple.controlcenter', index})
    registerControlCenterHotKeys(panel, true)
  else
    local menuBarItem = tfind(menuBarItems,
      function(item)
        return item.AXIdentifier == "com.apple.menuextra.controlcenter"
      end)
    menuBarItem:performAction(AX.Press)
    pane = getc(appUI, AX.Window, 1)
    local winTotalDelay = 0
    if pane == nil then
      repeat
        hs.timer.usleep(0.05 * 1000000)
        winTotalDelay = winTotalDelay + 0.05
        if winTotalDelay > 1 then return end
        pane = getc(appUI, AX.Window, 1)
      until pane ~= nil
    end
    if OS_VERSION >= OS.Ventura then
      pane = getc(pane, AX.Group, 1)
    end
    if enterPanel() then
      registerControlCenterHotKeys(panel)
    end
  end
end

local controlCenterPanels = {
  CC.AirDrop, CC.Bluetooth, CC.Display, CC.Focus, CC.KbBrightness,
  CC.NowPlaying, CC.ScreenMirror, CC.Sound, CC.WiFi
}
if OS_VERSION >= OS.Ventura then
  tinsert(controlCenterPanels, CC.StageManager)
end
if OS_VERSION >= OS.Sonoma then
  tconcat(controlCenterPanels, { CC.AXShortcuts, CC.Battery, CC.User })
  if OS_VERSION >= OS.Sonoma:withMinor(2) then
    tinsert(controlCenterPanels, CC.MusicRecognition)
  end
  if OS_VERSION >= OS.Sonoma:withMinor(6) then
    tinsert(controlCenterPanels, CC.Hearing)
  end
end
if get(KeybindingConfigs.hotkeys, "com.apple.controlcenter") then
  for _, panel in ipairs(controlCenterPanels) do
    local hkID = panel:gsub(' ', '')
    hkID = hkID:sub(1, 1):lower() .. hkID:sub(2)
    local pos = panel:find('‑')
    if pos then
      hkID = hkID:sub(1, pos-1) .. hkID:sub(pos+3,pos+3):lower() .. hkID:sub(pos+4)
    end
    local spec = get(KeybindingConfigs.hotkeys, "com.apple.controlcenter", hkID)
    if spec == nil and panel == CC.MusicRecognition then
      spec = get(KeybindingConfigs.hotkeys, "com.apple.controlcenter", "musicRecognition")
    end
    if spec then
      bindControlCenterPanel(spec, panel, bind(popupControlCenterSubPanel, panel))
    end
  end
end

local controlCenterHotKeys = nil

local function checkAndRegisterControlCenterHotKeys(hotkey)
  if controlCenterHotKeys == nil then
    hotkey:delete()
    return false
  else
    hotkey:enable()
    tinsert(controlCenterHotKeys, hotkey)
    return true
  end
end

local hotkeyMainBack
local hotkeyShow, hotkeyHide
local backgroundSoundsHotkeys
local selectNetworkHotkeys, selectNetworkWatcher
local focusOptionHotkeys, focusOptionWatcher
---@diagnostic disable-next-line: lowercase-global
function registerControlCenterHotKeys(panel, inMenuBar)
  local appUI = toappui(find('com.apple.controlcenter'))

  -- Locate Control Center window and root pane.
  -- This may block briefly because Control Center UI is created lazily.
  local pane = getc(appUI, AX.Window, 1)
  local winTotalDelay = 0
  if pane == nil then
    repeat
      hs.timer.usleep(0.05 * 1000000)
      winTotalDelay = winTotalDelay + 0.05
      if winTotalDelay > 1 then return end
      pane = getc(appUI, AX.Window, 1)
    until pane ~= nil
  end
  -- Normalize root pane structure across macOS versions.
  -- Starting from Ventura, most Control Center content is nested under AX.Group.
  if OS_VERSION >= OS.Ventura then
    pane = getc(pane, AX.Group, 1)
    if panel == CC.Hearing then
      while #pane == 0 do
        hs.timer.usleep(0.05 * 1000000)
      end
      if #pane == 1 and pane[1].AXRole == AX.ScrollArea then
        pane = pane[1]
      end
    end
  end

  -- Helper to localize Control Center UI labels for the current panel.
  local function mayLocalize(value)
    return controlCenterLocalized(panel, value)
  end

  -- Clear previously registered Control Center hotkeys.
  -- Hotkeys are panel-scoped and must be recreated on each panel entry.
  if controlCenterHotKeys ~= nil then
    for _, hotkey in ipairs(controlCenterHotKeys) do
      hotkey:delete()
    end
  end
  controlCenterHotKeys = {}
  -- Reset transient hotkeys used by expandable UI elements
  -- (e.g. disclosure triangles, background sounds, network lists).
  if hotkeyShow ~= nil then
    hotkeyShow:delete()
    hotkeyShow = nil
  end
  if hotkeyHide ~= nil then
    hotkeyHide:delete()
    hotkeyHide = nil
  end
  if backgroundSoundsHotkeys ~= nil then
    for _, hotkey in ipairs(backgroundSoundsHotkeys) do
      hotkey:delete()
    end
    backgroundSoundsHotkeys = nil
  end

  -- Register hotkey to return to the main Control Center panel.
  -- This is only available when entering from a sub-panel.
  if not inMenuBar then
    local msg = "Back"
    local appLocale = applicationValidLocale('com.apple.controlcenter')
    if appLocale ~= nil then
      local result = localizedString(msg, 'com.apple.AppStore',
                                     { locale = appLocale })
      if type(result) == 'string' then
        msg = result
      end
    end
    hotkeyMainBack = newControlCenter("⌘", "[", msg,
    function()
      assert(hotkeyMainBack) hotkeyMainBack:disable()
      for _, hotkey in ipairs(controlCenterHotKeys) do
        hotkey:delete()
      end
      controlCenterHotKeys = {}
      if hotkeyShow ~= nil then
        hotkeyShow:delete()
        hotkeyShow = nil
      end
      if hotkeyHide ~= nil then
        hotkeyHide:delete()
        hotkeyHide = nil
      end
      if backgroundSoundsHotkeys ~= nil then
        for _, hotkey in ipairs(backgroundSoundsHotkeys) do
          hotkey:delete()
        end
        backgroundSoundsHotkeys = nil
      end

      local menuBarItem = tfind(getc(appUI, AX.MenuBar, -1, AX.MenuBarItem),
        function(item)
          return item.AXIdentifier == "com.apple.menuextra.controlcenter"
        end)
      menuBarItem:performAction(AX.Press)
    end)
    if not checkAndRegisterControlCenterHotKeys(hotkeyMainBack) then
      return
    end
  end

  -- Register shortcut to jump from Control Center panel
  -- to its corresponding System Settings page (if available).
  if tcontain({ CC.WiFi, CC.Bluetooth, CC.Focus, CC.KbBrightness,
                CC.ScreenMirror, CC.Display, CC.Sound,
                CC.AXShortcuts, CC.Battery,
                CC.Hearing, CC.User, }, panel) then
    local button, title
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      local buttons = getc(pane, AX.Button)
      for i = #buttons, 1, -1 do
        title = OS_VERSION < OS.Ventura and buttons[i].AXTitle
            or buttons[i].AXAttributedDescription:getString()
        if title:find("…") then
          button = buttons[i]
          break
        end
      end
    until button or totalDelay > 0.9 or not pane:isValid()
    if button then
      local hotkey = newControlCenter("⌘", ",", title,
          function() button:performAction(AX.Press) end)
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
  end

  -- Panels with a top-level enable/disable switch.
  -- Bind Space to toggle the main checkbox.
  if tcontain({CC.WiFi, CC.Bluetooth, CC.AirDrop}, panel) then
    local checkbox
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      local cbs = getc(appUI, AX.Window, 1, AX.CheckBox) or {}
      checkbox = tfind(cbs, function(cb)
        return cb.AXIdentifier ~= nil and cb.AXIdentifier:find("%-header") ~= nil
      end)
      if checkbox == nil then
        cbs = getc(appUI, AX.Window, 1, AX.Group, 1, AX.CheckBox) or {}
        checkbox = tfind(cbs, function(cb)
          return cb.AXIdentifier ~= nil and cb.AXIdentifier:find("%-header") ~= nil
        end)
      end
    until checkbox or totalDelay > 1
    if checkbox then
      local hotkey = newControlCenter("", "Space",
        "Toggle " .. controlCenterLocalized(panel),
        function() checkbox:performAction(AX.Press) end
      )
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
  end

  -- Panels containing a primary slider.
  -- Provide fine-grained and jump-to-min/max shortcuts.
  if tcontain({CC.Display, CC.Sound, CC.KbBrightness}, panel) then
    local name = panel == CC.Sound and "Volume" or "Brightness"
    local actions = {{ '=', 'Up'}, {'-', 'Down'}}
    if OS_VERSION < OS.Tahoe or panel == CC.Display or panel == CC.Sound then
      tconcat(actions, {{'[', 'Min'}, {']', 'Max'}})
    end
    local slider
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      if panel == CC.Display then
        local role = OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group
        slider = tfind(getc(pane, role, 1, AX.Slider) or {},
            function(ele) return ele.AXEnabled end)
      else
        slider = tfind(getc(pane, AX.Slider) or {},
            function(ele) return ele.AXEnabled end)
      end
    until slider or totalDelay > 0.9 or not pane:isValid()
    if slider then
      for _, spec in ipairs(actions) do
        local key = spec[1]
        local msg = name .. ' ' .. spec[2]
        local hotkey = newControlCenter("", key, msg,
          function()
            if key == '=' then
              slider:performAction(AX.Increment)
            elseif key == '-' then
              slider:performAction(AX.Decrement)
            elseif key == '[' then
              if OS_VERSION >= OS.Tahoe then
                if panel == CC.Sound then
                  local device = hs.audiodevice.defaultOutputDevice()
                  device:setVolume(0)
                elseif panel == CC.Display then
                  hs.brightness.set(0)
                end
              else
                slider.AXValue = 0
              end
            else
              if OS_VERSION >= OS.Tahoe then
                if panel == CC.Sound then
                  local device = hs.audiodevice.defaultOutputDevice()
                  device:setVolume(100)
                elseif panel == CC.Display then
                  hs.brightness.set(100)
                end
              else
                slider.AXValue = 100
              end
            end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end
  end

  -- Panels displaying a list of selectable devices.
  -- Dynamically assign numeric hotkeys to visible entries.
  if tcontain({CC.Bluetooth, CC.Sound, CC.ScreenMirror}, panel) then
    local cbs
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      cbs = tifilter(getc(pane, AX.ScrollArea, 1, AX.CheckBox) or {},
          function(cb) return cb.AXEnabled end)
      if #cbs == 0 and panel == CC.ScreenMirror then
        cbs = tifilter(getc(pane, AX.ScrollArea, 1,
            AX.Group, 1, AX.CheckBox) or {},
          function(cb) return cb.AXEnabled end)
        if #cbs == 0 then
          cbs = tifilter(getc(pane, AX.ScrollArea, 1,
              AX.Group, 1, AX.DisclosureTriangle) or {},
            function(cb) return cb.AXEnabled end)
        end
      end
    until #cbs > 0 or totalDelay > 1 or not pane:isValid()
    if #cbs > 0 then
      local deviceIDs
      if panel == CC.Bluetooth and OS_VERSION >= OS.Tahoe then
        deviceIDs = getBluetoothDevices()
      end
      local index = 0
      for _, cb in ipairs(cbs) do
        local enabled = cb.AXValue
        local name
        if OS_VERSION < OS.Ventura then
          name = cb.AXTitle
        elseif panel == CC.Bluetooth and OS_VERSION >= OS.Tahoe then
          local ident = cb.AXIdentifier
          local _, identIdx = ident:find("device-", 1, true)
          ident = ident:sub(identIdx + 1, -1)
          name = deviceIDs[ident] or ident
        elseif panel == CC.ScreenMirror and cb.AXAttributedDescription ~= nil then
          name = cb.AXAttributedDescription:getString()
        else
          name = cb.AXIdentifier
          local _, nameIdx = name:find("device-", 1, true)
          name = name:sub(nameIdx + 1, -1)
          if panel == CC.Sound then
            local desc = cb.AXAttributedDescription
            if desc and desc:find(name) == nil then
              name = nil
            end
          end
        end
        if name then
          index = index + 1
          local msg = "Connect to " .. name
          if enabled == nil or enabled == 1 then
            local newName = name:match("(.-), %d+%%$")
            if newName ~= nil then name = newName end
            msg = "Disconnect to " .. name
          end
          local hotkey = newControlCenter("", tostring(index%10), msg,
              function()
                cb:performAction(AX.Press)
              end)
          if not checkAndRegisterControlCenterHotKeys(hotkey) then
            return
          end
        end
      end
    end
  end

  -- Helper to register left/right arrow hotkeys
  -- for expanding or collapsing disclosure sections.
  local registerHotkeyForTraingleDisclosure = function(actionFunc, msg, enabled)
    if enabled == 0 then
      hotkeyShow = newControlCenter("", "Right", "Show " .. msg,
        function()
          assert(hotkeyShow) hotkeyShow:disable()
          actionFunc()
          if hotkeyHide == nil then
            hotkeyHide = newControlCenter("", "Left", "Hide " .. msg,
              function()
                assert(hotkeyHide) hotkeyHide:disable()
                assert(hotkeyShow) hotkeyShow:enable()
                actionFunc()
              end)
          end
          assert(hotkeyHide) hotkeyHide:enable()
        end)
      assert(hotkeyShow) hotkeyShow:enable()
    else
      hotkeyHide = newControlCenter("", "Left", "Hide " .. msg,
        function()
          assert(hotkeyHide) hotkeyHide:disable()
          actionFunc()
          if hotkeyShow == nil then
            hotkeyShow = newControlCenter("", "Right", "Show " .. msg,
              function()
                assert(hotkeyShow) hotkeyShow:disable()
                hotkeyHide:enable()
                actionFunc()
              end)
          end
          assert(hotkeyShow) hotkeyShow:enable()
        end)
      assert(hotkeyHide) hotkeyHide:enable()
    end
  end

  if panel == CC.WiFi then
    -- Wi-Fi panel special handling:
    -- - Expand "Other Networks"
    -- - Bind numeric keys to available SSIDs
    -- - Track list changes dynamically
    local triangle
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      local sa = getc(pane, AX.ScrollArea, 1)
      if sa and sa[1] and sa[1].AXRole == AX.OpaqueProviderGroup then
        sa = sa[1]
      end
      triangle = getc(sa, AX.DisclosureTriangle, 1)
    until triangle or totalDelay > 0.5 or not pane:isValid()
    if triangle then
      local actionFunc = function()
        local actions = triangle:actionNames()
        triangle:performAction(actions[#actions])
      end
      local localizedOtherNetworks = mayLocalize("Other Networks")
      registerHotkeyForTraingleDisclosure(actionFunc,
          localizedOtherNetworks, triangle.AXValue)
    end

    -- select network
    selectNetworkHotkeys = {}
    local availableNetworksString = ""
    local selectNetworkActionFunc = function()
      if not pane:isValid()
          or pane[1] == nil or pane[1].AXIdentifier == nil then
        return
      end
      if pane[1].AXValue ~= controlCenterLocalized(panel) then
        return
      end
      local sa
      local totalDelay = 0
      repeat
        hs.timer.usleep(0.05 * 1000000)
        totalDelay = totalDelay + 0.05
        sa = getc(pane, AX.ScrollArea, 1)
        if sa and sa[1] and sa[1].AXRole == AX.OpaqueProviderGroup then
          sa = sa[1]
        end
      until sa or totalDelay > 0.5 or not pane:isValid()
      if sa then
        local availableNetworks = {}
        local cbs = tifilter(sa.AXChildren, function(ele)
          return ele.AXRole == AX.CheckBox or ele.AXRole == AX.Button
        end)
        for _, cb in ipairs(cbs) do
          local title
          if OS_VERSION < OS.Ventura then
            title = cb.AXTitle:match("([^,]+)")
          elseif cb.AXIdentifier then
            title = cb.AXIdentifier:sub(string.len("wifi-network-") + 1, -1)
          end
          if title then
            tinsert(availableNetworks, title)
            if #availableNetworks >= 10 then break end
          end
        end
        local newAvailableNetworksString = table.concat(availableNetworks, "|")
        if newAvailableNetworksString ~= availableNetworksString then
          availableNetworksString = newAvailableNetworksString
          for _, hotkey in ipairs(selectNetworkHotkeys or {}) do
            hotkey:delete()
          end
          selectNetworkHotkeys = {}
          local ssid
          for idx, title in ipairs(availableNetworks) do
            local selected = cbs[idx].AXValue
            local connected = false
            if cbs[idx].AXRole == AX.CheckBox and selected == 1 then
              connected = true
            elseif cbs[idx].AXRole == AX.Button then
              ssid = ssid or getSSID()
              if title == ssid then
                connected = true
              end
            end
            local msg = (connected and "Disconnect to " or "Connect to ") .. title
            local hotkey = newControlCenter("", tostring(idx % 10), msg,
              function()
                local cb = cbs[idx]
                local actions = cb:actionNames()
                cb:performAction(actions[#actions])
              end)
            assert(hotkey) hotkey:enable()
            tinsert(selectNetworkHotkeys, hotkey)
          end
        end
      else
        for _, hotkey in ipairs(selectNetworkHotkeys or {}) do
          hotkey:delete()
        end
        selectNetworkHotkeys = nil
      end
    end
    selectNetworkActionFunc()
    selectNetworkWatcher = ExecContinuouslyQuick(selectNetworkActionFunc)
  elseif panel == CC.AirDrop then
    -- AirDrop panel:
    -- Bind numeric keys to switch AirDrop visibility modes.
    local cb
    repeat
      hs.timer.usleep(0.05 * 1000000)
      cb = getc(pane, AX.CheckBox, 3)
    until cb or not pane:isValid()
    if cb then
      local cbs = { getc(pane, AX.CheckBox, 2), cb }
      local toggleNames
      if OS_VERSION < OS.Ventura then
        toggleNames = { cbs[1].AXTitle, cbs[2].AXTitle }
      else
        toggleNames = { cbs[1].AXAttributedDescription:getString(),
                        cbs[2].AXAttributedDescription:getString() }
      end
      for i=1,2 do
        local hotkey = newControlCenter("", tostring(i), toggleNames[i],
            function() cbs[i]:performAction(AX.Press) end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end
  elseif panel == CC.Focus then
    -- Focus panel supports hierarchical options.
    -- First-level keys toggle focus modes,
    -- second-level keys control options of the active mode.
    local cb1
    repeat
      hs.timer.usleep(0.05 * 1000000)
      cb1 = getc(pane, AX.CheckBox, 1)
    until cb1 or not pane:isValid()
    if cb1 then
      local h = getc(pane, AX.CheckBox, 1).AXSize.h
      local cbs = tifilter(getc(pane, AX.CheckBox),
          function(cb) return cb.AXSize.h >= h end)
      local toggleNames
      if OS_VERSION < OS.Ventura then
        toggleNames = hs.fnutils.imap(cbs,
            function(cb) return cb.AXTitle end)
      else
        toggleNames = hs.fnutils.imap(cbs,
            function(cb) return cb.AXAttributedDescription:getString() end)
      end
      for i=1,#toggleNames do
        local hotkey = newControlCenter("", tostring(i),
            toggleNames[i],
            function() cbs[i]:performAction(AX.Press) end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
      local focusOptionIndex
      local registerFocusOptionsFunc = function()
        if not pane:isValid()
            or pane[1] == nil or pane[1].AXIdentifier == nil then
          return
        end
        if pane[1].AXValue ~= controlCenterLocalized(panel) then
          return
        end
        local index
        cbs = tifilter(getc(pane, AX.CheckBox),
            function(cb) return cb.AXSize.h >= h end)
        for i, cb in ipairs(cbs) do
          if cb.AXValue == 1 then
            index = i break
          end
        end
        if index == focusOptionIndex then return end
        focusOptionIndex = index
        for _, hotkey in ipairs(focusOptionHotkeys or {}) do
          hotkey:delete()
        end
        focusOptionHotkeys = nil
        if index == nil then return end
        focusOptionHotkeys = {}
        local opts = tifilter(getc(pane, AX.CheckBox),
            function(cb) return cb.AXSize.h < h end)
        if #opts < 2 then
          hs.timer.usleep(0.05 * 1000000)
          opts = tifilter(getc(pane, AX.CheckBox),
              function(cb) return cb.AXSize.h < h end)
        end
        for i=1,#opts do
          local title = opts[i].AXAttributedDescription:getString()
          local hotkey = newControlCenter("⌘", tostring(i),
              toggleNames[index] .. " > " .. title,
              function() opts[i]:performAction(AX.Press) end)
          assert(hotkey) hotkey:enable()
          tinsert(focusOptionHotkeys, hotkey)
        end
      end
      registerFocusOptionsFunc()
      focusOptionWatcher = ExecContinuouslyQuick(registerFocusOptionsFunc)
    else
      for _, hotkey in ipairs(focusOptionHotkeys or {}) do
        hotkey:delete()
      end
      focusOptionHotkeys = nil
    end
  elseif panel == CC.Display then
    -- Display panel:
    -- Provide shortcuts for display toggles (Dark Mode / Night Shift / True Tone),
    -- brightness control, and external display options.
    local role = OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group
    local sa1
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      sa1 = getc(pane, role, 1)
    until sa1 or totalDelay > 0.5 or not pane:isValid()
    local i, j
    for m, sa in ipairs(getc(pane, role)) do
      for nn =1,#sa do
        local n = #sa - nn + 1
        if sa[n].AXRole == AX.DisclosureTriangle then
          i, j = m, n
          break
        end
      end
    end
    if i and j then
      local elem = getc(pane, role, i, nil, j)
      if elem then
        local hotkey = newControlCenter("", "Space",
            "Toggle Showing Display Presets",
            function() elem:performAction(AX.Press) end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end

    local area = getc(appUI, AX.Window, 1,
        OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group, 1)
    local cb3
    repeat
      hs.timer.usleep(0.05 * 1000000)
      cb3 = getc(area, AX.CheckBox, 3)
    until cb3 or not pane:isValid()
    if cb3 == nil then return end
    local cbs = getc(area, AX.CheckBox)
    local cbTitles = tmap(cbs, function (cb)
      return cb.AXAttributedDescription:getString()
    end)
    local cbIdents = tmap(cbs, function (cb)
      return cb.AXIdentifier
    end)
    local enableds = tmap(cbs, function (cb)
      return cb.AXValue
    end)
    for i=1,3 do
      local checkbox = tfind({"Dark Mode", "Night Shift", "True Tone"},
        function(ele)
          return cbTitles[i]:find(mayLocalize(ele))
        end)
      local op = enableds[i] == 0 and "Enable" or "Disable"
      local hotkey = newControlCenter("", tostring(i),
        op .. " " .. mayLocalize(checkbox),
        function()
          local cb = getc(area, AX.CheckBox, i)
          if not cb then return end
          cb:performAction(AX.Press)
          enableds[i] = 1 - enableds[i]
        end)
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
    for i=4,#cbs do
      if i - 3 > 10 then break end
      local _, nameIdx = cbIdents[i]:find("device-", 1, true)
      local device = cbIdents[i]:sub(nameIdx + 1, -1)
      local msg
      if enableds[i] == 0 then
        msg = "Connect to " .. device
      else
        msg = "Disconnect to " .. device
      end
      local hotkey = newControlCenter("⌘", tostring((i-3)%10), msg,
        function()
          local cb = getc(area, AX.CheckBox, i)
          if cb then cb:performAction(AX.Press) end
        end)
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
  elseif panel == CC.MusicRecognition then
    -- Music Recognition panel:
    -- Bind shortcut to start or stop music recognition.
    local msg = controlCenterLocalized(panel, "Start Listening")
    if type(msg) ~= 'string' then return end
    local hotkey = newControlCenter("", "Space", msg,
      function()
        local cb
        if OS_VERSION < OS.Tahoe then
          cb = getc(pane, AX.Group, 1, AX.CheckBox, 1)
        else
          cb = getc(pane, AX.Group, 1, AX.Group, 1, AX.CheckBox, 1)
        end
        if cb then cb:performAction(AX.Press) end
      end)
    if not checkAndRegisterControlCenterHotKeys(hotkey) then
      return
    end
  elseif panel == CC.Hearing then
    -- Hearing panel:
    -- Control background sounds, volume sliders, and sound profiles
    -- with expandable disclosure support.
    local hearingFunc
    hearingFunc = function()
      if hotkeyShow ~= nil then
        hotkeyShow:delete()
        hotkeyShow = nil
      end
      if hotkeyHide ~= nil then
        hotkeyHide:delete()
        hotkeyHide = nil
      end
      for _, hotkey in ipairs(backgroundSoundsHotkeys or {}) do
        hotkey:delete()
      end
      backgroundSoundsHotkeys = nil
      local slid
      local totalDelay = 0
      repeat
        hs.timer.usleep(0.05 * 1000000)
        totalDelay = totalDelay + 0.05
        slid = getc(pane, AX.Slider, 1)
      until slid or totalDelay > 1 or not pane:isValid()
      if slid == nil then
        local triangle = getc(pane, AX.DisclosureTriangle, 1)
        if triangle == nil then
          return
        end
      end

      local actionFunc
      local triangle = getc(pane, AX.DisclosureTriangle, 1)
      actionFunc = function()
        local actions = triangle:actionNames()
        local actIdx = pane.AXRole == AX.ScrollArea and 2 or 1
        triangle:performAction(actions[actIdx])
        hearingFunc()
      end
      registerHotkeyForTraingleDisclosure(actionFunc, "Sounds",
                                          slid and 1 or 0)
      if slid == nil then return end

      local sliders = getc(pane, AX.Slider)
          or getc(pane, AX.Slider)
      local enabledSliders = tifilter(sliders,
          function(slid) return slid.AXEnabled end)
      if #enabledSliders == 1 then
        if backgroundSoundsHotkeys == nil then
          backgroundSoundsHotkeys = {}
        end
        local actions = {{ '=', 'Up'}, {'-', 'Down'}}
        if OS_VERSION < OS.Tahoe then
          tconcat(actions, {{'[', 'Min'}, {']', 'Max'}})
        end
        for _, spec in pairs(actions) do
          local key = spec[1]
          local slid = enabledSliders[1]
          local hotkey = newControlCenter("", key, "Volume " .. spec[2],
            function()
              if key == '=' then
                slid:performAction(AX.Increment)
              elseif key == '-' then
                slid:performAction(AX.Decrement)
              elseif key == '[' then
                slid.AXValue = 0
              else
                slid.AXValue = 100
              end
            end)
          assert(hotkey) hotkey:enable()
          tinsert(backgroundSoundsHotkeys, hotkey)
        end
      end

      local cbs
      repeat
        hs.timer.usleep(0.05 * 1000000)
        cbs = getc(pane, AX.CheckBox)
        if cbs == nil then
          cbs = tifilter(getc(pane, AX.CheckBox) or {}, function(cb)
            return cb.AXIdentifier and cb.AXIdentifier:find("button%-identifier") end)
        end
      until #cbs > 0
      if #cbs > 1 then
        if backgroundSoundsHotkeys == nil then
          backgroundSoundsHotkeys = {}
        end
        for i=1,math.min(#cbs, 10) do
          local msg = cbs[i].AXAttributedDescription:getString()
          local hotkey = newControlCenter("", tostring(i % 10), msg,
              function() cbs[i]:performAction(AX.Press) end)
          assert(hotkey) hotkey:enable()
          tinsert(backgroundSoundsHotkeys, hotkey)
        end
      end
    end

    local hotkey = newControlCenter("", "Space",
      "Toggle " .. mayLocalize("Background Sounds"),
      function()
        if hotkeyShow ~= nil then
          hotkeyShow:delete()
          hotkeyShow = nil
        end
        if hotkeyHide ~= nil then
          hotkeyHide:delete()
          hotkeyHide = nil
        end
        for _, hotkey in ipairs(backgroundSoundsHotkeys or {}) do
          hotkey:delete()
        end
        backgroundSoundsHotkeys = nil
        local cb = getc(pane, AX.DisclosureTriangle, 1)
            or getc(pane, AX.CheckBox, 1)
        if cb then
          cb:performAction(AX.Press)
          hs.timer.doAfter(0.2,  hearingFunc)
        end
      end)
    if not checkAndRegisterControlCenterHotKeys(hotkey) then
      return
    end

    hearingFunc()
  elseif panel == CC.NowPlaying then
    -- Now Playing panel:
    -- Bind media transport controls and per-session playback shortcuts.
    local result
    local button2
    repeat
      hs.timer.usleep(0.05 * 1000000)
      if OS_VERSION >= OS.Tahoe then
        button2 = getc(pane, AX.Group, 1, AX.Button, 2)
      else
        button2 = getc(pane, AX.Button, 2)
      end
    until button2 or not pane:isValid()
    if button2 then
      if OS_VERSION >= OS.Tahoe then
        pane = getc(pane, AX.Group, 1)
      end
      if OS_VERSION < OS.Ventura then
        result = tmap(getc(pane, AX.Button),
            function(bt) return bt.AXTitle end)
      else
        result = #getc(pane, AX.Button)
      end
      if (type(result) == "number" and result == 3)
          or (type(result) == "table" and #result == 3) then
        if result == 3 then
          result = {
            mayLocalize("previous"),
            mayLocalize("play") .. "/" .. mayLocalize("pause"),
            mayLocalize("next")
          }
        end
        local hotkey
        hotkey = newControlCenter("", "Space", result[2],
          function()
            local defaultMusicAppForControlCenter =
                ApplicationConfigs["defaultMusicAppForControlCenter"]
            if defaultMusicAppForControlCenter ~= nil then
              local launchCustomizedApp = false
              local appTitle = getc(pane, AX.StaticText, 1)
              if OS_VERSION < OS.Tahoe then
                local appname = displayName('com.apple.Music')
                if appTitle and appTitle.AXValue == appname .. '.app' then
                  launchCustomizedApp = true
                end
              else
                if appTitle and appTitle.AXValue == mayLocalize("Not Playing") then
                  launchCustomizedApp = true
                end
              end
              if launchCustomizedApp then
                if type(defaultMusicAppForControlCenter) == 'string' then
                  defaultMusicAppForControlCenter =
                      { defaultMusicAppForControlCenter }
                end
                for _, appid in ipairs(defaultMusicAppForControlCenter) do
                  if installed(appid) then
                    hs.application.launchOrFocusByBundleID(appid)
                    return
                  end
                end
              end
            end
            local button = getc(pane, AX.Button, 2)
            if button then button:performAction(AX.Press) end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
        local buttonLeft = getc(pane, AX.Button, 1)
        if buttonLeft and buttonLeft.AXEnabled then
          hotkey = newControlCenter("", "Left", result[1],
            function()
              if buttonLeft then buttonLeft:performAction(AX.Press) end
            end)
          if not checkAndRegisterControlCenterHotKeys(hotkey) then
            return
          end
        end
        local buttonRight = getc(pane, AX.Button, 3)
        if buttonRight and buttonRight.AXEnabled then
          hotkey = newControlCenter("", "Right", result[3],
            function()
              if buttonRight then buttonRight:performAction(AX.Press) end
            end)
          if not checkAndRegisterControlCenterHotKeys(hotkey) then
            return
          end
        end
      elseif (type(result) == "number" and result > 3)
          or (type(result) == "table" and #result > 3) then
        local nEntries
        if type(result) == "number" then
          nEntries = result / 2
        else
          nEntries = #result / 2
        end
        for i = 1, nEntries do
          local buttonLabel = mayLocalize("play")
              .. "/" .. mayLocalize("pause")
          local hotkey = newControlCenter("", tostring(i),
            type(result) == "number" and buttonLabel or result[2*i-1],
            function()
              local button = getc(pane, AX.Button, 2 * i - 1)
              if button then button:performAction(AX.Press) end
            end)
          if not checkAndRegisterControlCenterHotKeys(hotkey) then
            return
          end
        end
      elseif result == 2 then
        for i, g in ipairs(getc(pane, AX.Group)) do
          local buttonLabel = mayLocalize("play")
              .. "/" .. mayLocalize("pause")
          local hotkey = newControlCenter("", tostring(i), buttonLabel,
            function()
              local button = getc(g, AX.Button, 1)
              if button then button:performAction(AX.Press) end
            end)
          if not checkAndRegisterControlCenterHotKeys(hotkey) then
            return
          end
        end
      end
    end
  end
end

-- Handle Control Center window creation and register dynamic hotkeys
local controlCenter = find("com.apple.controlcenter")
ControlCenterObserver = uiobserver.new(controlCenter:pid())
ControlCenterObserver:addWatcher(
  toappui(controlCenter),
  uinotifications.windowCreated
)

local function controlCenterObserverCallback()
  if controlCenter:focusedWindow() == nil then return end
  local controlCenterDestroyObserver =
      uiobserver.new(controlCenter:pid())
  if OS_VERSION >= OS.Tahoe then
    controlCenterDestroyObserver:addWatcher(
      toappui(controlCenter),
      uinotifications.uIElementDestroyed
    )
  else
    controlCenterDestroyObserver:addWatcher(
      towinui(controlCenter:focusedWindow()),
      uinotifications.uIElementDestroyed
    )
  end
  controlCenterDestroyObserver:callback(function()
    if OS_VERSION >= OS.Tahoe then
      local win = controlCenter:focusedWindow()
      if win and win:title() == controlCenter:name() then
        return
      end
    end
    if selectNetworkWatcher ~= nil then
      StopExecContinuously(selectNetworkWatcher)
      selectNetworkWatcher = nil
    end
    if selectNetworkHotkeys ~= nil then
      for _, hotkey in ipairs(selectNetworkHotkeys) do
        hotkey:delete()
      end
      selectNetworkHotkeys = nil
    end
    if focusOptionWatcher ~= nil then
      StopExecContinuously(focusOptionWatcher)
      focusOptionWatcher = nil
    end
    if focusOptionHotkeys ~= nil then
      for _, hotkey in ipairs(focusOptionHotkeys) do
        hotkey:delete()
      end
      focusOptionHotkeys = nil
    end
    if controlCenterHotKeys ~= nil then
      for _, hotkey in ipairs(controlCenterHotKeys) do
        hotkey:delete()
      end
      controlCenterHotKeys = nil
    end
    hotkeyMainBack = nil
    if hotkeyShow ~= nil then
      hotkeyShow:delete()
      hotkeyShow = nil
    end
    if hotkeyHide ~= nil then
      hotkeyHide:delete()
      hotkeyHide = nil
    end
    if backgroundSoundsHotkeys ~= nil then
      for _, hotkey in ipairs(backgroundSoundsHotkeys) do
        hotkey:delete()
      end
      backgroundSoundsHotkeys = nil
    end
    controlCenterDestroyObserver:stop()
    controlCenterDestroyObserver = nil
  end)
  controlCenterDestroyObserver:start()
end
ControlCenterObserver:callback(controlCenterObserverCallback)
ControlCenterObserver:start()

-- Detect currently active Control Center panel
local function getActiveControlCenterPanel()
  local appUI = toappui(find('com.apple.controlcenter'))
  local pane = getc(appUI, AX.Window, 1)
  if OS_VERSION >= OS.Ventura then
    pane = getc(pane, AX.Group, 1)
  end

  for _, panel in pairs(controlCenterPanels) do
    if testAlready(panel, pane) then
      return panel
    end
  end
end
if hs.window.focusedWindow() ~= nil
    and hs.window.focusedWindow():application():bundleID()
        == "com.apple.controlcenter"
    and hs.window.focusedWindow():subrole()
        == AX.SystemDialog then
  local frame = hs.window.focusedWindow():frame()
  local scrFrame = hs.screen.mainScreen():fullFrame()
  local inMenuBar = frame.x + frame.w ~= scrFrame.x + scrFrame.w
  registerControlCenterHotKeys(getActiveControlCenterPanel(),
                               inMenuBar)
  controlCenterObserverCallback()
end

ExecOnSilentLaunch("com.apple.controlcenter", function(app)
  ControlCenterObserver:stop()
  ControlCenterObserver = nil
  hs.timer.doAfter(2, function()
    controlCenter = app
    ControlCenterObserver = uiobserver.new(controlCenter:pid())
    ControlCenterObserver:addWatcher(
      toappui(controlCenter),
      uinotifications.windowCreated)
    ControlCenterObserver:callback(controlCenterObserverCallback)
    ControlCenterObserver:start()
  end)
end)
