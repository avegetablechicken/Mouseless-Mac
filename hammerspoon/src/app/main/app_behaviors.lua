-- ## configure specific apps

-- ### Mountain Duck
-- connect to servers on launch
local function connectMountainDuckEntries(app, connection)
  local appUI = toappui(app)
  local menuBar = getc(appUI.AXExtrasMenuBar, AX.Menu, 1)

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
        local condition = connection.condition
        if condition ~= nil then
          connection.condition = function()
            if condition.shell_command == nil then return executeCondition(condition) end
            local rc = executeCondition(condition, true)
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
    local ok = pcall(observer.addWatcher, observer, toappui(app), uinotifications.windowCreated)
    if not ok then
      observer:stop()
      return
    end
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
if installed("com.MonoCloud.MonoProxyMac") and applicationVersion("com.MonoCloud.MonoProxyMac") < "1.0.9" then
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
local function AppBehavior_monitorChangedCallback()
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

registerMonitorChangedCallback(AppBehavior_monitorChangedCallback)

-- usb callbacks

-- launch `MacDroid` automatically when connected to android phone
local phones = ApplicationConfigs.androidDevices or {}
local phonesManagers = ApplicationConfigs.manageAndroidDevices or {}
if type(phonesManagers) == 'string' then phonesManagers = { phonesManagers } end
local function isConfiguredPhone(device)
  return any(phones, function(phone)
    return device.productName == phone[1] and device.vendorName == phone[2]
  end)
end
local attachedPhones = {}
local function phoneKey(device)
  return table.concat({ tostring(device.vendorID), tostring(device.productID),
    device.vendorName or "", device.productName or "" }, "\0")
end
for _, device in ipairs(hs.usb.attachedDevices() or {}) do
  if isConfiguredPhone(device) then
    local key = phoneKey(device)
    attachedPhones[key] = (attachedPhones[key] or 0) + 1
  end
end

local function AppBehavior_usbChangedCallback(device)
  if not isConfiguredPhone(device) then return end
  local key = phoneKey(device)
  if device.eventType == "added" then
    attachedPhones[key] = (attachedPhones[key] or 0) + 1
    for _, appid in ipairs(phonesManagers) do
      if installed(appid) then
        hs.execute(strfmt("open -g -b '%s'", appid))
        return
      end
    end
  elseif device.eventType == "removed" then
    local count = attachedPhones[key]
    if count == nil then return end
    attachedPhones[key] = count > 1 and count - 1 or nil
    if next(attachedPhones) == nil then
      for _, appid in ipairs(phonesManagers) do
        quit(appid)
        if appid == "us.electronic.macdroid" then quit('MacDroid Extension') end
      end
    end
  end
end

registerUsbChangedCallback(AppBehavior_usbChangedCallback)
