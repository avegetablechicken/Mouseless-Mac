local tinsert = table.insert

local module = {}

-- Leave Hyper Mode when Hyper is pressed
function module:exitHyperMode()
  self.hyperMode:exit()
  self.hyperMode.Entered = false
  self.hyperTapper:stop()
  self.hyperTapper = nil
  self.hyperTimer:stop()
  self.hyperTimer = nil
end

function module:enterHyperMode()
  self.hyperMode:enter()
  self.hyperMode.Entered = true

  -- hyper key up may be captured by `Parallels Desktop`
  -- we need to check if hyper key is still pressed
  self.hyperPressed = true
  self.hyperTapper = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
    if e:getKeyCode() == hs.keycodes.map[self.hyper] then
      self.hyperPressed = true
    end
  end):start()
  self.hyperTimer = hs.timer.doEvery(1, function()
    if not self.hyperPressed then
      self:exitHyperMode()
    end
    self.hyperPressed = false
  end):start()
end

-- Utility to bind handler to Hyper+modifiers+key
function module:bindNoSuspend(mods, key, message, pressedfn, releasedfn, repeatfn)
  local hotkey = hs.hotkey.new(mods, key, pressedfn, releasedfn, repeatfn)
  hotkey.msg = self.hyper .. hotkey.idx .. ": " .. message
  tinsert(self.hyperMode.keys, hotkey)
  return hotkey
end

function module:bind(...)
  local hotkey = newHotkey(...)
  hotkey.msg = self.hyper .. hotkey.msg
  tinsert(self.hyperMode.keys, hotkey)
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
  o.trigger = hs.hotkey.bind("", o.hyper,
      function() o:enterHyperMode() end, function() o:exitHyperMode() end)
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
