-- Procedural, point-symmetric map: water, land, hills, rock, metal deposits.
local D = require("src.defs")
local U = require("src.util")

local M = {}
M.__index = M

M.WATER, M.LAND, M.HILL, M.ROCK = 0, 1, 2, 3

local function makeNoise(rng, size)
  local lat = {}
  for i = 0, (size + 2) * (size + 2) do lat[i] = rng:random() end
  local stride = size + 2
  local function smooth(t) return t * t * (3 - 2 * t) end
  return function(x, y)
    local xi, yi = math.floor(x), math.floor(y)
    local xf, yf = smooth(x - xi), smooth(y - yi)
    xi, yi = xi % size, yi % size
    local a = lat[yi * stride + xi]
    local b = lat[yi * stride + xi + 1]
    local c = lat[(yi + 1) * stride + xi]
    local d = lat[(yi + 1) * stride + xi + 1]
    return U.lerp(U.lerp(a, b, xf), U.lerp(c, d, xf), yf)
  end
end

function M.generate(opts)
  local self = setmetatable({}, M)
  local w = opts.size or 96
  local h = w
  self.w, self.h = w, h
  self.T = D.TILE
  self.seed = opts.seed or os.time()
  local rng = love.math.newRandomGenerator(self.seed)
  self.rng = rng

  local waterFrac = opts.water or 0.33
  local n1 = makeNoise(rng, 64)
  local n2 = makeNoise(rng, 64)
  local n3 = makeNoise(rng, 64)
  local ox, oy = rng:random() * 50, rng:random() * 50

  local function raw(x, y)
    local s = 1 / (w / 6)
    local v = n1(ox + x * s, oy + y * s) * 0.6
           + n2(ox + x * s * 2.1, oy + y * s * 2.1) * 0.28
           + n3(ox + x * s * 4.3, oy + y * s * 4.3) * 0.12
    return v
  end

  -- Symmetry: 2 players = 180-degree rotation; 3-4 players = 4-way rotation (a base per corner)
  local np = opts.mapPlayers or (type(opts.players) == "table" and #opts.players or (opts.players or 2))
  local four = np > 2
  self.four = four
  local syms
  if four then
    syms = {
      function(x, y) return x, y end,
      function(x, y) return w - 1 - x, h - 1 - y end,   -- 180
      function(x, y) return w - 1 - y, x end,           -- 90
      function(x, y) return y, h - 1 - x end,           -- 270
    }
  else
    syms = {
      function(x, y) return x, y end,
      function(x, y) return w - 1 - x, h - 1 - y end,
    }
  end
  self.syms = syms

  -- Start positions: player 1 bottom-left, 2 top-right, 3 top-left, 4 bottom-right
  local sx1, sy1 = math.floor(w * 0.18), math.floor(h * 0.80)
  self.starts = {}
  for i, f in ipairs(syms) do
    local x, y = f(sx1, sy1)
    self.starts[i] = { x = x, y = y }
  end

  -- Outer ocean: most maps are ringed by sea so navies always have somewhere to fight.
  -- Wetter maps get a wider, more ragged coast. Dry maps sometimes have no ring at all.
  local ring = opts.ring
  if ring == nil then ring = waterFrac >= 0.25 or rng:random() < 0.75 end
  self.ring = ring
  local ringW = math.max(3, w * (0.02 + waterFrac * 0.07))
  local function edgeDrop(x, y)
    if not ring then return 0 end
    local e = math.min(x, y, w - 1 - x, h - 1 - y)
    if e >= ringW * 1.8 then return 0 end
    local k = 1 - e / (ringW * 1.8)
    return k * k * 0.55
  end

  -- Symmetric height field
  local height = {}
  local vals = {}
  local ns = #syms
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local v = 0
      for _, f in ipairs(syms) do v = v + raw(f(x, y)) end
      v = v / ns
      -- 4-way averaging flattens the terrain; restore some contrast
      if four then v = 0.5 + (v - 0.5) * 1.5 end
      v = v - edgeDrop(x, y)
      -- raise ground around the starts so bases sit on land
      for _, s in ipairs(self.starts) do
        local d = U.dist(x, y, s.x, s.y)
        if d < 11 then v = v + (11 - d) / 11 * 0.35 end
      end
      height[y * w + x] = v
      vals[#vals + 1] = v
    end
  end
  table.sort(vals)
  local waterLevel = vals[math.max(1, math.floor(#vals * waterFrac))]
  local hillLevel = vals[math.floor(#vals * 0.86)]
  local rockLevel = vals[math.floor(#vals * 0.965)]

  local terrain = {}
  for i = 0, w * h - 1 do
    local v = height[i]
    if v <= waterLevel then terrain[i] = M.WATER
    elseif v >= rockLevel then terrain[i] = M.ROCK
    elseif v >= hillLevel then terrain[i] = M.HILL
    else terrain[i] = M.LAND end
  end
  -- Keep start areas clear of rock
  for _, s in ipairs(self.starts) do
    for y = s.y - 6, s.y + 6 do
      for x = s.x - 6, s.x + 6 do
        if x >= 0 and y >= 0 and x < w and y < h and U.dist(x, y, s.x, s.y) <= 6 then
          terrain[y * w + x] = M.LAND
        end
      end
    end
  end
  self.height = height
  self.terrain = terrain
  self.waterLevel = waterLevel
  if ring then
    -- the very edge is always open sea, so the ring is one connected body of water
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        if math.min(x, y, w - 1 - x, h - 1 - y) < 2 then terrain[y * w + x] = M.WATER end
      end
    end
  end

  -- Lakes big enough to matter get a channel cut out to the sea (symmetrically)
  self:labelComponents()
  self:channelLakes()
  self:ensureLandConnection()
  -- No dead lakes: water that can't reach the outer sea becomes land, so a shipyard
  -- is never stranded somewhere its ships can't fight
  self:labelComponents()
  self:fillLakes()
  self:placeDeposits(rng)

  self.blocked = {}     -- tile index -> entity occupying it
  self.deposit = {}     -- tile index -> true
  for _, dpos in ipairs(self.deposits) do self.deposit[dpos.y * w + dpos.x] = dpos end
  self:labelComponents()

  return self
end

-- Connected regions of land and of water (ignoring buildings), for quick reachability checks
function M:labelComponents()
  local w, h = self.w, self.h
  self.comp = { land = {}, sea = {} }
  local function isLayer(layer, t)
    if layer == "land" then return t == M.LAND or t == M.HILL end
    return t == M.WATER
  end
  for _, layer in ipairs({ "land", "sea" }) do
    local lab = self.comp[layer]
    local id = 0
    for i = 0, w * h - 1 do
      if not lab[i] and isLayer(layer, self.terrain[i]) then
        id = id + 1
        lab[i] = id
        local stack = { i }
        while #stack > 0 do
          local c = table.remove(stack)
          local cx, cy = c % w, math.floor(c / w)
          -- 8-neighbour connectivity matches the pathfinder (diagonals need both sides open)
          for dy = -1, 1 do
            for dx = -1, 1 do
              if dx ~= 0 or dy ~= 0 then
                local nx, ny = cx + dx, cy + dy
                if nx >= 0 and ny >= 0 and nx < w and ny < h then
                  local j = ny * w + nx
                  if not lab[j] and isLayer(layer, self.terrain[j]) then
                    local ok = true
                    if dx ~= 0 and dy ~= 0 then
                      ok = isLayer(layer, self.terrain[cy * w + nx]) and isLayer(layer, self.terrain[ny * w + cx])
                    end
                    if ok then
                      lab[j] = id
                      stack[#stack + 1] = j
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

function M:compAt(layer, tx, ty)
  if not self:inBounds(tx, ty) then return nil end
  return self.comp[layer][ty * self.w + tx]
end

-- Can something on `layer` at world (ax,ay) get within `reach` of world (bx,by)?
function M:canReach(layer, ax, ay, bx, by, reach)
  local T = self.T
  local atx, aty = math.floor(ax / T), math.floor(ay / T)
  local c = self:compAt(layer, atx, aty)
  if not c then
    -- standing on a blocked/odd tile: look at neighbours
    for dy = -1, 1 do for dx = -1, 1 do
      c = c or self:compAt(layer, atx + dx, aty + dy)
    end end
    if not c then return true end
  end
  local btx, bty = math.floor(bx / T), math.floor(by / T)
  if self:compAt(layer, btx, bty) == c then return true end
  local r = math.max(1, math.floor((reach or 0) / T))
  self.reachCache = self.reachCache or {}
  local key = layer .. c .. ":" .. (bty * self.w + btx) .. ":" .. r
  local cached = self.reachCache[key]
  if cached ~= nil then return cached end
  local res = false
  for dy = -r, r do
    for dx = -r, r do
      if dx * dx + dy * dy <= r * r and self:compAt(layer, btx + dx, bty + dy) == c then res = true; break end
    end
    if res then break end
  end
  self.reachCache[key] = res
  return res
end

function M:idx(x, y) return y * self.w + x end
function M:inBounds(x, y) return x >= 0 and y >= 0 and x < self.w and y < self.h end
function M:tileAt(wx, wy) return math.floor(wx / self.T), math.floor(wy / self.T) end
function M:center(tx, ty) return (tx + 0.5) * self.T, (ty + 0.5) * self.T end
function M:terrainAt(tx, ty)
  if not self:inBounds(tx, ty) then return M.ROCK end
  return self.terrain[ty * self.w + tx]
end

-- passability for a movement layer ("land" or "sea")
function M:passable(layer, tx, ty)
  if not self:inBounds(tx, ty) then return false end
  local i = ty * self.w + tx
  if self.blocked[i] then return false end
  local t = self.terrain[i]
  if layer == "land" then return t == M.LAND or t == M.HILL end
  if layer == "sea" then return t == M.WATER end
  return true
end

function M:landFloodFrom(x, y)
  local w, h = self.w, self.h
  local seen = {}
  local stack = { y * w + x }
  seen[y * w + x] = true
  while #stack > 0 do
    local i = table.remove(stack)
    local cx, cy = i % w, math.floor(i / w)
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      local nx, ny = cx + d[1], cy + d[2]
      if nx >= 0 and ny >= 0 and nx < w and ny < h then
        local j = ny * w + nx
        local t = self.terrain[j]
        if not seen[j] and (t == M.LAND or t == M.HILL) then
          seen[j] = true
          stack[#stack + 1] = j
        end
      end
    end
  end
  return seen
end

-- Make sure land units can walk between the two bases
function M:ensureLandConnection()
  local a = self.starts[1]
  for k = 2, #self.starts do
    local b = self.starts[k]
    local seen = self:landFloodFrom(a.x, a.y)
    if not seen[b.y * self.w + b.x] then
      -- carve a winding bridge from start 1 to start k, copied to every symmetric position
      local steps = 200
      for i = 0, steps do
        local t = i / steps
        local x = U.lerp(a.x, b.x, t) + math.sin(t * math.pi * 2) * self.w * 0.08
        local y = U.lerp(a.y, b.y, t)
        for dy = -1, 1 do
          for dx = -1, 1 do
            local tx, ty = math.floor(x + dx), math.floor(y + dy)
            for _, f in ipairs(self.syms) do
              local sx, sy = f(tx, ty)
              if self:inBounds(sx, sy) then self.terrain[sy * self.w + sx] = M.LAND end
            end
          end
        end
      end
    end
  end
end

function M:channelLakes()
  local w, h = self.w, self.h
  local lab = self.comp.sea
  local size, edge = {}, {}
  for i = 0, w * h - 1 do
    local c = lab[i]
    if c then
      size[c] = (size[c] or 0) + 1
      local x, y = i % w, math.floor(i / w)
      if x == 0 or y == 0 or x == w - 1 or y == h - 1 then edge[c] = true end
    end
  end
  if not next(edge) then return end
  -- Dijkstra out from the sea: cheap through low ground, so channels wind like rivers
  local dist, par, steps = {}, {}, {}
  local heap = {}
  local function push(c, i)
    heap[#heap + 1] = { c, i }
    local k = #heap
    while k > 1 do
      local p = math.floor(k / 2)
      if heap[p][1] <= heap[k][1] then break end
      heap[p], heap[k] = heap[k], heap[p]; k = p
    end
  end
  local function pop()
    local top = heap[1]
    local last = table.remove(heap)
    if #heap > 0 then
      heap[1] = last
      local k = 1
      while true do
        local l, r, m = 2 * k, 2 * k + 1, k
        if heap[l] and heap[l][1] < heap[m][1] then m = l end
        if heap[r] and heap[r][1] < heap[m][1] then m = r end
        if m == k then break end
        heap[m], heap[k] = heap[k], heap[m]; k = m
      end
    end
    return top
  end
  for i = 0, w * h - 1 do
    if lab[i] and edge[lab[i]] then dist[i] = 0; steps[i] = 0; push(0, i) end
  end
  local wl = self.waterLevel
  while #heap > 0 do
    local top = pop()
    local c, i = top[1], top[2]
    if c <= dist[i] then
      local x, y = i % w, math.floor(i / w)
      for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local nx, ny = x + d[1], y + d[2]
        if nx >= 0 and ny >= 0 and nx < w and ny < h then
          local j = ny * w + nx
          local nc = c + 1 + math.max(0, self.height[j] - wl) * 60
          if not dist[j] or nc < dist[j] then
            dist[j] = nc; par[j] = i; steps[j] = steps[i] + 1; push(nc, j)
          end
        end
      end
    end
  end
  local minSize = math.max(30, w * h * 0.004)
  local best = {}
  for i = 0, w * h - 1 do
    local c = lab[i]
    if c and not edge[c] and size[c] >= minSize then
      if not best[c] or dist[i] < dist[best[c]] then best[c] = i end
    end
  end
  local maxLen = w * 0.14
  for _, start in pairs(best) do
    local i = start
    if steps[i] > maxLen then i = nil end -- too far inland: it will be filled instead
    while i and dist[i] > 0 do
      local x, y = i % w, math.floor(i / w)
      for _, o in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 } }) do
        for _, f in ipairs(self.syms) do
          local sx, sy = f(x + o[1], y + o[2])
          if self:inBounds(sx, sy) then
            local k = sy * w + sx
            if self.terrain[k] ~= M.WATER then
              self.terrain[k] = M.WATER
              self.height[k] = math.min(self.height[k], self.waterLevel - 0.01)
            end
          end
        end
      end
      i = par[i]
    end
  end
end

function M:fillLakes()
  local w, h = self.w, self.h
  local lab = self.comp.sea
  local size, edge = {}, {}
  for i = 0, w * h - 1 do
    local c = lab[i]
    if c then
      size[c] = (size[c] or 0) + 1
      local x, y = i % w, math.floor(i / w)
      if x == 0 or y == 0 or x == w - 1 or y == h - 1 then edge[c] = true end
    end
  end
  -- the sea that counts: the edge-touching body, or failing that the largest one if it is big
  local keep = {}
  local anyEdge = next(edge) ~= nil
  if anyEdge then keep = edge
  else
    local best, bs = nil, 0
    for c, n in pairs(size) do if n > bs then best, bs = c, n end end
    if best and bs > w * h * 0.12 then keep[best] = true end
  end
  local filled = 0
  for i = 0, w * h - 1 do
    local c = lab[i]
    if c and not keep[c] then
      self.terrain[i] = M.LAND
      self.height[i] = math.max(self.height[i], self.waterLevel + 0.01)
      filled = filled + 1
    end
  end
  self.lakesFilled = filled
end

function M:placeDeposits(rng)
  local w, h = self.w, self.h
  local deps = {}
  local taken = {}
  local function ok(x, y)
    if x < 2 or y < 2 or x >= w - 2 or y >= h - 2 then return false end
    if self.terrain[y * w + x] ~= M.LAND then return false end
    for _, d in ipairs(deps) do
      if math.abs(d.x - x) + math.abs(d.y - y) < 3 then return false end
    end
    return true
  end
  local syms = self.syms
  local function okAll(x, y)
    for _, f in ipairs(syms) do
      if not ok(f(x, y)) then return false end
    end
    -- the symmetric copies must not crowd each other
    for i = 2, #syms do
      local sx, sy = syms[i](x, y)
      if math.abs(sx - x) + math.abs(sy - y) < 4 then return false end
    end
    return true
  end
  local function add(x, y)
    for _, f in ipairs(syms) do
      local sx, sy = f(x, y)
      deps[#deps + 1] = { x = sx, y = sy }
    end
  end
  -- near-base deposits
  local s = self.starts[1]
  local placed, tries = 0, 0
  while placed < 5 and tries < 500 do
    tries = tries + 1
    local ang = rng:random() * math.pi * 2
    local r = 3 + rng:random() * 5
    local x, y = math.floor(s.x + math.cos(ang) * r + 0.5), math.floor(s.y + math.sin(ang) * r + 0.5)
    if okAll(x, y) and U.dist(x, y, s.x, s.y) > 2.5 then
      add(x, y); placed = placed + 1
    end
  end
  -- scattered deposits, often in small clusters
  local target = math.floor(w * h / 260)
  tries = 0
  while #deps < target * 2 and tries < 5000 do
    tries = tries + 1
    local x, y = rng:random(2, w - 3), rng:random(2, h - 3)
    if okAll(x, y) then
      add(x, y)
      -- buddy deposit nearby
      if rng:random() < 0.6 then
        for _ = 1, 10 do
          local bx, by = x + rng:random(-3, 3), y + rng:random(-3, 3)
          if okAll(bx, by) then add(bx, by); break end
        end
      end
    end
  end
  self.deposits = deps
end

-- Nearest tile that satisfies pred, searching outward from (tx, ty)
function M:nearestTile(tx, ty, pred, maxR)
  maxR = maxR or 30
  if pred(tx, ty) then return tx, ty end
  for r = 1, maxR do
    local best, bd
    for dy = -r, r do
      for dx = -r, r do
        if math.abs(dx) == r or math.abs(dy) == r then
          local x, y = tx + dx, ty + dy
          if self:inBounds(x, y) and pred(x, y) then
            local d = dx * dx + dy * dy
            if not bd or d < bd then best, bd = { x, y }, d end
          end
        end
      end
    end
    if best then return best[1], best[2] end
  end
  return nil
end

-- Pre-render the terrain to a small image (8 px per tile), drawn scaled up
function M:buildImages()
  local P = 8
  local w, h = self.w, self.h
  local id = love.image.newImageData(w * P, h * P)
  local rng = love.math.newRandomGenerator(self.seed + 7)
  for ty = 0, h - 1 do
    for tx = 0, w - 1 do
      local i = ty * w + tx
      local t = self.terrain[i]
      local hv = self.height[i]
      local r, g, b
      if t == M.WATER then
        local depth = U.clamp((self.waterLevel - hv) * 6, 0, 1)
        r, g, b = 0.10 - depth * 0.05, 0.28 - depth * 0.12, 0.48 - depth * 0.12
      elseif t == M.LAND then
        local k = U.clamp((hv - self.waterLevel) * 3, 0, 1)
        r, g, b = 0.30 + k * 0.06, 0.42 + k * 0.03, 0.24 + k * 0.02
      elseif t == M.HILL then
        r, g, b = 0.44, 0.42, 0.30
      else
        r, g, b = 0.36, 0.34, 0.33
      end
      for py = 0, P - 1 do
        for px = 0, P - 1 do
          local j = (rng:random() - 0.5) * 0.04
          id:setPixel(tx * P + px, ty * P + py, r + j, g + j, b + j, 1)
        end
      end
      -- shoreline highlight
      if t ~= M.WATER then
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
          if self:terrainAt(tx + d[1], ty + d[2]) == M.WATER then
            for k = 0, P - 1 do
              local px = d[1] == 1 and P - 1 or (d[1] == -1 and 0 or k)
              local py = d[2] == 1 and P - 1 or (d[2] == -1 and 0 or k)
              id:setPixel(tx * P + px, ty * P + py, 0.62, 0.58, 0.40, 1)
            end
          end
        end
      end
      if t == M.ROCK then
        for _ = 1, 6 do
          local px, py = rng:random(0, P - 1), rng:random(0, P - 1)
          id:setPixel(tx * P + px, ty * P + py, 0.22, 0.21, 0.21, 1)
        end
      end
    end
  end
  self.image = love.graphics.newImage(id)
  self.image:setFilter("linear", "nearest")
  self.imagePx = P

  -- minimap image: 1 px per tile
  local mm = love.image.newImageData(w, h)
  for ty = 0, h - 1 do
    for tx = 0, w - 1 do
      local r, g, b = id:getPixel(tx * P + 4, ty * P + 4)
      mm:setPixel(tx, ty, r, g, b, 1)
    end
  end
  self.minimap = love.graphics.newImage(mm)
  self.minimap:setFilter("linear", "linear")
end

return M
