pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- all() (in C) against fake-08's former Lua all(): the same values in the
-- same order, on tables with holes, values deleted, added and replaced
-- while iterating, metatables. Prints "alltest ok" or the first mismatch.
function lua_all(c)
 if (c==nil or #c==0) return function() end
 local i,prev = 1,nil
 return function()
  if (c[i]==prev) i+=1
  while (i<=#c and c[i]==nil) i+=1
  prev=c[i]
  return prev
 end
end

function mk(seed,n)
 srand(seed)
 local t={}
 for k=1,n do
  if (rnd(1)<0.8) t[k]={id=k} else t[k]=nil
 end
 if (rnd(1)<0.3) t[n+2+flr(rnd(3))]={id=99}
 return t
end

-- mode: what the loop body does to the table
function walk(iter,t,mode,seed)
 srand(seed)
 local out={}
 for v in iter(t) do
  add(out,v.id)
  local r=rnd(1)
  if mode==1 and r<0.3 then del(t,v)
  elseif mode==2 and r<0.2 then add(t,{id=100+#out})
  elseif mode==3 and r<0.2 then deli(t,flr(rnd(#t))+1)
  elseif mode==4 and r<0.2 then t[flr(rnd(#t+2))+1]=nil
  elseif mode==5 and r<0.2 then t[flr(rnd(#t))+1]={id=200+#out}
  end
  if (#out>500) break
 end
 return out
end

function same(a,b)
 if (#a!=#b) return false
 for k=1,#a do if (a[k]!=b[k]) return false end
 return true
end

local fails=0
for seed=1,400 do
 for mode=0,5 do
  local n=seed%23
  local a=walk(all,mk(seed,n),mode,seed*7)
  local b=walk(lua_all,mk(seed,n),mode,seed*7)
  if not same(a,b) and fails<5 then
   fails+=1
   printh("alltest mismatch seed "..seed.." mode "..mode..": "..#a.." vs "..#b)
  end
 end
end
-- metatables: __index and __len
local base={{id=1},{id=2},{id=3}}
local mt=setmetatable({},{__index=base,__len=function() return 3 end})
if (not same(walk(all,mt,0,1),walk(lua_all,mt,0,1))) fails+=1 printh("alltest mismatch metatable")
-- nil, empty, strings
local cnt=0
for v in all(nil) do cnt+=1 end
for v in all({}) do cnt+=1 end
if (cnt!=0) fails+=1 printh("alltest mismatch empty")
printh(fails==0 and "alltest ok" or "alltest failed")
function _draw() cls() print(fails==0 and "ok" or "failed") end
