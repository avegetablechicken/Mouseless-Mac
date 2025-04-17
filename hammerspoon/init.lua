---@diagnostic disable: lowercase-global

HK = {
  PRIVELLEGE = 0,
  SWITCH = 1,
  IN_APP = 2,
  IN_APP_ = { MENU = 1, APP = 2, WEBSITE = 3, WINDOW = 4 },
  IN_WIN = 3,
  APPKEY = 4,
  BACKGROUND = 5,
  MENUBAR = 6,
  MENUBAR_ = { CONTROL_CENTER = 0 },
  WIN_OP = 7,
  WIN_OP_ = { MOVE = 1, RESIZE = 2, SPACE_SCREEN = 3 },
}

FLAGS = {}

HYPER = nil
KeybindingConfigs = nil
local function loadKeybindings(filePath)
  KeybindingConfigs = hs.json.read(filePath)
  for k, hp in pairs(KeybindingConfigs.hyper or {}) do
    if type(hp) == "string" then
      if hs.fnutils.contains({"fn", "shift", "option", "control", "command"}) then
        hp = {hp}
      end
    end
    if type(hp) ~= "string" then
      local modsRepr = ""
      if hs.fnutils.contains(hp, "command") then modsRepr = "⌘" end
      if hs.fnutils.contains(hp, "control") then modsRepr = modsRepr .. "⌃" end
      if hs.fnutils.contains(hp, "option") then modsRepr = modsRepr .. "⌥" end
      if hs.fnutils.contains(hp, "shift") then modsRepr = modsRepr .. "⇧" end
      if hs.fnutils.contains(hp, "fn") then modsRepr = "fn" .. modsRepr end
      KeybindingConfigs.hyper[k] = modsRepr
    end
  end
  if KeybindingConfigs.hyper ~= nil then
    HYPER = KeybindingConfigs.hyper.hyper
  end

  if KeybindingConfigs.hotkeys == nil then
    KeybindingConfigs.hotkeys = {}
  end
  for kind, cfg in pairs(KeybindingConfigs.hotkeys) do
    if kind ~= "menubar" then
      for k, spec in pairs(cfg) do
        if type(spec.mods) == 'string' then
          spec.mods = string.gsub(spec.mods, "%${(.-)}", function(key)
            local pos = 0
            local buf = KeybindingConfigs
            while true do
              local newPos = string.find(key, "%.", pos + 1)
              if newPos then
                buf = buf[string.sub(key, pos + 1, newPos - 1)]
              else
                buf = buf[string.sub(key, pos + 1)]
                break
              end
              pos = newPos
            end
            return buf
          end)
        end
      end
    end
  end
end
loadKeybindings("config/keybindings.json")

HyperModalList = {}
DoubleTapModalList = {}

local hyper = require('modal.hyper')
HyperModal = hyper.install(HYPER)
table.insert(HyperModalList, HyperModal)

-- get hotkey idx like how Hammerspoon does that
function hotkeyIdx(mods, key)
  local idx = string.upper(key)
  if type(mods) == 'string' then
    if mods == "shift" then idx = "⇧" .. idx
    elseif mods == "option" or mods == "alt" then idx = "⌥" .. idx
    elseif mods == "control" or mods == "ctrl" then idx = "⌃" .. idx
    elseif mods == "command" or mods == "cmd" then idx = "⌘" .. idx
    else
      if string.find(mods, "⇧") then idx = "⇧" .. idx end
      if string.find(mods, "⌥") then idx = "⌥" .. idx end
      if string.find(mods, "⌃") then idx = "⌃" .. idx end
      if string.find(mods, "⌘") then idx = "⌘" .. idx end
    end
  else
    if hs.fnutils.contains(mods, "shift") then idx = "⇧" .. idx end
    if hs.fnutils.contains(mods, "option") or hs.fnutils.contains(mods, "alt") then
      idx = "⌥" .. idx
    end
    if hs.fnutils.contains(mods, "control") or hs.fnutils.contains(mods, "ctrl") then
      idx = "⌃" .. idx
    end
    if hs.fnutils.contains(mods, "command") or hs.fnutils.contains(mods, "cmd") then
      idx = "⌘" .. idx
    end
  end
  return idx
end

-- send key strokes to the system. but if the key binding is registered, disable it temporally
function safeGlobalKeyStroke(mods, key)
  local idx = hotkeyIdx(mods, key)
  local conflicted = hs.fnutils.filter(hs.hotkey.getHotkeys(), function(hk)
    return hk.idx == idx
  end)
  if conflicted[1] ~= nil then
    conflicted[1]:disable()
  end
  hs.eventtap.keyStroke(mods, key)
  if conflicted[1] ~= nil then
    hs.timer.doAfter(1, function()
      if conflicted[1].enable ~= nil then
        conflicted[1]:enable()
      end
    end)
  end
end

function suspendWrapper(fn, mods, key, predicates)
  if fn ~= nil then
    local oldFn = fn
    fn = function()
      local enabled = not FLAGS["SUSPEND"]
      if predicates ~= nil then
        if enabled and predicates.and_ == true then
          if not(predicates.fn)() then
            enabled = false
          end
        elseif not enabled and predicates.or_ == true then
          if (predicates.fn)() then
            enabled = true
          end
        end
      end

      if enabled then
        oldFn()
      elseif mods ~= nil and key ~= nil then
        safeGlobalKeyStroke(mods, key)
      end
    end
  end
  return fn
end

local function getFunc(f)
  if f == nil then return nil end
  if type(f) == 'function' then return f end
  if type(f) == 'table' then
    local m = getmetatable(f)
    if m and m.__call and type(m.__call) == 'function' then
      return function() m.__call(f) end
    end
  end
  return nil
end

function newHotkeyImpl(mods, key, message, pressedfn, releasedfn, repeatfn)
  if message == nil or getFunc(message) then
    repeatfn=releasedfn releasedfn=pressedfn pressedfn=message message=nil -- shift down arguments
  end
  pressedfn = getFunc(pressedfn)
  releasedfn = getFunc(releasedfn)
  repeatfn = getFunc(repeatfn)
  local hotkey
  local validHyperModal = hs.fnutils.find(HyperModalList, function(modal)
    return modal.hyper == mods
  end)
  if validHyperModal ~= nil then
    hotkey = validHyperModal:bind("", key, message, pressedfn, releasedfn, repeatfn)
  else
    hotkey = hs.hotkey.new(mods, key, pressedfn, releasedfn, repeatfn)
  end
  if message ~= nil then
    if mods == HYPER then
      hotkey.msg = string.gsub(hotkey.msg, HyperModal.hyper, "✧", 1)
    else
      hotkey.msg = hotkey.idx .. ": " .. message
    end
  end
  return hotkey
end

function newHotkey(mods, key, message, pressedfn, releasedfn, repeatfn, predicates)
  if message == nil or getFunc(message) then
    predicates = repeatfn
    repeatfn=releasedfn releasedfn=pressedfn pressedfn=message message=nil -- shift down arguments
  end
  pressedfn = getFunc(pressedfn)
  releasedfn = getFunc(releasedfn)
  repeatfn = getFunc(repeatfn)
  pressedfn = suspendWrapper(pressedfn, mods, key, predicates)
  releasedfn = suspendWrapper(releasedfn, mods, key, predicates)
  repeatfn = suspendWrapper(repeatfn, mods, key, predicates)
  local hotkey = newHotkeyImpl(mods, key, message, pressedfn, releasedfn, repeatfn)
  hotkey.suspendable = true
  return hotkey
end

function newHotkeySpec(spec, ...)
  if spec == nil then return nil end
  return newHotkey(spec.mods, spec.key, ...)
end

function bindHotkeySpecImpl(spec, ...)
  local hotkey = newHotkeyImpl(spec.mods, spec.key, ...)
  if hotkey ~= nil then
    local validHyperModal = hs.fnutils.find(HyperModalList, function(modal)
      return modal.hyper == spec.mods
    end)
    if validHyperModal == nil then
      hotkey:enable()
    end
  end
  return hotkey
end

function bindHotkey(mods, ...)
  local hotkey = newHotkey(mods, ...)
  if hotkey ~= nil then
    local validHyperModal = hs.fnutils.find(HyperModalList, function(modal)
      return modal.hyper == mods
    end)
    if validHyperModal == nil then
      hotkey:enable()
    end
  end
  return hotkey
end

function bindHotkeySpec(spec, ...)
  if spec == nil then return nil end
  return bindHotkey(spec.mods, spec.key, ...)
end

local misc = KeybindingConfigs.hotkeys.global

-- toggle hotkeys
FLAGS["SUSPEND"] = false
HSKeybindings = nil
local toggleHotkey = bindHotkeySpecImpl(misc["toggleHotkeys"], "Toggle Hotkeys", function()
  FLAGS["SUSPEND"] = not FLAGS["SUSPEND"]
  if FLAGS["SUSPEND"] then
    hs.alert.show("Hammerspoon Hotkeys Suspended")
  else
    hs.alert.show("Hammerspoon Hotkeys Resumed")
  end
  if HSKeybindings ~= nil and HSKeybindings.isShowing then
    local validOnly = HSKeybindings.validOnly
    local showHS = HSKeybindings.showHS
    local showApp = HSKeybindings.showApp
    HSKeybindings:reset()
    HSKeybindings:update(validOnly, showHS, showApp)
  end
end)
toggleHotkey.kind = HK.PRIVELLEGE

-- reload
bindHotkeySpec(misc["reloadHammerspoon"], "Reload Hammerspoon", function()
  hs.reload()
end).kind = HK.PRIVELLEGE

-- toggle hamerspoon console
bindHotkeySpec(misc["toggleConsole"], "Toggle Hammerspoon Console",
function()
  local consoleWin = hs.console.hswindow()
  if consoleWin and consoleWin:isVisible() then
    consoleWin:close()
  elseif consoleWin and consoleWin:isMinimized() then
    consoleWin:unminimize()
  else
    hs.toggleConsole()
  end
end).kind = HK.PRIVELLEGE

processesExecEvery = {}
function ExecContinuously(action)
  local timeKey = tostring(hs.timer.absoluteTime())
  processesExecEvery[timeKey] = action
  return timeKey
end

function StopExecContinuously(timeKey)
  processesExecEvery[timeKey] = nil
end

ContinuousWatcher = hs.timer.new(1, function()
  for _, proc in pairs(processesExecEvery) do
    proc()
  end
end, true)

local function reloadConfig(files)
  if hs.fnutils.some(files, function(file) return file:sub(-4) == ".lua" end) then
    hs.reload()
  end
end

local function applicationCallback(appname, eventType, app)
  App_applicationCallback(appname, eventType, app)
  System_applicationCallback(appname, eventType, app)
end

-- for apps that launch silently
local processesOnSilentLaunch = {}
local hasLaunched = {}
function ExecOnSilentLaunch(appid, action, onlyFirstTime)
  if processesOnSilentLaunch[appid] == nil then
    processesOnSilentLaunch[appid] = {}
  end

  if onlyFirstTime then
    local idx = #processesOnSilentLaunch[appid] + 1
    local oldAction = action
    action = function(app)
      oldAction(app)
      table.remove(processesOnSilentLaunch[appid], idx)
    end
  end

  table.insert(processesOnSilentLaunch[appid], action)
  hasLaunched[appid] = find(appid) ~= nil
end

local processesOnSilentQuit = {}
function ExecOnSilentQuit(appid, action)
  if processesOnSilentQuit[appid] == nil then
    processesOnSilentQuit[appid] = {}
  end
  table.insert(processesOnSilentQuit[appid], action)
  hasLaunched[appid] = find(appid) ~= nil
end

ExecContinuously(function()
  local hasLaunchedTmp = {}
  for appid, processes in pairs(processesOnSilentLaunch) do
    local app = find(appid)
    if hasLaunched[appid] == false and app ~= nil then
      for _, proc in ipairs(processes) do
        proc(app)
      end
    end
    hasLaunchedTmp[appid] = app ~= nil
  end

  for appid, processes in pairs(processesOnSilentQuit) do
    local app = find(appid)
    if hasLaunched[appid] == true and app == nil then
      for _, proc in ipairs(processes) do
        proc(appid)
      end
    end
    hasLaunchedTmp[appid] = app ~= nil
  end

  hasLaunched = hasLaunchedTmp
end)

local function applicationInstalledCallback(files, flagTables)
  local newFiles, newFlagTables = {}, {}
  for i, file in ipairs(files) do
    if file:sub(-4) == ".app"
        and (flagTables[i].itemCreated or flagTables.itemRemoved) then
      table.insert(newFiles, file)
      table.insert(newFlagTables, flagTables[i])
    end
  end
  if #newFiles ~= 0 then
    App_applicationInstalledCallback(newFiles, newFlagTables)
    System_applicationInstalledCallback(newFiles, newFlagTables)
    File_applicationInstalledCallback(newFiles, newFlagTables)
  end
end

local function monitorChangedCallback()
  App_monitorChangedCallback()
  System_monitorChangedCallback()
  Screen_monitorChangedCallback()
end

local function usbChangedCallback(device)
  App_usbChangedCallback(device)
end

local function networkChangedCallback(storeObj, changedKeys)
  System_networkChangedCallback(storeObj, changedKeys)
end

ContinuousWatcher:start()
ConfigWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", reloadConfig):start()
AppWatcher = hs.application.watcher.new(applicationCallback):start()
MonitorWatcher = hs.screen.watcher.new(monitorChangedCallback):start()
UsbWatcher = hs.usb.watcher.new(usbChangedCallback):start()
AppInstalledWatchers = {}
local appDirs =
{
  "/Applications",
  os.getenv("HOME") .. "/Applications",
  os.getenv("HOME") .. "/Applications/JetBrains Toolbox",
  os.getenv("HOME") .. "/Parallels",
}
for _, appDir in ipairs(appDirs) do
  local watcher = hs.pathwatcher.new(appDir, applicationInstalledCallback):start()
  AppInstalledWatchers[appDir] = watcher
end

NetworkMonitorKeys = { "State:/Network/Global/IPv4" }
NetworkWatcher = hs.network.configuration.open()
NetworkWatcher:monitorKeys(NetworkMonitorKeys)
NetworkWatcher:setCallback(networkChangedCallback)
NetworkWatcher:start()

hs.urlevent.bind("alert", function(eventName, params)
  hs.alert.show(params["text"])
end)

-- manage app
require "app"

-- change system preferences
require "system"

-- move window in current space
require "window"

-- move cursor or window to other monitor
require "screen"

-- manage filesystem
require "fs"

-- miscellaneous function
require "misc"
