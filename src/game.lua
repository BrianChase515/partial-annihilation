-- In-game state: camera, selection, control groups, commands, input handling.
local D = require("src.defs")
local U = require("src.util")
local World = require("src.world")
local R = require("src.render")
local UI = require("src.ui")
local AI = require("src.ai")
local SFX = require("src.sfx")
local VOICE = require("src.voice")
local MUSIC = require("src.music")
local MatchLog = require("src.matchlog")
local ARENA = require("src.arena")
local ArenaAI = require("src.arena_ai")
local CG -- Commander Craft player logic (loaded for that mode)

local G = {}
G.__index = G

-- Can this builder reach that deposit? Land builders take land deposits (and offshore
-- ones right by the shore); Sea Constructors take offshore ones.
local function canReachDeposit(b, dp)
  if b.def.domain == "sea" then return dp.sea == true end
  return not dp.sea or (dp.shore or 9) <= 2
end


function G.new(opts)
  local self = setmetatable({}, G)
  self.opts = opts
  -- players[i] = { human = bool, ally = n, level = 1..10, profile = name }
  local players = opts.players
  if not players then
    players = {
      { human = true, ally = 1 },
      { ally = 2, level = opts.level or 5, profile = opts.profile or "Balanced" },
    }
  end
  if opts.autotest then
    players[1] = { ally = players[1].ally or 1, level = opts.level1 or players[1].level or 5, profile = opts.profile1 or "Balanced", class = players[1].class, race = players[1].race, bench = players[1].bench, legacy = players[1].legacy }
  end
  self.arena = opts.mode == "arena"
  self.craft = opts.mode == "craft"
  self.players = players
  local income = {}
  for i, p in ipairs(players) do income[i] = p.human and 1 or D.aiLevel(p.level).income end
  self.world = World.new({
    size = opts.size, water = opts.water, seed = opts.seed, mapPlayers = opts.mapPlayers, mods = opts.mods,
    playerTeam = 1, noFog = opts.autotest, players = players, aiIncome = income, arena = self.arena, craft = self.craft, template = opts.template,
    experimental = opts.experimental, sandbox = opts.sandbox, squadSetup = opts.squadSetup, coh = opts.coh, enemySquads = opts.enemySquads, cohLength = opts.cohLength,
  })
  local world = self.world
  world.humanTeams = {}
  for i, p in ipairs(players) do if p.human then world.humanTeams[i] = true end end
  R.init(world)
  self.ais = {}
  for i, p in ipairs(players) do
    if world.squads then
      if not p.human then
        local ai = require("src.squads").newAI(world, i, p.level)
        self.ais[#self.ais + 1] = ai
        p.profileName = ai.profileName
      end
    elseif self.craft then
      if not p.human then
        local ai = require("src.craft_ai").new(world, i, p.level, { bench = p.bench, legacy = p.legacy })
        self.ais[#self.ais + 1] = ai
        p.profileName = ai.profileName
      end
    elseif self.arena then
      if not p.human then
        local ai = ArenaAI.new(world, i, p.level)
        self.ais[#self.ais + 1] = ai
        p.profileName = ai.profileName
      end
    elseif not p.human then
      local ai = AI.new(world, i, p.level, p.profile or "Balanced")
      self.ais[#self.ais + 1] = ai
      p.profileName = ai.profileName
    end
  end
  world.onCommanderLevel = function(e, offer)
    if self.log then self.log:event(string.format("%s Commander reached level %d", D.teamName[e.team] or "?", e.clevel or 0)) end
    if e.team == 1 then
      self.stats.cmdLevel = e.clevel
      if self.arena or self.craft then
        if offer and #offer > 0 then
          self:notice("Level " .. e.clevel .. "!  " .. (offer[1].skill and "Choose a new skill" or "Choose an upgrade") .. " (Z / X)", 3)
        elseif not offer then
          local ult = ARENA.SKILLS[ARENA.byClass[e.class].ult]
          self:notice("Level 6: ULTIMATE unlocked - " .. ult.name .. " (R)", 5)
        else
          self:notice("Level " .. e.clevel .. "!", 2)
        end
        VOICE.say(offer and "commander_level" or "ultimate_ready")
      else
      if offer then
        self:notice("Commander reached level " .. e.clevel .. "!  Pick an upgrade (Z / X)", 3)
      else
        self:notice("Commander level 5: NUKE ARMED.  Select him and press N", 5)
      end
      VOICE.say(offer and "commander_level" or "nuke_ready")
      end
      SFX.play("ready", 0.7, 0)
    elseif e.clevel >= 5 and world:hostile(e.team, 1) and not world.heroes then
      self:notice(D.teamName[e.team] .. "'s Commander now has a NUKE.", 4)
    end
  end
  world.onCommanderEvent = function(e, text)
    if e.team == 1 then self:notice(text, 2)
    elseif world:isVisible(e) then self:notice(D.teamName[e.team] .. " Commander: " .. text, 2) end
  end
  world.onNuke = function(e, x, y)
    local secs = math.floor(U.dist(e.x, e.y, x, y) / require("src.commander").NUKE_SPEED + 0.5)
    local who = e.team == 1 and "You" or D.teamName[e.team]
    if e.team == 1 then self.stats.nukes = (self.stats.nukes or 0) + 1 end
    if self.log then self.log:event(string.format("NUKE launched by %s", D.teamName[e.team] or "?")) end
    self:notice("NUKE LAUNCHED by " .. who .. "!  Impact in " .. secs .. "s  (red circle)", 5)
    VOICE.say(world:hostile(e.team, 1) and "nuke_incoming" or "nuke_launched")
    MUSIC.bump(1.2)
    SFX.play("alert", 1, 0)
  end
  world.onDetonate = function(n)
    if self:onScreen(n.tx, n.ty) then
      SFX.play("boom", 1, 0)
      self.shake = 0.6
    end
  end
  world.onAlien = function(what, a, team)
    if self.log then self.log:event("Alien Tech: " .. what .. (team and (" by " .. (D.teamName[team] or "?")) or "")) end
    if what == "announce" then
      self:notice("ALIEN TECH incoming! Lands in 60s at the purple marker. Hold its zone for 15s to claim it.", 6)
      VOICE.say("alien_signal")
      SFX.play("alert", 0.8, 0)
    elseif what == "land" then
      self:notice("The Alien Walker has landed. Clear the zone and hold it!", 4)
      VOICE.say("alien_landed")
    elseif what == "claim" then
      local who = team == 1 and "You" or ((world:hostile(team, 1) and "Enemy " or "Your ally ") .. D.teamName[team])
      self:notice(who .. " claimed the Alien Walker!", 5)
      VOICE.say(world:hostile(team, 1) and "alien_lost" or "alien_claimed")
      SFX.play(team == 1 and "ready" or "alert", 0.9, 0)
    end
  end
  world.onDrop = function(sq)
    self:notice("Alien dropship spotted near the middle of the map. Its crew is undecided...", 4)
    VOICE.say("dropship")
  end
  self.flips = {}
  world.onDropEncounter = function(sq)
    if sq.team == 1 then
      self.flips[#self.flips + 1] = { sq = sq, t = 0 }
      VOICE.say("drop_contact")
      SFX.play("alert", 0.5, 0)
      return true -- wait for the coin flip
    end
    return false
  end
  world.onDropResolved = function(sq)
    if self.log then self.log:event(string.format("Drop crew (%d units) %s %s", #sq.units, sq.result == "join" and "joined" or "attacked", D.teamName[sq.team] or "?")) end
    if sq.team == 1 then return end
    local seen = false
    for _, u in ipairs(sq.units) do if u.alive and world:isVisible(u) then seen = true end end
    if seen then
      self:notice("A drop crew " .. (sq.result == "join" and "joined " or "attacked ") .. D.teamName[sq.team] .. "!", 3)
    end
  end
  world.onEliminate = function(team)
    if self.log then self.log:event((D.teamName[team] or "?") .. " eliminated") end
    local name = D.teamName[team]
    if team == 1 then
      local alliesLeft = false
      for t = 2, world.np do if not world.teams[t].dead and world:allied(t, 1) then alliesLeft = true end end
      if alliesLeft then self:notice("Your Commander has fallen. Your allies fight on - you're spectating.", 6) end
      self.spectating = true
    elseif world:hostile(team, 1) then
      self:notice(name .. " has been eliminated!", 4)
      VOICE.say("enemy_eliminated")
    else
      self:notice("Your ally " .. name .. " has been eliminated.", 4)
      VOICE.say("ally_eliminated")
    end
  end

  self.selected = {}      -- set: entity -> true
  self.groups = {}        -- 1..9 -> list of entities
  self.mode = nil         -- nil | "amove" | "patrol" | "build"
  self.buildKey = nil
  self.speed = 1
  self.paused = false
  self.menuOpen = false
  self.showHelp = false
  self.lastGroupTap = { n = nil, t = 0 }
  self.lastClick = { t = 0, e = nil }
  self.notices = {}
  self.stats = { built = 0, lost = 0, killed = 0 }
  self.edgePan = require("src.settings").v.edge
  self.showSidebar = true
  self.mouseLock = true

  -- camera centered on the commander
  local c = world.teams[1].commander
  self.cam = { x = 0, y = 0, zoom = 1 }
  self:centerOn(c.x, c.y)
  self:select({ c })

  world.onProduce = function(u, f)
    if u.team == 1 then
      self.stats.built = self.stats.built + 1
      if f.assignGroup then
        local g = self.groups[f.assignGroup] or {}
        g[#g + 1] = u
        self.groups[f.assignGroup] = g
      end
      if self.selected[f] or self:onScreen(f.x, f.y) then SFX.play("ready", 0.5, 0) end
    end
  end
  world.onFire = function(e, o)
    if o and o.team and (world:allied(e.team, 1) and world:hostile(o.team, 1) or world:allied(o.team, 1) and world:hostile(e.team, 1)) then
      if not self.arena then
        MUSIC.bump(o.key == "commander" and 0.05 or 0.02)
      elseif e.key == "commander" or o.key == "commander" then
        -- in the Arena creeps fight all the time; only Commander fights raise the music
        MUSIC.bump((e.team == 1 or o.team == 1) and 0.05 or 0.02)
      end
    end
    if e.team == 1 or world:isVisible(e) then
      local snd = (e.mods and e.mods.melee) and "punch" or SFX.weaponSound(e.def.weapon)
      -- Arena creeps fire constantly: keep them a notch under the Commanders and towers
      local v = (self.arena and e.key ~= "commander" and not e.def.building) and 0.6 or 1
      if snd then SFX.at(snd, e.x, e.y, self:soundView(), v) end
    end
  end
  world.onImpact = function(p)
    if (p.weapon and p.weapon.ballistic) and world:tileVisible(math.floor(p.tx / world.T), math.floor(p.ty / world.T)) then
      SFX.at("impact", p.tx, p.ty, self:soundView(), p.weapon.bomb and 1 or 0.8)
    end
  end
  world.onLevel = function(e)
    if e.team == 1 and self:onScreen(e.x, e.y) then SFX.play("ready", 0.35, 0) end
  end
  world.onKill = function(o, attacker)
    if self.log then self.log:onKill(o, attacker) end
    if o.general then
      if o.team == 1 then self:notice(o.genName .. " has fallen", 3)
      elseif world:hostile(o.team, 1) then self:notice("Enemy " .. o.genName .. " destroyed!", 3) end
      if self.log then self.log:event(string.format("%s %s killed", D.teamName[o.team], o.genName)) end
    end
    if attacker and attacker.team and (world:allied(o.team, 1) or world:allied(attacker.team, 1)) then
      MUSIC.bump(o.def.building and 0.15 or (o.key == "commander" and 0.6 or 0.07))
    end
    if o.team == 1 or world:isVisible(o) then
      local big = o.def.building or o.key == "commander" or o.def.radius >= 14
      if big then SFX.at("bigboom", o.x, o.y, self:soundView(), 1)
      else SFX.at("boom", o.x, o.y, self:soundView(), self.arena and 0.6 or 0.85) end
    end
    if o.team == 1 then self.stats.lost = self.stats.lost + 1
    elseif attacker and attacker.team == 1 then self.stats.killed = self.stats.killed + 1 end
  end
  world.onGeneral = function(g, what)
    if g.team == 1 then
      self:notice(string.format("%s promoted! (%s, Shift+C)", g.genName, g.def.name), 3.5)
      SFX.play("ready", 0.8, 0)
    elseif world:allied(g.team, 1) then
      self:notice(string.format("Allied %s takes the field", g.genName), 2.5)
    else
      self:notice(string.format("Enemy %s takes the field (%s)", g.genName, g.def.name), 3)
    end
    if self.log then self.log:event(string.format("%s %s promoted: %s", D.teamName[g.team], g.def.name, g.genName)) end
  end
  -- Annihilation games you play to the end teach the Mirror and Nemesis opponents
  -- (only plain games count: modifiers like Metal Alert or Post-Apocalypse change how people play)
  if not self.arena and not self.craft and not self.opts.autotest and world.official and self.players[1] and self.players[1].human then
    local GH = require("src.ghost")
    self.ghostRec = GH.newRecorder(world)
    local lv = 0
    for i, p in ipairs(self.players) do if not p.human and world:hostile(i, 1) then lv = math.max(lv, p.level or 5) end end
    self.ghostRec.oppLevel = lv > 0 and lv or 5
  end
  world.onTruckLost = function(o)
    if o.team == 1 then self:notice("Ore truck destroyed! That extractor rolls out a new one in 60s", 3) end
  end
  if world.squads then
    -- your squads start on control groups 1, 2, 3
    local SQ = require("src.squads")
    for i, sq in ipairs(SQ.squadsOf(world, 1)) do
      local g = {}
      for _, u in ipairs(sq.members) do g[#g + 1] = u end
      self.groups[i] = g
    end
    world.onSquadSkill = function(sq, slot)
      if sq.team == 1 then
        local sk = SQ.SKILLS[sq.skills[slot].key]
        self:notice(string.format("%s: %s", SQ.byType[sq.type].name, sk.name), 1.4)
      end
    end
    world.onSquadSound = function(name, x, y, v) SFX.at(name, x, y, self:soundView(), v) end
    world.onSquadReinforced = function(sq, u)
      if sq.team == 1 and world.time - (sq.lastReinfNote or -99) > 12 then
        sq.lastReinfNote = world.time
        self:notice(string.format("Squad %d (%s): replacements leaving the HQ to rejoin", sq.idx, SQ.byType[sq.type].name), 2)
      end
    end
    world.onSquadLeaderDown = function(sq)
      if sq.team == 1 then self:notice(string.format("%s Leader down - back at the HQ in 45s", SQ.byType[sq.type].name), 2.5) end
    end
    world.onPointTaken = function(p, ally)
      if ally == world.ally[1] then self:notice("Point " .. p.name .. " taken", 1.8)
      else self:notice("Point " .. p.name .. " lost to the enemy", 2.2) end
    end
  end
  world.onApocFog = function()
    self:notice("10:00 - the fog has lifted. Everything is in plain sight.", 5)
  end
  world.onBuilt = function(b)
    if b.team == 1 and b.def.building then VOICE.say("construction") end
    if self.ghostRec then require("src.ghost").onBuilt(self.ghostRec, b) end
  end
  if self.arena then
    world.onCommanderDown = function(c, attacker)
      local killer = attacker and (attacker.key == "commander" and attacker or attacker.owner)
      if c.team == 1 then
        self:notice(string.format("Your Commander is down. Respawning in %ds", math.ceil(c.respawnAt - world.time)), 4)
        VOICE.say("cmd_down")
        self.selected = {}
      elseif world:hostile(c.team, 1) then
        self:notice((killer and killer.team == 1 and "You destroyed " or "") .. D.teamName[c.team] .. "'s Commander!", 3)
        VOICE.say("enemy_cmd_down")
      else
        self:notice("Your ally's Commander is down", 3)
        -- flash the spot on the minimap so you can see which lane it was
        self:minimapPing(c.x, c.y, { R.teamColor(c.team) })
      end
      MUSIC.bump(0.5)
      if self.log then self.log:event(string.format("%s Commander (%s, L%d) down%s", D.teamName[c.team], c.class, c.clevel or 0,
        killer and (" - killed by " .. D.teamName[killer.team] .. " " .. killer.key) or "")) end
    end
    world.onRespawn = function(c)
      if c.team == 1 then
        self:notice("Commander back online", 2)
        VOICE.say("respawned")
        self:centerOn(c.x, c.y)
        self:select({ c })
      end
    end
    world.onTowerDown = function(s)
      local mine = world:allied(s.team, 1)
      local what = s.key == "core" and "Core" or (s.tier .. " " .. s.lane .. " tower")
      self:notice((mine and "We lost our " or "Destroyed the enemy ") .. what .. "!", 3)
      VOICE.say(mine and "tower_lost" or "tower_destroyed")
      MUSIC.bump(0.4)
      if self.log then self.log:event((mine and "Lost " or "Destroyed ") .. what) end
    end
    world.onDeny = function(o, by)
      if by and by.team == 1 then self:notice("Denied!", 0.8, o.x, o.y) end
    end
    world.onCreepLevel = function(side, L)
      local mine = side == world.arena.teamSide[1]
      self:notice((mine and "Our creeps reached level " or "Enemy creeps reached level ") .. L, 2.5)
    end
    world.onWave = function(k)
      if k == 1 then self:notice("The creeps are marching. Push a lane!", 3); VOICE.say("creeps") end
    end
    world.onJungle = function(text, side, kind)
      local st = world.arena
      local who = side and (side == st.teamSide[1] and "Your side" or (st.ffa and D.teamName[st.sideOwner[side]] or "The enemy")) or nil
      self:notice(who and string.format(text, who) or text, 3)
      if kind == "boss" or kind == "crest" then MUSIC.bump(0.4) end
      if self.log then self.log:event(who and string.format(text, who) or text) end
    end
    world.onSkill = function(c, def)
      if c.team == 1 or world:isVisible(c) then
        SFX.at("skill", c.x, c.y, self:soundView(), c.team == 1 and 1 or 0.7)
        -- call out every visible cast by name, so you learn what the enemy just did
        local col = c.team == 1 and { 1, 1, 1 } or (world:hostile(c.team, 1) and { 1, 0.5, 0.42 } or { 0.5, 1, 0.6 })
        if def.ult then col = { 1, 0.85, 0.35 } end
        world.effects[#world.effects + 1] = { kind = "label", text = def.name .. (def.ult and "!" or ""), x = c.x, y = c.y - c.def.radius - 52,
          t = 0, life = 1.6, color = col, size = def.ult and 16 or 13 }
      end
      if self.log and def.ult then self.log:event(string.format("%s used %s", D.teamName[c.team], def.name)) end
    end
  end
  if self.craft then
    CG = require("src.craft_game")
    CG.init(self)
  end
  self.lastAttackNotice = -100
  self.voiceState = { cmdHp = c.hp, nukeReady = false, lowM = 0, lowE = 0 }
  if not self.opts.autotest then VOICE.say("commander_online") end
  if not self.opts.autotest then
    MUSIC.reset()
    -- a different soundtrack each match
    MUSIC.match(self.craft and "craft" or (self.arena and "arena" or "rts"))
    local ok, lg = pcall(MatchLog.start, self)
    if ok then self.log = lg else print("match log disabled:", lg) end
  end
  self.musicScan = 0
  return self
end

---------------------------------------------------------------------------
-- Camera

function G:viewSize()
  return love.graphics.getWidth(), love.graphics.getHeight()
end

function G:centerOn(x, y)
  self.follow = nil
  local w, h = self:viewSize()
  local z = self.cam.zoom
  self.cam.x = x - w / 2 / z
  self.cam.y = y - (h - UI.PANEL_H + UI.TOP_H) / 2 / z
  self:clampCam()
end

function G:clampCam()
  local w, h = self:viewSize()
  local map = self.world.map
  local mw, mh = map.w * D.TILE, map.h * D.TILE
  local z = self.cam.zoom
  local vw, vh = w / z, h / z
  local padTop, padBot = UI.TOP_H / z, UI.PANEL_H / z
  -- the camera may run past the map's edges (up to about half a screen), so a base in a corner
  -- can still be brought to the middle of the view instead of hiding under the HUD
  local overX, overY = vw * 0.45, (vh - padTop - padBot) * 0.45
  if vw >= mw then
    self.cam.x = U.clamp(self.cam.x, (mw - vw) / 2 - overX, (mw - vw) / 2 + overX)
  else
    self.cam.x = U.clamp(self.cam.x, -overX, mw - vw + overX)
  end
  local usable = vh - padTop - padBot
  if usable >= mh then
    local c = (mh - usable) / 2 - padTop
    self.cam.y = U.clamp(self.cam.y, c - overY, c + overY)
  else
    self.cam.y = U.clamp(self.cam.y, -padTop - overY, mh - vh + padBot + overY)
  end
end

function G:onScreen(x, y)
  local c = self.cam
  if not c.wx0 then return false end
  return x > c.wx0 - 40 and x < c.wx1 + 40 and y > c.wy0 - 40 and y < c.wy1 + 40
end

function G:screenToWorld(sx, sy)
  return self.cam.x + sx / self.cam.zoom, self.cam.y + sy / self.cam.zoom
end

function G:worldToScreen(wx, wy)
  return (wx - self.cam.x) * self.cam.zoom, (wy - self.cam.y) * self.cam.zoom
end

function G:zoomAt(sx, sy, factor)
  local wx, wy = self:screenToWorld(sx, sy)
  local w, h = self:viewSize()
  local map = self.world.map
  local minZoom = math.min(w / (map.w * D.TILE), (h - UI.PANEL_H) / (map.h * D.TILE)) * 0.9
  self.cam.zoom = U.clamp(self.cam.zoom * factor, math.max(0.18, minZoom), 2.2)
  self.cam.x = wx - sx / self.cam.zoom
  self.cam.y = wy - sy / self.cam.zoom
  self:clampCam()
end

---------------------------------------------------------------------------
-- Selection helpers

-- a visible non-player entity under the point (enemy, ally, creep or gold mine), for the read-only info panel
function G:inspectable(wx, wy)
  local world = self.world
  return world:entityAt(wx, wy, function(o)
    if o.team == 1 or o.inMine then return false end
    return o.dormant or o.key == "goldmine" or world:isVisible(o)
  end)
end

function G:inspectValid()
  local e = self.inspect
  if not e then return nil end
  if not e.alive or e.inMine or not (e.dormant or e.key == "goldmine" or self.world:isVisible(e)) then self.inspect = nil; return nil end
  return e
end

function G:select(list, add)
  if not add then self.selected = {} end
  if #list > 0 then self.inspect = nil end
  for _, e in ipairs(list) do
    if e.alive and e.team == 1 and not e.def.truck then self.selected[e] = true end -- ore trucks drive themselves
  end
  -- Commander of Heroes: clicking any member selects the whole squad (hold Alt for one unit)
  if self.world.squads and not love.keyboard.isDown("lalt", "ralt") then
    for e in pairs(self.selected) do
      if e.squad then for _, u in ipairs(e.squad.members) do if u.alive then self.selected[u] = true end end end
    end
  end
  self.mode = nil
end

function G:selectedList()
  local out = {}
  for e in pairs(self.selected) do
    if e.alive then out[#out + 1] = e else self.selected[e] = nil end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function G:selectedMobile()
  local out = {}
  for _, e in ipairs(self:selectedList()) do
    if not e.def.building and e.team == 1 and not e.creep then out[#out + 1] = e end
  end
  return out
end

function G:selectedBuilders()
  local out = {}
  if self.arena then return out end
  if self.craft then return CG.selectedBuilders(self) end
  for _, e in ipairs(self:selectedList()) do
    if e.def.builds and not e.def.factory and e.built >= 1 then out[#out + 1] = e end
  end
  return out
end

function G:selectedFactories()
  local out = {}
  for _, e in ipairs(self:selectedList()) do
    if e.def.factory and e.built >= 1 then out[#out + 1] = e end
  end
  return out
end

-- What the command card shows: a builder's build list or a factory's unit list
function G:commandContext()
  if self.craft then return CG.commandContext(self) end
  local b = self:selectedBuilders()
  if #b > 0 then
    -- the Refinery only exists with the Metal Alert modifier
    local list = {}
    for _, k in ipairs(b[1].def.builds) do
      if not D.units[k].convoyOnly or self.world.mods.convoy then list[#list + 1] = k end
    end
    return "builder", list, b
  end
  local f = self:selectedFactories()
  if #f > 0 then
    -- use the most common factory type in the selection
    return "factory", f[1].def.builds, f
  end
  return nil
end

function G:subRevealed(e)
  local found = false
  self.world:query(e.x, e.y, 260, function(o)
    if o.alive and o.team == 1 and (o.def.domain == "sea" or o.def.domain == "sub") then
      if U.dist(o.x, o.y, e.x, e.y) < 240 then found = true end
    end
  end)
  return found
end

---------------------------------------------------------------------------
-- Orders

-- Spread units around a point in a loose grid, preserving their relative positions
function G:formation(units, x, y, ranked)
  local n = #units
  if n == 0 then return {} end
  if n == 1 then return { [units[1]] = { x, y } } end
  local maxR = 0
  local cx, cy = 0, 0
  for _, u in ipairs(units) do
    maxR = math.max(maxR, u.def.radius)
    cx, cy = cx + u.x, cy + u.y
  end
  cx, cy = cx / n, cy / n
  local spacing = maxR * 2 + 12
  local cols = math.ceil(math.sqrt(n))
  local rows = math.ceil(n / cols)
  -- orient the grid toward the move direction
  local dx, dy, len = U.norm(x - cx, y - cy)
  if len < 1 then dx, dy = 0, -1 end
  local px, py = -dy, dx
  local slots = {}
  for i = 0, n - 1 do
    local c = i % cols
    local r = math.floor(i / cols)
    local ox = (c - (cols - 1) / 2) * spacing
    local oy = (r - (rows - 1) / 2) * spacing
    slots[#slots + 1] = { x + px * ox - dx * oy, y + py * ox - dy * oy }
  end
  local result = {}
  local free = {}
  for i = 1, #slots do free[i] = true end
  if ranked then
    -- attack-move: shortest reach up front, artillery and other long guns in the back rows
    local w = self.world
    local function reach(u) return u.def.weapon and w:rangeOf(u) or 9999 end
    local order = {}
    for _, u in ipairs(units) do order[#order + 1] = u end
    table.sort(order, function(a, b)
      local ra, rb = reach(a), reach(b)
      if ra ~= rb then return ra < rb end
      return a.id < b.id
    end)
    for _, u in ipairs(order) do
      local relx, rely = u.x - cx + x, u.y - cy + y
      local row, best, bd
      for i, sl in ipairs(slots) do
        if free[i] then
          local r = math.floor((i - 1) / cols)
          if not row then row = r end
          if r == row then
            local d = U.dist2(relx, rely, sl[1], sl[2])
            if not bd or d < bd then best, bd = i, d end
          end
        end
      end
      free[best] = false
      result[u] = slots[best]
    end
    return result
  end
  -- greedy assignment: each unit takes the nearest free slot (relative to group centroid)
  local order = {}
  for _, u in ipairs(units) do order[#order + 1] = u end
  table.sort(order, function(a, b)
    return U.dist2(a.x, a.y, x, y) > U.dist2(b.x, b.y, x, y)
  end)
  for _, u in ipairs(order) do
    local relx, rely = u.x - cx + x, u.y - cy + y
    local best, bd
    for i, s in ipairs(slots) do
      if free[i] then
        local d = U.dist2(relx, rely, s[1], s[2])
        if not bd or d < bd then best, bd = i, d end
      end
    end
    free[best] = false
    result[u] = slots[best]
  end
  return result
end

function G:commandMove(x, y, kind, queue)
  local units = self:selectedMobile()
  local slots = self:formation(units, x, y, kind == "amove")
  -- group move: everyone walks at the slowest unit's pace so the army arrives together.
  -- Attack-move marches the same way, in ranks (short reach in front), until anyone in the
  -- group makes contact; then the march breaks and everyone fights (and kites) freely
  local groupSpeed, march
  if kind == "gmove" or (kind == "amove" and #units > 1) then
    for _, u in ipairs(units) do
      local sp = self.world:speedOf(u) / (u.sqSpeed or 1)
      if not groupSpeed or sp < groupSpeed then groupSpeed = sp end
    end
  end
  -- Commander of Heroes: each squad keeps its own pace (and marches as its own group)
  local perSquad = self.world.squads and (kind == "move" or kind == "gmove" or kind == "amove")
  local sqPace, sqCount, sqMarch = {}, {}, {}
  if perSquad then
    for _, u in ipairs(units) do
      local k = u.squad or u
      local sp = self.world:speedOf(u) / (u.sqSpeed or 1)
      if not sqPace[k] or sp < sqPace[k] then sqPace[k] = sp end
      sqCount[k] = (sqCount[k] or 0) + 1
    end
  end
  local fdx, fdy = 0, 0
  if kind == "amove" and groupSpeed then
    march = { speed = groupSpeed, n = #units }
    groupSpeed = nil
    -- form up first, where the army stands: the same ranks, shifted back to the group's centre
    if not queue then
      local cx, cy = 0, 0
      for _, u in ipairs(units) do cx, cy = cx + u.x, cy + u.y end
      cx, cy = cx / #units, cy / #units
      local dx, dy, len = U.norm(x - cx, y - cy)
      local back = math.min(len, 60)
      fdx, fdy = cx + dx * back - x, cy + dy * back - y
      march.formUp = true
    end
  end
  for _, u in ipairs(units) do
    local s = slots[u]
    local gs, mr = groupSpeed, march
    if perSquad then
      local k = u.squad or u
      if kind == "amove" then
        sqMarch[k] = sqMarch[k] or { speed = sqPace[k], n = sqCount[k], formUp = march and march.formUp }
        gs, mr = nil, sqMarch[k]
      else
        gs = sqPace[k]
      end
    end
    local o = { type = kind == "gmove" and "move" or kind, x = s[1], y = s[2], groupSpeed = gs, march = mr }
    if mr and mr.formUp then o.formX, o.formY = s[1] + fdx, s[2] + fdy end
    if kind == "patrol" then
      local last = queue and u.orders[#u.orders]
      o.fromX, o.fromY = last and last.x or u.x, last and last.y or u.y
    end
    self.world:issue(u, o, queue)
  end
  for _, f in ipairs(self:selectedFactories()) do
    self.world:issue(f, { type = kind == "patrol" and "patrol" or (kind == "gmove" and "move" or kind), x = x, y = y })
  end
  local col = kind == "gmove" and { 0.4, 0.9, 1 } or kind == "amove" and { 1, 0.4, 0.3 } or (kind == "patrol" and { 0.4, 0.7, 1 } or { 0.3, 1, 0.4 })
  self.world.effects[#self.world.effects + 1] = { kind = "ping", x = x, y = y, t = 0, life = 0.5, r = col[1], g = col[2], b = col[3] }
end

-- hold G while clicking: a group move (everyone at the slowest unit's pace); let go and clicks are normal again
function G:groupHeld()
  return not self.arena and love.keyboard.isDown("g") and #self:selectedMobile() > 1 and #self:selectedFactories() == 0
end

function G:rightClick(wx, wy, queue)
  local world = self.world
  if self:groupHeld() then self:commandMove(wx, wy, "gmove", queue); return end
  -- constructors right-clicking the retreat flag: they repair everything within 350 of it
  if self.flag and not self.craft and not self.arena and U.dist(wx, wy, self.flag.x, self.flag.y) < 50 and self:hasSelectedConstructor() then
    self:placeRepairZone(self.flag.x, self.flag.y, 350, queue)
    return
  end
  local target = world:entityAt(wx, wy, function(e)
    if e.team == 1 then return true end
    if e.def.domain == "sub" and not self:subRevealed(e) then return false end
    return world:isVisible(e) or (e.def.building and e.seen[1])
  end)
  local units = self:selectedMobile()
  if #units == 0 then
    -- factories only: rally onto a friendly unit (new units guard it), or a rally point
    local facs = self:selectedFactories()
    if #facs > 0 then
      if target and target.team == 1 and not target.def.building then
        for _, f in ipairs(facs) do f.rally = { type = "guard", target = target } end
        self:notice("New units will join and follow your " .. target.def.name, 2)
        world.effects[#world.effects + 1] = { kind = "ping", x = target.x, y = target.y, t = 0, life = 0.5, r = 0.4, g = 1, b = 0.6 }
      else
        self:commandMove(wx, wy, "move")
      end
    end
    return
  end
  if self.craft and CG.rightClick(self, wx, wy, queue) then return end
  if self.arena and target and target.creep and world:allied(target.team, 1) then
    local ok = false
    for _, u in ipairs(units) do
      if world:canDeny(u, target) then world:issue(u, { type = "attack", target = target }, queue); ok = true end
    end
    if ok then
      world.effects[#world.effects + 1] = { kind = "ping", x = target.x, y = target.y, t = 0, life = 0.5, r = 1, g = 1, b = 1 }
      return
    end
  end
  if target and target.team ~= 1 and not world:hostile(target.team, 1) then target = nil end
  if target and target.team ~= 1 then
    for _, u in ipairs(units) do
      if u.def.weapon and world:canTarget(u, target) then
        world:issue(u, { type = "attack", target = target }, queue)
      elseif not u.def.weapon then
        world:issue(u, { type = "move", x = target.x, y = target.y, arrive = 120 }, queue)
      end
    end
    world.effects[#world.effects + 1] = { kind = "ping", x = target.x, y = target.y, t = 0, life = 0.5, r = 1, g = 0.3, b = 0.2 }
    return
  end
  if target and target.team == 1 then
    local helps = target.built < 1 or target.hp < target.maxhp or target.def.factory
    local others = {}
    for _, u in ipairs(units) do
      if u.def.builds and helps and u ~= target then
        world:issue(u, { type = "assist", target = target, persist = target.def.factory and target.built >= 1 }, queue)
      elseif not target.def.building and u ~= target and u.def.weapon then
        -- right-click a friendly unit: guard it (follow and protect)
        world:issue(u, { type = "guard", target = target }, queue)
      else
        others[#others + 1] = u
      end
    end
    if #others > 0 then
      local slots = self:formation(others, wx, wy)
      for _, u in ipairs(others) do
        world:issue(u, { type = "move", x = slots[u][1], y = slots[u][2] }, queue)
      end
    end
    world.effects[#world.effects + 1] = { kind = "ping", x = target.x, y = target.y, t = 0, life = 0.5, r = 0.4, g = 1, b = 0.6 }
    return
  end
  self:commandMove(wx, wy, "move", queue)
end

-- The on-screen orders bar (same actions as the keyboard shortcuts)
function G:orderAction(action, shift)
  local slot = tonumber(tostring(action):match("^skill(%d)"))
  if slot then
    -- clicking a targeted skill's button waits for a click on the map
    local c = self.craft and CG.activeHero(self) or self:myCommander()
    local sk = c and c.skills and c.skills[slot]
    if sk and ARENA.SKILLS[sk.key].aim == "point" then
      self.mode, self.skillSlot = "skill", slot
      return
    end
    return self:useSkill(slot)
  end
  if action == "home" then return self:goHome() end
  if action == "hold" then
    self.holdToggle = not self.holdToggle
    self:notice(self.holdToggle and "Holding fire (click Hold again or press D to release)" or "Weapons free", 1.5)
    return
  end
  if self.arena and (action == "amove" or action == "stop") and #self:selectedMobile() == 0 then
    local c = self:myCommander()
    if c then self:select({ c }) end
  end
  if action == "amove" or action == "patrol" then
    if #self:selectedMobile() > 0 then self.mode = action end
  elseif action == "stop" then self:stop()
  elseif action == "flee" then self:retreat("flag"); VOICE.say("retreat")
  elseif action == "fleecmd" then self:retreat("commander"); VOICE.say("retreat")
  elseif action == "flag" then self.mode = "flag"
  elseif action == "destroy" then self:selfDestruct()
  elseif action == "army" then self:selectAllArmy()
  elseif action == "half" then if shift then self:selectOtherHalf() else self:selectHalf() end
  elseif action == "builder" and self.craft then CG.idleWorker(self)
  elseif action == "cmd" and self.craft then CG.cycleHero(self)
  elseif action == "cmd" and self.world.squads then self:keypressed("c")
  elseif action == "builder" then self:selectIdleBuilder()
  elseif action == "cmd" then
    local c = self.world.teams[1].commander
    if c and c.alive then self:centerOn(c.x, c.y); self:select({ c }) end
  elseif action == "follow" then self:startFollow(shift)
  elseif action == "nuke" then self:startNuke()
  elseif action == "repeat" then
    for _, f in ipairs(self:selectedFactories()) do f.repeatMode = not f.repeatMode end
  elseif action == "help" then self.showHelp = not self.showHelp
  end
end

-- Hold fire: while D is held (or the Hold button is on), your selected units - in the
-- Arena, your Commander - don't shoot, so you can time the killing shot
function G:updateHoldFire()
  local on = self.holdToggle or (not self.naming and love.keyboard.isDown("d"))
  local want = {}
  if on then
    for _, e in ipairs(self:selectedList()) do if e.team == 1 then want[e] = true end end
    if self.arena then local c = self:myCommander(); if c then want[c] = true end end
  end
  for e in pairs(self.held or {}) do if not want[e] then e.holdFire = nil end end
  for e in pairs(want) do e.holdFire = true end
  self.held = want
  self.holdingFire = on
end

-- Arena: use the skill in a slot at the mouse position
function G:useSkill(slot)
  if self.craft then return CG.useSkill(self, slot) end
  local c = self.world.teams[1].commander
  if not c or not c.alive then return end
  local mx, my = love.mouse.getPosition()
  local wx, wy = self:screenToWorld(mx, my)
  local ok, why = ARENA.useSkill(self.world, c, slot, wx, wy)
  if not ok and why then self:notice(why, 1.2) end
end

function G:goHome()
  local c = self.world.teams[1].commander
  if not c or not c.alive then return end
  self.world:issue(c, { type = "retreat", x = c.respawnX, y = c.respawnY })
  self:notice("Fleeing home: +50% speed, no shooting, can't be cancelled", 1.5)
end

-- Open a pre-filled GitHub issue with this game's official score
-- where the "ears" are for positional combat sounds: the middle of the view
function G:soundView()
  local cam = self.cam
  if not cam.wx0 then return nil end
  local v = self._sv or {}
  self._sv = v
  v.cx, v.cy = (cam.wx0 + cam.wx1) / 2, (cam.wy0 + cam.wy1) / 2
  v.halfW = (cam.wx1 - cam.wx0) / 2
  v.zoomMul = math.min(1, 0.45 + cam.zoom * 0.6)
  return v
end

function G:submitScore()
  local f, w = self.finalScore, self.world
  if not f or not f.official or self.submitted then return end
  local sc = w.score[1]
  local ok = require("src.online").submit({
    score = f.total, result = f.won and "Win" or "Loss",
    time = string.format("%d:%02d", math.floor(w.time / 60), math.floor(w.time % 60)),
    players = w.np, map = w.map.w .. "/" .. w.map.seed, lineup = f.lineup, mode = self.arena and "arena" or "rts",
    breakdown = string.format("pts %d x%.2f diff x%.2f opp x%.2f time", math.floor(f.pts), f.diffMul, f.oppMul, f.timeMul),
  })
  self.submitted = true
  self.submitMsg = ok and "Your browser opened a GitHub page: press \"Submit new issue\" there (needs a free GitHub account). The board updates within a minute or two."
    or "Couldn't open the browser."
end

-- Delete / Backspace: self-destruct the selected units and buildings you own.
-- The Commander is skipped unless he is the only thing selected and you press twice.
function G:selfDestruct()
  local w = self.world
  if self.arena then return end
  local list, cmd = {}, nil
  for _, e in ipairs(self:selectedList()) do
    if e.team == 1 and e.alive then
      if e.key == "commander" then cmd = e else list[#list + 1] = e end
    end
  end
  if #list == 0 and cmd then
    if self.confirmCmdDelete and love.timer.getTime() - self.confirmCmdDelete < 2.5 then
      self.confirmCmdDelete = nil
      w:kill(cmd)
    else
      self.confirmCmdDelete = love.timer.getTime()
      self:notice("Press Delete again to self-destruct your Commander (you lose)", 2.5)
    end
    return
  end
  if #list == 0 then return end
  local tm = w.teams[1]
  for _, e in ipairs(list) do
    -- unfinished construction is cancelled: refund the metal already spent
    if e.built < 1 and e.def.cost then
      tm.metal = math.min(tm.mStore, tm.metal + e.def.cost.metal * e.built)
    end
    w:kill(e)
  end
  self.selected = {}
  VOICE.say("self_destruct")
  self:notice(#list == 1 and "Self-destructed" or (#list .. " self-destructed"), 1.2)
end

function G:stop()
  for _, u in ipairs(self:selectedMobile()) do
    if not self.world:isFleeing(u) then
      u.orders = {}
      u.path = nil
      u.chase = nil
      u.homeX, u.homeY = u.x, u.y
    end
  end
end


function G:placeBuilding(wx, wy, queue)
  local key = self.buildKey
  local tx, ty = self.world:footprintAt(key, wx, wy)
  if not self.world:canPlace(key, tx, ty, 1) then
    self:notice("Can't build there", 1.2)
    return false
  end
  local builders = self:selectedBuilders()
  if self.craft then
    -- every selected worker takes the order (a group builds faster). Shift adds it after their
    -- other queued builds; gathering always resumes once the last one is done
    local ok, why = require("src.craft").canOrder(self.world, 1, key)
    if not ok then self:notice(why, 1.6); return false end
    if #builders == 0 then return false end
    for _, b in ipairs(builders) do
      local resume
      for _, o in ipairs(b.orders) do
        if o.type == "harvest" then resume = { type = "harvest", kind = o.kind, target = o.target, tree = o.tree } end
      end
      local other = false
      for _, o in ipairs(b.orders) do if o.type ~= "harvest" then other = true end end
      if queue and other then
        -- drop the trailing "back to work" so the new build queues behind the other builds
        for i = #b.orders, 2, -1 do if b.orders[i].type == "harvest" then table.remove(b.orders, i) end end
        if b.orders[1].type == "harvest" then table.remove(b.orders, 1); b.path = nil end
        self.world:issue(b, { type = "build", key = key, tx = tx, ty = ty }, #b.orders > 0)
      else
        self.world:issue(b, { type = "build", key = key, tx = tx, ty = ty }, false)
      end
      if resume then self.world:issue(b, resume, true) end
    end
    return true
  end
  local dp = key == "mex" and self.world.map.deposit[self.world.map:idx(tx, ty)]
  local any = false
  for _, b in ipairs(builders) do
    if self:builderCan(b, key) and (not dp or canReachDeposit(b, dp)) then
      self.world:issue(b, { type = "build", key = key, tx = tx, ty = ty }, queue)
      any = true
    end
  end
  if dp and not any then
    self:notice(dp.sea and "Only a Sea Constructor can reach that offshore deposit" or "Sea Constructors can't build on land", 2)
    return false
  end
  -- remember planned spot so ghosts are shown
  return true
end

-- Valid build spots inside a dragged rectangle: extractors on every free deposit,
-- other buildings packed in a grid with a one-tile walkway between them.
function G:depositUsable(dp, builders)
  for _, b in ipairs(builders or self:selectedBuilders()) do
    if canReachDeposit(b, dp) then return true end
  end
  return false
end

function G:areaSites(key, ax, ay, bx, by)
  local world = self.world
  local map = world.map
  local d = D.units[key]
  local T = D.TILE
  local x0, x1 = math.min(ax, bx), math.max(ax, bx)
  local y0, y1 = math.min(ay, by), math.max(ay, by)
  -- tiles already promised to queued builds
  local planned = {}
  for _, e in ipairs(world.entities) do
    if e.alive and e.team == 1 then
      for _, o in ipairs(e.orders) do
        if o.type == "build" and not o.ent then
          local od = D.units[o.key]
          for yy = o.ty, o.ty + od.h - 1 do for xx = o.tx, o.tx + od.w - 1 do planned[yy * map.w + xx] = true end end
        end
      end
    end
  end
  local function free(tx, ty)
    for yy = ty, ty + d.h - 1 do for xx = tx, tx + d.w - 1 do
      if planned[yy * map.w + xx] then return false end
    end end
    return world:canPlace(key, tx, ty, 1)
  end
  local sites = {}
  if key == "mex" then
    for _, dp in ipairs(map.deposits) do
      local cx, cy = map:center(dp.x, dp.y)
      if cx >= x0 - T / 2 and cx <= x1 + T / 2 and cy >= y0 - T / 2 and cy <= y1 + T / 2 and free(dp.x, dp.y)
        and self:depositUsable(dp) then
        sites[#sites + 1] = { tx = dp.x, ty = dp.y, dp = dp }
      end
    end
  else
    local tx0, ty0 = world:footprintAt(key, x0, y0)
    local tx1, ty1 = world:footprintAt(key, x1, y1)
    local stepX, stepY = d.w + 1, d.h + 1
    -- a thin drag is a line: pack along it
    if tx1 - tx0 < d.w then stepX = d.w + 1 end
    for ty = ty0, math.max(ty0, ty1), stepY do
      for tx = tx0, math.max(tx0, tx1), stepX do
        if free(tx, ty) then sites[#sites + 1] = { tx = tx, ty = ty } end
        if #sites >= 40 then break end
      end
      if #sites >= 40 then break end
    end
  end
  return sites
end

-- Hand out sites so each builder works through the ones nearest to it first
function G:assignSites(key, sites, queue)
  local d = D.units[key]
  local T = D.TILE
  local builders = {}
  for _, b in ipairs(self:selectedBuilders()) do
    if self:builderCan(b, key) then builders[#builders + 1] = b end
  end
  if #builders == 0 then return end
  local pos = {}
  for i, b in ipairs(builders) do
    pos[i] = { b.x, b.y }
    if queue and #b.orders > 0 then
      local o = b.orders[#b.orders]
      if o.x then pos[i] = { o.x, o.y } end
      if o.tx then pos[i] = { (o.tx + D.units[o.key].w / 2) * T, (o.ty + D.units[o.key].h / 2) * T } end
    end
    if not queue then b.orders = {}; b.path = nil end
  end
  local left = {}
  for i, st in ipairs(sites) do left[i] = st end
  while #left > 0 do
    local bi, si, bd
    for i, p in ipairs(pos) do
      for j, st in ipairs(left) do
        if not st.dp or canReachDeposit(builders[i], st.dp) then
          local cx, cy = (st.tx + d.w / 2) * T, (st.ty + d.h / 2) * T
          local dd = U.dist2(p[1], p[2], cx, cy)
          if not bd or dd < bd then bi, si, bd = i, j, dd end
        end
      end
    end
    if not bi then break end
    local st = table.remove(left, si)
    self.world:issue(builders[bi], { type = "build", key = key, tx = st.tx, ty = st.ty }, true)
    pos[bi] = { (st.tx + d.w / 2) * T, (st.ty + d.h / 2) * T }
  end
end

function G:builderCan(b, key)
  for _, k in ipairs(b.def.builds) do if k == key then return true end end
  return false
end

function G:queueUnit(key, count, remove)
  if self.craft then return CG.queueUnit(self, key, count, remove) end
  local factories = {}
  for _, f in ipairs(self:selectedFactories()) do
    for _, k in ipairs(f.def.builds) do if k == key then factories[#factories + 1] = f; break end end
  end
  if #factories == 0 then return end
  for _ = 1, count do
    if remove then
      -- remove from the factory that has the most of this unit queued
      local best, bn = nil, 0
      for _, f in ipairs(factories) do
        local n = 0
        for _, k in ipairs(f.queue) do if k == key then n = n + 1 end end
        if n > bn then best, bn = f, n end
      end
      if best then
        for i = #best.queue, 1, -1 do
          if best.queue[i] == key then
            table.remove(best.queue, i)
            if i == 1 then best.progress = 0 end
            break
          end
        end
      end
    else
      table.sort(factories, function(a, b) return #a.queue < #b.queue end)
      local f = factories[1]
      f.queue[#f.queue + 1] = key
    end
  end
end

function G:activateSlot(i, shift, right)
  local ctx, list = self:commandContext()
  if not ctx then return end
  local key = list[i]
  if not key then return end
  if ctx == "builder" then
    self.mode = "build"
    self.buildKey = key
  else
    self:queueUnit(key, shift and 5 or 1, right)
  end
end

-- Announcer checks that aren't tied to a single world event
function G:updateVoice(dt)
  local vs, w = self.voiceState, self.world
  VOICE.update()
  -- music: hostile units in sight keep at least a low simmer of tension
  self.musicScan = (self.musicScan or 0) - dt
  if self.musicScan <= 0 then
    self.musicScan = 1
    local seen = 0
    for _, e in ipairs(w.entities) do
      if e.alive and not e.def.building and e.team ~= 0 and w:hostile(e.team, 1) and w:isVisible(e) then seen = seen + 1 end
    end
    MUSIC.floor = math.min(0.32, seen * 0.025)
    -- winning or losing: your alliance's live score against the best enemy alliance
    if w.score then
      local mine, best = 0, 0
      local byAlly = {}
      for t = 1, w.np do
        local sc = w.score[t]
        if sc then byAlly[w.ally[t]] = (byAlly[w.ally[t]] or 0) + sc.pts end
      end
      for a, p in pairs(byAlly) do
        if a == w.ally[1] then mine = p elseif p > best then best = p end
      end
      local total = math.max(1500, mine + best)
      MUSIC.setMood((mine - best) / total * 2.5)
    end
  end
  local c = w.teams[1].commander
  if c and c.alive and c.key == "commander" then
    if c.hp < vs.cmdHp - 1 then
      if c.hp < c.maxhp * 0.3 then VOICE.say("commander_low") elseif not self.arena then VOICE.say("commander_attack") end
    end
    vs.cmdHp = c.hp
    if c.nukeReady and not vs.nukeReady and (c.clevel or 0) >= 5 and vs.sawNukeCycle then VOICE.say("nuke_ready") end
    if c.nukeReady and (c.clevel or 0) >= 5 then vs.sawNukeCycle = true end
    vs.nukeReady = c.nukeReady
  end
  -- stalled economy: demand outstrips supply for a few seconds
  local tm = w.teams[1]
  vs.lowM = (tm.mRatio < 0.5 and tm.mDemand > 0) and vs.lowM + dt or 0
  vs.lowE = (tm.eRatio < 0.5 and tm.eDemand > 0) and vs.lowE + dt or 0
  if self.arena then return end
  if vs.lowM > 6 then VOICE.say("low_metal"); vs.lowM = 0 end
  if vs.lowE > 6 then VOICE.say("low_energy"); vs.lowE = 0 end
end

function G:notice(text, life, x, y)
  self.notices[#self.notices + 1] = { text = text, t = 0, life = life or 2.5, x = x, y = y }
  if #self.notices > 4 then table.remove(self.notices, 1) end
end

---------------------------------------------------------------------------
-- Update

function G:update(dt)
  -- (re)center on the Commander on the first frame: the window may have been resized
  -- after the game was created (browser builds especially)
  local gw, gh = love.graphics.getDimensions()
  if not self.camReady or (self.world.time < 3 and (gw ~= self.lastW or gh ~= self.lastH)) then
    self.camReady = true
    self.lastW, self.lastH = gw, gh
    local c = self.world.teams[1].commander
    if c and not self.opts.autotest then self:centerOn(c.x, c.y) end
  end
  -- Arena: your Commander is always selected (summons can be added alongside him)
  if self.arena then
    local c = self.world.teams[1].commander
    if c and c.alive and not self.selected[c] then self.selected[c] = true end
  end
  if self.world.over then
    if not self.overShown then
      self.overShown = true
      self.overTime = love.timer.getTime()
      local won = self.world.over.winnerAlly == self.world.ally[1]
      VOICE.say(won and "victory" or "defeat")
      if self.ghostRec then
        local GH = require("src.ghost")
        self.ghostUnlocked = GH.finish(self.ghostRec, self.world)
        self.ghostProgress = GH.completed()
        self.ghostRec = nil
      end
      MUSIC.finale(won)
      local w = self.world
      if w.score then
        local ais, levels = {}, {}
        for i, p in ipairs(self.players) do
          if not p.human then
            local nm = self.craft and (tostring(w.teams[i].race) .. " " .. tostring(w.teams[i].commander.class))
              or (self.arena and (w.teams[i].commander.class or "?") or (p.profileName or p.profile))
            ais[#ais + 1] = (w:hostile(i, 1) and "" or "ally ") .. nm .. " " .. p.level
            levels[i] = p.level
          end
        end
        local total, f = require("src.mods").finalScore(w, 1, levels)
        f.official = w.official
        f.lineup = table.concat(ais, ", ")
        self.finalScore = f
        if self.log then self.log:finish() end
        if w.official and not self.opts.autotest then
          self.highRank = require("src.scores").add({
            pts = total, result = f.won and "Win" or "Loss", date = os.date("%Y-%m-%d"),
            desc = string.format("%dp vs %s, %d:%02d", w.np, f.lineup, math.floor(w.time / 60), math.floor(w.time % 60)),
          }, self.arena and "arena" or (self.craft and "craft" or nil))
        end
      end
    end
  end
  if self.ghostRec then
    self.ghostT = (self.ghostT or 0) - dt
    if self.ghostT <= 0 then self.ghostT = 5; require("src.ghost").sample(self.ghostRec, self.world) end
  end
  self:applyMouseLock()
  -- dropship encounter: a brief, suspenseful pause while the coin flips
  local flip = self.flips and self.flips[1]
  if flip and not self.menuOpen then
    flip.t = flip.t + dt
    local MOD = require("src.mods")
    if flip.t >= MOD.FLIP_TIME + 1.2 then
      table.remove(self.flips, 1)
    elseif flip.t >= MOD.FLIP_TIME and not flip.applied then
      flip.applied = true
      MOD.applyDrop(self.world, flip.sq)
      if flip.sq.result == "join" then
        self:notice("Heads! The drop crew joins you (" .. #flip.sq.units .. " units)", 3)
        SFX.play("ready", 0.9, 0)
        VOICE.say("drop_join")
      else
        self:notice("Tails! The drop crew attacks!", 3)
        VOICE.say("drop_hostile")
        SFX.play("boom", 0.7, 0)
      end
    end
    if not flip.applied then return end
  end
  if self.paused or self.menuOpen or self.naming then return end

  -- camera panning: arrows / screen edge (wider zone, speeds up near the very edge)
  local w, h = self:viewSize()
  local mx, my = love.mouse.getPosition()
  local pan = 1000 / self.cam.zoom * dt * require("src.settings").v.pan
  local kd = love.keyboard.isDown
  local dx, dy = 0, 0
  if kd("left") then dx = dx - 1 end
  if kd("right") then dx = dx + 1 end
  if kd("up") then dy = dy - 1 end
  if kd("down") then dy = dy + 1 end
  if self.edgePan and love.window.hasMouseFocus() and not self.dragPan and not self.rightPan then
    local edge = 18
    local function ramp(d) return 0.35 + 0.65 * (1 - d / edge) end
    if mx <= edge then dx = dx - ramp(mx) end
    if mx >= w - 1 - edge then dx = dx + ramp(w - 1 - mx) end
    if my <= edge then dy = dy - ramp(my) end
    if my >= h - 1 - edge then dy = dy + ramp(h - 1 - my) end
  end
  if dx ~= 0 or dy ~= 0 then
    self.follow = nil
    self.cam.x = self.cam.x + dx * pan
    self.cam.y = self.cam.y + dy * pan
    self:clampCam()
  end
  self:updateFollow(dt)

  -- fixed sub-steps (never longer than 1/30 s) so any speed plays out exactly the same.
  -- High speeds on a slow machine: a frame does at most ~0.1 s of real work and the rest
  -- is dropped, so the game runs as fast as it can instead of locking up
  local step = math.min(dt, 0.05) * self.speed
  local n = math.max(1, math.ceil(step / 0.034))
  local t0 = love.timer.getTime()
  for i = 1, n do
    self.world:update(step / n)
    for _, ai in ipairs(self.ais) do ai:update(step / n) end
    if i < n and self.speed > 3 and love.timer.getTime() - t0 > 0.1 then break end
  end

  -- under attack notices
  local tm = self.world.teams[1]
  if self.arena then
    -- Arena: only the Core matters for alarms
    local core = self.world.arena.core1
    if core and core.alive then
      if core.hp < (self.coreHp or core.hp) - 1 and self.world.time - (self.coreWarn or -99) > 20 then
        self.coreWarn = self.world.time
        self:notice("Our Core is under attack!", 3)
        VOICE.say("core_attack")
        self.attackX, self.attackY = core.x, core.y
      end
      self.coreHp = core.hp
    end
  elseif tm.lastAttacked > self.lastAttackNotice + 12 and self.world.time - tm.lastAttacked < 0.5 then
    self.lastAttackNotice = self.world.time
    self:notice("Under attack!  (press Space to jump there)", 3)
    if self.log and not self.firstContact then self.firstContact = true; self.log:event("First enemy attack on you") end
    local nearBase = false
    self.world:query(tm.lastAttackX, tm.lastAttackY, 160, function(o)
      if o.team == 1 and o.def.building then nearBase = true end
    end)
    VOICE.say(nearBase and "under_attack" or "units_attacked")
    MUSIC.bump(0.2)
    self.attackX, self.attackY = tm.lastAttackX, tm.lastAttackY
    if not self:onScreen(tm.lastAttackX, tm.lastAttackY) then SFX.play("alert", 0.6, 0) end
  end

  self:updateVoice(dt)
  self:updateHoldFire()
  if self.log then self.log:update() end

  for i = #self.notices, 1, -1 do
    local nt = self.notices[i]
    nt.t = nt.t + dt
    if nt.t > nt.life then table.remove(self.notices, i) end
  end
end

---------------------------------------------------------------------------
-- Draw

function G:draw()
  local lg = love.graphics
  local w, h = self:viewSize()
  lg.clear(0.05, 0.07, 0.09)
  local cam = self.cam
  cam.wx0, cam.wy0 = self:screenToWorld(0, 0)
  cam.wx1, cam.wy1 = self:screenToWorld(w, h)
  lg.push()
  if self.shake and self.shake > 0 then
    self.shake = self.shake - love.timer.getDelta()
    lg.translate((math.random() - 0.5) * 18 * self.shake, (math.random() - 0.5) * 18 * self.shake)
  end
  lg.scale(cam.zoom)
  lg.translate(-cam.x, -cam.y)
  R.drawWorld(cam, self)
  self:drawOverlays()
  lg.pop()

  -- box selection
  if self.boxStart then
    local mx, my = love.mouse.getPosition()
    local x0, y0 = self.boxStart[1], self.boxStart[2]
    if math.abs(mx - x0) > 4 or math.abs(my - y0) > 4 then
      lg.setColor(0.3, 1, 0.4, 0.12)
      lg.rectangle("fill", math.min(x0, mx), math.min(y0, my), math.abs(mx - x0), math.abs(my - y0))
      lg.setColor(0.3, 1, 0.4, 0.8)
      lg.setLineWidth(1)
      lg.rectangle("line", math.min(x0, mx), math.min(y0, my), math.abs(mx - x0), math.abs(my - y0))
    end
  end

  UI.draw(self)
  self:drawHoverInfo()
end

-- hovering a visible enemy, creep or mine: a small card with its name, health and weapon
function G:drawHoverInfo()
  if self.boxStart or self.mode or self.menuOpen or self.showHelp then return end
  local mx, my = love.mouse.getPosition()
  if UI.overPanel(self, mx, my) then return end
  local wx, wy = self:screenToWorld(mx, my)
  local e = self:inspectable(wx, wy)
  if not e then return end
  local world, d = self.world, e.def
  local lg = love.graphics
  local title = d.name
  if e.key == "commander" and e.class and world.heroes then
    local cls = require("src.arena").byClass[e.class]
    title = (cls and cls.name or e.class) .. "  L" .. (e.clevel or 0)
  end
  local lines = {}
  if e.key == "goldmine" then lines[#lines + 1] = string.format("%d gold left", e.gold or 0)
  else lines[#lines + 1] = string.format("HP %d / %d", math.max(0, e.hp), e.maxhp) end
  if d.weapon then
    local m = e.mods or {}
    local dmg = d.weapon.damage * (m.craftDmg or 1) * (e.key == "commander" and (m.dmg or 1) or 1)
    local kind = (d.melee or m.melee) and "Melee" or (d.weapon.ballistic and "Siege" or "Ranged")
    lines[#lines + 1] = string.format("%s %d dmg, range %d", kind, dmg, world:rangeOf(e))
  end
  local who = e.key == "goldmine" and "Neutral" or (e.team == 0 and "Neutral creep" or (world:hostile(e.team, 1) and "Enemy" or "Ally"))
  local f1, f2 = R.font(14), R.font(12)
  local tw = f1:getWidth(title)
  for _, l in ipairs(lines) do tw = math.max(tw, f2:getWidth(l)) end
  tw = math.max(tw, f2:getWidth(who))
  local bw, bh = tw + 20, 26 + #lines * 16 + 16
  local bx, by = mx + 18, my + 14
  local sw, sh = self:viewSize()
  if bx + bw > sw then bx = mx - bw - 10 end
  if by + bh > sh then by = my - bh - 10 end
  lg.setColor(0.05, 0.07, 0.1, 0.92)
  lg.rectangle("fill", bx, by, bw, bh, 5)
  local hc = e.team == 0 and { 0.95, 0.8, 0.4 } or (world:hostile(e.team, 1) and { 1, 0.45, 0.4 } or { 0.5, 1, 0.6 })
  lg.setColor(hc[1], hc[2], hc[3], 0.8)
  lg.setLineWidth(1)
  lg.rectangle("line", bx, by, bw, bh, 5)
  lg.setFont(f1); lg.setColor(1, 1, 1)
  lg.print(title, bx + 10, by + 5)
  lg.setFont(f2); lg.setColor(hc)
  lg.print(who, bx + 10, by + 24)
  lg.setColor(0.8, 0.85, 0.9)
  for i, l in ipairs(lines) do lg.print(l, bx + 10, by + 24 + i * 16) end
end

-- Orders, build ghosts, rally points, range rings for the selection
function G:drawOverlays()
  local lg = love.graphics
  local world = self.world
  local T = D.TILE
  if self.flag then
    local fx, fy = self.flag.x, self.flag.y
    lg.setColor(0, 0, 0, 0.4)
    lg.ellipse("fill", fx, fy, 8, 3)
    lg.setColor(0.85, 0.85, 0.85)
    lg.setLineWidth(2)
    lg.line(fx, fy, fx, fy - 34)
    local wave = math.sin(love.timer.getTime() * 4) * 2
    lg.setColor(1, 0.85, 0.3)
    lg.polygon("fill", fx, fy - 34, fx + 20, fy - 29 + wave, fx, fy - 23)
  end
  local shift = love.keyboard.isDown("lshift", "rshift")
  if self.craft then
    -- with several heroes selected, mark the one Q W E R drive
    local sel = CG.selectedHeroes(self)
    local a = #sel >= 2 and CG.activeHero(self)
    if a then
      local t = love.timer.getTime()
      lg.setColor(1, 0.82, 0.3, 0.9)
      lg.setLineWidth(2.5)
      lg.circle("line", a.x, a.y, a.def.radius + 9 + math.sin(t * 5) * 1.5)
      lg.polygon("fill", a.x, a.y - a.def.radius - 14, a.x - 6, a.y - a.def.radius - 24, a.x + 6, a.y - a.def.radius - 24)
    end
  end
  local ins = self:inspectValid()
  if ins then
    local hc = ins.team == 0 and { 0.95, 0.8, 0.4 } or (world:hostile(ins.team, 1) and { 1, 0.35, 0.3 } or { 0.5, 1, 0.6 })
    lg.setColor(hc[1], hc[2], hc[3], 0.9)
    lg.setLineWidth(2)
    if ins.def.building then lg.rectangle("line", ins.x - ins.def.w * T / 2 - 1, ins.y - ins.def.h * T / 2 - 1, ins.def.w * T + 2, ins.def.h * T + 2, 6)
    else lg.circle("line", ins.x, ins.y, ins.def.radius + 5) end
  end
  for _, e in ipairs(self:selectedList()) do
    -- order waypoints
    if not e.def.building and (#e.orders > 0) then
      local px, py = e.x, e.y
      for _, o in ipairs(e.orders) do
        local ox, oy = o.x, o.y
        if o.type == "build" then ox, oy = (o.tx + D.units[o.key].w / 2) * T, (o.ty + D.units[o.key].h / 2) * T end
        if (o.type == "attack" or o.type == "assist") and o.target then ox, oy = o.target.x, o.target.y end
        if ox then
          local c = ({ move = { 0.3, 1, 0.4 }, amove = { 1, 0.4, 0.3 }, attack = { 1, 0.2, 0.2 }, patrol = { 0.4, 0.7, 1 }, build = { 0.4, 0.9, 1 }, assist = { 0.4, 0.9, 1 }, retreat = { 1, 0.85, 0.3 } })[o.type] or { 1, 1, 1 }
          lg.setColor(c[1], c[2], c[3], shift and 0.6 or 0.3)
          lg.setLineWidth(1.5)
          lg.line(px, py, ox, oy)
          lg.circle("fill", ox, oy, 3)
          px, py = ox, oy
        end
        -- planned building ghost
        if o.type == "build" and not o.ent then
          local d = D.units[o.key]
          lg.setColor(0.4, 0.9, 1, 0.25)
          lg.rectangle("fill", o.tx * T + 2, o.ty * T + 2, d.w * T - 4, d.h * T - 4, 4)
          lg.setColor(0.4, 0.9, 1, 0.7)
          lg.rectangle("line", o.tx * T + 2, o.ty * T + 2, d.w * T - 4, d.h * T - 4, 4)
        end
      end
    end
    -- rally point
    if e.def.factory and e.rally then
      local rx, ry = e.rally.x, e.rally.y
      if e.rally.target then
        if e.rally.target.alive then rx, ry = e.rally.target.x, e.rally.target.y else e.rally = nil end
      end
      if rx then
        lg.setColor(0.3, 1, 0.4, 0.5)
        lg.setLineWidth(1)
        lg.line(e.x, e.y, rx, ry)
        lg.circle("line", rx, ry, e.rally and e.rally.target and 22 or 8)
      end
    end
    -- weapon range ring
    if e.def.weapon and e.built >= 1 then
      lg.setColor(1, 0.4, 0.3, 0.12)
      lg.setLineWidth(1)
      lg.circle("line", e.x, e.y, self.world:rangeOf(e))
    end
  end

  -- nuke targeting
  if self.mode == "nuke" then
    local mx, my = love.mouse.getPosition()
    local wx, wy = self:screenToWorld(mx, my)
    local R = require("src.commander").NUKE_RADIUS
    local own = 0
    world:query(wx, wy, R + 40, function(o)
      if o.alive and o.def.building and not world:hostile(o.team, 1) and U.dist2(wx, wy, o.x, o.y) < R * R then own = own + 1 end
    end)
    lg.setColor(1, 0.2, 0.1, 0.12)
    lg.circle("fill", wx, wy, R)
    lg.setColor(1, 0.3, 0.15, 0.9)
    lg.setLineWidth(3)
    lg.circle("line", wx, wy, R)
    lg.line(wx - 20, wy, wx + 20, wy); lg.line(wx, wy - 20, wx, wy + 20)
    if own > 0 then
      lg.setFont(require("src.render").font(16))
      lg.setColor(1, 0.9, 0.3)
      lg.print("WARNING: " .. own .. " of your/allied buildings in the blast", wx - 150, wy + R + 8)
    end
  end
  -- drag-to-build preview
  if self.mode == "build" and self.buildKey and self.buildDrag then
    local mx, my = love.mouse.getPosition()
    local wx, wy = self:screenToWorld(mx, my)
    local sx, sy = self.buildDrag[1], self.buildDrag[2]
    local d = D.units[self.buildKey]
    lg.setColor(0.4, 0.9, 1, 0.12)
    lg.rectangle("fill", math.min(sx, wx), math.min(sy, wy), math.abs(wx - sx), math.abs(wy - sy))
    lg.setColor(0.4, 0.9, 1, 0.6)
    lg.setLineWidth(1)
    lg.rectangle("line", math.min(sx, wx), math.min(sy, wy), math.abs(wx - sx), math.abs(wy - sy))
    if math.abs(wx - sx) > T * 0.5 or math.abs(wy - sy) > T * 0.5 then
      for _, st in ipairs(self:areaSites(self.buildKey, sx, sy, wx, wy)) do
        lg.setColor(0.3, 1, 0.4, 0.35)
        lg.rectangle("fill", st.tx * T + 2, st.ty * T + 2, d.w * T - 4, d.h * T - 4, 4)
        lg.setColor(0.3, 1, 0.4, 0.9)
        lg.rectangle("line", st.tx * T + 2, st.ty * T + 2, d.w * T - 4, d.h * T - 4, 4)
      end
      return
    end
  end
  -- build placement ghost
  if self.mode == "build" and self.buildKey then
    local mx, my = love.mouse.getPosition()
    if not UI.overPanel(self, mx, my) then
      local wx, wy = self:screenToWorld(mx, my)
      local d = D.units[self.buildKey]
      local tx, ty = world:footprintAt(self.buildKey, wx, wy)
      local ok = world:canPlace(self.buildKey, tx, ty, 1)
      if ok then lg.setColor(0.3, 1, 0.4, 0.35) else lg.setColor(1, 0.25, 0.2, 0.35) end
      lg.rectangle("fill", tx * T, ty * T, d.w * T, d.h * T, 4)
      if ok then lg.setColor(0.3, 1, 0.4, 0.9) else lg.setColor(1, 0.25, 0.2, 0.9) end
      lg.setLineWidth(2)
      lg.rectangle("line", tx * T, ty * T, d.w * T, d.h * T, 4)
      if d.weapon then
        lg.setColor(1, 1, 1, 0.25)
        lg.circle("line", (tx + d.w / 2) * T, (ty + d.h / 2) * T, d.weapon.range)
      end
      -- highlight deposits when placing an extractor
      if self.buildKey == "mex" then
        local bl = self:selectedBuilders()
        for _, dp in ipairs(world.map.deposits) do
          local i = world.map:idx(dp.x, dp.y)
          if not world.map.blocked[i] and self:depositUsable(dp, bl) then
            lg.setColor(1, 0.9, 0.3, 0.6)
            lg.circle("line", (dp.x + 0.5) * T, (dp.y + 0.5) * T, 14)
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Input

function G:mousepressed(x, y, button)
  self.stats.actions = (self.stats.actions or 0) + 1
  if self.naming then return end
  if self.world.over and self.overShown then
    return UI.overClick(self, x, y, button)
  end
  local SET = require("src.settings")
  if SET.open then SET.click(x, y, button); return end
  if self.menuOpen then return UI.menuClick(self, x, y, button) end
  if UI.click(self, x, y, button) then return end
  local wx, wy = self:screenToWorld(x, y)
  local shift = love.keyboard.isDown("lshift", "rshift")
  if button == 1 then
    if self.mode == "build" then
      -- start a possible drag; single click is handled on release
      self.buildDrag = { wx, wy }
      return
    elseif self.mode == "patrol" and self:hasSelectedConstructor() then
      -- constructors: click = patrol, drag = repair zone (decided on release)
      self.zoneStart = { wx, wy }
      return
    elseif not self.mode and self:groupHeld() then
      self:commandMove(wx, wy, "gmove", shift)
      return
    elseif self.mode == "amove" or self.mode == "patrol" then
      self:commandMove(wx, wy, self.mode, shift)
      if not shift then self.mode = nil end
      return
    elseif self.mode == "sqskill" and self.sqAim then
      self:squadSkill(self.sqAim.slot, self.sqAim.sq, wx, wy)
      self.mode, self.sqAim = nil, nil
      return
    elseif self.mode == "nuke" then
      self.world:launchNuke(self:myCommander(), wx, wy)
      self.mode = nil
      return
    elseif self.mode == "skill" then
      local c = self.skillHero or (self.craft and CG.activeHero(self)) or self:myCommander()
      if c and c.alive then
        local ok, why = ARENA.useSkill(self.world, c, self.skillSlot, wx, wy)
        if not ok and why then self:notice(why, 1.2) end
      end
      self.mode, self.skillHero = nil, nil
      return
    elseif self.mode == "flag" then
      self.flag = { x = wx, y = wy }
      self:notice("Retreat flag placed", 1.2)
      self.mode = nil
      return
    end
    self.boxStart = { x, y }
  elseif button == 2 then
    if self.mode then self.mode = nil; return end
    -- decide on release: a drag pans the camera, a click gives an order
    self.rightDown = { x, y, self.cam.x, self.cam.y }
    self.rightPan = false
  elseif button == 3 then
    self.dragPan = { x, y, self.cam.x, self.cam.y }
    self.follow = nil
  end
end

function G:hasSelectedConstructor()
  for _, e in ipairs(self:selectedMobile()) do
    if e.def.builds and not e.def.factory then return true end
  end
  return false
end

-- the zone being dragged right now: center, radius
function G:zoneDraft()
  if not self.zoneStart then return nil end
  local wx, wy = self:screenToWorld(love.mouse.getPosition())
  local d = U.dist(self.zoneStart[1], self.zoneStart[2], wx, wy)
  return self.zoneStart[1], self.zoneStart[2], d
end

function G:placeRepairZone(x, y, r, queue)
  r = math.max(140, math.min(900, r))
  local others = {}
  local n = 0
  for _, e in ipairs(self:selectedMobile()) do
    if e.def.builds and not e.def.factory then
      self.world:issue(e, { type = "repairzone", x = x, y = y, r = r }, queue) -- Shift: after what's queued
      n = n + 1
    else
      others[#others + 1] = e
    end
  end
  for _, e in ipairs(others) do
    local last = queue and e.orders[#e.orders]
    self.world:issue(e, { type = "patrol", x = x, y = y, fromX = last and last.x or e.x, fromY = last and last.y or e.y }, queue)
  end
  self.world.effects[#self.world.effects + 1] = { kind = "ping", x = x, y = y, t = 0, life = 0.6, r = 0.3, g = 1, b = 0.6 }
  self:notice(string.format("Repair zone: %d constructor%s on duty", n, n == 1 and "" or "s"), 1.5)
end

function G:mousereleased(x, y, button)
  if button == 1 and self.zoneStart then
    local cx, cy, d = self:zoneDraft()
    self.zoneStart = nil
    local shift = love.keyboard.isDown("lshift", "rshift")
    if d < 40 then
      self:commandMove(cx, cy, "patrol", shift)
    else
      self:placeRepairZone(cx, cy, d, shift)
    end
    if not shift then self.mode = nil end
    return
  end
  if button == 3 then self.dragPan = nil end
  if button == 2 and self.rightDown then
    local wasPan = self.rightPan
    self.rightDown, self.rightPan = nil, false
    if not wasPan then
      local wx, wy = self:screenToWorld(x, y)
      self:rightClick(wx, wy, love.keyboard.isDown("lshift", "rshift"))
    end
    return
  end
  if button == 1 then self.minimapDrag = false end
  if button == 1 and self.buildDrag and self.mode == "build" then
    local shift = love.keyboard.isDown("lshift", "rshift")
    local wx, wy = self:screenToWorld(x, y)
    local sx, sy = self.buildDrag[1], self.buildDrag[2]
    self.buildDrag = nil
    local d = D.units[self.buildKey]
    if math.abs(wx - sx) < d.w * D.TILE * 0.6 and math.abs(wy - sy) < d.h * D.TILE * 0.6 then
      if self:placeBuilding(wx, wy, shift) and not shift then self.mode = nil end
    else
      local sites = self:areaSites(self.buildKey, sx, sy, wx, wy)
      if #sites == 0 then
        self:notice("Nowhere to build in that area", 1.2)
      else
        self:assignSites(self.buildKey, sites, shift)
        self:notice(#sites .. " x " .. d.name .. " queued (nearest first)", 1.5)
        if not shift then self.mode = nil end
      end
    end
    return
  end
  self.buildDrag = nil
  if button ~= 1 or not self.boxStart then return end
  local x0, y0 = self.boxStart[1], self.boxStart[2]
  self.boxStart = nil
  local shift = love.keyboard.isDown("lshift", "rshift")
  local world = self.world
  if math.abs(x - x0) <= 4 and math.abs(y - y0) <= 4 then
    -- click select
    local wx, wy = self:screenToWorld(x, y)
    local e = world:entityAt(wx, wy, function(o) return o.team == 1 end)
    if not e then
      -- nothing of ours there: inspect whatever visible enemy / neutral / mine is under the cursor
      local other = self:inspectable(wx, wy)
      if not shift then self.selected = {} end
      self.inspect = other
      return
    end
    local now = love.timer.getTime()
    if self.lastClick.e == e and now - self.lastClick.t < 0.35 then
      -- double click: all of this type on screen
      local list = {}
      local cam = self.cam
      for _, o in ipairs(world.entities) do
        if o.alive and o.team == 1 and o.key == e.key and o.x > cam.wx0 and o.x < cam.wx1 and o.y > cam.wy0 and o.y < cam.wy1 then
          list[#list + 1] = o
        end
      end
      self:select(list, shift)
    elseif shift and self.selected[e] then
      self.selected[e] = nil
    else
      self:select({ e }, shift)
    end
    self.lastClick = { t = now, e = e }
    return
  end
  -- box select: prefer mobile units over buildings
  local ax, ay = self:screenToWorld(math.min(x, x0), math.min(y, y0))
  local bx, by = self:screenToWorld(math.max(x, x0), math.max(y, y0))
  local units, buildings = {}, {}
  for _, e in ipairs(world.entities) do
    if e.alive and e.team == 1 and e.x >= ax and e.x <= bx and e.y >= ay and e.y <= by then
      if e.def.building then buildings[#buildings + 1] = e else units[#units + 1] = e end
    end
  end
  -- a box with combat units in it leaves the constructors out (the Commander always comes along)
  local fighters = {}
  local hasCombat = false
  for _, e in ipairs(units) do
    local constructor = e.def.builds and not e.def.factory and e.key ~= "commander"
    if not constructor then fighters[#fighters + 1] = e end
    if not constructor and e.key ~= "commander" then hasCombat = true end
  end
  if hasCombat then units = fighters end
  if #units > 0 then self:select(units, shift)
  elseif #buildings > 0 then self:select(buildings, shift)
  elseif not shift then self.selected = {} end
end

function G:mousemoved(x, y, dx, dy)
  local rd = self.rightDown
  if rd then
    -- right-drag panning is off: on trackpads (Steam Deck) a slightly moving right-click
    -- turned into a pan and the order was lost. Right-click is always an order now.
    if self.rightPan then
      local z = self.cam.zoom
      self.cam.x = rd[3] - (x - rd[1]) / z
      self.cam.y = rd[4] - (y - rd[2]) / z
      self:clampCam()
    end
  end
  if self.dragPan then
    local z = self.cam.zoom
    self.cam.x = self.dragPan[3] - (x - self.dragPan[1]) / z
    self.cam.y = self.dragPan[4] - (y - self.dragPan[2]) / z
    self:clampCam()
  end
  if self.minimapDrag then UI.minimapDrag(self, x, y) end
end

function G:wheelmoved(dx, dy)
  local mx, my = love.mouse.getPosition()
  if UI.overPanel(self, mx, my) then return end
  if love.keyboard.isDown("lalt", "ralt") then
    -- Option + two-finger scroll pans (handy on a trackpad)
    self.follow = nil
    local sp = 40 * require("src.settings").v.scroll
    self.cam.x = self.cam.x - dx * sp / self.cam.zoom
    self.cam.y = self.cam.y - dy * sp / self.cam.zoom
    self:clampCam()
    return
  end
  local zf = 1 + 0.12 * require("src.settings").v.zoom
  if dy ~= 0 then self:zoomAt(mx, my, dy > 0 and zf or 1 / zf) end
end

-- Camera that tracks units. Cinematic mode also zooms to frame them.
function G:startFollow(cinematic)
  local list = self:selectedList()
  if #list == 0 then self.follow = nil; return end
  if self.follow then self.follow = nil; self:notice("Camera unlocked", 1); return end
  self.follow = { units = list, cinematic = cinematic }
  self:notice((cinematic and "Cinematic camera" or "Camera locked") .. " on " .. #list .. " units  (L or pan to release)", 1.6)
end

function G:updateFollow(dt)
  local f = self.follow
  if not f then return end
  local alive = {}
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, e in ipairs(f.units) do
    if e.alive then
      alive[#alive + 1] = e
      x0, y0 = math.min(x0, e.x), math.min(y0, e.y)
      x1, y1 = math.max(x1, e.x), math.max(y1, e.y)
    end
  end
  f.units = alive
  if #alive == 0 then self.follow = nil; return end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  local w, h = self:viewSize()
  local z = self.cam.zoom
  if f.cinematic then
    local vh = h - UI.PANEL_H - UI.TOP_H
    local target = math.min(w / (x1 - x0 + 700), vh / (y1 - y0 + 500))
    target = U.clamp(target, 0.45, 1.4)
    local nz = z + (target - z) * math.min(1, dt * 0.8)
    self.cam.zoom = nz
    z = nz
  end
  local tx = cx - w / 2 / z
  local ty = cy - (h - UI.PANEL_H + UI.TOP_H) / 2 / z
  local k = math.min(1, dt * (f.cinematic and 1.8 or 5))
  self.cam.x = self.cam.x + (tx - self.cam.x) * k
  self.cam.y = self.cam.y + (ty - self.cam.y) * k
  self:clampCam()
end

-- Keep the pointer inside the window so screen-edge panning always works
function G:applyMouseLock()
  local want = self.mouseLock and not self.menuOpen and not self.world.over and love.window.hasFocus()
  love.mouse.setGrabbed(want and true or false)
end

function G:keypressed(key)
  self.stats.actions = (self.stats.actions or 0) + 1
  if self.naming then return self:namingKey(key) end
  local ctrl = love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui")
  local shift = love.keyboard.isDown("lshift", "rshift")
  if self.world.over and self.overShown then return end

  if key == "escape" and require("src.settings").open then require("src.settings").open = false; require("src.settings").save(); return end
  if require("src.settings").open then return end
  if key == "escape" then
    if self.showHelp then self.showHelp = false
    elseif self.mode then self.mode = nil
    else self.menuOpen = not self.menuOpen end
    return
  end
  if self.menuOpen then return end
  if key == "f1" then self.showHelp = not self.showHelp; return end
  if key == "pause" or key == "f3" then self.paused = not self.paused; return end

  local n = tonumber(key)
  local alt = love.keyboard.isDown("lalt", "ralt")
  if n and n >= 1 and n <= 9 and alt and self.world.squads then
    -- Commander of Heroes: Alt+number pulls just that squad back to the HQ (your selection stays)
    local sq = require("src.squads").squadsOf(self.world, 1)[n]
    if sq then self:fleeSquad(sq) end
    return
  end
  if n and n >= 0 and n <= 9 and alt then
    -- Option/Alt+number: new units from the selected factories join that group (0 = none)
    local facs = self:selectedFactories()
    for _, f in ipairs(facs) do f.assignGroup = (n > 0) and n or nil end
    if #facs > 0 then
      self:notice(n > 0 and ("New units from " .. #facs .. " factory(s) will join group " .. n) or "Factory group cleared", 1.6)
    end
    return
  end
  if n and n >= 1 and n <= 9 and self.world.squads then
    -- Commander of Heroes: 1-5 always pick that squad (tap twice to jump to its leader)
    local SQ = require("src.squads")
    local sq = SQ.squadsOf(self.world, 1)[n]
    if not sq then return end
    local now = love.timer.getTime()
    local twice = self.lastGroupTap.n == n and now - self.lastGroupTap.t < 0.4
    self:pickSquad(sq, shift)
    if twice then
      local L = sq.leader
      if L and L.alive then self:centerOn(L.x, L.y) end
    end
    self.lastGroupTap = { n = n, t = now }
    return
  end
  if n and n >= 1 and n <= 9 then
    if ctrl then
      self.groups[n] = self:selectedList()
      self:notice("Group " .. n .. " set (" .. #self.groups[n] .. ")", 1.2)
    elseif shift then
      local g = self.groups[n] or {}
      local have = {}
      for _, e in ipairs(g) do have[e] = true end
      for _, e in ipairs(self:selectedList()) do if not have[e] then g[#g + 1] = e end end
      self.groups[n] = g
    else
      local g = self.groups[n]
      if g then
        local alive = {}
        for _, e in ipairs(g) do if e.alive then alive[#alive + 1] = e end end
        self.groups[n] = alive
        self:select(alive)
        local now = love.timer.getTime()
        if self.lastGroupTap.n == n and now - self.lastGroupTap.t < 0.4 and #alive > 0 then
          local cx, cy = 0, 0
          for _, e in ipairs(alive) do cx, cy = cx + e.x, cy + e.y end
          self:centerOn(cx / #alive, cy / #alive)
        end
        self.lastGroupTap = { n = n, t = now }
      end
    end
    return
  end

  if ctrl and key == "a" then
    self:selectAllArmy()
    return
  end
  if key == "h" then
    if shift then self:selectOtherHalf() else self:selectHalf() end
    return
  end
  if key == "z" or key == "x" then
    self:pickUpgrade(key == "z" and 1 or 2)
    return
  end
  if key == "d" and self.holdToggle then self.holdToggle = false end
  if self.world.squads and (key == "q" or key == "w") then self:squadSkill(key == "q" and 1 or 2); return end
  if self.craft then
    if key == "q" and shift and CG.trainWorker(self) then return end
    if CG.heroKey(self, key) then return end
    if key == "n" then return end
    if key == "c" then CG.cycleHero(self, shift); return end
    if key == "tab" then CG.idleWorker(self); return end
  end
  if self.arena then
    -- Arena: Q W E R fire skills at the mouse; F heads home to heal
    for slot, k in ipairs(ARENA.KEYS) do
      if key == k then self:useSkill(slot); return end
    end
    if key == "f" then self:goHome(); return end
    if key == "b" or key == "tab" or key == "n" or key == "g" or key == "p" then return end
  end
  if key == "n" then
    self:startNuke()
    return
  end
  if key == "f" then
    if ctrl then
      local mx, my = love.mouse.getPosition()
      local wx, wy = self:screenToWorld(mx, my)
      self.flag = { x = wx, y = wy }
      self:notice("Retreat flag placed", 1.2)
    else
      self:retreat(shift and "commander" or "flag")
      VOICE.say("retreat")
    end
    return
  end
  if ctrl and key == "b" then
    self:select(self.world:teamEntities(1, function(e) return e.key == "builder" end))
    return
  end

  -- build / produce slots
  for i, hk in ipairs(self.craft and UI.CRAFT_KEYS or D.hotkeys) do
    if key == hk then
      if self.craft and not self:commandContext() then break end
      self:activateSlot(i, shift); return
    end
  end

  if key == "a" then
    if #self:selectedMobile() > 0 then self.mode = "amove" end
  elseif key == "s" then
    self:stop()
  elseif (key == "delete" or key == "backspace") and not shift then
    self:selfDestruct()
  elseif key == "p" then
    if #self:selectedMobile() > 0 then self.mode = "patrol" end
  elseif key == "space" then
    if self.attackX and self.world.time - self.world.teams[1].lastAttacked < 15 then
      self:centerOn(self.attackX, self.attackY)
    else
      local c = self.world.teams[1].commander
      if c and c.alive then self:centerOn(c.x, c.y) end
    end
  elseif key == "c" and shift then
    -- cycle through your Generals
    local list = {}
    for _, g in ipairs((self.world.generals or {})[1] or {}) do if g.alive then list[#list + 1] = g end end
    if #list == 0 then self:notice("No Generals yet - a unit that reaches level 5 is promoted", 2)
    else
      self.genIdx = (self.genIdx or 0) % #list + 1
      local g = list[self.genIdx]
      self:centerOn(g.x, g.y); self:select({ g })
    end
  elseif key == "c" and self.world.squads then
    -- Commander of Heroes: C moves the active squad (the gold one Q / W fire for) through the
    -- selected squads; with one or none selected it steps to the next squad
    local SQ = require("src.squads")
    local sel = self:selectedSquads()
    local cur = self:activeSquad()
    if #sel > 1 then
      local i = 1
      for j, sq in ipairs(sel) do if sq == cur then i = j end end
      self.activeSq = sel[i % #sel + 1]
      self:notice(string.format("Active: squad %d, %s", self.activeSq.idx, SQ.byType[self.activeSq.type].name), 1.2)
    else
      local all = SQ.squadsOf(self.world, 1)
      local i = 0
      for j, sq in ipairs(all) do if sq == cur then i = j end end
      local nx = all[i % #all + 1]
      if nx then
        self:pickSquad(nx)
        local L = nx.leader
        if L and L.alive then self:centerOn(L.x, L.y) end
      end
    end
  elseif key == "home" or key == "c" then
    local c = self.world.teams[1].commander
    if c and c.alive then self:centerOn(c.x, c.y); self:select({ c }) end
  elseif key == "l" then
    self:startFollow(shift)
  elseif key == "f9" then
    self.mouseLock = not self.mouseLock
    self:notice(self.mouseLock and "Mouse kept inside window (edge panning on)" or "Mouse free to leave window", 1.6)
  elseif key == "f8" then
    self.edgePan = not self.edgePan
    local SET = require("src.settings"); SET.v.edge = self.edgePan; SET.save()
    self:notice(self.edgePan and "Edge panning on" or "Edge panning off", 1.2)
  elseif key == "tab" then
    self:selectIdleBuilder()
  elseif key == "=" or key == "kp+" then
    self:stepSpeed(1)
  elseif key == "-" or key == "kp-" then
    self:stepSpeed(-1)
  elseif key == "b" and not ctrl then
    self.showSidebar = not self.showSidebar
  elseif (key == "delete" or key == "backspace") and shift then
    -- cancel last queued order
    for _, u in ipairs(self:selectedMobile()) do
      if #u.orders > 0 then table.remove(u.orders); u.path = nil end
    end
  elseif key == "g" then
    local facs = self:selectedFactories()
    if #facs > 0 then
      for _, f in ipairs(facs) do f.repeatMode = not f.repeatMode end
    end
  elseif key == "m" and shift then
    MUSIC.setMuted(not MUSIC.muted)
    self:notice(MUSIC.muted and "Music off" or "Music on", 1)
  elseif key == "m" then
    SFX.muted = not SFX.muted
    self:notice(SFX.muted and "Sound effects off" or "Sound effects on", 1)
  elseif key == "v" then
    VOICE.muted = not VOICE.muted
    if VOICE.muted then VOICE.stopAll() end
    self:notice(VOICE.muted and "Announcer off" or "Announcer on", 1)
  end
end

-- Saving the current map under a name (seed + settings)
function G:startNaming()
  self.menuOpen = false
  self.naming = { text = "Map " .. self.world.map.seed }
  love.keyboard.setTextInput(true)
end

function G:textinput(t)
  if self.naming and #self.naming.text < 40 then self.naming.text = self.naming.text .. t end
end

function G:namingKey(key)
  local n = self.naming
  if key == "escape" then
    self.naming = nil
  elseif key == "backspace" then
    n.text = n.text:sub(1, -2)
  elseif key == "return" or key == "kpenter" then
    local name = n.text:gsub("^%s+", ""):gsub("%s+$", "")
    if #name > 0 then
      local map = self.world.map
      require("src.maps").add({ name = name, seed = map.seed, size = map.w, water = self.opts.water or 0.3, np = map.four and 4 or 2 })
      self:notice("Saved map \"" .. name .. "\"", 2)
    end
    self.naming = nil
  end
  if not self.naming then love.keyboard.setTextInput(false) end
end

-- Commander of Heroes: the squads with a unit selected
function G:selectedSquads()
  local seen, out = {}, {}
  for _, e in ipairs(self:selectedList()) do
    if e.squad and e.squad.team == 1 and not seen[e.squad] then seen[e.squad] = true; out[#out + 1] = e.squad end
  end
  table.sort(out, function(a, b) return a.idx < b.idx end)
  return out
end

-- the squad Q / W fire for: the active one if it's selected, else the first selected
function G:activeSquad()
  local list = self:selectedSquads()
  for _, sq in ipairs(list) do if sq == self.activeSq then return sq end end
  self.activeSq = list[1]
  return list[1]
end

-- select a squad (Shift adds it) and make it the active one; again on the active one jumps to it
function G:pickSquad(sq, add)
  local alive = {}
  for _, e in ipairs(sq.members) do if e.alive then alive[#alive + 1] = e end end
  local again = self.activeSq == sq and self.selected[alive[1] or false]
  self:select(alive, add)
  self.activeSq = sq
  if again or #alive == 0 then
    local L = sq.leader
    if L and L.alive then self:centerOn(L.x, L.y) elseif alive[1] then self:centerOn(alive[1].x, alive[1].y) end
  end
  if #alive == 0 then self:notice(string.format("Squad %d is gone for now - replacements are on the way from the HQ", sq.idx), 1.8) end
end

-- Q / W: skill 1 or 2 of the selected squads. Self skills fire for every selected squad that has
-- it ready; aimed skills go to the mouse, from the first squad that can
function G:squadSkill(slot, sqOnly, wx, wy)
  local SQ = require("src.squads")
  local act = self:activeSquad()
  local list = sqOnly and { sqOnly } or (act and { act } or {})
  if #list == 0 then self:notice("Select a squad first (1-5, or click its card)", 1.2); return end
  if sqOnly then self.activeSq = sqOnly end
  if not wx then wx, wy = self:screenToWorld(love.mouse.getPosition()) end
  local done, why = false, nil
  for _, sq in ipairs(list) do
    local s = sq.skills[slot]
    if s then
      local ok, r = SQ.cast(self.world, sq, slot, wx, wy)
      if ok then
        done = true
        if SQ.SKILLS[s.key].aim == "point" then break end
      else why = why or r end
    end
  end
  if not done and why then self:notice(why, 1.4) end
end
-- a flashing marker on the minimap for a few seconds (e.g. where an ally's Commander fell)
function G:minimapPing(x, y, col)
  self.mmPings = self.mmPings or {}
  self.mmPings[#self.mmPings + 1] = { x = x, y = y, t0 = love.timer.getTime(), col = col or { 1, 1, 1 } }
end

function G:myCommander()
  if self.craft then return CG.offerHero(self) end
  local c = self.world.teams[1].commander
  if c and c.alive then return c end
end

function G:pickUpgrade(i)
  local c = self:myCommander()
  if not c or #c.offers == 0 then return end
  local u = self.world:chooseUpgrade(c, i)
  if u then
    self:notice("Upgrade: " .. u.name, 2)
    SFX.play("ready", 0.6, 0)
  end
end

function G:startNuke()
  local c = self:myCommander()
  if not c then return end
  if not c.nukeReady then
    self:notice("The Nuke unlocks at Commander level 5", 1.5)
  elseif not self.world:canNuke(c) then
    local left = math.ceil(c.nukeReady - self.world.time)
    self:notice(string.format("Nuke recharging: %d:%02d", math.floor(left / 60), left % 60), 1.5)
  else
    self.mode = "nuke"
  end
end

-- game speed steps: the simulation always runs in the same small fixed steps, so speed never
-- changes the outcome, only how many steps a frame takes
G.SPEEDS = { 0.5, 1, 1.5, 2, 3, 5, 8, 10, 15 }
function G:setSpeed(v)
  self.speed = U.clamp(v, 0.5, 15)
  self:notice("Game speed " .. self.speed .. "x", 1)
end
function G:stepSpeed(dir)
  local cur, list = self.speed, G.SPEEDS
  local pick = dir > 0 and list[#list] or list[1]
  if dir > 0 then
    for _, v in ipairs(list) do if v > cur + 0.01 then pick = v; break end end
  else
    for i = #list, 1, -1 do if list[i] < cur - 0.01 then pick = list[i]; break end end
  end
  self:setSpeed(pick)
end

-- Pull the selected units back (weapons off, +25% speed) to the flag or the Commander
-- Commander of Heroes: one squad falls back to the HQ, whatever else is selected
function G:fleeSquad(sq)
  local keep = self.selected
  local alive = {}
  for _, u in ipairs(sq.members) do if u.alive then alive[#alive + 1] = u end end
  if #alive == 0 then return end
  self.selected = {}
  for _, u in ipairs(alive) do self.selected[u] = true end
  self:retreat("flag")
  self.selected = keep
  self:notice(string.format("Squad %d (%s) falling back to the HQ", sq.idx, require("src.squads").byType[sq.type].name), 1.5)
end

function G:retreat(where)
  local units = self:selectedMobile()
  local list = {}
  for _, u in ipairs(units) do
    if u.key == "commander" then
      -- the Commander flees home (+50% speed), powered down until he's fully repaired there
      local tm = self.world.teams[1]
      self.world:issue(u, { type = "retreat", x = tm.startX, y = tm.startY })
      self:notice("Commander retreating home: he stays there, weapons off, until fully repaired", 2.5)
    else list[#list + 1] = u end
  end
  if #list == 0 then return end
  local c = self.world.teams[1].commander
  local x, y
  local hq = self.world.squads and self.world.teams[1].hq
  if where == "flag" and self.flag then x, y = self.flag.x, self.flag.y
  elseif hq and hq.alive then x, y = hq.x, hq.y + 90 -- Commander of Heroes: flee to the HQ (it heals)
  elseif c and c.alive then x, y = c.x, c.y
  else x, y = self.world.teams[1].startX, self.world.teams[1].startY end
  local slots = self:formation(list, x, y)
  for _, u in ipairs(list) do
    self.world:issue(u, { type = "retreat", x = slots[u][1], y = slots[u][2] })
  end
  self.world.effects[#self.world.effects + 1] = { kind = "ping", x = x, y = y, t = 0, life = 0.6, r = 1, g = 0.85, b = 0.3 }
  local name = (where == "flag" and self.flag) and "the flag" or (hq and hq.alive and "the HQ" or "the Commander")
  self:notice("Retreating " .. #list .. " units to " .. name, 1.2)
end

-- Every combat unit you own (not the Commander or constructors)
function G:selectAllArmy()
  local list = self.world:teamEntities(1, function(e)
    return not e.def.building and e.def.weapon and e.key ~= "commander"
  end)
  self:select(list)
  self:notice("Selected all " .. #list .. " combat units", 1)
end

-- Keep half of the current selection, balanced per unit type, preferring
-- the units nearest the mouse pointer. Shift+H later grabs the other half.
function G:selectHalf()
  local list = self:selectedList()
  if #list < 2 then return end
  local mx, my = love.mouse.getPosition()
  local wx, wy = self:screenToWorld(mx, my)
  local byType, types = {}, {}
  for _, e in ipairs(list) do
    if not byType[e.key] then byType[e.key] = {}; types[#types + 1] = e.key end
    local t = byType[e.key]
    t[#t + 1] = e
  end
  local keep, rest = {}, {}
  for _, k in ipairs(types) do
    local t = byType[k]
    table.sort(t, function(a, b) return U.dist2(a.x, a.y, wx, wy) < U.dist2(b.x, b.y, wx, wy) end)
    local n = math.ceil(#t / 2)
    for i, e in ipairs(t) do
      if i <= n then keep[#keep + 1] = e else rest[#rest + 1] = e end
    end
  end
  self.otherHalf = rest
  self:select(keep)
  self:notice(string.format("Half: %d selected  (Shift+H = the other %d)", #keep, #rest), 1.5)
end

function G:selectOtherHalf()
  if not self.otherHalf then return end
  local alive = {}
  for _, e in ipairs(self.otherHalf) do if e.alive then alive[#alive + 1] = e end end
  if #alive == 0 then return end
  local prev = self:selectedList()
  self:select(alive)
  self.otherHalf = prev
  self:notice("Other half: " .. #alive .. " selected", 1.2)
end

function G:selectIdleBuilder()
  local idle = self.world:teamEntities(1, function(e) return e.def.builds and not e.def.factory and #e.orders == 0 end)
  if #idle == 0 then self:notice("No idle constructors", 1.2); return end
  self.idleIdx = ((self.idleIdx or 0) % #idle) + 1
  local b = idle[self.idleIdx]
  self:select({ b })
  self:centerOn(b.x, b.y)
end

return G
