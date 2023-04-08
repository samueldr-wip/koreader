return function(SdlDevice)
	local Emulator = SdlDevice:extend{
		model = "Emulator",
		isEmulator = yes,
		hasBattery = yes,
		hasEinkScreen = yes,
		hasFrontlight = yes,
		hasNaturalLight = yes,
		hasNaturalLightApi = yes,
		hasWifiToggle = yes,
		-- Not really, SdlDevice:reboot & SdlDevice:powerOff are not implemented, so we just exit ;).
		canPowerOff = yes,
		canReboot = yes,
		-- NOTE: Via simulateSuspend
		canSuspend = yes,
		canStandby = no,
	}

	function Emulator:supportsScreensaver() return true end

	function Emulator:simulateSuspend()
		local Screensaver = require("ui/screensaver")
		Screensaver:setup()
		Screensaver:show()
	end

	function Emulator:simulateResume()
		local Screensaver = require("ui/screensaver")
		Screensaver:close()
	end

	-- fake network manager for the emulator
	function Emulator:initNetworkManager(NetworkMgr)
		local UIManager = require("ui/uimanager")
		local connectionChangedEvent = function()
			if G_reader_settings:nilOrTrue("emulator_fake_wifi_connected") then
				UIManager:broadcastEvent(Event:new("NetworkConnected"))
			else
				UIManager:broadcastEvent(Event:new("NetworkDisconnected"))
			end
		end
		function NetworkMgr:turnOffWifi(complete_callback)
			G_reader_settings:flipNilOrTrue("emulator_fake_wifi_connected")
			UIManager:scheduleIn(2, connectionChangedEvent)
		end
		function NetworkMgr:turnOnWifi(complete_callback)
			G_reader_settings:flipNilOrTrue("emulator_fake_wifi_connected")
			UIManager:scheduleIn(2, connectionChangedEvent)
		end
		function NetworkMgr:isWifiOn()
			return G_reader_settings:nilOrTrue("emulator_fake_wifi_connected")
		end
		NetworkMgr.isConnected = NetworkMgr.isWifiOn
	end

	return Emulator
end
