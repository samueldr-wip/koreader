local logger = require("logger")
local powerd_light = require("device/mixins/powerd/light")
local powerd_none = function(class) return class end

return function(class)
    -- TODO: Detect the actual *power* part of PowerD here before the frontlight part.

    logger.info("mixins/powerd/detect: Detecting PowerD frontlight backend...")
    if os.execute("light -L &>/dev/null") == 0 then
        logger.info("  -> light")
        return powerd_light(class)
    else
        logger.info("  -> none")
        return powerd_none(class)
    end
end
