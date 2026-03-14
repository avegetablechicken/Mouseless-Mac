-- auto hide or quit apps with no windows (including pseudo windows such as popover or sheet)
local appsWithoutWindow = { hide = {}, quit = {} }
-- account for pseudo windows such as popover or sheet
local appsWithNoPseudoWindow = { hide = {}, quit = {} }
-- some apps may first close a window before create a targeted one, so delay is needed before checking
local appsWithoutWindowDelay = {}

do
  local appsHideWithoutWindowLoaded = ApplicationConfigs["hideWithoutWindow"] or {}
  local appsQuitWithoutWindowLoaded = ApplicationConfigs["quitWithoutWindow"] or {}

  for _, item in ipairs(appsHideWithoutWindowLoaded) do
    if type(item) == 'string' then
      appsWithoutWindow.hide[item] = true
    else
      for appid, cfg in pairs(item) do
        local windowFilter
        for k, v in pairs(cfg) do
          if (k == "allowPopover" or k == "allowSheet") and v then
            appsWithNoPseudoWindow.hide[appid] = {}
            if k == "allowPopover" then
              tinsert(appsWithNoPseudoWindow.hide[appid], AX.Popover)
            end
            if k == "allowSheet" then
              tinsert(appsWithNoPseudoWindow.hide[appid], AX.Sheet)
            end
          elseif k == "delay" then
            appsWithoutWindowDelay[appid] = v
          else
            if windowFilter == nil then windowFilter = {} end
            windowFilter[k] = v
          end
        end
        appsWithoutWindow.hide[appid] = windowFilter or true
      end
    end
  end
  for _, item in ipairs(appsQuitWithoutWindowLoaded) do
    if type(item) == 'string' then
      appsWithoutWindow.quit[item] = true
    else
      for appid, cfg in pairs(item) do
        local windowFilter
        for k, v in pairs(cfg) do
          if (k == "allowPopover" or k == "allowSheet") and v then
            appsWithNoPseudoWindow.quit[appid] = {}
            if k == "allowPopover" then
              tinsert(appsWithNoPseudoWindow.quit[appid], AX.Popover)
            end
            if k == "allowSheet" then
              tinsert(appsWithNoPseudoWindow.quit[appid], AX.Sheet)
            end
          elseif k == "delay" then
            appsWithoutWindowDelay[appid] = v
          else
            if windowFilter == nil then windowFilter = {} end
            windowFilter[k] = v
          end
        end
        appsWithoutWindow.quit[appid] = windowFilter or true
      end
    end
  end
end

local specialNoWindowRules = {
  ["com.apple.finder"] = function(app)
    if #hs.window.visibleWindows() == 1 and (hs.window.desktop()
        and hs.window.visibleWindows()[1]:id() == hs.window.desktop():id()) then
      return false
    end
    local nonDesktopWindows = tifilter(app:visibleWindows(), function(win)
      return hs.window.desktop() == nil or win:id() ~= hs.window.desktop():id()
    end)
    if #nonDesktopWindows == 0 then return true end
    local appid = app:bundleID()
    local quit = appsWithoutWindow.quit[appid] ~= nil
    local windowFilterRules = quit and appsWithoutWindow.quit
        or appsWithoutWindow.hide
    local windowFilter = hs.window.filter.new(false):setAppFilter(
      app:name(), windowFilterRules[appid])
    return tfind(nonDesktopWindows, function(win)
      return windowFilter:isWindowAllowed(win)
    end) == nil
  end
}
local function processAppWithoutWindow(app)
  local appid = app:bundleID() or app:name()
  local fn = function()
    local quit = appsWithoutWindow.quit[appid] ~= nil
    local defaultRule = function()
      local windowFilterRules = quit and appsWithoutWindow.quit
          or appsWithoutWindow.hide
      local windowFilter = hs.window.filter.new(false):setAppFilter(
          app:name(), windowFilterRules[appid])
      return tfind(app:visibleWindows(), function(win)
        return win:application() and windowFilter:isWindowAllowed(win)
      end) == nil
    end
    local specialRule = specialNoWindowRules[appid]
    if (specialRule == nil and defaultRule())
        or (specialRule ~= nil and specialRule(app, defaultRule)) then
      if quit == true then
        local wFilter = hs.window.filter.new(app:name())
        if #wFilter:getWindows() == 0 then
          app:kill()
        end
      else
        app:hide()
      end
    end
  end
  if appsWithoutWindowDelay[appid] == nil then
    fn()
  else
    hs.timer.doAfter(appsWithoutWindowDelay[appid], fn)
  end
end

local specialNoPseudoWindowRules = {
  ["com.app.menubarx"] = function(app, defaultRule)
    return appVer(app) < "1.6.9" and defaultRule()
  end
}
PseudoWindowDestroyObservers = {}
local function registerPseudoWindowDestroyObserver(app, roles)
  local appid = app:bundleID() or app:name()
  local observer = PseudoWindowDestroyObservers[appid]
  local appUI = toappui(app)
  if observer ~= nil then observer:start() return end
  observer = uiobserver.new(app:pid())
  observer:addWatcher(appUI, uinotifications.focusedUIElementChanged)
  local quit = appsWithNoPseudoWindow.quit[appid] ~= nil
  local windowFilterRules = quit and appsWithoutWindow.quit
      or appsWithoutWindow.hide
  local windowFilter = hs.window.filter.new(false):setAppFilter(
      app:name(), windowFilterRules[appid])
  local criterion = function(element) return tcontain(roles, element.AXRole) end
  local params = { count = 1, depth = 2 }
  local pseudoWindowObserver
  local observerCallback = function()
    appUI:elementSearch(function(msg, results, count)
      if count > 0 then
        if pseudoWindowObserver ~= nil then
          pseudoWindowObserver:stop()
          pseudoWindowObserver = nil
        end
        local role = results[1].AXRole
        local pseudoWindowObserverCallback = function()
          appUI:elementSearch(function(newMsg, newResults, newCount)
              if newCount == 0 then
                local defaultRule = function()
                  local noWindow = tfind(app:visibleWindows(), function(win)
                    return windowFilter:isWindowAllowed(win)
                  end) == nil
                  local noMenuFromPopover = true
                  if role == AX.Popover then
                    local menuBarMenu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1)
                    noMenuFromPopover = menuBarMenu.AXSelected == false
                  end
                  return noWindow and noMenuFromPopover
                end
                local specialRule = specialNoPseudoWindowRules[appid]
                if (specialRule == nil and defaultRule())
                    or (specialRule ~= nil and specialRule(app, defaultRule)) then
                  if quit == true then
                    local wFilter = hs.window.filter.new(app:name())
                    if #wFilter:getWindows() == 0 then
                      app:kill()
                    end
                  else
                    app:hide()
                  end
                end
              end
            end,
            criterion, params)
        end
        if appsWithoutWindowDelay[appid] then
          local oldCallback = pseudoWindowObserverCallback
          pseudoWindowObserverCallback = function()
            hs.timer.doAfter(appsWithoutWindowDelay[appid], oldCallback)
          end
        end
        pseudoWindowObserver = Evt.OnDestroy(
          results[1],
          pseudoWindowObserverCallback,
          hs.application.watcher.deactivated
        )
      end
    end,
    criterion, params)
  end
  observer:callback(observerCallback)
  observer:start()
  PseudoWindowDestroyObservers[appid] = observer
  Evt.StopOnTerminated(app, observer,
      function() PseudoWindowDestroyObservers[appid] = nil end)
end

AutoHideQuitWindowFilter = hs.window.filter.new(false)
for _, configs in ipairs{appsWithoutWindow.hide, appsWithoutWindow.quit} do
  for appid, cfg in pairs(configs) do
    Evt.OnRunning(appid, function(app)
      AutoHideQuitWindowFilter:setAppFilter(app:name(), cfg)
    end)
  end
end
AutoHideQuitWindowFilter:subscribe(hs.window.filter.windowDestroyed,
  function(win)
    if win == nil or win:application() == nil then return end
    processAppWithoutWindow(win:application())
  end)

-- Hammerspoon only account standard windows, so add watchers for pseudo windows here
for _, configs in ipairs {
  appsWithNoPseudoWindow.hide,
  appsWithNoPseudoWindow.quit,
} do
  for appid, roles in pairs(configs) do
    Evt.OnRunning(appid, function(app)
      registerPseudoWindowDestroyObserver(app, roles)
    end)
  end
end


-- ## remote desktop apps
-- remap modifier keys for specified windows of remote desktop apps
local frontApp = hs.application.frontmostApplication()

RemoteDesktopsMappingModifiers =
    get(KeybindingConfigs, 'remoteDesktopModifiers') or {}
for _, rules in pairs(RemoteDesktopsMappingModifiers) do
  for _, r in ipairs(rules) do
    local newMap = {}
    for k, v in pairs(r.map) do
      local shortKey = toshort(k)
      if shortKey ~= nil then newMap[shortKey] = toshort(v) end
    end
    r.map = newMap
  end
end

local MRD = {}
MRD.WF = {
  Remote = {}
}
if hs.application.nameForBundleID("com.microsoft.rdc.macos") == "Windows App" then
  Evt.OnRunning("com.microsoft.rdc.macos", function(app)
    MRD.WF.Remote = { rejectTitles = {} }
    for _, title in ipairs {"Favorites", "Devices", "Apps",
      "Settings", "About", "Device View Options", "App View Options" } do
      local locTitle = "^" .. T(title, app) .. "$"
      tinsert(MRD.WF.Remote.rejectTitles, locTitle)
    end
  end)
else
  MRD.WF.Remote = {
    rejectTitles = {
      "^Microsoft Remote Desktop$",
      "^Preferences$",
    }
  }
end

local function isDefaultRemoteDesktopWindow(window)
  local appid = window:application():bundleID()
  if appid == "com.realvnc.vncviewer" then
    local winUI = towinui(window)
    return tfind(getc(winUI, AX.Button),
      function(child) return child.AXHelp == "Session information" end) ~= nil
  elseif appid == "com.microsoft.rdc.macos" then
    local wFilter = hs.window.filter.new(false):setAppFilter(
        window:application():name(), MRD.WF.Remote)
    local result = wFilter:isWindowAllowed(window)
    if result then
      local winUI = towinui(window)
      local title
      title = "Cancel"
      if window:application():name() == "Windows App" then
        title = T(title, window:application())
      end
      for _, bt in ipairs(getc(winUI, AX.Button)) do
        if bt.AXTitle == title then
          return false
        end
      end
    end
    return result
  end
  return true
end

local function remoteDesktopWindowFilter(app)
  local appid = app:bundleID()
  local rules = RemoteDesktopsMappingModifiers[appid]
  local win = app:focusedWindow()
  for _, r in ipairs(rules or {}) do
    local valid = false
    -- some remote desktop like 'VNC Viewer' works at a lower level than Hammerspoon,
    -- so we have to remap modifiers by app like 'Karabiner' which works at a even lower level
    -- and restore modifiers in non-remote windows
    if win == nil or win:role() == AX.Sheet or win:role() == AX.Popover then
      valid = r.type == 'restore'
    elseif r.condition == nil then
      local isRDW = isDefaultRemoteDesktopWindow(win)
      valid = (r.type == 'restore' and not isRDW) or (r.type ~= 'restore' and isRDW)
    else
      if r.condition.windowFilter ~= nil then  -- currently only support window filter
        local wFilter = hs.window.filter.new(false):setAppFilter(
            app:name(), r.condition.windowFilter)
        valid = wFilter:isWindowAllowed(win)
      end
    end
    if valid then
      return r
    end
  end
  return nil
end
FLAGS["JUST_MODIFIED_MODIFIERS_FOR_MRD"] = false
RemoteDesktopModifierTapper = hs.eventtap.new({
  hs.eventtap.event.types.flagsChanged,
  hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.keyUp,
},
function(ev)
  local rule = remoteDesktopWindowFilter(hs.application.frontmostApplication())
  if rule ~= nil then
    if not FLAGS["JUST_MODIFIED_MODIFIERS_FOR_MRD"] then
      FLAGS["JUST_MODIFIED_MODIFIERS_FOR_MRD"] = true
      local evFlags =	ev:getFlags()
      local newEvFlags = {}
      for k, _ in pairs(evFlags) do
        newEvFlags[rule.map[k] or k] = true
      end
      ev:setFlags(newEvFlags)
      ev:post()
      return true
    else
      FLAGS["JUST_MODIFIED_MODIFIERS_FOR_MRD"] = false
    end
  end
  return false
end)

if frontApp then
  local frontAppID = frontApp:bundleID() or frontApp:name()
  if RemoteDesktopsMappingModifiers[frontAppID] then
    RemoteDesktopModifierTapper:start()
  end
end
for appid, _ in pairs(RemoteDesktopsMappingModifiers) do
  Evt.OnActivated(appid, function()
    if not RemoteDesktopModifierTapper:isEnabled() then
      RemoteDesktopModifierTapper:start()
    end
  end)
end

local function suspendHotkeysInRemoteDesktop(app)
  local win = app:focusedWindow()
  if win ~= nil then
    if isDefaultRemoteDesktopWindow(win) then
      if FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] == nil then
        FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] = not FLAGS["SUSPEND"]
      end
      FLAGS["SUSPEND"] = true
      return
    end
  end
  if FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] ~= nil then
    FLAGS["SUSPEND"] = not FLAGS["SUSPEND_IN_REMOTE_DESKTOP"]
    FLAGS["SUSPEND_IN_REMOTE_DESKTOP"] = nil
  end
end

local function watchForRemoteDesktopWindow(app)
  local appUI = toappui(app)
  local observer = uiobserver.new(app:pid())
  observer:addWatcher(appUI, uinotifications.focusedWindowChanged)
  observer:callback(bind(suspendHotkeysInRemoteDesktop, app))
  observer:start()
  Evt.StopOnDeactivated(app, observer)
  Evt.StopOnTerminated(app, observer)
end

for _, appid in ipairs(ApplicationConfigs["suspendHotkeysInRemoteDesktop"] or {}) do
  local frontAppID = frontApp and (frontApp:bundleID() or frontApp:name()) or nil
  if frontAppID == appid then
    watchForRemoteDesktopWindow(frontApp)
    suspendHotkeysInRemoteDesktop(frontApp)
  end
  Evt.OnActivated(appid, suspendHotkeysInRemoteDesktop)
  Evt.OnActivated(appid, watchForRemoteDesktopWindow)
end

-- ## hold cmd+w to close window for iOS apps because it will quit them
HoldToQuit = hs.loadSpoon("HoldToQuit")
HoldToQuit.duration = 0.2
HoldToQuit:init()
HoldToQuit:newHotkeys{ quit = { "⌘", "W" } }
---@diagnostic disable-next-line: lowercase-global
function mayRequireHoldToCloseWindow(app)
  local appid = app:bundleID()
  if appid == nil then return end
  local appPath = hs.application.pathForBundleID(appid)
  if exists(appPath .. '/WrappedBundle')
      or appPath:find("Steam/steamapps/common") then
    HoldToQuit:start()
  else
    HoldToQuit:stop()
  end
end
if frontApp then
  mayRequireHoldToCloseWindow(frontApp)
end

-- ## specify input source for apps
---@diagnostic disable-next-line: lowercase-global
function selectInputSourceInApp(app)
  local inputSource = get(ApplicationConfigs, "inputSource",
      app:bundleID() or app:name())
  if inputSource ~= nil then
    local currentSourceID = hs.keycodes.currentSourceID()
    if type(inputSource) == 'string' then
      if currentSourceID ~= inputSource then
        hs.keycodes.currentSourceID(inputSource)
      end
    else
      for _, source in ipairs(inputSource) do
        if currentSourceID == source then
          return
        end
        if hs.keycodes.currentSourceID(source) then
          break
        end
      end
    end
  end
end
