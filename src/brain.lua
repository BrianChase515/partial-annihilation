-- The shared decision engine for AI v2 (any mode can use it).
--
-- No yes/no rules: the AI lists what it could do, scores each option from several considerations,
-- and then - like AI War - does NOT always take the best one. How often it takes the very best
-- (the move that hurts you most) is what difficulty buys: about 37% at level 1, 63% at level 5,
-- 95% at level 10. Otherwise it picks among the nearly-best, weighted by score. A personality
-- (archetype + jitter, drawn per game) tilts the scores, so two games at the same level play
-- differently. Commitment keeps it from flip-flopping every think.
local B = {}

-- chance of taking the top-scoring option at this level
function B.sharpness(level)
  return math.min(0.97, 0.3 + 0.065 * (level or 5))
end

-- options: { { score = n, ... }, ... } (score >= 0). Returns the chosen option and its rank.
-- rng: a love RandomGenerator. Options scoring under `band` x the best are never picked
-- (the AI doesn't do something stupid just to be random).
function B.pick(options, level, rng, band)
  local list = {}
  for _, o in ipairs(options) do if o.score and o.score > 0 then list[#list + 1] = o end end
  if #list == 0 then return nil end
  table.sort(list, function(a, b) return a.score > b.score end)
  local top = list[1].score
  if #list == 1 or rng:random() < B.sharpness(level) then return list[1], 1 end
  -- nearly-best: within the band (wider for weaker players), weighted by how good they are
  band = band or (0.55 + 0.03 * (level or 5))
  local pool, tot = {}, 0
  for i, o in ipairs(list) do
    if o.score >= top * band then
      local wgt = (o.score / top) ^ 2
      pool[#pool + 1] = { o = o, w = wgt, i = i }
      tot = tot + wgt
    end
  end
  local r = rng:random() * tot
  for _, p in ipairs(pool) do
    r = r - p.w
    if r <= 0 then return p.o, p.i end
  end
  return pool[#pool].o, pool[#pool].i
end

-- keep doing `cur` unless something is clearly better (by `margin`) or it's been long enough to
-- reconsider. state = { choice, since } per decision; returns the option to follow
function B.commit(state, options, level, rng, now, opts)
  opts = opts or {}
  local margin, minHold = opts.margin or 1.25, opts.minHold or 12
  local cur
  if state.choice then
    for _, o in ipairs(options) do if o.key == state.choice.key then cur = o end end
  end
  local best = 0
  for _, o in ipairs(options) do if o.score > best then best = o.score end end
  local stale = now - (state.since or -1e9) > (state.reconsider or 45)
  if cur and cur.score > 0 and now - (state.since or 0) < minHold then return cur, false end
  if cur and cur.score > 0 and best < cur.score * margin and not stale then return cur, false end
  local pick = B.pick(options, level, rng, opts.band)
  if not pick then return nil, false end
  local changed = not state.choice or state.choice.key ~= pick.key
  state.choice, state.since = pick, now
  state.reconsider = (opts.reconsider or 45) * (0.7 + rng:random() * 0.6)
  return pick, changed
end

-- a personality: an archetype's weights, each nudged +/-20%. Archetypes: { name, weights = {} }
function B.personality(archetypes, rng, forced)
  local a = archetypes[rng:random(#archetypes)]
  if forced then for _, x in ipairs(archetypes) do if x.name == forced then a = x end end end
  local p = { name = a.name, w = {} }
  for k, v in pairs(a.weights) do p.w[k] = v * (0.8 + rng:random() * 0.4) end
  return p
end

-- short text of the top few options (for the match log)
function B.explain(options, chosen, n)
  local list = {}
  for _, o in ipairs(options) do if o.score and o.score > 0 then list[#list + 1] = o end end
  table.sort(list, function(a, b) return a.score > b.score end)
  local parts = {}
  for i = 1, math.min(n or 3, #list) do
    parts[#parts + 1] = string.format("%s%s %.2f", list[i] == chosen and "*" or "", list[i].label or list[i].key, list[i].score)
  end
  return table.concat(parts, ", ")
end

return B
