local logger = require("logger")
local clock_timedatectl = require("device/mixins/clock_timedatectl")
local clock_hwclock = require("device/mixins/clock_hwclock")
local clock_none = function() end

return function(class)
		logger.info("mixins/clock_detect: Detecting clock backend...")
		if os.execute("timedatectl show &>/dev/null") == 0 then
			logger.info("  -> timedatectl")
			return clock_timedatectl(class)
		elseif os.execute("hwclock -r &>/dev/null") == 0 then
			logger.info("  -> hwclock")
			return clock_hwclock(class)
		else
			logger.info("  -> none")
			return clock_none(class)
		end
end

