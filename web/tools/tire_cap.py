#!/usr/bin/env python3
"""Zamyka dół opony łukiem o promieniu = połowa jej szerokości i tnie wszystko niżej.

Cień pod kołem zostawiał tępy, szeroki koniec (CBR ~60 px przy dole, GSX 0).
Zamiast zgadywać, gdzie kończy się cień, LICZYMY KRZYWIZNĘ: opona ma proste
boki o szerokości tw, więc jej dół to półokrąg o promieniu tw/2. Wszystko pod
tym łukiem to z definicji nie opona.
"""
import glob, math
from PIL import Image

A = "/Users/mikomaks/Desktop/Programowanie/Projekty/MySpin/MySpin/Assets.xcassets"

def cap(name):
    p = glob.glob(f"{A}/{name}.imageset/*.png")[0]
    im = Image.open(p).convert("LA")
    a = im.split()[1]; w, h = a.size; px = a.load()
    ws = [sum(1 for x in range(w) if px[x, y] > 128) for y in range(h)]

    bot = max(y for y in range(h) if ws[y] > 0)
    band = sorted(v for v in ws[int(bot - h * 0.10):bot + 1] if v > 0)
    tw = band[len(band) // 2]
    r = tw / 2.0

    # Łuk zaczynamy tak, żeby opona skończyła się tam, gdzie kończy się teraz —
    # nie skracamy koła, tylko zaokrąglamy jego dół i ucinamy resztę.
    start = int(round(bot - r))
    xs = [x for x in range(w) if px[x, start] > 128]
    cx = (xs[0] + xs[-1]) / 2.0 if xs else w / 2.0

    for d in range(0, int(math.ceil(r)) + 1):
        y = start + d
        if y >= h: break
        hw = math.sqrt(max(0.0, r * r - d * d))
        L, R = cx - hw, cx + hw
        for x in range(w):
            cov = min(x + 1.0, R) - max(float(x), L)          # pokrycie ułamkowe = gładka krawędź
            v = int(round(255 * min(1.0, max(0.0, cov))))
            if px[x, y] > 128: px[x, y] = v                   # tniemy tylko to, co było oponą
            elif v > 0 and abs(x - cx) < r: px[x, y] = v      # domykamy łuk

    for y in range(start + int(math.ceil(r)) + 1, h):         # pod łukiem nie ma nic
        for x in range(w):
            px[x, y] = 0

    a = a.crop(a.getbbox())
    k = 708 / a.height
    a = a.resize((max(1, round(a.width * k)), 708), Image.LANCZOS)
    Image.merge("LA", (Image.new("L", a.size, 0), a)).save(p)

    w2, h2 = a.size; q = a.load()
    prof = [sum(1 for x in range(w2) if q[x, min(h2 - 1, int(h2 * f))] > 128)
            for f in (0.80, 0.86, 0.90, 0.94, 0.97, 0.995)]
    print(f"{name:22} opona {tw}px → r={r:.0f}  {w2}x{h2}  {prof}")

for n in ("cbr650rSilhouette", "cbr600rrSilhouette"):
    cap(n)
print(f"{'gsxSilhouette (wzorzec)':22}                    [128, 110, 108, 105, 72, 0]")
