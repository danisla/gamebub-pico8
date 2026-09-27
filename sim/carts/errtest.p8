pico-8 cartridge // http://www.pico-8.com
version 42
__lua__
f = 0
function _update60()
 f += 1
 if f == 30 then
  printh("calling nil")
  nosuchfunction()
 end
end
function _draw() cls() print(f, 10, 10, 7) end
