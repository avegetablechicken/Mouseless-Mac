-- System proxy helpers.
--
-- These helpers manage macOS system proxy settings using `networksetup`,
-- and provide a unified interface for different proxy clients and modes
-- (PAC / Global).

-- Disable all system proxy settings for the given network service
local function disable_proxy(networkservice)
  networkservice = networkservice or getNetworkService()
  local cmds = {
    'networksetup -setproxyautodiscovery "' .. networkservice .. '" off',
    'networksetup -setautoproxystate "' .. networkservice .. '" off',
    'networksetup -setwebproxystate "' .. networkservice .. '" off',
    'networksetup -setsecurewebproxystate "' .. networkservice .. '" off',
    'networksetup -setsocksfirewallproxystate "' .. networkservice .. '" off',
  }
  hs.execute(table.concat(cmds, ' && '))
end

local ProxyConfigs

-- Enable system proxy using PAC file for a proxy client
local function enable_proxy_PAC(client, location)
  local networkservice = getNetworkService()
  local cmds = {
    'networksetup -setproxyautodiscovery "' .. networkservice .. '" off',
    'networksetup -setwebproxystate "' .. networkservice .. '" off',
    'networksetup -setsecurewebproxystate "' .. networkservice .. '" off',
    'networksetup -setsocksfirewallproxystate "' .. networkservice .. '" off',
  }

  if client ~= nil then
    local config = ProxyConfigs[client]
    if location then
      config = config[location]
    end
    local PACFile = config.PAC
    tinsert(cmds, 'networksetup -setautoproxyurl "' .. networkservice .. '" ' .. PACFile)
  end
  tinsert(cmds, 'networksetup -setautoproxystate "' .. networkservice .. '" on')
  hs.execute(table.concat(cmds, ' && '))
end

-- Enable system proxy using global (HTTP / HTTPS / SOCKS) mode
local function enable_proxy_global(client, location, mode)
  local networkservice = getNetworkService()
  local cmds = {
    'networksetup -setproxyautodiscovery "' .. networkservice .. '" off',
    'networksetup -setautoproxystate "' .. networkservice .. '" off',
  }

  if client ~= nil then
    local config = ProxyConfigs[client]
    if location then
      config = config[location]
    end
    local addrs = config[mode or "global"] or config.global
    tinsert(cmds, 'networksetup -setwebproxy "' .. networkservice .. '" ' .. addrs[1] .. ' ' .. addrs[2])
    tinsert(cmds, 'networksetup -setsecurewebproxy "' .. networkservice .. '" ' .. addrs[3] .. ' ' .. addrs[4])
    tinsert(cmds, 'networksetup -setsocksfirewallproxy "' .. networkservice .. '" ' .. addrs[5] .. ' ' .. addrs[6])
  end

  tinsert(cmds, 'networksetup -setwebproxystate "' .. networkservice .. '" on')
  tinsert(cmds, 'networksetup -setsecurewebproxystate "' .. networkservice .. '" on')
  tinsert(cmds, 'networksetup -setsocksfirewallproxystate "' .. networkservice .. '" on')

  hs.execute(table.concat(cmds, ' && '))
end

local proxyAppBundleIDs = {
  V2RayX = "cenmrev.V2RayX",
  V2rayU = "net.yanue.V2rayU",
  v2rayN = "2dust.v2rayN",
  MonoCloud = "com.MonoCloud.MonoProxyMac",
  ["Clash Verge Rev"] = "io.github.clash-verge-rev.clash-verge-rev",
}

-- Toggle connect/disconnect VPN using `V2RayX`
local function toggleV2RayX(enable, alert)
  local appid = proxyAppBundleIDs.V2RayX
  if find(appid) == nil then
    hs.application.launchOrFocusByBundleID(appid)
  end

  local appUI = toappui(find(appid))
  local menu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1, AX.Menu, 1)
  if menu == nil then
    if alert then
      hs.alert("Error occurred while loading/unloading V2ray core in \"V2RayX\"")
    end
    return false
  end

  local set
  if enable == true then
    local load = getc(menu, AX.MenuItem, "Load core")
    if load ~= nil then
      load:performAction(AX.Press)
      set = true
    end
  elseif enable == false then
    local unload = getc(menu, AX.MenuItem, "Unload core")
    if unload ~= nil then
      unload:performAction(AX.Press)
      set = false
    end
  else
    local unload = getc(menu, AX.MenuItem, "Unload core")
    if unload ~= nil then
      unload:performAction(AX.Press)
      set = false
    else
      local load = getc(menu, AX.MenuItem, "Load core")
      load:performAction(AX.Press)
      set = true
    end
  end

  if enable == true or set then
    local unload = getc(menu, AX.MenuItem, "Unload core")
    if unload == nil then
      if alert then
        hs.alert("Error occurred while loading V2ray core in \"V2RayX\"")
      end
      return false
    end
  end

  if alert then
    if set == 0 then
      hs.alert("V2Ray core loaded in \"V2RayX\"")
    else
      hs.alert("V2Ray core unloaded in \"V2RayX\"")
    end
  end

  return true
end

-- Toggle connect/disconnect VPN using `V2rayU`
local function toggleV2RayU(enable, alert)
  local appid = proxyAppBundleIDs.V2rayU
  if find(appid) == nil then
    hs.application.launchOrFocusByBundleID(appid)
  end

  local appUI = toappui(find(appid))
  local menu = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1, AX.Menu, 1)
  if menu == nil then
    if alert then
      hs.alert("Error occurred while loading/unloading V2ray core in \"V2rayU\"")
    end
    return false
  end

  local set
  local turnOnTitle = localizedString("Turn v2ray-core On", appid)
  local turnOffTitle = localizedString("Turn v2ray-core Off", appid)
  if enable == true then
    local turnOn = getc(menu, AX.MenuItem, turnOnTitle)
    if turnOn ~= nil then
      turnOn:performAction(AX.Press)
      set = true
    end
  elseif enable == false then
    local turnOff = getc(menu, AX.MenuItem, turnOffTitle)
    if turnOff ~= nil then
      turnOff:performAction(AX.Press)
      set = false
    end
  else
    local turnOff = getc(menu, AX.MenuItem, turnOffTitle)
    if turnOff ~= nil then
      turnOff:performAction(AX.Press)
      set = false
    else
      local turnOn = getc(menu, AX.MenuItem, turnOnTitle)
      turnOn:performAction(AX.Press)
      set = true
    end
  end

  if enable == true or set then
    local turnOff = getc(menu, AX.MenuItem, turnOffTitle)
    if turnOff == nil then
      if alert then
        hs.alert("Error occurred while loading V2ray core in \"V2rayU\"")
      end
      return false
    end
  end

  if alert then
    if set then
      hs.alert("V2Ray core loaded in \"V2rayU\"")
    else
      hs.alert("V2Ray core unloaded in \"V2rayU\"")
    end
  end

  return true
end

-- Ensure a proxy client is running before using its local proxy ports
local function ensureProxyAppRunning(appname)
  local appid = proxyAppBundleIDs[appname]
  if find(appid) == nil then
    hs.application.launchOrFocusByBundleID(appid)
  end

  return true
end

local function findV2rayNElement(element, predicate, depth)
  if element == nil or (depth or 0) > 40 then return end
  if predicate(element) then return element end
  for _, child in ipairs(element.AXChildren or {}) do
    local found = findV2rayNElement(child, predicate, (depth or 0) + 1)
    if found then return found end
  end
end

local function v2rayNRoutingName()
  local path = os.getenv("HOME")
      .. "/Library/Application Support/v2rayN/guiConfigs/guiNDB.db"
  if not exists(path) then return end
  local db = hs.sqlite3.open(path, hs.sqlite3.OPEN_READONLY)
  if db == nil then return end
  local name
  local ok = pcall(function()
    for row in db:nrows("SELECT Remarks FROM RoutingItem WHERE IsActive = 1 LIMIT 1") do
      name = row.Remarks
    end
  end)
  db:close()
  if ok then return name end
end

local function matchesV2rayNRoute(name, mode)
  if type(name) ~= "string" then return false end
  local title = (ProxyConfigs.v2rayN.routing or {})[mode]
  if title ~= nil then return name == title end
  local keyword = mode == "global" and "Global" or "Whitelist"
  return name:find(keyword, 1, true) ~= nil
end

local function clickV2rayNMode(mode)
  ensureProxyAppRunning("v2rayN")
  local appid = proxyAppBundleIDs.v2rayN
  local app = find(appid)
  if app == nil then return false end
  if matchesV2rayNRoute(v2rayNRoutingName(), mode) then return true end
  local appUI = toappui(app)
  if not app:isFrontmost() or #app:visibleWindows() == 0 then
    if #app:visibleWindows() == 0 and getc(appUI, AX.MenuBar, -1) ~= nil then
      clickRightMenuBarItem(appid, "Display GUI")
    else
      app:activate(true)
    end
    return false
  end
  local routing = findV2rayNElement(appUI, function(element)
    return element.AXIdentifier == "cmbRoutings2"
  end)
  if routing == nil then return false end
  if routing.AXExpanded ~= true then
    routing:performAction("AXShowMenu")
    return false
  end
  local item = findV2rayNElement(routing, function(element)
    return element.AXRole == AX.MenuItem and element.AXEnabled ~= false
        and matchesV2rayNRoute(element.AXTitle, mode)
  end)
  if item and item.AXEnabled ~= false then
    -- Avalonia routing items expose neither AXPress nor writable AXSelected.
    leftClickAndRestore(item, app)
  end
  return false -- The existing activation timer retries until the route is saved.
end

local function clashVergeModeMenu(appid)
  local app = find(appid)
  if app == nil then return end
  local menu = getc(toappui(app), AX.MenuBar, -1,
      AX.MenuBarItem, 1, AX.Menu, 1)
  local outboundTitle = localizedString("Outbound Modes", appid)
  local outboundItem = outboundTitle and tfind(
      getc(menu, AX.MenuItem) or {}, function(item)
        local title = item.AXTitle
        return title == outboundTitle
            or title and title:sub(1, #outboundTitle + 2)
              == outboundTitle .. " ("
      end)
  return getc(outboundItem, AX.Menu, 1) or menu
end

local function clickClashVergeMode(title)
  local appid = proxyAppBundleIDs["Clash Verge Rev"]
  local menu = clashVergeModeMenu(appid)
  title = localizedString(title, appid)
  local item = getc(menu, AX.MenuItem, title)
  if item == nil then return false end
  item:performAction(AX.Press)
  return true
end

-- Toggle connect/disconnect VPN using `MonoCloud`
local function toggleMonoCloud(enable, alert)
  local appid = proxyAppBundleIDs.MonoCloud
  if find(appid) == nil then
    hs.application.launchOrFocusByBundleID(appid)
  end

  local appUI = toappui(find(appid))
  local appVer = applicationVersion(appid)
  local proxyItemTitle = "Set As System Proxy"
  if appVer and appVer >= "1.0" then
    proxyItemTitle = "System Proxy"
  end
  local menuItem = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1,
      AX.Menu, 1, AX.MenuItem, proxyItemTitle)
  if menuItem == nil then
    if alert then
      hs.alert("Error occurred. Please retry")
    end
    return false
  end

  local ticked = menuItem.AXMenuItemMarkChar
  local set
  if enable == true then
    if ticked ~= "✓" then
      menuItem:performAction(AX.Press)
      set = true
    end
  elseif enable == false then
    if ticked == "✓" then
      menuItem:performAction(AX.Press)
      set = false
    end
  else
    menuItem:performAction(AX.Press)
    set = ticked ~= "✓"
  end

  if alert then
    if set then
      hs.alert("Set MonoCloud as system proxy")
    else
      hs.alert("Unset MonoCloud as system proxy")
    end
  end

  return true
end

-- Proxy activation strategies.
--
-- Maps proxy clients and modes (global / pac) to activation routines,
-- combining application toggling and system proxy configuration.

-- Activate proxy client and configure system proxy according to mode
local proxyActivateFuncs = {
  V2RayX = {
    global = function()
      if toggleV2RayX(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2RayX, "Global Mode") then
          return enable_proxy_global("V2RayX")
        end
      end
      return false
    end,
    pac = function()
      if toggleV2RayX(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2RayX, "PAC Mode") then
          return enable_proxy_PAC("V2RayX")
        end
      end
      return false
    end
  },

  V2rayU = {
    global = function()
      if toggleV2RayU(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2rayU, "Global Mode") then
          return enable_proxy_global("V2rayU")
        end
      end
      return false
    end,
    pac = function()
      if toggleV2RayU(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2rayU, "Pac Mode") then
          return enable_proxy_PAC("V2rayU")
        end
      end
      return false
    end
  },

  v2rayN = {
    global = function()
      if clickV2rayNMode("global") then
        return enable_proxy_global("v2rayN")
      end
      return false
    end,
    pac = function()
      if clickV2rayNMode("pac") then
        return enable_proxy_global("v2rayN", nil, "pac")
      end
      return false
    end
  },

  ["Clash Verge Rev"] = {
    global = function()
      if ensureProxyAppRunning("Clash Verge Rev")
          and clickClashVergeMode("Global Mode") then
        return enable_proxy_global("Clash Verge Rev")
      end
      return false
    end,
    pac = function()
      if ensureProxyAppRunning("Clash Verge Rev")
          and clickClashVergeMode("Rule Mode") then
        return enable_proxy_global("Clash Verge Rev")
      end
      return false
    end
  },

  MonoCloud = {
    global = function()
      if toggleMonoCloud(false) then
        if clickRightMenuBarItem(proxyAppBundleIDs.MonoCloud, { "Outbound Mode", 2 }) then
          return enable_proxy_global("MonoCloud")
        end
      end
      return false
    end,
    pac = function()
      if toggleMonoCloud(false) then
        if clickRightMenuBarItem(proxyAppBundleIDs.MonoCloud, { "Outbound Mode", 3 }) then
          return enable_proxy_global("MonoCloud")
        end
      end
      return false
    end
  }
}

-- menubar for proxy
local proxy = hs.menubar.new(true, "PROXY")
local proxyIconPath = hs.configdir .. "/static/menubar/"
local proxyIconCacheDir = hs.fs.temporaryDirectory()
    .. hs.settings.bundleID .. "/images/"
local proxyForIcon = ""
local proxyAppIconBundleID
local composedProxyIcons = {}
local proxyUsesLightForeground
local proxyIconForcedInactive = false
local nextProxyThemeCheck = 0

local function imageLuminanceAt(image, x, y)
  local color = image:colorAt(hs.geometry.point(x, y))
  local rgb = color and hs.drawing.color.asRGB(color)
  if type(rgb) ~= "table" then return end
  return 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
end

-- Read the actual foreground used for a template icon in the menu bar.
-- This can differ from the global interface style because of the wallpaper.
local function menuBarUsesLightForeground()
  local app = hs.application.get("com.apple.finder")
  if not app then return end
  local appleMenu = getc(toappui(app), AX.MenuBar, 1, AX.MenuBarItem, 1)
  if not appleMenu or not appleMenu.AXPosition or not appleMenu.AXSize then
    return
  end
  local frame = hs.geometry.rect(
      appleMenu.AXPosition.x, appleMenu.AXPosition.y,
      appleMenu.AXSize.w, appleMenu.AXSize.h)
  local screen = hs.screen.mainScreen()
  local screenFrame = screen:fullFrame()
  if not frame or frame.x < screenFrame.x or frame.y < screenFrame.y
      or frame.x + frame.w > screenFrame.x + screenFrame.w
      or frame.y + frame.h > screenFrame.y + screenFrame.h then
    return
  end

  local snapshot = screen:snapshot(frame)
  if not snapshot then return end
  local size = snapshot:size()
  if size.w < 4 or size.h < 4 then return end

  local foreground = imageLuminanceAt(snapshot, size.w / 2, size.h / 2)
  local backgrounds = {
    imageLuminanceAt(snapshot, 1, 1),
    imageLuminanceAt(snapshot, size.w - 2, 1),
    imageLuminanceAt(snapshot, 1, size.h - 2),
    imageLuminanceAt(snapshot, size.w - 2, size.h - 2),
  }
  if not foreground or backgrounds[1] == nil or backgrounds[2] == nil
      or backgrounds[3] == nil or backgrounds[4] == nil then
    return
  end
  local background = (backgrounds[1] + backgrounds[2]
      + backgrounds[3] + backgrounds[4]) / 4
  if math.abs(foreground - background) < 0.15 then return end
  return foreground > background
end

local function composeProxyIcon(bundleID, lightForeground)
  local appVer = tostring(applicationVersion(bundleID) or "unknown")
  local cacheKey = bundleID .. "-" .. appVer
      .. (lightForeground and "-white" or "-black")
  local cacheFile = proxyIconCacheDir .. "proxy-" .. cacheKey .. ".png"
  if composedProxyIcons[cacheKey] then return composedProxyIcons[cacheKey] end
  if exists(cacheFile) then
    composedProxyIcons[cacheKey] = hs.image.imageFromPath(cacheFile)
    if composedProxyIcons[cacheKey] then return composedProxyIcons[cacheKey] end
  end

  local appIcon = hs.image.imageFromAppBundle(bundleID)
  if not appIcon then return end

  local color = { white = lightForeground and 1 or 0 }
  local canvas = hs.canvas.new({ x = 0, y = 0, w = 18, h = 18 })
  local center, nodes = { x = 8, y = 8.8 }, {{ x = 4.2, y = 4.7 }, { x = 12, y = 4.7 }, { x = 8, y = 13.6 }}
  for _, node in ipairs(nodes) do
    canvas:appendElements({ type = "segments", action = "stroke", coordinates = { center, node }, strokeColor = color, strokeWidth = 1.4 },
      { type = "circle", action = "fill", center = node, radius = 1.6, fillColor = color })
  end
  canvas:appendElements(
    { type = "circle", action = "fill", center = center, radius = 2, fillColor = color },
    { type = "image", image = appIcon, imageAlpha = 1,
      frame = { x = 8.8, y = 8.8, w = 9.0, h = 9.0 },
      imageScaling = "scaleProportionally" })

  local icon = canvas:imageFromCanvas()
  canvas:delete()
  composedProxyIcons[cacheKey] = icon
  if icon then
    mkdir(proxyIconCacheDir)
    icon:saveToFile(cacheFile, false, "PNG")
  end
  return icon
end

local function applyProxyIcon()
  local icon = "proxy.pdf"
  local template = true
  if proxyIconForcedInactive or proxyForIcon == "" then
    icon = "proxy-disabled.pdf"
    template = false
  elseif proxyAppIconBundleID then
    local composed = composeProxyIcon(
        proxyAppIconBundleID, proxyUsesLightForeground)
    if composed then icon, template = composed, false end
  end
  if type(icon) == "string" then icon = proxyIconPath .. icon end
  proxy:setIcon(icon, template)
  local label = proxyForIcon
  if label == "" then label = "Off" end
  proxy:setTooltip("Proxy: " .. label)
end

local function refreshProxyIconTheme(force)
  if proxyIconForcedInactive or not proxyAppIconBundleID then return end
  local now = hs.timer.secondsSinceEpoch()
  if not force and now < nextProxyThemeCheck then return end

  local detected = menuBarUsesLightForeground()
  nextProxyThemeCheck = now + (detected == nil and 1 or 5)
  if detected ~= nil and detected ~= proxyUsesLightForeground then
    proxyUsesLightForeground = detected
    applyProxyIcon()
  end
end

-- Set the proxy icon, composing a third-party app icon when available.
local function setProxyIcon(enabledProxy)
  proxyForIcon = enabledProxy or ""
  proxyAppIconBundleID = proxyAppBundleIDs[proxyForIcon]
  proxyIconForcedInactive = false
  if proxyAppIconBundleID then
    local detected = menuBarUsesLightForeground()
    if detected == nil then detected = hs.host.interfaceStyle() == "Dark" end
    proxyUsesLightForeground = detected
  end
  applyProxyIcon()
end

local function forceInactiveProxyIcon()
  proxyIconForcedInactive = true
  applyProxyIcon()
  proxy:setTooltip("Proxy: TUN Mode")
end

setProxyIcon(nil)
local proxyThemeWatcher = hs.distributednotifications.new(function()
  hs.timer.doAfter(0.1, function() refreshProxyIconTheme(true) end)
end, "AppleInterfaceThemeChangedNotification"):start()
local proxyMenu = {}

-- Proxy configuration loader.
--
-- Loads and normalizes proxy configurations from JSON files,
-- supporting optional conditions and multiple locations.
ProxyConfigs = {}

local function parseProxyModes(spec)
  local config = { routing = {} }
  if type(spec.pac) == "string" then config.PAC = spec.pac end
  for _, mode in ipairs({ "global", "pac" }) do
    local settings = spec[mode]
    if type(settings) == "table" then
      local httpIp, httpPort = settings.http:match("(.+):(%d+)")
      local httpsIp, httpsPort = settings.https:match("(.+):(%d+)")
      local socksIp, socksPort = settings.socks5:match("(.+):(%d+)")
      config[mode] = { httpIp, httpPort, httpsIp, httpsPort, socksIp, socksPort }
      config.routing[mode] = settings.routing
    end
  end
  return config
end

-- Parse proxy configuration definitions into normalized runtime structure
local function parseProxyConfigurations(configs)
  for name, config in pairs(configs) do
    ProxyConfigs[name] = config.locations == nil and parseProxyModes(config) or {}
    if config.condition ~= nil then
      ProxyConfigs[name].condition = config.condition
      if config.locations ~= nil then
        ProxyConfigs[name].locations = config.locations
        for _, loc in ipairs(config.locations) do
          ProxyConfigs[name][loc] = parseProxyModes(config[loc])
        end
      end
    end
  end
end

local proxyConfigs
if exists("config/proxy.json") then
  proxyConfigs = hs.json.read("config/proxy.json")
end
if proxyConfigs ~= nil then
  parseProxyConfigurations(proxyConfigs)
end

local privateProxyConfigs
if exists("config/private-proxy.json") then
  privateProxyConfigs = hs.json.read("config/private-proxy.json")
end
if privateProxyConfigs ~= nil then
  parseProxyConfigurations(privateProxyConfigs)
end

-- Shared styled text for section headers, mimicking macOS standard
-- section header appearance (smaller system font, secondary label color).
local SECTION_HEADER_STYLE = {
  font = { name = ".AppleSystemUIFont", size = 11 },
  color = { red = 0.55, green = 0.55, blue = 0.56, alpha = 1.0 },
}

local function styledTitle(text)
  return hs.styledtext.new(text, SECTION_HEADER_STYLE)
end

-- Proxy menubar.
--
-- Builds and maintains a dynamic menubar menu reflecting
-- current system proxy state and available proxy configurations.

local proxyMenuItemCandidates =
{
  {
    appname = "V2RayX",
    shortcut = 'x',
    items = {
      {
        title = "    Global Mode",
        fn = proxyActivateFuncs.V2RayX.global
      },

      {
        title = "    PAC Mode",
        fn = proxyActivateFuncs.V2RayX.pac
      }
    }
  },

  {
    appname = "V2rayU",
    shortcut = 'u',
    items = {
      {
        title = "    Global Mode",
        fn = proxyActivateFuncs.V2rayU.global
      },

      {
        title = "    PAC Mode",
        fn = proxyActivateFuncs.V2rayU.pac
      }
    }
  },

  {
    appname = "v2rayN",
    shortcut = 'n',
    items = {
      {
        title = "    Global Mode",
        fn = proxyActivateFuncs.v2rayN.global
      },
      {
        title = "    PAC Mode",
        fn = proxyActivateFuncs.v2rayN.pac
      }
    }
  },

  {
    appname = "Clash Verge Rev",
    shortcut = 'c',
    items = {
      {
        title = "    Global Mode",
        fn = proxyActivateFuncs["Clash Verge Rev"].global
      },

      {
        title = "    PAC Mode",
        fn = proxyActivateFuncs["Clash Verge Rev"].pac
      }
    }
  },

  {
    appname = "MonoCloud",
    shortcut = 'm',
    items = {
      {
        title = "    Global Mode",
        fn = proxyActivateFuncs.MonoCloud.global
      },

      {
        title = "    PAC Mode",
        fn = proxyActivateFuncs.MonoCloud.pac
      }
    }
  },
}

-- Proxy menu registration and state synchronization.
--
-- This section:
-- - Detects current system proxy state
-- - Matches it against configured proxy definitions
-- - Builds the menubar menu accordingly
-- - Reacts to network changes and service switches

-- Wrap proxy menu item to update checked state and extra info dynamically
local registerProxyMenu
local parseProxyInfo
local proxyActivationTimer
local proxyLaunchTimer
local function updateProxyWrapper(wrapped, appname)
  local fn = function(mod, item)
    if proxyLaunchTimer then
      proxyLaunchTimer:stop()
      proxyLaunchTimer = nil
    end
    if proxyActivationTimer then
      proxyActivationTimer:stop()
      proxyActivationTimer = nil
    end
    local appid = proxyAppBundleIDs[appname]
    local previousApp = appid and find(appid)
    local restoreV2rayN = appname == "v2rayN"
        and (previousApp == nil or #previousApp:visibleWindows() == 0)
    local activate = function()
      local activated = wrapped.fn(mod, item) ~= false
      local deadline = hs.timer.secondsSinceEpoch() + 10
      proxyActivationTimer = hs.timer.waitUntil(function()
        if not activated and (appid == nil or find(appid) ~= nil) then
          activated = wrapped.fn(mod, item) ~= false
        end
        local enabledProxy, mode = parseProxyInfo(NetworkWatcher:proxies())
        return activated and enabledProxy == (appname or "")
            and (appname == nil or mode == wrapped.title:match("%S+"))
            or hs.timer.secondsSinceEpoch() >= deadline
      end, function()
        proxyActivationTimer = nil
        if restoreV2rayN then
          local app = find(appid)
          local window = app and app:mainWindow()
          if window then window:close(); app:hide() end
        end
        registerProxyMenu(false)
        if not activated then hs.alert("Unable to activate " .. (appname or "proxy")) end
      end, 0.1)
    end
    if appid == nil then
      activate()
      return
    end
    local ready = function()
      local app = find(appid)
      if app == nil then return false end
      if appname == "v2rayN" then return true end
      local menu = getc(toappui(app), AX.MenuBar, -1,
          AX.MenuBarItem, 1, AX.Menu, 1)
      return #(getc(menu, AX.MenuItem) or {}) > 0
    end
    if ready() then
      activate()
      return
    end
    ensureProxyAppRunning(appname)
    local deadline = hs.timer.secondsSinceEpoch() + 10
    proxyActivationTimer = hs.timer.waitUntil(function()
      return ready() or hs.timer.secondsSinceEpoch() >= deadline
    end, function()
      proxyActivationTimer = nil
      if ready() then
        activate()
      else
        hs.alert("Error occurred while starting " .. appname .. ". Please retry")
      end
    end, 0.1)
  end

  return {
    title = wrapped.title,
    fn = fn,
    shortcut = wrapped.shortcut,
    checked = wrapped.checked,
  }
end

-- Register proxy menu entries for a specific proxy configuration
local function registerHTTPProxyEntries(menu, addr)
  local function endpoint(host, port)
    if host == nil or host == "" or port == nil or port == "" then return nil end
    return host .. ":" .. port
  end
  local http = endpoint(addr[1], addr[2])
  local https = endpoint(addr[3], addr[4])
  if http and http == https then
    tinsert(menu, { title = "HTTP(S)  " .. http, disabled = true })
  else
    if http then
      tinsert(menu, { title = "HTTP  " .. http, disabled = true })
    end
    if https then
      tinsert(menu, { title = "HTTPS  " .. https, disabled = true })
    end
  end
end

local function registerProxyMenuEntry(name, enabled, mode, proxyMenuIdx)
  local config, loc
  if ProxyConfigs[name].locations then
    local locations = ProxyConfigs[name].locations
    local rc = executeCondition(ProxyConfigs[name].condition, true)
    if rc >= 0 and #locations > rc then loc = locations[rc + 1]
    else return proxyMenuIdx end
    config = ProxyConfigs[name][loc]
  else
    if ProxyConfigs[name].condition
        and not executeCondition(ProxyConfigs[name].condition) then
      return proxyMenuIdx
    end
    config = ProxyConfigs[name]
  end
  if config ~= nil then
    tinsert(proxyMenu, { title = "-" })
    tinsert(proxyMenu, { title = styledTitle(name), disabled = true })
    if enabled and mode ~= nil then
      if mode == "PAC" then
        local PACFile = config.PAC
        tinsert(proxyMenu, {
          title = "PAC URL  " .. PACFile,
          disabled = true
        })
      else
        local addr = config.global
        registerHTTPProxyEntries(proxyMenu, addr)
        tinsert(proxyMenu, {
          title = "SOCKS5  " .. addr[5] .. ":" .. addr[6],
          disabled = true
        })
      end
    end
    if config.global ~= nil then
      tinsert(proxyMenu, updateProxyWrapper({
        title = "    Global Mode",
        fn = function() enable_proxy_global(name, loc) end,
        shortcut = tostring(proxyMenuIdx),
        checked = enabled and mode == "Global"
      }, name))
      proxyMenuIdx = proxyMenuIdx + 1
    end
    if config.PAC ~= nil then
      tinsert(proxyMenu, updateProxyWrapper({
        title = "    PAC Mode",
        fn = function() enable_proxy_PAC(name, loc) end,
        shortcut = tostring(proxyMenuIdx),
        checked = enabled and mode == "PAC"
      }, name))
      proxyMenuIdx = proxyMenuIdx + 1
    end
  end
  return proxyMenuIdx
end

-- Parse current system proxy state and detect enabled proxy and mode
parseProxyInfo = function(info, require_mode)
  if require_mode == nil then require_mode = true end
  local enabledProxy = ""
  local mode = nil
  if info.ProxyAutoConfigEnable == 1 then
    for appname, config in pairs(ProxyConfigs) do
      if config.locations == nil then
        if config.PAC ~= nil
            and info.ProxyAutoConfigURLString:match(config.PAC) then
          enabledProxy = appname
          mode = "PAC"
        end
      else
        for _, loc in ipairs(config.locations) do
          local spec = config[loc]
          if spec.PAC ~= nil
              and info.ProxyAutoConfigURLString:match(spec.PAC) then
            enabledProxy = appname
            mode = "PAC"
            break
          end
        end
      end
      if mode ~= nil then break end
    end
  elseif info.HTTPEnable == 1 and info.HTTPSEnable == 1 then
    for appname, config in pairs(ProxyConfigs) do
      if config.locations == nil then
        for _, proxyMode in ipairs({ "global", "pac" }) do
          local addrs = config[proxyMode]
          if addrs ~= nil
              and addrs[1] == info.HTTPProxy
              and addrs[2] == tostring(info.HTTPPort)
              and addrs[3] == info.HTTPSProxy
              and addrs[4] == tostring(info.HTTPSPort) then
            enabledProxy = appname
            break
          end
        end
      else
        for _, loc in pairs(config.locations) do
          local spec = config[loc]
          if spec.global ~= nil
              and spec.global[1] == info.HTTPProxy
              and spec.global[2] == tostring(info.HTTPPort)
              and spec.global[3] == info.HTTPSProxy
              and spec.global[4] == tostring(info.HTTPSPort) then
            enabledProxy = appname
            break
          end
        end
      end
      if enabledProxy ~= "" then
        if enabledProxy == "Clash Verge Rev" and require_mode then
          local appid = proxyAppBundleIDs[enabledProxy]
          if find(appid) ~= nil then
            local outboundModeMenu = clashVergeModeMenu(appid)
            if outboundModeMenu ~= nil then
              local ruleMode = getc(outboundModeMenu, AX.MenuItem,
                  localizedString("Rule Mode", appid))
              local globalMode = getc(outboundModeMenu, AX.MenuItem,
                  localizedString("Global Mode", appid))
              if ruleMode and ruleMode.AXMenuItemMarkChar == "✓" then
                mode = "PAC"
              elseif globalMode and globalMode.AXMenuItemMarkChar == "✓" then
                mode = "Global"
              end
            end
          end
        elseif enabledProxy == "v2rayN" and require_mode then
          local name = v2rayNRoutingName()
          if matchesV2rayNRoute(name, "global") then
            mode = "Global"
          elseif matchesV2rayNRoute(name, "pac") then
            mode = "PAC"
          end
        elseif enabledProxy ~= "MonoCloud" then
          mode = "Global"
        elseif require_mode then
          local appVer = applicationVersion(proxyAppBundleIDs.MonoCloud)
          if appVer and appVer >= "1.0" then
            mode = "Global"
          else
            local appid = proxyAppBundleIDs.MonoCloud
            if find(appid) ~= nil then
              local appUI = toappui(find(appid))
              local outboundModeMenu = getc(appUI, AX.MenuBar, -1,
                  AX.MenuBarItem, 1, AX.Menu, 1,
                  AX.MenuItem, "Outbound Mode", AX.Menu, 1)
              if outboundModeMenu ~= nil then
                if getc(outboundModeMenu, AX.MenuItem, 2)
                    .AXMenuItemMarkChar == "✓" then
                  mode = "Global"
                elseif getc(outboundModeMenu, AX.MenuItem, 3)
                    .AXMenuItemMarkChar == "✓" then
                  mode = "PAC"
                end
              end
            end
          end
        end
        break
      end
    end
  end
  if require_mode then
    return enabledProxy, mode
  else
    return enabledProxy
  end
end

local proxyExitItem
local proxyExitMenu
local proxyExitCheckedAt = 0
local proxyExitRequest = 0
local proxyExitTask
local proxyExitTimer

local PROXY_EXIT_HELP = {
  pactester_missing = "pactester is not installed, so the PAC route cannot be resolved. Install it with: brew install pacparser",
  pac_unreachable = "The configured PAC URL did not respond. Check the PAC URL and its local web server.",
  pac_invalid = "pactester could not evaluate the configured PAC file. Check the PAC file syntax.",
  pac_no_route = "The PAC file returned no route for the exit IP request. Check its FindProxyForURL result.",
  route_unsupported = "The PAC file returned an unsupported route. Use DIRECT, PROXY, HTTP, HTTPS, or SOCKS.",
  request_timeout = "The exit IP lookup timed out. Check the network and selected proxy, then retry.",
  request_failed = "The selected proxy route could not reach the exit IP service. Check that the proxy server is running.",
  response_invalid = "The exit IP service returned invalid data. Retry or check access to ipinfo.io.",
}

local function setProxyExitFailure(failure)
  proxyExitItem.tooltip = failure and
      (PROXY_EXIT_HELP[failure] or PROXY_EXIT_HELP.request_failed) or nil
end

local function awaitProxyExitTask(path, args, input, timeout, request)
  local thread = coroutine.running()
  local task
  local outputPath
  if not input then
    outputPath = os.tmpname()
    tinsert(args, "--output")
    tinsert(args, outputPath)
  end
  local function cleanup()
    if outputPath then os.remove(outputPath); outputPath = nil end
  end
  local function finish(status, body)
    if outputPath then
      if status == 0 then
        local file = io.open(outputPath, "rb")
        if file then
          body = file:read("*a")
          file:close()
        else
          status, body = -1, ""
        end
      end
      cleanup()
    end
    if not task or proxyExitTask ~= task then return end
    proxyExitTask = nil
    if proxyExitTimer then proxyExitTimer:stop(); proxyExitTimer = nil end
    if request == proxyExitRequest then
      assert(coroutine.resume(thread, status, body))
    end
  end
  -- File output avoids pipe limits and menu-tracking delays in stream callbacks.
  task = hs.task.new(path, finish, args)
  if not task then cleanup(); return -1, "" end
  proxyExitTask = task
  if input then task:setInput(input) end
  if not task:start() then
    proxyExitTask = nil
    cleanup()
    return -1, ""
  end
  proxyExitTimer = hs.timer.doAfter(timeout, function()
    task:terminate()
    finish(-1, "")
  end)
  return coroutine.yield()
end

local function queryProxyExit(request, deadline)
  local function curl(url, address, timeout)
    return awaitProxyExitTask("/usr/bin/curl", {
      "-q", "--silent", "--show-error", "--fail", "--connect-timeout", "5",
      "--max-time", tostring(timeout), "--proxy", address,
      "--noproxy", address == "" and "*" or "",
      "--header", "Cache-Control: no-cache", "--url", url,
    }, nil, timeout + 1, request)
  end
  local routes = { "DIRECT" }
  local settings = NetworkWatcher:proxies()
  if settings.ProxyAutoConfigEnable == 1 then
    local tester
    for _, path in ipairs({ "/opt/homebrew/bin/pactester", "/usr/local/bin/pactester" }) do
      if hs.fs.attributes(path, "mode") == "file" then tester = path; break end
    end
    if not tester then return nil, "pactester_missing" end
    local status, body = curl(settings.ProxyAutoConfigURLString, "", 10)
    if status ~= 0 then return nil, status == 28 and "request_timeout" or "pac_unreachable" end
    local code, result = awaitProxyExitTask(tester,
        { "-p", "-", "-u", "https://www.google.com/" }, body, 5, request)
    if code ~= 0 then return nil, "pac_invalid" end
    routes = {}
    for entry in result:gmatch("[^;]+") do
      local route = entry:match("^%s*(.-)%s*$")
      if route ~= "" then tinsert(routes, route) end
    end
    if #routes == 0 then return nil, "pac_no_route" end
  else
    for _, kind in ipairs({ "HTTPS", "HTTP", "SOCKS" }) do
      if settings[kind .. "Enable"] == 1 then
        local host = settings[kind .. "Proxy"]
        if host:find(":", 1, true) and host:sub(1, 1) ~= "[" then host = "[" .. host .. "]" end
        routes = { (kind == "SOCKS" and "SOCKS5 " or "PROXY ")
            .. host .. ":" .. settings[kind .. "Port"] }
        break
      end
    end
  end
  local schemes = { PROXY = "http", HTTP = "http", HTTPS = "https",
    SOCKS = "socks4a", SOCKS4 = "socks4a", SOCKS5 = "socks5h" }
  -- Only use fallbacks explicitly selected by the PAC.
  local failure = "request_failed"
  for _, route in ipairs(routes) do
    local remaining = math.floor(deadline - hs.timer.secondsSinceEpoch())
    if remaining <= 0 then return nil, "request_timeout" end
    local kind, address = route:match("^(%S+)%s+(%S+)$")
    if route == "DIRECT" then
      address = ""
    elseif schemes[kind] then
      address = schemes[kind] .. "://" .. address
    else
      return nil, "route_unsupported"
    end
    local status, body = curl("https://ipinfo.io/json", address, math.min(12, remaining))
    if status == 0 then
      local ok, info = pcall(hs.json.decode, body or "")
      if ok and type(info) == "table" and type(info.ip) == "string"
          and info.ip:match("^[%x%.:]+$") then return info end
      failure = "response_invalid"
    elseif status == 28 then
      failure = "request_timeout"
    end
  end
  return nil, failure
end

local function refreshProxyExit(force)
  if not proxyExitItem then return end
  local now = hs.timer.secondsSinceEpoch()
  if not force and now - proxyExitCheckedAt < 60 then return end
  proxyExitCheckedAt = now
  proxyExitRequest = proxyExitRequest + 1
  local request = proxyExitRequest
  local item, menu = proxyExitItem, proxyExitMenu
  if proxyExitTimer then proxyExitTimer:stop(); proxyExitTimer = nil end
  if proxyExitTask then
    local task = proxyExitTask
    proxyExitTask = nil
    task:terminate()
  end
  if not getNetworkService() then
    item.title = "No Network Access"
    setProxyExitFailure()
    proxy:setMenu(menu)
    return
  end
  if force then
    item.title = "Loading Server..."
    setProxyExitFailure()
  end
  RunCoroutine(function()
    local info, failure = queryProxyExit(request, now + 45)
    if request ~= proxyExitRequest then return end
    item.title = "Server inaccessible"
    setProxyExitFailure(failure)
    if info then
      local country = type(info.country) == "string" and info.country:upper() or ""
      local flag = ""
      if country:match("^[A-Z][A-Z]$") then
        flag = utf8.char(0x1F1E6 + country:byte(1) - 65,
            0x1F1E6 + country:byte(2) - 65) .. " "
      end
      item.title = "Server  " .. info.ip .. " " .. flag
      setProxyExitFailure()
    end
    proxy:setMenu(menu)
  end)
end

local function registerProxySettingsEntry(menu)
  tinsert(menu, { title = "-" })
  proxyExitItem = { title = "Loading Server...", disabled = true }
  proxyExitMenu = menu
  for i, entry in ipairs(menu) do
    if type(entry.title) == "string" and
        (entry.title:match("^PAC URL%s+") or entry.title:match("^HTTP[S()]*%s+")) then
      tinsert(menu, i, proxyExitItem)
      break
    end
  end
  refreshProxyExit(true)
  tinsert(menu, {
    title = "Show in " .. hs.application.nameForBundleID("com.apple.systempreferences"),
    fn = function()
      local app = hs.application.open("com.apple.systempreferences", 2, true)
      local action = function()
        if OS_VERSION < OS.Ventura then
          hs.osascript.applescript([[
            tell application id "com.apple.systempreferences"
              set current pane to pane "com.apple.preference.network"
              repeat until anchor "Proxies" of current pane exists
                delay 0.1
              end repeat
              reveal anchor "Proxies" of current pane
            end tell
          ]])
        else
          hs.osascript.applescript([[
            tell application id "com.apple.systempreferences"
              reveal anchor "Proxies" of pane ¬
                  id "com.apple.Network-Settings.extension"
            end tell
          ]])
        end
      end

      if app:focusedWindow():role() == AX.Sheet then
        hs.eventtap.keyStroke("", "Escape")
        hs.timer.waitUntil(function()
          return app:focusedWindow():role() ~= AX.Sheet
        end, action)
      else
        action()
      end
    end
  })
end

-- Build and register proxy menubar according to current system state
local function registerProxyMenuImpl(enabledProxy, mode)
  if enabledProxy == nil then
    enabledProxy, mode = parseProxyInfo(NetworkWatcher:proxies())
  end
  setProxyIcon(enabledProxy)

  proxyMenu =
  {
    {
      title = "Information",
      fn = function()
        local info = NetworkWatcher
            :contents("State:/Network/Global/Proxies")["State:/Network/Global/Proxies"]
        local enabled, m = parseProxyInfo(info)
        local header
        if enabled ~= "" then
          header = "Enabled: " .. enabled
          if m ~= nil then
            header = header .. " (" .. m .. ")"
          end
        else
          header = "No Proxy Enabled"
        end

        local content = header .. [[


          Details:

          Auto Proxy Discovery: ]] .. (info.ProxyAutoDiscoveryEnable == 1 and "On" or "Off") .. [[ 

          Auto Proxy:
          URL: ]] .. (info.ProxyAutoConfigURLString or "(null)") .. [[ 
          Enabled: ]] .. (info.ProxyAutoConfigEnable == 1 and "Yes" or "No") .. [[ 

          HTTP Proxy:
          Enabled: ]] .. (info.HTTPEnable == 1 and "Yes" or "No") .. [[ 
          Server: ]] .. (info.HTTPProxy or "").. [[ 
          Port: ]] .. (info.HTTPPort or 0) .. [[ 

          HTTPS Proxy:
          Enabled: ]] .. (info.HTTPSEnable == 1 and "Yes" or "No") .. [[ 
          Server: ]] .. (info.HTTPSProxy or "") .. [[ 
          Port: ]] .. (info.HTTPSPort or 0) .. [[ 

          SOCKS Proxy:
          Enabled: ]] .. (info.SOCKSEnable == 1 and "Yes" or "No") .. [[ 
          Server: ]] .. (info.SOCKSProxy or "") .. [[ 
          Port: ]] .. (info.SOCKSPort or 0)
        hs.focus()
        hs.dialog.blockAlert("Proxy Configuration", content)
      end
    },

    updateProxyWrapper({
      title = "Disable",
      fn = function() disable_proxy() end,
      shortcut = '0',
      checked = enabledProxy == ""
    }),
  }

  local proxyMenuIdx = 1
  local otherProxies = {}
  for name, _ in pairs(ProxyConfigs) do
    if tfind(proxyMenuItemCandidates,
          function(item)
            return item.appname == name
          end) == nil then
      if name == "System" then
        proxyMenuIdx = registerProxyMenuEntry('System',
            enabledProxy == "System", mode, proxyMenuIdx)
      else
        tinsert(otherProxies, name)
      end
    end
  end

  for _, candidate in ipairs(proxyMenuItemCandidates) do
    local appid = proxyAppBundleIDs[candidate.appname]
    if ProxyConfigs[candidate.appname] ~= nil and installed(appid) then
      tinsert(proxyMenu, { title = "-" })
      tinsert(proxyMenu, {
        title = styledTitle(candidate.appname),
        fn = function()
          local actionFunc = function()
            clickRightMenuBarItem(appid)
          end
          if find(appid) == nil then
            local previous = tfind(proxyMenu, function(entry) return entry.checked and entry.fn end)
            local service = getNetworkService()
            local originalProxy, originalMode = parseProxyInfo(NetworkWatcher:proxies())
            local lastProxy, lastMode = originalProxy, originalMode
            local changedAt
            local deadline = hs.timer.secondsSinceEpoch() + 10
            if proxyLaunchTimer then proxyLaunchTimer:stop() end
            hs.application.launchOrFocusByBundleID(appid)
            proxyLaunchTimer = hs.timer.waitUntil(function()
              local currentProxy, currentMode = parseProxyInfo(NetworkWatcher:proxies())
              local now = hs.timer.secondsSinceEpoch()
              if currentProxy ~= lastProxy or currentMode ~= lastMode then
                lastProxy, lastMode, changedAt = currentProxy, currentMode, now
              end
              return changedAt ~= nil and now - changedAt >= 0.5 or now >= deadline
            end, function()
              proxyLaunchTimer = nil
              if previous and service == getNetworkService()
                  and (lastProxy ~= originalProxy or lastMode ~= originalMode) then
                previous.fn({})
              end
            end, 0.1)
            hs.timer.waitUntil(
              function() return find(appid) ~= nil end,
              actionFunc)
          else
            actionFunc()
          end
        end,
        shortcut = candidate.shortcut
      })
      if candidate.appname == enabledProxy and mode ~= nil then
        if mode == "PAC" and
            ProxyConfigs[candidate.appname]["PAC"] ~= nil then
          local PACFile = ProxyConfigs[candidate.appname]["PAC"]
          tinsert(proxyMenu, {
            title = "PAC URL  " .. PACFile,
            disabled = true,
          })
        elseif ProxyConfigs[candidate.appname]["global"] ~= nil then
          local addr = ProxyConfigs[candidate.appname][mode:lower()]
              or ProxyConfigs[candidate.appname].global
          registerHTTPProxyEntries(proxyMenu, addr)
          tinsert(proxyMenu, {
            title = "SOCKS5  " .. addr[5] .. ":" .. addr[6],
            disabled = true,
          })
        end
      end

      for _, menuItem in ipairs(candidate.items) do
        menuItem.shortcut = tostring(proxyMenuIdx)
        local checked = (candidate.appname == enabledProxy)
            and mode and menuItem.title:match(mode) ~= nil
        menuItem.checked = checked
        tinsert(proxyMenu, updateProxyWrapper(menuItem, candidate.appname))
        proxyMenuIdx = proxyMenuIdx + 1
      end
    end
  end

  for _, name in ipairs(otherProxies) do
    proxyMenuIdx = registerProxyMenuEntry(
        name, enabledProxy == name,
        mode, proxyMenuIdx)
  end

  registerProxySettingsEntry(proxyMenu)
  proxy:setMenu(proxyMenu)
end

-- TUN mode detection. Finds utun interfaces with IPv4 addresses, then
-- verifies via netstat that host TCP connections are actually flowing
-- through them. This excludes idle utun interfaces (e.g. Parallels shared
-- networking) that have an IP but don't carry host internet traffic.
local tunActive = false
local tunInfo = nil
local tunCheckTask
local TUN_SHELL_CMD = [[
  for iface in $(ifconfig 2>/dev/null | awk '/^utun[0-9]/{gsub(/:.*/,"",$1); print $1}'); do
    addr=$(ifconfig "$iface" 2>/dev/null | awk '/inet / && $2!="127.0.0.1"{print $2}')
    if [ -n "$addr" ]; then
      count=$(netstat -an -p tcp 2>/dev/null | grep -c "$addr")
      if [ "$count" -gt 0 ]; then echo "$iface $addr"; fi
    fi
  done
]]

local function updateTUNState(result)
  local detected = result and result ~= ""
  if detected then
    tunInfo = {}
    for iface, addr in result:gmatch("(%S+)%s+(%S+)") do
      tinsert(tunInfo, {interface = iface, address = addr})
    end
    if #tunInfo == 0 then tunInfo = nil end
  else
    tunInfo = nil
  end
  if detected ~= tunActive then
    tunActive = detected
    return true
  end
  return false
end

local function checkTUNState(callback)
  if tunCheckTask ~= nil then return end
  local task = hs.task.new("/bin/zsh", function(exitCode, stdout)
    tunCheckTask = nil
    if exitCode ~= 0 then return end
    local changed = updateTUNState(stdout)
    if callback then callback(changed) end
  end, { "-c", TUN_SHELL_CMD })
  if task == nil then return end
  tunCheckTask = task
  if not task:start() then tunCheckTask = nil end
end

-- Register proxy menubar with retry logic on network availability

registerProxyMenu = function(retry, enabledProxy, mode)
  if not getNetworkService() then
    setProxyIcon("")
    local menu = {{
      title = "No Network Access",
      disabled = true
    }}
    registerProxySettingsEntry(menu)
    proxy:setMenu(menu)
    if not retry then
      return false
    else
      hs.timer.waitUntil(getNetworkService,
        function() registerProxyMenu(false) end,
        3
      )
      return false
    end
  elseif getNetworkService() == 'iPhone USB' then
    proxyExitRequest = proxyExitRequest + 1
    proxyExitItem = nil
    setProxyIcon("")
    local menu = {{
      title = "Proxy Configured on iPhone",
      disabled = true
    }}
    proxy:setMenu(menu)
    return true
  elseif tunActive then
    registerProxyMenuImpl(enabledProxy, mode)
    forceInactiveProxyIcon()
    if tunInfo and #tunInfo > 0 then
      for i, info in ipairs(tunInfo) do
        tinsert(proxyMenu, 1 + i, {
          title = strfmt("TUN: %s (%s)", info.interface, info.address),
          disabled = true
        })
      end
    else
      tinsert(proxyMenu, 2, { title = "TUN Mode", disabled = true })
    end
    for _, item in ipairs(proxyMenu) do
      if item.fn and not (item.shortcut and item.shortcut:match("^[a-z]$")) then
        item.disabled = true
      end
    end
    proxy:setMenu(proxyMenu)
    return true
  else
    registerProxyMenuImpl(enabledProxy, mode)
    return true
  end
end

local proxySettings
if exists("config/misc.json") then
  proxySettings = hs.json.read("config/misc.json").proxy
end

-- Network watcher callback to re-register proxy menu on network changes
local lastIpv4State
local function registerProxyMenuWrapper(storeObj, changedKeys)
  NetworkMonitorKeys = tifilter(NetworkMonitorKeys, function(key)
    return key:match("Setup:/Network/Service/(.-)/Proxies") == nil
  end)
  local Ipv4State = NetworkWatcher
      :contents("State:/Network/Global/IPv4")
      ["State:/Network/Global/IPv4"]
  local enabledProxy, enabledMode
  if Ipv4State ~= nil then
    local curNetID = Ipv4State["PrimaryService"]
    tinsert(NetworkMonitorKeys, "Setup:/Network/Service/" .. curNetID .. "/Proxies")
    if lastIpv4State == nil and proxySettings ~= nil then
      for _, cfg in ipairs(proxySettings) do
        if cfg.condition == nil or executeCondition(cfg.condition) then
          for _, candidate in ipairs(cfg.candidates or {}) do
            local name, mode = candidate.name, candidate.mode
            if ProxyConfigs[name] ~= nil
                and (candidate.condition == nil
                    or executeCondition(candidate.condition)) then
              local config, loc
              if ProxyConfigs[name].condition ~= nil then
                if ProxyConfigs[name].locations then
                  local locations = ProxyConfigs[name].locations
                  local rc = executeCondition(ProxyConfigs[name].condition, true)
                  if rc >= 0 and #locations > rc then loc = locations[rc + 1] end
                  if loc then
                    config = ProxyConfigs[name][loc]
                  end
                elseif executeCondition(ProxyConfigs[name].condition) then
                  config = ProxyConfigs[name]
                end
              else
                config = ProxyConfigs[name]
              end
              if config ~= nil then
                enabledProxy = name
                if mode == "global" then
                  enabledMode = "Global"
                elseif mode == "pac" then
                  enabledMode = "PAC"
                end
                local curProxy, curMode = parseProxyInfo(NetworkWatcher:proxies())
                if curProxy == enabledProxy and curMode == enabledMode then
                  goto L_PROXY_SET
                end
                local actFunc = get(proxyActivateFuncs, name, mode)
                if actFunc ~= nil then
                  actFunc()
                elseif mode == "global" then
                  enable_proxy_global(name, loc)
                elseif mode == "pac" then
                  enable_proxy_PAC(name, loc)
                end
                goto L_PROXY_SET
              end
            end
          end
        end
      end
      disable_proxy()
    end
  end
  ::L_PROXY_SET::
  NetworkWatcher:monitorKeys(NetworkMonitorKeys)
  checkTUNState(function(changed)
    if changed then registerProxyMenu(true) end
  end)
  registerProxyMenu(true, enabledProxy, enabledMode)
  lastIpv4State = Ipv4State
end
registerProxyMenuWrapper()


local menubarHK = KeybindingConfigs.hotkeys.global or {}

local proxyHotkey = bindHotkeySpec(menubarHK["showProxyMenu"], "Show Proxy Menu",
function()
  local hammerspoon = find(hs.settings.bundleID)
  if hiddenByMenuBarManager(hammerspoon, proxy:autosaveName()) then
    clickRightMenuBarItem{hammerspoon, proxy:autosaveName()}
    return
  end
  popupRightMenuBarItem(proxy)
end)
if proxyHotkey then
  proxyHotkey.kind = HK.MENUBAR
  proxyHotkey.icon = hs.image.imageFromAppBundle("com.apple.systempreferences")
end

for appname, appid in pairs(proxyAppBundleIDs) do
  ExecOnSilentLaunch(appid, function()
    ExecOnSilentQuit(appid, function()
      if getNetworkService() ~= nil then
        local enabledProxy = parseProxyInfo(NetworkWatcher:proxies(), false)
        if enabledProxy == appname then
          disable_proxy()
        end
      end
    end)
  end)
end

local function SystemProxy_applicationInstalledCallback(files, flagTables)
  for i = 1, #files do
    if files[i]:match("V2RayX")
        or files[i]:match("V2rayU")
        or files[i]:match("v2rayN")
        or files[i]:match("Clash Verge")
        or files[i]:match("MonoProxyMac") then
      registerProxyMenu(true)
    end
  end
end

registerApplicationInstalledCallback(SystemProxy_applicationInstalledCallback)

local function SystemProxy_networkChangedCallback(storeObj, changedKeys)
  registerProxyMenuWrapper(storeObj, changedKeys)
end

registerNetworkChangedCallback(SystemProxy_networkChangedCallback)


-- utun interfaces do not create SCDynamicStore keys, so network callbacks
-- cannot detect TUN changes. Poll instead, but skip during startup.
ExecContinuously(function()
  if FLAGS["LOADING"] then return end
  checkTUNState(function(changed)
    if changed then registerProxyMenu(true) end
  end)
  refreshProxyIconTheme(false)
  refreshProxyExit(false)
end)

SystemProxyMenubar = proxy
SystemProxyThemeWatcher = proxyThemeWatcher
