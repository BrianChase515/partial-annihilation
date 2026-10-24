-- Commander Craft: units, buildings, research and races (a Warcraft-style ruleset).
-- Costs are paid in full when you order something: gold, wood and food (supply).
-- work / 10 = seconds to build or train. tier: 1 = hall, 2 = Keep/Stronghold,
-- 3 = Castle/Fortress. Each production building researches upgrades for its own units.
return function(D)
  local U = D.units
  local LAND = { land = true, sea = true }
  local ALL = { land = true, sea = true, air = true }

  local function unit(t)
    t.craftOnly = true
    t.domain = t.domain or "land"
    t.shape = t.shape or (t.domain == "air" and "tri" or "square")
    t.cost.metal, t.cost.energy = 0, 0
    return t
  end
  local function building(t)
    t.craftOnly = true
    t.domain, t.building, t.place = "building", true, "land"
    t.cost.metal, t.cost.energy = 0, 0
    return t
  end
  local function research(t)
    t.craftOnly, t.research, t.domain = true, true, "research"
    t.cost.metal, t.cost.energy, t.cost.food = 0, 0, 0
    t.radius, t.hp, t.speed, t.sight = 1, 1, 0, 0
    t.short = t.short or "Up"
    return t
  end

  -- ================================================================== VANGUARD (order, steel, faith)
  U.peasant = unit({ name = "Peasant", short = "P", worker = true, radius = 8, hp = 240, speed = 80, sight = 260,
    buildPower = 10, buildRange = 100, melee = true,
    weapon = { damage = 6, range = 55, reload = 1.2, speed = 900, targets = LAND },
    cost = { gold = 75, wood = 0, food = 1, work = 120 }, xp = 15,
    desc = "Mines gold, chops wood and builds. Right-click a gold mine or a tree to gather." })
  U.footman = unit({ name = "Footman", short = "F", radius = 10, hp = 620, speed = 74, sight = 280, melee = true, armor = 0.85,
    weapon = { damage = 14, range = 65, reload = 1.1, speed = 900, targets = LAND },
    cost = { gold = 135, wood = 0, food = 2, work = 160 }, xp = 30,
    desc = "Melee. Sword-and-shield infantry that holds the line. Learn Defend at the Barracks." })
  U.rifleman = unit({ name = "Rifleman", short = "R", radius = 9, hp = 450, speed = 72, sight = 320,
    weapon = { damage = 22, range = 270, reload = 1.35, speed = 800, targets = ALL },
    cost = { gold = 175, wood = 25, food = 2, work = 190 }, xp = 32,
    desc = "Ranged. Long musket; hits ground and air." })
  U.knight = unit({ name = "Knight", short = "K", radius = 12, hp = 1150, speed = 100, sight = 300, melee = true, armor = 0.78, tier = 3,
    weapon = { damage = 30, range = 70, reload = 1.25, speed = 900, targets = LAND },
    cost = { gold = 245, wood = 60, food = 4, work = 280 }, xp = 60,
    desc = "Melee. Heavy cavalry: fast and very tough. Needs a Castle." })
  U.cleric = unit({ name = "Cleric", short = "C", radius = 9, hp = 380, speed = 70, sight = 300, tier = 2,
    weapon = { damage = 8, range = 230, reload = 1.6, speed = 700, targets = ALL },
    healer = { amount = 45, every = 1.8, range = 260 },
    cost = { gold = 140, wood = 20, food = 2, work = 200 }, xp = 30,
    desc = "Caster. Heals the most wounded ally nearby every couple of seconds. Needs a Keep." })
  U.magus = unit({ name = "Magus", short = "Mg", radius = 9, hp = 360, speed = 70, sight = 320, tier = 2,
    weapon = { damage = 10, range = 250, reload = 1.6, speed = 700, targets = ALL },
    slower = { every = 4, range = 320, dur = 6 },
    cost = { gold = 155, wood = 20, food = 2, work = 220 }, xp = 30,
    desc = "Caster. Slows an enemy fighter every few seconds (40% slower). Needs a Keep." })
  U.mortar = unit({ name = "Mortar Team", short = "M", radius = 11, hp = 420, speed = 55, sight = 300, tier = 2,
    weapon = { damage = 55, range = 470, minRange = 110, reload = 3.2, speed = 320, splash = 55, ballistic = true, targets = LAND, bldMul = 2.0 },
    cost = { gold = 190, wood = 70, food = 3, work = 260 }, xp = 40,
    desc = "Siege. Lobs shells that wreck buildings and clumps; weak up close. Needs a Keep." })
  U.gryphon = unit({ name = "Gryphon Rider", short = "G", domain = "air", radius = 12, hp = 820, speed = 140, sight = 360, tier = 3,
    weapon = { damage = 36, range = 110, reload = 1.4, speed = 800, targets = ALL },
    cost = { gold = 280, wood = 70, food = 4, work = 300 }, xp = 60,
    desc = "Air. Hammer-throwing flyer; only ranged attacks can hit it. Needs a Castle." })

  U.v_hall = building({ name = "Town Hall", short = "TH", w = 4, h = 4, hp = 3200, sight = 380, factory = true, buildPower = 10,
    hall = true, dropoff = { gold = true, wood = true }, food = 12, armor = 0.7,
    builds = { "peasant", "v_keep", "v_castle" },
    cost = { gold = 385, wood = 205, food = 0, work = 1100 },
    desc = "Trains Peasants and takes in gold and wood. Upgrades to Keep (tier 2) and Castle (tier 3). Provides 12 food." })
  U.v_farm = building({ name = "Farm", short = "Fm", w = 2, h = 2, hp = 500, sight = 200, food = 6, armor = 0.8,
    cost = { gold = 80, wood = 20, food = 0, work = 350 }, desc = "Provides 6 food (supply)." })
  U.v_barracks = building({ name = "Barracks", short = "Bk", w = 3, h = 3, hp = 1500, sight = 260, factory = true, buildPower = 10, armor = 0.8,
    builds = { "footman", "rifleman", "knight", "rv_defend", "rv_rifles", "rv_warhorse" },
    cost = { gold = 160, wood = 50, food = 0, work = 600 },
    desc = "Trains Footmen and Riflemen, Knights with a Castle. Researches Defend, Long Rifles and Warhorse Training." })
  U.v_mill = building({ name = "Lumber Mill", short = "LM", w = 3, h = 3, hp = 1000, sight = 260, factory = true, buildPower = 10, armor = 0.8,
    dropoff = { wood = true }, builds = { "rv_lumber", "rv_masonry" },
    cost = { gold = 120, wood = 0, food = 0, work = 500 },
    desc = "Takes in wood. Researches Improved Lumber Harvesting and Masonry (tougher buildings)." })
  U.v_forge = building({ name = "Blacksmith", short = "Bs", w = 3, h = 3, hp = 1200, sight = 260, factory = true, buildPower = 10, armor = 0.8,
    builds = { "r_weap1", "r_weap2", "r_weap3", "r_armor1", "r_armor2", "r_armor3" },
    cost = { gold = 140, wood = 60, food = 0, work = 550 },
    desc = "Forges weapon and armor upgrades for all your units (three levels each)." })
  U.v_altar = building({ name = "Altar of Kings", short = "Al", w = 3, h = 3, hp = 1100, sight = 260, factory = true, buildPower = 10, armor = 0.8,
    altar = true, builds = {}, cost = { gold = 180, wood = 50, food = 0, work = 600 },
    desc = "Summons more heroes (up to 3). Fallen heroes rise here." })
  U.v_tower = building({ name = "Guard Tower", short = "GT", w = 2, h = 2, hp = 900, sight = 420, armor = 0.7,
    weapon = { damage = 24, range = 330, reload = 1.0, speed = 800, targets = ALL },
    cost = { gold = 110, wood = 80, food = 0, work = 450 }, desc = "Shoots ground and air." })
  U.v_sanctum = building({ name = "Arcane Sanctum", short = "Sa", w = 3, h = 3, hp = 1100, sight = 260, factory = true, buildPower = 10, armor = 0.8, tier = 2,
    builds = { "cleric", "magus", "rv_cleric", "rv_magus" },
    cost = { gold = 150, wood = 140, food = 0, work = 650 },
    desc = "Trains Clerics and Magi. Researches their adept training. Needs a Keep." })
  U.v_workshop = building({ name = "Workshop", short = "Ws", w = 3, h = 3, hp = 1200, sight = 260, factory = true, buildPower = 10, armor = 0.8, tier = 2,
    builds = { "mortar", "rv_barrage" },
    cost = { gold = 140, wood = 140, food = 0, work = 650 },
    desc = "Builds Mortar Teams and researches Barrage. Needs a Keep." })
  U.v_aviary = building({ name = "Gryphon Aviary", short = "Av", w = 3, h = 3, hp = 1200, sight = 260, factory = true, buildPower = 10, armor = 0.8, tier = 3,
    builds = { "gryphon", "rv_hammers" },
    cost = { gold = 140, wood = 150, food = 0, work = 650 },
    desc = "Trains Gryphon Riders and researches Storm Hammers. Needs a Castle." })

  -- ================================================================== WARBAND (tribes, beasts, spirits)
  U.peon = unit({ name = "Peon", short = "P", worker = true, radius = 8, hp = 260, speed = 80, sight = 260,
    buildPower = 10, buildRange = 100, melee = true,
    weapon = { damage = 7, range = 55, reload = 1.2, speed = 900, targets = LAND },
    cost = { gold = 75, wood = 0, food = 1, work = 120 }, xp = 15,
    desc = "Mines gold, chops wood and builds. Right-click a gold mine or a tree to gather." })
  U.grunt = unit({ name = "Grunt", short = "G", radius = 11, hp = 760, speed = 72, sight = 280, melee = true, armor = 0.9,
    weapon = { damage = 18, range = 65, reload = 1.2, speed = 900, targets = LAND },
    cost = { gold = 170, wood = 0, food = 3, work = 190 }, xp = 40,
    desc = "Melee. Brutal axe infantry: more health and bite than a Footman, but more food." })
  U.headhunter = unit({ name = "Headhunter", short = "H", radius = 9, hp = 420, speed = 74, sight = 320,
    weapon = { damage = 23, range = 250, reload = 1.5, speed = 700, targets = ALL },
    cost = { gold = 150, wood = 20, food = 2, work = 180 }, xp = 30,
    desc = "Ranged. Throws spears at ground and air." })
  U.demolisher = unit({ name = "Demolisher", short = "D", radius = 12, hp = 500, speed = 52, sight = 300, tier = 2,
    weapon = { damage = 62, range = 450, minRange = 110, reload = 3.6, speed = 320, splash = 50, ballistic = true, targets = LAND, bldMul = 2.2 },
    cost = { gold = 220, wood = 50, food = 4, work = 280 }, xp = 45,
    desc = "Siege. Burning boulders flatten buildings; weak up close. Needs a Stronghold." })
  U.raider = unit({ name = "Raider", short = "Rd", radius = 12, hp = 900, speed = 112, sight = 300, melee = true, tier = 2,
    weapon = { damage = 22, range = 70, reload = 1.1, speed = 900, targets = LAND, bldMul = 1.6 },
    cost = { gold = 185, wood = 40, food = 3, work = 240 }, xp = 50,
    desc = "Melee. Wolf riders: fast, and they tear down buildings. Learn Ensnare at the Beastiary. Needs a Stronghold." })
  U.wyvern = unit({ name = "Wyvern Rider", short = "W", domain = "air", radius = 12, hp = 640, speed = 150, sight = 360, tier = 3,
    weapon = { damage = 28, range = 210, reload = 1.3, speed = 700, targets = ALL },
    cost = { gold = 265, wood = 40, food = 4, work = 280 }, xp = 55,
    desc = "Air. Flying spear thrower; hits ground and air. Needs a Fortress." })
  U.shaman = unit({ name = "Shaman", short = "S", radius = 9, hp = 360, speed = 70, sight = 300, tier = 2,
    weapon = { damage = 8, range = 230, reload = 1.6, speed = 700, targets = ALL },
    lust = { every = 7, range = 300, dur = 12, rof = 1.3, speed = 1.2 },
    cost = { gold = 130, wood = 25, food = 2, work = 200 }, xp = 30,
    desc = "Caster. Casts Bloodlust on a fighting ally every few seconds (+30% attack speed, +20% speed). Needs a Stronghold." })
  U.mystic = unit({ name = "Mystic", short = "My", radius = 9, hp = 340, speed = 70, sight = 300, tier = 2,
    weapon = { damage = 9, range = 230, reload = 1.6, speed = 700, targets = ALL },
    ward = { every = 3, range = 220, amount = 22 },
    cost = { gold = 145, wood = 25, food = 2, work = 210 }, xp = 30,
    desc = "Caster. A healing ward: every few seconds, all your units around her recover health. Needs a Stronghold." })
  U.ironhide = unit({ name = "Ironhide", short = "I", radius = 15, hp = 1500, speed = 70, sight = 300, melee = true, armor = 0.85, tier = 3,
    weapon = { damage = 34, range = 75, reload = 1.5, speed = 900, splash = 45, targets = LAND },
    cost = { gold = 280, wood = 80, food = 5, work = 320 }, xp = 70,
    desc = "Melee. A towering bull-man; every swing cleaves through everything around the target. Needs a Fortress." })

  U.w_hall = building({ name = "Great Hall", short = "GH", w = 4, h = 4, hp = 3600, sight = 380, factory = true, buildPower = 10,
    hall = true, dropoff = { gold = true, wood = true }, food = 12, armor = 0.7,
    builds = { "peon", "w_stronghold", "w_fortress" },
    cost = { gold = 385, wood = 185, food = 0, work = 1100 },
    desc = "Trains Peons and takes in gold and wood. Upgrades to Stronghold (tier 2) and Fortress (tier 3). Provides 12 food." })
  U.w_burrow = building({ name = "Burrow", short = "Bw", w = 2, h = 2, hp = 650, sight = 300, food = 7, armor = 0.75,
    weapon = { damage = 7, range = 240, reload = 1.2, speed = 700, targets = ALL },
    cost = { gold = 100, wood = 40, food = 0, work = 380 },
    desc = "Provides 7 food, and its defenders throw spears at anything close." })
  U.w_barracks = building({ name = "War Camp", short = "WC", w = 3, h = 3, hp = 1600, sight = 260, factory = true, buildPower = 10, armor = 0.8,
    builds = { "grunt", "headhunter", "demolisher", "rw_berserk", "rw_regen", "rw_oil" },
    cost = { gold = 180, wood = 50, food = 0, work = 600 },
    desc = "Trains Grunts, Headhunters and (Stronghold) Demolishers. Researches Berserker Strength, Troll Regeneration, Burning Oil." })
  U.w_forge = building({ name = "War Mill", short = "WM", w = 3, h = 3, hp = 1200, sight = 260, factory = true, buildPower = 10, armor = 0.8,
    dropoff = { gold = true, wood = true },
    builds = { "r_weap1", "r_weap2", "r_weap3", "r_armor1", "r_armor2", "r_armor3", "rw_pillage", "rw_spikes" },
    cost = { gold = 205, wood = 0, food = 0, work = 550 },
    desc = "Takes in gold and wood. Forges weapons and armor (three levels each), Pillage and Spiked Barricades." })
  U.w_altar = building({ name = "Altar of Storms", short = "Al", w = 3, h = 3, hp = 1100, sight = 260, factory = true, buildPower = 10, armor = 0.8,
    altar = true, builds = {}, cost = { gold = 180, wood = 50, food = 0, work = 600 },
    desc = "Summons more heroes (up to 3). Fallen heroes rise here." })
  U.w_tower = building({ name = "Watch Tower", short = "WT", w = 2, h = 2, hp = 850, sight = 420, armor = 0.7,
    weapon = { damage = 26, range = 320, reload = 1.0, speed = 800, targets = ALL },
    cost = { gold = 110, wood = 80, food = 0, work = 450 }, desc = "Shoots ground and air." })
  U.w_lodge = building({ name = "Spirit Lodge", short = "SL", w = 3, h = 3, hp = 1100, sight = 260, factory = true, buildPower = 10, armor = 0.8, tier = 2,
    builds = { "shaman", "mystic", "rw_shaman", "rw_mystic" },
    cost = { gold = 150, wood = 150, food = 0, work = 650 },
    desc = "Trains Shamans and Mystics and their adept training. Needs a Stronghold." })
  U.w_beastiary = building({ name = "Beastiary", short = "Be", w = 3, h = 3, hp = 1200, sight = 260, factory = true, buildPower = 10, armor = 0.8, tier = 2,
    builds = { "raider", "wyvern", "rw_ensnare", "rw_venom" },
    cost = { gold = 145, wood = 140, food = 0, work = 650 },
    desc = "Trains Raiders and (Fortress) Wyvern Riders. Researches Ensnare and Envenomed Spears. Needs a Stronghold." })
  U.w_totem = building({ name = "Bull Totem", short = "BT", w = 3, h = 3, hp = 1300, sight = 260, factory = true, buildPower = 10, armor = 0.8, tier = 3,
    builds = { "ironhide", "rw_pulverize" },
    cost = { gold = 135, wood = 155, food = 0, work = 650 },
    desc = "Trains Ironhides and researches Pulverize. Needs a Fortress." })

  U.peasant.builds = { "v_farm", "v_barracks", "v_mill", "v_forge", "v_altar", "v_tower", "v_sanctum", "v_workshop", "v_aviary", "v_hall" }
  U.peon.builds = { "w_burrow", "w_barracks", "w_forge", "w_altar", "w_tower", "w_lodge", "w_beastiary", "w_totem", "w_hall" }

  -- ================================================================== research
  local function hallUp(key, name, tier, after, cost, work, desc)
    U[key] = research({ name = name, short = "T" .. tier, tierUp = tier, tier = tier - 1, after = after,
      cost = { gold = cost[1], wood = cost[2], work = work }, desc = desc })
  end
  hallUp("v_keep", "Upgrade to Keep", 2, nil, { 320, 210 }, 600, "Tier 2: unlocks Arcane Sanctum, Workshop and new research. +1000 hall health.")
  hallUp("v_castle", "Upgrade to Castle", 3, "v_keep", { 360, 270 }, 750, "Tier 3: unlocks Knights, the Gryphon Aviary and top research. +1000 hall health.")
  hallUp("w_stronghold", "Upgrade to Stronghold", 2, nil, { 315, 190 }, 600, "Tier 2: unlocks Spirit Lodge, Beastiary, Demolishers and new research. +1000 hall health.")
  hallUp("w_fortress", "Upgrade to Fortress", 3, "w_stronghold", { 325, 190 }, 750, "Tier 3: unlocks the Bull Totem, Wyvern Riders and top research. +1000 hall health.")

  U.r_weap1 = research({ name = "Weapons I", short = "W1", stat = "weap", level = 1, cost = { gold = 100, wood = 50, work = 450 },
    desc = "+12% damage for all your units (not heroes or towers)." })
  U.r_weap2 = research({ name = "Weapons II", short = "W2", stat = "weap", level = 2, tier = 2, after = "r_weap1", cost = { gold = 175, wood = 175, work = 600 },
    desc = "Another +12% damage. Needs tier 2." })
  U.r_weap3 = research({ name = "Weapons III", short = "W3", stat = "weap", level = 3, tier = 3, after = "r_weap2", cost = { gold = 250, wood = 300, work = 750 },
    desc = "Another +12% damage. Needs tier 3." })
  U.r_armor1 = research({ name = "Armor I", short = "A1", stat = "armor", level = 1, cost = { gold = 100, wood = 75, work = 450 },
    desc = "Your units take 9% less damage (not heroes)." })
  U.r_armor2 = research({ name = "Armor II", short = "A2", stat = "armor", level = 2, tier = 2, after = "r_armor1", cost = { gold = 175, wood = 200, work = 600 },
    desc = "Another 9% less damage taken. Needs tier 2." })
  U.r_armor3 = research({ name = "Armor III", short = "A3", stat = "armor", level = 3, tier = 3, after = "r_armor2", cost = { gold = 250, wood = 325, work = 750 },
    desc = "Another 9% less damage taken. Needs tier 3." })

  -- Vanguard
  U.rv_defend = research({ name = "Defend", short = "Df", cost = { gold = 100, wood = 150, work = 450 },
    unitMods = { footman = { rangedArmor = 0.6 } }, desc = "Footmen raise their shields: 40% less damage from ranged attacks and towers." })
  U.rv_rifles = research({ name = "Long Rifles", short = "LR", tier = 2, cost = { gold = 75, wood = 125, work = 400 },
    unitMods = { rifleman = { range = 1.25 } }, desc = "Riflemen +25% range. Needs a Keep." })
  U.rv_warhorse = research({ name = "Warhorse Training", short = "WT", tier = 3, cost = { gold = 125, wood = 125, work = 450 },
    unitMods = { knight = { hp = 1.25 } }, desc = "Knights +25% health. Needs a Castle." })
  U.rv_lumber = research({ name = "Improved Lumber Harvesting", short = "IL", cost = { gold = 100, wood = 0, work = 400 },
    flag = "lumber", desc = "Workers carry 15 wood per trip instead of 10." })
  U.rv_masonry = research({ name = "Masonry", short = "Ms", tier = 2, cost = { gold = 125, wood = 75, work = 450 },
    flag = "masonry", desc = "Your buildings take 20% less damage. Needs a Keep." })
  U.rv_cleric = research({ name = "Cleric Adept Training", short = "CA", tier = 3, cost = { gold = 100, wood = 100, work = 450 },
    flag = "clericAdept", desc = "Clerics heal 60% more, more often. Needs a Castle." })
  U.rv_magus = research({ name = "Magus Adept Training", short = "MA", tier = 3, cost = { gold = 100, wood = 100, work = 450 },
    flag = "magusAdept", desc = "Magi slow two enemies at once, for longer. Needs a Castle." })
  U.rv_barrage = research({ name = "Barrage", short = "Br", tier = 2, cost = { gold = 125, wood = 150, work = 450 },
    unitMods = { mortar = { dmg = 1.2, splash = 1.3 } }, desc = "Mortar shells +20% damage and a wider blast. Needs a Keep." })
  U.rv_hammers = research({ name = "Storm Hammers", short = "SH", tier = 3, cost = { gold = 125, wood = 225, work = 450 },
    unitMods = { gryphon = { splash = 40 } }, desc = "Gryphon hammers bounce: damage splashes around the target. Needs a Castle." })

  -- Warband
  U.rw_berserk = research({ name = "Berserker Strength", short = "BS", tier = 2, cost = { gold = 100, wood = 150, work = 450 },
    unitMods = { grunt = { hp = 1.2, dmg = 1.12 } }, desc = "Grunts +20% health and +12% damage. Needs a Stronghold." })
  U.rw_regen = research({ name = "Troll Regeneration", short = "TR", tier = 2, cost = { gold = 100, wood = 100, work = 400 },
    unitMods = { headhunter = { regen = 4 } }, desc = "Headhunters regenerate 4 health a second. Needs a Stronghold." })
  U.rw_oil = research({ name = "Burning Oil", short = "BO", tier = 3, cost = { gold = 150, wood = 200, work = 450 },
    unitMods = { demolisher = { dmg = 1.25, splash = 1.25 } }, desc = "Demolisher boulders burn: +25% damage, wider blast. Needs a Fortress." })
  U.rw_pillage = research({ name = "Pillage", short = "Pl", cost = { gold = 75, wood = 25, work = 350 },
    flag = "pillage", desc = "Melee units steal gold when they hit enemy buildings." })
  U.rw_spikes = research({ name = "Spiked Barricades", short = "SB", tier = 2, cost = { gold = 100, wood = 125, work = 450 },
    flag = "spikes", desc = "Melee attackers take 20% of their damage back when they hit your buildings. Needs a Stronghold." })
  U.rw_shaman = research({ name = "Shaman Adept Training", short = "SA", tier = 3, cost = { gold = 100, wood = 100, work = 450 },
    flag = "shamanAdept", desc = "Bloodlust comes faster and lasts longer. Needs a Fortress." })
  U.rw_mystic = research({ name = "Mystic Adept Training", short = "MA", tier = 3, cost = { gold = 100, wood = 100, work = 450 },
    flag = "mysticAdept", desc = "Healing wards heal 60% more. Needs a Fortress." })
  U.rw_ensnare = research({ name = "Ensnare", short = "En", tier = 2, cost = { gold = 50, wood = 75, work = 350 },
    unitMods = { raider = { ensnare = true } }, desc = "Raiders' bolas slow what they hit. Needs a Stronghold." })
  U.rw_venom = research({ name = "Envenomed Spears", short = "ES", tier = 3, cost = { gold = 100, wood = 150, work = 450 },
    unitMods = { wyvern = { poison = 60 } }, desc = "Wyvern spears poison for 60 damage over 3 seconds. Needs a Fortress." })
  U.rw_pulverize = research({ name = "Pulverize", short = "Pv", tier = 3, cost = { gold = 100, wood = 200, work = 450 },
    unitMods = { ironhide = { dmg = 1.15, splash = 1.5 } }, desc = "Ironhides smash harder and wider. Needs a Fortress." })

  -- ================================================================== neutrals and the map
  U.goldmine = building({ name = "Gold Mine", short = "$", w = 3, h = 3, hp = 99999, sight = 0, neutralSite = true,
    cost = { gold = 0, wood = 0, food = 0, work = 1 },
    desc = "Workers mine gold here, one at a time. It runs dry eventually." })
  U.gnoll = unit({ name = "Gnoll Brute", short = "g", radius = 10, hp = 580, speed = 70, sight = 300, melee = true,
    weapon = { damage = 19, range = 65, reload = 1.2, speed = 900, targets = LAND },
    cost = { gold = 0, wood = 0, food = 0, work = 1 }, xp = 45, bounty = 15, desc = "A neutral creep." })
  U.gnollarcher = unit({ name = "Gnoll Archer", short = "a", radius = 9, hp = 395, speed = 70, sight = 320,
    weapon = { damage = 21, range = 240, reload = 1.4, speed = 700, targets = ALL },
    cost = { gold = 0, wood = 0, food = 0, work = 1 }, xp = 40, bounty = 15, desc = "A neutral creep." })
  U.ogrelord = unit({ name = "Ogre Warlord", short = "O", radius = 15, hp = 1965, speed = 66, sight = 320, melee = true, armor = 0.85,
    weapon = { damage = 50, range = 75, reload = 1.4, speed = 900, targets = LAND, splash = 40 },
    cost = { gold = 0, wood = 0, food = 0, work = 1 }, xp = 140, bounty = 100,
    desc = "The boss guarding the middle mine. Drops a gold bounty." })

  -- ================================================================== races
  D.CRAFT = {
    START_GOLD = 500, START_WOOD = 150, FOOD_CAP = 80,
    HERO_COST = { { gold = 0, wood = 0 }, { gold = 425, wood = 100 }, { gold = 425, wood = 135 } },
    HERO_FOOD = 5, MAX_HEROES = 3,
    races = {
      { key = "vanguard", name = "Vanguard", tag = "Order and steel: footmen and knights, riflemen, clerics and magi, mortars and gryphons.",
        hall = "v_hall", worker = "peasant", farm = "v_farm", barracks = "v_barracks", altar = "v_altar", forge = "v_forge",
        mill = "v_mill", tower = "v_tower", tiers = { "v_keep", "v_castle" }, tierNames = { "Town Hall", "Keep", "Castle" },
        heroes = { "warden", "ranger", "elementalist", "ascetic", "infiltrator" } },
      { key = "warband", name = "Warband", tag = "Tribes and beasts: grunts and raiders, headhunters, shamans and mystics, demolishers, wyverns and ironhides.",
        hall = "w_hall", worker = "peon", farm = "w_burrow", barracks = "w_barracks", altar = "w_altar", forge = "w_forge",
        mill = "w_forge", tower = "w_tower", tiers = { "w_stronghold", "w_fortress" }, tierNames = { "Great Hall", "Stronghold", "Fortress" },
        heroes = { "juggernaut", "shifter", "hexer", "spiritcaller", "reclaimer" } },
    },
  }
  D.CRAFT.byKey = {}
  for _, r in ipairs(D.CRAFT.races) do D.CRAFT.byKey[r.key] = r end
  -- hero recruits at the altars: one entry per class
  for _, r in ipairs(D.CRAFT.races) do
    local altar = U[r.altar]
    for _, cls in ipairs(r.heroes) do
      local key = "hero_" .. cls
      U[key] = { name = cls:sub(1, 1):upper() .. cls:sub(2), short = "H", craftOnly = true, heroRecruit = cls,
        domain = "research", radius = 1, hp = 1, speed = 0, sight = 0,
        cost = { gold = 425, wood = 100, food = 5, work = 350, metal = 0, energy = 0 },
        desc = "Summon this hero. Your 2nd and 3rd heroes cost gold and wood; three at most." }
      altar.builds[#altar.builds + 1] = key
    end
  end
end
