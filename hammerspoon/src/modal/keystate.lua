-- Native input state (see keystate_native.m), compiled once per source change.
-- Returns false when the module cannot be built, so callers can fall back.
local log = hs.logger.new('keystate', 'info')

local ok, result = pcall(function()
  local source = hs.configdir .. '/src/modal/keystate_native.m'
  local file = assert(io.open(source, 'r'))
  local content = file:read('*a') file:close()
  -- Lua's headers ship with Hammerspoon: rebuild when either changes.
  local headers = hs.processInfo.bundlePath .. '/Contents/Frameworks/LuaSkin.framework/Headers'
  local binary = hs.fs.temporaryDirectory() .. 'hammerspoon-keystate-'
      .. hs.hash.SHA256(content .. hs.processInfo.version) .. '.so'
  if not hs.fs.attributes(binary) then
    local quote = function(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    local output, built = hs.execute('/usr/bin/clang -shared -fPIC -fobjc-arc'
        .. ' -undefined dynamic_lookup -framework CoreGraphics -framework Foundation'
        .. ' -I' .. quote(headers)
        .. ' ' .. quote(source)
        .. ' -o ' .. quote(binary) .. ' 2>&1')
    assert(built, output)
  end
  return assert(package.loadlib(binary, 'luaopen_keystate_native'))()
end)
if not ok then
  log.e('native input state unavailable: ' .. tostring(result))
  return false
end
return result
