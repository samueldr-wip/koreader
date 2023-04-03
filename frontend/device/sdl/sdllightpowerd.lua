local logger = require("logger")
local SDLPowerD = require("device/sdl/powerd")
local Math = require("optmath")

---
-- SDLPowerD backend using `light` to control the backlight.
local SDLLightPowerD = SDLPowerD:new{
	-- Light operates on a range of 0 to 100.
	fl_min = 0,
	fl_max = 100,
	-- So we'll also operate on a warmth mix from 0 to 100
	fl_warmth_min = 0,
	fl_warmth_max = 100,
}

function SDLLightPowerD:init()

	local config = self.device.lightPowerDConfig or {}
	self.config = config
	if self.device.hasNaturalLight() then
		if not config.warm or not config.cool then
			logger.warn("SDLLightPowerD: Device declares hasNaturalLight, but does not configure warm or cool light.")
		end
	end

	SDLPowerD.init(self, config)
end

-- Query `light` with useful defaults
function SDLLightPowerD:_light(args)
	local cmd = "light " .. args
	local handle = io.popen(cmd, "r")
	if not handle then return end
	local output = handle:read("*all")
	handle:close()
	return output
end
function SDLLightPowerD:_light_warm(args)
	local node = self.config.warm
	return self:_light("-s ".. node .." "..args)
end
function SDLLightPowerD:_light_cool(args)
	local node = self.config.cool
	return self:_light("-s ".. node .." "..args)
end

function SDLLightPowerD:frontlightIntensityHW()
	local intensity = 0

	if self.device.hasNaturalLight() then
		local warm_intensity = Math.round(tonumber(self:_light_warm("-G")) or 0)
		local cool_intensity = Math.round(tonumber(self:_light_cool("-G")) or 0)
		intensity = math.max(warm_intensity, cool_intensity)
	else
		intensity = Math.round(tonumber(self:_light("-G")) or 0)
	end

	return intensity
end

function SDLLightPowerD:setIntensityHW(intensity)
	SDLPowerD:setIntensityHW(intensity)
	intensity = intensity or self.fl_intensity

	if not self.device.hasNaturalLight() then
		self:_light("-S " .. intensity)
		return
	end

	local fl_warmth = self.fl_warmth

	local cool_intensity = 0
	local warm_intensity = 0

	if fl_warmth > 50 then
		warm_intensity = intensity
		cool_intensity = intensity - (intensity * (fl_warmth - 50)/50)
	else
		warm_intensity = intensity * fl_warmth/50
		cool_intensity = intensity
	end

	self:_light_warm("-S " .. warm_intensity)
	self:_light_cool("-S " .. cool_intensity)
end

function SDLLightPowerD:frontlightWarmthHW()
	if not self.device.hasNaturalLight() then
		return 0
	end

	local warm = math.ceil(tonumber(self:_light_warm("-G")) or 0)
	local cool = math.ceil(tonumber(self:_light_cool("-G")) or 0)
	if warm == 0 and cool == 0 then
		return 0
	end

	if warm > cool then
		return 50 + 50 * (cool/warm)
	else
		return      50 * (warm/cool)
	end
end

function SDLLightPowerD:setWarmthHW(warmth)
	if not self.device.hasNaturalLight() then
		return
	end

	self:setIntensityHW()
end

return SDLLightPowerD
