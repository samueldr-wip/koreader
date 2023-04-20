return function(class)
	class.setDateTime = function(self, year, month, day, hour, min, sec)
		if hour == nil or min == nil then return true end
		local command
		if year and month and day then
			command = string.format("date -s '%d-%d-%d %d:%d:%d'", year, month, day, hour, min, sec)
		else
			command = string.format("date -s '%d:%d'",hour, min)
		end
		if os.execute(command) == 0 then
			os.execute("hwclock -u -w")
			return true
		else
			return false
		end
	end
end
