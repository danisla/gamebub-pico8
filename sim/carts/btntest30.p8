pico-8 cartridge // http://www.pico-8.com
version 42
__lua__
f = 0
presses = 0
function _update()
 f += 1
 if btnp(5) then
  presses += 1
  printh("btnp at update "..f.." total "..presses)
 end
end
function _draw() cls() print(presses, 10, 10, 7) end
