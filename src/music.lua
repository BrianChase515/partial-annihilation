-- Dynamic orchestral score. Three tempo-locked stems loop together; their volumes follow
-- how much fighting the player is involved in:
--   calm      -> ambient strings, choir, harp, celesta
--   skirmish  -> + cellos/basses ostinato, tremolo, timpani (tension)
--   battle    -> + full brass, percussion, driving strings (combat)
-- Streamed from disk, so memory use stays tiny.
local M = { muted = false, volume = 0.55, intensity = 0, heat = 0 }
local stems, gains = {}, { ambient = 0, tension = 0, combat = 0 }
local stinger
local playing = false
local resyncT = 0

local function load(name, mode)
  local ok, s = pcall(love.audio.newSource, "assets/music/" .. name .. ".ogg", mode or "stream")
  return ok and s or nil
end

local function smooth(e0, e1, x)
  local t = math.max(0, math.min(1, (x - e0) / (e1 - e0)))
  return t * t * (3 - 2 * t)
end

function M.start()
  if not love.audio then return end
  if not stems.ambient then
    for _, k in ipairs({ "ambient", "tension", "combat" }) do
      stems[k] = load(k)
      if stems[k] then stems[k]:setLooping(true); stems[k]:setVolume(0) end
    end
  end
  if stinger then stinger:stop(); stinger = nil end
  if playing then return end
  playing = true
  for _, s in pairs(stems) do s:seek(0); s:play() end
end

function M.stop()
  playing = false
  for _, s in pairs(stems) do s:stop() end
end

-- something happened involving the player's side; amount ~ how dramatic it was
function M.bump(amount)
  M.heat = math.min(1.6, M.heat + amount)
end

-- level = "menu" keeps it to the ambient layer at a lower volume
function M.update(dt, level)
  if not playing then return end
  -- heat decays; intensity chases heat (fast attack, slow release)
  M.heat = math.max(0, M.heat - (M.heat * 0.12 + 0.015) * dt)
  local target = math.min(1, math.max(M.heat, M.floor or 0))
  if level == "menu" then target = 0 end
  local rate = target > M.intensity and 0.45 or 0.12
  M.intensity = M.intensity + (target - M.intensity) * math.min(1, dt * rate * 3)
  local i = M.intensity
  local want = {
    ambient = 1 - 0.65 * smooth(0.2, 0.8, i),
    tension = smooth(0.12, 0.45, i),
    combat = smooth(0.45, 0.8, i),
  }
  local master = M.muted and 0 or M.volume * (level == "menu" and 0.7 or 1)
  if M.fadeOut then
    M.fadeOut = math.max(0, M.fadeOut - dt * 0.5)
    master = master * M.fadeOut
    if M.fadeOut <= 0 then M.stop() end
  end
  for k, s in pairs(stems) do
    gains[k] = gains[k] + (want[k] - gains[k]) * math.min(1, dt * 1.5)
    s:setVolume(gains[k] * master)
  end
  -- keep the stems sample-locked (streams can drift apart a hair over long sessions)
  resyncT = resyncT + dt
  if resyncT > 4 and stems.ambient then
    resyncT = 0
    local t = stems.ambient:tell()
    for k, s in pairs(stems) do
      if k ~= "ambient" and math.abs(s:tell() - t) > 0.03 then s:seek(t) end
    end
  end
end

function M.setMuted(m)
  M.muted = m
  if stinger then stinger:setVolume(m and 0 or M.volume) end
end

-- end of game: fade the loops, play the fanfare or the lament
function M.finale(won)
  M.fadeOut = 1
  stinger = load(won and "victory" or "defeat", "static")
  if stinger and not M.muted then stinger:setVolume(M.volume * 1.1); stinger:play() end
end

function M.reset()
  M.heat, M.intensity, M.fadeOut, M.floor = 0, 0, nil, 0
end

-- title screen: make sure the calm layer is playing
function M.menu()
  if stinger and stinger:isPlaying() then return end
  M.fadeOut = nil
  if not playing then M.reset(); M.start() end
  M.heat, M.floor = 0, 0
end

return M
