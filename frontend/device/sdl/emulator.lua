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

	require("device/mixins/network_dummy")(Emulator)

	return Emulator
end
