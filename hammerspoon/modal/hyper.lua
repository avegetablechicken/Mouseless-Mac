local tinsert = table.insert

local log = hs.logger.new('hotkey', 'info')

local module = {}

-- Leave Hyper Mode when Hyper is pressed
function module:exitHyperMode()
  self.hyperMode:exit()
  self.hyperMode.Entered = false
end

function module:enterHyperMode()
  self.hyperMode:enter()
  self.hyperMode.Entered = true
end

-- Utility to bind handler to Hyper+modifiers+key
function module:bindNoSuspend(mods, key, message, pressedfn, releasedfn, repeatfn)
  local hotkey = hs.hotkey.new(mods, key, pressedfn, releasedfn, repeatfn)
  local hyper = self.hyper
  if Mod.Hyper and (hyper:upper() == Mod.Hyper.Long:upper()
      or hyper:upper() == Mod.Hyper.Short:upper()) then
    hyper = Mod.Hyper.Symbol
  end
  hotkey.msg = hyper .. hotkey.idx .. ": " .. message
  tinsert(self.hyperMode.keys, hotkey)
  log.f('Enabled hotkey %s', hotkey.msg)
  return hotkey
end

function module:bind(...)
  local hotkey = newHotkey(...)
  local hyper = self.hyper
  if Mod.Hyper and (hyper:upper() == Mod.Hyper.Long:upper()
      or hyper:upper() == Mod.Hyper.Short:upper()) then
    hyper = Mod.Hyper.Symbol
  end
  hotkey.msg = hyper .. hotkey.msg
  tinsert(self.hyperMode.keys, hotkey)
  log.f('Enabled hotkey %s', hotkey.msg)
  return hotkey
end

-- Binds the enter/exit functions of the Hyper modal to all combinations of modifiers
function module:_new(hyper)
  local o = {}
  setmetatable(o, self)
  self.__index = self
  o.hyper = hyper
  o.hyperMode = hs.hotkey.modal.new()
  o.hyperMode.Entered = false
  o.trigger = hs.hotkey.new("", o.hyper,
      function() o:enterHyperMode() end, function() o:exitHyperMode() end)
  if Mod.Hyper and (hyper:upper() == Mod.Hyper.Long:upper()
      or hyper:upper() == Mod.Hyper.Short:upper()) then
    o.trigger.msg = "HYPER"
  end
  local logLevel = hs.hotkey.getLogLevel()
  hs.hotkey.setLogLevel('nothing')
  o.trigger:enable()
  hs.hotkey.setLogLevel(logLevel)
  log.f('Enabled modal %s', o.trigger.msg)
  return o
end

function module:enable()
  self.trigger:enable()
  return self
end

function module:disable()
  self.trigger:disable()
  return self
end

function module.install(hotKey)
  return module:_new(hotKey)
end

return module
