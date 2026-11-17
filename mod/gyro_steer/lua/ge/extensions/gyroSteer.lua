-- GyroSteer: steers the player's car from the tilt of a controller, as measured by the GyroSteer app
-- and sent here over UDP on 127.0.0.1.
--
-- From the app: "gs1 s=<steering -1..1, positive = right> f=<input filter: 1 gamepad, 2 wheel>", "gs1 off", or
-- "gs1 ping". Each batch gets an answer, "gs1 ack car=<0|1> on=<0|1> [applied=<the car's steering input>] v=<VERSION>",
-- so the app can show that the game is listening, what the car did with the value after the game's smoothing, and
-- whether this mod matches the app's version.
-- Steering goes through the vehicle's normal input.event (as input source 'gyroSteer'), so the gamepad smoothing and
-- steering assists still apply. Other steering inputs (the stick) still work; the next tilt reading takes over again.
-- While the sticks are pedals, the car takes steering only from GyroSteer (input.setAllowedInputSource), so pushing
-- the left stick to brake can't steer, not even for a frame.
--
-- Pedals from the sticks: "gs1 p t=<throttle 0..1> b=<brake 0..1> f=<filter>". Each pedal goes to the car only when
-- it changes, and again every RESEND while it is held, so at rest the triggers' own bindings still work. If the app
-- goes quiet for TIMEOUT while a pedal is held, the pedal is let go, so the throttle can't stick.
--
-- "gs1 mode pedals=<0|1> gyro=<0|1>", every 0.5 s: while the sticks are pedals, the camera ignores the stick (its
-- turn input is cleared every frame, and the game's action filter is asked to drop the stick's camera actions), and,
-- while the gyro steers, the filter is asked to drop the stick's own steering, so pushing a stick for the pedals
-- doesn't swing the camera or steer. The mouse camera and the triggers are untouched; the keyboard's camera turn
-- pauses too. Everything comes back when the app says so, goes quiet for MODE_TIMEOUT, or the mod unloads.
--
-- Camera on the D-pad: "gs1 cam hold=<0|1> x=<-1|0|1> y=<-1|0|1>", on every change and every 0.1 s while held. While a
-- button chosen in the app is held, the D-pad turns the camera, and the game's own D-pad actions (by default the
-- radial menu, look back, recover and reset) are paused so they don't fire too. Let go and they're back.

local M = {}

local VERSION = '0.3.0'  -- matches the app's version; checked by the release build
local PORT = 47731
local TIMEOUT = 0.5   -- seconds without steering before it is handed back
local RESEND = 0.1    -- seconds; resend an unchanged value so a stick nudge doesn't stick
local RETRY = 5       -- seconds between attempts to open the port if it was busy
local ACK_EVERY = 0.03

-- Run in the vehicle after each steering command: reports the car's steering input back to this extension.
local REPORT = " obj:queueGameEngineLua('extensions.hook(\"onGyroSteerApplied\", ' .. tostring(electrics.values.steering_input or 0) .. ')')"

local udp = nil
local retryIn = 0
local warnedBusy = false
local active = false
local quiet = 0
local sentValue, sentFilter, sentVehId = nil, nil, nil
local sinceSend = 0
local sinceAck = 0
local applied = nil
local pedalSent = { throttle = 0, brake = 0 }
local pedalSince = { throttle = 0, brake = 0 }
local pedalFilter = FILTER_PAD
local pedalVehId = nil
local pedalQuiet = 0

local MODE_TIMEOUT = 2
-- What BeamNG's default controller maps put on the D-pad while driving; the controller's own D-pad bindings are
-- added to these when the camera hold starts.
local DPAD_DEFAULTS = { 'toggleRadialMenuMulti', 'look_back', 'recover_vehicle', 'reset_physics', 'activateStarterMotor' }
local PAUSED_ACTIONS = {
  camera = { 'rotate_camera_horizontal', 'rotate_camera_vertical' },  -- the right stick's default camera actions
  steering = { 'steering' },  -- stick or wheel steering; the keyboard uses steer_left/steer_right
  dpad = DPAD_DEFAULTS,
}
local modeQuiet = math.huge
local modePedals, modeGyro = false, false
local paused = { camera = false, steering = false, dpad = false }
local lockedVehId = nil  -- the car that takes steering only from GyroSteer

local CAM_TIMEOUT = 0.3  -- seconds; the app repeats the camera hold every 0.1 s
local camQuiet = math.huge
local camHold, camX, camY = false, 0, 0
local camTurning = false

local function openSocket()
  local s = socket.udp()
  if not s then return end
  if s:setsockname('127.0.0.1', PORT) == nil then
    s:close()
    if not warnedBusy then
      log('E', 'gyroSteer', 'UDP port ' .. PORT .. ' is busy; gyro steering is off until it is free')
      warnedBusy = true
    end
    return
  end
  s:settimeout(0)
  udp = s
  log('I', 'gyroSteer', 'listening for the GyroSteer app on 127.0.0.1:' .. PORT)
end

local LOCK = "if input.setAllowedInputSource then input.setAllowedInputSource('steering', 'gyroSteer', true) end "
local UNLOCK = "if input.setAllowedInputSource then input.setAllowedInputSource('steering', nil) end"

-- Lets the car take steering from anywhere again.
local function unlockSteering()
  local veh = lockedVehId and be:getObjectByID(lockedVehId)
  if veh then veh:queueLuaCommand(UNLOCK) end
  lockedVehId = nil
end

local function steer(veh, value, filter)
  local id = veh:getId()
  local lock = paused.steering
  if lockedVehId and (not lock or lockedVehId ~= id) then unlockSteering() end
  -- The lock goes with every command, so it survives the car being reloaded.
  local command = string.format("input.event('steering', %.4f, %d, nil, nil, nil, 'gyroSteer')", value, filter)
  if lock then
    command = LOCK .. command
    lockedVehId = id
  end
  veh:queueLuaCommand(command .. REPORT)
end

local function release(message)
  local veh = getPlayerVehicle(0)
  if veh and sentValue then steer(veh, 0, sentFilter or FILTER_PAD) end
  unlockSteering()
  active = false
  applied = nil
  sentValue, sentFilter, sentVehId = nil, nil, nil
  if message then ui_message(message, 3, 'gyroSteer') end
end

local function apply(value, filter, dt)
  if not active then
    active = true
    ui_message('Gyro steering on', 2, 'gyroSteer')
  end
  local veh = getPlayerVehicle(0)
  if not veh then return end
  local id = veh:getId()
  sinceSend = sinceSend + dt
  if value ~= sentValue or filter ~= sentFilter or id ~= sentVehId or sinceSend >= RESEND then
    steer(veh, value, filter)
    sentValue, sentFilter, sentVehId = value, filter, id
    sinceSend = 0
  end
end

local function pedalEvent(veh, name, value, filter)
  veh:queueLuaCommand(string.format("input.event('%s', %.3f, %d)", name, value, filter))
end

-- Lets go of any pedal still held, in the car it was sent to.
local function releasePedals()
  local veh = pedalVehId and be:getObjectByID(pedalVehId)
  for name, v in pairs(pedalSent) do
    if v > 0 and veh then pedalEvent(veh, name, 0, pedalFilter) end
    pedalSent[name] = 0
  end
end

local function applyPedals(throttle, brake, filter)
  local veh = getPlayerVehicle(0)
  if not veh then return end
  local id = veh:getId()
  if pedalVehId and id ~= pedalVehId then releasePedals() end  -- switched cars: let go in the old one
  pedalVehId, pedalFilter = id, filter
  for name, v in pairs({ throttle = throttle, brake = brake }) do
    if v ~= pedalSent[name] or (v > 0 and pedalSince[name] >= RESEND) then
      pedalEvent(veh, name, v, filter)
      pedalSent[name] = v
      pedalSince[name] = 0
    end
  end
end

-- Clears the stick's camera turn. Between frames MoveManager is the main view's input state, and the camera reads
-- it later in the frame (onPreRender), so clearing it here each frame keeps the camera still even if the game's
-- action filter lets the stick through. The mouse turns the camera through other fields, so it keeps working; the
-- keyboard's camera turn uses these too, so it pauses with the stick.
local function holdCamera()
  local mm = MoveManager
  if mm then mm.yawLeft, mm.yawRight, mm.pitchUp, mm.pitchDown = 0, 0, 0, 0 end
end

-- Turns the camera the way the D-pad points, through the same calls as the game's own camera keys.
local function turnCamera(x, y)
  local cam = core_camera
  if not cam or not cam.rotate_yaw_left then return end
  local f = FILTER_KBD or 0
  cam.rotate_yaw_left(x < 0 and 1 or 0, f, 0)
  cam.rotate_yaw_right(x > 0 and 1 or 0, f, 0)
  cam.rotate_pitch_up(y > 0 and 1 or 0, f, 0)
  cam.rotate_pitch_down(y < 0 and 1 or 0, f, 0)
end

-- Every action bound to a D-pad on a controller, plus BeamNG's defaults.
local function dpadActions()
  local seen, list = {}, {}
  local function add(action)
    if action and not seen[action] then
      seen[action] = true
      table.insert(list, action)
    end
  end
  for _, action in ipairs(DPAD_DEFAULTS) do add(action) end
  local devices = core_input_bindings and core_input_bindings.bindings or {}
  for _, device in ipairs(devices) do
    local name = tostring(device.devname or '')
    local bindings = device.contents and device.contents.bindings or {}
    if not name:find('^keyboard') and not name:find('^mouse') then
      for _, binding in ipairs(bindings) do
        local control = tostring(binding.control or ''):lower()
        if not binding.unused and (control:find('pov') or control:find('dpad')) then add(binding.action) end
      end
    end
  end
  return list
end

-- Pauses or restores one group of the game's input actions. `force` applies it even if it looks unchanged (at load,
-- in case a Lua reload kept an old pause in the game's filter).
local function pause(name, on, force)
  if paused[name] == on and not force then return end
  paused[name] = on
  if name == 'dpad' and on then PAUSED_ACTIONS.dpad = dpadActions() end
  if name == 'steering' and not on then unlockSteering() end
  local filter = core_input_actionFilter
  if filter then
    filter.setGroup('gyroSteer_' .. name, PAUSED_ACTIONS[name])
    filter.addAction(0, 'gyroSteer_' .. name, on)
  end
  if name == 'camera' and on then holdCamera() end
  if name == 'dpad' then
    log('D', 'gyroSteer', 'D-pad actions ' .. (on and 'paused for the camera: ' .. table.concat(PAUSED_ACTIONS.dpad, ', ') or 'restored'))
  elseif not force then
    local filtered = filter and filter.isActionBlocked and filter.isActionBlocked(PAUSED_ACTIONS[name][1])
    log('I', 'gyroSteer', string.format('stick %s %s (game action filter reports blocked: %s)', name,
      on and 'paused' or 'restored', tostring(filtered)))
    if name == 'camera' then
      ui_message(on and 'Sticks are gas and brake: stick camera paused' or 'Stick camera back', 3, 'gyroSteerCamera')
    end
  end
end

local function updatePauses()
  local alive = modeQuiet < MODE_TIMEOUT
  pause('camera', alive and modePedals)
  pause('steering', alive and modePedals and modeGyro)
end

local function answer(ip, port)
  local reply = string.format('gs1 ack car=%d on=%d', getPlayerVehicle(0) and 1 or 0, active and 1 or 0)
  if active and applied then reply = reply .. string.format(' applied=%.4f', applied) end
  udp:sendto(reply .. ' v=' .. VERSION, ip, port)
  sinceAck = 0
end

local function onUpdate(dtReal)
  if not udp then
    retryIn = retryIn - dtReal
    if retryIn <= 0 then
      retryIn = RETRY
      openSocket()
    end
    return
  end

  -- Only the newest steering value matters; an "off" after it wins. Likewise only the newest pedals.
  local value, filter, off, fromIp, fromPort
  local throttle, brake, pFilter
  local modeHeard, camHeard = false, false
  for _ = 1, 500 do
    local data, ip, port = udp:receivefrom()
    if not data then break end
    fromIp, fromPort = ip, port
    if data:sub(1, 7) == 'gs1 off' then
      off, value = true, nil
    elseif data:sub(1, 6) == 'gs1 s=' then
      local v = tonumber(data:match('s=(%-?[%d%.]+)'))
      if v then
        value, off = v, false
        filter = tonumber(data:match('f=(%d)')) == 2 and FILTER_DIRECT or FILTER_PAD
      end
    elseif data:sub(1, 6) == 'gs1 p ' then
      local t, b = tonumber(data:match('t=(%-?[%d%.]+)')), tonumber(data:match('b=(%-?[%d%.]+)'))
      if t and b then
        throttle, brake = t, b
        pFilter = tonumber(data:match('f=(%d)')) == 2 and FILTER_DIRECT or FILTER_PAD
      end
    elseif data:sub(1, 9) == 'gs1 mode ' then
      modePedals = data:match('pedals=(%d)') == '1'
      modeGyro = data:match('gyro=(%d)') == '1'
      modeHeard = true
    elseif data:sub(1, 8) == 'gs1 cam ' then
      camHold = data:match('hold=(%d)') == '1'
      camX = tonumber(data:match('x=(%-?%d)')) or 0
      camY = tonumber(data:match('y=(%-?%d)')) or 0
      camHeard = true
    end
  end

  modeQuiet = modeHeard and 0 or modeQuiet + dtReal
  updatePauses()
  if paused.camera then holdCamera() end

  camQuiet = camHeard and 0 or camQuiet + dtReal
  local camOn = camHold and camQuiet < CAM_TIMEOUT
  pause('dpad', camOn)
  if camOn then
    turnCamera(camX, camY)
    camTurning = true
  elseif camTurning then
    turnCamera(0, 0)
    camTurning = false
  end

  for name in pairs(pedalSince) do pedalSince[name] = pedalSince[name] + dtReal end
  if throttle then
    pedalQuiet = 0
    applyPedals(math.max(0, math.min(1, throttle)), math.max(0, math.min(1, brake)), pFilter)
  elseif pedalSent.throttle > 0 or pedalSent.brake > 0 then
    pedalQuiet = pedalQuiet + dtReal
    if pedalQuiet > TIMEOUT then releasePedals() end
  end

  if value then
    quiet = 0
    apply(math.max(-1, math.min(1, value)), filter, dtReal)
  elseif off then
    if active then release('Gyro steering off') end
  elseif active then
    quiet = quiet + dtReal
    if quiet > TIMEOUT then release('Gyro steering stopped (app closed or controller disconnected)') end
  end

  sinceAck = sinceAck + dtReal
  if fromIp and sinceAck >= ACK_EVERY then answer(fromIp, fromPort) end
end

-- Called (through extensions.hook) by the vehicle with its steering input after each steering command.
local function onGyroSteerApplied(value)
  if active then applied = value end
end

local function onExtensionLoaded()
  pause('camera', false, true)
  pause('steering', false, true)
  pause('dpad', false, true)
  openSocket()
end

local function onExtensionUnloaded()
  if active then release() end
  releasePedals()
  pause('camera', false)
  pause('steering', false)
  pause('dpad', false)
  unlockSteering()
  if camTurning then turnCamera(0, 0) end
  if udp then
    udp:close()
    udp = nil
  end
end

M.onUpdate = onUpdate
M.onGyroSteerApplied = onGyroSteerApplied
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
