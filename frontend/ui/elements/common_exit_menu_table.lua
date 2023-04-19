local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local exit_settings = {}

-- If only exit is available
local short_exit_menu = true

exit_settings.exit_menu = {
    text = _("Exit"),
    hold_callback = function()
        if Device:canExit() then
            UIManager:broadcastEvent(Event:new("Exit"))
        end
    end,
    -- submenu entries will be appended by xyz_menu_order_lua
}
if Device:canExit() then
    exit_settings.exit = {
        text = _("Exit"),
        callback = function()
            UIManager:broadcastEvent(Event:new("Exit"))
        end,
    }
end
if Device:canRestart() then
    short_exit_menu = false
    exit_settings.restart_koreader = {
        text = _("Restart KOReader"),
        callback = function()
            UIManager:broadcastEvent(Event:new("Restart"))
        end,
    }
end
if Device:canSuspend() then
    short_exit_menu = false
    exit_settings.sleep = {
        text = _("Sleep"),
        callback = function()
            UIManager:suspend()
        end,
    }
end
if Device:canReboot() then
    short_exit_menu = false
    exit_settings.reboot = {
        text = _("Reboot the device"),
        keep_menu_open = true,
        callback = function()
            UIManager:askForReboot()
        end
    }
end
if Device:canPowerOff() then
    short_exit_menu = false
    exit_settings.poweroff = {
        text = _("Power off"),
        keep_menu_open = true,
        callback = function()
            UIManager:askForPowerOff()
        end
    }
end

if short_exit_menu then
    exit_settings.exit_menu = exit_settings.exit
    exit_settings.exit = nil
    exit_settings.restart_koreader = nil
end

return exit_settings
