-- Unit and building definitions for Partial Annihilation.
-- cost: metal, energy, work (work / buildPower = seconds to build)
-- domain: land | sea | sub | air | building
-- weapon.targets: set of domains it can hit (buildings count as "land")

local D = {}

D.TILE = 32
D.VERSION = "0.13.2"  -- the first two numbers are the high-score season
D.SEASON = D.VERSION:match("^(%d+%.%d+)")

D.units = {
  commander = {
    name = "Commander", short = "CMD", domain = "land", shape = "commander",
    radius = 15, hp = 3000, speed = 58, sight = 340, turn = 6,
    buildPower = 12, buildRange = 130, regen = 4,
    builds = { "mex", "solar", "landfac", "airfac", "shipyard", "turret", "aaturret", "storage" },
    weapon = { damage = 45, range = 210, reload = 0.6, speed = 560, targets = { land = true, sea = true } },
    income = { metal = 1.0, energy = 15 },
    storage = { metal = 600, energy = 2500 },
    desc = "Your leader. Builds anything. If it dies, you lose.",
  },
  builder = {
    name = "Constructor", short = "B", domain = "land", shape = "square",
    radius = 10, hp = 260, speed = 74, sight = 260,
    buildPower = 7, buildRange = 105,
    builds = { "mex", "solar", "landfac", "airfac", "shipyard", "turret", "aaturret", "storage" },
    cost = { metal = 60, energy = 500, work = 60 },
    desc = "Builds structures. Right-click your own unfinished or damaged things to help or repair.",
  },
  scout = {
    name = "Scout", short = "1", domain = "land", shape = "square",
    radius = 8, hp = 130, speed = 155, sight = 420,
    weapon = { damage = 7, range = 150, reload = 0.35, speed = 650, targets = { land = true, sea = true } },
    cost = { metal = 35, energy = 280, work = 28 },
    desc = "Fast and fragile. Good for finding the enemy.",
  },
  tank = {
    name = "Tank", short = "2", domain = "land", shape = "square",
    radius = 12, hp = 650, speed = 72, sight = 290,
    weapon = { damage = 32, range = 190, reload = 1.0, speed = 520, targets = { land = true, sea = true } },
    cost = { metal = 115, energy = 850, work = 95 },
    desc = "Main battle unit. Solid all-rounder on land.",
  },
  artillery = {
    name = "Artillery", short = "3", domain = "land", shape = "square",
    radius = 12, hp = 300, speed = 50, sight = 270,
    weapon = { damage = 85, range = 440, minRange = 90, reload = 3.2, speed = 300, splash = 55, ballistic = true, targets = { land = true, sea = true } },
    cost = { metal = 160, energy = 1200, work = 130 },
    desc = "Long range, splash damage. Weak up close.",
  },
  flak = {
    name = "Flak Truck", short = "4", domain = "land", shape = "square",
    radius = 11, hp = 380, speed = 72, sight = 320,
    weapon = { damage = 30, range = 320, reload = 0.5, speed = 850, splash = 38, targets = { air = true } },
    cost = { metal = 105, energy = 900, work = 90 },
    desc = "Anti-air only. Flak bursts damage every aircraft nearby.",
  },
  fighter = {
    name = "Fighter", short = "1", domain = "air", shape = "tri",
    radius = 10, hp = 210, speed = 270, sight = 420,
    weapon = { damage = 19, range = 170, reload = 0.4, speed = 900, targets = { air = true } },
    cost = { metal = 90, energy = 1500, work = 80 },
    desc = "Fast air superiority. Only hits aircraft.",
  },
  bomber = {
    name = "Bomber", short = "2", domain = "air", shape = "tri",
    radius = 12, hp = 360, speed = 175, sight = 300,
    weapon = { damage = 130, range = 60, reload = 2.4, speed = 260, splash = 50, ballistic = true, bomb = true, targets = { land = true, sea = true } },
    cost = { metal = 150, energy = 2500, work = 140 },
    desc = "Drops heavy bombs on ground and ships.",
  },
  gunship = {
    name = "Gunship", short = "3", domain = "air", shape = "tri",
    radius = 12, hp = 520, speed = 135, sight = 320,
    weapon = { damage = 14, range = 175, reload = 0.3, speed = 700, targets = { land = true, sea = true } },
    cost = { metal = 200, energy = 2600, work = 160 },
    desc = "Hovering attacker. Steady damage to ground and ships.",
  },
  boat = {
    name = "Patrol Boat", short = "1", domain = "sea", shape = "circle",
    radius = 11, hp = 420, speed = 115, sight = 360,
    weapon = { damage = 18, range = 210, reload = 0.55, speed = 700, targets = { land = true, sea = true, air = true } },
    cost = { metal = 100, energy = 700, work = 80 },
    desc = "Fast boat. Hits land, sea and air (lightly).",
  },
  destroyer = {
    name = "Destroyer", short = "2", domain = "sea", shape = "circle",
    radius = 16, hp = 1500, speed = 70, sight = 360,
    weapon = { damage = 62, range = 330, reload = 1.5, speed = 560, targets = { land = true, sea = true, sub = true } },
    cost = { metal = 260, energy = 1700, work = 200 },
    desc = "Heavy warship. Long guns and depth charges for subs.",
  },
  battleship = {
    name = "Battleship", short = "4", domain = "sea", shape = "circle",
    radius = 22, hp = 4200, speed = 40, sight = 460,
    weapon = { damage = 55, range = 1300, minRange = 200, reload = 3.6, speed = 420, splash = 48, ballistic = true,
      targets = { land = true, sea = true } },
    cost = { metal = 800, energy = 5500, work = 520 },
    desc = "Siege ship. Shells anything within 40 tiles, but slowly. Can't hit aircraft or subs. Everyone will hunt it.",
  },
  seabuilder = {
    name = "Sea Constructor", short = "B", domain = "sea", shape = "circle",
    radius = 12, hp = 500, speed = 80, sight = 300,
    buildPower = 8, buildRange = 110,
    builds = { "mex", "tidal", "seabattery", "shipyard" },
    cost = { metal = 90, energy = 700, work = 75 },
    desc = "Builds offshore extractors, tidal generators, Sea Batteries and shipyards.",
  },
  sub = {
    name = "Submarine", short = "3", domain = "sub", shape = "circle",
    radius = 12, hp = 700, speed = 82, sight = 300,
    weapon = { damage = 150, range = 230, reload = 3.0, speed = 260, torpedo = true, targets = { sea = true, sub = true } },
    cost = { metal = 200, energy = 1500, work = 170 },
    desc = "Torpedoes ships. Only ships can hit it.",
  },

  walker = {
    name = "Alien Walker", short = "W", domain = "land", shape = "walker",
    radius = 26, hp = 9000, speed = 42, sight = 480, regen = 15,
    weapon = { damage = 150, range = 340, reload = 1.1, speed = 520, splash = 60, targets = { land = true, sea = true, air = true } },
    cost = { metal = 1500, energy = 0, work = 1 },
    desc = "Alien tech. Devastating guns that hit land, sea and air. Claimed by holding its zone.",
  },

  -- Commander Arena summons ------------------------------------------
  drone = {
    name = "Drone", short = "R", domain = "land", shape = "square", arenaOnly = true,
    radius = 10, hp = 520, speed = 80, sight = 300,
    weapon = { damage = 26, range = 170, reload = 0.9, speed = 560, targets = { land = true, sea = true } },
    cost = { metal = 50, energy = 0, work = 1 },
    desc = "A wreck rebuilt by a Reclaimer. Fights for its master.",
  },
  wolf = {
    name = "Wolf", short = "W", domain = "land", shape = "square", arenaOnly = true,
    radius = 10, hp = 720, speed = 112, sight = 300,
    weapon = { damage = 30, range = 110, reload = 0.7, speed = 700, targets = { land = true, sea = true } },
    cost = { metal = 50, energy = 0, work = 1 },
    desc = "A Shifter's loyal hunter.",
  },
  shadow = {
    name = "Shadow Clone", short = "SC", domain = "land", shape = "square", arenaOnly = true,
    radius = 13, hp = 1300, speed = 80, sight = 330,
    weapon = { damage = 55, range = 200, reload = 0.6, speed = 600, targets = { land = true, sea = true } },
    cost = { metal = 50, energy = 0, work = 1 },
    desc = "An Infiltrator's shadow. Gone in 15 seconds.",
  },
  decoy = {
    name = "Decoy", short = "D", domain = "land", shape = "square", arenaOnly = true,
    radius = 13, hp = 1500, speed = 0, sight = 200,
    cost = { metal = 50, energy = 0, work = 1 },
    desc = "Draws enemy fire.",
  },
  sentry = {
    name = "Lightning Sentry", short = "LS", domain = "building", building = true, arenaOnly = true,
    w = 1, h = 1, place = "land", hp = 600, sight = 320,
    weapon = { damage = 28, range = 270, reload = 0.45, speed = 900, targets = { land = true, sea = true } },
    cost = { metal = 40, energy = 0, work = 1 },
    desc = "An Infiltrator's trap turret.",
  },

  ghoul = {
    name = "Ghoul", short = "G", domain = "land", shape = "square", arenaOnly = true,
    radius = 9, hp = 400, speed = 98, sight = 280,
    weapon = { damage = 18, range = 100, reload = 0.6, speed = 700, targets = { land = true, sea = true } },
    cost = { metal = 40, energy = 0, work = 1 },
    desc = "A Hexer's shambling servant.",
  },
  gargantuan = {
    name = "Gargantuan", short = "GG", domain = "land", shape = "square", arenaOnly = true,
    radius = 17, hp = 2600, speed = 72, sight = 300,
    weapon = { damage = 70, range = 120, reload = 1.1, speed = 600, splash = 45, targets = { land = true, sea = true } },
    cost = { metal = 200, energy = 0, work = 1 },
    desc = "A hulking brute raised by a Hexer's ultimate.",
  },

  -- Arena jungle: neutral camps and the Colossus (they only fight back) ---------------
  scavenger = {
    name = "Scavenger", short = "s", domain = "land", shape = "square", arenaOnly = true, jungle = true,
    radius = 10, hp = 650, speed = 75, sight = 260, xp = 70,
    weapon = { damage = 26, range = 130, reload = 0.8, speed = 650, targets = { land = true, sea = true } },
    cost = { metal = 60, energy = 0, work = 1 },
    desc = "A feral salvage drone guarding its scrap pile. Only fights if you start it.",
  },
  ravager = {
    name = "Ravager", short = "RV", domain = "land", shape = "square", arenaOnly = true, jungle = true,
    radius = 15, hp = 2200, speed = 65, sight = 280, xp = 210,
    weapon = { damage = 70, range = 150, reload = 1.2, speed = 600, splash = 40, targets = { land = true, sea = true } },
    cost = { metal = 200, energy = 0, work = 1 },
    desc = "A heavy jungle brute. Worth a lot of experience.",
  },
  colossus = {
    name = "Colossus", short = "COL", domain = "land", shape = "square", arenaOnly = true, jungle = true, boss = true,
    radius = 26, hp = 16000, speed = 45, sight = 340, xp = 900,
    weapon = { damage = 150, range = 230, reload = 1.6, speed = 520, splash = 70, targets = { land = true, sea = true } },
    cost = { metal = 1500, energy = 0, work = 1 },
    desc = "The ancient war machine in the pit. Whoever brings it down wins the Colossus Crest for their whole side.",
  },

  -- Commander Arena structures (not buildable) ------------------------
  atower = {
    name = "Defense Tower", short = "DT", domain = "building", building = true, arenaOnly = true,
    w = 2, h = 2, place = "land", hp = 2000, sight = 420,
    weapon = { damage = 75, range = 330, reload = 1.0, speed = 760, targets = { land = true, sea = true } },
    cost = { metal = 600, energy = 0, work = 1 },
    desc = "Guards a lane. Shoots creeps first, and Commanders who attack a Commander under it.",
  },
  core = {
    name = "Core", short = "CORE", domain = "building", building = true, arenaOnly = true,
    w = 4, h = 4, place = "land", hp = 5000, sight = 460,
    weapon = { damage = 130, range = 380, reload = 0.85, speed = 800, targets = { land = true, sea = true } },
    cost = { metal = 1500, energy = 0, work = 1 },
    desc = "Destroy the enemy Core to win. Heals friendly Commanders nearby.",
  },

  -- Buildings ---------------------------------------------------------
  mex = {
    name = "Metal Extractor", short = "M", domain = "building", building = true,
    w = 1, h = 1, place = "deposit", hp = 400,
    income = { metal = 1.6 },
    cost = { metal = 50, energy = 300, work = 45 },
    desc = "Build on a metal deposit. +1.6 metal per second (+2.6 on a rich deposit: gold ring in the middle, teal ring offshore).",
  },
  solar = {
    name = "Solar Collector", short = "E", domain = "building", building = true,
    w = 2, h = 2, place = "land", hp = 500,
    income = { energy = 14 },
    cost = { metal = 70, energy = 0, work = 55 },
    desc = "+14 energy per second.",
  },
  seabattery = {
    name = "Sea Battery", short = "SB", domain = "building", building = true,
    w = 2, h = 2, place = "water", hp = 1900,
    weapon = { damage = 34, range = 330, reload = 0.45, speed = 820, splash = 30, targets = { land = true, sea = true, air = true } },
    cost = { metal = 170, energy = 1100, work = 120 },
    desc = "A floating gun platform. Tougher than a Gun Tower and hits land, sea AND air. Built on water by Sea Constructors.",
  },
  tidal = {
    name = "Tidal Generator", short = "TG", domain = "building", building = true,
    w = 2, h = 2, place = "water", hp = 450,
    income = { energy = 24 },
    cost = { metal = 80, energy = 0, work = 60 },
    desc = "+24 energy per second. Must be built on water (Sea Constructor).",
  },
  storage = {
    name = "Storage", short = "S", domain = "building", building = true,
    w = 2, h = 2, place = "land", hp = 800,
    storage = { metal = 1000, energy = 4000 },
    cost = { metal = 90, energy = 400, work = 60 },
    desc = "+1000 metal and +4000 energy storage.",
  },
  landfac = {
    name = "Vehicle Plant", short = "VP", domain = "building", building = true,
    w = 3, h = 3, place = "land", hp = 2400, factory = true, buildPower = 10,
    builds = { "builder", "scout", "tank", "artillery", "flak" },
    cost = { metal = 280, energy = 900, work = 190 },
    desc = "Builds land units.",
  },
  airfac = {
    name = "Aircraft Plant", short = "AP", domain = "building", building = true,
    w = 3, h = 3, place = "land", hp = 2000, factory = true, buildPower = 10,
    builds = { "fighter", "bomber", "gunship" },
    cost = { metal = 340, energy = 1600, work = 240 },
    desc = "Builds aircraft.",
  },
  shipyard = {
    name = "Shipyard", short = "SY", domain = "building", building = true,
    w = 3, h = 3, place = "water", hp = 2400, factory = true, buildPower = 10,
    builds = { "seabuilder", "boat", "destroyer", "sub", "battleship" },
    cost = { metal = 300, energy = 1000, work = 210 },
    desc = "Builds ships. Must be placed on water.",
  },
  turret = {
    name = "Gun Tower", short = "T", domain = "building", building = true,
    w = 1, h = 1, place = "land", hp = 1600,
    weapon = { damage = 30, range = 300, reload = 0.5, speed = 650, targets = { land = true, sea = true } },
    cost = { metal = 85, energy = 650, work = 80 },
    desc = "Defensive tower against land units and ships.",
  },
  aaturret = {
    name = "AA Tower", short = "A", domain = "building", building = true,
    w = 1, h = 1, place = "land", hp = 900,
    weapon = { damage = 34, range = 340, reload = 0.5, speed = 900, splash = 38, targets = { air = true } },
    cost = { metal = 95, energy = 750, work = 80 },
    desc = "Defensive tower against aircraft.",
  },
}

-- Commander Craft (Warcraft-style mode): its own units, buildings, research and races
require("src.craft_defs")(D)

-- Fill in derived fields
for key, d in pairs(D.units) do
  d.key = key
  if d.building then
    d.radius = math.max(d.w, d.h) * D.TILE * 0.5
    d.sight = d.sight or (d.weapon and d.weapon.range + 60 or 240)
  end
  if d.weapon then
    d.weapon.minRange = d.weapon.minRange or 0
    d.weapon.splash = d.weapon.splash or 0
  end
end

-- Which weapon target flag hits which domain
function D.canHit(weapon, targetDomain)
  if targetDomain == "building" then return weapon.targets.land end
  return weapon.targets[targetDomain] == true
end

D.hotkeys = { "q", "w", "e", "r", "t", "y", "u", "i" }

D.teamColor = {
  [0] = { 0.72, 0.42, 1.00 },  -- neutral alien tech / undecided drop crews
  [-1] = { 0.62, 0.52, 0.30 }, -- marauders (drop crews that attacked)
  [1] = { 0.30, 0.62, 1.00 },
  [2] = { 1.00, 0.34, 0.28 },
  [3] = { 0.35, 0.85, 0.40 },
  [4] = { 1.00, 0.78, 0.22 },
  [5] = { 0.20, 0.85, 0.80 },
  [6] = { 1.00, 0.48, 0.78 },
  [7] = { 0.62, 0.45, 1.00 },
  [8] = { 1.00, 0.58, 0.20 },
  [9] = { 0.92, 0.92, 0.95 },
  [10] = { 0.62, 0.40, 0.25 },
}
D.teamName = { "Blue", "Red", "Green", "Gold", "Teal", "Pink", "Violet", "Orange", "White", "Brown", [0] = "Neutral", [-1] = "Marauders" }
-- Groovy modifier palette (60s/70s): turquoise, hot pink, lime, tangerine
D.groovyColor = {
  [-1] = { 0.95, 0.95, 0.30 },
  [0] = { 0.85, 0.35, 1.00 },
  [1] = { 0.10, 0.88, 0.85 },
  [2] = { 1.00, 0.22, 0.68 },
  [3] = { 0.62, 1.00, 0.18 },
  [4] = { 1.00, 0.58, 0.08 },
}

-- AI strength by level 1..10 (5 matches the original "Normal")
function D.aiLevel(n)
  n = math.max(1, math.min(10, n or 5))
  local income = n <= 5 and (0.6 + 0.1 * (n - 1)) or (1.0 + 0.12 * (n - 5))
  return {
    level = n,
    income = income,
    think = math.max(0.4, 2.4 - 0.25 * (n - 1)),
    waveBase = math.max(5, math.floor(11 - 0.75 * (n - 1) + 0.5)),
    waveGrow = 1 + math.floor(n / 4),
    firstWave = math.max(90, 540 - 75 * (n - 1)),
    maxFactories = 2 + math.floor(n / 2),
    turrets = 1 + math.floor(n / 3) + (n >= 5 and 1 or 0),
    builderBonus = n >= 7 and 1 or 0,
    retreat = n >= 4,          -- pulls badly damaged units home
    raids = n >= 6,            -- occasional harassment of outlying extractors
  }
end

-- AI personalities, independent of strength. Multipliers adjust the level's values.
D.profiles = {
  { key = "Balanced",   desc = "Plays a bit of everything.", hunters = 2, huntersFrom = 300, huntersChance = 0.5 },
  { key = "Aggressive", desc = "Rushes early and keeps the pressure on.",
    firstWaveMul = 0.55, waveMul = 0.7, turretMul = 0.3, expandMul = 0.8, hunters = 3, huntersFrom = 150,
    weights = { tank = 1.4, scout = 1.6, artillery = 0.5 } },
  { key = "Turtle",     desc = "Rings its base and outposts with towers, parks battleships in its harbor, attacks late with big waves.", commander = "cautious",
    firstWaveMul = 1.7, waveMul = 1.6, turretMul = 3, turretBonus = 2, aaBonus = 2, expandMul = 0.7, fortify = true, fortifyFrom = 140, harbor = true,
    weights = { artillery = 2.2, flak = 1.5, destroyer = 1.5 } },
  { key = "Boomer",     desc = "Grabs the whole map's metal, then floods you.",
    firstWaveMul = 1.5, waveMul = 1.5, expandMul = 1.8, builderBonus = 2, factoryEcoMul = 0.75 },
  { key = "Air",        desc = "Rules the skies.", airFirst = true, factoryAirShare = 0.75,
    weights = { fighter = 1.3, bomber = 1.5, gunship = 1.5, flak = 0.5 } },
  { key = "Naval",      desc = "Builds a navy wherever there is water.", navalFirst = true,
    weights = { destroyer = 1.5, sub = 1.3, boat = 1.3 } },
  { key = "Raider",     desc = "Constant hit-and-run attacks on your extractors.", raidEvery = 50, hunters = 4, huntersFrom = 120,
    weights = { scout = 2.5, gunship = 1.6, boat = 1.4 } },
  { key = "Warlord",    desc = "Its Commander leads from the front, hunts for kills and nukes early.", commander = "aggressive",
    firstWaveMul = 0.8, builderBonus = 1, hunters = 3, huntersFrom = 210, weights = { tank = 1.3, artillery = 1.2 } },
  { key = "Random",     desc = "One of the above, chosen secretly." },
}
function D.profile(key)
  for _, p in ipairs(D.profiles) do if p.key == key then return p end end
  return D.profiles[1]
end

return D
