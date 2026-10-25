-- Robotic announcer. Lines are pre-rendered OGGs in assets/voice (see tools/voices.py).
-- One line at a time; a short queue; per-line cooldowns so it never nags.
local V = { muted = false, volume = 0.9 }
local sources, lastSaid, queue = {}, {}, {}
local current

local COOLDOWN = {
  under_attack = 25, units_attacked = 30, commander_attack = 20, commander_low = 30,
  construction = 10, low_metal = 60, low_energy = 60, retreat = 4, self_destruct = 2,
}
local URGENT = { nuke_incoming = true, commander_low = true, defeat = true, victory = true }

local function src(key)
  if sources[key] == nil then
    local ok, s = pcall(love.audio.newSource, "assets/voice/" .. key .. ".ogg", "static")
    sources[key] = ok and s or false
  end
  return sources[key] or nil
end

function V.say(key)
  if V.modeMuted then return end
  if V.recorder then return V.recorder(key) end -- (trailer tool)
  if V.muted or not love.audio then return end
  local now = love.timer.getTime()
  if lastSaid[key] and now - lastSaid[key] < (COOLDOWN[key] or 6) then return end
  for _, k in ipairs(queue) do if k == key then return end end
  lastSaid[key] = now
  if URGENT[key] then
    if current then current:stop(); current = nil end
    table.insert(queue, 1, key)
  else
    if #queue >= 2 then return end
    queue[#queue + 1] = key
  end
  V.update()
end

function V.update()
  if current and current:isPlaying() then return end
  current = nil
  while #queue > 0 and not current do
    local s = src(table.remove(queue, 1))
    if s then
      s:setVolume(V.volume)
      s:play()
      current = s
    end
  end
end

-- is the announcer talking right now? (battlefield cries wait for him)
function V.busy() return current ~= nil and current:isPlaying() end

function V.stopAll()
  queue = {}
  if current then current:stop(); current = nil end
end

return V
