pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- z8lua's sandbox fallback (lvm.c OP_GETTABUP / OP_GETTABLE): with _ENV
-- replaced by a table, API functions missing from it are still found in the
-- cart's sandbox (as PICO-8 does for Ex-Terra). Also when the table's
-- __index metamethod grows the Lua stack first (the fallback must write
-- the result where the stack is now). Prints "envtest ok" or the failures.
fails=0
function check(name,ok)
 if not ok then fails+=1 printh("envtest failed: "..name) end
end

-- _ENV replaced by a plain table: API functions from the sandbox
function plain(t)
 local _ENV=t
 return flr(x)+abs(y)
end
check("plain",plain({x=2.5,y=-3})==5)

-- in a loop (OP_GETTABLE)
function loop(list)
 local s=0
 for _ENV in all(list) do
  s+=flr(v)
 end
 return s
end
check("loop",loop({{v=1.5},{v=2.5},{v=3.9}})==6)

-- __index that grows the stack (deep recursion), then the fallback
function deep(n)
 if (n==0) return 0
 local a,b,c,d,e,f,g,h=1,2,3,4,5,6,7,8
 return deep(n-1)+a
end
function grow(t)
 local _ENV=setmetatable({x=7.5},{__index=function(t,k) deep(300) return nil end})
 local a,b,c=1,2,3
 local r=flr(x)
 return r+a+b+c
end
for k=1,20 do check("grow "..k,grow()==13) end

-- values the fallback mustn't change: present keys, nil results
function present(t)
 local _ENV=t
 return flr
end
check("present",present({flr="mine"})=="mine")
function missing(t)
 local _ENV=t
 return not_an_api_function
end
check("missing",missing({})==nil)

printh(fails==0 and "envtest ok" or "envtest failed")
function _draw() cls() print(fails==0 and "ok" or "failed") end
