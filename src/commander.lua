-- Commander progression: levels from his own kills, a roguelike upgrade pick
-- (2 random choices from 20) at levels 1-4, and the Nuke at level 5. In long games he keeps
-- going: every level after 5 adds another nuke (stored, ready at once), each level a good deal
-- harder to reach than the last.
local C = {}

-- Commander XP = metal value of everything he personally destroys (cumulative per level)
C.THRESHOLDS = { 300, 820, 1650, 2850, 4500, 9000, 16000, 26000, 40000, 60000 }
C.MAX_LEVEL = 10
C.NUKE_LEVEL = 5
C.NUKE_RADIUS = 280
C.NUKE_COOLDOWN = 600      -- seconds of game time
C.NUKE_SPEED = 420         -- missile speed (it's a long, visible flight)

-- Each upgrade sets fields in cmd.mods (read by the world) or does something once.
C.upgrades = {
  { key = "hull",      name = "Reinforced Hull",    desc = "+40% max health.",
    apply = function(w, e) e.mods.hp = (e.mods.hp or 1) * 1.4; local old = e.maxhp; e.maxhp = math.floor(e.def.hp * e.mods.hp * (e.hpMul or 1)); e.hp = e.hp + (e.maxhp - old) end },
  { key = "regen",     name = "Nano Regeneration",  desc = "Repairs himself 25 HP per second, even in combat.",
    apply = function(w, e) e.mods.regen = 25 end },
  { key = "cannon",    name = "Heavy Cannon",       desc = "+60% weapon damage.",
    apply = function(w, e) e.mods.dmg = (e.mods.dmg or 1) * 1.6 end },
  { key = "loader",    name = "Rapid Loader",       desc = "Fires 50% faster.",
    apply = function(w, e) e.mods.rof = (e.mods.rof or 1) * 1.5 end },
  { key = "barrel",    name = "Long Barrel",        desc = "+35% weapon range.",
    apply = function(w, e) e.mods.range = (e.mods.range or 1) * 1.35 end },
  { key = "treads",    name = "Overdrive Treads",   desc = "+40% movement speed.",
    apply = function(w, e) e.mods.speed = (e.mods.speed or 1) * 1.4 end },
  { key = "engineer",  name = "Engineer Core",      desc = "Builds twice as fast.",
    apply = function(w, e) e.mods.build = (e.mods.build or 1) * 2 end },
  { key = "nanolathe", name = "Extended Nanolathe", desc = "+70% build reach, so he can build from safety.",
    apply = function(w, e) e.mods.buildRange = (e.mods.buildRange or 1) * 1.7 end },
  { key = "siphon",    name = "Resource Siphon",    desc = "Commander produces +4 metal and +40 energy per second.",
    apply = function(w, e) e.mods.income = { metal = 4, energy = 40 }; w.economyDirty = true end },
  { key = "storage",   name = "Mass Storage",       desc = "+1500 metal and +6000 energy storage.",
    apply = function(w, e) e.mods.storage = { metal = 1500, energy = 6000 }; w.economyDirty = true end },
  { key = "flakmount", name = "Flak Mount",         desc = "His gun can now shoot down aircraft.",
    apply = function(w, e) e.mods.hitsAir = true end },
  { key = "splash",    name = "Explosive Shells",   desc = "Shots explode, hitting everything nearby.",
    apply = function(w, e) e.mods.splash = 55 end },
  { key = "eye",       name = "Radar Eye",          desc = "+70% sight range.",
    apply = function(w, e) e.mods.sight = (e.mods.sight or 1) * 1.7 end },
  { key = "healaura",  name = "Repair Aura",        desc = "Friendly units within 300 repair 3% per second, even mid-fight.",
    apply = function(w, e) e.mods.healAura = true end },
  { key = "rally",     name = "Inspiring Presence", desc = "Friendly units within 350 deal +25% damage.",
    apply = function(w, e) e.mods.dmgAura = true end },
  { key = "shield",    name = "Shield Generator",   desc = "Takes 40% less damage.",
    apply = function(w, e) e.mods.armor = (e.mods.armor or 1) * 0.6 end },
  { key = "secondwind", name = "Second Wind",       desc = "Once: survives a killing blow at 1 HP and is invulnerable for 6 seconds.",
    apply = function(w, e) e.mods.secondWind = true end },
  { key = "recall",    name = "Emergency Recall",   desc = "Teleports home when below 25% health (every 2 minutes).",
    apply = function(w, e) e.mods.recall = true end },
  { key = "salvage",   name = "Salvager",           desc = "Anything he destroys refunds 40% of its metal cost to you.",
    apply = function(w, e) e.mods.salvage = 0.4 end },
  { key = "reinforce", name = "Reinforcements",     desc = "Four veteran tanks arrive at his side right now.",
    apply = function(w, e) w:reinforce(e) end },
}
C.byKey = {}
for _, u in ipairs(C.upgrades) do C.byKey[u.key] = u end

-- Two random upgrades the Commander doesn't have yet
function C.offer(rng, e)
  local pool = {}
  for _, u in ipairs(C.upgrades) do
    if not e.taken[u.key] then pool[#pool + 1] = u end
  end
  local out = {}
  for _ = 1, math.min(2, #pool) do
    local i = rng:random(#pool)
    out[#out + 1] = table.remove(pool, i)
  end
  return out
end

return C
