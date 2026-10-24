-- Ghost opponents for Annihilation, learned from the player's own games.
--   Mirror  - plays like you: your unit mix, expansion speed, defences and attack timing
--   Nemesis - plays against you: finds your habits and builds to punish one or two of them
-- Every finished Annihilation game (a win or a loss, not a game you quit) adds a summary to a
-- small file in the save folder. The file is per game version, so each new build starts fresh.
-- Five finished games unlock both opponents.
local D = require("src.defs")
local U = require("src.util")

local GH = {}
GH.NEEDED = 5
GH.KEEP = 20 -- remember the last twenty games

local function fileName() return "ghost_" .. D.VERSION:gsub("[^%w]", "_") .. ".lua" end

-- tiny serializer for plain tables of numbers, strings and booleans
local function ser(v, ind)
  ind = ind or ""
  local t = type(v)
  if t == "number" then return string.format("%.4g", v)
  elseif t == "string" then return string.format("%q", v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "table" then
    local out = { "{\n" }
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
      out[#out + 1] = ind .. "  " .. key .. " = " .. ser(v[k], ind .. "  ") .. ",\n"
    end
    out[#out + 1] = ind .. "}"
    return table.concat(out)
  end
  return "nil"
end

function GH.load()
  if GH.data then return GH.data end
  local data
  local ok, chunk = pcall(love.filesystem.load, fileName())
  if ok and chunk then
    local ok2, t = pcall(chunk)
    if ok2 and type(t) == "table" then data = t end
  end
  GH.data = data or { games = {}, completed = 0, unlocked = false }
  return GH.data
end

function GH.save()
  pcall(love.filesystem.write, fileName(), "return " .. ser(GH.data) .. "\n")
end

function GH.unlocked() return GH.load().unlocked end
function GH.completed() return GH.load().completed or 0 end

---------------------------------------------------------------------------
-- Recording: one per game, fed by the world as things happen

function GH.newRecorder(world)
  local rec = { units = {}, built = {}, mex5 = 0, mex10 = 0, firstAttack = nil, cmdUps = {}, oppLevel = 5 }
  world.onProduced = function(u)
    if u.team == 1 then rec.units[u.key] = (rec.units[u.key] or 0) + 1 end
  end
  return rec
end

function GH.onBuilt(rec, b)
  if rec and b.team == 1 and b.def.building then rec.built[b.key] = (rec.built[b.key] or 0) + 1 end
end

-- every few seconds: extractor count checkpoints and the first time our army reaches an enemy base
function GH.sample(rec, world)
  if not rec then return end
  local t = world.time
  local mex = 0
  for _, e in ipairs(world.entities) do if e.alive and e.team == 1 and e.key == "mex" then mex = mex + 1 end end
  if t <= 300 then rec.mex5 = mex end
  if t <= 600 then rec.mex10 = mex end
  if not rec.firstAttack then
    for tt = 2, world.np do
      if world:hostile(tt, 1) then
        local tm = world.teams[tt]
        local n = 0
        for _, e in ipairs(world.entities) do
          if e.alive and e.team == 1 and e.def.weapon and not e.def.building and e.key ~= "commander"
            and U.dist(e.x, e.y, tm.startX, tm.startY) < 1100 then n = n + 1 end
        end
        if n >= 3 then rec.firstAttack = t; break end
      end
    end
  end
end

-- a game reached its end (won or lost): file it; returns true if this one unlocked the ghosts
function GH.finish(rec, world)
  if not rec then return false end
  local data = GH.load()
  local c = world.teams[1].commander
  if c and c.upgrades then for _, u in ipairs(c.upgrades) do rec.cmdUps[#rec.cmdUps + 1] = u.key end end
  rec.length = world.time
  rec.oppLevel = rec.oppLevel or 5
  rec.won = world.over and world.over.winnerAlly == world.ally[1] or false
  if not rec.firstAttack then rec.firstAttack = world.time end
  table.insert(data.games, rec)
  while #data.games > GH.KEEP do table.remove(data.games, 1) end
  data.completed = (data.completed or 0) + 1
  local just = false
  if not data.unlocked and data.completed >= GH.NEEDED then data.unlocked = true; just = true end
  GH.save()
  GH.install()
  return just
end

---------------------------------------------------------------------------
-- What the games say about you

local AIR = { fighter = true, bomber = true, gunship = true }
local SEA = { boat = true, destroyer = true, sub = true, battleship = true, seabuilder = true }
local ARMY = { scout = true, tank = true, artillery = true, flak = true, fighter = true, bomber = true, gunship = true,
  boat = true, destroyer = true, sub = true, battleship = true }
-- a "typical" army, to compare yours against
local BASE = { tank = 0.45, artillery = 0.14, scout = 0.12, flak = 0.06, fighter = 0.06, bomber = 0.06, gunship = 0.06,
  boat = 0.02, destroyer = 0.02, sub = 0.01, battleship = 0.005 }

function GH.habits()
  local data = GH.load()
  local n = #data.games
  if n == 0 then return nil end
  local units, total = {}, 0
  local turrets, aa, mex5, mex10, first, builders = 0, 0, 0, 0, 0, 0
  for _, g in ipairs(data.games) do
    for k, v in pairs(g.units or {}) do
      if ARMY[k] then units[k] = (units[k] or 0) + v; total = total + v end
      if k == "builder" then builders = builders + v end
    end
    turrets = turrets + ((g.built or {}).turret or 0)
    aa = aa + ((g.built or {}).aaturret or 0)
    mex5, mex10 = mex5 + (g.mex5 or 0), mex10 + (g.mex10 or 0)
    first = first + (g.firstAttack or 600)
  end
  local h = { games = n, share = {}, total = total / n }
  for k in pairs(ARMY) do h.share[k] = total > 0 and (units[k] or 0) / total or 0 end
  local air, sea = 0, 0
  for k, v in pairs(h.share) do if AIR[k] then air = air + v end; if SEA[k] then sea = sea + v end end
  h.air, h.sea = air, sea
  h.antiAir = h.share.flak + h.share.fighter + (aa / n) * 0.03
  h.turrets, h.aa = turrets / n, aa / n
  h.mex5, h.mex10 = mex5 / n, mex10 / n
  h.firstAttack = first / n
  h.builders = builders / n
  h.tankShare = h.share.tank
  return h
end

-- Mirror: an AI personality set from your averages
function GH.mirror()
  local h = GH.habits()
  local p = { key = "Mirror", ghost = true, desc = "Plays like you, learned from your last games.", weights = {} }
  if not h then return p end
  for k, b in pairs(BASE) do
    p.weights[k] = U.clamp((h.share[k] + 0.01) / (b + 0.01), 0.1, 4)
  end
  if h.air > 0.35 then p.airFirst = true; p.factoryAirShare = math.min(0.85, h.air + 0.1) end
  if h.sea > 0.3 then p.navalFirst = true end
  p.firstWaveMul = U.clamp(h.firstAttack / 240, 0.5, 2.2)
  p.turretMul = U.clamp(h.turrets / 3, 0.15, 3.5)
  p.aaBonus = math.floor(h.aa / 2)
  p.expandMul = U.clamp((h.mex10 > 0 and h.mex10 or 6) / 8, 0.6, 1.9)
  p.builderBonus = math.floor(U.clamp((h.builders - 5) / 2, 0, 3))
  if h.turrets >= 8 then p.fortify, p.fortifyFrom = true, 160 end
  if h.share.scout > 0.25 then p.hunters, p.huntersFrom = 3, 150 end
  local bits = {}
  bits[#bits + 1] = string.format("%d%% air", math.floor(h.air * 100 + 0.5))
  bits[#bits + 1] = string.format("%d%% tanks", math.floor(h.tankShare * 100 + 0.5))
  bits[#bits + 1] = string.format("%.0f turrets", h.turrets)
  bits[#bits + 1] = string.format("first push ~%d:%02d", math.floor(h.firstAttack / 60), math.floor(h.firstAttack % 60))
  p.desc = "Plays like you (from your last " .. h.games .. " games): " .. table.concat(bits, ", ") .. "."
  return p
end

-- Nemesis: picks the two habits it can punish hardest
function GH.nemesis()
  local h = GH.habits()
  local p = { key = "Nemesis", ghost = true, desc = "Plays against your habits.", weights = {} }
  if not h then return p end
  local cands = {}
  local function add(score, text, apply) cands[#cands + 1] = { score = score, text = text, apply = apply } end
  -- little anti-air: come from the sky
  add((0.12 - h.antiAir) * 10 + (h.aa < 1 and 0.4 or 0), "you rarely build anti-air", function()
    p.airFirst, p.factoryAirShare = true, 0.7
    p.weights.gunship, p.weights.bomber = 1.9, 1.7
  end)
  -- a slow expansion: raid early
  add((7 - h.mex5) / 4, "you expand slowly", function()
    p.raidEvery, p.hunters, p.huntersFrom = 55, 3, 120
    p.weights.scout = 2
  end)
  -- few defences: rush
  add((3 - h.turrets) / 3 + (h.firstAttack > 330 and 0.3 or 0), "you build few defences", function()
    p.firstWaveMul, p.waveMul = 0.55, 0.75
    p.weights.tank = 1.5
  end)
  -- a turtle: out-range the walls (artillery with spotters)
  add((h.turrets - 6) / 4, "you turtle behind turrets", function()
    p.weights.artillery, p.spotChance = 2.6, 1
    p.firstWaveMul = 1.1
  end)
  -- an air player: flak, fighters and AA everywhere
  add((h.air - 0.3) * 4, "you lean on aircraft", function()
    p.weights.flak, p.weights.fighter = 2.6, 2.4
    p.aaBonus = 3
  end)
  -- massed tanks: bombers and gunships
  add((h.tankShare - 0.55) * 4, "you mass tanks", function()
    p.weights.bomber, p.weights.gunship = (p.weights.bomber or 1) * 1.6, (p.weights.gunship or 1) * 1.6
    p.weights.artillery = (p.weights.artillery or 1) * 1.4
  end)
  -- late first push: boom
  add((h.firstAttack - 420) / 180, "you attack late", function()
    p.expandMul, p.builderBonus = 1.6, 2
  end)
  table.sort(cands, function(a, b) return a.score > b.score end)
  local used = {}
  for i = 1, 2 do
    local c = cands[i]
    if c and c.score > 0 then c.apply(); used[#used + 1] = c.text end
  end
  if #used == 0 then
    -- no clear weakness: a sharp all-rounder
    p.firstWaveMul, p.expandMul = 0.85, 1.2
    used[1] = "no obvious weakness yet, so it just plays sharp"
  end
  p.insights = used
  p.desc = "Plays against you: " .. table.concat(used, " and ") .. "."
  return p
end

-- the strength they play at (no difficulty pick for them): Mirror matches the level you usually
-- face, nudged by how you've been doing; Nemesis plays one level above that
function GH.level(kind)
  local data = GH.load()
  local n, sum, wins = 0, 0, 0
  for _, g in ipairs(data.games) do n = n + 1; sum = sum + (g.oppLevel or 5); if g.won then wins = wins + 1 end end
  local L = n > 0 and sum / n or 5
  local rate = n > 0 and wins / n or 0.5
  if rate > 0.6 then L = L + 1 elseif rate < 0.4 then L = L - 1 end
  L = math.floor(L + 0.5)
  if kind == "Nemesis" then L = L + 1 end
  return math.max(1, math.min(10, L))
end

-- put the two into the personality list (after Random) once they're unlocked
function GH.install()
  if not GH.unlocked() then return end
  local have = {}
  for i, p in ipairs(D.profiles) do if p.ghost then have[p.key] = i end end
  local m, n = GH.mirror(), GH.nemesis()
  if have.Mirror then D.profiles[have.Mirror] = m else D.profiles[#D.profiles + 1] = m end
  if have.Nemesis then D.profiles[have.Nemesis] = n else D.profiles[#D.profiles + 1] = n end
end

GH.UNLOCK_TEXT = "New opponents unlocked: MIRROR and NEMESIS.\n" ..
  "Mirror plays like you - your unit mix, how fast you expand, how much you defend and when you attack.\n" ..
  "Nemesis plays against you - it finds two of your habits (no anti-air? slow expansion?) and punishes them.\n" ..
  "Both learn from your last games on this version. Pick them as an enemy personality."

return GH
