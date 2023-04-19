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

    function Emulator:setEventHandlers(UIManager)
        if not self:canSuspend() then
            -- If we can't suspend, we have no business even trying to, as we may not have overloaded `SdlDevice:simulateResume`.
            -- Instead, rely on the Generic Suspend/Resume handlers.
            return
        end

        UIManager.event_handlers.Suspend = function()
            self:_beforeSuspend()
            self:simulateSuspend()
        end
        UIManager.event_handlers.Resume = function()
            self:simulateResume()
            self:_afterResume()
        end
        UIManager.event_handlers.PowerRelease = function()
            -- Resume if we were suspended
            if self.screen_saver_mode then
                UIManager.event_handlers.Resume()
            else
                UIManager.event_handlers.Suspend()
            end
        end
    end

	require("device/mixins/network_dummy")(Emulator)

	return Emulator
end
