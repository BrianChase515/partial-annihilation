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
local lastTell, loops = 0, 0
local swap = 1          -- gain multiplier while crossing from one suite to the next
local swapping = false

local function load(name, mode)
  local ok, s = pcall(love.audio.newSource, "assets/music/" .. name .. ".ogg", mode or "stream")
  return ok and s or nil
end

local function smooth(e0, e1, x)
  local t = math.max(0, math.min(1, (x - e0) / (e1 - e0)))
  return t * t * (3 - 2 * t)
end

-- five soundtracks: "" (D minor), "_b" Iron Tide (E minor), "_c" Ashfall (C minor),
-- "_d" Overdrive (A minor), "_e" Last Light (G minor)
M.SUITES = { "", "_b", "_c", "_d", "_e" }
M.LOOPS_PER_SUITE = 2
M.NAMES = { [""] = "Annihilation", _b = "Iron Tide", _c = "Ashfall", _d = "Overdrive", _e = "Last Light" }
M.changedAt = nil   -- love.timer time of the last soundtrack change (for the "Music:" label)   -- during a match, move on to another suite after this many loops

-- a shuffled order of all suites, starting with `first`
function M.playlist(first)
  local rest = {}
  for _, s in ipairs(M.SUITES) do if s ~= first then rest[#rest + 1] = s end end
  for i = #rest, 2, -1 do local j = love.math.random(i); rest[i], rest[j] = rest[j], rest[i] end
  table.insert(rest, 1, first)
  return rest
end

-- start a match: random first suite, then rotate through the rest
function M.match()
  -- start on a different soundtrack than the one that was just playing
  local first
  for _ = 1, 8 do
    first = M.SUITES[love.math.random(#M.SUITES)]
    if first ~= M.suite then break end
  end
  M.queue = M.playlist(first)
  M.qi = 1
  M.rotate = true
  M.start(M.queue[1])
end

function M.start(suite)
  if not love.audio then return end
  suite = suite or M.suite or ""
  if suite ~= M.suite then
    for _, st in pairs(stems) do st:stop() end
    stems = {}
    playing = false
    M.suite = suite
  end
  if not stems.ambient then
    for _, k in ipairs({ "ambient", "tension", "combat" }) do
      stems[k] = load(k .. suite)
      if stems[k] then stems[k]:setLooping(true); stems[k]:setVolume(0) end
    end
  end
  if stinger then stinger:stop(); stinger = nil end
  if playing then return end
  playing = true
  -- start somewhere random in the loop, so no two starts sound the same
  local off = 0
  if stems.ambient then
    local ok, dur = pcall(function() return stems.ambient:getDuration() end)
    if ok and dur and dur > 8 then off = love.math.random() * (dur - 4) end
  end
  lastTell, loops = off, 0
  for _, s in pairs(stems) do s:seek(off); s:play() end
  M.changedAt = love.timer.getTime()
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
  -- count loops; after a few, fade out and come back in with the next suite
  if stems.ambient and level ~= "menu" and M.rotate and not M.fadeOut then
    local t = stems.ambient:tell()
    if t < lastTell - 1 then loops = loops + 1 end
    lastTell = t
    if loops >= M.LOOPS_PER_SUITE and not swapping then swapping = true end
  end
  if swapping then
    swap = swap - dt / 2.5
    if swap <= 0 then
      swapping = false
      M.qi = (M.qi or 1) % #(M.queue or M.SUITES) + 1
      M.start((M.queue or M.SUITES)[M.qi])
      swap = 0
    end
  elseif swap < 1 then
    swap = math.min(1, swap + dt / 3)
  end
  master = master * math.max(0, swap)
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
  loops, swap, swapping = 0, 1, false
  lastTell = stems.ambient and stems.ambient:tell() or 0
end

-- title screen: make sure the calm layer is playing
function M.menu()
  if stinger and stinger:isPlaying() then return end
  M.fadeOut = nil
  M.rotate = false
  if not playing then
    M.reset()
    -- a different soundtrack from the one that just played
    local pick
    for _ = 1, 8 do
      pick = M.SUITES[love.math.random(#M.SUITES)]
      if pick ~= M.suite then break end
    end
    M.start(pick)
  end
  M.heat, M.floor = 0, 0
end

return M
