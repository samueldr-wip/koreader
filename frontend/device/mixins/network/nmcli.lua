local util = require("frontend/util")
local logger = require("logger")
local _ = require("gettext")
local JSON = require("json")
local BSSID_PATTERN = table.concat({
    "%x%x",
    "%x%x",
    "%x%x",
    "%x%x",
    "%x%x",
    "%x%x",
}, ".:")

local function snarf(cmd)
    -- logger.info("network_nmcli: $ ", cmd)
    local std_out = io.popen("LD_LIBRARY_PATH= " .. cmd)
    if not std_out then
        return
    end
    local str = util.trim(std_out:read("*all"))
    -- logger.info("network_nmcli: <- ", JSON.encode(str))
    std_out:close()
    return str
end

local function nmcli(cmd)
    if type(cmd) == "string" then
        return snarf("nmcli --terse --color=no " .. cmd)
    else
        return snarf(util.shell_escape({"nmcli", "--terse", "--color=no", table.unpack(cmd)}))
    end
end

local function yes() return true end

---
-- Mixin adding the required `initNetworkManager` for NetworkManager (the Linux thing).
return function(class)
    -- Skip adding this Mixin if there is no WiFi hardware.
    if nmcli({"--fields=wifi-hw", "general"}) ~= "enabled" then
        return
    end

    class.hasWifiToggle = yes
    class.hasWifiManager = yes

    function class:initNetworkManager(NetworkMgr)
        function NetworkMgr:isWifiOn()
            local status = nmcli({"radio", "wifi"})

            return status == "enabled"
        end

        ---
        -- Turns off the Wifi hardware.
        function NetworkMgr:turnOffWifi(complete_callback)
            nmcli({"radio", "wifi", "off"})

            if complete_callback then
                complete_callback()
            end
        end

        ---
        -- Turns on the Wifi hardware.
        -- Connection to a known network happens in the background.
        function NetworkMgr:turnOnWifi(complete_callback)
            nmcli({"radio", "wifi", "on"})

            self:reconnectOrShowNetworkMenu(complete_callback)
        end

        ---
        -- Handles showing the network scan menu if needed, but not the other complex behaviour in NetworkMgr.
        function NetworkMgr:reconnectOrShowNetworkMenu(complete_callback)
            -- Requiring these globally causes a reference loop since they depend on device
            local InfoMessage = require("ui/widget/infomessage")
            local UIManager = require("ui/uimanager")

            local info = InfoMessage:new{text = _("Scanning for networks…")}
            UIManager:show(info)
            UIManager:nextTick(function()
                network_list, err = self:getNetworkList()
                UIManager:close(info)

                if network_list == nil then
                    UIManager:show(InfoMessage:new{text = err})
                    return
                end

                if self.wifi_toggle_long_press then
                    self.wifi_toggle_long_press = nil
                    UIManager:show(require("ui/widget/networksetting"):new{
                        force_selection = true,
                        network_list = network_list,
                        connect_callback = complete_callback,
                    })
                end
                if complete_callback then
                    complete_callback()
                end
            end)
        end

        ---
        -- Returns the first wifi device name
        function NetworkMgr:getNetworkInterfaceName()
            return nmcli("--fields=type,device device | grep ^wifi: | head -n1 | cut -d: -f2-")
        end

        function NetworkMgr:isConnected()
            return nmcli({"networking", "connectivity", "check"}) == "full"
        end

        function NetworkMgr:disconnectNetwork(network)
            nmcli({"device", "disconnect", self:getNetworkInterfaceName()})
        end

        function NetworkMgr:getCurrentNetwork()
            return nmcli({"--get-values=GENERAL.CONNECTION", "device", "show", self:getNetworkInterfaceName()})
        end

        function NetworkMgr:_getKnownNetworks()
            local known_networks = {}

            data = nmcli("--fields=type,name connection show --order type:active:name | grep '^802-11-wireless:' | cut -d':' -f2-")
            -- Lists all networks keyed by SSID (name)
            -- This is probably slightly incorrect since it does not consider identical names with different BSSID/psks as different networks.
            for name in string.gmatch(data, "([^\n]+)") do
                local network = {
                    name = name,
                    ssid = nmcli({"--get-values=802-11-wireless.ssid", "connection", "show", name}),
                    psk = nmcli({"--show-secrets", "--get-values=802-11-wireless-security.psk", "connection", "show", name}),
                }
                known_networks[network["ssid"]] = network
            end

            self._known_networks = known_networks

            return known_networks
        end

        function NetworkMgr:getNetworkList()
            local list = {}
            local known_networks = self:_getKnownNetworks()
            local ifname = self:getNetworkInterfaceName()

            -- 58:WPA2:pair_ccmp group_ccmp psk:SSIDNAME
            local data = nmcli({"--fields=active,signal,security,rsn-flags,bssid,ssid", "device", "wifi", "list", "ifname", ifname, "--rescan", "yes"})
            for line in string.gmatch(data, "([^\n]+)") do
                local active, signal, security, flags, bssid, ssid = string.match(line, "([^:]*):([^:]*):([^:]*):([^:]*):("..BSSID_PATTERN.."):(.*)")
                signal = tonumber(signal)

                bssid = bssid:gsub("\\:", ":")

                -- Skip networks without SSIDs
                if ssid ~= "" then
                    local network = {
                        ssid = ssid,
                        bssid = bssid,
                        connected = active == "yes",
                        security = security,
                        flags = "["..security.."]["..flags.."]",
                        -- We don't have signal level with nmcli
                        --signal_level = -258,
                        signal_quality = signal,
                    }
                    if known_networks[ssid] then
                        network["password"] = known_networks[ssid]["psk"]
                    end
                    table.insert(list, network)
                end
            end

            return list
        end

        function NetworkMgr:authenticateNetwork(network)
            -- Requiring these globally causes a reference loop since they depend on device
            local InfoMessage = require("ui/widget/infomessage")
            local UIManager = require("ui/uimanager")

            -- Re-use the existing listing
            local known_networks = self._known_networks or {}
            local ifname = self:getNetworkInterfaceName()

            local ssid = network["ssid"]
            local known_network = false
            local different_password = false

            local info = InfoMessage:new{text = _("Authenticating…")}
            UIManager:show(info)
            UIManager:forceRePaint()

            -- Connecting to a known network without modifications
            if known_networks[ssid] then
                known_network = true
            end
            if known_networks[ssid] and network["password"] and known_networks[ssid]["psk"] ~= network["password"] then
                different_password = true
            end
            logger.info("authenticateNetwork", JSON.encode(network))

            -- Adding a network, or modifying a network
            if not known_network or different_password then
                -- Update the known network password
                -- Otherwise editing the value in the connection list may fail
                known_networks[ssid]["psk"] = network["password"]

                local cmd = {"connection"}
                if known_network then
                    -- We're modifying
                    table.insert(cmd, "modify")
                    table.insert(cmd, "id")
                    table.insert(cmd, ssid)
                else
                    -- We're adding
                    table.insert(cmd, "add")
                    table.insert(cmd, "con-name")
                    table.insert(cmd, ssid)
                    table.insert(cmd, "type")
                    table.insert(cmd, "wifi")
                    table.insert(cmd, "ssid")
                    table.insert(cmd, ssid)
                end

                if network["password"] then
                    -- https://developer-old.gnome.org/NetworkManager/stable/settings-802-11-wireless-security.html
                    if network["security"]:match("^WPA") then
                        table.insert(cmd, "wifi-sec.key-mgmt")
                        table.insert(cmd, "wpa-psk")
                        table.insert(cmd, "wifi-sec.psk")
                        table.insert(cmd, network["password"])
                    elseif network["security"]:match("WEP") then
                        -- TODO: verify that this is correct
                        table.insert(cmd, "wifi-sec.key-mgmt")
                        table.insert(cmd, "none")
                        table.insert(cmd, "wifi-sec.wep-key-type")
                        table.insert(cmd, "1") -- NM_WEP_KEY_TYPE_KEY
                        table.insert(cmd, "wifi-sec.wep-key0")
                        table.insert(cmd, network["password"])
                    end
                end
                nmcli(cmd)
            end

            local ret = nmcli({"connection", "up", ssid, "ifname", ifname})

            UIManager:close(info)
            UIManager:forceRePaint()

            if ret:match("^Connection successfully activated.*") then
                return true
            end

            return false, ret
        end

        function NetworkMgr:obtainIP()
            -- no-op, handled by NM
        end

        function NetworkMgr:releaseIP()
            -- no-op, handled by NM
        end

        function NetworkMgr:restoreWifiAsync()
            -- no-op, happens implicitly with NM
        end
    end
end
