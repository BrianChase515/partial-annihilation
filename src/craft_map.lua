-- Commander Craft map: "the Horseshoe". A U of land around a lake - each player's base sits
-- at the top of one arm, the arms meet along the bottom, and a peninsula juts up from the
-- middle of the bottom to a rich gold mine guarded by creeps. Forests line the outer
-- edges (wood to chop). Mirror-symmetric left/right.
local D = require("src.defs")
local U = require("src.util")
local M = require("src.map")

local CM = {}
M.TREE = 4

CM.TEMPLATES = {
  { "horseshoe", "Horseshoe", "The Horseshoe: a U of land around a lake. Bases at the top of each arm, corner expansions, a rich mine on the peninsula in the middle." },
  { "classic", "Horseshoe Classic", "Horseshoe Classic: smaller and quicker. Only three gold mines - yours, theirs, and the rich one on the peninsula across the contested beach." },
  { "temple", "Old Temple", "Old Temple: open ground, bases in opposite corners, a natural expansion beside each, and a walled plaza in the middle with a rich mine and a boss." },
  { "isles", "Shallow Isles", "Shallow Isles: two big islands joined by shallow fords; each has a base and an outer expansion, and a small island in the middle holds the rich mine." },
  { "glade", "Serpent Glade", "Serpent Glade: one long road winds through deep forest between the bases, past pocket expansions; a narrow hunters' trail cuts across." },
  { "wild", "Wildlands", "Wildlands: creeps everywhere. Eleven camps in forest clearings guard every expansion and the roads between them - lots of experience for heroes that hunt." },
  { "cross", "Crossroads 2v2", "Crossroads (2v2): you and an ally share the west against two enemies in the east. Each team is one race; heroes may repeat across players. Contested mines north, south and in the middle.", players = 4 },
}

function CM.generate(opts)
  local t = opts.template
  if t == "random" or not t then
    local list = { "horseshoe", "classic", "temple", "isles", "glade", "wild" }
    t = list[love.math.newRandomGenerator(opts.seed or os.time()):random(#list)]
  end
  if t == "horseshoe" then return CM.horseshoe(opts) end
  if t == "classic" then opts.classic = true; return CM.horseshoe(opts) end
  if t == "cross" then return CM.quad(opts) end
  return CM.carved(opts, t)
end

function CM.horseshoe(opts)
  local self = setmetatable({}, M)
  local classic = opts.classic
  local N = classic and 72 or (opts.size or 88)
  local w, h = N, N
  self.w, self.h = w, h
  self.T = D.TILE
  self.seed = opts.seed or os.time()
  self.craft = true
  self.template = classic and "classic" or "horseshoe"
  local rng = love.math.newRandomGenerator(self.seed)
  self.rng = rng

  local terrain, height = {}, {}
  self.wood = {}
  local armW = math.floor(N * 0.235)            -- each arm ~21 tiles wide
  local bottomTop = math.floor(N * 0.73)        -- the bottom strip starts here
  local jutHalf = math.floor(N * 0.1)
  local cx = (w - 1) / 2
  local jutTop = math.floor(N * 0.36)
  -- gentle wobble on the shorelines so it doesn't look ruled
  local ph1, ph2 = rng:random() * 6.28, rng:random() * 6.28
  local function wob(v, k) return math.floor(1.6 * math.sin(v * 0.21 + ph1 + k) + 1.1 * math.sin(v * 0.47 + ph2 + k * 2)) end

  for y = 0, h - 1 do
    for x = 0, w - 1 do
      -- mirror: build the left half, copy to the right
      local mx = x <= cx and x or (w - 1 - x)
      local i = y * w + x
      height[i] = 0.5
      local land = false
      local edge = math.min(mx, y, h - 1 - y)
      if mx < armW + wob(y, 0) and y >= 3 then land = true end
      if y >= bottomTop + wob(mx, 1) then land = true end
      -- the peninsula, with a rounded tip
      local jx = math.abs(x - cx)
      local tipY = jutTop + math.max(0, (jx - jutHalf * 0.4)) * 0.9
      if jx <= jutHalf + wob(y, 2) * 0.5 and y >= tipY then land = true end
      if edge < 2 then terrain[i] = M.ROCK
      elseif land then terrain[i] = M.LAND
      else terrain[i] = M.WATER end
    end
  end
  self.terrain, self.height = terrain, height
  self.waterLevel = 0.55

  -- key sites (left side; mirrored for the right)
  local baseX, baseY = math.floor(armW * 0.55), math.floor(N * 0.2)
  local mineL = { x = baseX - 1, y = baseY - 9 }
  local hallL = { x = baseX - 2, y = baseY - 1 }
  local centerMine = { x = math.floor(cx) - 1, y = jutTop + 3 }
  -- corner creep camps (small, for hero experience)
  local campL = { x = math.floor(armW * 0.5), y = math.floor(N * 0.84) }
  -- a corner expansion at the bottom of each arm, guarded by that camp
  local expL = { x = math.floor(armW * 0.35), y = math.floor(N * 0.75) }
  local midCamp = { x = math.floor(cx), y = jutTop + 8 }

  -- forests: the outer edge of each arm, the bottom edge, the top of each arm, a grove
  -- beside each base, and scattered copses that keep the lanes about 12 tiles wide
  local function setTree(x, y, amt)
    if x < 2 or y < 2 or x > w - 3 or y > h - 3 then return end
    local i = y * w + x
    if terrain[i] ~= M.LAND then return end
    terrain[i] = M.TREE
    self.wood[i] = amt or 100
  end
  local function both(x, y, amt) setTree(x, y, amt); setTree(w - 1 - x, y, amt) end
  for y = 3, h - 3 do
    local thick = 3 + (math.sin(y * 0.37 + ph1) > 0.4 and 1 or 0)
    for x = 2, 1 + thick do both(x, y) end
  end
  for x = 2, math.floor(cx) do
    local thick = 3 + (math.sin(x * 0.31 + ph2) > 0.5 and 1 or 0)
    for y = h - 2 - thick, h - 3 do both(x, y) end
  end
  for x = 2, armW + 2 do for y = 2, 5 do both(x, y) end end
  -- a thick grove right beside each base (the main wood line)
  for y = baseY - 4, baseY + 9 do
    for x = armW - 6, armW + 2 do
      if rng:random() < 0.92 then both(x, y) end
    end
  end
  -- copses along the arm and the bottom, never in the middle of the lane
  for _ = 1, 10 do
    local y = rng:random(math.floor(N * 0.38), math.floor(N * 0.68))
    local x = rng:random(armW - 6, armW)
    for dy = 0, rng:random(1, 3) do for dx = 0, rng:random(1, 3) do both(x + dx, y + dy) end end
  end
  for _ = 1, 8 do
    local x = rng:random(armW + 2, math.floor(cx) - jutHalf - 2)
    local y = h - 4 - rng:random(3, 5)
    for dy = 0, rng:random(0, 2) do for dx = 0, rng:random(1, 3) do both(x + dx, y + dy) end end
  end
  -- along both shores of the peninsula
  for y = jutTop + 10, bottomTop - 2 do
    if rng:random() < 0.6 then
      local x = math.floor(cx) - jutHalf + 1
      both(x, y); both(x + 1, y)
    end
  end

  -- clear the sites (mines, halls, camps) of trees and rock
  local function clear(x0, y0, x1, y1)
    for y = y0, y1 do for x = x0, x1 do
      for _, xx in ipairs({ x, w - 1 - x }) do
        local i = y * w + xx
        if xx >= 2 and y >= 2 and xx < w - 2 and y < h - 2 then
          if terrain[i] == M.TREE or terrain[i] == M.WATER then terrain[i] = M.LAND; self.wood[i] = nil end
        end
      end
    end end
  end
  clear(mineL.x - 2, mineL.y - 1, mineL.x + 4, hallL.y + 6)
  clear(hallL.x - 3, hallL.y - 2, hallL.x + 7, hallL.y + 8)
  clear(centerMine.x - 3, centerMine.y - 2, centerMine.x + 5, centerMine.y + 10)
  clear(campL.x - 3, campL.y - 3, campL.x + 3, campL.y + 3)
  if not classic then clear(expL.x - 2, expL.y - 2, expL.x + 9, expL.y + 9) end

  self.deposits, self.deposit, self.blocked = {}, {}, {}
  self.mines = {
    { x = mineL.x, y = mineL.y, gold = 9000, side = 1 },
    { x = w - 3 - mineL.x, y = mineL.y, gold = 9000, side = 2 },
    { x = centerMine.x, y = centerMine.y, gold = 12000, center = true },
  }
  if not classic then
    -- the full Horseshoe also has an expansion in each bottom corner (Classic has only three mines)
    self.mines[#self.mines + 1] = { x = expL.x, y = expL.y, gold = 6000, corner = 1 }
    self.mines[#self.mines + 1] = { x = w - 3 - expL.x, y = expL.y, gold = 6000, corner = 2 }
  end
  self.halls = { { x = hallL.x, y = hallL.y }, { x = w - 4 - hallL.x, y = hallL.y } }
  self.camps = {
    { x = campL.x, y = campL.y, kind = "small" },
    { x = w - 1 - campL.x, y = campL.y, kind = "small" },
    { x = midCamp.x, y = midCamp.y, kind = "big" },
  }
  -- hero start: just below the hall
  self.starts = {}
  local players = opts.players or { { ally = 1 }, { ally = 2 } }
  for t = 1, #players do
    local side = ((t - 1) % 2) + 1
    local hl = self.halls[side]
    self.starts[t] = { x = hl.x + 2, y = hl.y + 6, side = side }
  end
  self:labelComponents()
  return self
end

---------------------------------------------------------------------------
-- Carved maps: start from solid forest (or open water), carve clearings and roads, then drop
-- mines, halls and creep camps. Two-player maps are point-symmetric (180 degrees).

function CM.carved(opts, template)
  local self = setmetatable({}, M)
  local N = 96
  local w, h = N, N
  self.w, self.h = w, h
  self.T = D.TILE
  self.seed = opts.seed or os.time()
  self.craft = true
  self.template = template
  local rng = love.math.newRandomGenerator(self.seed)
  self.rng = rng
  local terrain, height = {}, {}
  self.wood = {}
  local water = template == "isles"
  for i = 0, w * h - 1 do
    height[i] = 0.5
    terrain[i] = water and M.WATER or 4
    if not water then self.wood[i] = 100 end
  end
  self.terrain, self.height = terrain, height
  self.waterLevel = 0.55
  local ph = rng:random() * 6.28
  local function rot(x, y) return w - 1 - x, h - 1 - y end
  local function set(x, y, t)
    if x < 2 or y < 2 or x > w - 3 or y > h - 3 then return end
    local i = y * w + x
    terrain[i] = t
    if t == 4 then self.wood[i] = 100 else self.wood[i] = nil end
  end
  -- a blob (both sides): radius r, with a wobbly edge
  local function blob(cx, cy, r, t)
    t = t or M.LAND
    for _, c in ipairs({ { cx, cy }, { rot(cx, cy) } }) do
      for y = math.floor(c[2] - r - 3), math.ceil(c[2] + r + 3) do
        for x = math.floor(c[1] - r - 3), math.ceil(c[1] + r + 3) do
          local a = math.atan2(y - c[2], x - c[1])
          local rr = r + 1.3 * math.sin(a * 3 + ph) + 0.8 * math.sin(a * 5 - ph)
          if (x - c[1]) ^ 2 + (y - c[2]) ^ 2 <= rr * rr then set(x, y, t) end
        end
      end
    end
  end
  -- a road through points (both sides), half-width hw
  local function road(pts, hw, t)
    for i = 1, #pts - 1 do
      local a, b = pts[i], pts[i + 1]
      local len = math.max(1, U.dist(a[1], a[2], b[1], b[2]))
      for k = 0, len, 0.5 do
        local f = k / len
        local x, y = a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
        local ww = hw + 0.8 * math.sin((x + y) * 0.3 + ph)
        blob(x, y, ww, t)
      end
    end
  end
  local mines, halls, camps = {}, {}, {}
  local function mine(x, y, gold, extra)
    local m = { x = x, y = y, gold = gold }
    for k, v in pairs(extra or {}) do m[k] = v end
    mines[#mines + 1] = m
    if not m.center then
      local rx, ry = rot(x, y)
      local m2 = { x = rx - 2, y = ry - 2, gold = gold }
      for k, v in pairs(extra or {}) do m2[k] = v end
      if m2.side then m2.side = 2 end
      mines[#mines + 1] = m2
    end
  end
  local function camp(x, y, kind, center)
    camps[#camps + 1] = { x = x, y = y, kind = kind }
    if not center then local rx, ry = rot(x, y); camps[#camps + 1] = { x = rx, y = ry, kind = kind } end
  end
  local c = (N - 1) / 2
  local q = N / 96
  local function P(fx, fy) return math.floor(fx * N + 0.5), math.floor(fy * N + 0.5) end

  local base, natural, nat2
  if template == "temple" then
    base = { P(0.2, 0.2) }
    natural = { P(0.47, 0.13) }
    nat2 = { P(0.13, 0.5) }
    blob(base[1], base[2], 12 * q)
    blob(natural[1], natural[2], 7 * q)
    blob(nat2[1], nat2[2], 6 * q)
    blob(c, c, 14 * q)
    road({ { base[1], base[2] }, { natural[1], natural[2] }, { c + 10 * q, c - 16 * q }, { c, c } }, 3.6 * q)
    road({ { base[1], base[2] }, { nat2[1], nat2[2] }, { c - 16 * q, c + 10 * q }, { c, c } }, 3.6 * q)
    road({ { base[1], base[2] }, { c - 6 * q, c - 6 * q } }, 3.2 * q)
    -- a rocky wall around the plaza with four gaps (paths cut it again below)
    for a = 0, 63 do
      local ang = a / 64 * math.pi * 2
      if math.abs(math.sin(ang * 2)) > 0.35 then
        local x, y = math.floor(c + math.cos(ang) * 15 * q + 0.5), math.floor(c + math.sin(ang) * 15 * q + 0.5)
        set(x, y, M.ROCK)
      end
    end
    -- side lanes around the plaza that link the two halves
    road({ { natural[1], natural[2] }, { P(0.8, 0.18) } }, 3 * q)
    mine(base[1] - 7, base[2] - 7, 9000, { side = 1 })
    mine(natural[1] - 1, natural[2] - 5, 5500)
    mine(nat2[1] - 5, nat2[2] - 1, 5500)
    mine(math.floor(c) - 1, math.floor(c) - 1, 12000, { center = true })
    camp(natural[1] + 3, natural[2] + 3, "small")
    camp(nat2[1] + 3, nat2[2] + 3, "small")
    camp(math.floor(c) + 4, math.floor(c) + 4, "big", true)
  elseif template == "isles" then
    base = { P(0.22, 0.3) }
    natural = { P(0.18, 0.72) }
    -- the west island
    blob(base[1], base[2], 14 * q)
    blob(natural[1], natural[2], 9 * q)
    road({ { base[1], base[2] }, { natural[1], natural[2] } }, 8 * q)
    -- the middle island and the fords (shallow, walkable)
    blob(c, c, 9 * q)
    road({ { base[1] + 8 * q, base[2] }, { P(0.5, 0.2) }, { P(0.75, 0.25) } }, 3 * q)
    road({ { natural[1], natural[2] }, { c - 6 * q, c + 4 * q } }, 2.6 * q)
    -- trees on the islands: groves along the shores
    for i = 0, w * h - 1 do
      local x, y = i % w, math.floor(i / w)
      if terrain[i] == M.LAND then
        local nearWater = false
        for dy = -2, 2 do for dx = -2, 2 do
          local j = (y + dy) * w + (x + dx)
          if terrain[j] == M.WATER then nearWater = true end
        end end
        if nearWater and rng:random() < 0.75 and U.dist(x, y, c, c) > 10 * q then set(x, y, 4) end
      end
    end
    mine(base[1] - 8, base[2] - 6, 9000, { side = 1 })
    mine(natural[1] - 5, natural[2] + 2, 6000)
    mine(math.floor(c) - 1, math.floor(c) - 1, 12000, { center = true })
    camp(natural[1] + 2, natural[2] - 4, "small")
    camp(math.floor(c) + 4, math.floor(c) + 3, "big", true)
  elseif template == "wild" then
    -- Wildlands: open-ish forest full of clearings, a creep camp in nearly every one
    base = { P(0.16, 0.18) }
    natural = { P(0.42, 0.12) }
    nat2 = { P(0.12, 0.46) }
    local glen1, glen2, glen3 = { P(0.32, 0.34) }, { P(0.62, 0.3) }, { P(0.26, 0.64) }
    blob(base[1], base[2], 11 * q)
    blob(natural[1], natural[2], 7 * q)
    blob(nat2[1], nat2[2], 7 * q)
    blob(glen1[1], glen1[2], 5 * q); blob(glen2[1], glen2[2], 5 * q); blob(glen3[1], glen3[2], 5.5 * q)
    blob(c, c, 11 * q)
    road({ { base[1], base[2] }, { natural[1], natural[2] }, { glen2[1], glen2[2] }, { c, c } }, 3.2 * q)
    road({ { base[1], base[2] }, { nat2[1], nat2[2] }, { glen3[1], glen3[2] }, { c, c } }, 3.2 * q)
    road({ { base[1], base[2] }, { glen1[1], glen1[2] }, { c, c } }, 2.8 * q)
    -- the long lanes that run past the enemy's third base
    road({ { natural[1], natural[2] }, { P(0.72, 0.14) }, { P(0.88, 0.54) } }, 2.6 * q)
    mine(base[1] - 6, base[2] - 7, 9000, { side = 1 })
    mine(natural[1] - 1, natural[2] - 5, 6000)
    mine(nat2[1] - 5, nat2[2] - 1, 6000)
    mine(math.floor(c) - 1, math.floor(c) - 1, 12000, { center = true })
    camp(natural[1] + 3, natural[2] + 3, "medium")
    camp(nat2[1] + 3, nat2[2] + 3, "medium")
    camp(glen1[1], glen1[2], "small")
    camp(glen2[1], glen2[2], "small")
    camp(glen3[1], glen3[2], "medium")
    camp(math.floor(c) + 4, math.floor(c) + 4, "big", true)
  else -- glade
    base = { P(0.15, 0.16) }
    natural = { P(0.18, 0.55) }
    blob(base[1], base[2], 11 * q)
    blob(natural[1], natural[2], 6 * q)
    blob(c, c, 9 * q)
    -- the serpent road: east, down, west, down... to the middle and on (mirrored half)
    road({ { base[1], base[2] }, { P(0.55, 0.18) }, { P(0.6, 0.33) }, { P(0.3, 0.36) }, { P(0.32, 0.47) }, { c, c } }, 3.4 * q)
    road({ { natural[1], natural[2] }, { P(0.32, 0.47) } }, 2.8 * q)
    -- the hunters' trail: narrow, straight across the forest
    road({ { base[1] + 6, base[2] + 6 }, { P(0.12, 0.85) }, { P(0.3, 0.88) } }, 1.6 * q)
    mine(base[1] - 6, base[2] - 7, 9000, { side = 1 })
    mine(natural[1] - 5, natural[2] - 1, 6000)
    mine(math.floor(c) - 1, math.floor(c) - 1, 12000, { center = true })
    camp(natural[1] + 2, natural[2] + 2, "small")
    camp(math.floor(c) + 4, math.floor(c) + 4, "big", true)
  end
  -- border
  for y = 0, h - 1 do for x = 0, w - 1 do
    if x < 2 or y < 2 or x > w - 3 or y > h - 3 then terrain[y * w + x] = M.ROCK; self.wood[y * w + x] = nil end
  end end
  -- clear room around every mine and the halls
  local function clear(x0, y0, x1, y1)
    for y = math.max(2, y0), math.min(h - 3, y1) do for x = math.max(2, x0), math.min(w - 3, x1) do
      if terrain[y * w + x] ~= M.LAND then terrain[y * w + x] = M.LAND; self.wood[y * w + x] = nil end
    end end
  end
  for _, m in ipairs(mines) do clear(m.x - 2, m.y - 2, m.x + 4, m.y + 4) end
  -- halls: four or five tiles from the main mine, toward the middle of the base clearing
  local hx, hy = math.floor(base[1] - 2), math.floor(base[2] - 2)
  halls[1] = { x = hx, y = hy }
  local rx, ry = rot(hx, hy)
  halls[2] = { x = rx - 3, y = ry - 3 }
  for _, hl in ipairs(halls) do clear(hl.x - 3, hl.y - 3, hl.x + 7, hl.y + 7) end
  for _, cp in ipairs(camps) do clear(cp.x - 3, cp.y - 3, cp.x + 3, cp.y + 3) end
  self.deposits, self.deposit, self.blocked = {}, {}, {}
  self.mines, self.halls, self.camps = mines, halls, camps
  self.starts = {}
  local players = opts.players or { { ally = 1 }, { ally = 2 } }
  for t = 1, #players do
    local side = ((t - 1) % 2) + 1
    local hl = halls[side]
    self.starts[t] = { x = hl.x + 2, y = hl.y + 6, side = side }
  end
  self:labelComponents()
  return self
end

---------------------------------------------------------------------------
-- Crossroads (2v2): four corner bases, mirrored both ways. The west pair (players 1 and 3)
-- face the east pair (2 and 4); each team shares an expansion on its own edge, and three
-- contested mines sit north, south and in the middle.
function CM.quad(opts)
  local self = setmetatable({}, M)
  local N = 112
  local w, h = N, N
  self.w, self.h = w, h
  self.T = D.TILE
  self.seed = opts.seed or os.time()
  self.craft = true
  self.template = "cross"
  local rng = love.math.newRandomGenerator(self.seed)
  self.rng = rng
  local terrain, height = {}, {}
  self.wood = {}
  for i = 0, w * h - 1 do height[i] = 0.5; terrain[i] = 4; self.wood[i] = 100 end
  self.terrain, self.height = terrain, height
  self.waterLevel = 0.55
  local ph = rng:random() * 6.28
  local function set(x, y, t)
    if x < 2 or y < 2 or x > w - 3 or y > h - 3 then return end
    local i = y * w + x
    terrain[i] = t
    if t == 4 then self.wood[i] = 100 else self.wood[i] = nil end
  end
  local function sym(x, y) return { { x, y }, { w - 1 - x, y }, { x, h - 1 - y }, { w - 1 - x, h - 1 - y } } end
  local function blob(cx, cy, r, t)
    t = t or M.LAND
    for _, c in ipairs(sym(cx, cy)) do
      for y = math.floor(c[2] - r - 3), math.ceil(c[2] + r + 3) do
        for x = math.floor(c[1] - r - 3), math.ceil(c[1] + r + 3) do
          local a = math.atan2(y - c[2], x - c[1])
          local rr = r + 1.3 * math.sin(a * 3 + ph) + 0.8 * math.sin(a * 5 - ph)
          if (x - c[1]) ^ 2 + (y - c[2]) ^ 2 <= rr * rr then set(x, y, t) end
        end
      end
    end
  end
  local function road(pts, hw)
    for i = 1, #pts - 1 do
      local a, b = pts[i], pts[i + 1]
      local len = math.max(1, U.dist(a[1], a[2], b[1], b[2]))
      for k = 0, len, 0.5 do
        local f = k / len
        local x, y = a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
        blob(x, y, hw + 0.8 * math.sin((x + y) * 0.3 + ph))
      end
    end
  end
  local function P(fx, fy) return math.floor(fx * N + 0.5), math.floor(fy * N + 0.5) end
  local c = (N - 1) / 2
  local bx, by = P(0.14, 0.15)
  local ex, ey = P(0.1, 0.5)       -- the team's shared expansion on its own edge
  local nx, ny = P(0.5, 0.12)      -- contested, north (and south)
  local gx, gy = P(0.3, 0.33)      -- a glade between your base and the middle
  blob(bx, by, 11)
  blob(ex, ey, 7)
  blob(nx, ny, 7)
  blob(gx, gy, 5)
  blob(c, c, 11)
  road({ { bx, by }, { ex, ey } }, 3.2)
  road({ { bx, by }, { nx, ny } }, 3.2)
  road({ { bx, by }, { gx, gy }, { c, c } }, 3)
  road({ { ex, ey }, { c - 12, c } }, 2.8)
  road({ { nx, ny }, { c, c - 12 } }, 2.8)
  -- border
  for y = 0, h - 1 do for x = 0, w - 1 do
    if x < 2 or y < 2 or x > w - 3 or y > h - 3 then terrain[y * w + x] = M.ROCK; self.wood[y * w + x] = nil end
  end end
  local mines, camps = {}, {}
  local function clear(x0, y0, x1, y1)
    for y = math.max(2, y0), math.min(h - 3, y1) do for x = math.max(2, x0), math.min(w - 3, x1) do
      if terrain[y * w + x] ~= M.LAND then terrain[y * w + x] = M.LAND; self.wood[y * w + x] = nil end
    end end
  end
  -- mines: a 3x3 footprint, so mirrored copies shift by two tiles
  local function mine4(x, y, gold)
    for _, p in ipairs({ { x, y }, { w - 3 - x, y }, { x, h - 3 - y }, { w - 3 - x, h - 3 - y } }) do
      mines[#mines + 1] = { x = p[1], y = p[2], gold = gold }
    end
  end
  mine4(bx - 7, by - 6, 9000)
  -- shared team expansions (one per side: west and east)
  mines[#mines + 1] = { x = ex - 6, y = math.floor(c) - 1, gold = 7000 }
  mines[#mines + 1] = { x = w - 3 - (ex - 6), y = math.floor(c) - 1, gold = 7000 }
  -- contested north and south, and the rich middle
  mines[#mines + 1] = { x = math.floor(c) - 1, y = ny - 5, gold = 7000 }
  mines[#mines + 1] = { x = math.floor(c) - 1, y = h - 3 - (ny - 5), gold = 7000 }
  mines[#mines + 1] = { x = math.floor(c) - 1, y = math.floor(c) - 1, gold = 14000, center = true }
  for _, p in ipairs(sym(gx, gy)) do camps[#camps + 1] = { x = p[1], y = p[2], kind = "small" } end
  camps[#camps + 1] = { x = ex + 3, y = math.floor(c) + 3, kind = "medium" }
  camps[#camps + 1] = { x = w - 1 - (ex + 3), y = math.floor(c) - 3, kind = "medium" }
  camps[#camps + 1] = { x = math.floor(c) + 3, y = ny + 3, kind = "medium" }
  camps[#camps + 1] = { x = math.floor(c) - 3, y = h - 1 - (ny + 3), kind = "medium" }
  camps[#camps + 1] = { x = math.floor(c) + 4, y = math.floor(c) + 4, kind = "big" }
  for _, m in ipairs(mines) do clear(m.x - 2, m.y - 2, m.x + 4, m.y + 4) end
  -- halls: top-left, top-right, bottom-left, bottom-right (4x4 footprint)
  local hx, hy = bx - 2, by - 2
  local halls = { { x = hx, y = hy }, { x = w - 4 - hx, y = hy }, { x = hx, y = h - 4 - hy }, { x = w - 4 - hx, y = h - 4 - hy } }
  for _, hl in ipairs(halls) do clear(hl.x - 3, hl.y - 3, hl.x + 7, hl.y + 7) end
  for _, cp in ipairs(camps) do clear(cp.x - 3, cp.y - 3, cp.x + 3, cp.y + 3) end
  self.deposits, self.deposit, self.blocked = {}, {}, {}
  self.mines, self.halls, self.camps = mines, halls, camps
  -- players 1 & 3 (west) against 2 & 4 (east)
  self.starts = {}
  local players = opts.players or { {}, {}, {}, {} }
  for t = 1, #players do
    local hl = halls[t]
    self.starts[t] = { x = hl.x + 2, y = hl.y + 6, side = t }
  end
  self:labelComponents()
  return self
end

-- a tree was felled: it becomes grass (the picture is drawn every frame, so only the
-- minimap needs repainting)
function M:fellTree(tx, ty)
  local i = ty * self.w + tx
  self.terrain[i] = M.LAND
  self.wood[i] = nil
  if self.mmData and self.minimap then
    local r, g, b = 0.31, 0.43, 0.25
    self.mmData:setPixel(tx, ty, r, g, b, 1)
    self.mmDirty = true
  end
  self.reachCache = nil
end

return CM
