-- Tiny procedural sound effects (no audio files needed).
local S = { muted = false, volume = 0.5 }
local rate = 22050
local sounds = {}
local last = {}

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
