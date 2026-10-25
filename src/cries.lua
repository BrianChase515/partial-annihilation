-- War is Hell: the human cost. Death screams and wounded shouts (assets/voice/cry_*.ogg: real
-- recorded voices, credited in assets/voice/CREDITS.md - VoiceBosch's death and damage packs plus the "aargh"
-- screams from OpenGameArt), placed in the world like combat sounds, and blood: sprays on hits, pools where
-- someone fell (they stay on the ground).
local C = {}
local NDEATH, NHURT = 33, 22
local cache = {}
local lastAny, lastBy = -99, setmetatable({}, { __mode = "k" })
local hurtSrc = setmetatable({}, { __mode = "k" })

local function source(key)
  if cache[key] == nil then
    local ok, s = pcall(love.audio.newSource, "assets/voice/" .. key .. ".ogg", "static")
    cache[key] = ok and { s } or false
  end
  local pool = cache[key]
  if not pool then return nil end
  for _, s in ipairs(pool) do if not s:isPlaying() then return s end end
  if #pool < 3 then local s = pool[1]:clone(); pool[#pool + 1] = s; return s end
  return nil
end

-- one voice at a time: a cry never talks over the announcer or another cry (a death scream may
-- cut off a wounded shout, nothing else interrupts)
local playing
local function busy()
  if require("src.voice").busy() then return true end
  return playing and playing:isPlaying()
end

local function play(key, u, view, vol, urgent)
  if C.recorder then return C.recorder(key, u, view, vol, urgent) end -- (trailer tool)
  local SFX = require("src.sfx")
  if SFX.muted or not love.audio then return end
  if busy() then
    if urgent and playing and playing:isPlaying() and hurtSrc[playing] and not require("src.voice").busy() then playing:stop()
    else return end
  end
  local pan, fall = 0, 1
  if view then
    local dx, dy = u.x - view.cx, u.y - view.cy
    local hw = math.max(200, view.halfW)
    pan = math.max(-1, math.min(1, dx / hw)) * 0.8
    local d = math.sqrt(dx * dx + dy * dy) / hw
    fall = d <= 1 and 1 - 0.3 * d or math.max(0, 0.7 - (d - 1) * 0.9)
  end
  local v = (vol or 1) * fall * math.min(1, SFX.volume * 2)
  if v < 0.03 then return end
  local s = source(key)
  if not s then return end
  s:setVolume(v)
  s:setPitch(0.95 + love.math.random() * 0.12)
  if s:getChannelCount() == 1 then s:setPosition(pan, 0, -math.sqrt(1 - pan * pan)) end
  s:play()
  playing = s
  hurtSrc[s] = nil
  return s
end

function C.scream(u, view, vol)
  play("cry_death_" .. love.math.random(NDEATH), u, view, vol, true)
end

-- a wounded unit shouts now and then (not every hit, and not all at once)
function C.hurt(u, view, vol)
  local now = love.timer.getTime()
  if now - lastAny < 2.5 or now - (lastBy[u] or -99) < 14 then return end
  if u.hp > u.maxhp * 0.4 or love.math.random() > 0.35 then return end
  local s = play("cry_hurt_" .. love.math.random(NHURT), u, view, vol)
  if s then lastAny, lastBy[u] = now, now; hurtSrc[s] = true end
end

-- a man who has given up, pleading (War is Hell's mercy)
function C.beg(u, view, vol)
  local s = play("cry_hurt_" .. love.math.random(NHURT), u, view, vol)
  if type(s) == "userdata" then hurtSrc[s] = true; s:setPitch(1.05 + love.math.random() * 0.1) end
end

-- blood: a fan of droplets on a hit; a pool and spatter where someone fell (kept, up to a cap)
function C.blood(world, u, dead)
  local fx = world.effects
  fx[#fx + 1] = { kind = "blood", x = u.x, y = u.y, t = 0, life = dead and 0.9 or 0.45, size = dead and 1 or 0.45,
    seed = love.math.random() * 100 }
  if dead then
    world.decals = world.decals or {}
    local d = world.decals
    d[#d + 1] = { x = u.x, y = u.y, r = u.def.radius * (1.4 + love.math.random() * 0.6), seed = love.math.random() * 100 }
    for _ = 1, 4 do
      local a, r = love.math.random() * math.pi * 2, u.def.radius * (1 + love.math.random() * 1.8)
      d[#d + 1] = { x = u.x + math.cos(a) * r, y = u.y + math.sin(a) * r, r = 3 + love.math.random() * 6, seed = love.math.random() * 100 }
    end
    while #d > 600 do table.remove(d, 1) end
  end
end

-- pools of blood on the ground (drawn under the units)
function C.drawDecals(world)
  local lg = love.graphics
  for _, d in ipairs(world.decals or {}) do
    lg.setColor(0.42, 0.03, 0.03, 0.75)
    lg.circle("fill", d.x, d.y, d.r)
    lg.setColor(0.3, 0.02, 0.02, 0.6)
    lg.circle("fill", d.x + math.sin(d.seed) * d.r * 0.3, d.y + math.cos(d.seed) * d.r * 0.3, d.r * 0.6)
  end
end

function C.drawSpray(fx, k)
  local lg = love.graphics
  for i = 1, fx.size >= 1 and 14 or 6 do
    local a = fx.seed + i * 2.4
    local r = (8 + (i * 7) % 22) * (0.4 + k) * fx.size * 1.6
    lg.setColor(0.65, 0.04, 0.04, (1 - k) * 0.9)
    lg.circle("fill", fx.x + math.cos(a) * r, fx.y + math.sin(a) * r, 2.5 + (i % 3))
  end
end

return C
