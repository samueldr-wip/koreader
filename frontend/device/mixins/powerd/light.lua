local logger = require("logger")
local Math = require("optmath")

---
-- Extends the given table, expected to be a PowerD, to enable backlight control using `light`.
return function(class)
    ---
    -- PowerD mixin using `light` to control the backlight.
    local LightPowerD = class:new{
        -- Light operates on a range of 0 to 100.
        fl_min = 0,
        fl_max = 100,
        -- So we'll also operate on a warmth mix from 0 to 100
        fl_warmth_min = 0,
        fl_warmth_max = 100,
    }

    ---
    -- Converts from a sysfs path to a light-compatible target
    function _sysfs_to_light_param(path)
        return path:gsub("^/sys/class/backlight/", "sysfs/backlight/")
    end

    function LightPowerD:init()
        local config = self.device.frontlight_settings or {}
        self.config = config
        if self.device.hasNaturalLight() then
            if not config.frontlight_warm or not config.frontlight_cool then
                logger.warn("LightPowerD: Device declares hasNaturalLight, but does not configure warm or cool light.")
            end
        end
        class.init(self, config)
    end

    -- Query `light` with useful defaults
    function LightPowerD:_light(args)
        local cmd = "light " .. args
        local handle = io.popen(cmd, "r")
        if not handle then return end
        local output = handle:read("*all")
        handle:close()
        return output
    end
    function LightPowerD:_light_warm(args)
        local node = _sysfs_to_light_param(self.config.frontlight_warm)
        return self:_light("-s ".. node .." "..args)
    end
    function LightPowerD:_light_cool(args)
        local node = _sysfs_to_light_param(self.config.frontlight_cool)
        return self:_light("-s ".. node .." "..args)
    end

    function LightPowerD:frontlightIntensityHW()
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

    function LightPowerD:setIntensityHW(intensity)
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

    function LightPowerD:frontlightWarmthHW()
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

    function LightPowerD:setWarmthHW(warmth)
        if not self.device.hasNaturalLight() then
            return
        end

        self:setIntensityHW()
    end

    return LightPowerD
end
