local logger = require("logger")
local function yes() return true end

return function(class)
    logger.info("mixins/network_detect: Detecting network backend...")
    if os.execute("LD_LIBRARY_PATH= nmcli --terse --fields=running general &>/dev/null") == 0 then
        logger.info("  -> nmcli")
        require("device/mixins/network_nmcli")(class)
    else
        logger.info("  -> none")
    end
end
