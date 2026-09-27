pico-8 cartridge // http://www.pico-8.com
version 42
__lua__
f = 0
function _update60()
 f += 1
 if btn() != 0 or f % 60 == 0 then printh("frame "..f.." btn "..btn().." btnp5 "..tostr(btnp(5))) end
end
function _draw() cls() print(btn(), 10, 10, 7) end
