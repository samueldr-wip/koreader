local FFIUtil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local T = FFIUtil.template
local sleep = FFIUtil.sleep

local wifi_on = false
local network_connected = false

---
-- Mixin adding the required `initNetworkManager` for a fake connection process example.
--
-- This is useful only for development.
return function(class)
    class.hasWifiToggle = yes
    class.hasWifiManager = yes

    function class:initNetworkManager(NetworkMgr)
        logger.info("network_dummy: initNetworkManager")

        function NetworkMgr:turnOffWifi(complete_callback)
            logger.info("network_dummy: turnOffWifi")
            sleep(1)
            self:disconnectNetwork()
            wifi_on = false
            if complete_callback then
                complete_callback()
            end
        end

        function NetworkMgr:turnOnWifi(complete_callback)
            logger.info("network_dummy: turnOnWifi")
            sleep(1)
            wifi_on = true
            self:reconnectOrShowNetworkMenu(complete_callback)
        end

        function NetworkMgr:getNetworkInterfaceName()
            return "wlan0-dummy"
        end

        function NetworkMgr:obtainIP()
            logger.info("network_dummy: obtainIP")
        end

        function NetworkMgr:releaseIP()
            logger.info("network_dummy: releaseIP")
        end

        function NetworkMgr:restoreWifiAsync()
            logger.info("network_dummy: restoreWifiAsync")
        end

        function NetworkMgr:isWifiOn()
            return wifi_on
        end

        --NetworkMgr:setWirelessBackend("wpa_supplicant", {ctrl_interface = "/var/run/wpa_supplicant/wlan0"})
        function NetworkMgr:getNetworkList()
            logger.info("network_dummy: getNetworkList")
            sleep(1)
            local list = {
                {
                    ssid = "Dummy Network",
                    connected = network_connected,
                    flags = "[WPA2-PSK-CCMP][ESS]",
                    signal_level = -58,
                    signal_quality = 84,
                    password = "12345678", -- This means the network is already saved in the backend...
                },
                {
                    ssid = "Other Network",
                    connected = false,
                    flags = "[WPA2-PSK-CCMP][ESS]",
                    signal_level = -258,
                    signal_quality = 30,
                },
            }
            return list
        end
        function NetworkMgr:getCurrentNetwork()
            return "Dummy Network"
        end
        function NetworkMgr:authenticateNetwork(network)
            -- Requiring these globally causes a reference loop since they depend on device
            local InfoMessage = require("ui/widget/infomessage")
            local UIManager = require("ui/uimanager")

            network_connected = false
            logger.info("network_dummy: authenticateNetwork")

            local info = InfoMessage:new{text = _("Authenticating…")}
            UIManager:show(info)
            UIManager:forceRePaint()

            sleep(1)
            UIManager:close(info)
            UIManager:forceRePaint()

            if network.ssid == "Dummy Network" then
                network_connected = true

                return true
            end

            -- Development aide only, no need to translate...
            return false, "[Only allowed to connect to Dummy Network]"
        end
        function NetworkMgr:disconnectNetwork(network)
            logger.info("network_dummy: disconnectNetwork")
            network_connected = false
        end

        function NetworkMgr:isConnected()
            return network_connected
        end

        function NetworkMgr:isNetworkInfoAvailable()
            return network_connected
        end
    end
end
