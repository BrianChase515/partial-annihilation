-- Saved maps: a name plus everything needed to regenerate the same map.
local M = {}
local FILE = "saved_maps.txt"

function M.load()
  local list = {}
  if not love.filesystem.getInfo(FILE) then return list end
  for line in love.filesystem.lines(FILE) do
    local name, seed, size, water, np = line:match("^(.-)\t(%d+)\t(%d+)\t([%d%.]+)\t(%d+)$")
    if name then
      list[#list + 1] = { name = name, seed = tonumber(seed), size = tonumber(size), water = tonumber(water), np = tonumber(np) }
    end
  end
  return list
end

function M.saveAll(list)
  local out = {}
  for _, m in ipairs(list) do
    out[#out + 1] = string.format("%s\t%d\t%d\t%.2f\t%d", m.name:gsub("[\t\n]", " "), m.seed, m.size, m.water, m.np)
  end
  love.filesystem.write(FILE, table.concat(out, "\n") .. "\n")
end

function M.add(entry)
  local list = M.load()
  -- replace an existing entry with the same name
  for i = #list, 1, -1 do if list[i].name == entry.name then table.remove(list, i) end end
  table.insert(list, 1, entry)
  M.saveAll(list)
end

function M.remove(name)
  local list = M.load()
  for i = #list, 1, -1 do if list[i].name == name then table.remove(list, i) end end
  M.saveAll(list)
end

return M
