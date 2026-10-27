-- Match log: a plain-text record of each game for balance review.
-- Written next to PartialAnnihilation.love in a "logs" folder (falls back to LÖVE's save
-- folder), appended as the game goes so a quit or crash still leaves a usable log.
local D = require("src.defs")
local L = {}
L.__index = L

local function logDir()
  local base = love.filesystem.getSource()
  if base and base:match("%.love$") and love.system.getOS() ~= "Web" then
    local dir = love.filesystem.getSourceBaseDirectory() .. "/logs"
    -- (only start a helper to make the folder when it isn't there yet: on macOS every helper
    -- that touches Documents asks for permission again)
    local probe = io.open(dir .. "/.probe", "w")
    if not probe then
      if love.system.getOS() == "Windows" then os.execute('mkdir "' .. dir .. '" 2>nul')
      else os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'") end
      probe = io.open(dir .. "/.probe", "w")
    end
    if probe then probe:close(); os.remove(dir .. "/.probe"); return dir, true end
  end
  love.filesystem.createDirectory("logs")
  return love.filesystem.getSaveDirectory() .. "/logs", false
end

local function mmss(t) return string.format("%d:%02d", math.floor(t / 60), math.floor(t % 60)) end

function L.start(game)
  local self = setmetatable({ game = game, lines = {}, nextSnap = 60 }, L)
  local w = game.world
  local dir, direct = logDir()
  local name = string.format("%s_seed%d.txt", os.date("%Y-%m-%d_%H%M%S"), w.map.seed % 100000000)
  self.direct = direct
  if direct then self.path = dir .. "/" .. name
  else self.lpath = "logs/" .. name; self.path = dir .. "/" .. name end
  local mods = {}
  for k, v in pairs(w.mods or {}) do if v then mods[#mods + 1] = k end end
  table.sort(mods)
  local water, total = 0, w.map.w * w.map.h
  for i = 0, total - 1 do if w.map.terrain[i] == 0 then water = water + 1 end end
  local mk = w.craft and "craft" or (w.arena and "arena" or (w.coh and "coh" or "rts"))
  self:raw("PARTIAL ANNIHILATION MATCH LOG  v" .. D.VERSION .. "  (" .. D.MODE_NAMES[mk] .. " " .. D.MODE_VERSIONS[mk][1] .. ")   " .. os.date("%Y-%m-%d %H:%M"))
  if w.craft then
    self:raw(string.format("Mode: COMMANDER CRAFT   map %s %dx%d seed %d, official score: %s", w.map.template or "horseshoe",
      w.map.w, w.map.h, w.map.seed, w.official and "yes" or "no"))
  elseif w.arena then
    self:raw(string.format("Mode: COMMANDER ARENA   map %s %dx%d seed %d, %d sides%s, official score: %s", w.map.template or "classic",
      w.map.w, w.map.h, w.map.seed, w.arena.nSides, w.arena.ffa and " (free-for-all)" or "", w.official and "yes" or "no"))
  else
  self:raw(w.coh and "Mode: COMMANDER OF HEROES" or "Mode: ANNIHILATION")
  self:raw(string.format("Map: %dx%d seed %d, water %.0f%% (%s), modifiers: %s, official score: %s",
    w.map.w, w.map.h, w.map.seed, 100 * water / total, w.map.ring and "ocean ring" or "no ring",
    #mods > 0 and table.concat(mods, ",") or "none", w.official and "yes" or "no"))
  local land, rich, sea = 0, 0, 0
  for _, dp in ipairs(w.map.deposits) do
    if dp.sea then sea = sea + 1 elseif dp.rich then rich = rich + 1 else land = land + 1 end
  end
  self:raw(string.format("Metal deposits: %d land, %d rich land (center), %d rich offshore", land, rich, sea))
  end
  for i, p in ipairs(game.players) do
    self:raw(string.format("  P%d %-7s team %d  %s%s", i, D.teamName[i] or "?", p.team or w.ally[i],
      p.human and "HUMAN" or (tostring(p.profileName or p.profile) .. " level " .. tostring(p.level)),
      w.craft and ("  race " .. tostring(w.teams[i].race) .. "  hero " .. tostring(w.teams[i].commander.class))
      or (w.arena and ("  class " .. tostring(w.teams[i].commander.class)) or "")))
  end
  self:raw("")
  if w.craft then
    self:raw("Snapshots every minute: gold/wood banked and income per minute, food/upkeep, tier, workers on gold/wood,")
    self:raw("army (food in fighting units), K/L = kills/losses so far, heroes (class, level, skills, cards), unit and building counts.")
  elseif w.arena then
    self:raw("Snapshots every minute: each Commander's class, level, health, deaths, skills and upgrades.")
  else
  self:raw("Snapshots every minute: income m/e per second, banked metal, unit and building counts,")
  self:raw("army = metal value of combat units, Cmd = Commander level/hp/upgrades, K/L = enemy kills/own losses so far.")
  end
  self:raw("")
  self.kills, self.losses = {}, {}
  for t = 1, w.np do self.kills[t], self.losses[t] = 0, 0 end
  self:flush()
  return self
end

function L:raw(s) self.lines[#self.lines + 1] = s end

function L:event(text)
  self:raw(string.format("[%s] %s", mmss(self.game.world.time), text))
end

function L:flush()
  if #self.lines == 0 then return end
  local text = table.concat(self.lines, "\n") .. "\n"
  self.lines = {}
  if self.direct then
    local f = io.open(self.path, "a")
    if f then f:write(text); f:close() end
  else
    love.filesystem.append(self.lpath, text)
  end
end

function L:onKill(o, attacker)
  local w = self.game.world
  if o.team and o.team >= 1 then self.losses[o.team] = (self.losses[o.team] or 0) + 1 end
  if attacker and attacker.team and attacker.team >= 1 and w:hostile(attacker.team, o.team) then
    self.kills[attacker.team] = (self.kills[attacker.team] or 0) + 1
  end
  if o.key == "commander" and not w.craft then
    self:event(string.format("%s's Commander destroyed by %s", D.teamName[o.team] or "?",
      attacker and ((D.teamName[attacker.team] or "?") .. " " .. attacker.key) or "self-destruct/unknown"))
  end
end

function L:snapshot()
  local w = self.game.world
  local g = self.game
  self:raw(string.format("--- %s ---", mmss(w.time)))
  if w.squads and w.capPoints then
    local SQ = require("src.squads")
    local parts = {}
    for a, tk in pairs(w.squads.tickets) do parts[#parts + 1] = string.format("side %d: %d tickets, %d points", a, math.floor(tk), SQ.held(w, a)) end
    table.sort(parts)
    self:raw("  " .. table.concat(parts, " | "))
  end
  if w.craft then
    local C = require("src.craft")
    if g.stats then self:raw(string.format("  actions/min %d", g.stats.actions or 0)); g.stats.actions = 0 end
    for t = 1, w.np do
      local tm = w.teams[t]
      if not tm.dead then
        local kinds, onG, onW, army = {}, 0, 0, 0
        for _, e in ipairs(w.entities) do
          if e.alive and e.team == t then
            kinds[e.key] = (kinds[e.key] or 0) + 1
            local o = e.orders and e.orders[1]
            if (o and o.type == "harvest" and o.kind == "gold") or e.inMine then onG = onG + 1
            elseif o and o.type == "harvest" then onW = onW + 1 end
            if not e.def.building and not e.def.worker and e.key ~= "commander" and e.def.cost and e.def.cost.food then army = army + e.def.cost.food end
          end
        end
        local ks = {}
        for k, n in pairs(kinds) do if k ~= "commander" then ks[#ks + 1] = k .. " " .. n end end
        table.sort(ks)
        local _, upk = C.upkeep(tm)
        local r = C.raceOf(w, t)
        self:raw(string.format("  %-7s %s %s | gold %d (+%d/min) wood %d (+%d/min) | food %d/%d %s | workers gold %d wood %d | army food %d | K %d L %d",
          D.teamName[t] or "?", tm.race, r.tierNames[tm.tier or 1], tm.gold, tm.goldRate or 0, tm.wood, tm.woodRate or 0,
          tm.foodUsed or 0, tm.foodCap or 0, upk, onG, onW, army, self.kills[t] or 0, self.losses[t] or 0))
        for _, h in ipairs(C.heroesOf(w, t, true)) do
          local sk, ups = {}, {}
          for i = 1, 4 do if h.skills and h.skills[i] then sk[#sk + 1] = h.skills[i].key end end
          for _, u in ipairs(h.upgrades or {}) do ups[#ups + 1] = u.name end
          self:raw(string.format("          hero %-12s L%d %s | skills %s | %s", h.class or "?", h.clevel or 0,
            h.alive and ("hp " .. math.floor(h.hp) .. "/" .. h.maxhp) or "DEAD", table.concat(sk, ","), table.concat(ups, ", ")))
        end
        local res = {}
        for k in pairs(tm.research or {}) do res[#res + 1] = k end
        table.sort(res)
        self:raw("          " .. table.concat(ks, ", ") .. (#res > 0 and ("  | research: " .. table.concat(res, ",")) or ""))
      end
    end
    self:flush()
    return
  end
  if w.arena then
    local st = w.arena
    local towers, kills = {}, {}
    for sd = 1, st.nSides do towers[sd] = 0; kills[sd] = tostring(st.kills[sd] or 0) end
    for _, s in ipairs(st.structures) do if s.alive and s.key ~= "core" then towers[s.side] = towers[s.side] + 1 end end
    self:raw(string.format("  wave %d   Commander kills by side %s   towers standing by side %s   actions/min %d",
      st.wave, table.concat(kills, "/"), table.concat(towers, "/"), g.stats.actions or 0))
    -- creep levels (side-wide) and denies
    do
      local A = require("src.arena")
      local parts = {}
      for sd = 1, st.nSides do
        local L = st.creepLvl and st.creepLvl[sd] or 0
        local bar = st.creepBar and st.creepBar[sd] or 0
        local pct = L >= A.CREEP_MAX and 100 or math.floor(100 * bar / A.creepNeed(L))
        local d = st.denies and st.denies[sd]
        parts[#parts + 1] = string.format("side %d L%d (%d%%) denies %d", sd, L, pct, d and d.n or 0)
      end
      self:raw("  creeps: " .. table.concat(parts, "   "))
    end
    g.stats.actions = 0
    for t = 1, w.np do
      local c = w.teams[t].commander
      local ups = {}
      for _, u in ipairs(c.upgrades or {}) do ups[#ups + 1] = u.name end
      local sk = {}
      for i = 1, 4 do if c.skills and c.skills[i] then sk[#sk + 1] = c.skills[i].key end end
      self:raw(string.format("  %-7s %-12s L%d %s deaths %d | skills %s | %s", D.teamName[t] or "?", c.class or "?", c.clevel or 0,
        c.alive and ("hp " .. math.floor(c.hp) .. "/" .. c.maxhp) or "DEAD", st.deaths[t] or 0, table.concat(sk, ","), table.concat(ups, ", ")))
    end
    self:flush()
    return
  end
  for t = 1, w.np do
    local tm = w.teams[t]
    if not tm.dead then
      local units, blds, army = 0, 0, 0
      local kinds = {}
      for _, e in ipairs(w.entities) do
        if e.team == t then
          if e.def.building then blds = blds + 1 else units = units + 1 end
          kinds[e.key] = (kinds[e.key] or 0) + 1
          if not e.def.building and e.def.weapon and e.key ~= "commander" and e.def.cost then army = army + e.def.cost.metal end
        end
      end
      local ks = {}
      for k, n in pairs(kinds) do ks[#ks + 1] = k .. " " .. n end
      table.sort(ks)
      local c = tm.commander
      local ups = {}
      for _, u in ipairs((c and c.upgrades) or {}) do ups[#ups + 1] = u.name or u.key end
      local extra = ""
      if t == 1 then extra = string.format("  actions/min %d", g.stats.actions or 0); g.stats.actions = 0 end
      local sc = w.score and w.score[t]
      self:raw(string.format("  %-7s m +%.1f e +%.0f bank %d | units %d blds %d army %d | K %d L %d | pts %d | Cmd L%d hp %d%s%s",
        D.teamName[t] or "?", tm.mIncome or 0, tm.eIncome or 0, tm.metal or 0, units, blds, army,
        self.kills[t] or 0, self.losses[t] or 0, sc and math.floor(sc.pts) or 0,
        c and c.clevel or 0, c and c.alive and math.floor(c.hp) or 0, #ups > 0 and (" [" .. table.concat(ups, ", ") .. "]") or "", extra))
      self:raw("          " .. table.concat(ks, ", "))
    end
  end
  self:flush()
end

function L:update()
  local w = self.game.world
  if w.time >= self.nextSnap then
    self.nextSnap = self.nextSnap + 60
    self:snapshot()
  end
  if #self.lines > 0 and w.time - (self.lastFlush or 0) > 5 then
    self.lastFlush = w.time
    self:flush()
  end
end

function L:finish()
  if self.done then return end
  self.done = true
  local g, w = self.game, self.game.world
  self:snapshot()
  local won = w.over and w.over.winnerAlly == w.ally[1]
  self:raw("")
  self:raw(string.format("RESULT: %s at %s%s", w.over and (won and "VICTORY" or "DEFEAT") or "quit before the end", mmss(w.time),
    w.parTime and (" (par " .. mmss(w.parTime) .. ")") or ""))
  local f = g.finalScore
  if f then
    local sc = w.score[1]
    self:raw(string.format("Score: kills %d + streak bonus %d (best x%.1f, streak %d) + building %d + Commander %d = %d pts",
      sc.killPts, sc.streakPts, sc.bestMult, sc.bestStreak, sc.buildPts, sc.cmdPts, f.pts))
    self:raw(string.format("       x%.2f difficulty x%.2f opposition x%.2f time = %d %s", f.diffMul, f.oppMul, f.timeMul, f.total,
      f.official and "(official)" or "(unofficial)"))
  end
  for t = 1, w.np do
    local tm = w.teams[t]
    self:raw(string.format("  %-7s %s  kills %d losses %d", D.teamName[t] or "?",
      tm.dead and ("eliminated at " .. mmss(tm.deadTime or 0)) or "survived", self.kills[t] or 0, self.losses[t] or 0))
  end
  -- how each side played (the same numbers the tournament harness compares)
  if w.tel then
    local Tel = require("src.telemetry")
    self:raw("")
    self:raw("HOW EACH SIDE PLAYED")
    for t = 1, w.np do self:raw(string.format("  %-7s %s", D.teamName[t] or "?", Tel.describe(Tel.fingerprint(w, t)))) end
    -- who killed what
    local pairs2 = {}
    for _, r in ipairs(w.tel.kills) do
      if r.at and r.at ~= r.vt then
        local k = string.format("%s %s > %s %s", D.teamName[r.at] or "?", r.ak or "?", D.teamName[r.vt] or "?", r.vk or "?")
        pairs2[k] = (pairs2[k] or 0) + 1
      end
    end
    local ks = {}
    for k in pairs(pairs2) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b) return pairs2[a] > pairs2[b] end)
    if #ks > 0 then
      self:raw("KILLS (killer > victim)")
      for i = 1, math.min(14, #ks) do self:raw(string.format("  %3d  %s", pairs2[ks[i]], ks[i])) end
    end
  end
  self:flush()
end

return L
