pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- count, add, del, deli, foreach (in C) against fake-08's former Lua
-- versions: the same results and the same tables after, on random tables
-- (holes, duplicates, shared values), random arguments (nil, false,
-- fractional, negative, out of range), metatables, and foreach callbacks
-- that change the table. Prints "tabletest ok" or the first mismatches.
function l_count(c,v)
 local cnt,max = 0,#c
 if v == nil then
  for i=1,max do if (c[i] != nil) cnt+=1 end
 else
  for i=1,max do if (c[i] == v) cnt+=1 end
 end
 return cnt
end
function l_add(c, x, i)
 if c != nil then
  i=i and mid(1,i\1,#c+1) or #c+1
  for j=#c,i,-1 do c[j+1]=c[j] end
  c[i]=x
  return x
 end
end
function l_del(c,v)
 if c != nil then
  local max = #c
  for i=1,max do
   if c[i]==v then
    for j=i,max do c[j]=c[j+1] end
    return v
   end
  end
 end
end
function l_deli(c,i)
 if c != nil then
  i=i and mid(1,i\1,#c) or #c
  local v=c[i]
  for j=i,#c do c[j]=c[j+1] end
  return v
 end
end
function l_foreach(c, f)
 for v in all(c) do f(v) end
end

objs={{},{},{},"a","b",1,2,3,2.5,true,false}
function val()
 local r=flr(rnd(14))
 if (r<11) return objs[r+1]
 if (r==11) return nil
 return flr(rnd(5))
end
-- two identical tables (same values)
function mk(n,withmt)
 local a,b={},{}
 for k=1,n do
  local v=val()
  if (rnd(1)<0.15) v=nil
  a[k]=v b[k]=v
 end
 if rnd(1)<0.2 then local x=val() a[n+2]=x b[n+2]=x end
 if withmt then
  setmetatable(a,{__index=function(t,k) return k==1 and "m" or nil end})
  setmetatable(b,getmetatable(a))
 end
 return a,b
end
function arg()
 local r=flr(rnd(9))
 if (r==0) return nil
 if (r==1) return false
 if (r==2) return rnd(12)-2
 if (r==3) return 0
 if (r==4) return -3
 if (r==5) return 40
 return flr(rnd(12))
end
function same(a,b)
 for k=-2,45 do if not rawequal(rawget(a,k),rawget(b,k)) return false end
 return true
end
function res(...) return {n=select("#",...),...} end
function sameres(x,y)
 if (x.n!=y.n) return false
 for k=1,x.n do if not rawequal(x[k],y[k]) return false end
 return true
end

fails=0
function check(name,seed,ok)
 if not ok then
  fails+=1
  if (fails<=8) printh("tabletest mismatch "..name.." seed "..seed)
 end
end
for seed=1,600 do
 for op=1,5 do
  srand(seed*13+op)
  local n=flr(rnd(18))
  local a,b=mk(n,rnd(1)<0.1)
  local p1,p2=arg(),val()
  srand(seed*7)
  local ra,rb
  if op==1 then
   ra,rb=res(count(a,p2)),res(l_count(b,p2))
   if (rnd(1)<0.3) ra,rb=res(count(a)),res(l_count(b))
  elseif op==2 then
   ra,rb=res(add(a,p2,p1)),res(l_add(b,p2,p1))
  elseif op==3 then
   ra,rb=res(del(a,p2)),res(l_del(b,p2))
  elseif op==4 then
   ra,rb=res(deli(a,p1)),res(l_deli(b,p1))
  else
   local sa,sb={},{}
   local mode=flr(rnd(4))
   local function cb(t,s) return function(v)
    add(s,v)
    local r=rnd(1)
    if (mode==1 and r<0.3) l_del(t,v)
    if (mode==2 and r<0.2 and #s<60) l_add(t,"x")
    if (mode==3 and r<0.2) l_deli(t,1)
   end end
   srand(seed*3) foreach(a,cb(a,sa))
   srand(seed*3) l_foreach(b,cb(b,sb))
   ra,rb=res(#sa),res(#sb)
   if (not same(sa,sb)) ra=res("seq")
  end
  check(({"count","add","del","deli","foreach"})[op],seed,sameres(ra,rb) and same(a,b))
 end
end
printh(fails==0 and "tabletest ok" or "tabletest failed")
function _draw() cls() print(fails==0 and "ok" or "failed") end
