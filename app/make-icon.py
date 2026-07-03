from PIL import Image, ImageDraw
import math

def make(sz):
    img = Image.new("RGBA", (sz, sz), (0,0,0,0))
    d = ImageDraw.Draw(img)
    s = sz/1024.0
    # rounded-rect gradient-ish background (deep indigo -> violet)
    r = int(220*s)
    def rr(box, rad, fill):
        d.rounded_rectangle(box, radius=rad, fill=fill)
    rr([int(40*s),int(40*s),int(984*s),int(984*s)], r, (30,27,75,255))     # base
    rr([int(40*s),int(40*s),int(984*s),int(560*s)], r, (49,46,129,255))    # top sheen (approx)
    rr([int(40*s),int(300*s),int(984*s),int(984*s)], r, (30,27,75,255))
    # mic capsule
    cx = sz/2
    capW, capTop, capBot = int(150*s), int(250*s), int(560*s)
    d.rounded_rectangle([cx-capW/2, capTop, cx+capW/2, capBot], radius=capW/2, fill=(238,238,255,255))
    # mic stand arc (U shape)
    arcW = int(300*s)
    d.arc([cx-arcW/2, int(360*s), cx+arcW/2, int(660*s)], start=0, end=180,
          fill=(199,210,254,255), width=int(34*s))
    # stem
    d.rounded_rectangle([cx-int(17*s), int(640*s), cx+int(17*s), int(760*s)], radius=int(17*s), fill=(199,210,254,255))
    # base foot
    d.rounded_rectangle([cx-int(120*s), int(760*s), cx+int(120*s), int(792*s)], radius=int(16*s), fill=(199,210,254,255))
    return img

import os
ic = os.path.expanduser("~/.config/senti/appicon.iconset")
os.makedirs(ic, exist_ok=True)
specs = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for base,scale in specs:
    px = base*scale
    img = make(px)
    name = f"icon_{base}x{base}{'@2x' if scale==2 else ''}.png"
    img.save(os.path.join(ic, name))
print("iconset written to", ic)
