---@diagnostic disable: lowercase-global

local t = hs.timer.absoluteTime()
FLAGS = {}
FLAGS["LOADING"] = true

OS = {
  Cheetah           = "10.00",
  Puma              = "10.01",
  Jaguar            = "10.02",
  Panther           = "10.03",
  Tiger             = "10.04",
  Leopard           = "10.05",
  ["Snow Leopard"]  = "10.06",
  Lion              = "10.07",
  ["Mountain Lion"] = "10.08",
  Mavericks         = "10.09",
  Yosemite          = "10.10",
  ["El Capitan"]    = "10.11",
  Sierra            = "10.12",
  ["High Sierra"]   = "10.13",
  Mojave            = "10.14",
  Catalina          = "10.15",
  ["Big Sur"]       = "11",
  Monterey          = "12",
  Ventura           = "13",
  Sonoma            = "14",
  Sequoia           = "15",
  Tahoe             = "26"
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
  IN_APP_ = { MENU = 1, APP = 2, WINDOW = 3 },
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
tmap = hs.fnutils.map
tcopy = hs.fnutils.copy
any = hs.fnutils.some
all = hs.fnutils.every
foreach = hs.fnutils.each
bind = hs.fnutils.partial
toappui = hs.axuielement.applicationElement
towinui = hs.axuielement.windowElement
uiobserver = hs.axuielement.observer
uinotifications = hs.axuielement.observer.notifications

hs.window.filter.ignoreAlways["com.apple.WebKit.WebContent"] = true

Mod = {
  Cmd = {
    Long = 'command',
    Short = 'cmd',
    Symbol = '⌘'
  },
  Ctrl = {
    Long = 'control',
    Short = 'ctrl',
    Symbol = '⌃'
  },
  Alt = {
    Long = 'option',
    Short = 'alt',
    Symbol = '⌥'
  },
  Shift = {
    Long = 'shift',
    Short = 'shift',
    Symbol = '⇧'
  },
  Fn = {
    Long = 'fn',
    Short = 'fn',
    Symbol = '🌐︎'
  }
}

function tolong(mod)
  for _, tbl in pairs(Mod) do
    if mod == tbl.Short or mod == tbl.Symbol then
      return tbl.Long
    end
  end
  return mod
end

function toshort(mod)
  for _, tbl in pairs(Mod) do
    if mod == tbl.Long or mod == tbl.Symbol then
      return tbl.Short
    end
  end
  return mod
end

function tosymbol(mod)
  for _, tbl in pairs(Mod) do
    if mod:upper() == tbl.Long:upper() or mod:upper() == tbl.Short:upper() then
      return tbl.Symbol
    end
  end
  return mod
end

KeybindingConfigs = nil
ModsInHSOrder = { Mod.Fn.Long, Mod.Cmd.Long, Mod.Ctrl.Long, Mod.Alt.Long, Mod.Shift.Long }
local function loadKeybindings(filePath)
  KeybindingConfigs = hs.json.read(filePath)
  for k, hp in pairs(KeybindingConfigs.hyper or {}) do
    if type(hp) == "string" then
      if tcontain(ModsInHSOrder, hp) then
        hp = {hp}
      end
    end
    if type(hp) ~= "string" then
      local modsRepr = ""
      for _, mod in ipairs(ModsInHSOrder) do
        if tcontain(hp, mod) then
          modsRepr = modsRepr .. tosymbol(mod)
        end
      end
      KeybindingConfigs.hyper[k] = modsRepr
    end
  end
  if KeybindingConfigs.hyper ~= nil then
    local HYPER = KeybindingConfigs.hyper.hyper
    Mod.Hyper = {
      Long = HYPER:lower(),
      Short = HYPER:lower(),
      Symbol = '✧'
    }
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
if Mod.Hyper then
  tinsert(HyperModalList, hyper.install(Mod.Hyper.Long))
end
Globe = require('modal.globe')

-- get hotkey idx like how Hammerspoon does that
function hotkeyIdx(mods, key)
  key = key:upper()
  local idx = ""
  if type(mods) == 'string' then
    for _, mod in ipairs(ModsInHSOrder) do
      if mods == mod or mods == toshort(mod) then
        return tosymbol(mod) .. key
      end
    end
    for _, mod in ipairs(ModsInHSOrder) do
      mod = tosymbol(mod)
      if mods:find(mod) then idx = idx .. mod end
    end
  else
    for _, mod in ipairs(ModsInHSOrder) do
      if tcontain(mods, mod) or tcontain(mods, toshort(mod)) then
        idx = idx .. tosymbol(mod)
      end
    end
  end
  return idx .. key
end

-- send key strokes to the system. but if the key binding is registered, disable it temporally
function safeGlobalKeyStroke(mods, key)
  local idx = hotkeyIdx(mods, key)
  local conflicted = tfind(hs.hotkey.getHotkeys(), function(hk)
    return hk.idx == idx
  end)
  if conflicted then
    conflicted:disable()
  end
  hs.eventtap.keyStroke(mods, key)
  if conflicted then
    hs.timer.doAfter(0.3, function()
      if conflicted.enable ~= nil then
        conflicted:enable()
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

A_Hotkey, A_Message = nil, nil
function A_HotkeyWrapper(fn, tbl)
  if tbl == nil then
    tbl = { hotkey = A_Hotkey, message = A_Message }
  end
  return function(...)
    A_Hotkey, A_Message = tbl.hotkey, tbl.message
    local ret = fn(...)
    A_Hotkey, A_Message = nil, nil
    return ret
  end
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
    return type(mods) == 'string' and tosymbol(modal.hyper) == tosymbol(mods)
  end)
  local globeModal
  if type(mods) == 'table' then
    globeModal = tfind(mods, function(mod)
      return tfind({ Mod.Fn.Long, Mod.Fn.Short, Mod.Fn.Symbol },
                   function(fn) return mod:lower() == fn end) ~= nil
    end) ~= nil
  else
    globeModal = tfind({ Mod.Fn.Long, Mod.Fn.Short, Mod.Fn.Symbol },
        function(fn)
          return mods:lower():find(fn) ~= nil
        end) ~= nil
  end
  local tbl = {}
  if pressedfn then
    pressedfn = A_HotkeyWrapper(pressedfn, tbl)
  end
  if releasedfn then
    releasedfn = A_HotkeyWrapper(releasedfn, tbl)
  end
  if repeatfn then
    repeatfn = A_HotkeyWrapper(repeatfn, tbl)
  end
  if validHyperModal ~= nil then
    hotkey = validHyperModal:bind("", key, message, pressedfn, releasedfn, repeatfn)
  elseif globeModal then
    hotkey = Globe.bind(mods, key, message, pressedfn, releasedfn)
  else
    hotkey = hs.hotkey.new(mods, key, pressedfn, releasedfn, repeatfn)
    if message ~= nil then
      hotkey.msg = hotkey.idx .. ": " .. message
    end
  end
  tbl.hotkey = hotkey
  tbl.message = message
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
      return type(spec.mods) == 'string'
          and tosymbol(modal.hyper) == tosymbol(spec.mods)
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
      return type(mods) == 'string' and tosymbol(modal.hyper) == tosymbol(mods)
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

URLHotkeyMessages = {}
function registerURLHotkeyMessage(event, key, value, message)
  if URLHotkeyMessages[event] == nil then
    URLHotkeyMessages[event] = {}
  end
  if URLHotkeyMessages[event][key] == nil then
    URLHotkeyMessages[event][key] = {}
  end
  URLHotkeyMessages[event][key][value] = message
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
    local showCustom = HSKeybindings.showCustom
    local showApp = HSKeybindings.showApp
    HSKeybindings:reset()
    HSKeybindings:update(validOnly, showCustom, showApp)
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

ContinuousWatcher = hs.timer.new(0.25, function()
  for _, proc in pairs(processesExecEvery) do
    proc()
  end
end, true)

local function reloadConfig(files)
  if any(files, function(file) return file:sub(-4) == ".lua" end) then
    hs.reload()
  end
end

local function applicationCallback(appname, eventType, app)
  App_applicationCallback(appname, eventType, app)
end

-- for apps that launch silently
local processesOnSilentLaunch = {}
local launchedApps = {}
function ExecOnSilentLaunch(appid, action)
  if processesOnSilentLaunch[appid] == nil then
    processesOnSilentLaunch[appid] = {}
  end

  tinsert(processesOnSilentLaunch[appid], action)
  launchedApps[appid] = find(appid)
end

local processesOnSilentQuit = {}
function ExecOnSilentQuit(appid, action)
  if processesOnSilentQuit[appid] == nil then
    processesOnSilentQuit[appid] = {}
  end
  tinsert(processesOnSilentQuit[appid], action)
  launchedApps[appid] = find(appid)
end

ExecContinuously(function()
  local launchedAppsTmp = {}
  for appid, processes in pairs(processesOnSilentLaunch) do
    local app = find(appid)
    if launchedApps[appid] == nil and app ~= nil then
      applicationCallback(app:name(), hs.application.watcher.launching, app)
      for _, proc in ipairs(processes) do
        proc(app)
      end
      applicationCallback(app:name(), hs.application.watcher.launched, app)
    end
    launchedAppsTmp[appid] = app
  end

  for appid, processes in pairs(processesOnSilentQuit) do
    local app = find(appid)
    if launchedApps[appid] and app == nil then
      for _, proc in ipairs(processes) do
        proc(appid)
      end
      applicationCallback(launchedApps[appid]:name(),
          hs.application.watcher.terminated, launchedApps[appid])
      processesOnSilentQuit[appid] = nil
    end
    launchedAppsTmp[appid] = app
  end

  launchedApps = launchedAppsTmp
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

FLAGS["LOADING"] = false
print(strfmt("-- Loading time: %d ms", (hs.timer.absoluteTime() - t) // 1000000))
