local module = {}

local eventtap  = require("hs.eventtap")
local event     = eventtap.event
local log     	= hs.logger.new('hotkey', 'info')

-- part of the returned table so user can easily edit it
module.bindings = { }

module.keys = {}
module.allKeys = {}

local keyHandler = function(e)
  local mods = {}
  for k, v in pairs(e:getFlags()) do
    if v == true then
      tinsert(mods, k)
    end
  end
  local key = hs.keycodes.map[e:getKeyCode()]
  if key == nil then return false end
  local idx = hotkeyIdx(mods, key)
  local eventType
  if e:getType() == event.types.keyDown then
    eventType = 1
  elseif e:getType() == event.types.keyUp then
    eventType = 2
  end
  local hotkey = get(module.keys, idx, 1)
  if hotkey == nil then
    if key == 'home' then
      key = 'left'
    elseif key == 'end' then
      key = 'right'
    elseif key == 'pageup' then
      key = 'up'
    elseif key == 'pagedown' then
      key = 'down'
    else
      return false
    end
    idx = hotkeyIdx(mods, key)
    hotkey = get(module.keys, idx, 1)
  end
  if hotkey then
    local callback = get(module.bindings, hotkey, eventType)
    if callback then
      callback()
      return true, {}
    end
  end
  return false
end
local keyWatcher = eventtap.new({ event.types.keyDown, event.types.keyUp }, keyHandler)

local fnHandler = function(e)
  if e:getFlags().fn then
    if not keyWatcher:isEnabled() then keyWatcher:start() end
  elseif keyWatcher:isEnabled() then
    keyWatcher:stop()
  end
end
local fnWatcher = eventtap.new({ event.types.flagsChanged }, fnHandler)


local hotkey = {}

function hotkey:enable()
  if self.idx == nil or self.enabled then return end
  if module.keys[self.idx] == nil then
    module.keys[self.idx] = {}
  end
  local frontmostHK = module.keys[self.idx][1]
  if frontmostHK then
    frontmostHK.enabled = false
    log.f('Disabled previous hotkey %s', frontmostHK.msg)
  end
  self.enabled = true
  log.f('Enabled hotkey %s', self.msg)
  tinsert(module.keys[self.idx], 1, self)
  return self
end

function hotkey:disable()
  if self.idx == nil then return end
  local frontmostHK = get(module.keys, self.idx, 1)
  local pos = tindex(module.keys[self.idx] or {}, self)
  if pos == nil then return end
  tremove(module.keys[self.idx], pos)
  self.enabled = false
  log.f('Disabled hotkey %s', self.msg)
  if frontmostHK == self then
    frontmostHK = module.keys[self.idx][1]
    if frontmostHK then
      frontmostHK.enabled = true
      log.f('Re-enabled previous hotkey %s', frontmostHK.msg)
    end
  end
  return self
end

function hotkey:delete()
  self:disable()
  self._delete = true
  module.allKeys[self.idx] = tifilter(module.allKeys[self.idx],
      function(hk) return hk._delete ~= true end)
  self._delete = nil
  self.idx = nil
  log.f('Deleted hotkey %s', self.msg)
end

function module.enable()
  if not fnWatcher:isEnabled() then fnWatcher:start() end
  return module
end

function module.disable()
  if fnWatcher:isEnabled() then fnWatcher:stop() end
  return module
end

function module.isEnabled()
  return fnWatcher:isEnabled()
end

function module.bind(mods, key, message, pressedfn, releasedfn)
  local idx = hotkeyIdx(mods, key)
  local o = {}
  setmetatable(o, { __index = hotkey })
  o.idx = idx
  o.msg = o.idx .. ': ' .. message
  o.enabled = false
  module.bindings[o] = {
    pressedfn or function() end,
    releasedfn or function() end,
  }
  if module.allKeys[o.idx] == nil then
    module.allKeys[o.idx] = {}
  end
  tinsert(module.allKeys[o.idx], 1, o)
  module.enable()
  return o
end

return module