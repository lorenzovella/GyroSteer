-- GyroSteer: steers the player's car from the tilt of a controller, as measured by the GyroSteer app on the Mac
-- and sent here over UDP on 127.0.0.1.
--
-- From the app: "gs1 s=<steering -1..1, positive = right> f=<input filter: 1 gamepad, 2 wheel>", "gs1 off", or
-- "gs1 ping". Each batch gets an answer, "gs1 ack car=<0|1> on=<0|1> [applied=<the car's steering input>]", so the
-- app can show that the game is listening and what the car did with the value after the game's smoothing.
-- Steering goes through the vehicle's normal input.event, so the gamepad smoothing and steering assists still
-- apply. Other steering inputs (the stick) still work; the next tilt reading takes over again.
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

local M = {}

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
local PAUSED_ACTIONS = {
  camera = { 'rotate_camera_horizontal', 'rotate_camera_vertical' },  -- the right stick's default camera actions
  steering = { 'steering' },  -- stick or wheel steering; the keyboard uses steer_left/steer_right
}
local modeQuiet = math.huge
local modePedals, modeGyro = false, false
local paused = { camera = false, steering = false }

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

local function steer(veh, value, filter)
  veh:queueLuaCommand(string.format("input.event('steering', %.4f, %d)", value, filter) .. REPORT)
end

local function release(message)
  local veh = getPlayerVehicle(0)
  if veh and sentValue then steer(veh, 0, sentFilter or FILTER_PAD) end
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

-- Pauses or restores one group of the game's input actions. `force` applies it even if it looks unchanged (at load,
-- in case a Lua reload kept an old pause in the game's filter).
local function pause(name, on, force)
  if paused[name] == on and not force then return end
  paused[name] = on
  local filter = core_input_actionFilter
  if filter then
    filter.setGroup('gyroSteer_' .. name, PAUSED_ACTIONS[name])
    filter.addAction(0, 'gyroSteer_' .. name, on)
  end
  if name == 'camera' and on then holdCamera() end
  if not force then
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
  udp:sendto(reply, ip, port)
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
  local modeHeard = false
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
    end
  end

  modeQuiet = modeHeard and 0 or modeQuiet + dtReal
  updatePauses()
  if paused.camera then holdCamera() end

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
  openSocket()
end

local function onExtensionUnloaded()
  if active then release() end
  releasePedals()
  pause('camera', false)
  pause('steering', false)
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
