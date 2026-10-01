#!/usr/bin/env python3
"""Writes gfxtest.p8: draws every frame with the graphics functions the
accelerator handles (and the ones it doesn't, mixed in), with clipping,
camera, palettes and fill patterns changing every frame. Run with and without
the accelerator (sim/Makefile VEXII_GFX) and compare the frames
(sim/cmp_frames.py)."""
from pathlib import Path

LUA = r"""
t=0
function _update() t+=1 end
function _draw()
 cls(t%16)
 camera(flr(sin(t/97)*24),flr(cos(t/71)*24))
 clip(t%23,t%19,90+t%40,96+t%33)
 -- sprites: sizes, flips, off the edges, palettes
 for i=0,47 do
  local x=(i*37+t*3)%190-40
  local y=(i*23+t*2)%190-40
  local n=(i*7+t)%128
  if i%5==0 then pal(i%16,(i+t)%16) end
  if i%7==0 then palt(i%16,i%2==0) end
  if i%11==0 then pal() palt() end
  spr(n,x,y,1+i%3,1+(i>>1)%3,i%2==1,(i>>2)%2==1)
 end
 pal() palt()
 -- sprite sheet edges: sources past the right and bottom edges
 spr(15,10,10,3,1) spr(127,30,10,2,3,true) spr(255,50,10,2,2,false,true)
 -- fills: rectangles, patterns (also transparent), spans
 local pats={0,0x5a5a,0xa5a5.8,0x0f0f,0x1234.8,0xffff,0x8000.8}
 for i=0,13 do
  fillp(pats[i%#pats+1])
  rectfill((i*29+t)%170-25,(i*13+t*2)%170-25,(i*41+t)%150-10,(i*17+t*3)%150-10,(i+t)%16+((i*3)%16)*16)
 end
 for i=0,5 do
  fillp(pats[(i+t)%#pats+1])
  circfill((i*31+t)%140,(i*19+t*2)%140,(i*3+t)%25,i+4)
  ovalfill((i*23)%120,(i*37+t)%120,(i*23)%120+(t%30),(i*37+t)%120+12,i+8)
  rect((i*19+t)%130,(i*7)%130,(i*19+t)%130+(i*5)%40,(i*7)%130+(t%50),i+1)
  line((i*11+t)%128,0,(i*13)%128,127,i+2)
 end
 fillp()
 -- map, stretched sprites, text
 map((t>>3)%16,0,(t%40)-20,64,10,6)
 sspr((t*3)%96,(t*5)%96,24,16,(t*2)%110-10,90,30+t%17,20,t%2==0,t%3==0)
 pal(7,t%16) print("gfx "..t,40,(t*2)%140-6,7) pal()
 -- screen memory: read back (pget, peek) and written by the cpu
 camera() clip()
 local p=pget(t%128,(t*3)%128)
 pset(0,0,p)
 poke(0x6040+t%64,peek(0x6000+(t*7)%8192))
 memcpy(0x6000+64*120,0x6000+64*(t%100),64*4)
 -- the sprite sheet changed (sset) between draws
 sset(t%128,(t*5)%128,t%16)
 spr(t%128,100,100,2,2)
end
"""


def gfx_rows():
    rows = []
    for y in range(128):
        row = []
        for x in range(128):
            # Varied colors, with transparent (0) runs.
            v = (x * 7 + y * 13 + (x * y) // 11) % 19
            row.append("0" if v >= 16 else "%x" % v)
        rows.append("".join(row))
    return rows


def map_rows():
    return ["".join("%02x" % ((x * 5 + y * 3) % 128) for x in range(128)) for y in range(32)]


def main():
    out = ["pico-8 cartridge // http://www.pico-8.com", "version 41", "__lua__", LUA.strip(), "__gfx__"]
    out += gfx_rows()
    out += ["__map__"] + map_rows()
    Path(__file__).with_name("gfxtest.p8").write_text("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
