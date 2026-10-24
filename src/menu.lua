-- Title screen: map options, up to 4 player slots with teams, saved maps.
local UI = require("src.ui")
local R = require("src.render")
local D = require("src.defs")
local Maps = require("src.maps")
local U_fmt = require("src.util").fmt

local Menu = {}
Menu.__index = Menu
local ARENA = require("src.arena")
-- per-mode color themes: RTS steel blue, Arena crimson and violet
local THEMES = {
  rts = { bg = { 0.05, 0.07, 0.1 }, title = { 0.95, 0.97, 1 }, sub = { 0.6, 0.7, 0.8 }, field = { 0.1, 0.13, 0.17 },
    active = { 0.2, 0.42, 0.62 }, btn = { 0.13, 0.17, 0.23 }, hover = { 0.2, 0.26, 0.34 }, line = { 0.4, 0.55, 0.7 } },
  arena = { bg = { 0.08, 0.04, 0.08 }, title = { 1, 0.86, 0.6 }, sub = { 0.85, 0.62, 0.72 }, field = { 0.16, 0.08, 0.14 },
    active = { 0.62, 0.2, 0.38 }, btn = { 0.2, 0.1, 0.18 }, hover = { 0.32, 0.15, 0.27 }, line = { 0.8, 0.45, 0.62 } },
  craft = { bg = { 0.05, 0.07, 0.04 }, title = { 1, 0.85, 0.45 }, sub = { 0.75, 0.82, 0.6 }, field = { 0.1, 0.13, 0.08 },
    active = { 0.45, 0.36, 0.12 }, btn = { 0.13, 0.16, 0.1 }, hover = { 0.22, 0.26, 0.16 }, line = { 0.75, 0.65, 0.35 } },
}
local ATEMPLATES = {
  { "classic", "Classic", "Classic: three lanes, two towers each. The standard match." },
  { "longroad", "Long Road", "Long Road: winding lanes and three towers per lane. Longer, more strategic games (par +3 min)." },
  { "gauntlet", "Gauntlet", "Gauntlet: one wide lane, three towers deep. A brutal brawl down the middle (par 10 min). Free-for-all keeps its lanes." },
  { "open", "Open Field", "Open Field: three lanes with almost no rock between them, so roaming and ganks rule." },
  { "treeline", "Treeline", "Treeline: two lanes with a jungle between them - neutral camps for XP, two capture shrines (+8% speed and damage each) and the Colossus in the middle. Built for 3v3. Randomized every match." },
  { "battlefield", "Battlefield", "Battlefield (DOTA style): three lanes, a river, jungle camps in every quarter, two shrines and a Colossus that alternates between two pits. Randomized every match." },
}
local ASIZES = { { "Small", 64 }, { "Medium", 80 }, { "Large", 96 }, { "Huge", 112 } }
-- which formats each map is built for; the size follows from map and format. "Experimental" on
-- the title screen unlocks any mix (and makes the game unofficial)
local AMAP_FORMATS = {
  classic = { "1v1", "1v2", "2v1", "2v2", "FFA 3", "FFA 4" },
  longroad = { "1v1", "2v2", "3v3" },
  gauntlet = { "1v1", "1v2", "2v1", "2v2" },
  open = { "1v1", "2v2", "3v3", "FFA 4" },
  treeline = { "2v2", "3v3" },
  battlefield = { "3v3", "5v5" },
}
local function aformatOK(tmpl, fname)
  for _, f in ipairs(AMAP_FORMATS[tmpl] or {}) do if f == fname then return true end end
  return false
end
local function aautoSize(tmpl, fmt)
  local n = fmt.ffa or (fmt[2] + fmt[3])
  if n >= 10 then return 4 end
  if tmpl == "treeline" or tmpl == "battlefield" then return n >= 6 and 3 or 3 end
  if n <= 2 then return 2 end
  return 3
end
local AFORMATS = { { "1v1", 1, 1 }, { "1v2", 1, 2 }, { "2v2", 2, 2 }, { "2v1", 2, 1 }, { "3v3", 3, 3 }, { "5v5", 5, 5 }, { "FFA 3", 1, 0, ffa = 3 }, { "FFA 4", 1, 0, ffa = 4 } }
-- arena slots: 1 you, 2 ally, 3 enemy, 4 enemy 2, 5 ally 2, 6 enemy 3
local ASLOT_NAMES = { "You", "Ally", "Enemy", "Enemy 2", "Ally 2", "Enemy 3", "Ally 3", "Enemy 4", "Ally 4", "Enemy 5" }

local SIZES = { { "Small", 96 }, { "Medium", 128 }, { "Large", 160 } }
-- Annihilation game types, and the Sandbox armies (kept for the whole session)
local GAMETYPES = { { "standard", "Standard" }, { "sandbox", "Sandbox" } }
local SANDBOX_UNITS = { "scout", "tank", "artillery", "flak", "fighter", "bomber", "gunship", "boat", "destroyer", "sub", "battleship", "walker" }
local RTS_SETUP = { game = "standard",
  sandbox = { you = { tank = 20, artillery = 6, flak = 4 }, enemy = { tank = 20, artillery = 6, gunship = 4 } } }
-- Commander of Heroes: map, format, difficulty and the squads you field
local COH_FORMATS = { { "1v1", 1, 1 }, { "2v2", 2, 2 } }
local COH_SETUP = { v = 2, enemy = "own", size = 1, format = 1, level = 5, squadTab = 1, squads = require("src.squads").defaults() }
local WATER = { { "Dry", 0.15 }, { "Some", 0.30 }, { "Lots", 0.45 } }
local RANDOM_PROF = #D.profiles   -- "Random" is the last personality
local LEVEL_NAMES = { "very easy", "easy", "easy+", "relaxed", "normal", "tough", "hard", "very hard", "brutal", "insane" }

-- menu memory: every choice on all three tabs is saved when a game starts and restored on the
-- next visit to the title screen (and the next launch)
local MEMFILE = "menu_setup.lua"
local function ser(v)
  local t = type(v)
  if t == "number" then return string.format("%.6g", v)
  elseif t == "string" then return string.format("%q", v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "table" then
    local out = {}
    for k, x in pairs(v) do
      if type(x) ~= "function" then
        local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
        out[#out + 1] = key .. "=" .. ser(x)
      end
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "nil"
end
local function loadMemory()
  local ok, chunk = pcall(love.filesystem.load, MEMFILE)
  if not ok or not chunk then return nil end
  local ok2, t = pcall(chunk)
  return ok2 and type(t) == "table" and t or nil
end
function Menu:remember()
  local mem = { mode = self.mode, sizeI = self.size, waterI = self.water, slots = self.slots, mods = self.mods,
    arenaSetup = self.arena, craftSetup = self.craft, rts = RTS_SETUP, coh = COH_SETUP }
  pcall(love.filesystem.write, MEMFILE, "return " .. ser(mem))
end

function Menu.new(prev)
  local self = setmetatable({}, Menu)
  -- what was set up last time wins over the defaults (the finished game's own options otherwise)
  local mem = loadMemory()
  if mem then
    prev = { sizeI = mem.sizeI, waterI = mem.waterI, slots = mem.slots, menuMode = mem.mode, arenaSetup = mem.arenaSetup,
      craftSetup = mem.craftSetup, mods = mem.mods, savedMap = prev and prev.savedMap }
    if mem.rts then
      RTS_SETUP.game = mem.rts.game or RTS_SETUP.game
      local known = false
      for _, g in ipairs(GAMETYPES) do if g[1] == RTS_SETUP.game then known = true end end
      if not known then RTS_SETUP.game = "standard" end
      if mem.rts.sandbox then RTS_SETUP.sandbox = mem.rts.sandbox end
    end
    if mem.coh then
      local SQ = require("src.squads")
      COH_SETUP.size = mem.coh.size or COH_SETUP.size
      COH_SETUP.format = COH_FORMATS[mem.coh.format or 0] and mem.coh.format or 1
      COH_SETUP.level = mem.coh.level or COH_SETUP.level
      COH_SETUP.enemy = mem.coh.enemy or COH_SETUP.enemy
      -- (setups saved before v2 had the anti-air squad off: start those from the new defaults)
      if mem.coh.v == 2 and mem.coh.squads and #mem.coh.squads == require("src.squads").SLOTS then
        COH_SETUP.squads = mem.coh.squads
        for _, ds in ipairs(COH_SETUP.squads) do SQ.fixDesign(ds) end
      end
    end
  end
  self.size = prev and prev.sizeI or 2
  self.water = prev and prev.waterI or 2
  self.slots = prev and prev.slots or {
    { on = true, human = true, team = 1 },
    { on = true, team = 2, level = 5, prof = RANDOM_PROF },
    { on = false, team = 3, level = 5, prof = RANDOM_PROF },
    { on = false, team = 4, level = 5, prof = RANDOM_PROF },
  }
  for _, sl in ipairs(self.slots) do
    if sl.prof and not D.profiles[sl.prof] then sl.prof = RANDOM_PROF end -- (e.g. Mirror, before it unlocks again)
  end
  self.savedMap = prev and prev.savedMap or nil
  self.mode = prev and prev.menuMode or "rts"
  self.arena = prev and prev.arenaSetup or {
    size = 2, format = 1,
    slots = { { human = true, class = 0 }, { class = 0, level = 5 }, { class = 0, level = 5 }, { class = 0, level = 5 } },
  }
  for i = #self.arena.slots + 1, 10 do self.arena.slots[i] = { class = 0, level = 5 } end
  self.craft = prev and prev.craftSetup or { race = 0, hero = 0, enemy = 0, level = 5, map = 1 }
  self.craft.map = self.craft.map or 1
  self.mods = prev and prev.mods or { alien = false, drops = false, score = false, groovy = false }
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

function Menu:tabRects(r)
  local x0, y, w, h = self:layout()
  r[#r + 1] = { x = w - 132, y = h - 40, w = 118, h = 30, label = "Settings", action = "settings", small = true }
  local ty = math.max(14, y - 240)
  local tabs = { { "ANNIHILATION", "rts" }, { "COMMANDER ARENA", "arena" }, { "COMMANDER CRAFT", "craft" }, { "COMMANDER OF HEROES", "coh" } }
  local tw, gap = 238, 8
  local tx = w / 2 - (#tabs * tw + (#tabs - 1) * gap) / 2
  for i, tb in ipairs(tabs) do
    r[#r + 1] = { x = tx + (i - 1) * (tw + gap), y = ty, w = tw, h = 50, label = tb[1], tab = tb[2], big = true, active = self.mode == tb[2] }
  end
end

-- which arena slots are in play for the chosen format: you, ally, enemy 1, enemy 2
function Menu:arenaActive()
  local f = AFORMATS[self.arena.format]
  if f.ffa then return { true, f.ffa >= 4, true, true, false, false, false, false, false, false } end
  return { true, f[2] >= 2, true, f[3] >= 2, f[2] >= 3, f[3] >= 3, f[2] >= 4, f[3] >= 4, f[2] >= 5, f[3] >= 5 }
end

-- the order players are created in (it decides their colors): you, enemy, ally, enemy 2, ally 2, enemy 3
function Menu:arenaOrder()
  local act = self:arenaActive()
  local out = {}
  for _, i in ipairs({ 1, 3, 2, 4, 5, 6, 7, 8, 9, 10 }) do if act[i] then out[#out + 1] = i end end
  return out
end

function Menu:className(k)
  if k == 0 then return "Random" end
  return ARENA.CLASSES[k].name
end

function Menu:arenaRects()
  local x0, y, w, h = self:layout()
  local r = {}
  self:tabRects(r)
  local A = self.arena
  local tkey = ATEMPLATES[A.template or 1][1]
  -- 1. the map; 2. the formats it was built for; 3. size (automatic unless Experimental)
  for i, o in ipairs(ATEMPLATES) do
    -- two groups: simple lane maps, then the jungle maps (camps, shrines, the Colossus)
    r[#r + 1] = { x = x0 + (i - 1) * 92 + (i >= 5 and 18 or 0), y = y, w = 88, h = 34, jungle = i >= 5, label = o[2], afield = "template", value = i,
      active = (A.template or 1) == i, rowLabel = i == 1 and "Map" or nil, tmpl = i }
  end
  local fx = 0
  for i, o in ipairs(AFORMATS) do
    if A.experimental or aformatOK(tkey, o[1]) then
      r[#r + 1] = { x = x0 + fx * 70, y = y + 44, w = 66, h = 34, label = o[1], afield = "format", value = i, active = A.format == i,
        rowLabel = fx == 0 and "Format" or nil }
      fx = fx + 1
    end
  end
  if A.experimental then
    for i, o in ipairs(ASIZES) do
      r[#r + 1] = { x = x0 + (i - 1) * 92, y = y + 88, w = 88, h = 34, label = o[1], afield = "size", value = i, active = A.size == i, rowLabel = i == 1 and "Arena size" or nil }
    end
  else
    local si = aautoSize(tkey, AFORMATS[A.format])
    r[#r + 1] = { x = x0, y = y + 88, w = 200, h = 34, label = "Size: " .. ASIZES[si][1] .. " (automatic)", kind = "info", rowLabel = "Arena size", small = true }
  end
  r[#r + 1] = { x = x0 + 376, y = y + 88, w = 144, h = 34, label = A.experimental and "Experimental: ON" or "Experimental", kind = "aexp",
    active = A.experimental, small = true }
  local ty = y + 160
  local ffa = AFORMATS[A.format].ffa
  local names = ffa and { "You", "Rival 3", "Rival 1", "Rival 2" } or ASLOT_NAMES
  local colorSlot = {}
  for k, i in ipairs(self:arenaOrder()) do colorSlot[i] = k end
  local act = self:arenaActive()
  local nAct = 0
  for i = 1, 10 do if act[i] then nAct = nAct + 1 end end
  local rowH = nAct > 4 and 38 or 46
  local row = 0
  local compact = nAct > 6
  -- 5v5: allies in a left column, enemies on the right, all narrower
  if compact then
    local sideRow = { 0, 0 }
    for _, i in ipairs({ 1, 2, 5, 7, 9, 3, 4, 6, 8, 10 }) do
      if act[i] then
        local col = (i == 1 or i == 2 or i == 5 or i == 7 or i == 9) and 0 or 1
        local yy = ty + sideRow[col + 1] * rowH
        sideRow[col + 1] = sideRow[col + 1] + 1
        local xx = x0 - 130 + col * 352
        local sl = A.slots[i]
        r[#r + 1] = { x = xx, y = yy, w = 72, h = rowH - 4, label = names[i], slot = colorSlot[i], kind = "chip", on = true, small = true }
        r[#r + 1] = { x = xx + 76, y = yy, w = 120, h = rowH - 4, label = self:className(sl.class), aslot = i, kind = "aclass" }
        if not sl.human then
          r[#r + 1] = { x = xx + 200, y = yy, w = 26, h = rowH - 4, label = "-", aslot = i, kind = "alvdown" }
          r[#r + 1] = { x = xx + 228, y = yy, w = 64, h = rowH - 4, label = tostring(sl.level), aslot = i, kind = "lvlabel", alevel = true }
          r[#r + 1] = { x = xx + 294, y = yy, w = 26, h = rowH - 4, label = "+", aslot = i, kind = "alvup" }
        end
      end
    end
    row = math.max(sideRow[1], sideRow[2])
  end
  for _, i in ipairs(compact and {} or ffa and { 1, 3, 4, 2 } or { 1, 2, 5, 3, 4, 6 }) do
    if act[i] then
      local yy = ty + row * rowH
      row = row + 1
      local sl = A.slots[i]
      r[#r + 1] = { x = x0 - 130, y = yy, w = 118, h = rowH - 4, label = names[i], slot = colorSlot[i], kind = "chip", on = true }
      r[#r + 1] = { x = x0, y = yy, w = 168, h = rowH - 4, label = self:className(sl.class), aslot = i, kind = "aclass" }
      if not sl.human then
        r[#r + 1] = { x = x0 + 176, y = yy, w = 32, h = rowH - 4, label = "-", aslot = i, kind = "alvdown" }
        r[#r + 1] = { x = x0 + 212, y = yy, w = 132, h = rowH - 4, label = sl.level .. "  " .. LEVEL_NAMES[sl.level], aslot = i, kind = "lvlabel", alevel = true }
        r[#r + 1] = { x = x0 + 348, y = yy, w = 32, h = rowH - 4, label = "+", aslot = i, kind = "alvup" }
      end
    end
  end
  local by = ty + math.max(4 * 46, (compact and row or nAct) * rowH) + 54
  self.arenaStartY = by
  r[#r + 1] = { x = x0, y = by, w = 520, h = 54, label = "START", action = "start" }
  r[#r + 1] = { x = x0, y = by + 64, w = 256, h = 36, label = "Controls", action = "help" }
  r[#r + 1] = { x = x0 + 264, y = by + 64, w = 256, h = 36, label = "Quit", action = "quit" }
  -- class roster (hover for details)
  for i, c in ipairs(ARENA.CLASSES) do
    local half = math.ceil(#ARENA.CLASSES / 2)
    local col, row = (i - 1) >= half and 1 or 0, (i - 1) % half
    r[#r + 1] = { x = x0 + 580 + col * 152, y = y + row * 34, w = 148, h = 30, label = c.name, roster = i, kind = "roster",
      active = A.slots[1].class == i }
  end
  self:updateRect(r, w)
  return r
end

function Menu:updateRect(r, w)
  local ON = require("src.online")
  if ON.state == "available" or ON.state == "downloading" or ON.state == "updated" or ON.state == "failed" then
    local label = ({ available = "Update to v" .. tostring(ON.latest), downloading = "Downloading...",
      updated = "Restart to finish update", failed = "Update failed - retry" })[ON.state]
    r[#r + 1] = { x = w - 300, y = 16, w = 284, h = 40, label = label, action = "update", active = ON.state ~= "failed" }
  end
end

-- Commander Craft setup: your race and hero, the enemy's race and strength
function Menu:craftRects()
  local x0, y, w, h = self:layout()
  local r = {}
  self:tabRects(r)
  local CS = self.craft
  local races = D.CRAFT.races
  for i, rc in ipairs(races) do
    r[#r + 1] = { x = x0 + (i - 1) * 132, y = y, w = 126, h = 34, label = rc.name, cfield = "race", value = i, active = CS.race == i, rowLabel = i == 1 and "Your race" or nil, craceHover = i }
  end
  r[#r + 1] = { x = x0 + #races * 132, y = y, w = 126, h = 34, label = "Random", cfield = "race", value = 0, active = CS.race == 0, rowLabel = nil }
  -- heroes of your race (or every class when your race is random)
  local list = {}
  if CS.race > 0 then list = races[CS.race].heroes end
  for i, ck in ipairs(list) do
    r[#r + 1] = { x = x0 + (i - 1) * 100, y = y + 46, w = 96, h = 34, label = ARENA.byClass[ck].name, cfield = "hero", value = i,
      active = CS.hero == i, rowLabel = i == 1 and "Your hero" or nil, heroKey = ck, small = true }
  end
  r[#r + 1] = { x = x0 + #list * 100, y = y + 46, w = 96, h = 34, label = "Random", cfield = "hero", value = 0, active = CS.hero == 0,
    rowLabel = #list == 0 and "Your hero" or nil, small = true }
  for i, rc in ipairs(races) do
    r[#r + 1] = { x = x0 + (i - 1) * 132, y = y + 92, w = 126, h = 34, label = rc.name, cfield = "enemy", value = i, active = CS.enemy == i, rowLabel = i == 1 and "Enemy race" or nil, craceHover = i }
  end
  r[#r + 1] = { x = x0 + #races * 132, y = y + 92, w = 126, h = 34, label = "Random", cfield = "enemy", value = 0, active = CS.enemy == 0 }
  local CMAPS = require("src.craft_map").TEMPLATES
  -- two rows of four (the last slot is Random)
  for i, t in ipairs(CMAPS) do
    local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
    r[#r + 1] = { x = x0 + col * 130, y = y + 184 + row * 38, w = 126, h = 34, label = t[2], cfield = "map", value = i, active = CS.map == i,
      rowLabel = i == 1 and "Map" or nil, small = true, cmapHover = i }
  end
  do
    local i = #CMAPS + 1
    local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
    r[#r + 1] = { x = x0 + col * 130, y = y + 184 + row * 38, w = 126, h = 34, label = "Random (1v1)", cfield = "map", value = 0, active = CS.map == 0, small = true }
  end
  r[#r + 1] = { x = x0, y = y + 138, w = 32, h = 34, label = "-", kind = "clvdown", rowLabel = "Difficulty" }
  r[#r + 1] = { x = x0 + 36, y = y + 138, w = 160, h = 34, label = CS.level .. "  " .. LEVEL_NAMES[CS.level], kind = "lvlabel", clevel = true }
  r[#r + 1] = { x = x0 + 200, y = y + 138, w = 32, h = 34, label = "+", kind = "clvup" }
  local by = y + 348
  self.craftStartY = by
  r[#r + 1] = { x = x0, y = by, w = 520, h = 54, label = "START", action = "start" }
  r[#r + 1] = { x = x0, y = by + 64, w = 256, h = 36, label = "Controls", action = "help" }
  r[#r + 1] = { x = x0 + 264, y = by + 64, w = 256, h = 36, label = "Quit", action = "quit" }
  self:updateRect(r, w)
  return r
end

function Menu:drawCraftInfo(x0, y, w, h, hoverRace, hoverHero)
  local lg = love.graphics
  local CS = self.craft
  lg.setFont(R.font(12))
  lg.setColor(0.62, 0.68, 0.55)
  local CMAPS = require("src.craft_map").TEMPLATES
  local twoV = CS.map > 0 and CMAPS[CS.map].players == 4
  lg.printf((twoV and "2v2 with a computer ally (your race) against two enemies (the enemy race). " or "1v1. ") ..
    "Mine gold, chop wood, mind your food and upkeep, climb three tiers, and bring heroes.", x0, y + 262, 520)
  lg.setFont(R.font(14))
  lg.setColor(0.75, 0.8, 0.65)
  local desc
  if self.hoverMap then
    desc = require("src.craft_map").TEMPLATES[self.hoverMap][3]
  elseif hoverHero then
    local cls = ARENA.byClass[hoverHero]
    desc = cls.name .. ": " .. cls.tag
  elseif hoverRace then
    local rc = D.CRAFT.races[hoverRace]
    desc = rc.name .. ": " .. rc.tag .. "  Heroes: " .. table.concat((function()
      local t = {}
      for _, k in ipairs(rc.heroes) do t[#t + 1] = ARENA.byClass[k].name end
      return t end)(), ", ") .. "."
  elseif self.hoverLevel then
    local L = self.hoverLevel
    desc = "Difficulty " .. L .. " (" .. LEVEL_NAMES[L] .. "): " .. (L <= 2 and "few workers, forgets chores, attacks with whatever it has." or
      L <= 4 and "a so-so economy, techs late, pokes at you early." or
      L <= 6 and "a full economy, creeps with its hero, attacks when it's ahead, focuses hurt heroes." or
      "tight macro, early tech and expansion, picks its fights" .. (L >= 8 and string.format("; also mines %d%% faster.", (L - 7) * 10) or "."))
  else
    desc = "Destroy every enemy building. Hover a race or hero to read about it."
  end
  lg.printf(desc, x0, y + 296, 520)
  -- right column: the race you picked
  local rc = CS.race > 0 and D.CRAFT.races[CS.race]
  local px = x0 + 580
  lg.setFont(R.font(13))
  lg.setColor(0.6, 0.66, 0.5)
  lg.print(rc and (rc.name:upper() .. "  - units by building") or "RACES", px, y - 22)
  lg.setFont(R.font(12))
  local yy = y
  local function line(t, col)
    lg.setColor(col[1], col[2], col[3])
    lg.printf(t, px, yy, 340)
    local _, ls = R.font(12):getWrap(t, 340)
    yy = yy + #ls * 16 + 3
  end
  if rc then
    local function names(keys)
      local t = {}
      for _, k in ipairs(keys) do local d = D.units[k]; if d and not d.research and not d.heroRecruit then t[#t + 1] = d.name .. (d.tier and d.tier > 1 and (" (T" .. d.tier .. ")") or "") end end
      return table.concat(t, ", ")
    end
    local hall = D.units[rc.hall]
    line(rc.tierNames[1] .. " > " .. rc.tierNames[2] .. " > " .. rc.tierNames[3] .. ": " .. names(hall.builds), { 1, 0.85, 0.45 })
    for _, bk in ipairs(D.units[rc.worker].builds) do
      local d = D.units[bk]
      if d.factory and bk ~= rc.hall and not d.altar then
        local u = names(d.builds)
        local res = {}
        for _, k in ipairs(d.builds) do if D.units[k].research then res[#res + 1] = D.units[k].name end end
        line(d.name .. (d.tier and d.tier > 1 and (" (T" .. d.tier .. ")") or "") .. ": " .. (u ~= "" and u or "") ..
          (#res > 0 and ((u ~= "" and "  |  " or "") .. "researches " .. table.concat(res, ", ")) or ""), { 0.82, 0.86, 0.75 })
      end
    end
  else
    for _, r2 in ipairs(D.CRAFT.races) do line(r2.name .. ": " .. r2.tag, { 0.82, 0.86, 0.75 }) end
  end
  -- high scores
  self.craftScores = self.craftScores or require("src.scores").load("craft")
  local hy = math.max(yy + 14, y + 250)
  lg.setFont(R.font(13))
  lg.setColor(0.6, 0.66, 0.5)
  lg.print("CRAFT HIGH SCORES  season " .. D.SEASON, px, hy)
  lg.setFont(R.font(12))
  if #self.craftScores == 0 then
    lg.setColor(0.45, 0.5, 0.42)
    lg.print("None yet - win a game.", px, hy + 20)
  end
  for i, sc in ipairs(self.craftScores) do
    if i > 5 then break end
    lg.setColor(i == 1 and 1 or 0.85, i == 1 and 0.85 or 0.88, i == 1 and 0.35 or 0.8)
    lg.print(string.format("%d. %s  %s  %s", i, U_fmt(sc.pts), sc.result, sc.date), px, hy + 2 + i * 18)
  end
end

function Menu:rects()
  if self.mode == "arena" then return self:arenaRects() end
  if self.mode == "craft" then return self:craftRects() end
  if self.mode == "coh" then return self:cohRects() end
  local x0, y, w, h = self:layout()
  local r = {}
  self:tabRects(r)
  -- game type, then map size and water on one row
  for i, o in ipairs(GAMETYPES) do
    r[#r + 1] = { x = x0 + (i - 1) * 174, y = y, w = 168, h = 34, label = o[2], gametype = o[1], active = RTS_SETUP.game == o[1],
      rowLabel = i == 1 and "Game" or nil }
  end
  for i, o in ipairs(SIZES) do
    r[#r + 1] = { x = x0 + (i - 1) * 84, y = y + 44, w = 80, h = 34, label = o[1], field = "size", value = i, rowLabel = i == 1 and "Map" or nil, small = true }
  end
  for i, o in ipairs(WATER) do
    r[#r + 1] = { x = x0 + 266 + (i - 1) * 84, y = y + 44, w = 80, h = 34, label = o[1] .. (i == 1 and " land" or (i == 2 and " water" or " water")), field = "water", value = i, small = true }
  end
  -- modifiers (toggles, can combine)
  local MODLIST = { { "alien", "Alien Tech" }, { "drops", "Dropships" }, { "convoy", "Metal Alert" }, { "apoc", "Post-Apoc" }, { "groovy", "Groovy" } }
  for i, m in ipairs(MODLIST) do
    r[#r + 1] = { x = x0 + (i - 1) * 105, y = y + 88, w = 100, h = 34, label = m[2], modkey = m[1],
      active = self.mods[m[1]], rowLabel = i == 1 and "Modifiers" or nil, small = true }
  end
  -- player slots
  local ty = y + 160
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
        local prof = D.profiles[s.prof]
        if prof and prof.ghost then
          -- Mirror and Nemesis pick their own strength
          local L = require("src.ghost").level(prof.key)
          r[#r + 1] = { x = x0 + 176, y = yy, w = 204, h = 36, label = "Auto  (level " .. L .. ")", slot = i, kind = "lvauto" }
        else
          r[#r + 1] = { x = x0 + 176, y = yy, w = 32, h = 36, label = "-", slot = i, kind = "lvdown" }
          r[#r + 1] = { x = x0 + 212, y = yy, w = 132, h = 36, label = s.level .. "  " .. LEVEL_NAMES[s.level], slot = i, kind = "lvlabel" }
          r[#r + 1] = { x = x0 + 348, y = yy, w = 32, h = 36, label = "+", slot = i, kind = "lvup" }
        end
        r[#r + 1] = { x = x0 + 388, y = yy, w = 132, h = 36, label = D.profiles[s.prof].key .. "  v", slot = i, kind = "prof" }
      end
    end
  end
  local by = ty + 4 * 46 + 54
  r[#r + 1] = { x = x0, y = by, w = 520, h = 54, label = "START", action = "start" }
  r[#r + 1] = { x = x0, y = by + 64, w = 256, h = 36, label = "Controls", action = "help" }
  r[#r + 1] = { x = x0 + 264, y = by + 64, w = 256, h = 36, label = "Quit", action = "quit" }
  local px = x0 + 580
  if RTS_SETUP.game == "sandbox" then
    -- the two armies: a count per unit type (click +/-, Shift for 10, right-click lowers)
    for i, k in ipairs(SANDBOX_UNITS) do
      local yy = y + (i - 1) * 30
      for si, side in ipairs({ "you", "enemy" }) do
        local cx = px + 150 + (si - 1) * 120
        r[#r + 1] = { x = cx, y = yy, w = 26, h = 26, label = "-", kind = "sbdown", sbside = side, sbkey = k, small = true }
        r[#r + 1] = { x = cx + 28, y = yy, w = 50, h = 26, label = tostring(RTS_SETUP.sandbox[side][k] or 0), kind = "sbcount", sbside = side, sbkey = k, small = true }
        r[#r + 1] = { x = cx + 80, y = yy, w = 26, h = 26, label = "+", kind = "sbup", sbside = side, sbkey = k, small = true }
      end
    end
    self:updateRect(r, w)
    return r
  end
  -- saved maps panel
  r[#r + 1] = { x = px, y = y, w = 300, h = 34, label = "Random new map", action = "random", active = not self.savedMap }
  for i, m in ipairs(self.maps) do
    if i > 5 then break end
    local yy = y + 44 + (i - 1) * 40
    r[#r + 1] = { x = px, y = yy, w = 262, h = 34, label = m.name, map = m, active = self.savedMap and self.savedMap.name == m.name }
    r[#r + 1] = { x = px + 268, y = yy, w = 32, h = 34, label = "x", delmap = m }
  end
  -- game update (top-right), when GitHub has a newer version
  self:updateRect(r, w)
  return r
end

-- Commander of Heroes setup: map, format, difficulty on the left; your three squads on the right
function Menu:cohRects()
  local x0, y, w, h = self:layout()
  local r = {}
  self:tabRects(r)
  local C = COH_SETUP
  for i, o in ipairs({ { "Small", 1 }, { "Medium", 2 } }) do
    r[#r + 1] = { x = x0 + (i - 1) * 104, y = y, w = 100, h = 34, label = o[1], kind = "cohsize", value = o[2],
      active = C.size == o[2], rowLabel = i == 1 and "Map" or nil }
  end
  for i, o in ipairs(COH_FORMATS) do
    r[#r + 1] = { x = x0 + (i - 1) * 104, y = y + 44, w = 100, h = 34, label = o[1], kind = "cohfmt", value = i,
      active = C.format == i, rowLabel = i == 1 and "Format" or nil }
  end
  for i, o in ipairs({ { "Their own picks", "own" }, { "Mirror yours", "mirror" } }) do
    r[#r + 1] = { x = x0 + (i - 1) * 154, y = y + 88, w = 150, h = 34, label = o[1], kind = "cohenemy", value = o[2],
      active = (C.enemy or "own") == o[2], rowLabel = i == 1 and "Enemy squads" or nil, small = true }
  end
  r[#r + 1] = { x = x0, y = y + 132, w = 32, h = 34, label = "-", kind = "cohlv", d = -1, rowLabel = "Difficulty" }
  r[#r + 1] = { x = x0 + 36, y = y + 132, w = 132, h = 34, label = C.level .. "  " .. LEVEL_NAMES[C.level], kind = "cohlv", d = 0 }
  r[#r + 1] = { x = x0 + 172, y = y + 132, w = 32, h = 34, label = "+", kind = "cohlv", d = 1 }
  local by = y + 4 * 46 + 54 + 160
  r[#r + 1] = { x = x0, y = by, w = 520, h = 54, label = "START", action = "start" }
  r[#r + 1] = { x = x0, y = by + 64, w = 256, h = 36, label = "Controls", action = "help" }
  r[#r + 1] = { x = x0 + 264, y = by + 64, w = 256, h = 36, label = "Quit", action = "quit" }
  -- the squads: five slots, each one kind of unit
  local SQ = require("src.squads")
  local px = x0 + 580
  for i = 1, SQ.SLOTS do
    local sq = C.squads[i]
    local yy = y + (i - 1) * 40
    r[#r + 1] = { x = px + 102, y = yy, w = 70, h = 32, label = sq.on and "On" or "Off", kind = "sqon", sqi = i, active = sq.on, small = true,
      cohRow = i }
    local ty = SQ.byType[sq.type] or SQ.TYPES[1]
    local un = D.units[ty.unit].name
    if not un:match("y$") then un = un .. "s" end
    r[#r + 1] = { x = px + 178, y = yy, w = 200, h = 32, label = ty.name .. "  (" .. ty.size .. " " .. un .. ")  v",
      kind = "sqtype", sqi = i, small = true, cohRow = i }
  end
  self:updateRect(r, w)
  return r
end

function Menu:drawCohInfo(x0, y)
  local lg = love.graphics
  local SQ = require("src.squads")
  local C = COH_SETUP
  local cur = C.squads[C.squadTab] or C.squads[1]
  local px = x0 + 580
  lg.setFont(R.font(13))
  lg.setColor(0.55, 0.62, 0.7)
  lg.print("YOUR SQUADS  (2 to 5; each is one kind of unit, led by a veteran)", px, y - 22)
  local ok, n, air = SQ.validSetup(C.squads)
  local mx, my = love.mouse.getPosition()
  for i = 1, SQ.SLOTS do
    local yy = y + (i - 1) * 40
    if my >= yy and my <= yy + 32 and mx >= px and mx <= px + 380 and not self.dropdown then C.squadTab = i end
    lg.setFont(R.font(14))
    local on = C.squads[i].on
    lg.setColor(C.squadTab == i and 1 or 0.8, C.squadTab == i and 0.85 or 0.84, C.squadTab == i and 0.4 or 0.9, on and 1 or 0.5)
    lg.print("Squad " .. i, px + 4, yy + 7)
  end
  cur = C.squads[C.squadTab] or C.squads[1]
  local ty = SQ.byType[cur.type] or SQ.TYPES[1]
  local yy = y + SQ.SLOTS * 40 + 10
  lg.setColor(0.95, 0.85, 0.5)
  lg.printf("Squad " .. C.squadTab .. ": " .. ty.name .. " - " .. ty.desc, px, yy, 400)
  yy = yy + 40
  for slot, key in ipairs(ty.skills) do
    local sk = SQ.SKILLS[key]
    local text = (slot == 1 and "Q  " or "W  ") .. sk.name .. ": " .. sk.desc
    lg.setColor(0.75, 0.85, 1)
    lg.printf(text, px, yy, 400)
    local _, lines = R.font(13):getWrap(text, 400)
    yy = yy + #lines * 16 + 4
  end
  if not ok then
    lg.setColor(1, 0.5, 0.4)
    lg.print(n < 2 and "Field at least 2 squads." or "Only one air squad (Gunships) a side.", px, yy + 6)
  elseif not SQ.hasAntiAir(C.squads) then
    lg.setColor(1, 0.75, 0.35)
    lg.printf("No anti-air: only Air Defense and Recon (light AA) can hit the enemy's Gunships.", px, yy + 6, 400)
  end
  -- how it plays, under the setup on the left
  lg.setColor(0.6, 0.66, 0.74)
  lg.printf("Five capture points. Ground units standing on a point take it (aircraft can't). "
    .. "Hold more points than the enemy and their tickets drain; every unit you lose costs tickets too. "
    .. "Run them out of tickets, or destroy their HQ, to win.\n\n"
    .. "1-5 always select that squad (twice: jump to it); click any unit for its whole squad (Alt: one unit). Fallen members are replaced at your HQ and walk back out to their leader - "
    .. "faster the more points you hold - and units heal fast there. A fallen leader returns after 45 s. Never scored (yet).",
    x0, y + 186, 520)
end

function Menu:activeCount()
  local n = 0
  for _, s in ipairs(self.slots) do if s.on then n = n + 1 end end
  return n
end

function Menu:validTeams()
  if self.mode == "arena" or self.mode == "craft" then return true end
  if self.mode == "coh" then return (require("src.squads").validSetup(COH_SETUP.squads)) end
  if self.savedMap and self.savedMap.np <= 2 and self:activeCount() > 2 then return false end
  local teams, n = {}, 0
  for _, s in ipairs(self.slots) do
    if s.on and not teams[s.team] then teams[s.team] = true; n = n + 1 end
  end
  return n >= 2
end

function Menu:update(dt)
  self.t = self.t + dt
  local ON = require("src.online")
  if not self.noOnline then ON.check() end
  ON.poll()
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
  local th = THEMES[self.mode] or THEMES.rts
  lg.clear(th.bg[1], th.bg[2], th.bg[3])
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
  lg.setColor(th.title[1], th.title[2], th.title[3])
  lg.print(title, w / 2 - f:getWidth(title) / 2, y - 150)
  lg.setFont(R.font(18))
  lg.setColor(th.sub[1], th.sub[2], th.sub[3])
  local sub = self.mode == "arena" and "Commander Arena: no base, no army. Your Commander, three lanes and endless creeps."
    or (self.mode == "craft" and "Commander Craft: gold, lumber, heroes and three tiers. Warcraft rules, our heroes.")
    or (self.mode == "coh" and "Commander of Heroes: lead squads, not armies. Take the map, bleed their tickets."
    or "A small real-time strategy game of land, sea and air. Shapes included.")
  lg.print(sub, w / 2 - R.font(18):getWidth(sub) / 2, y - 78)
  do
    local mv = D.MODE_VERSIONS[self.mode] or D.MODE_VERSIONS.rts
    local vt = string.format("%s v%s  -  %s", D.MODE_NAMES[self.mode] or "Annihilation", mv[1], mv[2])
    lg.setFont(R.font(13))
    lg.setColor(th.sub[1], th.sub[2], th.sub[3], 0.7)
    lg.print(vt, w / 2 - R.font(13):getWidth(vt) / 2, y - 52)
  end

  -- column headers for player slots
  lg.setFont(R.font(13))
  lg.setColor(0.55, 0.62, 0.7)
  local ty = y + 160
  if self.mode == "craft" then
    -- (rows carry their own labels)
  elseif self.mode == "coh" then
    self:drawCohInfo(x0, y)
  elseif self.mode == "arena" then
    local fm = AFORMATS[self.arena.format]
    if not fm.ffa and fm[2] + fm[3] > 6 then
      lg.print("Your side  (class / difficulty)", x0 - 130, ty - 22)
      lg.print("Enemy side", x0 + 222, ty - 22)
    else
      lg.print("Commanders", x0 - 130, ty - 22)
      lg.print("Class (click to cycle)", x0, ty - 22)
      lg.print("Difficulty (1-10)", x0 + 176, ty - 22)
    end
    lg.print("CLASSES  (click one to play it)", x0 + 580, y - 22)
  else
    lg.print("Players", x0 - 130, ty - 22)
    lg.print("Team", x0 + 78, ty - 22)
    lg.print("Difficulty (1-10)", x0 + 176, ty - 22)
    lg.print("Personality (click to choose)", x0 + 388, ty - 22)
    if false then
    elseif RTS_SETUP.game == "sandbox" then
      lg.print("SANDBOX ARMIES", x0 + 580, y - 22)
      lg.setColor(0.6, 0.85, 1); lg.print("Your side", x0 + 580 + 150 + 22, y - 22)
      lg.setColor(1, 0.55, 0.5); lg.print("Enemies", x0 + 580 + 270 + 26, y - 22)
      lg.setFont(R.font(13))
      for i, k in ipairs(SANDBOX_UNITS) do
        lg.setColor(0.8, 0.85, 0.92)
        lg.print(D.units[k].name, x0 + 580, y + (i - 1) * 30 + 5)
      end
      lg.setColor(0.5, 0.56, 0.64)
      lg.printf("Shift-click = 10 at a time, right-click lowers. Every team on a side gets that army. Your Commander still has to survive. Never scored.",
        x0 + 580, y + #SANDBOX_UNITS * 30 + 8, 380)
      lg.setFont(R.font(13))
      lg.setColor(0.55, 0.62, 0.7)
    else
      lg.print("SAVED MAPS", x0 + 580, y - 22)
    end
  end

  local mx, my = love.mouse.getPosition()
  local hoverProf, hoverMod, hoverClass, hoverTmpl
  self.hoverLevel, self.hoverRace, self.hoverHero, self.hoverMap = nil, nil, nil, nil
  for _, r in ipairs(self:rects()) do
    if r.rowLabel then
      lg.setFont(R.font(16))
      lg.setColor(0.75, 0.8, 0.88)
      lg.print(r.rowLabel, r.x - 130, r.y + 7)
    end
    local hover = mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h
    local active = (r.field == "size" and self.size == r.value) or (r.field == "water" and self.water == r.value) or r.active
    if r.kind == "prof" and hover then hoverProf = self.slots[r.slot] end
    if r.modkey and hover then hoverMod = r.modkey end
    if hover and r.roster then hoverClass = r.roster end
    if hover and r.kind == "aclass" then
      local k = self.arena.slots[r.aslot].class
      hoverClass = k > 0 and k or -1
    end
    if r.afield then active = r.active end
    if hover and r.tmpl then hoverTmpl = r.tmpl end
    if hover and r.alevel and self.mode == "arena" then self.hoverLevel = self.arena.slots[r.aslot].level end
    if hover and r.clevel then self.hoverLevel = self.craft.level end
    if hover and r.craceHover then self.hoverRace = r.craceHover end
    if hover and r.heroKey then self.hoverHero = r.heroKey end
    if hover and r.cmapHover then self.hoverMap = r.cmapHover end
    if r.cfield then active = r.active end
    if r.kind == "chip" then
      local c = D.teamColor[r.slot]
      local on = r.on
      if on == nil then on = self.slots[r.slot].on end
      lg.setColor(c[1] * 0.35, c[2] * 0.35, c[3] * 0.35, on and 1 or 0.4)
      lg.rectangle("fill", r.x, r.y, r.w, r.h, 6)
      lg.setColor(c[1], c[2], c[3], on and 1 or 0.4)
      if r.small then
        lg.rectangle("fill", r.x + 5, r.y + r.h / 2 - 5, 10, 10, 2)
        lg.setFont(R.font(13))
        lg.setColor(1, 1, 1, on and 1 or 0.45)
        lg.print(r.label, r.x + 19, r.y + r.h / 2 - 8)
      else
        lg.rectangle("fill", r.x + 8, r.y + 10, 16, 16, 3)
        lg.setFont(R.font(16))
        lg.setColor(1, 1, 1, on and 1 or 0.45)
        lg.print(r.label, r.x + 32, r.y + 8)
      end
    else
      if r.action == "start" then
        if self:validTeams() then
          lg.setColor(hover and 0.2 or 0.15, hover and 0.55 or 0.45, hover and 0.3 or 0.25)
        else
          lg.setColor(0.25, 0.25, 0.27)
        end
      elseif r.kind == "lvlabel" then
        lg.setColor(th.field[1], th.field[2], th.field[3])
      elseif active then
        lg.setColor(th.active[1], th.active[2], th.active[3])
      else
        local c = hover and th.hover or th.btn
        lg.setColor(c[1], c[2], c[3])
      end
      lg.rectangle("fill", r.x, r.y, r.w, r.h, 6)
      lg.setColor(th.line[1], th.line[2], th.line[3], 0.8)
      lg.rectangle("line", r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1, 6)
      local fs = r.action == "start" and 24 or (r.big and 20 or (r.small and 13 or 15))
      while fs > 11 and R.font(fs):getWidth(r.label or "") > r.w - 14 do fs = fs - 1 end -- long labels shrink to fit
      if r.big and r.active then
        lg.setColor(0.95, 0.75, 0.3)
        lg.rectangle("line", r.x - 2.5, r.y - 2.5, r.w + 5, r.h + 5, 8)
      end
      lg.setFont(R.font(fs))
      lg.setColor(1, 1, 1)
      local label = r.label
      if r.action == "start" and not self:validTeams() then
        label = self.mode == "coh" and "Fix your squads (see right)"
          or ((self.savedMap and self.savedMap.np <= 2 and self:activeCount() > 2) and "That saved map is 2-player only" or "Put someone on another team")
      end
      lg.print(label, r.x + r.w / 2 - R.font(fs):getWidth(label) / 2, r.y + r.h / 2 - fs * 0.62)
      if r.roster then
        local ck = ARENA.CLASSES[r.roster].key
        lg.setColor(1, 1, 1, 0.9)
        require("src.icons").draw("cls_" .. ck, r.x + 18, r.y + r.h / 2, r.h - 6)
      end
    end
  end
  if self.mode == "craft" then
    self:drawCraftInfo(x0, y, w, h, self.hoverRace, self.hoverHero)
  elseif self.mode == "arena" then
    -- captions under the two map groups
    lg.setFont(R.font(11))
    lg.setColor(0.62, 0.66, 0.74)
    lg.print("simple: lanes, towers, creeps", x0 + 4, y - 16)
    lg.setColor(0.78, 0.6, 1)
    lg.print("jungle: camps, shrines, Colossus", x0 + 4 * 92 + 18 + 4, y - 16)
    lg.setColor(0.72, 0.42, 1, 0.5)
    lg.setLineWidth(1)
    lg.line(x0 + 4 * 92 + 7, y - 14, x0 + 4 * 92 + 7, y + 34)
    self:drawArenaInfo(x0, y, w, h, hoverClass, hoverTmpl)
  elseif self.mode == "coh" then
    -- (drawn with the column headers)
  else
  -- personality description
  lg.setFont(R.font(14))
  lg.setColor(0.65, 0.72, 0.8)
  local desc
  local MODDESC = {
    alien = "Alien Tech: a huge alien walker lands near the middle. Hold its zone 15s to claim it. Repeats. (Score becomes unofficial.)",
    drops = "Dropships: from 3:00, alien crews drop and wander. Meet one and a coin flip decides: join you or attack. (Unofficial score.)",
    groovy = "Groovy: flower-power explosions, far-out colors and a slowly tripping landscape. Cosmetic, so score stays official.",
    convoy = "Metal Alert: a quarter of the metal deposits, worth triple - but an ore truck has to haul it to your Refinery. Lose a truck and that extractor needs a minute to roll out another. (Unofficial.)",
    apoc = "Post-Apocalypse: no Commanders - everyone starts with a single Constructor. Destroy every enemy unit and building to win. The fog lifts at 10:00. (Unofficial.)",
  }
  if hoverMod then desc = MODDESC[hoverMod]
  elseif hoverProf then desc = D.profiles[hoverProf.prof].key .. ": " .. D.profiles[hoverProf.prof].desc
  else desc = "Same team number = allies. Hover a personality to see what it does." end
  lg.printf(desc, x0, ty + 4 * 46 + 4, 520)
  if RTS_SETUP.game == "standard" then
  if self.savedMap then
    lg.setColor(0.6, 0.85, 0.65)
    lg.printf("Playing saved map: " .. self.savedMap.name .. "  (seed " .. self.savedMap.seed .. ")", x0 + 580, y + 44 + math.min(5, #self.maps) * 40 + 2, 300)
  elseif #self.maps == 0 then
    lg.setColor(0.5, 0.56, 0.64)
    lg.printf("No saved maps yet. In a game, open the menu (Esc) and choose \"Save this map\" to keep one you like.", x0 + 580, y + 48, 300)
  end
  -- high scores (Score mode)
  self.scores = self.scores or require("src.scores").load()
  local hy = y + 44 + 5 * 40 + 34
  lg.setFont(R.font(13))
  lg.setColor(0.55, 0.62, 0.7)
  lg.print("HIGH SCORES  season " .. D.SEASON, x0 + 580, hy)
  local official = not (self.mods.alien or self.mods.drops or self.mods.convoy or self.mods.apoc)
  if official then lg.setColor(0.5, 0.9, 0.55) else lg.setColor(1, 0.6, 0.35) end
  local ot = official and "this game counts" or "modifiers on: unofficial"
  lg.print(ot, x0 + 580 + 300 - R.font(13):getWidth(ot), hy)
  if #self.scores == 0 then
    lg.setColor(0.45, 0.5, 0.58)
    lg.print("None yet - win a game with no Alien Tech or Dropships.", x0 + 580, hy + 22)
  end
  for i, sc in ipairs(self.scores) do
    if i > 5 then break end
    lg.setColor(i == 1 and 1 or 0.85, i == 1 and 0.85 or 0.88, i == 1 and 0.35 or 0.92)
    lg.print(string.format("%d. %s  %s  %s", i, U_fmt(sc.pts), sc.result, sc.date), x0 + 580, hy + 4 + i * 20)
  end
  -- online leaderboard for this version (fetched from GitHub in the background)
  local ON = require("src.online")
  local oy = hy + 4 + 6 * 20 + 14
  lg.setColor(0.55, 0.62, 0.7)
  lg.print("ONLINE LEADERBOARD  season " .. D.SEASON, x0 + 580, oy)
  if not ON.board or #ON.board == 0 then
    lg.setColor(0.45, 0.5, 0.58)
    lg.print(ON.board and "No scores yet this version - be the first." or "(offline)", x0 + 580, oy + 22)
  else
    for i, e in ipairs(ON.board) do
      if i > 5 then break end
      lg.setColor(i == 1 and 1 or 0.85, i == 1 and 0.85 or 0.88, i == 1 and 0.35 or 0.92)
      local nm = tostring(e.name or "?")
      if #nm > 14 then nm = nm:sub(1, 13) .. "." end
      lg.print(string.format("%d. %s  %s  %s", i, U_fmt(e.score), nm, tostring(e.result or "")), x0 + 580, oy + 4 + i * 20)
    end
  end
  end -- (not sandbox)
  end -- rts info
  do
    local ON = require("src.online")
    if ON.msg and (ON.state == "failed" or ON.state == "noupdate" or ON.state == "updated") then
      lg.setFont(R.font(13))
      lg.setColor(0.8, 0.85, 0.95)
      lg.printf(ON.msg, w - 300, 62, 284)
    end
  end
  lg.setColor(0.4, 0.45, 0.52)
  lg.print("v" .. D.VERSION .. "  (" .. (D.MODE_NAMES[self.mode] or "") .. " " .. ((D.MODE_VERSIONS[self.mode] or {})[1] or "") .. ")", 12, h - 24)
  UI.drawMusicLabel(80, h - 24, false, true)
  lg.setFont(R.font(13))
  lg.setColor(0.5, 0.56, 0.64)
  local tip = self.mode == "arena"
    and "Tip: stay behind your creeps, let them soak tower fire, and go home to heal. Q W E R use skills at the mouse."
    or self.mode == "craft" and "Tip: keep five workers on gold and a few on wood, build Farms before you need them, and creep with your hero early."
    or self.mode == "coh" and "Tip: 1-5 grab a squad (Shift adds). Q / W fire the ACTIVE (gold) squad's skills; C moves the gold to the next one."
    or (require("src.ghost").unlocked() and "Tip: Mirror (plays like you) and Nemesis (plays against your habits) are in the personality list."
      or string.format("Finish %d more Annihilation games (win or lose, no gameplay modifiers) to unlock two opponents that learn from you.",
        math.max(0, require("src.ghost").NEEDED - require("src.ghost").completed())))
  -- (skipped when the buttons reach the bottom of a small screen)
  if not (self.mode == "arena" and self.arenaStartY and self.arenaStartY + 104 > h - 44) then
    lg.print(tip, w / 2 - R.font(13):getWidth(tip) / 2, h - 40)
  end
  self:drawDropdown()
  if self.showHelp then UI.drawHelp(self.mode == "craft" and "craft" or (self.mode == "coh" and "coh") or self.mode == "arena") end
  if require("src.settings").open then require("src.settings").draw() end
end

function Menu:drawArenaInfo(x0, y, w, h, hoverClass, hoverTmpl)
  local lg = love.graphics
  local ty = y + 160
  lg.setFont(R.font(14))
  lg.setColor(0.65, 0.72, 0.8)
  local desc
  if self.hoverLevel then
    local L = self.hoverLevel
    desc = "Difficulty " .. L .. " (" .. LEVEL_NAMES[L] .. "): " .. (L <= 2 and "slow to react, rarely uses skills." or
      L <= 4 and "reacts in about a second, uses skills sometimes, denies from 4." or
      L <= 6 and "last-hits, denies, backs off from stronger Commanders, leads skill shots at 6." or
      "fast reactions, near-perfect last hits and skill use" .. (L >= 8 and string.format("; also +%d%% experience.", (L - 7) * 10) or "."))
  elseif hoverTmpl then
    desc = ATEMPLATES[hoverTmpl][3]
  elseif hoverClass and hoverClass > 0 then
    local c = ARENA.CLASSES[hoverClass]
    local names = {}
    for _, k in ipairs(c.skills) do names[#names + 1] = ARENA.SKILLS[k].name end
    desc = c.name .. ": " .. c.tag .. "  Skills: " .. table.concat(names, ", ") .. ".  Ultimate: " .. ARENA.SKILLS[c.ult].name .. "."
  elseif hoverClass == -1 then
    desc = "Random: a class picked for you when the match starts."
  else
    desc = "Destroy the enemy Core. Towers guard each lane: outer first, then inner, then the Core. Hover a class to read about it."
  end
  lg.printf(desc, x0, (self.arenaStartY and self.arenaStartY - 48) or (ty + 4 * 46 + 4), 520)
  -- arena high scores and online board
  self.arenaScores = self.arenaScores or require("src.scores").load("arena")
  local hy = y + 5 * 34 + 30
  lg.setFont(R.font(13))
  lg.setColor(0.55, 0.62, 0.7)
  lg.print("ARENA HIGH SCORES  season " .. D.SEASON, x0 + 580, hy)
  if #self.arenaScores == 0 then
    lg.setColor(0.45, 0.5, 0.58)
    lg.print("None yet - win an Arena match.", x0 + 580, hy + 22)
  end
  for i, sc in ipairs(self.arenaScores) do
    if i > 5 then break end
    lg.setColor(i == 1 and 1 or 0.85, i == 1 and 0.85 or 0.88, i == 1 and 0.35 or 0.92)
    lg.print(string.format("%d. %s  %s  %s", i, U_fmt(sc.pts), sc.result, sc.date), x0 + 580, hy + 4 + i * 20)
  end
  local ON = require("src.online")
  local oy = hy + 4 + 6 * 20 + 14
  lg.setColor(0.55, 0.62, 0.7)
  lg.print("ONLINE ARENA LEADERBOARD  season " .. D.SEASON, x0 + 580, oy)
  local board = ON.arenaBoard
  if not board or #board == 0 then
    lg.setColor(0.45, 0.5, 0.58)
    lg.print(board and "No scores yet this version - be the first." or "(offline)", x0 + 580, oy + 22)
  else
    for i, e in ipairs(board) do
      if i > 5 then break end
      lg.setColor(i == 1 and 1 or 0.85, i == 1 and 0.85 or 0.88, i == 1 and 0.35 or 0.92)
      local nm = tostring(e.name or "?")
      if #nm > 14 then nm = nm:sub(1, 13) .. "." end
      lg.print(string.format("%d. %s  %s  %s", i, U_fmt(e.score), nm, tostring(e.result or "")), x0 + 580, oy + 4 + i * 20)
    end
  end
end

function Menu:dropdownItems()
  local d = self.dropdown
  if not d then return {} end
  local h = love.graphics.getHeight()
  local items = {}
  local ih = 28
  local y0 = d.y
  if d.coh then
    -- Commander of Heroes: the squad types
    local SQ = require("src.squads")
    if y0 + #SQ.TYPES * ih > h - 10 then y0 = math.max(10, h - 10 - #SQ.TYPES * ih) end
    for i, ty in ipairs(SQ.TYPES) do
      local un = D.units[ty.unit].name
      if not un:match("y$") then un = un .. "s" end
      items[i] = { x = d.x, y = y0 + (i - 1) * ih, w = d.w, h = ih - 2, ctype = ty.key, label = ty.name .. "  (" .. ty.size .. " " .. un .. ")" }
    end
    return items
  end
  if y0 + #D.profiles * ih > h - 10 then y0 = math.max(10, h - 10 - #D.profiles * ih) end
  for i, p in ipairs(D.profiles) do
    items[i] = { x = d.x, y = y0 + (i - 1) * ih, w = d.w, h = ih - 2, prof = i, label = p.key }
  end
  return items
end

function Menu:drawDropdown()
  local d = self.dropdown
  if not d then return end
  local lg = love.graphics
  local items = self:dropdownItems()
  local mx, my = love.mouse.getPosition()
  local top, bottom = items[1].y - 4, items[#items].y + items[#items].h + 4
  lg.setColor(0.04, 0.05, 0.08, 0.97)
  lg.rectangle("fill", d.x - 4, top, d.w + 8, bottom - top, 6)
  lg.setColor(0.4, 0.55, 0.7)
  lg.rectangle("line", d.x - 3.5, top + 0.5, d.w + 7, bottom - top - 1, 6)
  local hoverDesc
  for _, it in ipairs(items) do
    local hover = mx >= it.x and mx <= it.x + it.w and my >= it.y and my <= it.y + it.h
    local cur = d.coh and (COH_SETUP.squads[d.coh].type == it.ctype) or (not d.coh and self.slots[d.slot].prof == it.prof)
    if hover then lg.setColor(0.22, 0.32, 0.45) elseif cur then lg.setColor(0.16, 0.3, 0.45) else lg.setColor(0.1, 0.13, 0.18) end
    lg.rectangle("fill", it.x, it.y, it.w, it.h, 4)
    lg.setFont(R.font(15))
    lg.setColor(1, 1, 1)
    lg.print(it.label, it.x + 10, it.y + 4)
    if hover then
      if it.ctype then
        local SQ = require("src.squads")
        local ty = SQ.byType[it.ctype]
        hoverDesc = ty.desc .. "\n\nQ  " .. SQ.SKILLS[ty.skills[1]].name .. ": " .. SQ.SKILLS[ty.skills[1]].desc
          .. "\nW  " .. SQ.SKILLS[ty.skills[2]].name .. ": " .. SQ.SKILLS[ty.skills[2]].desc
      else hoverDesc = D.profiles[it.prof].desc end
    end
  end
  if hoverDesc then
    lg.setFont(R.font(13))
    local tw = 300
    local _, lines = R.font(13):getWrap(hoverDesc, tw - 16)
    local th = #lines * 16 + 12
    lg.setColor(0.04, 0.05, 0.08, 0.97)
    lg.rectangle("fill", d.x + d.w + 10, top, tw, th, 6)
    lg.setColor(0.85, 0.9, 0.95)
    lg.printf(hoverDesc, d.x + d.w + 18, top + 6, tw - 16)
  end
end

function Menu:mousepressed(x, y, b)
  if self.dropdown then
    for _, it in ipairs(self:dropdownItems()) do
      if x >= it.x and x <= it.x + it.w and y >= it.y and y <= it.y + it.h then
        if it.ctype then COH_SETUP.squads[self.dropdown.coh].type = it.ctype; COH_SETUP.squadTab = self.dropdown.coh
        else self.slots[self.dropdown.slot].prof = it.prof end
      end
    end
    self.dropdown = nil
    return
  end
  if self.showHelp then self.showHelp = false; return end
  local SET = require("src.settings")
  if SET.open then SET.click(x, y, b); return end
  for _, r in ipairs(self:rects()) do
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
      local s = r.slot and self.slots[r.slot]
      local dir = (b == 2) and -1 or 1
      local as = r.aslot and self.arena.slots[r.aslot]
      if r.tab then self.mode = r.tab
      elseif r.cfield then
        self.craft[r.cfield] = r.value
        if r.cfield == "race" then self.craft.hero = 0 end
      elseif r.kind == "clvdown" then self.craft.level = math.max(1, self.craft.level - 1)
      elseif r.kind == "clvup" then self.craft.level = math.min(10, self.craft.level + 1)
      elseif r.kind == "lvlabel" and r.clevel then self.craft.level = (self.craft.level - 1 + dir) % 10 + 1
      elseif r.afield then self.arena[r.afield] = r.value
        -- a map change keeps the format only if the map was built for it
        if r.afield == "template" and not self.arena.experimental then
          local tk = ATEMPLATES[r.value][1]
          if not aformatOK(tk, AFORMATS[self.arena.format][1]) then
            for i, o in ipairs(AFORMATS) do if o[1] == AMAP_FORMATS[tk][1] then self.arena.format = i; break end end
          end
        end
        -- ten Commanders need room: 5v5 starts on a Huge map (you can still pick another)
        if r.afield == "format" and AFORMATS[r.value][1] == "5v5" then self.arena.size = #ASIZES end
      elseif r.kind == "aexp" then
        self.arena.experimental = not self.arena.experimental
        if not self.arena.experimental then
          local tk = ATEMPLATES[self.arena.template or 1][1]
          if not aformatOK(tk, AFORMATS[self.arena.format][1]) then
            for i, o in ipairs(AFORMATS) do if o[1] == AMAP_FORMATS[tk][1] then self.arena.format = i; break end end
          end
        end
      elseif r.kind == "aclass" then as.class = (as.class + dir) % (#ARENA.CLASSES + 1)
      elseif r.kind == "alvdown" then as.level = math.max(1, as.level - 1)
      elseif r.kind == "alvup" then as.level = math.min(10, as.level + 1)
      elseif r.kind == "lvlabel" and r.alevel then as.level = (as.level - 1 + dir) % 10 + 1
      elseif r.kind == "roster" then
        -- pick this class for yourself (click again for Random)
        local you = self.arena.slots[1]
        you.class = (you.class == r.roster) and 0 or r.roster
      elseif r.modkey then self.mods[r.modkey] = not self.mods[r.modkey]
      elseif r.gametype then RTS_SETUP.game = r.gametype
      elseif r.kind == "sqtab" then COH_SETUP.squadTab = r.sqi
      elseif r.kind == "sqon" then
        local sq = COH_SETUP.squads[r.sqi]
        sq.on = not sq.on
        COH_SETUP.squadTab = r.sqi
      elseif r.kind == "sqtype" then
        COH_SETUP.squadTab = r.sqi
        self.dropdown = { coh = r.sqi, x = r.x, y = r.y + r.h + 2, w = 250 }
      elseif r.kind == "cohsize" then COH_SETUP.size = r.value
      elseif r.kind == "cohfmt" then COH_SETUP.format = r.value
      elseif r.kind == "cohenemy" then COH_SETUP.enemy = r.value
      elseif r.kind == "cohlv" then COH_SETUP.level = math.max(1, math.min(10, COH_SETUP.level + (r.d ~= 0 and r.d or dir)))
      elseif r.kind == "sbdown" or r.kind == "sbup" or r.kind == "sbcount" then
        local step = love.keyboard.isDown("lshift", "rshift") and 10 or 1
        local d = (r.kind == "sbdown" or (r.kind == "sbcount" and b == 2)) and -step or step
        local t = RTS_SETUP.sandbox[r.sbside]
        t[r.sbkey] = math.max(0, math.min(300, (t[r.sbkey] or 0) + d))
      elseif r.field then self[r.field] = r.value; self.savedMap = nil
      elseif r.kind == "toggle" then
        s.on = not s.on
        -- keep slots contiguous so colors stay put
        if s.on then for i = 2, r.slot do self.slots[i].on = true end
        else for i = r.slot, 4 do self.slots[i].on = false end end
      elseif r.kind == "team" then s.team = (s.team - 1 + dir) % 4 + 1
      elseif r.kind == "lvdown" then s.level = math.max(1, s.level - 1)
      elseif r.kind == "lvup" then s.level = math.min(10, s.level + 1)
      elseif r.kind == "lvlabel" then s.level = (s.level - 1 + dir) % 10 + 1
      elseif r.kind == "prof" then
        -- open the personality list under the button
        self.dropdown = { slot = r.slot, x = r.x, y = r.y + r.h + 2, w = 200 }
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
      elseif r.action == "settings" then SET.open = true
      elseif r.action == "update" then
        local ON = require("src.online")
        if ON.state == "updated" then love.event.quit("restart")
        elseif ON.state ~= "downloading" then ON.update() end
      elseif r.action == "quit" then love.event.quit() end
      return
    end
  end
end

function Menu:keypressed(k)
  if require("src.settings").open then
    if k == "escape" then require("src.settings").open = false; require("src.settings").save() end
    return
  end
  if (k == "return" or k == "space") and self:validTeams() then return "start" end
  if k == "escape" and self.dropdown then self.dropdown = nil; return end
  local SET = require("src.settings")
  if k == "escape" and SET.open then SET.open = false; SET.save(); return end
  if k == "escape" then
    if self.showHelp then self.showHelp = false else love.event.quit() end
  end
  if k == "f1" then self.showHelp = not self.showHelp end
end

function Menu:options()
  self:remember()
  if self.mode == "craft" then
    local CS = self.craft
    local races = D.CRAFT.races
    local myRace = CS.race > 0 and races[CS.race].key or nil
    local hero = (CS.race > 0 and CS.hero > 0) and races[CS.race].heroes[CS.hero] or nil
    local enemy = CS.enemy > 0 and races[CS.enemy].key or nil
    local CMAPS = require("src.craft_map").TEMPLATES
    local players = { { human = true, ally = 1, race = myRace, class = hero }, { ally = 2, level = CS.level, race = enemy } }
    if CS.map > 0 and CMAPS[CS.map].players == 4 then
      -- 2v2: each team is one race (settle a random race now so both teammates share it)
      myRace = myRace or races[love.math.random(#races)].key
      enemy = enemy or races[love.math.random(#races)].key
      players = { { human = true, ally = 1, race = myRace, class = hero }, { ally = 2, level = CS.level, race = enemy },
        { ally = 1, level = CS.level, race = myRace }, { ally = 2, level = CS.level, race = enemy } }
    end
    return { mode = "craft", size = 88, menuMode = "craft", craftSetup = CS, arenaSetup = self.arena,
      template = CS.map > 0 and CMAPS[CS.map][1] or "random",
      players = players,
      sizeI = self.size, waterI = self.water, slots = self.slots, mods = {} }
  end
  if self.mode == "coh" then
    local C = COH_SETUP
    local f = COH_FORMATS[C.format]
    local players = { { human = true, ally = 1 } }
    for _ = 1, f[3] do players[#players + 1] = { ally = 2, level = C.level } end
    for _ = 2, f[2] do players[#players + 1] = { ally = 1, level = C.level } end
    -- creation order decides colors and starts: you, enemy, (ally, enemy 2)
    if #players == 4 then players = { players[1], players[2], players[4], players[3] } end
    return { mode = "rts", coh = true, size = C.size == 1 and 96 or 128, water = WATER[1][2], players = players,
      mods = { squads = true }, squadSetup = C.squads, enemySquads = C.enemy or "own", menuMode = "coh",
      arenaSetup = self.arena, craftSetup = self.craft, sizeI = self.size, waterI = self.water, slots = self.slots }
  end
  if self.mode == "arena" then
    local A = self.arena
    local act = self:arenaActive()
    local players = {}
    local allyOf = AFORMATS[A.format].ffa and { 1, 4, 2, 3 } or { 1, 1, 2, 2, 1, 2, 1, 2, 1, 2 }
    for _, i in ipairs(self:arenaOrder()) do
      do
        local sl = A.slots[i]
        players[#players + 1] = { human = sl.human, ally = allyOf[i], level = sl.level,
          class = sl.class > 0 and ARENA.CLASSES[sl.class].key or nil }
      end
    end
    local sizeI = A.experimental and A.size or aautoSize(ATEMPLATES[A.template or 1][1], AFORMATS[A.format])
    return { mode = "arena", size = ASIZES[sizeI][2], players = players, menuMode = "arena", arenaSetup = A, craftSetup = self.craft,
      experimental = A.experimental,
      template = ATEMPLATES[A.template or 1][1],
      sizeI = self.size, waterI = self.water, slots = self.slots, mods = {} }
  end
  local players = {}
  for _, s in ipairs(self.slots) do
    if s.on then
      local prof = (not s.human) and D.profiles[s.prof] or nil
      local lvl = s.level
      if prof and prof.ghost then lvl = require("src.ghost").level(prof.key) end
      players[#players + 1] = { human = s.human, ally = s.team, level = lvl, profile = prof and prof.key or nil }
    end
  end
  local o = {
    size = SIZES[self.size][2], water = WATER[self.water][2], players = players,
    sizeI = self.size, waterI = self.water, slots = self.slots, savedMap = self.savedMap,
    mods = { alien = self.mods.alien, drops = self.mods.drops, groovy = self.mods.groovy, convoy = self.mods.convoy, apoc = self.mods.apoc,
      sandbox = RTS_SETUP.game == "sandbox" or nil },
    sandbox = RTS_SETUP.game == "sandbox" and RTS_SETUP.sandbox or nil,
    menuMode = "rts", arenaSetup = self.arena, craftSetup = self.craft,
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
