function love.conf(t)
  t.identity = "partial-annihilation"
  t.version = "11.5"
  t.window.title = "Partial Annihilation"
  t.window.width = 1600
  t.window.height = 960
  t.window.resizable = true
  t.window.minwidth = 960
  t.window.minheight = 600
  t.window.highdpi = true
  t.window.vsync = 1
  t.window.msaa = 4
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
end
