-- Saved maps: a name plus everything needed to regenerate the same map.
local M = {}
local FILE = "saved_maps.txt"

function M.load()
  local list = {}
  if not love.filesystem.getInfo(FILE) then return list end
  for line in love.filesystem.lines(FILE) do
    -- (an optional sixth field says which game the map is for: "rts" - the default, older
    -- files - "conquest" or "wih" for Commander of Heroes)
    local name, seed, size, water, np, mode = line:match("^(.-)\t(%d+)\t(%d+)\t([%d%.]+)\t(%d+)\t?(%a*)$")
    if name then
      list[#list + 1] = { name = name, seed = tonumber(seed), size = tonumber(size), water = tonumber(water), np = tonumber(np),
        mode = (mode and mode ~= "") and mode or "rts" }
    end
  end
  return list
end

function M.saveAll(list)
  local out = {}
  for _, m in ipairs(list) do
    out[#out + 1] = string.format("%s\t%d\t%d\t%.2f\t%d\t%s", (m.name:gsub("[\t\n]", " ")), m.seed, m.size, m.water, m.np, m.mode or "rts")
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
