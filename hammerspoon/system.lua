require "utils"

-- menubar for caffeine
local caffeine = hs.menubar.new(true, "CAFFEINE")

local function setCaffeineDisplay(state)
  if state then
    caffeine:setTitle("AWAKE")
  else
    caffeine:setTitle("SLEEPY")
  end
end

local function caffeineClicked()
  setCaffeineDisplay(hs.caffeinate.toggle("displayIdle"))
end

if caffeine then
  caffeine:setClickCallback(caffeineClicked)
  setCaffeineDisplay(hs.caffeinate.get("displayIdle"))
end

-- system proxy helpers
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

local function disable_proxy(networkservice)
  networkservice = networkservice or getNetworkService()
  hs.execute('networksetup -setproxyautodiscovery "' .. networkservice .. '" off')
  hs.execute('networksetup -setautoproxystate "' .. networkservice .. '" off')
  hs.execute('networksetup -setwebproxystate "' .. networkservice .. '" off')
  hs.execute('networksetup -setsecurewebproxystate "' .. networkservice .. '" off')
  hs.execute('networksetup -setsocksfirewallproxystate "' .. networkservice .. '" off')
end

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

local proxyAppBundleIDs = {
  V2RayX = "cenmrev.V2RayX",
  V2rayU = "net.yanue.V2rayU",
  MonoCloud = "com.MonoCloud.MonoProxyMac",
}

-- toggle connect/disconnect VPN using `V2RayX`
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

-- toggle connect/disconnect VPN using `V2rayU`
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

-- toggle connect/disconnect VPN using `MonoCloud`(`MonoProxyMac`)
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

  local interface = hs.network.primaryInterfaces()
  local interfaceName = getNetworkService(true)
  if condition.ssid then
    if interfaceName == 'Wi-Fi' then
      local ssid = hs.wifi.currentNetwork()
      if ssid == nil then
        if hs.location.servicesEnabled() then
          hs.location.start()
          -- you may be prompted to authorise Hammerspoon to use Location Services
          if hs.location.get() then
            ssid = hs.wifi.currentNetwork()
          end
          hs.location.stop()
        end
      end
      if ssid == nil then
        local osv = hs.host.operatingSystemVersion()
        if osv.major < 15 or (osv.major == 15 and osv.minor < 6) then
          ssid = hs.execute(strfmt([[
            ipconfig getsummary %s | awk -F ' SSID : '  '/ SSID : / {print $2}' | tr -d '\n'
          ]], interface))
        end
      end
      if ssid and ssid ~= "" then
        local ssidPatterns = type(condition.ssid) == 'string'
            and { condition.ssid } or condition.ssid
        if tfind(ssidPatterns, function(id) return ssid:match(id) end) then
          return true
        end
      end
    end
  end
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

-- load proxy configs
ProxyConfigs = {}

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
    if ProxyConfigs[candidate.appname] ~= nil
        and hs.application.pathForBundleID(appid) ~= nil
        and hs.application.pathForBundleID(appid) ~= "" then
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


local menubarHK = KeybindingConfigs.hotkeys.global

local proxyHotkey = bindHotkeySpec(menubarHK["showProxyMenu"], "Show Proxy Menu",
    bind(clickRightMenuBarItem, {hs.settings.bundleID, proxy:title()}))
proxyHotkey.kind = HK.MENUBAR
proxyHotkey.icon = hs.image.imageFromAppBundle("com.apple.systempreferences")

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

-- assume `Control Center` window is always frontmost
-- so not necessary to call "inAppHotKeysWrapper"
local function newControlCenter(...)
  local hotkey = newHotkey(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.MENUBAR
  hotkey.subkind = HK.MENUBAR_.CONTROL_CENTER
  return hotkey
end

local function bindControlCenter(...)
  local hotkey = bindHotkeySpec(...)
  if hotkey == nil then return nil end
  hotkey.kind = HK.MENUBAR
  hotkey.subkind = HK.MENUBAR_.CONTROL_CENTER
  return hotkey
end

local controlCenterPanelFuncs = {}
hs.urlevent.bind("controlcenter", function(eventName, params)
  if params["panel"] == "Music Recognition" then
    params["panel"] = "Recognize Music"
  end
  local fn = controlCenterPanelFuncs[params["panel"]]
  if fn then fn() end
end)

local function bindControlCenterURL(panel, func)
  controlCenterPanelFuncs[panel] = func
end

local defaultMusicAppForControlCenter
defaultMusicAppForControlCenter = ApplicationConfigs["defaultMusicAppForControlCenter"]

local function controlCenterLocalized(panel, key)
  if key == nil then
    key = panel
  end
  if panel == "Users" and key == "Users" then
    key = "User"
  end
  if panel == "Recognize Music" then
    panel = "Music Recognition"
  end
  panel = panel:gsub(" ", ""):gsub("‑", "")
  local result = localizedString(key, "com.apple.controlcenter", panel)
  if result == nil and panel == "Focus" then
    result = localizedString(key, "com.apple.controlcenter",
        { framework = "DoNotDisturb.framework" }, true)
    if result == nil then
      result = localizedString(key, "com.apple.controlcenter",
          { framework = "DoNotDisturbKit.framework" }, true)
    end
  end
  return result
end

local function testAlready(panel, pane, role)
  local locPanel = controlCenterLocalized(panel)

  if role == nil then
    if tcontain({ "Wi‑Fi", "Focus", "Bluetooth", "AirDrop",
                  "Keyboard Brightness", "Screen Mirroring",
                  "Accessibility Shortcuts", "Battery",
                  "Sound", "Hearing" }, panel) then
      local elem = getc(pane, AX.StaticText, 1)
      return elem and elem.AXValue == locPanel
    elseif panel == "Display" then
      local sa = getc(pane, OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group, 1)
      local elem = getc(sa, AX.DisclosureTriangle, 1)
      local title = elem and (elem.AXTitle or elem.AXAttributedDescription:getString())
      return elem and title == locPanel
    elseif panel == "Recognize Music" or panel == "Music Recognition" then
      local elem = getc(pane, AX.Group, 1, AX.Group, 1, AX.CheckBox, 1)
      local title = elem and (elem.AXTitle or elem.AXAttributedDescription:getString())
      return elem and title:match('^'..locPanel)
    elseif panel == "Now Playing" then
      if OS_VERSION < OS.Ventura then
        local mayLocalize = bind(controlCenterLocalized, panel)
        return getc(pane, AX.Button, mayLocalize("rewind")) ~= nil
            or getc(pane, AX.Button, mayLocalize("previous")) ~= nil
            or (#getc(pane, AX.Button, mayLocalize("play"))
              + #getc(pane, AX.Button, mayLocalize("pause"))) > 1
      else
        if OS_VERSION >= OS.Tahoe then pane = getc(pane, AX.Group, 1) end
        return pane and #getc(pane, AX.Button) > 2
            and (#getc(pane, AX.Image) > 0 or pane[1].AXRole == AX.Unknown)
      end
    elseif panel == "Users" then
      local elem = pane[#pane]
      local title = elem.AXTitle or elem.AXAttributedDescription:getString()
      return title == controlCenterLocalized(panel, "Users & Groups Settings…")
    end
  end

  return tfind(getc(pane, role) or {}, function(elem)
    local title = elem.AXTitle or elem.AXAttributedDescription:getString()
    if title == locPanel then return true end
  end) ~= nil
end

local function popupControlCenterSubPanel(panel, allowReentry)
  local app = find("com.apple.controlcenter")
  local appUI = toappui(app)
  local pane

  local function enterPanel()
    local role, index
    if tcontain({ "Wi‑Fi", "Focus",
                  "Bluetooth", "AirDrop",
                  "Recognize Music", "Music Recognition" }, panel) then
      role = AX.CheckBox index = 2
    elseif panel == "Screen Mirroring" then
      if OS_VERSION >= OS.Ventura and OS_VERSION <= OS.Sequoia then
        role = AX.Button index = 1
      else
        role = AX.CheckBox index = 2
      end
    elseif panel == "Display" then
      if OS_VERSION >= OS.Ventura and OS_VERSION <= OS.Sequoia then
        role = AX.Group
      else
        role = AX.StaticText
      end
      index = 1
    elseif panel == "Keyboard Brightness" then
      if OS_VERSION <= OS.Sequoia then
        role = AX.Button
      else
        role = AX.StaticText
      end
      index = 1
    elseif panel == "Sound" then
      role = AX.StaticText index = 1
    elseif tcontain({ "Accessibility Shortcuts",
                      "Battery", "Hearing", "Users" }, panel) then
      role = AX.Button index = 1
    elseif panel == "Now Playing" then
      local ele
      if OS_VERSION >= OS.Tahoe then
        ele = tfind(getc(pane, AX.Group), function(g)
          local bts = getc(g, AX.Button)
          return #bts == 3 and bts[1].AXIdentifier:find("backward")
            and bts[3].AXIdentifier:find("forward")
            and (bts[2].AXIdentifier:find("play") or bts[2].AXIdentifier:find("pause"))
        end)
      else
        ele = getc(pane, AX.Image, -1)
        local totalDelay = 0
        while ele == nil do
          hs.timer.usleep(0.05 * 1000000)
          totalDelay = totalDelay + 0.05
          if totalDelay > 3 then return end
          ele = getc(pane, AX.Image, -1)
        end
      end
      if ele then
        local index = 1
        if OS_VERSION >= OS.Tahoe then index = index + 1 end
        local act = ele:actionNames()[index]
        ele:performAction(act)
      end
      return
    end

    local ele
    local totalDelay = 0
    local locPanel = controlCenterLocalized(panel)
    repeat
      ele = tfind(getc(pane, role), function(e)
        if role == AX.StaticText then
          return e.AXValue == locPanel
        else
          local title = e.AXTitle or e.AXAttributedDescription:getString()
          return title == locPanel
        end
      end)
      if ele == nil then
        hs.timer.usleep(0.05 * 1000000)
        totalDelay = totalDelay + 0.05
      end
    until ele or totalDelay > 0.9 or not pane:isValid()
    if ele then
      if OS_VERSION >= OS.Tahoe then index = index + 1 end
      local act = ele:actionNames()[index]
      ele:performAction(act)
    end
  end

  if app:mainWindow() then
    pane = getc(appUI, AX.Window, 1)
    if OS_VERSION >= OS.Ventura then
      pane = getc(pane, AX.Group, 1)
    end
    if panel == "Hearing" then
      if #pane == 1 and pane[1].AXRole == AX.ScrollArea then
        pane = pane[1]
      end
    end
    if testAlready("Wi‑Fi", pane, AX.CheckBox)
        and testAlready("Bluetooth", pane, AX.CheckBox) then
      enterPanel()
      registerControlCenterHotKeys(panel)
      return
    elseif testAlready(panel, pane) and not allowReentry then
      return
    end
  end

  local locPanel = controlCenterLocalized(panel)
  local index
  local menuBarItems = getc(toappui(app), AX.MenuBar, -1, AX.MenuBarItem)
  if OS_VERSION >= OS.Tahoe then
    menuBarItems = tifilter(menuBarItems, function(item)
      return item.AXIdentifier ~= nil
    end)
  end
  for i, elem in ipairs(menuBarItems) do
    if elem.AXDescription and elem.AXDescription:find(locPanel) then
      index = i break
    end
  end
  if index then
    clickRightMenuBarItem({'com.apple.controlcenter', index},
                          {}, OS_VERSION >= OS.Tahoe and "click" or nil)
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
    enterPanel()
    registerControlCenterHotKeys(panel)
  end
end

local controlCenterPanels = {
  "Accessibility Shortcuts", "AirDrop", "Battery", "Bluetooth",
  "Display", "Focus", "Hearing", "Keyboard Brightness",
  "Now Playing", "Screen Mirroring", "Sound",
  "Users", "Wi‑Fi"
}
if OS_VERSION >= OS.Tahoe then
  tinsert(controlCenterPanels, "Recognize Music")
else
  tinsert(controlCenterPanels, "Music Recognition")
end
for _, panel in ipairs(controlCenterPanels) do
  bindControlCenterURL(panel, bind(popupControlCenterSubPanel, panel))
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
  if OS_VERSION >= OS.Ventura then
    pane = getc(pane, AX.Group, 1)
    if panel == "Hearing" then
      while #pane == 0 do
        hs.timer.usleep(0.05 * 1000000)
      end
      if #pane == 1 and pane[1].AXRole == AX.ScrollArea then
        pane = pane[1]
      end
    end
  end

  local function mayLocalize(value)
    return controlCenterLocalized(panel, value)
  end

  if controlCenterHotKeys ~= nil then
    for _, hotkey in ipairs(controlCenterHotKeys) do
      hotkey:delete()
    end
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

  -- back to main panel
  if not inMenuBar then
    local msg = "Back"
    local appLocale = applicationValidLocale('com.apple.controlcenter')
    if appLocale ~= nil then
      local result = localizedString(msg, 'com.apple.AppStore',
                                     { locale = appLocale })
      if result ~= nil then
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

  -- jump to related panel in `System Preferences`
  if tcontain({ "Wi‑Fi", "Bluetooth", "Focus", "Keyboard Brightness",
                "Screen Mirroring", "Display", "Sound",
                "Accessibility Shortcuts", "Battery",
                "Hearing", "Users", }, panel) then
    local button, title
    repeat
      hs.timer.usleep(0.05 * 1000000)
      local buttons = getc(pane, AX.Button)
      for i = #buttons, 1, -1 do
        title = OS_VERSION < OS.Ventura and buttons[i].AXTitle
            or buttons[i].AXAttributedDescription:getString()
        if title:find("…") then
          button = buttons[i]
          break
        end
      end
    until button or not pane:isValid()
    if button then
      local hotkey = newControlCenter("⌘", ",", title,
          function() button:performAction(AX.Press) end)
      if not checkAndRegisterControlCenterHotKeys(hotkey) then
        return
      end
    end
  end

  -- pandel with a switch-off button
  if tcontain({"Wi‑Fi", "Bluetooth", "AirDrop"}, panel) then
    local checkbox
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      checkbox = tfind(getc(appUI, AX.Window, 1, AX.CheckBox), function(cb)
        return cb.AXIdentifier ~= nil and cb.AXIdentifier:find("%-header") ~= nil
      end)
      if checkbox == nil then
        checkbox = tfind(getc(appUI, AX.Window, 1, AX.Group, 1, AX.CheckBox), function(cb)
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

  -- panel with a slider
  if tcontain({"Display", "Sound", "Keyboard Brightness"}, panel) then
    local name = panel == "Sound" and "Volume" or "Brightness"
    local actions = {{ '=', 'Up'}, {'-', 'Down'}}
    if OS_VERSION < OS.Tahoe then
      tconcat(actions, {{'[', 'Min'}, {']', 'Max'}})
    end
    local enabledSliders
    repeat
      hs.timer.usleep(0.05 * 1000000)
      if panel == "Display" then
        local role = OS_VERSION < OS.Ventura and AX.ScrollArea or AX.Group
        enabledSliders = getc(pane, role, 1, AX.Slider)
      else
        enabledSliders = getc(pane, AX.Slider)
      end
    until enabledSliders and #enabledSliders > 0 or not pane:isValid()
    if #enabledSliders == 1 then
      for _, spec in ipairs(actions) do
        local key = spec[1]
        local msg = name .. ' ' .. spec[2]
        local slid = enabledSliders[1]
        local hotkey = newControlCenter("", key, msg,
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
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      end
    end
  end

  -- panel with a list of devices
  if tcontain({"Bluetooth", "Sound", "Screen Mirroring"}, panel) then
    local cbs
    local totalDelay = 0
    repeat
      hs.timer.usleep(0.05 * 1000000)
      totalDelay = totalDelay + 0.05
      cbs = tifilter(getc(pane, AX.ScrollArea, 1, AX.CheckBox) or {},
          function(cb) return cb.AXEnabled end)
      if #cbs == 0 and panel == "Screen Mirroring" then
        cbs = tifilter(getc(pane, AX.ScrollArea, 1,
            AX.Group, 1, AX.CheckBox) or {},
          function(cb) return cb.AXEnabled end)
      end
    until #cbs > 0 or totalDelay > 1 or not pane:isValid()
    if #cbs > 0 then
      for i=1, math.min(#cbs, 10) do
        local enabled = cbs[i].AXValue
        local name
        if OS_VERSION < OS.Ventura then
          name = cbs[i].AXTitle
        elseif panel == "Bluetooth" and OS_VERSION >= OS.Tahoe then
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

  if panel == "Wi‑Fi" then
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
        for idx, cb in ipairs(getc(sa, AX.CheckBox)) do
          local ft = OS_VERSION < OS.Ventura and cb.AXTitle or cb.AXIdentifier
          if idx > 10 then break end
          local title
          if OS_VERSION < OS.Ventura then
            title = ft:match("([^,]+)")
          else
            title = ft:sub(string.len("wifi-network-") + 1, -1)
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
          for idx, title in ipairs(availableNetworks) do
            local selected = getc(sa, AX.CheckBox, idx).AXValue
            local msg = "Connect to " .. title
            if selected == nil or selected == 1 then
              msg = "Disconnect to " .. title
            end
            local hotkey = newControlCenter("", tostring(idx % 10), msg,
              function()
                local cb = getc(sa, AX.CheckBox, idx)
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
  elseif panel == "Focus" then
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
  elseif panel == "Display" then
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
  elseif panel == "Recognize Music" or panel == "Music Recognition" then
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
  elseif panel == "Hearing" then
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
  elseif panel == "Now Playing" then
    local result
    local button3
    repeat
      hs.timer.usleep(0.05 * 1000000)
      if OS_VERSION >= OS.Tahoe then
        button3 = getc(pane, AX.Group, 1, AX.Button, 3)
      else
        button3 = getc(pane, AX.Button, 3)
      end
    until button3 or not pane:isValid()
    if button3 then
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
            if defaultMusicAppForControlCenter ~= nil then
              local appname = displayName('com.apple.Music')
              local appTitle = getc(pane, AX.StaticText, 1)
              if appTitle and appTitle.AXValue == appname .. '.app' then
                if type(defaultMusicAppForControlCenter) == 'string' then
                  defaultMusicAppForControlCenter =
                      { defaultMusicAppForControlCenter }
                end
                for _, appid in ipairs(defaultMusicAppForControlCenter) do
                  local appPath = hs.application.pathForBundleID(appid)
                  if appPath ~= nil and appPath ~= "" then
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
        hotkey = newControlCenter("", "Left", result[1],
          function()
            local button = getc(pane, AX.Button, 1)
            if button then button:performAction(AX.Press) end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
        hotkey = newControlCenter("", "Right", result[3],
          function()
            local button = getc(pane, AX.Button, 3)
            if button then button:performAction(AX.Press) end
          end)
        if not checkAndRegisterControlCenterHotKeys(hotkey) then
          return
        end
      elseif (type(result) == "number" and result > 3)
          or (type(result) == "table" and #result > 3) then
        local nEntries
        if type(result) == "number" then
          nEntries = result / 2
        else
          nEntries = #result / 2
        end
        local hotkey
        for i = 1, nEntries do
          local buttonLabel = mayLocalize("play")
              .. "/" .. mayLocalize("pause")
          hotkey = newControlCenter("", tostring(i),
            type(result) == "number" and buttonLabel or result[2*i-1],
            function()
              local button = getc(pane, AX.Button, 2 * i - 1)
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
      if win and win:title() == localizedString("Control Center",
          controlCenter:bundleID()) then
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
