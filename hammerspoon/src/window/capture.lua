local M = {}

-- Compile once at configuration load, never on the shortcut's display path.
function M.new(h)
  h = h or hs
  local directory = debug.getinfo(1, 'S').source:sub(2):match('(.*/)')
  local source = directory .. 'capture_native.m'
  local file = assert(io.open(source, 'r'))
  local content = file:read('*a'); file:close()
  local binary = h.fs.temporaryDirectory() .. 'hammerspoon-window-capture-'
      .. h.hash.SHA256(content) .. '.so'
  if not h.fs.attributes(binary) then
    local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    local output, ok = h.execute('/usr/bin/clang -shared -fPIC -fobjc-arc -O2'
        .. ' -undefined dynamic_lookup -framework Cocoa '
        .. quote(source) .. ' -o ' .. quote(binary) .. ' 2>&1')
    assert(ok, output)
  end
  return assert(package.loadlib(binary, 'luaopen_window_capture'))()
end

return M
