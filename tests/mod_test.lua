-- Runs the BeamNG mod against stand-ins for the parts of the game it uses, and checks what it does with the app's
-- packets. Run from the repo root: luajit tests/mod_test.lua

local failures = 0
local function check(ok, what)
  print((ok and 'PASS  ' or 'FAIL  ') .. what)
  if not ok then failures = failures + 1 end
end

-- The game, faked.
local inbox = {}          -- packets waiting for the mod
local sent = {}           -- the mod's replies
local commands = {}       -- Lua queued into the car
local blocked = {}        -- action filter: group -> blocked?
local groups = {}
local camera = {}         -- last value per camera call

socket = { udp = function()
  return {
    setsockname = function() return 1 end,
    settimeout = function() end,
    receivefrom = function() local p = table.remove(inbox, 1); if p then return p, '127.0.0.1', 5000 end end,
    sendto = function(_, data) table.insert(sent, data) end,
    close = function() end,
  }
end }
local car = { getId = function() return 7 end, queueLuaCommand = function(_, c) table.insert(commands, c) end }
getPlayerVehicle = function() return car end
be = { getObjectByID = function(_, id) return id == 7 and car or nil end }
FILTER_KBD, FILTER_PAD, FILTER_DIRECT = 0, 1, 2
MoveManager = { yawLeft = 0, yawRight = 0, pitchUp = 0, pitchDown = 0 }
log = function() end
ui_message = function() end
core_input_actionFilter = {
  setGroup = function(name, actions) groups[name] = actions end,
  addAction = function(_, name, on) blocked[name] = on end,
  isActionBlocked = function() return true end,
}
core_camera = {}
for _, f in ipairs({ 'rotate_yaw_left', 'rotate_yaw_right', 'rotate_pitch_up', 'rotate_pitch_down' }) do
  core_camera[f] = function(v) camera[f] = v end
end
core_input_bindings = { bindings = {
  { devname = 'xinput0', contents = { bindings = {
    { control = 'rpov', action = 'reset_physics' },
    { control = 'upov', action = 'my_custom_dpad_action' },
    { control = 'thumblx', action = 'steering' },
  } } },
  { devname = 'keyboard0', contents = { bindings = { { control = 'up', action = 'accelerate' } } } },
} }

local mod = dofile('mod/gyro_steer/lua/ge/extensions/gyroSteer.lua')
mod.onExtensionLoaded()

local function frame(...)
  for _, p in ipairs({ ... }) do table.insert(inbox, p) end
  commands = {}
  mod.onUpdate(1 / 60)
end
local function lastCommand() return commands[#commands] or '' end
local function contains(list, x) for _, v in ipairs(list or {}) do if v == x then return true end end return false end

-- Steering with the sticks as pedals: locked to GyroSteer.
frame('gs1 mode pedals=1 gyro=1', 'gs1 s=0.2500 f=2')
check(lastCommand():find("setAllowedInputSource%('steering', 'gyroSteer', true%)") ~= nil, 'sticks as pedals: steering locked to GyroSteer')
check(lastCommand():find("input.event%('steering', 0.2500, 2, nil, nil, nil, 'gyroSteer'%)") ~= nil, 'steering sent as source gyroSteer')
check(blocked.gyroSteer_steering == true and blocked.gyroSteer_camera == true, 'stick steering and camera actions paused')

-- Pedals off: unlocked, and plain steering.
frame('gs1 mode pedals=0 gyro=1', 'gs1 s=0.3000 f=2')
local unlocked, lockedAgain = false, false
for _, c in ipairs(commands) do
  if c:find("setAllowedInputSource%('steering', nil%)") then unlocked = true end
  if c:find("'gyroSteer', true") then lockedAgain = true end
end
check(unlocked and not lockedAgain, 'pedals off: steering unlocked')
check(blocked.gyroSteer_steering == false, 'pedals off: stick steering back')

-- Gyro off releases the steering.
frame('gs1 mode pedals=1 gyro=1', 'gs1 s=0.1000 f=2')
frame('gs1 off')
local centred, freed = false, false
for _, c in ipairs(commands) do
  if c:find("input.event%('steering', 0.0000") then centred = true end
  if c:find("setAllowedInputSource%('steering', nil%)") then freed = true end
end
check(centred and freed, 'gyro off: steering centred once and unlocked')

-- Camera: nothing paused until the button is held.
check(blocked.gyroSteer_dpad == false, 'D-pad actions untouched before the camera button is held')
frame('gs1 cam hold=1 x=1 y=0')
check(blocked.gyroSteer_dpad == true, 'camera button held: D-pad actions paused')
check(contains(groups.gyroSteer_dpad, 'reset_physics') and contains(groups.gyroSteer_dpad, 'my_custom_dpad_action')
  and contains(groups.gyroSteer_dpad, 'look_back') and not contains(groups.gyroSteer_dpad, 'steering'),
  "paused: the controller's own D-pad bindings plus the defaults, nothing else")
check(camera.rotate_yaw_right == 1 and camera.rotate_yaw_left == 0, 'D-pad right turns the camera right')
frame('gs1 cam hold=1 x=0 y=1')
check(camera.rotate_pitch_up == 1 and camera.rotate_yaw_right == 0, 'D-pad up turns the camera up')
frame('gs1 cam hold=0 x=0 y=0')
check(blocked.gyroSteer_dpad == false and camera.rotate_pitch_up == 0, 'let go: D-pad actions back, camera stops')

-- The app goes quiet while holding: let go after the timeout.
frame('gs1 cam hold=1 x=-1 y=0')
for _ = 1, 30 do frame() end
check(blocked.gyroSteer_dpad == false and camera.rotate_yaw_left == 0, 'app quiet for 0.5 s: camera hold released')

-- Replies carry the version.
check((sent[#sent] or ''):find(' v=%d+%.%d+%.%d+') ~= nil, 'replies say the mod version')

mod.onExtensionUnloaded()
check(blocked.gyroSteer_camera == false and blocked.gyroSteer_steering == false and blocked.gyroSteer_dpad == false,
  'unloading restores everything')

if failures > 0 then
  print(failures .. ' failed')
  os.exit(1)
end
print('all passed')
