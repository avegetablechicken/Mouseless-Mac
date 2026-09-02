local tinsert = table.insert

local log = hs.logger.new('hotkey', 'info')

local module = {}

-- Leave Hyper Mode when Hyper is released.
function module:exitHyperMode()
  self.hyperMode:exit()
  self.hyperMode.Entered = false
  if self.hyperTapper then
    self.hyperTapper:stop()
    self.hyperTapper = nil
  end
end

function module:enterHyperMode()
  if self:isEnabled() then return end

  self.hyperMode:enter()
  self.hyperMode.Entered = true

  -- Observe key-up directly because the hotkey release callback can be
  -- delayed by other synchronous callbacks. Never infer release from missing
  -- key-repeat events: F18 does not reliably repeat while it is held.
  self.hyperTapper = hs.eventtap.new({hs.eventtap.event.types.keyUp}, function(e)
    if e:getKeyCode() == hs.keycodes.map[self.hyper] then
      self.hyperKeyDown = false
      self:exitHyperMode()
    end
  end):start()
end

function module:isEnabled()
  return self.hyperMode and self.hyperMode.Entered
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
  local originalDelete = hotkey.delete
  hotkey.delete = function(hk)
    local index = tindex(self.hyperMode.keys, hk)
    if index then
      tremove(self.hyperMode.keys, index)
    end
    originalDelete(hk)
  end
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
  o.hyperKeyDown = false
  o.trigger = hs.hotkey.new("", o.hyper,
      function()
        if o.hyperKeyDown then return end
        o.hyperKeyDown = true
        o:enterHyperMode()
      end, function()
        o.hyperKeyDown = false
        o:exitHyperMode()
      end)
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
