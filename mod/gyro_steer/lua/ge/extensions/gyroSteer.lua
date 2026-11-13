-- GyroSteer: steers the player's car from the tilt of a controller, as measured by the GyroSteer app on the Mac
-- and sent here over UDP on 127.0.0.1.
--
-- From the app: "gs1 s=<steering -1..1, positive = right> f=<input filter: 1 gamepad, 2 wheel>", "gs1 off", or
-- "gs1 ping". Each batch gets an answer, "gs1 ack car=<0|1> on=<0|1> [applied=<the car's steering input>]", so the
-- app can show that the game is listening and what the car did with the value after the game's smoothing.
-- Steering goes through the vehicle's normal input.event, so the gamepad smoothing and steering assists still
-- apply. Other steering inputs (the stick) still work; the next tilt reading takes over again.

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

  -- Only the newest steering value matters; an "off" after it wins.
  local value, filter, off, fromIp, fromPort
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
    end
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
  openSocket()
end

local function onExtensionUnloaded()
  if active then release() end
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
