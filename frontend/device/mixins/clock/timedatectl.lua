local logger = require("logger")

return function(class)
	class.setDateTime = function(self, year, month, day, hour, min, sec)
		if hour == nil or min == nil then
			-- Detect if we can change the time
			result = os.execute("timedatectl show | grep ^NTP=yes &> /dev/null") ~= 0
			if not result then
				logger.info("mixins/clock_timedatectl: Automatic time synchronization is enabled; clock backend disabled")
			end
			return result
		end
		local command
		if year and month and day then
			command = string.format("timedatectl set-time '%d-%d-%d %d:%d:%d'", year, month, day, hour, min, sec)
		else
			command = string.format("timedatectl set-time '%d:%d'",hour, min)
		end
		return os.execute(command) == 0
	end
end
