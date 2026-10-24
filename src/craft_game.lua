-- Commander Craft: the player-side game logic (selection, orders, hotkeys, notices).
-- Hooked from game.lua wherever the mode differs from the RTS.
local D = require("src.defs")
local U = require("src.util")
local C = require("src.craft")
local ARENA = require("src.arena")
local VOICE = require("src.voice")
local SFX = require("src.sfx")
local MUSIC = require("src.music")

local CG = {}

function CG.init(game)
  local w = game.world
  w.onCraftRefused = function(why, who)
    if not game.opts.autotest then game:notice(why, 1.8) end
  end
  w.onResearch = function(team, d)
    if team == 1 then
      game:notice((d.tierUp and "Upgraded: " or "Research complete: ") .. d.name:gsub("^Upgrade to ", ""), 2.5)
      SFX.play("ready", 0.7, 0)
      if game.log then game.log:event("Research: " .. d.name) end
    elseif w:hostile(team, 1) and d.tierUp and game.log then
      game.log:event(string.format("%s reached tier %d", D.teamName[team], d.tierUp))
    end
  end
  w.onHeroJoined = function(c)
    if c.team == 1 then
      game:notice(ARENA.byClass[c.class].name .. " joins you!", 2.5)
      SFX.play("ready", 0.9, 0)
    elseif w:hostile(c.team, 1) then
      game:notice("The enemy summoned a " .. ARENA.byClass[c.class].name, 2.5)
    end
    if game.log then game.log:event(string.format("%s hero joined: %s", D.teamName[c.team], c.class)) end
  end
  w.onCommanderDown = function(c, attacker)
    local killer = attacker and (attacker.key == "commander" and attacker or attacker.owner)
    if c.team == 1 then
      game:notice(string.format("Your %s has fallen. Rises at your altar in %ds (for %d gold)", ARENA.byClass[c.class].name,
        math.ceil(c.respawnAt - w.time), C.reviveCost(c)), 3.5)
      VOICE.say("cmd_down")
    elseif w:hostile(c.team, 1) then
      game:notice("Enemy hero slain: " .. ARENA.byClass[c.class].name, 3)
      VOICE.say("enemy_cmd_down")
    end
    MUSIC.bump(0.5)
    if game.log then game.log:event(string.format("%s hero (%s, L%d) down%s", D.teamName[c.team], c.class, c.clevel or 0,
      killer and (" - killed by " .. D.teamName[killer.team] .. " " .. killer.key) or "")) end
  end
  w.onRespawn = function(c)
    if c.team == 1 then
      game:notice(ARENA.byClass[c.class].name .. " has risen", 2)
      VOICE.say("respawned")
    end
  end
  w.onRevealed = function(team)
    if team == 1 then game:notice("You have no hall left: build one, or the enemy will see your base!", 5)
    elseif w:hostile(team, 1) then game:notice(D.teamName[team] .. " has lost every hall - their buildings are revealed", 4) end
  end
  w.onMineEmpty = function(m)
    if game.log then game.log:event("A gold mine ran dry" .. (m.center and " (the middle mine)" or "")) end
    local near
    for _, e in ipairs(w.entities) do if e.alive and e.team == 1 and e.def.hall and U.dist(e.x, e.y, m.x, m.y) < 700 then near = true end end
    if near then game:notice("Our gold mine has run dry - expand!", 4) end
  end
  w.onSkill = function(c, def)
    if c.team == 1 or w:isVisible(c) then
      SFX.at("skill", c.x, c.y, game:soundView(), c.team == 1 and 1 or 0.7)
      local col = c.team == 1 and { 1, 1, 1 } or (w:hostile(c.team, 1) and { 1, 0.5, 0.42 } or { 0.5, 1, 0.6 })
      if def.ult then col = { 1, 0.85, 0.35 } end
      w.effects[#w.effects + 1] = { kind = "label", text = def.name .. (def.ult and "!" or ""), x = c.x, y = c.y - c.def.radius - 52,
        t = 0, life = 1.6, color = col, size = def.ult and 16 or 13 }
    end
    if game.log and def.ult then game.log:event(string.format("%s used %s", D.teamName[c.team], def.name)) end
  end
end

-- the hero your skill keys and level-up cards talk to: the selected one, else your first
function CG.activeHero(game)
  local w = game.world
  local sel
  for _, e in ipairs(game:selectedList()) do
    if e.key == "commander" and e.team == 1 and e.alive then sel = e; break end
  end
  if sel then return sel end
  for _, h in ipairs(C.heroesOf(w, 1, false)) do return h end
end

function CG.offerHero(game)
  local a = CG.activeHero(game)
  if a and a.offers and #a.offers > 0 then return a end
  for _, h in ipairs(C.heroesOf(game.world, 1, false)) do
    if h.offers and #h.offers > 0 then return h end
  end
  return a
end

-- workers build; heroes don't (their def says Commander)
function CG.selectedBuilders(game)
  local out = {}
  for _, e in ipairs(game:selectedList()) do
    if e.def.worker and e.built >= 1 then out[#out + 1] = e end
  end
  return out
end

-- what the command card shows: researched and owned things drop off the list
function CG.visible(game, f, key)
  local w = game.world
  local tm = w.teams[1]
  local d = D.units[key]
  if d.research then
    if tm.research[key] then return false end
    if d.after and not tm.research[d.after] and not D.units[d.after].tierUp then
      -- show the next level only once the previous is done
      return false
    end
    if d.tierUp and d.after and not tm.research[d.after] then return false end
  end
  if d.heroRecruit then
    for _, h in ipairs(C.heroesOf(w, 1, true)) do if h.class == d.heroRecruit then return false end end
  end
  return true
end

function CG.commandContext(game)
  local b = CG.selectedBuilders(game)
  if #b > 0 then return "builder", b[1].def.builds, b end
  local f = game:selectedFactories()
  if #f > 0 then
    -- the most common factory type in the selection
    local count, best, bn = {}, nil, 0
    for _, x in ipairs(f) do count[x.key] = (count[x.key] or 0) + 1; if count[x.key] > bn then best, bn = x.key, count[x.key] end end
    local same = {}
    for _, x in ipairs(f) do if x.key == best then same[#same + 1] = x end end
    local list = {}
    for _, k in ipairs(same[1].def.builds) do if CG.visible(game, same[1], k) then list[#list + 1] = k end end
    return "factory", list, same
  end
  return nil
end

function CG.queueUnit(game, key, count, remove)
  local w = game.world
  local factories = {}
  for _, f in ipairs(game:selectedFactories()) do
    for _, k in ipairs(f.def.builds) do if k == key then factories[#factories + 1] = f; break end end
  end
  if #factories == 0 then return end
  for _ = 1, count do
    if remove then
      local best, bi
      for _, f in ipairs(factories) do
        for i = #f.queue, 1, -1 do
          if f.queue[i] == key and (not best or i > 1) then best, bi = f, i; break end
        end
      end
      if best then C.dequeue(w, best, bi) end
    else
      table.sort(factories, function(a, b) return #a.queue < #b.queue end)
      local ok, why = C.enqueue(w, factories[1], key)
      if not ok then
        if why then game:notice(why, 1.6) end
        break
      end
      local d = D.units[key]
      if d.research or d.heroRecruit then break end
    end
  end
  C.recount(w)
end

-- right-click with workers: gold mine -> mine it, tree -> chop it, own drop-off -> bring the load home
function CG.rightClick(game, wx, wy, queue)
  local w = game.world
  local workers = {}
  for _, e in ipairs(game:selectedMobile()) do if e.def.worker then workers[#workers + 1] = e end end
  if #workers == 0 then return false end
  local target = w:entityAt(wx, wy, function(e) return e.key == "goldmine" or (e.team == 1 and e.def.building) end)
  if target and target.key == "goldmine" then
    for _, u in ipairs(workers) do w:issue(u, { type = "harvest", kind = "gold", target = target }, queue) end
    w.effects[#w.effects + 1] = { kind = "ping", x = target.x, y = target.y, t = 0, life = 0.5, r = 1, g = 0.85, b = 0.3 }
    return true
  end
  if target and target.team == 1 and target.def.dropoff and target.built >= 1 then
    local any = false
    for _, u in ipairs(workers) do
      if u.carry and target.def.dropoff[u.carry.kind] then
        local o = { type = "harvest", kind = u.carry.kind, returning = true }
        if u.carry.kind == "gold" then o.target = C.nearestMine(w, target.x, target.y) end
        w:issue(u, o, queue)
        any = true
      end
    end
    if any then return true end
  end
  local tx, ty = w.map:tileAt(wx, wy)
  if w.map:inBounds(tx, ty) and w.map.terrain[ty * w.map.w + tx] == 4 then
    for _, u in ipairs(workers) do w:issue(u, { type = "harvest", kind = "wood", tree = { x = tx, y = ty } }, queue) end
    w.effects[#w.effects + 1] = { kind = "ping", x = (tx + 0.5) * w.T, y = (ty + 0.5) * w.T, t = 0, life = 0.5, r = 0.4, g = 1, b = 0.4 }
    return true
  end
  return false
end

-- Q W E R cast the hero's skills when a hero (and no worker or building) is selected
function CG.heroKey(game, key)
  if game:commandContext() then return false end
  local h = CG.activeHero(game)
  if not h or not game.selected[h] then return false end
  for slot, k in ipairs(ARENA.KEYS) do
    if key == k then
      local sk = h.skills and h.skills[slot]
      if sk and ARENA.SKILLS[sk.key].aim == "point" and game.clickCast then
        game.mode, game.skillSlot = "skill", slot
      else
        CG.useSkill(game, slot)
      end
      return true
    end
  end
  return false
end

function CG.useSkill(game, slot)
  local h = CG.activeHero(game)
  if not h or not h.alive then return end
  local mx, my = love.mouse.getPosition()
  local wx, wy = game:screenToWorld(mx, my)
  local ok, why = ARENA.useSkill(game.world, h, slot, wx, wy)
  if not ok and why then game:notice(why, 1.2) end
end

-- C: jump between your heroes
function CG.cycleHero(game)
  local list = C.heroesOf(game.world, 1, false)
  if #list == 0 then game:notice("No hero alive", 1.2); return end
  game.heroIdx = (game.heroIdx or 0) % #list + 1
  local h = list[game.heroIdx]
  game:centerOn(h.x, h.y)
  game:select({ h })
end

-- Tab / the Builder button: the next idle worker
function CG.idleWorker(game)
  local list = {}
  for _, e in ipairs(game.world.entities) do
    if e.alive and e.team == 1 and e.def.worker and #e.orders == 0 and not e.inMine then list[#list + 1] = e end
  end
  if #list == 0 then game:notice("No idle workers", 1); return end
  game.idleIdx = (game.idleIdx or 0) % #list + 1
  local e = list[game.idleIdx]
  game:centerOn(e.x, e.y)
  game:select({ e })
end

return CG
