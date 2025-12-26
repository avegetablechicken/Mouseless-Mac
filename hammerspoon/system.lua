-- System-level features and integrations.
--
-- This module provides:
-- - System menubar utilities (caffeine, proxy, Control Center)
-- - Network and proxy management helpers
-- - Control Center automation and hotkeys
-- - System-related callbacks (battery / network / monitor)
--
-- Most logic here is UI-automation heavy and relies on Accessibility APIs.

require "utils"

-- Caffeine menubar.
--
-- Provides a simple menubar toggle to control display sleep state
-- via hs.caffeinate.
local caffeine = hs.menubar.new(true, "CAFFEINE")

-- Update caffeine menubar title according to display sleep state
local function setCaffeineDisplay(state)
  if state then
    caffeine:setTitle("AWAKE")
  else
    caffeine:setTitle("SLEEPY")
  end
end

-- Toggle display idle sleep and update caffeine menubar
local function caffeineClicked()
  setCaffeineDisplay(hs.caffeinate.toggle("displayIdle"))
end

if caffeine then
  caffeine:setClickCallback(caffeineClicked)
  setCaffeineDisplay(hs.caffeinate.get("displayIdle"))
end

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
  MonoCloud = "com.MonoCloud.MonoProxyMac",
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

-- Toggle connect/disconnect VPN using `MonoCloud`
local function toggleMonoCloud(enable, alert)
  local appid = proxyAppBundleIDs.MonoCloud
  if find(appid) == nil then
    hs.application.launchOrFocusByBundleID(appid)
  end

  local appUI = toappui(find(appid))
  local menuItem = getc(appUI, AX.MenuBar, -1, AX.MenuBarItem, 1,
      AX.Menu, 1, AX.MenuItem, "Set As System Proxy")
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

  MonoCloud = {
    global = function()
      if toggleMonoCloud(false) then
        if clickRightMenuBarItem(proxyAppBundleIDs.MonoCloud, { "Outbound Mode", 2 }) then
          enable_proxy_global("MonoCloud")
        end
      end
    end,
    pac = function()
      if toggleMonoCloud(false) then
        if clickRightMenuBarItem(proxyAppBundleIDs.MonoCloud, { "Outbound Mode", 3 }) then
          enable_proxy_global("MonoCloud")
        end
      end
    end
  }
}

local shellCommandsExecutedOnLoading = {}
local function executeProxyCondition(condition, returnCode)
  -- Phase 1: evaluate shell command condition (cached during loading)
  if condition.shell_command then
    local status, rc
    if FLAGS["LOADING"] then
      local cmd = tfind(shellCommandsExecutedOnLoading, function(cmd)
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
        tinsert(shellCommandsExecutedOnLoading,
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
proxy:setTitle("PROXY")
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
    local newProxyMenu = {}
    for _, _item in ipairs(proxyMenu) do
      _item.checked = false
      item.checked = true
      if not _item.title:find("Proxy:")
          and not _item.title:find("PAC File:")then
        tinsert(newProxyMenu, _item)
      end
      if _item.title == appname then
        local info = NetworkWatcher:proxies()
        if item.title:match("PAC") then
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
    tinsert(proxyMenu, { title = name, disabled = true })
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
        if enabledProxy ~= "MonoCloud" then
          mode = "Global"
        elseif require_mode then
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
        title = candidate.appname,
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

-- Register proxy menubar with retry logic on network availability
local function registerProxyMenu(retry, enabledProxy, mode)
  if not getNetworkService() then
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
    local menu = {{
      title = "Proxy Configured on iPhone",
      disabled = true
    }}
    proxy:setMenu(menu)
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
  registerProxyMenu(true, enabledProxy, enabledMode)
  lastIpv4State = Ipv4State
end
registerProxyMenuWrapper()


local menubarHK = KeybindingConfigs.hotkeys.global or {}

local proxyHotkey = bindHotkeySpec(menubarHK["showProxyMenu"], "Show Proxy Menu",
    bind(clickRightMenuBarItem, {hs.settings.bundleID, proxy:autosaveName()}))
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


-- Control Center automation.
--
-- This section provides deep automation for macOS Control Center,
-- including:
-- - Opening specific panels
-- - Registering panel-specific hotkeys
-- - Handling UI differences across macOS versions
--
-- Implementation relies heavily on Accessibility APIs and
-- version-specific UI heuristics.

-- assume `Control Center` window is always frontmost

local CC = {
  AXShortcuts       = "Accessibility Shortcuts",
  AirDrop           = "AirDrop",
  Battery           = "Battery",
  Bluetooth         = "Bluetooth",
  Display           = "Display",
  Focus             = "Focus",
  Hearing           = "Hearing",
  KbBrightness      = "Keyboard Brightness",
  MusicRecognition  = "Music Recognition",
  NowPlaying        = "Now Playing",
  ScreenMirror      = "Screen Mirroring",
  Sound             = "Sound",
  StageManager      = "Stage Manager",
  User              = "User",
  WiFi              = "Wi‑Fi",
}
if OS_VERSION >= OS.Tahoe then
  CC.MusicRecognition = "Recognize Music"
end

-- Control Center hotkey bindings.
--
-- Hotkeys registered here are contextual and only active
-- while Control Center UI is present.

local controlCenterLocalized

-- Create a Control Center specific hotkey
local function newControlCenter(...)
  local hotkey = newHotkey(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.MENUBAR
  hotkey.subkind = HK.MENUBAR_.CONTROL_CENTER
  return hotkey
end

-- Bind a Control Center hotkey using hotkey spec
local function bindControlCenter(...)
  local hotkey = bindHotkeySpec(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.MENUBAR
  hotkey.subkind = HK.MENUBAR_.CONTROL_CENTER
  return hotkey
end

-- Bind hotkey to open a specific Control Center panel
local function bindControlCenterPanel(spec, panel, func)
  local locAppName = displayName("com.apple.controlcenter")
  local locPanel = controlCenterLocalized(panel)
  local message = locAppName..' > '..locPanel
  return bindControlCenter(spec, message, func)
end

-- Register URL event handler for Control Center panel switching
local controlCenterPanelFuncs = {}
local function bindURLEventForControlCenter()
  hs.urlevent.bind("controlcenter", function(eventName, params)
    if params["panel"] == "Music Recognition" or params["panel"] == "Recognize Music" then
      params["panel"] = CC.MusicRecognition
    end
    local fn = controlCenterPanelFuncs[params["panel"]]
    if fn then fn() end
  end)
end

-- Register URL-based Control Center panel trigger
local function bindControlCenterPanelURL(panel, func)
  controlCenterPanelFuncs[panel] = func

  local locAppName = displayName("com.apple.controlcenter")
  local locPanel = controlCenterLocalized(panel)
  registerURLHotkeyMessage('controlcenter', 'panel', panel,
                           locAppName..' > '..locPanel)
  if OS_VERSION < OS.Tahoe and panel == CC.MusicRecognition then
    registerURLHotkeyMessage('controlcenter', 'panel', "Recognize Music",
                            locAppName..' > '..locPanel)
  end
end

controlCenterLocalized = function(panel, key)
  if key == nil then
    key = panel
  end

  local localeFile
  if panel == CC.User then
    localeFile = "Users"
  elseif panel == CC.MusicRecognition then
    localeFile = "Music Recognition"
  else
    localeFile = panel
  end
  localeFile = localeFile:gsub(" ", ""):gsub("‑", "")
  local params
  if panel == CC.StageManager then
    params = {
      localeFile = localeFile,
      locale = applicationLocale('com.apple.WindowManager')
    }
  else
    params = localeFile
  end

  local result = localizedString(key, "com.apple.controlcenter", params)
  if not result and panel == CC.Focus then
    result = localizedString(key, "com.apple.controlcenter",
        { framework = "DoNotDisturb.framework" }, true)
    if not result then
      result = localizedString(key, "com.apple.controlcenter",
          { framework = "DoNotDisturbKit.framework" }, true)
    end
  end
  return result
end

local function testAlready(panel, pane, role)
  if panel == CC.StageManager then return false end
  local locPanel = controlCenterLocalized(panel)

  if role == nil then
    if tcontain({ CC.WiFi, CC.Focus, CC.Bluetooth, CC.AirDrop,
                  CC.KbBrightness, CC.ScreenMirror,
                  CC.AXShortcuts, CC.Battery,
                  CC.Sound, CC.Hearing }, panel) then
      local elem = getc(pane, AX.StaticText, 1)
      return elem and elem.AXValue == locPanel
    elseif panel == CC.Display then
      local str = controlCenterLocalized(panel, "Display Settings…")
      local buttons = getc(pane, AX.Button)
      for i = #buttons, 1, -1 do
        local title = OS_VERSION < OS.Ventura and buttons[i].AXTitle
            or buttons[i].AXAttributedDescription:getString()
        if title == str then
          return true
        end
      end
      return false
    elseif panel == CC.MusicRecognition then
      local elem = getc(pane, AX.Group, 1, AX.Group, 1, AX.CheckBox, 1)
      local title
      if elem and elem.AXTitle then
        title = elem.AXTitle
      elseif elem and elem.AXAttributedDescription then
        title = elem.AXAttributedDescription:getString()
      end
      return elem and title:match('^'..locPanel)
    elseif panel == CC.NowPlaying then
      if OS_VERSION < OS.Ventura then
        local mayLocalize = bind(controlCenterLocalized, panel)
        return getc(pane, AX.Button, mayLocalize("rewind")) ~= nil
            or getc(pane, AX.Button, mayLocalize("previous")) ~= nil
            or (#getc(pane, AX.Button, mayLocalize("play"))
              + #getc(pane, AX.Button, mayLocalize("pause"))) > 1
      else
        if OS_VERSION >= OS.Tahoe then pane = getc(pane, AX.Group, 1) end
        return pane and #getc(pane, AX.Button) > 1
            and (#getc(pane, AX.Image) > 0 or pane[1].AXRole == AX.Unknown)
      end
    elseif panel == CC.User then
      local elem = pane[#pane]
      local title
      if elem and elem.AXTitle then
        title = elem.AXTitle
      elseif elem and elem.AXAttributedDescription then
        title = elem.AXAttributedDescription:getString()
      end
      return title == controlCenterLocalized(panel, "Users & Groups Settings…")
    end
  end

  return tfind(getc(pane, role) or {}, function(elem)
    return elem.AXTitle == locPanel
        or elem.AXAttributedDescription:getString():match('^'..locPanel)
  end) ~= nil
end

local function getBluetoothConnectedDevices()
  local output, status = hs.execute("system_profiler SPBluetoothDataType")
  if not status then
      hs.alert.show("Failed to run system_profiler for Bluetooth")
      return {}
  end

  local devices = {}
  local inConnected = false
  local currentName = nil

  for line in output:gmatch("[^\r\n]+") do
    if line:match("^%s*Connected:") then
      inConnected = true
    elseif line:match("^%s*Not Connected:") then
      inConnected = false
    end

    if inConnected then
      local nameMatch = line:match("^%s+(.+):%s*$")
      if nameMatch and not line:match("^%s+Address:") then
        currentName = nameMatch
      end

      local addrMatch = line:match("^%s+Address:%s*([0-9A-F:]+)%s*$")
      if addrMatch and currentName then
        devices[addrMatch] = currentName
        currentName = nil
      end
    end
  end

  return devices
end

-- Open or switch to a specific Control Center sub-panel
local function popupControlCenterSubPanel(panel, allowReentry)
  -- Phase 1: detect current Control Center window and UI container
  -- Phase 2: locate panel entry point based on OS version
  -- Phase 3: perform UI action to enter panel
  -- Phase 4: register panel-specific hotkeys

  local app = find("com.apple.controlcenter")
  local appUI = toappui(app)
  local pane

  local function enterPanel()  -- assume in BentoBox-0 since macOS Tahoe
    local role, locPanel
    if tcontain({ CC.WiFi, CC.Focus, CC.Bluetooth, CC.AirDrop,
                  CC.MusicRecognition }, panel) then
      role = AX.CheckBox
    elseif panel == CC.ScreenMirror then
      if OS_VERSION >= OS.Ventura and OS_VERSION <= OS.Sequoia then
        role = AX.Button
      else
        role = AX.CheckBox
      end
    elseif panel == CC.StageManager then
      if OS_VERSION >= OS.Tahoe then
        role = AX.CheckBox
      else
        role = AX.Button
      end
    elseif panel == CC.Display then
      if OS_VERSION >= OS.Ventura and OS_VERSION <= OS.Sequoia then
        role = AX.Group
      elseif OS_VERSION > OS.Tahoe or
          (OS_VERSION == OS.Tahoe and hs.host.operatingSystemVersion().minor >= 1) then
        role = AX.Button
      else
        role = AX.StaticText
      end
    elseif panel == CC.KbBrightness then
      if OS_VERSION <= OS.Sequoia then
        role = AX.Button
      elseif OS_VERSION > OS.Tahoe or
          (OS_VERSION == OS.Tahoe and hs.host.operatingSystemVersion().minor >= 1) then
        role = AX.Button
        locPanel = controlCenterLocalized(panel, "Keyboard")
      else
        role = AX.StaticText
      end
    elseif panel == CC.Sound then
      if OS_VERSION > OS.Tahoe or
        (OS_VERSION == OS.Tahoe and hs.host.operatingSystemVersion().minor >= 1) then
        role = AX.Button
      else
        role = AX.StaticText
      end
    elseif tcontain({ CC.Battery, CC.Hearing }, panel) then
      role = AX.Button
    elseif tcontain({ CC.AXShortcuts, CC.User }, panel) then
      if OS_VERSION > OS.Tahoe or
          (OS_VERSION == OS.Tahoe and hs.host.operatingSystemVersion().minor >= 1) then
        role = AX.CheckBox
        if panel == CC.AXShortcuts then
          locPanel = controlCenterLocalized(panel, "Accessibility")
        end
      else
        role = AX.Button
      end
    elseif panel == CC.NowPlaying then
      local ele
      local totalDelay = 0
      repeat
        if OS_VERSION >= OS.Tahoe then
          ele = tfind(getc(pane, AX.Group), function(g)
            local bts = getc(g, AX.Button)
            return #bts == 3 and bts[1].AXIdentifier:find("backward")
              and bts[3].AXIdentifier:find("forward")
              and (bts[2].AXIdentifier:find("play") or bts[2].AXIdentifier:find("pause"))
          end)
        else
          ele = getc(pane, AX.Image, -1)
        end
        if ele == nil then
          hs.timer.usleep(0.05 * 1000000)
          totalDelay = totalDelay + 0.05
        end
      until ele or totalDelay > 3 or not pane:isValid()
      if ele then
        local actions = ele:actionNames()
        ele:performAction(actions[#actions])
        return true
      end
      return false
    end

    local ele
    local totalDelay = 0
    locPanel = locPanel or controlCenterLocalized(panel)
    repeat
      ele = tfind(getc(pane, role), function(e)
        if panel == CC.Focus then
          return e.AXIdentifier == "controlcenter-focus-modes"
        end
        if role == AX.Group then
          local elem = getc(e, AX.StaticText, 1)
          return elem and elem.AXValue == locPanel
        elseif role == AX.StaticText then
          return e.AXValue == locPanel
        else
          return e.AXTitle == locPanel or (e.AXAttributedDescription
              and e.AXAttributedDescription:getString():match('^'..locPanel))
        end
      end)
      if ele == nil then
        hs.timer.usleep(0.05 * 1000000)
        totalDelay = totalDelay + 0.05
      end
    until ele or totalDelay > 0.9 or not pane:isValid()
    if ele then
      local actions = ele:actionNames()
      local ret = ele:performAction(actions[#actions])
      if ret and panel == CC.StageManager then
        local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
        local menuBarItem = tfind(menuBarItems,
          function(item)
            return item.AXIdentifier == "com.apple.menuextra.controlcenter"
          end)
        menuBarItem:performAction(AX.Press)
      end
      return true
    end
    return false
  end

  if app:mainWindow() then
    pane = getc(appUI, AX.Window, 1)
    if OS_VERSION >= OS.Ventura then
      pane = getc(pane, AX.Group, 1)
    end
    if panel == CC.Hearing then
      if #pane == 1 and pane[1].AXRole == AX.ScrollArea then
        pane = pane[1]
      end
    end
    if testAlready(CC.WiFi, pane, AX.CheckBox)
        and testAlready(CC.Bluetooth, pane, AX.CheckBox) then
      if enterPanel() then
        registerControlCenterHotKeys(panel)
      end
      return
    elseif testAlready(panel, pane) and not allowReentry then
      return
    end
  end

  local locPanel = controlCenterLocalized(panel)
  local index
  local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
  for i, elem in ipairs(menuBarItems) do
    if elem.AXDescription and elem.AXDescription:find(locPanel) then
      index = i break
    end
  end
  if index then
    clickRightMenuBarItem({'com.apple.controlcenter', index})
    registerControlCenterHotKeys(panel, true)
  else
    local menuBarItem = tfind(menuBarItems,
      function(item)
        return item.AXIdentifier == "com.apple.menuextra.controlcenter"
      end)
    menuBarItem:performAction(AX.Press)
    pane = getc(appUI, AX.Window, 1)
    local winTotalDelay = 0
    if pane == nil then
      repeat
        hs.timer.usleep(0.05 * 1000000)
        winTotalDelay = winTotalDelay + 0.05
        if winTotalDelay > 1 then return end
        pane = getc(appUI, AX.Window, 1)
      until pane ~= nil
    end
    if OS_VERSION >= OS.Ventura then
      pane = getc(pane, AX.Group, 1)
    end
    if enterPanel() then
      registerControlCenterHotKeys(panel)
    end
  end
end

local controlCenterPanels = {
  CC.AirDrop, CC.Bluetooth, CC.Display, CC.Focus, CC.KbBrightness,
  CC.NowPlaying, CC.ScreenMirror, CC.Sound, CC.WiFi
}
local osMinor = hs.host.operatingSystemVersion().minor
if OS_VERSION >= OS.Ventura then
  tinsert(controlCenterPanels, CC.StageManager)
end
if OS_VERSION >= OS.Sonoma then
  tconcat(controlCenterPanels, { CC.AXShortcuts, CC.Battery, CC.User })
  if OS_VERSION > OS.Sonoma or osMinor >= 2 then
    tinsert(controlCenterPanels, CC.MusicRecognition)
  end
  if OS_VERSION > OS.Sonoma or osMinor >= 6 then
    tinsert(controlCenterPanels, CC.Hearing)
  end
end
if get(KeybindingConfigs.hotkeys, "com.apple.controlcenter") then
  for _, panel in ipairs(controlCenterPanels) do
    local hkID = panel:gsub(' ', '')
    hkID = hkID:sub(1, 1):lower() .. hkID:sub(2)
    local pos = panel:find('‑')
    if pos then
      hkID = hkID:sub(1, pos-1) .. hkID:sub(pos+3,pos+3):lower() .. hkID:sub(pos+4)
    end
    local spec = get(KeybindingConfigs.hotkeys, "com.apple.controlcenter", hkID)
    if spec == nil and panel == CC.MusicRecognition then
      spec = get(KeybindingConfigs.hotkeys, "com.apple.controlcenter", "musicRecognition")
    end
    if spec then
      bindControlCenterPanel(spec, panel, bind(popupControlCenterSubPanel, panel))
    end
  end
end

local controlCenterHotKeys = nil

local function checkAndRegisterControlCenterHotKeys(hotkey)
  if controlCenterHotKeys == nil then
    hotkey:delete()
    return false
  else
    hotkey:enable()
    tinsert(controlCenterHotKeys, hotkey)
    return true
  end
end

local hotkeyMainBack
local hotkeyShow, hotkeyHide
local backgroundSoundsHotkeys
local selectNetworkHotkeys, selectNetworkWatcher
local focusOptionHotkeys, focusOptionWatcher
---@diagnostic disable-next-line: lowercase-global
function registerControlCenterHotKeys(panel, inMenuBar)
  local appUI = toappui(find('com.apple.controlcenter'))

  -- Locate Control Center window and root pane.
  -- This may block briefly because Control Center UI is created lazily.
  local pane = getc(appUI, AX.Window, 1)
  local winTotalDelay = 0
  if pane == nil then
    repeat
      hs.timer.usleep(0.05 * 1000000)
      winTotalDelay = winTotalDelay + 0.05
      if winTotalDelay > 1 then return end
      pane = getc(appUI, AX.Window, 1)
    until pane ~= nil
  end
  -- Normalize root pane structure across macOS versions.
  -- Starting from Ventura, most Control Center content is nested under AX.Group.
  if OS_VERSION >= OS.Ventura then
    pane = getc(pane, AX.Group, 1)
    if panel == CC.Hearing then
      while #pane == 0 do
        hs.timer.usleep(0.05 * 1000000)
      end
      if #pane == 1 and pane[1].AXRole == AX.ScrollArea then
        pane = pane[1]
      end
    end
  end

  -- Helper to localize Control Center UI labels for the current panel.
  local function mayLocalize(value)
    return controlCenterLocalized(panel, value)
  end

  -- Clear previously registered Control Center hotkeys.
  -- Hotkeys are panel-scoped and must be recreated on each panel entry.
  if controlCenterHotKeys ~= nil then
    for _, hotkey in ipairs(controlCenterHotKeys) do
      hotkey:delete()
    end
  end
  controlCenterHotKeys = {}
  -- Reset transient hotkeys used by expandable UI elements
  -- (e.g. disclosure triangles, background sounds, network lists).
  if hotkeyShow ~= nil then
    hotkeyShow:delete()
    hotkeyShow = nil
  end
  if hotkeyHide ~= nil then
    hotkeyHide:delete()
    hotkeyHide = nil
  end
  if backgroundSoundsHotkeys ~= nil then
    for _, hotkey in ipairs(backgroundSoundsHotkeys) do
      hotkey:delete()
    end
    backgroundSoundsHotkeys = nil
  end

  -- Register hotkey to return to the main Control Center panel.
  -- This is only available when entering from a sub-panel.
  if not inMenuBar then
    local msg = "Back"
    local appLocale = applicationValidLocale('com.apple.controlcenter')
    if appLocale ~= nil then
      local result = localizedString(msg, 'com.apple.AppStore',
                                     { locale = appLocale })
      if result then
        msg = result
      end
    end
    hotkeyMainBack = newControlCenter("⌘", "[", msg,
    function()
      assert(hotkeyMainBack) hotkeyMainBack:disable()
      for _, hotkey in ipairs(controlCenterHotKeys) do
        hotkey:delete()
      end
      controlCenterHotKeys = {}
      if hotkeyShow ~= nil then
        hotkeyShow:delete()
        hotkeyShow = nil
      end
      if hotkeyHide ~= nil then
        hotkeyHide:delete()
        hotkeyHide = nil
      end
      if backgroundSoundsHotkeys ~= nil then
        for _, hotkey in ipairs(backgroundSoundsHotkeys) do
          hotkey:delete()
        end
        backgroundSoundsHotkeys = nil
      end

      local menuBarItem = tfind(getc(appUI, AX.MenuBar, -1, AX.MenuBarItem),
        function(item)
          return item.AXIdentifier == "com.apple.menuextra.controlcenter"
        end)
      menuBarItem:performAction(AX.Press)
    end)
    if not checkAndRegisterControlCenterHotKeys(hotkeyMainBack) then
      return
    end
  end

  -- Register shortcut to jump from Control Center panel
  -- to its corresponding System Settings page (if available).
  if tcontain({ CC.WiFi, CC.Bluetooth, CC.Focus, CC.KbBrightness,
                CC.ScreenMirror, CC.Display, CC.Sound,
                CC.AXShortcuts, CC.Battery,
                CC.Hearing, CC.User, }, panel) then
    local button, title
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      local buttons = getc(pane, AX.Button)
      for i = #buttons, 1, -1 do
        title = OS_VERSION < OS.Ventura and buttons[i].AXTitle
            or buttons[i].AXAttributedDescription:getString()
        if title:find("…") then
          button = buttons[i]
          break
        end
      end
    until button or totalDelay > 0.9 or not pane:isValid()
    if button then
      local hotkey = newControlCenter("⌘", ",", title,
          function() button:performAction(AX.Press) end)
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
  end

  -- Panels with a top-level enable/disable switch.
  -- Bind Space to toggle the main checkbox.
  if tcontain({CC.WiFi, CC.Bluetooth, CC.AirDrop}, panel) then
    local checkbox
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      local cbs = getc(appUI, AX.Window, 1, AX.CheckBox) or {}
      checkbox = tfind(cbs, function(cb)
        return cb.AXIdentifier ~= nil and cb.AXIdentifier:find("%-header") ~= nil
      end)
      if checkbox == nil then
        cbs = getc(appUI, AX.Window, 1, AX.Group, 1, AX.CheckBox) or {}
        checkbox = tfind(cbs, function(cb)
          return cb.AXIdentifier ~= nil and cb.AXIdentifier:find("%-header") ~= nil
        end)
      end
    until checkbox or totalDelay > 1
    if checkbox then
      local hotkey = newControlCenter("", "Space",
        "Toggle " .. controlCenterLocalized(panel),
        function() checkbox:performAction(AX.Press) end
      )
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
  end

  -- Panels containing a primary slider.
  -- Provide fine-grained and jump-to-min/max shortcuts.
  if tcontain({CC.Display, CC.Sound, CC.KbBrightness}, panel) then
    local name = panel == CC.Sound and "Volume" or "Brightness"
    local actions = {{ '=', 'Up'}, {'-', 'Down'}}
    if OS_VERSION < OS.Tahoe or panel == CC.Display or panel == CC.Sound then
      tconcat(actions, {{'[', 'Min'}, {']', 'Max'}})
    end
    local slider
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      if panel == CC.Display then
        local role = OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group
        slider = tfind(getc(pane, role, 1, AX.Slider) or {},
            function(ele) return ele.AXEnabled end)
      else
        slider = tfind(getc(pane, AX.Slider) or {},
            function(ele) return ele.AXEnabled end)
      end
    until slider or totalDelay > 0.9 or not pane:isValid()
    if slider then
      for _, spec in ipairs(actions) do
        local key = spec[1]
        local msg = name .. ' ' .. spec[2]
        local hotkey = newControlCenter("", key, msg,
          function()
            if key == '=' then
              slider:performAction(AX.Increment)
            elseif key == '-' then
              slider:performAction(AX.Decrement)
            elseif key == '[' then
              if OS_VERSION >= OS.Tahoe then
                if panel == CC.Sound then
                  local device = hs.audiodevice.defaultOutputDevice()
                  device:setVolume(0)
                elseif panel == CC.Display then
                  hs.brightness.set(0)
                end
              else
                slider.AXValue = 0
              end
            else
              if OS_VERSION >= OS.Tahoe then
                if panel == CC.Sound then
                  local device = hs.audiodevice.defaultOutputDevice()
                  device:setVolume(100)
                elseif panel == CC.Display then
                  hs.brightness.set(100)
                end
              else
                slider.AXValue = 100
              end
            end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end
  end

  -- Panels displaying a list of selectable devices.
  -- Dynamically assign numeric hotkeys to visible entries.
  if tcontain({CC.Bluetooth, CC.Sound, CC.ScreenMirror}, panel) then
    local cbs
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      cbs = tifilter(getc(pane, AX.ScrollArea, 1, AX.CheckBox) or {},
          function(cb) return cb.AXEnabled end)
      if #cbs == 0 and panel == CC.ScreenMirror then
        cbs = tifilter(getc(pane, AX.ScrollArea, 1,
            AX.Group, 1, AX.CheckBox) or {},
          function(cb) return cb.AXEnabled end)
        if #cbs == 0 then
          cbs = tifilter(getc(pane, AX.ScrollArea, 1,
              AX.Group, 1, AX.DisclosureTriangle) or {},
            function(cb) return cb.AXEnabled end)
        end
      end
    until #cbs > 0 or totalDelay > 1 or not pane:isValid()
    if #cbs > 0 then
      local deviceIDs
      for i=1, math.min(#cbs, 10) do
        local enabled = cbs[i].AXValue
        local name
        if OS_VERSION < OS.Ventura then
          name = cbs[i].AXTitle
        elseif panel == CC.Bluetooth and OS_VERSION >= OS.Tahoe then
          if enabled == 1 then
            local ident = cbs[i].AXIdentifier
            local _, identIdx = ident:find("device-", 1, true)
            ident = ident:sub(identIdx + 1, -1)
            deviceIDs = deviceIDs or getBluetoothConnectedDevices()
            name = deviceIDs[ident] or ident
          else
            name = cbs[i].AXAttributedDescription:getString()
          end
        elseif panel == CC.ScreenMirror and cbs[i].AXAttributedDescription ~= nil then
          name = cbs[i].AXAttributedDescription:getString()
        else
          name = cbs[i].AXIdentifier
          local _, nameIdx = name:find("device-", 1, true)
          name = name:sub(nameIdx + 1, -1)
        end
        local msg = "Connect to " .. name
        if enabled == nil or enabled == 1 then
          local newName = name:match("(.-), %d+%%$")
          if newName ~= nil then name = newName end
          msg = "Disconnect to " .. name
        end
        local hotkey = newControlCenter("", tostring(i%10), msg,
            function()
              cbs[i]:performAction(AX.Press)
            end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end
  end

  -- Helper to register left/right arrow hotkeys
  -- for expanding or collapsing disclosure sections.
  local registerHotkeyForTraingleDisclosure = function(actionFunc, msg, enabled)
    if enabled == 0 then
      hotkeyShow = newControlCenter("", "Right", "Show " .. msg,
        function()
          assert(hotkeyShow) hotkeyShow:disable()
          actionFunc()
          if hotkeyHide == nil then
            hotkeyHide = newControlCenter("", "Left", "Hide " .. msg,
              function()
                assert(hotkeyHide) hotkeyHide:disable()
                assert(hotkeyShow) hotkeyShow:enable()
                actionFunc()
              end)
          end
          assert(hotkeyHide) hotkeyHide:enable()
        end)
      assert(hotkeyShow) hotkeyShow:enable()
    else
      hotkeyHide = newControlCenter("", "Left", "Hide " .. msg,
        function()
          assert(hotkeyHide) hotkeyHide:disable()
          actionFunc()
          if hotkeyShow == nil then
            hotkeyShow = newControlCenter("", "Right", "Show " .. msg,
              function()
                assert(hotkeyShow) hotkeyShow:disable()
                hotkeyHide:enable()
                actionFunc()
              end)
          end
          assert(hotkeyShow) hotkeyShow:enable()
        end)
      assert(hotkeyHide) hotkeyHide:enable()
    end
  end

  if panel == CC.WiFi then
    -- Wi-Fi panel special handling:
    -- - Expand "Other Networks"
    -- - Bind numeric keys to available SSIDs
    -- - Track list changes dynamically
    local triangle
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      local sa = getc(pane, AX.ScrollArea, 1)
      if sa and sa[1] and sa[1].AXRole == AX.OpaqueProviderGroup then
        sa = sa[1]
      end
      triangle = getc(sa, AX.DisclosureTriangle, 1)
    until triangle or totalDelay > 0.5 or not pane:isValid()
    if triangle then
      local actionFunc = function()
        local actions = triangle:actionNames()
        triangle:performAction(actions[#actions])
      end
      local localizedOtherNetworks = mayLocalize("Other Networks")
      registerHotkeyForTraingleDisclosure(actionFunc,
          localizedOtherNetworks, triangle.AXValue)
    end

    -- select network
    selectNetworkHotkeys = {}
    local availableNetworksString = ""
    local selectNetworkActionFunc = function()
      if not pane:isValid()
          or pane[1] == nil or pane[1].AXIdentifier == nil then
        return
      end
      if pane[1].AXValue ~= controlCenterLocalized(panel) then
        return
      end
      local sa
      local totalDelay = 0
      repeat
        hs.timer.usleep(0.05 * 1000000)
        totalDelay = totalDelay + 0.05
        sa = getc(pane, AX.ScrollArea, 1)
        if sa and sa[1] and sa[1].AXRole == AX.OpaqueProviderGroup then
          sa = sa[1]
        end
      until sa or totalDelay > 0.5 or not pane:isValid()
      if sa then
        local availableNetworks = {}
        local cbs = tifilter(sa.AXChildren, function(ele)
          return ele.AXRole == AX.CheckBox or ele.AXRole == AX.Button
        end)
        for idx=1,math.min(#cbs, 10) do
          local cb = cbs[idx]
          local title
          if OS_VERSION < OS.Ventura then
            title = cb.AXTitle:match("([^,]+)")
          else
            title = cb.AXIdentifier:sub(string.len("wifi-network-") + 1, -1)
          end
          tinsert(availableNetworks, title)
        end
        local newAvailableNetworksString = table.concat(availableNetworks, "|")
        if newAvailableNetworksString ~= availableNetworksString then
          availableNetworksString = newAvailableNetworksString
          for _, hotkey in ipairs(selectNetworkHotkeys or {}) do
            hotkey:delete()
          end
          selectNetworkHotkeys = {}
          local ssid
          for idx, title in ipairs(availableNetworks) do
            local selected = cbs[idx].AXValue
            local connected = false
            if cbs[idx].AXRole == AX.CheckBox and selected == 1 then
              connected = true
            elseif cbs[idx].AXRole == AX.Button then
              ssid = ssid or getSSID()
              if title == ssid then
                connected = true
              end
            end
            local msg = (connected and "Disconnect to " or "Connect to ") .. title
            local hotkey = newControlCenter("", tostring(idx % 10), msg,
              function()
                local cb = cbs[idx]
                local actions = cb:actionNames()
                cb:performAction(actions[#actions])
              end)
            assert(hotkey) hotkey:enable()
            tinsert(selectNetworkHotkeys, hotkey)
          end
        end
      else
        for _, hotkey in ipairs(selectNetworkHotkeys or {}) do
          hotkey:delete()
        end
        selectNetworkHotkeys = nil
      end
    end
    selectNetworkActionFunc()
    selectNetworkWatcher = ExecContinuously(selectNetworkActionFunc)
  elseif panel == "AirDrop" then
    -- AirDrop panel:
    -- Bind numeric keys to switch AirDrop visibility modes.
    local cb
    repeat
      hs.timer.usleep(0.05 * 1000000)
      cb = getc(pane, AX.CheckBox, 3)
    until cb or not pane:isValid()
    if cb then
      local cbs = { getc(pane, AX.CheckBox, 2), cb }
      local toggleNames
      if OS_VERSION < OS.Ventura then
        toggleNames = { cbs[1].AXTitle, cbs[2].AXTitle }
      else
        toggleNames = { cbs[1].AXAttributedDescription:getString(),
                        cbs[2].AXAttributedDescription:getString() }
      end
      for i=1,2 do
        local hotkey = newControlCenter("", tostring(i), toggleNames[i],
            function() cbs[i]:performAction(AX.Press) end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end
  elseif panel == CC.Focus then
    -- Focus panel supports hierarchical options.
    -- First-level keys toggle focus modes,
    -- second-level keys control options of the active mode.
    local cb1
    repeat
      hs.timer.usleep(0.05 * 1000000)
      cb1 = getc(pane, AX.CheckBox, 1)
    until cb1 or not pane:isValid()
    if cb1 then
      local h = getc(pane, AX.CheckBox, 1).AXSize.h
      local cbs = tifilter(getc(pane, AX.CheckBox),
          function(cb) return cb.AXSize.h >= h end)
      local toggleNames
      if OS_VERSION < OS.Ventura then
        toggleNames = hs.fnutils.imap(cbs,
            function(cb) return cb.AXTitle end)
      else
        toggleNames = hs.fnutils.imap(cbs,
            function(cb) return cb.AXAttributedDescription:getString() end)
      end
      for i=1,#toggleNames do
        local hotkey = newControlCenter("", tostring(i),
            toggleNames[i],
            function() cbs[i]:performAction(AX.Press) end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
      local focusOptionIndex
      local registerFocusOptionsFunc = function()
        if not pane:isValid()
            or pane[1] == nil or pane[1].AXIdentifier == nil then
          return
        end
        if pane[1].AXValue ~= controlCenterLocalized(panel) then
          return
        end
        local index
        for i, cb in ipairs(cbs) do
          if cb.AXValue == 1 then
            index = i break
          end
        end
        if index == focusOptionIndex then return end
        focusOptionIndex = index
        for _, hotkey in ipairs(focusOptionHotkeys or {}) do
          hotkey:delete()
        end
        focusOptionHotkeys = nil
        if index == nil then return end
        focusOptionHotkeys = {}
        local opts = tifilter(getc(pane, AX.CheckBox),
            function(cb) return cb.AXSize.h < h end)
        if #opts < 2 then
          hs.timer.usleep(0.05 * 1000000)
          opts = tifilter(getc(pane, AX.CheckBox),
              function(cb) return cb.AXSize.h < h end)
        end
        for i=1,#opts do
          local title = opts[i].AXAttributedDescription:getString()
          local hotkey = newControlCenter("⌘", tostring(i),
              toggleNames[index] .. " > " .. title,
              function() opts[i]:performAction(AX.Press) end)
          assert(hotkey) hotkey:enable()
          tinsert(focusOptionHotkeys, hotkey)
        end
      end
      registerFocusOptionsFunc()
      focusOptionWatcher = ExecContinuously(registerFocusOptionsFunc)
    else
      for _, hotkey in ipairs(focusOptionHotkeys or {}) do
        hotkey:delete()
      end
      focusOptionHotkeys = nil
    end
  elseif panel == CC.Display then
    -- Display panel:
    -- Provide shortcuts for display toggles (Dark Mode / Night Shift / True Tone),
    -- brightness control, and external display options.
    local role = OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group
    local sa1
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      sa1 = getc(pane, role, 1)
    until sa1 or totalDelay > 0.5 or not pane:isValid()
    local i, j
    for m, sa in ipairs(getc(pane, role)) do
      for nn =1,#sa do
        local n = #sa - nn + 1
        if sa[n].AXRole == AX.DisclosureTriangle then
          i, j = m, n
          break
        end
      end
    end
    if i and j then
      local elem = getc(pane, role, i, nil, j)
      if elem then
        local hotkey = newControlCenter("", "Space",
            "Toggle Showing Display Presets",
            function() elem:performAction(AX.Press) end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end

    local area = getc(appUI, AX.Window, 1,
        OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group, 1)
    local cb3
    repeat
      hs.timer.usleep(0.05 * 1000000)
      cb3 = getc(area, AX.CheckBox, 3)
    until cb3 or not pane:isValid()
    if cb3 == nil then return end
    local cbs = getc(area, AX.CheckBox)
    local cbTitles = tmap(cbs, function (cb)
      return cb.AXAttributedDescription:getString()
    end)
    local cbIdents = tmap(cbs, function (cb)
      return cb.AXIdentifier
    end)
    local enableds = tmap(cbs, function (cb)
      return cb.AXValue
    end)
    for i=1,3 do
      local checkbox = tfind({"Dark Mode", "Night Shift", "True Tone"},
        function(ele)
          return cbTitles[i]:find(mayLocalize(ele))
        end)
      local op = enableds[i] == 0 and "Enable" or "Disable"
      local hotkey = newControlCenter("", tostring(i),
        op .. " " .. mayLocalize(checkbox),
        function()
          local cb = getc(area, AX.CheckBox, i)
          if not cb then return end
          cb:performAction(AX.Press)
          enableds[i] = 1 - enableds[i]

          if checkbox == "Dark Mode" then
            local appid = hs.application.frontmostApplication():bundleID()
            if tcontain({"com.google.Chrome",
                         "com.microsoft.edgemac",
                         "com.microsoft.edgemac.Dev"}, appid) then
              local scheme = appid == "com.google.Chrome" and "chrome" or "edge"
              local ok = hs.osascript.applescript(strfmt([[
                tell application id "%s"
                  set tabCount to count of tabs of front window
                  set tabFound to false
                  repeat with i from 1 to tabCount
                    set tabURL to URL of tab i of front window
                    if tabURL contains "%s://flags/#enable-force-dark" then
                      set tabFound to true
                      exit repeat
                    end if
                  end repeat
                  if tabFound is false then
                    tell front window
                      set newTab to make new tab at the end of tabs ¬
                          with properties {URL:"%s://flags/#enable-force-dark"}
                      delay 0.5
                    end tell
                  else
                    tell front window
                      set active tab index to i
                    end tell
                  end if
                end tell
              ]], appid, scheme, scheme))
              if ok then
                local app = find(appid)
                local appUI = toappui(app)
                local winUI = towinui(app:focusedWindow())
                local webarea
                repeat
                  webarea = getc(winUI, AX.Group, 1, AX.Group, 1,
                      AX.Group, 1, AX.Group, 1, AX.WebArea, 1)
                until webarea ~= nil
                local list, button
                local totalDelay = 0
                repeat
                  if appid == "com.google.Chrome" then
                    list = getc(webarea, AX.Group, 2, AX.Group, 1,
                                AX.Group, 4, AX.Group, 1)
                  else
                    list = getc(webarea, AX.Group, 1, AX.Group, 2,
                                AX.Group, 1, AX.Group, 3, AX.Group, 1)
                  end
                  if list ~= nil then
                    for _, c in ipairs(list) do
                      if c[1].AXTitle:find("Auto Dark Mode") then
                        button = getc(c, AX.Group, 2, AX.PopupButton, 1)
                      end
                    end
                  else
                    list = tfind(webarea.AXChildren, function(elem)
                      return elem.AXSubrole == AX.TabPanel
                    end)
                    if list == nil and getc(webarea, AX.Group, 4) then
                      list = tfind(getc(webarea, AX.Group, 4).AXChildren,
                        function(elem)
                          return elem.AXSubrole == AX.TabPanel
                        end)
                    end
                  end
                  for ci, c in ipairs(list.AXChildren) do
                    if c.AXRole == AX.Link
                        and c.AXDescription == "#enable-force-dark" then
                      button = getc(list[ci + 1], AX.PopupButton, 1)
                      break
                    end
                  end
                  if button == nil then
                    hs.timer.usleep(0.1 * 1000000)
                    totalDelay = totalDelay + 0.1
                  end
                until button ~= nil or totalDelay > 3 or not webarea:isValid()
                local darkMode = enableds[i] == 1 and "Enabled" or "Disabled"
                if button.AXValue == darkMode then return end
                local clicked = leftClickAndRestore(button, app)
                if not clicked then return end

                local menuItem
                totalDelay = 0
                repeat
                  menuItem = getc(winUI, AX.Group, 1, AX.Group, 1,
                      AX.Group, 1, AX.Group, 1, AX.Menu, 1, AX.MenuItem, darkMode)
                  if menuItem == nil then
                    hs.timer.usleep(0.1 * 1000000)
                    totalDelay = totalDelay + 0.1
                  end
                until menuItem ~= nil or totalDelay > 3 or not webarea:isValid()
                menuItem:performAction(AX.Press)
                local hotkey, observer
                hotkey = AppWinBind(app:focusedWindow(), {
                  mods = "⌘", key = "Return",
                  message = "Relaunch",
                  fn = function()
                    local button = getc(webarea, AX.Group, 4, AX.Group, -1,
                        AX.Group, 2, AX.Button, 1)
                    if button == nil then
                      button = getc(webarea, AX.Group, 7, AX.Button, 1)
                    end
                    leftClickAndRestore(button, app)
                    if hotkey ~= nil then
                      hotkey:delete()
                      hotkey = nil
                    end
                    if observer ~= nil then
                      observer:stop()
                      observer = nil
                    end
                  end,
                })
                observer = uiobserver.new(app:pid())
                observer:addWatcher(appUI, uinotifications.focusedUIElementChanged)
                observer:addWatcher(winUI, uinotifications.titleChanged)
                observer:addWatcher(appUI, uinotifications.applicationDeactivated)
                observer:callback(function()
                  local frontWinBundleID = hs.window.frontmostWindow()
                      :application():bundleID()
                  if frontWinBundleID == appid and webarea:isValid() then
                    local url = getc(webarea.AXParent.AXParent, AX.Toolbar, 1,
                        AX.Group, 1, AX.TextField, 1).AXValue
                    if url == scheme .. "://flags/#enable-force-dark" then
                      return
                    end
                  end
                  if hotkey ~= nil then
                    hotkey:delete()
                    hotkey = nil
                  end
                  if observer ~= nil then
                    observer:stop()
                    observer = nil
                  end
                end)
                observer:start()
              end
            end
          end
        end)
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
    for i=4,#cbs do
      if i - 3 > 10 then break end
      local _, nameIdx = cbIdents[i]:find("device-", 1, true)
      local device = cbIdents[i]:sub(nameIdx + 1, -1)
      local msg
      if result[2][i] == 0 then
        msg = "Connect to " .. device
      else
        msg = "Disconnect to " .. device
      end
      local hotkey = newControlCenter("⌘", tostring((i-3)%10), msg,
        function()
          local cb = getc(area, AX.CheckBox, i)
          if cb then cb:performAction(AX.Press) end
        end)
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
  elseif panel == CC.MusicRecognition then
    -- Music Recognition panel:
    -- Bind shortcut to start or stop music recognition.
    local msg = "Start Listening"
    msg = controlCenterLocalized(panel, msg) or msg
    local hotkey = newControlCenter("", "Space", msg,
      function()
        local cb
        if OS_VERSION < OS.Tahoe then
          cb = getc(pane, AX.Group, 1, AX.CheckBox, 1)
        else
          cb = getc(pane, AX.Group, 1, AX.Group, 1, AX.CheckBox, 1)
        end
        if cb then cb:performAction(AX.Press) end
      end)
    if not checkAndRegisterControlCenterHotKeys(hotkey) then
      return
    end
  elseif panel == CC.Hearing then
    -- Hearing panel:
    -- Control background sounds, volume sliders, and sound profiles
    -- with expandable disclosure support.
    local hearingFunc
    hearingFunc = function()
      if hotkeyShow ~= nil then
        hotkeyShow:delete()
        hotkeyShow = nil
      end
      if hotkeyHide ~= nil then
        hotkeyHide:delete()
        hotkeyHide = nil
      end
      for _, hotkey in ipairs(backgroundSoundsHotkeys or {}) do
        hotkey:delete()
      end
      backgroundSoundsHotkeys = nil
      local slid
      local totalDelay = 0
      repeat
        hs.timer.usleep(0.05 * 1000000)
        totalDelay = totalDelay + 0.05
        slid = getc(pane, AX.Slider, 1)
      until slid or totalDelay > 1 or not pane:isValid()
      if slid == nil then
        local triangle = getc(pane, AX.DisclosureTriangle, 1)
        if triangle == nil then
          return
        end
      end

      local actionFunc
      local triangle = getc(pane, AX.DisclosureTriangle, 1)
      actionFunc = function()
        local actions = triangle:actionNames()
        local actIdx = pane.AXRole == AX.ScrollArea and 2 or 1
        triangle:performAction(actions[actIdx])
        hearingFunc()
      end
      registerHotkeyForTraingleDisclosure(actionFunc, "Sounds",
                                          slid and 1 or 0)
      if slid == nil then return end

      local sliders = getc(pane, AX.Slider)
          or getc(pane, AX.Slider)
      local enabledSliders = tifilter(sliders,
          function(slid) return slid.AXEnabled end)
      if #enabledSliders == 1 then
        if backgroundSoundsHotkeys == nil then
          backgroundSoundsHotkeys = {}
        end
        local actions = {{ '=', 'Up'}, {'-', 'Down'}}
        if OS_VERSION < OS.Tahoe then
          tconcat(actions, {{'[', 'Min'}, {']', 'Max'}})
        end
        for _, spec in pairs(actions) do
          local key = spec[1]
          local slid = enabledSliders[1]
          local hotkey = newControlCenter("", key, "Volume " .. spec[2],
            function()
              if key == '=' then
                slid:performAction(AX.Increment)
              elseif key == '-' then
                slid:performAction(AX.Decrement)
              elseif key == '[' then
                slid.AXValue = 0
              else
                slid.AXValue = 100
              end
            end)
          assert(hotkey) hotkey:enable()
          tinsert(backgroundSoundsHotkeys, hotkey)
        end
      end

      local cbs
      repeat
        hs.timer.usleep(0.05 * 1000000)
        cbs = getc(pane, AX.CheckBox)
        if cbs == nil then
          cbs = tifilter(getc(pane, AX.CheckBox) or {}, function(cb)
            return cb.AXIdentifier and cb.AXIdentifier:find("button%-identifier") end)
        end
      until #cbs > 0
      if #cbs > 1 then
        if backgroundSoundsHotkeys == nil then
          backgroundSoundsHotkeys = {}
        end
        for i=1,math.min(#cbs, 10) do
          local msg = cbs[i].AXAttributedDescription:getString()
          local hotkey = newControlCenter("", tostring(i % 10), msg,
              function() cbs[i]:performAction(AX.Press) end)
          assert(hotkey) hotkey:enable()
          tinsert(backgroundSoundsHotkeys, hotkey)
        end
      end
    end

    local hotkey = newControlCenter("", "Space",
      "Toggle " .. mayLocalize("Background Sounds"),
      function()
        if hotkeyShow ~= nil then
          hotkeyShow:delete()
          hotkeyShow = nil
        end
        if hotkeyHide ~= nil then
          hotkeyHide:delete()
          hotkeyHide = nil
        end
        for _, hotkey in ipairs(backgroundSoundsHotkeys or {}) do
          hotkey:delete()
        end
        backgroundSoundsHotkeys = nil
        local cb = getc(pane, AX.DisclosureTriangle, 1)
            or getc(pane, AX.CheckBox, 1)
        if cb then
          cb:performAction(AX.Press)
          hs.timer.doAfter(0.2,  hearingFunc)
        end
      end)
    if not checkAndRegisterControlCenterHotKeys(hotkey) then
      return
    end

    hearingFunc()
  elseif panel == CC.NowPlaying then
    -- Now Playing panel:
    -- Bind media transport controls and per-session playback shortcuts.
    local result
    local button2
    repeat
      hs.timer.usleep(0.05 * 1000000)
      if OS_VERSION >= OS.Tahoe then
        button2 = getc(pane, AX.Group, 1, AX.Button, 2)
      else
        button2 = getc(pane, AX.Button, 2)
      end
    until button2 or not pane:isValid()
    if button2 then
      if OS_VERSION >= OS.Tahoe then
        pane = getc(pane, AX.Group, 1)
      end
      if OS_VERSION < OS.Ventura then
        result = tmap(getc(pane, AX.Button),
            function(bt) return bt.AXTitle end)
      else
        result = #getc(pane, AX.Button)
      end
      if (type(result) == "number" and result == 3)
          or (type(result) == "table" and #result == 3) then
        if result == 3 then
          result = {
            mayLocalize("previous"),
            mayLocalize("play") .. "/" .. mayLocalize("pause"),
            mayLocalize("next")
          }
        end
        local hotkey
        hotkey = newControlCenter("", "Space", result[2],
          function()
            local defaultMusicAppForControlCenter =
                ApplicationConfigs["defaultMusicAppForControlCenter"]
            if defaultMusicAppForControlCenter ~= nil then
              local launchCustomizedApp = false
              local appTitle = getc(pane, AX.StaticText, 1)
              if OS_VERSION < OS.Tahoe then
                local appname = displayName('com.apple.Music')
                if appTitle and appTitle.AXValue == appname .. '.app' then
                  launchCustomizedApp = true
                end
              else
                if appTitle and appTitle.AXValue == mayLocalize("Not Playing") then
                  launchCustomizedApp = true
                end
              end
              if launchCustomizedApp then
                if type(defaultMusicAppForControlCenter) == 'string' then
                  defaultMusicAppForControlCenter =
                      { defaultMusicAppForControlCenter }
                end
                for _, appid in ipairs(defaultMusicAppForControlCenter) do
                  if installed(appid) then
                    hs.application.launchOrFocusByBundleID(appid)
                    return
                  end
                end
              end
            end
            local button = getc(pane, AX.Button, 2)
            if button then button:performAction(AX.Press) end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
        local buttonLeft = getc(pane, AX.Button, 1)
        if buttonLeft and buttonLeft.AXEnabled then
          hotkey = newControlCenter("", "Left", result[1],
            function()
              if buttonLeft then buttonLeft:performAction(AX.Press) end
            end)
          if not checkAndRegisterControlCenterHotKeys(hotkey) then
            return
          end
        end
        local buttonRight = getc(pane, AX.Button, 3)
        if buttonRight and buttonRight.AXEnabled then
          hotkey = newControlCenter("", "Right", result[3],
            function()
              if buttonRight then buttonRight:performAction(AX.Press) end
            end)
          if not checkAndRegisterControlCenterHotKeys(hotkey) then
            return
          end
        end
      elseif (type(result) == "number" and result > 3)
          or (type(result) == "table" and #result > 3) then
        local nEntries
        if type(result) == "number" then
          nEntries = result / 2
        else
          nEntries = #result / 2
        end
        for i = 1, nEntries do
          local buttonLabel = mayLocalize("play")
              .. "/" .. mayLocalize("pause")
          local hotkey = newControlCenter("", tostring(i),
            type(result) == "number" and buttonLabel or result[2*i-1],
            function()
              local button = getc(pane, AX.Button, 2 * i - 1)
              if button then button:performAction(AX.Press) end
            end)
          if not checkAndRegisterControlCenterHotKeys(hotkey) then
            return
          end
        end
      elseif result == 2 then
        for i, g in ipairs(getc(pane, AX.Group)) do
          local buttonLabel = mayLocalize("play")
              .. "/" .. mayLocalize("pause")
          local hotkey = newControlCenter("", tostring(i), buttonLabel,
            function()
              local button = getc(g, AX.Button, 1)
              if button then button:performAction(AX.Press) end
            end)
          if not checkAndRegisterControlCenterHotKeys(hotkey) then
            return
          end
        end
      end
    end
  end
end

-- Handle Control Center window creation and register dynamic hotkeys
local controlCenter = find("com.apple.controlcenter")
ControlCenterObserver = uiobserver.new(controlCenter:pid())
ControlCenterObserver:addWatcher(
  toappui(controlCenter),
  uinotifications.windowCreated
)

local function controlCenterObserverCallback()
  if controlCenter:focusedWindow() == nil then return end
  local controlCenterDestroyObserver =
      uiobserver.new(controlCenter:pid())
  if OS_VERSION >= OS.Tahoe then
    controlCenterDestroyObserver:addWatcher(
      toappui(controlCenter),
      uinotifications.uIElementDestroyed
    )
  else
    controlCenterDestroyObserver:addWatcher(
      towinui(controlCenter:focusedWindow()),
      uinotifications.uIElementDestroyed
    )
  end
  controlCenterDestroyObserver:callback(function()
    if OS_VERSION >= OS.Tahoe then
      local win = controlCenter:focusedWindow()
      if win and win:title() == displayName(controlCenter:bundleID()) then
        return
      end
    end
    if selectNetworkWatcher ~= nil then
      StopExecContinuously(selectNetworkWatcher)
      selectNetworkWatcher = nil
    end
    if selectNetworkHotkeys ~= nil then
      for _, hotkey in ipairs(selectNetworkHotkeys) do
        hotkey:delete()
      end
      selectNetworkHotkeys = nil
    end
    if focusOptionWatcher ~= nil then
      StopExecContinuously(focusOptionWatcher)
      focusOptionWatcher = nil
    end
    if focusOptionHotkeys ~= nil then
      for _, hotkey in ipairs(focusOptionHotkeys) do
        hotkey:delete()
      end
      focusOptionHotkeys = nil
    end
    if controlCenterHotKeys ~= nil then
      for _, hotkey in ipairs(controlCenterHotKeys) do
        hotkey:delete()
      end
      controlCenterHotKeys = nil
    end
    hotkeyMainBack = nil
    if hotkeyShow ~= nil then
      hotkeyShow:delete()
      hotkeyShow = nil
    end
    if hotkeyHide ~= nil then
      hotkeyHide:delete()
      hotkeyHide = nil
    end
    if backgroundSoundsHotkeys ~= nil then
      for _, hotkey in ipairs(backgroundSoundsHotkeys) do
        hotkey:delete()
      end
      backgroundSoundsHotkeys = nil
    end
    controlCenterDestroyObserver:stop()
    controlCenterDestroyObserver = nil
  end)
  controlCenterDestroyObserver:start()
end
ControlCenterObserver:callback(controlCenterObserverCallback)
ControlCenterObserver:start()

-- Detect currently active Control Center panel
local function getActiveControlCenterPanel()
  local appUI = toappui(find('com.apple.controlcenter'))
  local pane = getc(appUI, AX.Window, 1)
  if OS_VERSION >= OS.Ventura then
    pane = getc(pane, AX.Group, 1)
  end

  for _, panel in pairs(controlCenterPanels) do
    if testAlready(panel, pane) then
      return panel
    end
  end
end
if hs.window.focusedWindow() ~= nil
    and hs.window.focusedWindow():application():bundleID()
        == "com.apple.controlcenter"
    and hs.window.focusedWindow():subrole()
        == AX.SystemDialog then
  local frame = hs.window.focusedWindow():frame()
  local scrFrame = hs.screen.mainScreen():fullFrame()
  local inMenuBar = frame.x + frame.w ~= scrFrame.x + scrFrame.w
  registerControlCenterHotKeys(getActiveControlCenterPanel(),
                               inMenuBar)
  controlCenterObserverCallback()
end

ExecContinuously(function()
  if not controlCenter:isRunning() then
    hs.timer.doAfter(2, function()
      ControlCenterObserver:stop()
      controlCenter = find("com.apple.controlcenter")
      ControlCenterObserver = uiobserver.new(controlCenter:pid())
      ControlCenterObserver:addWatcher(
        toappui(controlCenter),
        uinotifications.windowCreated)
      ControlCenterObserver:callback(controlCenterObserverCallback)
      ControlCenterObserver:start()
    end)
  end
end)


-- Menu bar item search.
--
-- Provides a chooser-based interface to search and trigger
-- menu bar items across running applications.

local function registerSearchMenuBar()
  -- Collect menu bar items from all running applications.
  -- For each app, try to load autosaved status item identifiers
  -- and map them to accessibility menu bar elements if available.
  local menuBarItems, maps = {}, {}
  local apps = hs.application.runningApplications()
  for _, app in ipairs(apps) do
    local appid = app:bundleID() or app:name()
    local map, preferred = loadStatusItemsAutosaveName(app, true)
    if map and #map > 0 then
      maps[appid] = map or {}
      if appid ~= 'com.apple.controlcenter' or OS_VERSION < OS.Tahoe then
        local appMenuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
        if appMenuBarItems then
          for i, item in ipairs(appMenuBarItems) do
            tinsert(menuBarItems, { item, i, preferred[i] })
          end
        else
          for i, item in ipairs(preferred) do
            tinsert(menuBarItems, { app, i, item })
          end
        end
      end
    end
  end
  if #menuBarItems == 0 then
    return
  end

  -- Sort menu bar items by their on-screen position (right to left),
  -- falling back to autosave name order when accessibility position
  -- is unavailable.
  table.sort(menuBarItems, function(a, b)
    if a[1].AXPosition and b[1].AXPosition then
      return a[1].AXPosition.x > b[1].AXPosition.x
    else
      return a[3] < b[3]
    end
  end)

  -- On newer macOS versions, Control Center hosts additional menu bar items
  -- (e.g. empty entries and Live Activities) that need to be excluded or
  -- merged into the global menu bar ordering
  if OS_VERSION >= OS.Tahoe then
    local appMenuBarItems = getc(toappui(find('com.apple.controlcenter')),
        AX.MenuBar, -1, AX.MenuBarItem)
    appMenuBarItems = tifilter(appMenuBarItems, function(item)
      return item.AXIdentifier
          and (item.AXIdentifier:sub(1, 20) == 'com.apple.menuextra.'
            or item.AXIdentifier:sub(-13) == '.liveActivity')
    end)
    local items = {}
    for i, item in ipairs(appMenuBarItems) do
      tinsert(items, { item, i })
    end
    table.sort(items, function(a, b)
      return a[1].AXPosition.x > b[1].AXPosition.x
    end)
    foreach(items, function(item)
      local position = item[1].AXPosition.x
      for i=1,#menuBarItems do
        if menuBarItems[i][1].AXPosition and menuBarItems[i][1].AXPosition.x < position then
          tinsert(menuBarItems, i, item)
          break
        end
      end
    end)
  end

  -- Trim menu bar items to only those to the right of Control Center,
  -- since items on the left are not reachable via Control Center UI.
  for i, pair in ipairs(menuBarItems) do
    local item = pair[1]
    local app
    if item.AXPosition then
      app = item.AXParent.AXParent:asHSApplication()
    else
      app = item
    end
    local appid = app:bundleID() or app:name()
    if appid == 'com.apple.controlcenter' then
      for j=i-1,1,-1 do
        tremove(menuBarItems, j)
      end
      break
    end
  end

  -- Build chooser entries from collected menu bar items.
  -- Each entry includes display text, optional subtitle,
  -- application icon, and extra search patterns.
  local choices = {}
  local ccBentoBoxCnt = 0
  for _, pair in ipairs(menuBarItems) do
    local item, idx = pair[1], pair[2]
    local app
    if item.AXPosition then
      app = item.AXParent.AXParent:asHSApplication()
    else
      app = item
    end
    local appid = app:bundleID() or app:name()
    local appname = app:name()
    local title, extraSearchPattern
    if #maps[appid] > 1 then
      local autosaveName = maps[appid][idx]
      if appid == 'com.apple.controlcenter' then
        -- Special handling for Control Center items:
        -- - Normalize BentoBox naming
        -- - Attach additional search patterns
        if autosaveName then
          extraSearchPattern = autosaveName
          if autosaveName:match('^BentoBox%-') then
            if ccBentoBoxCnt > 0 then
              title = "BentoBox-" .. tostring(ccBentoBoxCnt)
            end
            ccBentoBoxCnt = ccBentoBoxCnt + 1
          end
        elseif item.AXDescription:match('^'..appname) then
          if OS_VERSION < OS.Tahoe then
            extraSearchPattern = "BentoBox"
          else
            extraSearchPattern = "BentoBox-" .. tostring(ccBentoBoxCnt)
            if ccBentoBoxCnt > 0 then
              title = "BentoBox-" .. tostring(ccBentoBoxCnt)
            end
            ccBentoBoxCnt = ccBentoBoxCnt + 1
          end
        elseif item.AXIdentifier:sub(-13) == '.liveActivity' then
          extraSearchPattern = item.AXIdentifier
        else
          local parts = strsplit(item.AXIdentifier, "%.")
          extraSearchPattern = parts[#parts]
        end
        extraSearchPattern = { appname, extraSearchPattern }
        appname = item.AXDescription
      elseif autosaveName ~= "Item-0" or #tifilter(maps[appid],
          function(v) return v:sub(1, 5) == "Item-" end) > 1 then
        title = autosaveName
      end
    end

    -- Resolve icon and search metadata for menu bar items.
    --
    -- Prefer using the application's bundle ID to fetch its icon directly.
    -- However, some menu bar items are backed by helper processes or
    -- non-bundled executables, in which case `app:bundleID()` is nil.
    local image
    if app:bundleID() then
      image = hs.image.imageFromAppBundle(appid)
    else
      -- Fallback for processes without a bundle ID:
      -- Inspect the executable path via `lsof` to locate the enclosing `.app`
      -- bundle, then infer its bundle identifier manually.
      local pathStr, ok = hs.execute(strfmt([[
          lsof -a -d txt -p %s 2>/dev/null | sed -n '2p' | awk '{print $NF}']], app:pid()))
      if ok and pathStr ~= "" then
        local parts = {}
        for part in string.gmatch(pathStr, "[^/]+") do
            table.insert(parts, part)
        end

        -- Walk backwards to find the nearest enclosing `.app` bundle
        for i = #parts, 1, -1 do
          if parts[i]:sub(-4) == ".app" then
            local subPath = {}
            for j = 1, i do
                table.insert(subPath, parts[j])
            end
            local appPath = "/" .. table.concat(subPath, "/")
            local info = hs.application.infoForBundlePath(appPath)
            if info and info.CFBundleIdentifier then
              extraSearchPattern = info.CFBundleIdentifier
              image = hs.image.imageFromAppBundle(info.CFBundleIdentifier)
              break
            end
          end
        end
      end
    end
    choices[#choices + 1] = {
      text = appname,
      subText = title,
      image = image,
      id = #choices + 1,
      appid = appid,
      extraPattern = extraSearchPattern
    }
  end

  -- Chooser callback:
  -- Trigger the selected menu bar item using the most reliable method
  -- (accessibility press or simulated mouse click), depending on the item.
  local chooser
  chooser = hs.chooser.new(function(choice)
    if choice == nil then return end
    hs.timer.doAfter(0, function()
      local item = menuBarItems[choice.id][1]
      if item.AXPosition == nil then
        local left, right = menuBarItems[choice.id+1][1], menuBarItems[choice.id-1][1]
        if left.AXPosition and right.AXPosition then
          local position = hs.geometry.point(
            (left.AXPosition.x + left.AXSize.w + right.AXPosition.x) / 2,
            left.AXPosition.y + left.AXSize.h / 2
          )
          if choice.appid == "at.obdev.littlesnitch.agent" then
            rightClickAndRestore(position)
          else
            leftClickAndRestore(position)
          end
        end
        return
      end
      if choice.appid:sub(1, 10) == 'com.apple.' then
        if type(choice.extraPattern) ~= 'table'
            or tfind(choice.extraPattern, function(pattern)
                  return pattern:sub(-13) == '.liveActivity'
                end) == nil then
          menuBarItems[choice.id][1]:performAction(AX.Press)
          return
        end
      end
      if not leftClickAndRestore(item, find(choice.appid)) then
        if choice.appid == hs.settings.bundleID then
          -- Special-case handling for Hammerspoon menu bar items
          -- (e.g. caffeine and proxy), which cannot always be triggered
          -- via accessibility actions.
          if choice.subText == caffeine:autosaveName() then
            caffeineClicked()
            return
          elseif choice.subText == proxy:autosaveName() then
            local frame = proxy:_frame()
            local screenFrame = hs.screen.mainScreen():frame()
            proxy:popupMenu({ x = frame.x,
                              y = screenFrame.y + screenFrame.h - frame.y })
            return
          end
          -- fixme: hanging issue
          hs.alert.show("Cannot trigger Hammerspoon menu bar item", 2)
          return
        end
        menuBarItems[choice.id][1]:performAction(AX.Press)
      end
    end)
  end)
  chooser:choices(choices)

  -- Dynamic filtering:
  -- Match query against app name, bundle ID, item title,
  -- and additional extracted identifiers.
  chooser:queryChangedCallback(function(query)
    local newChoices = {}
    local loweredQuery = string.lower(query)
    for _, choice in ipairs(choices) do
      if choice.text:lower():find(loweredQuery, 1, true)
          or choice.appid:lower():find(loweredQuery, 1, true)
          or (choice.subText and choice.subText:lower()
              :find(loweredQuery, 1, true))
          or (type(choice.extraPattern) == 'string'
              and choice.extraPattern:lower():find(loweredQuery, 1, true))
          or (type(choice.extraPattern) == 'table'
              and tfind(choice.extraPattern, function(pattern)
                return pattern:lower():find(loweredQuery, 1, true)
              end)) then
        tinsert(newChoices, choice)
      end
    end
    chooser:choices(newChoices)
  end)
  hs.keycodes.currentSourceID("com.apple.keylayout.ABC")
  chooser:show()
end

local hotkeySearchMenuBar
local misc = KeybindingConfigs.hotkeys.global
if misc ~= nil and misc["searchMenuBar"] ~= nil then
  local menuBarManagers = {
    "com.surteesstudios.Bartender",
    "com.jordanbaird.Ice",
  }
  local anyRunning = tfind(menuBarManagers, function(appid)
    return find(appid) ~= nil
  end)
  if not anyRunning then
    hotkeySearchMenuBar = bindHotkeySpec(misc["searchMenuBar"],
        'Search Menu Bar', registerSearchMenuBar)
    hotkeySearchMenuBar.kind = HK.MENUBAR
  end
  foreach(menuBarManagers, function(appid)
    ExecOnSilentLaunch(appid, function()
      if hotkeySearchMenuBar then
        hotkeySearchMenuBar:disable()
      end
      ExecOnSilentQuit(appid, function()
        anyRunning = tfind(menuBarManagers, function(appid)
          return find(appid) ~= nil
        end)
        if not anyRunning then
          if hotkeySearchMenuBar == nil then
            hotkeySearchMenuBar = bindHotkeySpec(misc["searchMenuBar"],
                'Search Menu Bar', registerSearchMenuBar)
            hotkeySearchMenuBar.kind = HK.MENUBAR
          end
          hotkeySearchMenuBar:enable()
        end
      end)
    end)
  end)
end

-- # callbacks

-- application installation/uninstallation callbacks
function System_applicationInstalledCallback(files, flagTables)
  for i=1,#files do
    if files[i]:match("V2RayX")
        or files[i]:match("V2rayU")
        or files[i]:match("MonoProxyMac") then
      registerProxyMenu(true)
    end
  end
end

-- monitor callbacks

local builtinMonitor = "Built-in Retina Display"

function System_monitorChangedCallback()
  local screens = hs.screen.allScreens()

  -- only for built-in monitor
  local builtinMonitorEnable = any(screens,
    function(screen)
      return screen:name() == builtinMonitor
    end)

  -- for external monitors
  if (builtinMonitorEnable and #screens > 1)
    or (not builtinMonitorEnable and #screens > 0) then
    hs.caffeinate.set("displayIdle", true)
    caffeine:setTitle("AWAKE")
  elseif builtinMonitorEnable and #screens == 1 then
    hs.caffeinate.set("displayIdle", false)
    caffeine:setTitle("SLEEPY")
  end
end

function System_networkChangedCallback(storeObj, changedKeys)
  registerProxyMenuWrapper(storeObj, changedKeys)
end

-- battery callbacks

function System_batteryChangedCallback()
  local percent = hs.battery.percentage()
  if percent <= 10 then
    if not hs.battery.isCharging() then
      hs.alert.show("Battery is low, please charge your laptop!", 3)
    end

    if hs.caffeinate.get("displayIdle") then
      hs.caffeinate.set("displayIdle", false)
      caffeine:setTitle("SLEEPY")
    end
    if hs.caffeinate.get("systemIdle") then
      hs.caffeinate.set("systemIdle", false)
    end
  end
end

shellCommandsExecutedOnLoading = {}
