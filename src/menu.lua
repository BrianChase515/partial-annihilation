-- Title screen: map options, up to 4 player slots with teams, saved maps.
local UI = require("src.ui")
local R = require("src.render")
local D = require("src.defs")
local Maps = require("src.maps")

local Menu = {}
Menu.__index = Menu

local SIZES = { { "Small", 72 }, { "Medium", 96 }, { "Large", 128 } }
local WATER = { { "Dry", 0.15 }, { "Some", 0.30 }, { "Lots", 0.45 } }
local LEVEL_NAMES = { "very easy", "easy", "easy+", "relaxed", "normal", "tough", "hard", "very hard", "brutal", "insane" }

function Menu.new(prev)
  local self = setmetatable({}, Menu)
  self.size = prev and prev.sizeI or 2
  self.water = prev and prev.waterI or 2
  self.slots = prev and prev.slots or {
    { on = true, human = true, team = 1 },
    { on = true, team = 2, level = 5, prof = 1 },
    { on = false, team = 3, level = 5, prof = 1 },
    { on = false, team = 4, level = 5, prof = 1 },
  }
  self.savedMap = prev and prev.savedMap or nil
  self.maps = Maps.load()
  self.t = 0
  self.shapes = {}
  local rng = love.math.newRandomGenerator(os.time())
  for i = 1, 40 do
    self.shapes[i] = {
      x = rng:random() * 1600, y = rng:random() * 1000, vx = 20 + rng:random() * 40, vy = (rng:random() - 0.5) * 10,
      kind = rng:random(3), team = rng:random(4), s = 8 + rng:random() * 10,
    }
  end
  return self
end

function Menu:layout()
  local w, h = love.graphics.getDimensions()
  local x0 = math.max(150, w / 2 - 470)
  local y = h / 2 - 150
  return x0, y, w, h
end

function Menu:rects()
  local x0, y, w, h = self:layout()
  local r = {}
  for i, o in ipairs(SIZES) do
    r[#r + 1] = { x = x0 + (i - 1) * 118, y = y, w = 110, h = 34, label = o[1], field = "size", value = i, rowLabel = i == 1 and "Map size" or nil }
  end
  for i, o in ipairs(WATER) do
    r[#r + 1] = { x = x0 + (i - 1) * 118, y = y + 44, w = 110, h = 34, label = o[1], field = "water", value = i, rowLabel = i == 1 and "Water" or nil }
  end
  -- player slots
  local ty = y + 112
  for i, s in ipairs(self.slots) do
    local yy = ty + (i - 1) * 46
    local name = i == 1 and "You" or ("CPU " .. (i - 1))
    r[#r + 1] = { x = x0 - 130, y = yy, w = 118, h = 36, label = name, slot = i, kind = "chip" }
    if i > 2 then
      r[#r + 1] = { x = x0, y = yy, w = 70, h = 36, label = s.on and "On" or "Off", slot = i, kind = "toggle", active = s.on }
    end
    if s.on then
      r[#r + 1] = { x = x0 + 78, y = yy, w = 90, h = 36, label = "Team " .. s.team, slot = i, kind = "team" }
      if not s.human then
        r[#r + 1] = { x = x0 + 176, y = yy, w = 32, h = 36, label = "-", slot = i, kind = "lvdown" }
        r[#r + 1] = { x = x0 + 212, y = yy, w = 132, h = 36, label = s.level .. "  " .. LEVEL_NAMES[s.level], slot = i, kind = "lvlabel" }
        r[#r + 1] = { x = x0 + 348, y = yy, w = 32, h = 36, label = "+", slot = i, kind = "lvup" }
        r[#r + 1] = { x = x0 + 388, y = yy, w = 132, h = 36, label = D.profiles[s.prof].key, slot = i, kind = "prof" }
      end
    end
  end
  local by = ty + 4 * 46 + 40
  r[#r + 1] = { x = x0, y = by, w = 520, h = 54, label = "START", action = "start" }
  r[#r + 1] = { x = x0, y = by + 64, w = 256, h = 36, label = "Controls", action = "help" }
  r[#r + 1] = { x = x0 + 264, y = by + 64, w = 256, h = 36, label = "Quit", action = "quit" }
  -- saved maps panel
  local px = x0 + 580
  r[#r + 1] = { x = px, y = y, w = 300, h = 34, label = "Random new map", action = "random", active = not self.savedMap }
  for i, m in ipairs(self.maps) do
    if i > 9 then break end
    local yy = y + 44 + (i - 1) * 40
    r[#r + 1] = { x = px, y = yy, w = 262, h = 34, label = m.name, map = m, active = self.savedMap and self.savedMap.name == m.name }
    r[#r + 1] = { x = px + 268, y = yy, w = 32, h = 34, label = "x", delmap = m }
  end
  return r
end

function Menu:activeCount()
  local n = 0
  for _, s in ipairs(self.slots) do if s.on then n = n + 1 end end
  return n
end

function Menu:validTeams()
  if self.savedMap and self.savedMap.np <= 2 and self:activeCount() > 2 then return false end
  local teams, n = {}, 0
  for _, s in ipairs(self.slots) do
    if s.on and not teams[s.team] then teams[s.team] = true; n = n + 1 end
  end
  return n >= 2
end

function Menu:update(dt)
  self.t = self.t + dt
  local w = love.graphics.getWidth()
  for _, s in ipairs(self.shapes) do
    s.x = s.x + s.vx * dt * (s.team % 2 == 1 and 1 or -1)
    s.y = s.y + s.vy * dt
    if s.x > w + 30 then s.x = -30 end
    if s.x < -30 then s.x = w + 30 end
  end
end

function Menu:draw()
  local lg = love.graphics
  local x0, y, w, h = self:layout()
  lg.clear(0.05, 0.07, 0.1)
  for _, s in ipairs(self.shapes) do
    local c = D.teamColor[s.team]
    lg.setColor(c[1], c[2], c[3], 0.22)
    if s.kind == 1 then lg.rectangle("fill", s.x - s.s, s.y - s.s, s.s * 2, s.s * 2, 3)
    elseif s.kind == 2 then lg.circle("fill", s.x, s.y, s.s)
    else
      local a = s.team % 2 == 1 and 0 or math.pi
      lg.polygon("fill", s.x + math.cos(a) * s.s * 1.4, s.y + math.sin(a) * s.s * 1.4,
        s.x + math.cos(a + 2.5) * s.s, s.y + math.sin(a + 2.5) * s.s,
        s.x + math.cos(a - 2.5) * s.s, s.y + math.sin(a - 2.5) * s.s)
    end
  end
  local title = "PARTIAL ANNIHILATION"
  local f = R.font(56)
  lg.setFont(f)
  lg.setColor(0, 0, 0, 0.5)
  lg.print(title, w / 2 - f:getWidth(title) / 2 + 4, y - 150 + 4)
  lg.setColor(0.95, 0.97, 1)
  lg.print(title, w / 2 - f:getWidth(title) / 2, y - 150)
  lg.setFont(R.font(18))
  lg.setColor(0.6, 0.7, 0.8)
  local sub = "A small real-time strategy game of land, sea and air. Shapes included."
  lg.print(sub, w / 2 - R.font(18):getWidth(sub) / 2, y - 78)

  -- column headers for player slots
  lg.setFont(R.font(13))
  lg.setColor(0.55, 0.62, 0.7)
  local ty = y + 112
  lg.print("Players", x0 - 130, ty - 22)
  lg.print("Team", x0 + 78, ty - 22)
  lg.print("Difficulty (1-10)", x0 + 176, ty - 22)
  lg.print("Personality (click to cycle)", x0 + 388, ty - 22)
  lg.print("SAVED MAPS", x0 + 580, y - 22)

  local mx, my = love.mouse.getPosition()
  local hoverProf
  for _, r in ipairs(self:rects()) do
    if r.rowLabel then
      lg.setFont(R.font(16))
      lg.setColor(0.75, 0.8, 0.88)
      lg.print(r.rowLabel, r.x - 130, r.y + 7)
    end
    local hover = mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h
    local active = (r.field == "size" and self.size == r.value) or (r.field == "water" and self.water == r.value) or r.active
    if r.kind == "prof" and hover then hoverProf = self.slots[r.slot] end
    if r.kind == "chip" then
      local c = D.teamColor[r.slot]
      local on = self.slots[r.slot].on
      lg.setColor(c[1] * 0.35, c[2] * 0.35, c[3] * 0.35, on and 1 or 0.4)
      lg.rectangle("fill", r.x, r.y, r.w, r.h, 6)
      lg.setColor(c[1], c[2], c[3], on and 1 or 0.4)
      lg.rectangle("fill", r.x + 8, r.y + 10, 16, 16, 3)
      lg.setFont(R.font(16))
      lg.setColor(1, 1, 1, on and 1 or 0.45)
      lg.print(r.label, r.x + 32, r.y + 8)
    else
      if r.action == "start" then
        if self:validTeams() then
          lg.setColor(hover and 0.2 or 0.15, hover and 0.55 or 0.45, hover and 0.3 or 0.25)
        else
          lg.setColor(0.25, 0.25, 0.27)
        end
      elseif r.kind == "lvlabel" then
        lg.setColor(0.1, 0.13, 0.17)
      elseif active then
        lg.setColor(0.2, 0.42, 0.62)
      else
        lg.setColor(hover and 0.2 or 0.13, hover and 0.26 or 0.17, hover and 0.34 or 0.23)
      end
      lg.rectangle("fill", r.x, r.y, r.w, r.h, 6)
      lg.setColor(0.4, 0.55, 0.7, 0.8)
      lg.rectangle("line", r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1, 6)
      local fs = r.action == "start" and 24 or 15
      lg.setFont(R.font(fs))
      lg.setColor(1, 1, 1)
      local label = r.label
      if r.action == "start" and not self:validTeams() then
        label = (self.savedMap and self.savedMap.np <= 2 and self:activeCount() > 2) and "That saved map is 2-player only" or "Put someone on another team"
      end
      lg.print(label, r.x + r.w / 2 - R.font(fs):getWidth(label) / 2, r.y + r.h / 2 - fs * 0.62)
    end
  end
  -- personality description
  lg.setFont(R.font(14))
  lg.setColor(0.65, 0.72, 0.8)
  local desc
  if hoverProf then desc = D.profiles[hoverProf.prof].key .. ": " .. D.profiles[hoverProf.prof].desc
  else desc = "Same team number = allies. Hover a personality to see what it does." end
  lg.print(desc, x0, ty + 4 * 46 + 8)
  if self.savedMap then
    lg.setColor(0.6, 0.85, 0.65)
    lg.print("Playing saved map: " .. self.savedMap.name .. "  (seed " .. self.savedMap.seed .. ")", x0 + 580, y + 44 + math.min(9, #self.maps) * 40 + 8)
  elseif #self.maps == 0 then
    lg.setColor(0.5, 0.56, 0.64)
    lg.printf("No saved maps yet. In a game, open the menu (Esc) and choose \"Save this map\" to keep one you like.", x0 + 580, y + 48, 300)
  end
  lg.setFont(R.font(13))
  lg.setColor(0.5, 0.56, 0.64)
  local tip = "Tip: build Metal Extractors on the yellow deposits and Solar Collectors for energy, then a Vehicle Plant. Kill enemy Commanders to win."
  lg.print(tip, w / 2 - R.font(13):getWidth(tip) / 2, h - 40)
  if self.showHelp then UI.drawHelp() end
end

function Menu:mousepressed(x, y, b)
  if self.showHelp then self.showHelp = false; return end
  for _, r in ipairs(self:rects()) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      local s = r.slot and self.slots[r.slot]
      local dir = (b == 2) and -1 or 1
      if r.field then self[r.field] = r.value; self.savedMap = nil
      elseif r.kind == "toggle" then
        s.on = not s.on
        -- keep slots contiguous so colors stay put
        if s.on then for i = 2, r.slot do self.slots[i].on = true end
        else for i = r.slot, 4 do self.slots[i].on = false end end
      elseif r.kind == "team" then s.team = (s.team - 1 + dir) % 4 + 1
      elseif r.kind == "lvdown" then s.level = math.max(1, s.level - 1)
      elseif r.kind == "lvup" then s.level = math.min(10, s.level + 1)
      elseif r.kind == "lvlabel" then s.level = (s.level - 1 + dir) % 10 + 1
      elseif r.kind == "prof" then s.prof = (s.prof - 1 + dir) % #D.profiles + 1
      elseif r.map and b == 1 then
        self.savedMap = r.map
        for i, sz in ipairs(SIZES) do if sz[2] == r.map.size then self.size = i end end
      elseif r.delmap and b == 1 then
        Maps.remove(r.delmap.name)
        if self.savedMap and self.savedMap.name == r.delmap.name then self.savedMap = nil end
        self.maps = Maps.load()
      elseif r.action == "random" then self.savedMap = nil
      elseif r.action == "start" and b == 1 then
        if self:validTeams() then return "start" end
      elseif r.action == "help" then self.showHelp = true
      elseif r.action == "quit" then love.event.quit() end
      return
    end
  end
end

function Menu:keypressed(k)
  if (k == "return" or k == "space") and self:validTeams() then return "start" end
  if k == "escape" then
    if self.showHelp then self.showHelp = false else love.event.quit() end
  end
  if k == "f1" then self.showHelp = not self.showHelp end
end

function Menu:options()
  local players = {}
  for _, s in ipairs(self.slots) do
    if s.on then
      players[#players + 1] = { human = s.human, ally = s.team, level = s.level, profile = (not s.human) and D.profiles[s.prof].key or nil }
    end
  end
  local o = {
    size = SIZES[self.size][2], water = WATER[self.water][2], players = players,
    sizeI = self.size, waterI = self.water, slots = self.slots, savedMap = self.savedMap,
  }
  if self.savedMap then
    o.seed = self.savedMap.seed
    o.size = self.savedMap.size
    o.water = self.savedMap.water
    o.mapPlayers = self.savedMap.np
  end
  return o
end

return Menu
