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
  local ringW = math.max(3, w * (0.02 + waterFrac * 0.1))
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
    -- an inlet on every side: a winding bay that brings the sea part-way inland
    local lots = waterFrac >= 0.4
    local depth = math.floor(w * (lots and 0.44 or (0.14 + waterFrac * 0.24)))
    local half = waterFrac >= 0.4 and 2.6 or (waterFrac >= 0.25 and 2.1 or 1.6)
    local function carve(cx, cy, r)
      for yy = math.floor(cy - r), math.ceil(cy + r) do
        for xx = math.floor(cx - r), math.ceil(cx + r) do
          if U.dist(xx, yy, cx, cy) <= r then
            for _, f in ipairs(self.syms) do
              local sx, sy = f(xx, yy)
              if sx >= 0 and sy >= 0 and sx < w and sy < h then
                local i = sy * w + sx
                terrain[i] = M.WATER
                height[i] = math.min(height[i], waterLevel - 0.02)
              end
            end
          end
        end
      end
    end
    local sides = four and { "left" } or { "left", "top" }
    -- wet maps get two long inlets per side, reaching deep into the map
    if lots then
      local more = {}
      for _, sd in ipairs(sides) do more[#more + 1] = { sd, 0.22 + rng:random() * 0.1 }; more[#more + 1] = { sd, 0.62 + rng:random() * 0.12 } end
      sides = more
    else
      for i, sd in ipairs(sides) do sides[i] = { sd, 0.35 + rng:random() * 0.3 } end
    end
    for _, sdef in ipairs(sides) do
      local side, along = sdef[1], sdef[2]
      local x, y, dx, dy
      if side == "left" then x, y, dx, dy = 0, along * h, 1, 0 else x, y, dx, dy = along * w, 0, 0, 1 end
      local phase = rng:random() * 6.28
      for step = 0, depth do
        local t = step / depth
        local wob = math.sin(phase + t * 5) * 0.9
        x, y = x + dx + dy * wob, y + dy + dx * wob
        local near = false
        for _, st in ipairs(self.starts) do
          for _, f in ipairs(self.syms) do
            local sx, sy = f(x, y)
            if U.dist(sx, sy, st.x, st.y) < 13 then near = true end
          end
        end
        if near then break end
        carve(x, y, half * (1 - t * 0.45))
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
---------------------------------------------------------------------------
-- Commander Arena map: two bases in opposite corners joined by three lanes
-- (top, middle, bottom), with rocky "jungle" between them. Point-symmetric.

local function polyLen(pts)
  local L = 0
  for i = 2, #pts do L = L + U.dist(pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2]) end
  return L
end

-- point (and direction) at fraction f along a polyline
local function polyAt(pts, f)
  local total = polyLen(pts)
  local want = total * f
  for i = 2, #pts do
    local a, b = pts[i - 1], pts[i]
    local seg = U.dist(a[1], a[2], b[1], b[2])
    if want <= seg or i == #pts then
      local t = seg > 0 and math.min(1, want / seg) or 0
      local dx, dy = (b[1] - a[1]) / math.max(seg, 1e-6), (b[2] - a[2]) / math.max(seg, 1e-6)
      return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, dx, dy
    end
    want = want - seg
  end
  return pts[#pts][1], pts[#pts][2], 0, 0
end
M.polyAt = polyAt

function M.generateArena(opts)
  local self = setmetatable({}, M)
  local w = opts.size or 80
  local h = w
  self.w, self.h = w, h
  self.T = D.TILE
  self.seed = opts.seed or os.time()
  self.arena = true
  local rng = love.math.newRandomGenerator(self.seed)
  self.rng = rng
  self.syms = {
    function(x, y) return x, y end,
    function(x, y) return w - 1 - x, h - 1 - y end,
  }
  local n1, n2 = makeNoise(rng, 64), makeNoise(rng, 64)
  local ox, oy = rng:random() * 50, rng:random() * 50
  local function raw(x, y)
    local s = 1 / (w / 9)
    return n1(ox + x * s, oy + y * s) * 0.65 + n2(ox + x * s * 2.3, oy + y * s * 2.3) * 0.35
  end
  local A = { math.floor(w * 0.11), math.floor(h * 0.89) }
  local B = { w - 1 - A[1], h - 1 - A[2] }
  local lanes = {
    top = { A, { A[1], math.floor(h * 0.11) }, { B[1], B[2] } },
    mid = { A, B },
    bot = { A, { math.floor(w * 0.89), A[2] }, { B[1], B[2] } },
  }
  -- the bends of the side lanes are pulled in a little so the corners aren't hugging the edge
  lanes.top[2] = { math.floor(w * 0.11), math.floor(h * 0.11) }
  lanes.bot[2] = { math.floor(w * 0.89), math.floor(h * 0.89) }
  self.lanes = lanes

  local height, terrain = {}, {}
  -- distance from (x,y) to the nearest lane centerline, in tiles
  local function laneDist(x, y)
    local best = math.huge
    for _, pts in pairs(lanes) do
      for i = 2, #pts do
        local ax, ay, bx, by = pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2]
        local vx, vy = bx - ax, by - ay
        local L2 = vx * vx + vy * vy
        local t = L2 > 0 and math.max(0, math.min(1, ((x - ax) * vx + (y - ay) * vy) / L2)) or 0
        best = math.min(best, U.dist(x, y, ax + vx * t, ay + vy * t))
      end
    end
    return best
  end
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local v = (raw(x, y) + raw(w - 1 - x, h - 1 - y)) / 2
      v = 0.5 + (v - 0.5) * 1.6
      local i = y * w + x
      height[i] = v
      local edge = math.min(x, y, w - 1 - x, h - 1 - y)
      local ld = laneDist(x, y)
      local base = math.min(U.dist(x, y, A[1], A[2]), U.dist(x, y, B[1], B[2]))
      if edge < 2 then terrain[i] = M.ROCK
      elseif ld <= 2.6 or base <= 9 then terrain[i] = M.LAND
      elseif v > 0.6 then terrain[i] = M.ROCK
      elseif v > 0.52 then terrain[i] = M.HILL
      else terrain[i] = M.LAND end
    end
  end
  self.height, self.terrain = height, terrain
  self.waterLevel = -1
  self.deposits, self.deposit, self.blocked = {}, {}, {}

  -- structures: per side, an outer and an inner tower on each lane, and the Core
  self.towers = {}
  local tiers = { { "outer", 0.36 }, { "inner", 0.2 } }
  for lane, pts in pairs(lanes) do
    for _, tier in ipairs(tiers) do
      local x, y, dx, dy = polyAt(pts, tier[2])
      -- set the tower beside the lane, not in it
      local px, py = math.floor(x - dy * 3 + 0.5), math.floor(y + dx * 3 + 0.5)
      self.towers[#self.towers + 1] = { side = 1, lane = lane, tier = tier[1], x = px, y = py }
      self.towers[#self.towers + 1] = { side = 2, lane = lane, tier = tier[1], x = w - 1 - px, y = h - 1 - py }
    end
  end
  for _, t in ipairs(self.towers) do
    for yy = t.y - 2, t.y + 2 do
      for xx = t.x - 2, t.x + 2 do
        if self:inBounds(xx, yy) and math.min(xx, yy, w - 1 - xx, h - 1 - yy) >= 2 then terrain[yy * w + xx] = M.LAND end
      end
    end
  end
  self.cores = { { x = A[1], y = A[2] }, { x = B[1], y = B[2] } }

  -- start spots around each Core; player t uses side (1 or 2) by alliance
  local spots = {}
  for side = 1, 2 do
    spots[side] = {}
    local c = self.cores[side]
    local dir = side == 1 and 1 or -1
    for k, off in ipairs({ { 4, -4 }, { 6, -1 }, { 1, -6 } }) do
      spots[side][k] = { x = c.x + off[1] * dir, y = c.y + off[2] * dir }
    end
  end
  self.starts = {}
  local players = opts.players or { { ally = 1 }, { ally = 2 } }
  local used = { 0, 0 }
  local ally1 = players[1].ally or 1
  for t, p in ipairs(players) do
    local side = (p.ally or t) == ally1 and 1 or 2
    used[side] = used[side] + 1
    self.starts[t] = spots[side][math.min(3, used[side])]
    self.starts[t].side = side
  end
  self:labelComponents()
  return self
end

-- Mirror the whole map left-to-right (used to vary which corner you start in)
function M:flipX()
  local w, h = self.w, self.h
  local function flipArr(a)
    if not a then return end
    local out = {}
    for y = 0, h - 1 do
      for x = 0, w - 1 do out[y * w + (w - 1 - x)] = a[y * w + x] end
    end
    for k, v in pairs(out) do a[k] = v end
  end
  flipArr(self.terrain)
  flipArr(self.height)
  flipArr(self.shoreDist)
  for _, d in ipairs(self.deposits) do d.x = w - 1 - d.x end
  self.deposit = {}
  for _, d in ipairs(self.deposits) do self.deposit[d.y * w + d.x] = d end
  for _, st in ipairs(self.starts) do st.x = w - 1 - st.x end
  if self.syms then
    local old = self.syms
    -- symmetries conjugated by the flip still map the flipped map onto itself
    local new = {}
    for i, f in ipairs(old) do
      new[i] = function(x, y) local fx, fy = f(w - 1 - x, y); return w - 1 - fx, fy end
    end
    self.syms = new
  end
  self:labelComponents()
end

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
  local function add(x, y, rich)
    for _, f in ipairs(syms) do
      local sx, sy = f(x, y)
      deps[#deps + 1] = { x = sx, y = sy, rich = rich }
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
  -- rich land deposits around the middle of the map: worth fighting over
  local cx, cy = math.floor(w / 2), math.floor(h / 2)
  local richWant, richN = #syms == 2 and 2 or 1, 0
  tries = 0
  while richN < richWant and tries < 800 do
    tries = tries + 1
    local r = 2 + rng:random() * w * 0.09
    local a = rng:random() * math.pi * 2
    local x, y = math.floor(cx + math.cos(a) * r + 0.5), math.floor(cy + math.sin(a) * r + 0.5)
    if okAll(x, y) then add(x, y, true); richN = richN + 1 end
  end
  -- scattered deposits: scarcer than they used to be, and thinner near the bases so
  -- the metal that matters is out in the contested parts of the map
  local target = math.floor(w * h / 380)
  local far = w * 0.38
  tries = 0
  while #deps < target * 2 and tries < 8000 do
    tries = tries + 1
    local x, y = rng:random(2, w - 3), rng:random(2, h - 3)
    local dmin = math.huge
    for _, st in ipairs(self.starts) do dmin = math.min(dmin, U.dist(x, y, st.x, st.y)) end
    local weight = math.max(0.15, math.min(1, (dmin - 8) / far))
    if rng:random() < weight and okAll(x, y) then
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
  self:placeSeaDeposits(rng)
end

-- Rich offshore deposits: worth more than land ones, and only reachable by sea
-- (a few sit close enough to the shore for land constructors). Whoever rules the
-- sea gets this income, so even an inland base has a reason to fight for the water.
function M:placeSeaDeposits(rng)
  local w, h = self.w, self.h
  -- distance (in tiles) from each water tile to the nearest land
  local dist, q, qh = {}, {}, 1
  for i = 0, w * h - 1 do
    if self.terrain[i] ~= M.WATER then dist[i] = 0; q[#q + 1] = i end
  end
  while qh <= #q do
    local i = q[qh]; qh = qh + 1
    local x, y = i % w, math.floor(i / w)
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      local nx, ny = x + d[1], y + d[2]
      if nx >= 0 and ny >= 0 and nx < w and ny < h then
        local j = ny * w + nx
        if not dist[j] then dist[j] = dist[i] + 1; q[#q + 1] = j end
      end
    end
  end
  self.shoreDist = dist
  local water = 0
  for i = 0, w * h - 1 do if self.terrain[i] == M.WATER then water = water + 1 end end
  local deps = self.deposits
  local syms = self.syms
  local function ok(x, y)
    if x < 3 or y < 3 or x >= w - 3 or y >= h - 3 then return false end
    local i = y * w + x
    if self.terrain[i] ~= M.WATER or dist[i] < 1 or dist[i] > 7 then return false end
    for _, d in ipairs(deps) do
      if math.abs(d.x - x) + math.abs(d.y - y) < 3 then return false end
    end
    return true
  end
  local function okAll(x, y)
    for _, f in ipairs(syms) do if not ok(f(x, y)) then return false end end
    for i = 2, #syms do
      local sx, sy = syms[i](x, y)
      if math.abs(sx - x) + math.abs(sy - y) < 6 then return false end
    end
    return true
  end
  local function add(x, y)
    for _, f in ipairs(syms) do
      local sx, sy = f(x, y)
      deps[#deps + 1] = { x = sx, y = sy, sea = true, shore = dist[sy * w + sx] }
    end
  end
  local target = math.floor(water / 420 / #syms)  -- fields per symmetric copy
  local fields, tries = 0, 0
  while fields < target and tries < 4000 do
    tries = tries + 1
    local x, y = rng:random(3, w - 4), rng:random(3, h - 4)
    if okAll(x, y) then
      add(x, y); fields = fields + 1
      -- rich fields come in clusters of 2-3
      for _ = 1, rng:random(1, 2) do
        for _ = 1, 12 do
          local bx, by = x + rng:random(-3, 3), y + rng:random(-3, 3)
          if okAll(bx, by) then add(bx, by); break end
        end
      end
    end
  end
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
