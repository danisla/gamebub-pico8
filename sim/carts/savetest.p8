pico-8 cartridge // http://www.pico-8.com
version 42
__lua__
cartdata("gamebub_savetest")
n = dget(0) + 1
dset(0, n)
printh("savetest count "..n)
function _draw()
 cls(1)
 print("save test", 10, 10, 7)
 print("count "..n, 10, 20, 10)
end
