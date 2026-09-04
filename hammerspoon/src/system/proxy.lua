-- System proxy helpers.
--
-- These helpers manage macOS system proxy settings using `networksetup`,
-- and provide a unified interface for different proxy clients and modes
-- (PAC / Global).

-- Get current primary network service name or service ID
local function getNetworkService(userDefinedName)
  if userDefinedName == nil then
    userDefinedName = true
  end
  local Ipv4State = NetworkWatcher
      :contents("State:/Network/Global/IPv4")["State:/Network/Global/IPv4"]
  if Ipv4State then
    local serviceID = Ipv4State["PrimaryService"]
    if userDefinedName then
      local service = NetworkWatcher
          :contents("Setup:/Network/Service/" .. serviceID)
          ["Setup:/Network/Service/" .. serviceID]
      return service and service.UserDefinedName
    else
      return serviceID
    end
  end
end

-- Disable all system proxy settings for the given network service
local function disable_proxy(networkservice)
  networkservice = networkservice or getNetworkService()
  hs.execute('networksetup -setproxyautodiscovery "' .. networkservice .. '" off')
  hs.execute('networksetup -setautoproxystate "' .. networkservice .. '" off')
  hs.execute('networksetup -setwebproxystate "' .. networkservice .. '" off')
  hs.execute('networksetup -setsecurewebproxystate "' .. networkservice .. '" off')
  hs.execute('networksetup -setsocksfirewallproxystate "' .. networkservice .. '" off')
end

local ProxyConfigs

-- Enable system proxy using PAC file for a proxy client
local function enable_proxy_PAC(client, networkservice, location)
  networkservice = networkservice or getNetworkService()
  hs.execute('networksetup -setproxyautodiscovery "' .. networkservice .. '" off')
  hs.execute('networksetup -setwebproxystate "' .. networkservice .. '" off')
  hs.execute('networksetup -setsecurewebproxystate "' .. networkservice .. '" off')
  hs.execute('networksetup -setsocksfirewallproxystate "' .. networkservice .. '" off')

  if client ~= nil then
    local PACFile
    if location == nil then
      PACFile = ProxyConfigs[client].PAC
    else
      PACFile = ProxyConfigs[client][location].PAC
    end
    hs.execute('networksetup -setautoproxyurl "' .. networkservice .. '" ' .. PACFile)
  end
  hs.execute('networksetup -setautoproxystate "' .. networkservice .. '" on')
end

-- Enable system proxy using global (HTTP / HTTPS / SOCKS) mode
local function enable_proxy_global(client, networkservice, location)
  networkservice = networkservice or getNetworkService()
  hs.execute('networksetup -setproxyautodiscovery "' .. networkservice .. '" off')
  hs.execute('networksetup -setautoproxystate "' .. networkservice .. '" off')

  if client ~= nil then
    local addrs
    if location == nil then
      addrs = ProxyConfigs[client].global
    else
      addrs = ProxyConfigs[client][location].global
    end
    hs.execute('networksetup -setwebproxy "' .. networkservice .. '" ' .. addrs[1] .. ' ' .. addrs[2])
    hs.execute('networksetup -setsecurewebproxy "' .. networkservice .. '" ' .. addrs[3] .. ' ' .. addrs[4])
    hs.execute('networksetup -setsocksfirewallproxy "' .. networkservice .. '" ' .. addrs[5] .. ' ' .. addrs[6])
  end

  hs.execute('networksetup -setwebproxystate "' .. networkservice .. '" on')
  hs.execute('networksetup -setsecurewebproxystate "' .. networkservice .. '" on')
  hs.execute('networksetup -setsocksfirewallproxystate "' .. networkservice .. '" on')
end

-- Optimized version that chains networksetup commands into a single shell
-- invocation to reduce process overhead. Used by MonoCloud v1.0+ where the
-- original enable_proxy_global does 8 separate hs.execute calls.
local function enable_proxy_global_fast(client, networkservice, location)
  networkservice = networkservice or getNetworkService()
  local cmds = {
    'networksetup -setproxyautodiscovery "' .. networkservice .. '" off',
    'networksetup -setautoproxystate "' .. networkservice .. '" off',
  }

  if client ~= nil then
    local addrs
    if location == nil then
      addrs = ProxyConfigs[client].global
    else
      addrs = ProxyConfigs[client][location].global
    end
    tinsert(cmds, 'networksetup -setwebproxy "' .. networkservice .. '" ' .. addrs[1] .. ' ' .. addrs[2])
    tinsert(cmds, 'networksetup -setsecurewebproxy "' .. networkservice .. '" ' .. addrs[3] .. ' ' .. addrs[4])
    tinsert(cmds, 'networksetup -setsocksfirewallproxy "' .. networkservice .. '" ' .. addrs[5] .. ' ' .. addrs[6])
  end

  tinsert(cmds, 'networksetup -setwebproxystate "' .. networkservice .. '" on')
  tinsert(cmds, 'networksetup -setsecurewebproxystate "' .. networkservice .. '" on')
  tinsert(cmds, 'networksetup -setsocksfirewallproxystate "' .. networkservice .. '" on')

  hs.execute(table.concat(cmds, ' && '))
end

-- Proxy client togglers.
--
-- These functions control third-party proxy applications by automating
-- their menu bar UI via Accessibility APIs.
--
-- They are responsible only for toggling the proxy client state
-- (connect / disconnect), not for configuring system proxy settings.

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

-- Ensure `v2rayN` is running before using its local proxy ports
local function ensureV2RayNRunning()
  local appid = proxyAppBundleIDs.v2rayN
  if find(appid) == nil then
    hs.application.launchOrFocusByBundleID(appid)
  end

  return true
end

-- Ensure `Clash Verge Rev` is running before using its local proxy ports
local function ensureClashVergeRevRunning()
  local appid = proxyAppBundleIDs["Clash Verge Rev"]
  if find(appid) == nil then
    hs.application.launchOrFocusByBundleID(appid)
  end

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
          enable_proxy_global("V2RayX")
        end
      end
    end,
    pac = function()
      if toggleV2RayX(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2RayX, "PAC Mode") then
          enable_proxy_PAC("V2RayX")
        end
      end
    end
  },

  V2rayU = {
    global = function()
      if toggleV2RayU(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2rayU, "Global Mode") then
          enable_proxy_global("V2rayU")
        end
      end
    end,
    pac = function()
      if toggleV2RayU(true) then
        if clickRightMenuBarItem(proxyAppBundleIDs.V2rayU, "Pac Mode") then
          enable_proxy_PAC("V2rayU")
        end
      end
    end
  },

  v2rayN = {
    global = function()
      if ensureV2RayNRunning() then
        enable_proxy_global("v2rayN")
      end
    end
  },

  ["Clash Verge Rev"] = {
    global = function()
      if ensureClashVergeRevRunning()
          and clickRightMenuBarItem(
            proxyAppBundleIDs["Clash Verge Rev"], { 3, 2 }) then
        enable_proxy_global("Clash Verge Rev")
      end
    end,
    pac = function()
      if ensureClashVergeRevRunning()
          and clickRightMenuBarItem(
            proxyAppBundleIDs["Clash Verge Rev"], { 3, 1 }) then
        enable_proxy_global("Clash Verge Rev")
      end
    end
  },

  MonoCloud = {
    global = function()
      if toggleMonoCloud(false) then
        if clickRightMenuBarItem(proxyAppBundleIDs.MonoCloud, { "Outbound Mode", 2 }) then
          local appVer = applicationVersion(proxyAppBundleIDs.MonoCloud)
          if appVer and appVer >= "1.0" then
            enable_proxy_global_fast("MonoCloud")
          else
            enable_proxy_global("MonoCloud")
          end
        end
      end
    end,
    pac = function()
      if toggleMonoCloud(false) then
        if clickRightMenuBarItem(proxyAppBundleIDs.MonoCloud, { "Outbound Mode", 3 }) then
          local appVer = applicationVersion(proxyAppBundleIDs.MonoCloud)
          if appVer and appVer >= "1.0" then
            enable_proxy_global_fast("MonoCloud")
          else
            enable_proxy_global("MonoCloud")
          end
        end
      end
    end
  }
}

local function executeProxyCondition(condition, returnCode)
  -- Phase 1: evaluate shell command condition (cached during loading)
  if condition.shell_command then
    local status, rc
    if FLAGS["LOADING"] then
      local cmd = tfind(LoadBuf.shellCommands, function(cmd)
        return cmd[1] == condition.shell_command
      end)
      if cmd then
        status, rc = cmd[2], cmd[3]
        if returnCode then return rc end
        if status then return true end
      end
    end
    if rc == nil then
      _, status, _, rc = hs.execute(condition.shell_command)
      if FLAGS["LOADING"] then
        tinsert(LoadBuf.shellCommands,
            { condition.shell_command, status, rc })
      end
    end
    if returnCode then return rc end
    if status then return true end
  end

  if returnCode then return -1 end

  -- Phase 2: evaluate Wi-Fi SSID based condition
  local interface = hs.network.primaryInterfaces()
  local interfaceName = getNetworkService(true)
  if condition.ssid then
    if interfaceName == 'Wi-Fi' then
      local ssid = getSSID(interface)
      if ssid and ssid ~= "" then
        local ssidPatterns = type(condition.ssid) == 'string'
            and { condition.ssid } or condition.ssid
        if tfind(ssidPatterns, function(id) return ssid:match(id) end) then
          return true
        end
      end
    end
  end

  -- Phase 3: evaluate Ethernet IP based condition
  if condition.etherNet then
    if interfaceName:match('^USB (.-) LAN$') then
      local ip = NetworkWatcher
        :contents("State:/Network/Interface/"..interface.."/IPv4")
        ["State:/Network/Interface/" .. interface .. "/IPv4"]
      if ip and ip.Addresses and ip.Addresses[1] then
        local addrPatterns = type(condition.etherNet) == 'string'
            and { condition.etherNet } or condition.etherNet
        if tfind(addrPatterns, function(addr)
            return ip.Addresses[1]:match(addr) end) then
          return true
        end
      end
    end
  end
  return false
end

-- menubar for proxy
local proxy = hs.menubar.new(true, "PROXY")
local proxyIconPath = hs.configdir .. "/static/menubar/"
local proxyIconNames = {
  V2RayX = "v2rayx",
  V2rayU = "v2rayu",
  v2rayN = "v2rayn",
  MonoCloud = "monocloud",
  ["Clash Verge Rev"] = "clash-verge-rev",
}
local proxyForIcon = ""
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
  local app = hs.application.frontmostApplication()
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

local function applyProxyIcon()
  local icon = "proxy.pdf"
  local template = true
  if proxyIconForcedInactive or proxyForIcon == "" then
    icon = "proxy-disabled.pdf"
    template = false
  else
    local appIconName = proxyIconNames[proxyForIcon]
    if appIconName then
      local suffix = proxyUsesLightForeground and "-white" or ""
      local appIcon = "proxy-" .. appIconName .. suffix .. ".pdf"
      if hs.fs.attributes(proxyIconPath .. appIcon) then
        icon = appIcon
        template = false
      end
    end
  end
  proxy:setIcon(proxyIconPath .. icon, template)
  local label = proxyForIcon
  if label == "" then label = "Off" end
  proxy:setTooltip("Proxy: " .. label)
end

local function refreshProxyIconTheme(force)
  if proxyIconForcedInactive or not proxyIconNames[proxyForIcon] then return end
  local now = hs.timer.secondsSinceEpoch()
  if not force and now < nextProxyThemeCheck then return end

  local detected = menuBarUsesLightForeground()
  nextProxyThemeCheck = now + (detected == nil and 1 or 5)
  if detected ~= nil and detected ~= proxyUsesLightForeground then
    proxyUsesLightForeground = detected
    applyProxyIcon()
  end
end

-- Set the proxy icon, adding a third-party app icon when available.
local function setProxyIcon(enabledProxy)
  proxyForIcon = enabledProxy or ""
  proxyIconForcedInactive = false
  if proxyIconNames[proxyForIcon] then
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

-- Parse proxy configuration definitions into normalized runtime structure
local function parseProxyConfigurations(configs)
  for name, config in pairs(configs) do
    ProxyConfigs[name] = {}
    if config.condition ~= nil then
      ProxyConfigs[name].condition = config.condition
      if config.locations ~= nil then
        ProxyConfigs[name].locations = config.locations
        for _, loc in ipairs(config.locations) do
          ProxyConfigs[name][loc] = {}
          local spec = config[loc]
          ProxyConfigs[name][loc]["PAC"] = spec.pac
          if spec.global ~= nil then
            local httpIp, httpPort = spec.global.http:match("(.+):(%d+)")
            local httpsIp, httpsPort = spec.global.https:match("(.+):(%d+)")
            local socksIp, socksPort = spec.global.socks5:match("(.+):(%d+)")
            ProxyConfigs[name][loc]["global"] = {
              httpIp, httpPort, httpsIp, httpsPort, socksIp, socksPort
            }
          end
        end
      end
    end
    if config.locations == nil then
      local spec = config
      ProxyConfigs[name]["PAC"] = spec.pac
      if spec.global ~= nil then
        local httpIp, httpPort = spec.global.http:match("(.+):(%d+)")
        local httpsIp, httpsPort = spec.global.https:match("(.+):(%d+)")
        local socksIp, socksPort = spec.global.socks5:match("(.+):(%d+)")
        ProxyConfigs[name]["global"] = {
          httpIp, httpPort, httpsIp, httpsPort, socksIp, socksPort
        }
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
local function updateProxyWrapper(wrapped, appname)
  local fn = function(mod, item)
    wrapped.fn(mod, item)
    setProxyIcon(appname or "")
    local newProxyMenu = {}
    for _, _item in ipairs(proxyMenu) do
      _item.checked = false
      item.checked = true
      if not _item.title:find("Proxy:")
          and not _item.title:find("PAC File:")then
        tinsert(newProxyMenu, _item)
      end
      if _item.title == appname
          or (_item.title.getString and _item.title:getString() == appname) then
        local info = NetworkWatcher:proxies()
        if item.title:match("PAC") and info.ProxyAutoConfigURLString then
          tinsert(newProxyMenu, {
            title = "PAC File: " .. info.ProxyAutoConfigURLString,
            disabled = true
          })
        else
          tinsert(newProxyMenu, {
            title = "HTTP Proxy: " .. info.HTTPProxy .. ":" .. info.HTTPPort,
            disabled = true
          })
          tinsert(newProxyMenu, {
            title = "SOCKS5 Proxy: " .. info.SOCKSProxy .. ":" .. info.SOCKSPort,
            disabled = true,
          })
        end
      end
    end
    proxyMenu = newProxyMenu
    proxy:setMenu(proxyMenu)
  end

  return {
    title = wrapped.title,
    fn = fn,
    shortcut = wrapped.shortcut,
    checked = wrapped.checked,
  }
end

-- Register proxy menu entries for a specific proxy configuration
local function registerProxyMenuEntry(name, enabled, mode, proxyMenuIdx)
  local config, loc
  if ProxyConfigs[name].locations then
    local locations = ProxyConfigs[name].locations
    local rc = executeProxyCondition(ProxyConfigs[name].condition, true)
    if rc >= 0 and #locations > rc then loc = locations[rc + 1]
    else return proxyMenuIdx end
    config = ProxyConfigs[name][loc]
  else
    if ProxyConfigs[name].condition
        and not executeProxyCondition(ProxyConfigs[name].condition) then
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
          title = "PAC File: " .. PACFile,
          disabled = true
        })
      else
        local addr = config.global
        tinsert(proxyMenu, {
          title = "HTTP Proxy: " .. addr[1] .. ":" .. addr[2],
          disabled = true
        })
        tinsert(proxyMenu, {
          title = "SOCKS5 Proxy: " .. addr[5] .. ":" .. addr[6],
          disabled = true
        })
      end
    end
    if config.global ~= nil then
      tinsert(proxyMenu, updateProxyWrapper({
        title = "    Global Mode",
        fn = function() enable_proxy_global(name, nil, loc) end,
        shortcut = tostring(proxyMenuIdx),
        checked = enabled and mode == "Global"
      }, name))
      proxyMenuIdx = proxyMenuIdx + 1
    end
    if config.PAC ~= nil then
      tinsert(proxyMenu, updateProxyWrapper({
        title = "    PAC Mode",
        fn = function() enable_proxy_PAC(name, nil, loc) end,
        shortcut = tostring(proxyMenuIdx),
        checked = enabled and mode == "PAC"
      }, name))
      proxyMenuIdx = proxyMenuIdx + 1
    end
  end
  return proxyMenuIdx
end

-- Parse current system proxy state and detect enabled proxy and mode
local function parseProxyInfo(info, require_mode)
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
        if config.global ~= nil
          and config.global[1] == info.HTTPProxy
          and config.global[2] == tostring(info.HTTPPort)
          and config.global[3] == info.HTTPSProxy
          and config.global[4] == tostring(info.HTTPSPort) then
          enabledProxy = appname
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
            local outboundModeMenu = getc(toappui(find(appid)), AX.MenuBar, -1,
                AX.MenuBarItem, 1, AX.Menu, 1, AX.MenuItem, 3, AX.Menu, 1)
            if outboundModeMenu ~= nil then
              if getc(outboundModeMenu, AX.MenuItem, 1).AXMenuItemMarkChar == "✓" then
                mode = "PAC"
              elseif getc(outboundModeMenu, AX.MenuItem, 2).AXMenuItemMarkChar == "✓" then
                mode = "Global"
              end
            end
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

local function registerProxySettingsEntry(menu)
  tinsert(menu, { title = "-" })
  tinsert(menu, {
    title = "Proxy Settings",
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
            hs.application.launchOrFocusByBundleID(appid)
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
            title = "PAC File: " .. PACFile,
            disabled = true,
          })
        elseif ProxyConfigs[candidate.appname]["global"] ~= nil then
          local addr = ProxyConfigs[candidate.appname]["global"]
          tinsert(proxyMenu, {
            title = "HTTP Proxy: " .. addr[1] .. ":" .. addr[2],
            disabled = true,
          })
          tinsert(proxyMenu, {
            title = "SOCKS5 Proxy: " .. addr[5] .. ":" .. addr[6],
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

local function registerProxyMenu(retry, enabledProxy, mode)
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
        if cfg.condition == nil or executeProxyCondition(cfg.condition) then
          for _, candidate in ipairs(cfg.candidates or {}) do
            local name, mode = candidate.name, candidate.mode
            if ProxyConfigs[name] ~= nil then
              local config, loc
              if ProxyConfigs[name].condition ~= nil then
                if ProxyConfigs[name].locations then
                  local locations = ProxyConfigs[name].locations
                  local rc = executeProxyCondition(ProxyConfigs[name].condition, true)
                  if rc >= 0 and #locations > rc then loc = locations[rc + 1] end
                  if loc then
                    config = ProxyConfigs[name][loc]
                  end
                elseif executeProxyCondition(ProxyConfigs[name].condition) then
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
                  enable_proxy_global(name, nil, loc)
                elseif mode == "pac" then
                  enable_proxy_PAC(name, nil, loc)
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
  local frame = proxy:_frame()
  if not frame then return end
  local screenFrame = hs.screen.mainScreen():frame()
  proxy:popupMenu({
    x = frame.x,
    y = screenFrame.y + screenFrame.h - frame.y
  })
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

-- toggle system proxy
local function toggleSystemProxy(networkservice)
  local info = NetworkWatcher:proxies()

  if info.ProxyAutoDiscoveryEnable == 1
    or info.HTTPEnable == 1
    or info.HTTPSEnable == 1
    or info.SOCKSEnable == 1 then
    disable_proxy(networkservice)
    hs.alert("System proxy disabled")
  elseif info.ProxyAutoConfigEnable == 1 then
    enable_proxy_global(nil, networkservice)
    hs.alert("System proxy enabled (global mode)")
  else
    enable_proxy_PAC(nil, networkservice)
    hs.alert("System proxy enabled (auto mode)")
    end
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
end)

SystemProxyMenubar = proxy
SystemProxyThemeWatcher = proxyThemeWatcher
