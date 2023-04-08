local Event = require("ui/event")
local Generic = require("device/generic/device")
local SDL = require("ffi/SDL2_0")
local ffi = require("ffi")
local logger = require("logger")
local util = require("util")
local time = require("ui/time")
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

local SdlDevice = Generic:extend{
    model = "SDL",
    isSDL = yes,
    home_dir = os.getenv("XDG_DOCUMENTS_DIR") or os.getenv("HOME"),
    hasBattery = SDL.getPowerInfo,
    powerDBackend = require("device/sdl/powerd"),
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

function SdlDevice:init()
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
    self.powerd = self.powerDBackend:new({device = self})

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

require("device/mixins/clock_detect")(SdlDevice)

function SdlDevice:isAlwaysFullscreen()
    -- return true on embedded devices, which should default to fullscreen
    return self:isDefaultFullscreen()
end

function SdlDevice:toggleFullscreen()
    local current_mode = self.fullscreen or self:isDefaultFullscreen()
    local new_mode = not current_mode
    local ok, err = SDL.setWindowFullscreen(new_mode)
    if not ok then
        logger.warn("Unable to toggle fullscreen mode to", new_mode, "\n", err)
    else
        self.fullscreen = new_mode
    end
end

function SdlDevice:setEventHandlers(UIManager)
    if not self:canSuspend() then
        -- If we can't suspend, we have no business even trying to, as we may not have overloaded `SdlDevice:simulateResume`.
        -- Instead, rely on the Generic Suspend/Resume handlers.
        return
    end

    UIManager.event_handlers.Suspend = function()
        self:_beforeSuspend()
        self:simulateSuspend()
    end
    UIManager.event_handlers.Resume = function()
        self:simulateResume()
        self:_afterResume()
    end
    UIManager.event_handlers.PowerRelease = function()
        -- Resume if we were suspended
        if self.screen_saver_mode then
            UIManager.event_handlers.Resume()
        else
            UIManager.event_handlers.Suspend()
        end
    end
end

function SdlDevice:initNetworkManager(NetworkMgr)
    function NetworkMgr:isWifiOn() return true end
    function NetworkMgr:isConnected()
        -- Pull the default gateway first, so we don't even try to ping anything if there isn't one...
        local default_gw = SdlDevice:getDefaultRoute()
        if not default_gw then
            return false
        end
        return 0 == os.execute("ping -c1 -w2 " .. default_gw .. " > /dev/null")
    end
end

-- Devices extending SdlDevice

local Emulator = require("device/sdl/emulator")(SdlDevice)

local Desktop = SdlDevice:extend{
    model = "Generic (SDL "..SDL.getPlatform()..")",
    isDesktop = yes,
    canRestart = notOSX,
    hasExitOptions = notOSX,
}

-- TODO: systemctl backend for device state
--   -> remarkable will need a way to call disable-wifi before suspend
function Desktop:standby(max_duration)
end

function Desktop:resume()
end

function Desktop:suspend()
    os.execute("systemctl suspend")
end

function Desktop:powerOff()
    os.execute("systemctl poweroff")
end

function Desktop:reboot()
    os.execute("systemctl reboot")
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
    powerDBackend = require("device/sdl/sdllightpowerd"),
    lightPowerDConfig = {
        warm = "sysfs/backlight/backlight_warm",
        cool = "sysfs/backlight/backlight_cool",
    },
    canSuspend = yes,
    canReboot = yes,
    canPowerOff = yes,
    canStandby = no,
    -- TODO: nmcli NetworkMgr backend
    -- hasWifiToggle = yes,
}

io.write("Starting SDL in " .. SDL.getBasePath() .. "\n")

-------------- device probe ------------
local model = nil

-- Allow overriding the model
if os.getenv("KO_MODEL") then
    model = os.getenv("KO_MODEL")
end

logger.info("SDL device: Looking for a more specific model...")

-- Linux ARM devices are likely to be using Device Tree.
if model then
    logger.info("Using KO_MODEL as model...")
end

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

if model == nil then
	model = "(Generic Desktop)"
	-- TODO: change the emulator semantics; emulator should be opt-in with KO_EMULATOR imo.
	if os.getenv("KO_MULTIUSER") or os.getenv("APPIMAGE") or os.getenv("UBUNTU_APPLICATION_ISOLATION") then
		model = "(Generic Desktop)"
	else
		model = "(Emulator)"
	end
end

-- Using JSON.encode here to ensure any control characters gets sussed-out.
logger.info("  model:", JSON.encode(model))

local device_backend = Desktop

if model == "(Emulator)" then
	device_backend = Emulator
elseif model:match("^Pine64 PineNote") then
	device_backend = PineNote
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
