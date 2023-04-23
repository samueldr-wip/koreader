local Event = require("ui/event")
local Generic = require("device/generic/device")
local SDL = require("ffi/SDL2_0")
local ffi = require("ffi")
local logger = require("logger")
local util = require("util")
local time = require("ui/time")
local _ = require("gettext")
local JSON = require("json")

-- SDL computes WM_CLASS on X11/Wayland based on process's binary name.
-- Some desktop environments rely on WM_CLASS to name the app and/or to assign the proper icon.
if jit.os == "Linux" or jit.os == "BSD" or jit.os == "POSIX" then
    if not os.getenv("SDL_VIDEO_WAYLAND_WMCLASS") then ffi.C.setenv("SDL_VIDEO_WAYLAND_WMCLASS", "KOReader", 1) end
    if not os.getenv("SDL_VIDEO_X11_WMCLASS") then ffi.C.setenv("SDL_VIDEO_X11_WMCLASS", "KOReader", 1) end
end

local function yes() return true end
local function no() return false end
local function notOSX() return jit.os ~= "OSX" end

local function isUrl(s)
    return type(s) == "string" and s:match("*?://")
end

local function isCommand(s)
    return os.execute("command -v "..s.." >/dev/null") == 0
end

local function runCommand(command)
    local env = jit.os ~= "OSX" and 'env -u LD_LIBRARY_PATH ' or ""
    return os.execute(env..command) == 0
end

local function getDesktopDicts()
    local t = {
        { "Goldendict", "Goldendict", false, "goldendict" },
    }
    -- apple dict is always present in osx
    if jit.os == "OSX" then
        table.insert(t, 1, { "Apple", "AppleDict", false, "dict://" })
    end
    return t
end

local function getLinkOpener()
    if jit.os == "Linux" and isCommand("xdg-open") then
        return true, "xdg-open"
    elseif jit.os == "OSX" and isCommand("open") then
        return true, "open"
    end
    return false
end

-- thirdparty app support
local external = require("device/thirdparty"):new{
    dicts = getDesktopDicts(),
    check = function(self, app)
        if (isUrl(app) and getLinkOpener()) or isCommand(app) then
            return true
        end
        return false
    end,
}

local SDLDevice = Generic:extend{
    model = "SDL",
    isSDL = yes,
    home_dir = os.getenv("XDG_DOCUMENTS_DIR") or os.getenv("HOME"),
    hasBattery = SDL.getPowerInfo,
    hasKeyboard = yes,
    hasKeys = yes,
    hasDPad = yes,
    hasWifiToggle = no,
    isTouchDevice = yes,
    isDefaultFullscreen = no,
    needsScreenRefreshAfterResume = no,
    hasColorScreen = yes,
    hasEinkScreen = no,
    hasSystemFonts = yes,
    canSuspend = no,
    canStandby = no,
    startTextInput = SDL.startTextInput,
    stopTextInput = SDL.stopTextInput,
    canOpenLink = getLinkOpener,
    openLink = function(self, link)
        local enabled, tool = getLinkOpener()
        if not enabled or not tool or not link or type(link) ~= "string" then return end
        return runCommand(tool .. " '" .. link .. "'")
    end,
    canExternalDictLookup = yes,
    getExternalDictLookupList = function() return external.dicts end,
    doExternalDictLookup = function(self, text, method, callback)
        external.when_back_callback = callback
        local ok, app = external:checkMethod("dict", method)
        if app then
            if isUrl(app) and getLinkOpener() then
                ok = self:openLink(app..text)
            elseif isCommand(app) then
                ok = runCommand(app .. " " .. text .. " &")
            end
        end
        if ok and external.when_back_callback then
            external.when_back_callback()
            external.when_back_callback = nil
        end
    end,
    window = G_reader_settings:readSetting("sdl_window", {}),
}

function SDLDevice:init()
    -- allows to set a viewport via environment variable
    -- syntax is Lua table syntax, e.g. EMULATE_READER_VIEWPORT="{x=10,w=550,y=5,h=790}"
    local viewport = os.getenv("EMULATE_READER_VIEWPORT")
    if viewport then
        self.viewport = require("ui/geometry"):new(loadstring("return " .. viewport)())
    end

    local touchless = os.getenv("DISABLE_TOUCH") == "1"
    if touchless then
        self.isTouchDevice = no
    end

    local portrait = os.getenv("EMULATE_READER_FORCE_PORTRAIT")
    if portrait then
        self.isAlwaysPortrait = yes
    end

    self.hasClipboard = yes
    self.screen = require("ffi/framebuffer_SDL2_0"):new{
        device = self,
        debug = logger.dbg,
        w = self.window.width,
        h = self.window.height,
        x = self.window.left,
        y = self.window.top,
        is_always_portrait = self.isAlwaysPortrait(),
    }
    self.powerd = require("device/sdl/powerd"):new{device = self}

    local ok, re = pcall(self.screen.setWindowIcon, self.screen, "resources/koreader.png")
    if not ok then logger.warn(re) end

    local input = require("ffi/input")
    self.input = require("device/input"):new{
        device = self,
        event_map = require("device/sdl/event_map_sdl2"),
        handleSdlEv = function(device_input, ev)
            local Geom = require("ui/geometry")
            local UIManager = require("ui/uimanager")

            -- SDL events can remain cdata but are almost completely transparent
            local SDL_TEXTINPUT = 771
            local SDL_MOUSEWHEEL = 1027
            local SDL_MULTIGESTURE = 2050
            local SDL_DROPFILE = 4096
            local SDL_WINDOWEVENT_MOVED = 4
            local SDL_WINDOWEVENT_RESIZED = 5

            if ev.code == SDL_MOUSEWHEEL then
                local scrolled_x = ev.value.x
                local scrolled_y = ev.value.y

                local up = 1
                local down = -1

                local pos = Geom:new{
                    x = 0,
                    y = 0,
                    w = 0, h = 0,
                }

                local fake_ges = {
                    ges = "pan",
                    distance = 200,
                    relative = {
                        x = 50*scrolled_x,
                        y = 100*scrolled_y,
                    },
                    pos = pos,
                    time = time.timeval(ev.time),
                    mousewheel_direction = scrolled_y,
                }
                local fake_ges_release = {
                    ges = "pan_release",
                    distance = fake_ges.distance,
                    relative = fake_ges.relative,
                    pos = pos,
                    time = time.timeval(ev.time),
                    from_mousewheel = true,
                }
                local fake_pan_ev = Event:new("Pan", nil, fake_ges)
                local fake_release_ev = Event:new("Gesture", fake_ges_release)
                if scrolled_y == down then
                    fake_ges.direction = "north"
                    UIManager:broadcastEvent(fake_pan_ev)
                    UIManager:broadcastEvent(fake_release_ev)
                elseif scrolled_y == up then
                    fake_ges.direction = "south"
                    UIManager:broadcastEvent(fake_pan_ev)
                    UIManager:broadcastEvent(fake_release_ev)
                end
            elseif ev.code == SDL_MULTIGESTURE then
                -- no-op for now
                do end -- luacheck: ignore 541
            elseif ev.code == SDL_DROPFILE then
                local dropped_file_path = ev.value
                if dropped_file_path and dropped_file_path ~= "" then
                    local ReaderUI = require("apps/reader/readerui")
                    ReaderUI:doShowReader(dropped_file_path)
                end
            elseif ev.code == SDL_WINDOWEVENT_RESIZED then
                device_input.device.screen.screen_size.w = ev.value.data1
                device_input.device.screen.screen_size.h = ev.value.data2
                device_input.device.screen.resize(device_input.device.screen, ev.value.data1, ev.value.data2)
                self.window.width = ev.value.data1
                self.window.height = ev.value.data2

                local new_size = device_input.device.screen:getSize()
                logger.dbg("Resizing screen to", new_size)

                -- try to catch as many flies as we can
                -- this means we can't just return one ScreenResize or SetDimensons event
                UIManager:broadcastEvent(Event:new("SetDimensions", new_size))
                UIManager:broadcastEvent(Event:new("ScreenResize", new_size))
                --- @todo Toggle this elsewhere based on ScreenResize?

                -- this triggers paged media like PDF and DjVu to redraw
                -- CreDocument doesn't need it
                UIManager:broadcastEvent(Event:new("RedrawCurrentPage"))

                local FileManager = require("apps/filemanager/filemanager")
                if FileManager.instance then
                    FileManager.instance:reinit(FileManager.instance.path,
                        FileManager.instance.focused_file)
                end
            elseif ev.code == SDL_WINDOWEVENT_MOVED then
                self.window.left = ev.value.data1
                self.window.top = ev.value.data2
            elseif ev.code == SDL_TEXTINPUT then
                UIManager:sendEvent(Event:new("TextInput", tostring(ev.value)))
            end
        end,
        hasClipboardText = function()
            return input.hasClipboardText()
        end,
        getClipboardText = function()
            return input.getClipboardText()
        end,
        setClipboardText = function(text)
            return input.setClipboardText(text)
        end,
        gameControllerRumble = function(left_intensity, right_intensity, duration)
            return input.gameControllerRumble(left_intensity, right_intensity, duration)
        end,
        file_chooser = input.file_chooser,
    }

    self.keyboard_layout = require("device/sdl/keyboard_layout")

    if self.input.gameControllerRumble(0, 0, 0) then
        self.isHapticFeedbackEnabled = yes
        self.performHapticFeedback = function(type)
            self.input.gameControllerRumble()
        end
    end

    if portrait then
        self.input:registerEventAdjustHook(
            self.input.adjustTouchSwitchAxesAndMirrorX,
            (self.screen:getScreenWidth() - 1)
        )
    end

    Generic.init(self)
end

require("device/mixins/clock/detect")(SDLDevice)

-- Guess at the network backend to use
require("device/mixins/network/detect")(SDLDevice)

function SDLDevice:isAlwaysFullscreen()
    -- return true on embedded devices, which should default to fullscreen
    return self:isDefaultFullscreen()
end

function SDLDevice:toggleFullscreen()
    local current_mode = self.fullscreen or self:isDefaultFullscreen()
    local new_mode = not current_mode
    local ok, err = SDL.setWindowFullscreen(new_mode)
    if not ok then
        logger.warn("Unable to toggle fullscreen mode to", new_mode, "\n", err)
    else
        self.fullscreen = new_mode
    end
end

-- Devices extending SDLDevice

local Emulator = require("device/sdl/emulator")(SDLDevice)

local function ko_env(name, default_fn)
    return function()
        if os.getenv(name) then
            return false
        end

        return default_fn()
    end
end

local Desktop = SDLDevice:extend{
    model = "Generic (SDL "..SDL.getPlatform()..")",
    isDesktop = yes,
    canExit        = ko_env("KO_NO_EXIT", yes),
    canRestart     = ko_env("KO_NO_RESTART", notOSX),
    canSuspend     = ko_env("KO_NO_SUSPEND", notOSX),
    canReboot      = ko_env("KO_NO_REBOOT", notOSX),
    canPowerOff    = ko_env("KO_NO_POWEROFF", notOSX),
    -- On Linux desktop, different backends can control the backlight or frontlight.
    hasFrontlight  = notOSX,
}

function Desktop:suspend()
    os.execute("systemctl suspend")
end

function Desktop:powerOff()
    os.execute("systemctl poweroff")
end

function Desktop:reboot()
    os.execute("systemctl reboot")
end

function Desktop:onPowerPress()
    self:suspend()
end

function Desktop:onPowerLongPress()
    local UIManager = require("ui/uimanager")
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")

    if self._power_menu then
        UIManager:close(self._power_menu)
        return
    end

    buttons = {}
    if self:canSuspend() then
        table.insert(buttons, {
            {
                text = _("Suspend"),
                callback = function()
                    UIManager:nextTick(function()
                        self:suspend()
                        UIManager:close(self._power_menu)
                    end)
                end,
            },
        })
    end
    if self:canReboot() then
        table.insert(buttons, {
            {
                text = _("Reboot"),
                hidden = self:canReboot(),
                callback = function()
                    UIManager:nextTick(function()
                        self:reboot()
                        UIManager:close(self._power_menu)
                    end)
                end,
            },
        })
    end
    if self:canPowerOff() then
        table.insert(buttons, {
            {
                text = _("Power off"),
                hidden = self:canPowerOff(),
                callback = function()
                    UIManager:nextTick(function()
                        self:powerOff()
                        UIManager:close(self._power_menu)
                    end)
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:nextTick(function()
                    UIManager:close(self._power_menu)
                end)
            end,
        },
    })

    self._power_menu = ButtonDialogTitle:new{
        name = "power_menu",
        title = _("Power Menu"),
        title_align = "center",
        buttons = buttons,
        onCloseWidget = function()
            self._power_menu = nil
        end
    }
    UIManager:show(self._power_menu)
end

function Desktop:setEventHandlers(UIManager)
    -- Ensure SDLDevice:setEventHandlers isn't used.
    Generic.setEventHandlers(self, UIManager)
    local default_suspend = UIManager.event_handlers.Suspend;
    UIManager.event_handlers.Suspend = function()
        default_suspend()
        self:suspend()
    end
    UIManager.event_handlers.PowerPress = function()
        -- Ignore key repeat events
        if not self._current_power_press then
            self._current_power_press = time.now()
        end

        -- In ms, makes the following code easier to grok.
        local press_duration = (time.now() - self._current_power_press) / 1000
        if press_duration > 1000 and not self._current_power_long_press then
            self._current_power_long_press = true
            if self.onPowerLongPress then
                UIManager:nextTick(function()
                    self:onPowerLongPress()
                end)
            end
        end
    end
    UIManager.event_handlers.PowerRelease = function()
        if not self._current_power_press then return end

        if not self._current_power_long_press and self.onPowerPress then
            UIManager:nextTick(function()
                self:onPowerPress()
            end)
        end
        self._current_power_press = nil
        self._current_power_long_press = false
    end
end

local PineNote = Desktop:extend{
    model = "PineNote",
    hasKeyboard = no,
    hasKeys = no,
    hasDPad = no,
    hasEinkScreen = yes,
    hasColorScreen = no,
    -- NOTE: uses SDL.getPowerDevice()
    hasBattery = yes,
    hasFrontlight = yes,
    hasNaturalLight = yes,
    hasNaturalLightApi = yes,
    frontlight_settings = {
        frontlight_cool = "/sys/class/backlight/backlight_cool",
        frontlight_warm = "/sys/class/backlight/backlight_warm",
    },
}

function PineNote:init()
    Desktop.init(self)

    -- Add a temporary workaround to make full screen refreshes work better.
    -- The current driver doesn't implement ioctls to ask for specific waveforms and such.
    -- I'll note that it is possible the SDL implementation may not be suitable once
    -- such ioctls are available; we'd need to be able to configure the `RenderPresent`
    -- to send the right information when updating the display.
    logger.info("Adding quirk for EBC display refresh");
    local original_refreshFullImp = self.screen.refreshFullImp
    local function set_diff_mode(value)
        local f = io.open("/sys/module/rockchip_ebc/parameters/diff_mode", "w")
        if not f then return end
        f:write(value)
        f:close()
    end
    -- Unsetting auto-refresh will also reset its counter on next refresh
    local function set_autorefresh(value)
        local f = io.open("/sys/module/rockchip_ebc/parameters/auto_refresh", "w")
        if not f then return end
        f:write(value)
        f:close()
    end
    local previous_refresh_value = nil
    local function reset_config()
        set_diff_mode("1")
        -- Assume we want autorefresh on if for some reason we couldn't read what it was set to.
        if not previous_refresh_value then
            previous_refresh_value = "1"
        end
        set_autorefresh(previous_refresh_value)
    end

    self.screen.refreshFullImp = function(self, x, y, w, h, d)
        local bb = self.full_bb or self.bb
        original_refreshFullImp(self, x, y, w, h, d)

        -- Refresh the whole display if we made an actual full display update.
        -- (This approximately represents a page turn in my limited experience.)
        if w == bb:getWidth() and h == bb:getHeight() then
            local UIManager = require("ui/uimanager")

            local f = io.open("/sys/module/rockchip_ebc/parameters/auto_refresh", "r")
            if f then
                previous_refresh_value = util.trim(f:read("*all"))
                f:close()
            end

            -- By the time RenderPresent is called (after this function returns),
            -- we'll be in diff_mode == 0, so a flashing redraw will be made.
            set_diff_mode("0")
            -- Temporarily reset autorefresh too
            set_autorefresh("0")

            -- De-queue previously scheduled reset, if any
            UIManager:unschedule(reset_config)
            -- Some time after, we'll be back in partial redraw.
            UIManager:scheduleIn(0.5, reset_config)
            -- No, this is not good.
        end
    end
end

logger.info("Starting SDL in:", SDL.getBasePath())

-------------- device probe ------------
local model = nil

-- Allow overriding the model
if os.getenv("KO_MODEL") then
    logger.info("Using KO_MODEL as model...")
    model = os.getenv("KO_MODEL")
else
    logger.info("SDL device: Looking for a more specific model...")
end

-- Linux ARM devices are likely to be using Device Tree.
if not model and util.fileExists("/proc/device-tree/model") then
    logger.info("Using device-tree for model detection...")
    local file, err = io.open("/proc/device-tree/model", "r")
    if file then
        -- /proc/device-tree entries end with a NUL byte.
        -- We need to strip them for easier comparison later.
        model = file:read("*all"):gsub("%z", "")
    else
        logger.err("SDL device: failed to open /proc/device-tree/model", err)
    end
end

-- TODO: DMI model detection, if relevant (See /sys/class/dmi/)

-- Still no model? Assume a generic device or the Emulator.
if model == nil then
    if os.getenv("KO_MULTIUSER") or os.getenv("APPIMAGE") or os.getenv("UBUNTU_APPLICATION_ISOLATION") then
        model = "(Generic Desktop)"
    else
        model = "(Emulator)"
    end
end

-- Using JSON.encode here to ensure any control characters or whitespaces gets printed to the console.
logger.info("  model:", JSON.encode(model))

-- The actual backend used may be extended by the distribution method in use.
local device_backend = Desktop

if model == "(Emulator)" then
    device_backend = Emulator
elseif model:match("^Pine64 PineNote") then
    device_backend = PineNote
elseif model ~= "(Generic Desktop)" then
    logger.info("No device-specific backend for detected model: ", JSON.encode(model))
end

logger.info("SDL device: Detecting distribution method...")
if os.getenv("APPIMAGE") then
    logger.info("  Running as AppImage")
    return device_backend:extend({
        model = device_backend.model.." (AppImage)",
        hasOTAUpdates = yes,
    })
elseif os.getenv("UBUNTU_APPLICATION_ISOLATION") then
    logger.info("  Running as Ubuntu Application (UbuntuTouch)")
    return device_backend:extend{
        model = device_backend.model.." (UbuntuTouch)",
        isDefaultFullscreen = yes,
    }
else
    logger.info("  (No specific distribution method)")
end

return device_backend
