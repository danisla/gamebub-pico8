pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- sin/cos at exact quarter turns (sin_helper read past its table there).
-- PICO-8: cos(0)=1, sin(0.25)=-1, cos(0.5)=-1, sin(0.75)=1, sin(0)=0.
local fails=0
function check(name,got,want)
 if got!=want then fails+=1 printh("trigtest "..name.." = "..tostr(got,true).." want "..tostr(want,true)) end
end
for k=-3,3 do
 check("cos("..k..")",cos(k),1)
 check("sin("..k.."+0.25)",sin(k+0.25),-1)
 check("cos("..k.."+0.5)",cos(k+0.5),-1)
 check("sin("..k.."+0.75)",sin(k+0.75),1)
 check("sin("..k..")",sin(k),0)
 check("cos("..k.."+0.25)",cos(k+0.25),0)
end
printh(fails==0 and "trigtest ok" or "trigtest failed")
function _draw() cls() print(fails==0 and "ok" or "failed") end
