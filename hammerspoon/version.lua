local Version = {}
Version.__index = Version

local StrictVersion = {}
StrictVersion.__index = StrictVersion

local PartialVersion = {}
PartialVersion.__index = PartialVersion

local function parse_version(v)
  local parts = {}
  local tv = type(v)

  if tv == "string" or tv == "number" then
    for num in tostring(v):gmatch("%d+") do
      parts[#parts + 1] = tonumber(num)
    end

  elseif tv == "table" then
    if v.major ~= nil or v.minor ~= nil or v.patch ~= nil then
      if v.major ~= nil then
        parts[1] = tonumber(v.major)
      end
      if v.minor ~= nil then
        parts[2] = tonumber(v.minor)
      end
      if v.patch ~= nil then
        parts[3] = tonumber(v.patch)
      end
    else
      for i = 1, #v do
        parts[i] = tonumber(v[i])
      end
    end

  else
    error("unsupported version type: " .. tv)
  end

  return parts
end

local function compare_prefix(a, b)
  local n = math.min(#a, #b)

  for i = 1, n do
    if a[i] < b[i] then return -1 end
    if a[i] > b[i] then return 1 end
  end

  return 0
end

local function compare_strict(a, b)
  local n = math.max(#a, #b)

  for i = 1, n do
    local av = a[i] or 0
    local bv = b[i] or 0
    if av < bv then return -1 end
    if av > bv then return  1 end
  end

  return 0
end

local function ensure_strict(v)
  if getmetatable(v) == StrictVersion then
    return v
  end
  return StrictVersion.new(v)
end

local function ensure_partial(v)
  if getmetatable(v) == PartialVersion then
    return v
  end
  return PartialVersion.new(v)
end

function StrictVersion.__lt(a, b)
  a = ensure_strict(a)
  b = ensure_strict(b)
  return compare_strict(a.parts, b.parts) < 0
end

function StrictVersion.__le(a, b)
  a = ensure_strict(a)
  b = ensure_strict(b)
  return compare_strict(a.parts, b.parts) <= 0
end

function PartialVersion.__lt(a, b)
  a = ensure_partial(a)
  b = ensure_partial(b)
  return compare_prefix(a.parts, b.parts) < 0
end

function PartialVersion.__le(a, b)
  a = ensure_partial(a)
  b = ensure_partial(b)
  return compare_prefix(a.parts, b.parts) <= 0
end

function StrictVersion:equals(other)
  local other_ver = ensure_strict(other)

  if not other_ver then
    return rawequal(self, other_ver)
  end

  local pa, pb = self.parts, other_ver.parts
  local n = math.max(#pa, #pb)

  for i = 1, n do
    local ai = pa[i] or 0
    local bi = pb[i] or 0
    if ai ~= bi then
      return false
    end
  end

  return true
end

function PartialVersion:withMinor(minor)
  return StrictVersion.new({
    major = self.major,
    minor = tonumber(minor),
  })
end

function PartialVersion:withPatch(patch)
  return StrictVersion.new({
    major = self.major,
    minor = self.minor,
    patch = tonumber(patch),
  })
end

local function version_index(self, key)
  if key == "major" then
    return self.parts[1] or 0
  elseif key == "minor" then
    return self.parts[2] or 0
  elseif key == "patch" then
    return self.parts[3] or 0
  else
    return getmetatable(self)[key]
  end
end

local function version_tostring(self)
  return table.concat(self.parts, ".")
end

PartialVersion.__index     = version_index
PartialVersion.__tostring = version_tostring

StrictVersion.__index     = version_index
StrictVersion.__tostring = version_tostring

function Version.newOS(v)
  return setmetatable({
    parts = parse_version(v)
  }, PartialVersion)
end

function Version.new(v)
  return setmetatable({
    parts = parse_version(v)
  }, StrictVersion)
end

PartialVersion.new  = Version.newOS
StrictVersion.new   = Version.new

return Version