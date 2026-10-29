#!/usr/bin/env python3
"""Sylwetki + ikona → data URI wklejane do web/index.html.

Strona ma być JEDNYM plikiem (łatwo ją gdziekolwiek wrzucić i dodać do ekranu
początkowego), więc obrazki są wbudowane jako data URI zamiast osobnych plików.

Sylwetki zapisujemy jako BIAŁY kształt + alpha, bo w CSS kolorujemy je przez
-webkit-mask-image + background — maska używa kanału alpha, a kolor bierze się
z tła, więc dopasowuje się do strefy przechyłu (jak renderingMode(.template)
w apce iOS).

Użycie:  python3 web/tools/make_assets.py         # wypisze klucz → data URI
"""
import base64, glob, io, json, math, os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
A = os.path.join(ROOT, "MySpin/Assets.xcassets")
SIL_H = 420          # na ekranie sylwetka ma <300 px, 420 daje zapas na @3x
ICON = 180

def sil(name):
    p = glob.glob(f"{A}/{name}.imageset/*.png")[0]
    a = Image.open(p).convert("LA").split()[1]
    a = a.resize((max(1, round(a.width * SIL_H / a.height)), SIL_H), Image.LANCZOS)
    im = Image.merge("LA", (Image.new("L", a.size, 255), a))
    buf = io.BytesIO(); im.save(buf, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()

def icon():
    ic = Image.new("RGBA", (ICON, ICON), (10, 10, 12, 255))
    d = ImageDraw.Draw(ic); c = ICON / 2; r = ICON * 0.38
    for deg in range(-60, 60, 3):
        col = (46,217,122) if abs(deg) < 25 else (247,204,38) if abs(deg) < 40 \
              else (255,128,13) if abs(deg) < 52 else (255,51,31)
        d.arc([c-r, c-r, c+r, c+r], deg-90, deg-90+3.6, fill=col, width=int(ICON*0.075))
    a = math.radians(22 - 90)
    d.line([c+math.cos(a)*r*0.45, c+math.sin(a)*r*0.45,
            c+math.cos(a)*r*1.12, c+math.sin(a)*r*1.12], fill=(255,255,255), width=int(ICON*0.035))
    g = Image.open(glob.glob(f"{A}/gsxSilhouette.imageset/*.png")[0]).convert("LA")
    gh = int(ICON * 0.30)
    g = g.resize((max(1, round(g.width * gh / g.height)), gh), Image.LANCZOS)
    tint = Image.new("RGBA", g.size, (255, 70, 70, 255)); tint.putalpha(g.split()[1])
    rot = tint.rotate(-22, expand=True, resample=Image.BICUBIC)
    ic.alpha_composite(rot, (int(c - rot.width/2), int(c - gh/2) - 4))
    buf = io.BytesIO(); ic.save(buf, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()

if __name__ == "__main__":
    out = {"gsx": sil("gsxSilhouette"), "cbr650r": sil("cbr650rSilhouette"),
           "cbr600rr": sil("cbr600rrSilhouette"), "icon": icon()}
    for k, v in out.items():
        print(f"{k:9} {len(v)/1024:6.1f} KB")
    json.dump(out, open(os.path.join(ROOT, "web/_assets.json"), "w"))
    print("\n→ web/_assets.json (podmień placeholdery __GSX__ / __CBR650R__ / __CBR600RR__ / __ICON__)")
