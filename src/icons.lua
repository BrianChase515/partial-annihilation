-- Unit and building pictures: white silhouettes from game-icons.net (CC BY 3.0, see README),
-- tinted at draw time. Falls back to the text label if a picture is missing.
local I = {}
local cache = {}

function I.get(key)
  local c = cache[key]
  if c == nil then
    local path = "assets/icons/" .. key .. ".png"
    c = false
    if love.filesystem.getInfo(path) then
      local ok, img = pcall(love.graphics.newImage, path, { mipmaps = true })
      if ok then
        img:setFilter("linear", "linear")
        pcall(function() img:setMipmapFilter("linear", 0) end)
        c = img
      end
    end
    cache[key] = c
  end
  return c or nil
end

function I.has(key) return I.get(key) ~= nil end

-- draw centered at x, y, `size` pixels (in the current transform) across, in the current color
function I.draw(key, x, y, size, angle)
  local img = I.get(key)
  if not img then return false end
  local s = size / img:getWidth()
  love.graphics.draw(img, x, y, angle or 0, s, s, img:getWidth() / 2, img:getHeight() / 2)
  return true
end

return I
