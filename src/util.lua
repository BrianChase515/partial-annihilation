local U = {}

function U.dist(ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  return math.sqrt(dx * dx + dy * dy)
end

function U.dist2(ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  return dx * dx + dy * dy
end

function U.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function U.lerp(a, b, t) return a + (b - a) * t end

function U.norm(x, y)
  local l = math.sqrt(x * x + y * y)
  if l < 1e-6 then return 0, 0, 0 end
  return x / l, y / l, l
end

function U.shuffle(t, rng)
  for i = #t, 2, -1 do
    local j = rng:random(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

function U.weightedPick(rng, weights)
  local total = 0
  for _, w in pairs(weights) do total = total + w end
  if total <= 0 then return nil end
  local r = rng:random() * total
  for k, w in pairs(weights) do
    r = r - w
    if r <= 0 then return k end
  end
  return next(weights)
end

-- Binary min-heap keyed by f
local Heap = {}
Heap.__index = Heap
function U.newHeap() return setmetatable({ n = 0, k = {}, v = {} }, Heap) end
function Heap:push(val, key)
  local n = self.n + 1
  self.n = n
  local k, v = self.k, self.v
  k[n], v[n] = key, val
  while n > 1 do
    local p = math.floor(n / 2)
    if k[p] <= k[n] then break end
    k[p], k[n] = k[n], k[p]
    v[p], v[n] = v[n], v[p]
    n = p
  end
end
function Heap:pop()
  if self.n == 0 then return nil end
  local k, v = self.k, self.v
  local top = v[1]
  k[1], v[1] = k[self.n], v[self.n]
  k[self.n], v[self.n] = nil, nil
  self.n = self.n - 1
  local i, n = 1, self.n
  while true do
    local l, r = i * 2, i * 2 + 1
    local s = i
    if l <= n and k[l] < k[s] then s = l end
    if r <= n and k[r] < k[s] then s = r end
    if s == i then break end
    k[s], k[i] = k[i], k[s]
    v[s], v[i] = v[i], v[s]
    i = s
  end
  return top
end

function U.fmt(n)
  n = math.floor(n + 0.5)
  if n >= 10000 then return string.format("%.1fk", n / 1000) end
  return tostring(n)
end

return U
