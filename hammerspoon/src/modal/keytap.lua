-- Keyboard event taps that do not make every key wait for Lua: the native tap
-- (see keystate_native.m) passes keys on from a background thread. Events of
-- the `listen` types are reported after they were delivered. Only events of
-- the `decide` types that match `keys`, or any of them while fn is held with
-- `whileFn`, wait for the callback, which returns whether to consume them.
-- The callback also receives how many key-downs had been delivered, counting
-- a reported key-down itself; see keystate.keyDownCount.
-- Without the native module, an hs.eventtap tap over all the types is used
-- instead, and the callback's results are returned to it as they are.
local keystate = require('modal.keystate')
local log = hs.logger.new('keytap', 'info')

local M = {}

local modifierBits = { cmd = 1, alt = 2, shift = 4, ctrl = 8, fn = 16 }

local function mask(types)
  local result = 0
  for _, type in ipairs(types or {}) do result = result | (1 << type) end
  return result
end

-- new({ listen = types, decide = types, keys = { { mods, key }, ... },
--       whileFn = boolean }, fn) -> tap, whether the tap is native
function M.new(options, fn)
  local watcher
  if keystate and keystate.watch then
    local rules = {}
    for _, spec in ipairs(options.keys or {}) do
      local mods, key = spec[1], spec[2]
      if type(mods) == 'string' then mods = { mods } end
      local set = 0
      for _, mod in ipairs(mods or {}) do set = set | assert(modifierBits[mod], mod) end
      rules[#rules + 1] = { assert(hs.keycodes.map[key:lower()], key), set }
    end
    local event = hs.eventtap.event
    watcher = keystate.watch(mask(options.listen), mask(options.decide), rules,
        options.whileFn == true, function(data, keyDowns, userData)
          local e = event.newEventFromData(data)
          if userData ~= 0 then e:setProperty(event.properties.eventSourceUserData, userData) end
          local ok, result = xpcall(fn, debug.traceback, e, keyDowns)
          if not ok then log.e(result) end
          return ok and result == true
        end)
  end
  if watcher then return watcher, true end
  local types = {}
  for _, list in ipairs({ options.listen or {}, options.decide or {} }) do
    for _, type in ipairs(list) do
      if not hs.fnutils.contains(types, type) then types[#types + 1] = type end
    end
  end
  return hs.eventtap.new(types, fn), false
end

-- Run an action after a deciding callback has returned, so that its key does
-- not wait for the action and pass through if that takes too long.
local deferred = {}
function M.defer(fn, ...)
  local args = table.pack(...)
  local timer
  timer = hs.timer.doAfter(0, function()
    deferred[timer] = nil
    fn(table.unpack(args, 1, args.n))
  end)
  deferred[timer] = true
end

return M
