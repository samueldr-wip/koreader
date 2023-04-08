return function(class)
	class.setDateTime = function(self, year, month, day, hour, min, sec)
		if hour == nil or min == nil then return true end
		local command
		if year and month and day then
			command = string.format("timedatectl set-time '%d-%d-%d %d:%d:%d'", year, month, day, hour, min, sec)
		else
			command = string.format("timedatectl set-time '%d:%d'",hour, min)
		end
		return os.execute(command) == 0
	end
end
