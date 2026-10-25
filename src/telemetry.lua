-- Telemetry: a structured record of what happened in a match and what the computer decided,
-- for every mode. It feeds the match log (so a game that felt off can be read back) and the
-- tournament harness (tools/tourney.lua), which turns each game into a behaviour fingerprint
-- and measures how much games differ from one another.
--
--   world.tel = Tel.new(world)            (done in Game.new)
--   Tel.note(world, kind, team, text)     a decision or event ("plan", "capture", "break"...)
--   Tel.fingerprint(world, team)          numbers that describe how a side played
local U = require("src.util")
local Tel = {}
Tel.__index = Tel

local GRID = 8            -- presence heat map: GRID x GRID cells over the map
local SAMPLE = 5          -- seconds between presence / grouping samples

function Tel.new(world)
  local self = setmetatable({ world = world, notes = {}, kills = {}, dmg = {}, heat = {}, groups = {},
    firstContact = nil, nextSample = 0, decisions = {}, phase = {} }, Tel)
  for t = 1, world.np do
    self.heat[t] = {}
    for i = 1, GRID * GRID do self.heat[t][i] = 0 end
    self.dmg[t], self.groups[t], self.decisions[t] = {}, {}, {}
    self.phase[t] = { early = { 0, 0, 0 }, mid = { 0, 0, 0 } }
  end
  return self
end

function Tel.note(world, kind, team, text)
  local self = world and world.tel
  if not self then return end
  local n = { t = world.time, kind = kind, team = team, text = text }
  self.notes[#self.notes + 1] = n
  if team and self.decisions[team] then
    local d = self.decisions[team]
    d[kind] = (d[kind] or 0) + 1
  end
  if world.onTelNote then world.onTelNote(n) end
end

-- called from W:damage (actual damage dealt, capped at what the target had)
function Tel:damage(o, amount, attacker)
  if not attacker or not attacker.team or not self.dmg[attacker.team] or not o.team or o.team == attacker.team then return end
  local k = attacker.key or "?"
  local d = self.dmg[attacker.team]
  d[k] = (d[k] or 0) + math.min(amount, o.hp)
  if not self.firstContact and o.team >= 1 and self.world:hostile(o.team, attacker.team) and not o.def.building then
    self.firstContact = self.world.time
  end
end

function Tel:kill(o, attacker)
  if not o.team or o.team < 1 then return end
  self.kills[#self.kills + 1] = { t = self.world.time, vt = o.team, vk = o.key, at = attacker and attacker.team,
    ak = attacker and attacker.key, d = attacker and attacker.x and U.dist(o.x, o.y, attacker.x, attacker.y) or nil }
end

-- every few seconds: where each side's fighting units are, and how many separate groups they form
function Tel:update()
  local w = self.world
  if w.time < self.nextSample then return end
  self.nextSample = w.time + SAMPLE
  local W, H = w.map.w * w.T, w.map.h * w.T
  local byTeam = {}
  for _, e in ipairs(w.entities) do
    if e.alive and e.team and e.team >= 1 and self.heat[e.team] and not e.def.building and e.def.weapon and not e.creep then
      local gx = math.min(GRID - 1, math.floor(e.x / W * GRID))
      local gy = math.min(GRID - 1, math.floor(e.y / H * GRID))
      local i = gy * GRID + gx + 1
      self.heat[e.team][i] = self.heat[e.team][i] + 1
      -- where it was, by phase (first two minutes; two to five)
      local ph = w.time < 120 and "early" or (w.time < 300 and "mid" or nil)
      if ph then
        local a = self.phase[e.team][ph]
        a[1], a[2], a[3] = a[1] + e.x, a[2] + e.y, a[3] + 1
      end
      byTeam[e.team] = byTeam[e.team] or {}
      local l = byTeam[e.team]
      l[#l + 1] = e
    end
  end
  -- army size (metal value of fighting units) at 3 and 6 minutes: how fast a side gets going
  for _, mark in ipairs({ 180, 360 }) do
    if w.time >= mark and not self["army" .. mark] then
      local v = {}
      for _, e in ipairs(w.entities) do
        if e.alive and e.team and e.team >= 1 and not e.def.building and e.def.weapon and e.key ~= "commander" and e.key ~= "builder" then
          local c = e.def.cost
          v[e.team] = (v[e.team] or 0) + (c and (c.metal + c.energy / 10) or 50)
        end
      end
      self["army" .. mark] = v
    end
  end
  -- groups: single-linkage clusters (units within 350 of each other are one group)
  for t, l in pairs(byTeam) do
    local seen, n = {}, 0
    for i = 1, #l do
      if not seen[i] then
        n = n + 1
        local stack = { i }
        seen[i] = true
        while #stack > 0 do
          local a = l[table.remove(stack)]
          for j = 1, #l do
            if not seen[j] and U.dist2(a.x, a.y, l[j].x, l[j].y) < 350 * 350 then seen[j] = true; stack[#stack + 1] = j end
          end
        end
      end
    end
    local g = self.groups[t]
    g[#g + 1] = n
  end
end

local function entropy(cells)
  local tot = 0
  for _, v in ipairs(cells) do tot = tot + v end
  if tot == 0 then return 0 end
  local h = 0
  for _, v in ipairs(cells) do if v > 0 then local p = v / tot; h = h - p * math.log(p) end end
  return h / math.log(#cells)
end

-- the numbers that describe how `team` played this game (all roughly 0..1 or in seconds)
function Tel.fingerprint(world, team)
  local self = world.tel
  if not self then return {} end
  local f = {}
  f.length = world.time
  f.firstContact = self.firstContact or world.time
  -- damage share by unit type
  local tot = 0
  for _, v in pairs(self.dmg[team] or {}) do tot = tot + v end
  f.dmgShare = {}
  for k, v in pairs(self.dmg[team] or {}) do f.dmgShare[k] = tot > 0 and v / tot or 0 end
  -- map coverage: share of cells it was ever seen in, and how spread its presence was
  local cells, used = self.heat[team] or {}, 0
  for _, v in ipairs(cells) do if v > 0 then used = used + 1 end end
  f.coverage = #cells > 0 and used / #cells or 0
  f.spread = entropy(cells)
  -- centre of mass of presence (0..1 in x and y): where on the map it liked to be
  local sx, sy, sn = 0, 0, 0
  for i, v in ipairs(cells) do
    local gx, gy = (i - 1) % GRID, math.floor((i - 1) / GRID)
    sx, sy, sn = sx + (gx + 0.5) / GRID * v, sy + (gy + 0.5) / GRID * v, sn + v
  end
  f.cx, f.cy = sn > 0 and sx / sn or 0.5, sn > 0 and sy / sn or 0.5
  -- groups it fought in (average, and how much that varied)
  local g = self.groups[team] or {}
  local gs, gq = 0, 0
  for _, v in ipairs(g) do gs = gs + v end
  f.groups = #g > 0 and gs / #g or 0
  for _, v in ipairs(g) do gq = gq + (v - f.groups) ^ 2 end
  f.groupsVar = #g > 1 and math.sqrt(gq / (#g - 1)) or 0
  -- engagement range: median distance of its kills
  local ds = {}
  local k, l = 0, 0
  for _, r in ipairs(self.kills) do
    if r.at == team and r.d then ds[#ds + 1] = r.d end
    if r.at == team then k = k + 1 end
    if r.vt == team then l = l + 1 end
  end
  table.sort(ds)
  f.killRange = #ds > 0 and ds[math.ceil(#ds / 2)] or 0
  f.kills, f.losses = k, l
  f.army3 = self.army180 and self.army180[team] or 0
  f.army6 = self.army360 and self.army360[team] or 0
  -- decisions it logged, by kind
  f.decisions = self.decisions[team] or {}
  local nd = 0
  for _, v in pairs(f.decisions) do nd = nd + v end
  f.decisionRate = nd / math.max(60, world.time) * 60
  -- where it went early and mid-game: forward (toward the enemy's start) and sideways, as
  -- fractions of the map diagonal
  local tm = world.teams[team]
  local ex, ey
  for t = 1, world.np do if world:hostile(t, team) then ex, ey = world.teams[t].startX, world.teams[t].startY end end
  local W, H = world.map.w * world.T, world.map.h * world.T
  local diag = math.sqrt(W * W + H * H)
  for _, ph in ipairs({ "early", "mid" }) do
    local a = self.phase[team] and self.phase[team][ph]
    if a and a[3] > 0 and ex and tm.startX then
      local px, py = a[1] / a[3] - tm.startX, a[2] / a[3] - tm.startY
      local fx, fy = U.norm(ex - tm.startX, ey - tm.startY)
      f[ph .. "Fwd"] = (px * fx + py * fy) / diag
      f[ph .. "Side"] = (-px * fy + py * fx) / diag
    else
      f[ph .. "Fwd"], f[ph .. "Side"] = 0, 0
    end
  end
  return f
end

-- one-line summary of a fingerprint for the match log
function Tel.describe(f)
  local parts = {}
  local share = {}
  for k, v in pairs(f.dmgShare or {}) do share[#share + 1] = { k, v } end
  table.sort(share, function(a, b) return a[2] > b[2] end)
  for i = 1, math.min(4, #share) do parts[#parts + 1] = string.format("%s %d%%", share[i][1], math.floor(share[i][2] * 100 + 0.5)) end
  return string.format("first contact %ds, groups %.1f (+/-%.1f), coverage %d%%, kill range %d, damage: %s",
    math.floor(f.firstContact or 0), f.groups or 0, f.groupsVar or 0, math.floor((f.coverage or 0) * 100 + 0.5),
    math.floor(f.killRange or 0), #parts > 0 and table.concat(parts, ", ") or "none")
end

return Tel
