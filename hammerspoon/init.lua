---@diagnostic disable: lowercase-global

OS = {
  Cheetah = "10.00",
  Puma = "10.01",
  Jaguar = "10.02",
  Panther = "10.03",
  Tiger = "10.04",
  Leopard = "10.05",
  ["Snow Leopard"] = "10.06",
  Lion = "10.07",
  ["Mountain Lion"] = "10.08",
  Mavericks = "10.09",
  Yosemite = "10.10",
  ["El Capitan"] = "10.11",
  Sierra = "10.12",
  ["High Sierra"] = "10.13",
  Mojave = "10.14",
  Catalina = "10.15",
  ["Big Sur"] = "11",
  Monterey = "12",
  Ventura = "13",
  Sonoma = "14",
  Sequoia = "15",
}

local osVersion = hs.host.operatingSystemVersion()
local vm = osVersion.major
if vm < 11 then
  local vminor = (osVersion.minor < 10 and "0" or "") .. tostring(osVersion.minor)
  OS_VERSION = tostring(vm) .. "." .. tostring(vminor)
else
  OS_VERSION = tostring(vm)
end

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

local function capitalize(str)
  return str:sub(1, 1):upper() .. str:sub(2)
end
AX = {
  Heading             = "AXHeading",
  OpaqueProviderGroup = "AXOpaqueProviderGroup",
  WebArea             = "AXWebArea",
  LandmarkBanner      = "AXLandmarkBanner",
  TabPanel            = "AXTabPanel",
  Open                = "AXOpen",
}
for k, v in pairs(hs.axuielement.roles) do AX[capitalize(k)] = v end
for k, v in pairs(hs.axuielement.subroles) do AX[capitalize(k)] = v end
for k, v in pairs(hs.axuielement.actions) do AX[capitalize(k)] = v end

strfmt = string.format
strsplit = hs.fnutils.split
tinsert = table.insert
tremove = table.remove
tconcat = hs.fnutils.concat
tcontain = hs.fnutils.contains
tfind = hs.fnutils.find
tindex = hs.fnutils.indexOf
tfilter = hs.fnutils.filter
tifilter = hs.fnutils.ifilter
tcopy = hs.fnutils.copy
foreach = hs.fnutils.each
bind = hs.fnutils.partial
toappui = hs.axuielement.applicationElement
towinui = hs.axuielement.windowElement
uiobserver = hs.axuielement.observer
uinotifications = hs.axuielement.observer.notifications

FLAGS = {}

HYPER = nil
KeybindingConfigs = nil
local function loadKeybindings(filePath)
  KeybindingConfigs = hs.json.read(filePath)
  for k, hp in pairs(KeybindingConfigs.hyper or {}) do
    if type(hp) == "string" then
      if tcontain({"fn", "shift", "option", "control", "command"}) then
        hp = {hp}
      end
    end
    if type(hp) ~= "string" then
      local modsRepr = ""
      if tcontain(hp, "command") then modsRepr = "⌘" end
      if tcontain(hp, "control") then modsRepr = modsRepr .. "⌃" end
      if tcontain(hp, "option") then modsRepr = modsRepr .. "⌥" end
      if tcontain(hp, "shift") then modsRepr = modsRepr .. "⇧" end
      if tcontain(hp, "fn") then modsRepr = "fn" .. modsRepr end
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
          spec.mods = spec.mods:gsub("%${(.-)}", function(key)
            local pos = 0
            local buf = KeybindingConfigs
            while true do
              local newPos = key:find("%.", pos + 1)
              if newPos then
                buf = buf[key:sub(pos + 1, newPos - 1)]
              else
                buf = buf[key:sub(pos + 1)]
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

ApplicationConfigs = {}
if hs.fs.attributes("config/application.json") ~= nil then
  ApplicationConfigs = hs.json.read("config/application.json")
end

HyperModalList = {}
DoubleTapModalList = {}

local hyper = require('modal.hyper')
HyperModal = hyper.install(HYPER)
tinsert(HyperModalList, HyperModal)

-- get hotkey idx like how Hammerspoon does that
function hotkeyIdx(mods, key)
  local idx = key:upper()
  if type(mods) == 'string' then
    if mods == "shift" then idx = "⇧" .. idx
    elseif mods == "option" or mods == "alt" then idx = "⌥" .. idx
    elseif mods == "control" or mods == "ctrl" then idx = "⌃" .. idx
    elseif mods == "command" or mods == "cmd" then idx = "⌘" .. idx
    else
      if mods:find("⇧") then idx = "⇧" .. idx end
      if mods:find("⌥") then idx = "⌥" .. idx end
      if mods:find("⌃") then idx = "⌃" .. idx end
      if mods:find("⌘") then idx = "⌘" .. idx end
    end
  else
    if tcontain(mods, "shift") then idx = "⇧" .. idx end
    if tcontain(mods, "option") or tcontain(mods, "alt") then
      idx = "⌥" .. idx
    end
    if tcontain(mods, "control") or tcontain(mods, "ctrl") then
      idx = "⌃" .. idx
    end
    if tcontain(mods, "command") or tcontain(mods, "cmd") then
      idx = "⌘" .. idx
    end
  end
  return idx
end

-- send key strokes to the system. but if the key binding is registered, disable it temporally
function safeGlobalKeyStroke(mods, key)
  local idx = hotkeyIdx(mods, key)
  local conflicted = tfilter(hs.hotkey.getHotkeys(), function(hk)
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
  local validHyperModal = tfind(HyperModalList, function(modal)
    return modal.hyper == mods
  end)
  if validHyperModal ~= nil then
    hotkey = validHyperModal:bind("", key, message, pressedfn, releasedfn, repeatfn)
  else
    hotkey = hs.hotkey.new(mods, key, pressedfn, releasedfn, repeatfn)
  end
  if message ~= nil then
    if mods == HYPER then
      hotkey.msg = hotkey.msg:gsub(HyperModal.hyper, "✧", 1)
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
    local validHyperModal = tfind(HyperModalList, function(modal)
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
    local validHyperModal = tfind(HyperModalList, function(modal)
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
end

-- for apps that launch silently
local processesOnSilentLaunch = {}
local hasLaunched = {}
function ExecOnSilentLaunch(appid, action)
  if processesOnSilentLaunch[appid] == nil then
    processesOnSilentLaunch[appid] = {}
  end

  tinsert(processesOnSilentLaunch[appid], action)
  hasLaunched[appid] = find(appid) ~= nil
end

local processesOnSilentQuit = {}
function ExecOnSilentQuit(appid, action)
  if processesOnSilentQuit[appid] == nil then
    processesOnSilentQuit[appid] = {}
  end
  tinsert(processesOnSilentQuit[appid], action)
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
      processesOnSilentQuit[appid] = nil
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
      tinsert(newFiles, file)
      tinsert(newFlagTables, flagTables[i])
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
