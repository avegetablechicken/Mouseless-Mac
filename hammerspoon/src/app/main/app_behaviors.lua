-- ## configure specific apps

-- ### Mountain Duck
-- connect to servers on launch
local function connectMountainDuckEntries(app, connection)
  local appUI = toappui(app)
  local menuBar = getc(appUI, AX.MenuBar, -1, AX.Menu, 1)

  if type(connection) == 'string' then
    local menuItem = getc(menuBar, AX.MenuItem, connection,
        AX.Menu, 1, AX.MenuItem, 1)
    if menuItem ~= nil then
      Callback.Press(menuItem)
    end
  else
    local fullfilled = connection.condition(app)
    if fullfilled == nil then return end
    local connects = connection[connection.locations[fullfilled and 1 or 2]]
    local disconnects = connection[connection.locations[fullfilled and 2 or 1]]
    for _, item in ipairs(connects) do
      local menuItem = getc(menuBar, AX.MenuItem, item,
          AX.Menu, 1, AX.MenuItem, 1)
      if menuItem ~= nil then
        Callback.Press(menuItem)
      end
    end
    local disconnect = localizedString('Disconnect', app:bundleID())
    for _, item in ipairs(disconnects) do
      local menuItem = getc(menuBar, AX.MenuItem, item,
          AX.Menu, 1, AX.MenuItem, disconnect)
      if menuItem ~= nil then
        Callback.Press(menuItem)
      end
    end
  end
end
do
  local mountainDuckConfig = ApplicationConfigs["io.mountainduck"]
  if mountainDuckConfig ~= nil and mountainDuckConfig.connections ~= nil then
    for _, connection in ipairs(mountainDuckConfig.connections) do
      if type(connection) == 'table' then
        local shell_command = get(connection, "condition", "shell_command")
        if shell_command ~= nil then
          connection.condition = function()
            local _, _, _, rc = hs.execute(shell_command)
            if rc == 0 then
              return true
            elseif rc == 1 then
              return false
            else
              return nil
            end
          end
        else
          connection.condition = nil
        end
      end
    end
    Evt.OnRunning("io.mountainduck", function(app)
      for _, connection in ipairs(mountainDuckConfig.connections) do
        connectMountainDuckEntries(app, connection)
      end
    end)
  end
end

-- ## Barrier
-- barrier window may not be focused when it is created, so focus it
-- note: barrier is mistakenly recognized as an app prohibited from having GUI elements,
--       so window filter does not work unless the app is activated once.
--       we use uielement observer instead
if installed("barrier") then
  Evt.OnRunning("barrier", function(app)
    local observer = uiobserver.new(app:pid())
    observer:addWatcher(toappui(app), uinotifications.windowCreated)
    observer:callback(function(_, winUI) winUI:asHSWindow():focus() end)
    observer:start()
    Evt.StopOnTerminated(app, observer)
  end)
end

-- ## Dash (version < 7 on macOS Tahoe and later)
if installed("com.kapeli.dashdoc") then
  Evt.OnLaunched("com.kapeli.dashdoc", function(app)
    local win = app:focusedWindow()
    if win and win:subrole() == AX.Dialog then
      local winUI = towinui(win)
      local text = getc(winUI, AX.StaticText, 1)
      if text and text.AXValue == "Operating system not supported" then
        local cancel = getc(winUI, AX.Button, "Cancel")
        if cancel then Callback.Press(cancel) end
        return
      end
    end
    local observer = uiobserver.new(app:pid())
    observer:addWatcher(toappui(app), uinotifications.windowCreated)
    observer:callback(function(obs, winUI)
      if winUI.AXSubrole == AX.Dialog then
        local text = getc(winUI, AX.StaticText, 1)
        if text and text.AXValue == "Operating system not supported" then
          local cancel = getc(winUI, AX.Button, "Cancel")
          if cancel then Callback.Press(cancel) end
          obs:stop() obs = nil
        end
      end
    end)
    observer:start()
    Evt.StopOnTerminated(app, observer)
  end)
end

-- MonoProxyMac
if installed("com.MonoCloud.MonoProxyMac") then
  Evt.OnLaunched("com.MonoCloud.MonoProxyMac", function(app)
    local observer = uiobserver.new(app:pid())
    observer:addWatcher(toappui(app), uinotifications.windowCreated)
    observer:callback(function(obs, winUI)
      local text = getc(winUI, AX.StaticText, 1)
      if text and text.AXValue == "Helper install fail!" then
        local confirm = getc(winUI, AX.Button, "OK")
        if confirm then Callback.Press(confirm) end
        obs:stop() obs = nil
      end
    end)
    observer:start()
    Evt.StopOnTerminated(app, observer)

    local win = app:focusedWindow()
    if win and win:subrole() == AX.Dialog then
      local winUI = towinui(win)
      local text = getc(winUI, AX.StaticText, 1)
      if text and text.AXValue == "Chute icon not visible" then
        local confirm = getc(winUI, AX.Button, "OK")
        if confirm then Callback.Press(confirm) end
        return
      end
    end
    local observer = uiobserver.new(app:pid())
    observer:addWatcher(toappui(app), uinotifications.windowCreated)
    observer:callback(function(obs, winUI)
      if winUI.AXSubrole == AX.Dialog then
        local text = getc(winUI, AX.StaticText, 1)
        if text and text.AXValue == "Chute icon not visible" then
          local confirm = getc(winUI, AX.Button, "OK")
          if confirm then Callback.Press(confirm) end
          obs:stop() obs = nil
        end
      end
    end)
    observer:start()
    Evt.StopOnTerminated(app, observer)
  end)
end


-- ## callbacks

-- monitor callbacks

-- launch applications automatically when connected to an external monitor
function AppBehavior_monitorChangedCallback()
  local screens = hs.screen.allScreens()

  -- only for built-in monitor
  local builtinMonitorEnable = any(screens, function(screen)
    return screen:name() == "Built-in Retina Display"
  end)
  if builtinMonitorEnable then
    -- hs.application.launchOrFocusByBundleID("pl.maketheweb.TopNotch")
  else
    quit("pl.maketheweb.TopNotch")
  end

  -- for external monitors
  if (builtinMonitorEnable and #screens > 1)
    or (not builtinMonitorEnable and #screens > 0) then
    if find("me.guillaumeb.MonitorControl") == nil then
      hs.execute([[open -g -b "me.guillaumeb.MonitorControl"]])
    end
  elseif builtinMonitorEnable and #screens == 1 then
    quit("me.guillaumeb.MonitorControl")
  end
end

-- usb callbacks

-- launch `MacDroid` automatically when connected to android phone
local phones = ApplicationConfigs.androidDevices or {}
local phonesManagers = ApplicationConfigs.manageAndroidDevices or {}
if type(phonesManagers) == 'string' then phonesManagers = { phonesManagers } end
local attached_android_count = 0

function AppBehavior_usbChangedCallback(device)
  if device.eventType == "added" then
    attached_android_count = attached_android_count + 1
    for _, phone in ipairs(phones) do
      if device.productName == phone[1] and device.vendorName == phone[2] then
        for _, appid in ipairs(phonesManagers) do
          if installed(appid) then
            hs.execute(strfmt("open -g -b '%s'", appid))
            return
          end
        end
      end
    end
  elseif device.eventType == "removed" then
    attached_android_count = attached_android_count - 1
    if attached_android_count == 0 then
      for _, appid in ipairs(phonesManagers) do
        quit(appid)
        if appid == "us.electronic.macdroid" then
          quit('MacDroid Extension')
        end
      end
    end
  end
end