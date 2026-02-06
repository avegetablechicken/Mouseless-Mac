local Version = {}
Version.__index = Version

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

local function compare_parts(a, b)
  local n = math.min(#a, #b)

  for i = 1, n do
    if a[i] < b[i] then
      return -1
    elseif a[i] > b[i] then
      return 1
    end
  end

  return 0
end

function Version.new(v)
  return setmetatable({
    raw = v,
    parts = parse_version(v)
  }, Version)
end

function Version:__index(key)
  if key == "major" then
    return self.parts[1] or 0
  elseif key == "minor" then
    return self.parts[2] or 0
  elseif key == "patch" then
    return self.parts[3] or 0
  else
    return Version[key]
  end
end

local function ensure_version(v)
  if getmetatable(v) == Version then
    return v
  end
  return Version.new(v)
end

function Version.__lt(a, b)
  a = ensure_version(a)
  b = ensure_version(b)
  return compare_parts(a.parts, b.parts) < 0
end

function Version.__le(a, b)
  a = ensure_version(a)
  b = ensure_version(b)
  return compare_parts(a.parts, b.parts) <= 0
end

function Version.__tostring(self)
  return table.concat(self.parts, ".")
end

function Version:withMinor(minor)
  return Version.new({
    major = self.major,
    minor = tonumber(minor),
  })
end

function Version:withPatch(patch)
  return Version.new({
    major = self.major,
    minor = self.minor,
    patch = tonumber(patch),
  })
end

return Version