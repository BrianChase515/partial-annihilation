-- Tiny procedural sound effects (no audio files needed).
local S = { muted = false, volume = 0.5 }
local rate = 22050
local sounds = {}
local files = {}
local last = {}

-- name, variations, voices per variation
S.FILES = { { "rifle", 3, 3 }, { "blaster", 3, 3 }, { "heavy", 2, 2 }, { "artillery", 2, 2 }, { "impact", 3, 2 },
  { "flak", 2, 2 }, { "torpedo", 1, 2 }, { "boom", 3, 2 }, { "bigboom", 2, 2 }, { "skill", 2, 2 } }
-- loudness and minimum gap between plays of each kind (keeps big battles from turning into noise)
S.MIX = { rifle = { 0.32, 0.06 }, blaster = { 0.34, 0.07 }, heavy = { 0.55, 0.12 }, artillery = { 0.6, 0.18 },
  impact = { 0.5, 0.1 }, flak = { 0.3, 0.09 }, torpedo = { 0.5, 0.25 }, boom = { 0.55, 0.08 },
  bigboom = { 0.85, 0.25 }, skill = { 0.5, 0.05 } }

-- which sound a weapon makes when it fires
function S.weaponSound(w)
  if not w then return "blaster" end
  if w.torpedo then return "torpedo" end
  if w.bomb then return nil end                       -- bombs are heard when they land
  if w.ballistic then return "artillery" end
  if w.targets and w.targets.air and not w.targets.land then return "flak" end
  if w.damage >= 60 then return "heavy" end
  if w.damage < 20 or w.reload <= 0.35 then return "rifle" end
  return "blaster"
end

-- play a combat sound placed in the world: pan from where it is on screen,
-- quieter the further it is from the view (a little bleed from just off-screen)
-- view = { x, y, cx, cy, halfW }  (sound position, camera center, half view width in world units)
function S.at(name, x, y, view, vol)
  if S.muted or not S.ok or S.combatOff then return end
  local set = files[name]
  if not set then return end
  local mix = S.MIX[name] or { 0.5, 0.05 }
  local now = love.timer.getTime()
  if last[name] and now - last[name] < mix[2] then return end
  local pan, fall = 0, 1
  if view then
    local dx, dy = x - view.cx, y - view.cy
    local hw = math.max(200, view.halfW)
    pan = math.max(-1, math.min(1, dx / hw)) * 0.8
    local d = math.sqrt(dx * dx + dy * dy) / hw     -- 1 = edge of the screen
    fall = d <= 1 and 1 - 0.3 * d or math.max(0, 0.7 - (d - 1) * 0.9)
    -- zoomed far out everything is a bit quieter
    fall = fall * (view.zoomMul or 1)
  end
  local v = (vol or 1) * mix[1] * fall * S.volume * (S.combatVolume or 1)
  if v < 0.02 then return end
  last[name] = now
  local pool = set[love.math.random(#set)]
  for _, src in ipairs(pool) do
    if not src:isPlaying() then
      src:setVolume(v)
      src:setPitch(1 + (love.math.random() - 0.5) * 0.12)
      if src:getChannelCount() == 1 then src:setPosition(pan, 0, -math.sqrt(1 - pan * pan)) end
      src:play()
      return true
    end
  end
end

local function make(dur, fn)
  local n = math.floor(dur * rate)
  local sd = love.sound.newSoundData(n, rate, 16, 1)
  local rng = love.math.newRandomGenerator(n)
  local state = { lp = 0 }
  for i = 0, n - 1 do
    local t = i / rate
    local v = fn(t, dur, rng, state)
    sd:setSample(i, math.max(-1, math.min(1, v)))
  end
  return sd
end

function S.init()
  if not love.audio then return end
  local ok = pcall(function()
    love.audio.setDistanceModel("none")   -- positions only pan; we do our own distance falloff
    local data = {}
    -- light gun: short noisy click
    data.shot = make(0.07, function(t, d, rng, s)
      local env = (1 - t / d) ^ 3
      s.lp = s.lp + ((rng:random() * 2 - 1) - s.lp) * 0.5
      return (s.lp * 0.6 + math.sin(t * 2 * math.pi * 900) * 0.3) * env * 0.7
    end)
    -- cannon: low thump
    data.cannon = make(0.18, function(t, d, rng, s)
      local env = (1 - t / d) ^ 2.5
      s.lp = s.lp + ((rng:random() * 2 - 1) - s.lp) * 0.15
      return (math.sin(t * 2 * math.pi * (120 - t * 300)) * 0.7 + s.lp * 0.5) * env
    end)
    -- explosion: filtered noise rumble
    data.boom = make(0.6, function(t, d, rng, s)
      local env = (1 - t / d) ^ 2
      s.lp = s.lp + ((rng:random() * 2 - 1) - s.lp) * (0.08 - t * 0.1)
      return s.lp * 2.2 * env
    end)
    -- unit ready: two rising tones
    data.ready = make(0.22, function(t, d)
      local f = t < 0.1 and 660 or 990
      local env = math.min(1, (d - t) * 20) * math.min(1, t * 200)
      return math.sin(t * 2 * math.pi * f) * 0.35 * env
    end)
    -- alert: three quick beeps
    data.alert = make(0.45, function(t)
      local k = math.floor(t / 0.15)
      local local_t = t - k * 0.15
      local on = local_t < 0.09 and 1 or 0
      local tri = 2 * math.abs(2 * ((t * 520) % 1) - 1) - 1
      return tri * 0.3 * on
    end)
    -- click for UI
    data.click = make(0.03, function(t, d)
      return math.sin(t * 2 * math.pi * 1500) * (1 - t / d) * 0.25
    end)
    -- recorded-style combat sounds rendered by tools/sfx.py (several variations each)
    for _, spec in ipairs(S.FILES) do
      local name, n = spec[1], spec[2]
      for i = 1, n do
        local ok2, sd2 = pcall(love.sound.newSoundData, "assets/sfx/" .. name .. i .. ".ogg")
        if ok2 then
          files[name] = files[name] or {}
          local pool = {}
          for _ = 1, spec[3] do
            local src = love.audio.newSource(sd2, "static")
            pool[#pool + 1] = src
          end
          table.insert(files[name], pool)
        end
      end
    end
    for k, sd in pairs(data) do
      sounds[k] = {}
      for i = 1, (k == "shot" and 6 or 3) do
        sounds[k][i] = love.audio.newSource(sd, "static")
      end
    end
  end)
  S.ok = ok
end

-- play a sound; vol 0..1. Throttled so big battles don't turn into noise.
function S.play(name, vol, pitchVar)
  if S.muted or not S.ok then return end
  local pool = sounds[name]
  if not pool then return end
  local now = love.timer.getTime()
  local gap = ({ shot = 0.05, cannon = 0.08, boom = 0.08 })[name] or 0.02
  if last[name] and now - last[name] < gap then return end
  last[name] = now
  for _, src in ipairs(pool) do
    if not src:isPlaying() then
      src:setVolume((vol or 1) * S.volume)
      src:setPitch(1 + (math.random() - 0.5) * (pitchVar or 0.2))
      src:play()
      return
    end
  end
end

return S
