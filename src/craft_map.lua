-- Commander Craft map: "the Horseshoe". A U of land around a lake - each player's base sits
-- at the top of one arm, the arms meet along the bottom, and a peninsula juts up from the
-- middle of the bottom to a rich gold mine guarded by creeps. Forests line the outer
-- edges (wood to chop). Mirror-symmetric left/right.
local D = require("src.defs")
local U = require("src.util")
local M = require("src.map")

local CM = {}
M.TREE = 4

function CM.generate(opts)
  local self = setmetatable({}, M)
  local N = opts.size or 88
  local w, h = N, N
  self.w, self.h = w, h
  self.T = D.TILE
  self.seed = opts.seed or os.time()
  self.craft = true
  self.template = "horseshoe"
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
  clear(expL.x - 2, expL.y - 2, expL.x + 9, expL.y + 9)

  self.deposits, self.deposit, self.blocked = {}, {}, {}
  self.mines = {
    { x = mineL.x, y = mineL.y, gold = 9000, side = 1 },
    { x = w - 3 - mineL.x, y = mineL.y, gold = 9000, side = 2 },
    { x = centerMine.x, y = centerMine.y, gold = 12000, center = true },
    { x = expL.x, y = expL.y, gold = 6000, corner = 1 },
    { x = w - 3 - expL.x, y = expL.y, gold = 6000, corner = 2 },
  }
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
