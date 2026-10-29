#!/usr/bin/env python3
"""Test narzędzi canlog.py na sztucznej jeździe o znanej treści.

Generuje log w formacie apki (ramki 10 Hz + telefon 10 Hz) z 20 minut jazdy:
znane ramki (obroty, bieg, gaz, przechył, licznik koła) i trzy „ukryte" sygnały
pod wymyślonymi ID. Sprawdza, że `check` potwierdza przechył i licznik koła,
a `find` wskazuje ukryte sygnały na pierwszym miejscu — oraz że wariant, w którym
motocykl pokazuje 0° w zakrętach, zostaje odrzucony.

Uruchomienie:  /usr/bin/python3 tools/can/selftest.py
"""
import io
import os
import sys
import tempfile
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import canlog  # noqa: E402  (może przełączyć interpreter na taki z numpy)

np = canlog.np

GEAR_KMH_PER_1000 = [0, 9.6, 12.9, 15.9, 18.6, 21.0, 23.4]   # zmyślone, tylko do testu
PULSES_PER_M = 2.35


def ride(seconds=1200, seed=7):
    """Prawdziwy przebieg jazdy co 0,1 s."""
    rng = np.random.default_rng(seed)
    t = np.arange(0, seconds, 0.1)
    # prędkość: suma wolnych fal + postoje
    v = 70 + 45 * np.sin(t / 47) + 25 * np.sin(t / 13 + 1) + 10 * np.sin(t / 5.1)
    v = np.clip(v, 0, 190)
    v[(t % 300) < 25] = 0                       # postoje na światłach
    kernel = np.ones(30) / 30
    v = np.convolve(v, kernel, mode="same")
    # przechył: zakręty tylko w ruchu
    lean = 32 * np.sin(t / 7.3) * np.sin(t / 31) + 8 * np.sin(t / 2.9)
    lean *= np.clip(v / 40, 0, 1)
    gear = np.clip(np.digitize(v, [1, 35, 60, 85, 110, 140]), 0, 6)
    rpm = np.where(gear > 0, v / np.array(GEAR_KMH_PER_1000)[np.maximum(gear, 1)] * 1000, 1300)
    rpm = np.where(v < 1, 1300, rpm) + rng.normal(0, 25, len(t))
    thr = np.clip(60 + np.gradient(v, 0.1) * 40 + v * 1.2, 0, 690)
    dist = np.cumsum(v / 3.6 * 0.1)
    alt = 300 + 120 * np.sin(dist / 4000)
    coolant = 85 + 12 * (1 - np.exp(-t / 200)) + 4 * np.sin(t / 90)
    return dict(t=t, v=v, lean=lean, gear=gear, rpm=rpm, thr=thr, dist=dist, alt=alt,
                coolant=coolant, rng=rng)


def write_log(path, r, bike_lean_alive=True):
    t, rng = r["t"], r["rng"]
    n = len(t)

    def hexb(vals):
        return "".join(f"{int(x) & 0xFF:02X}" for x in vals)

    lean_bike = r["lean"] if bike_lean_alive else r["lean"] * 0.03
    lean_word = np.clip(np.round(32768 + lean_bike * 32768 / 180), 0, 65535).astype(int)
    rpm = np.clip(np.round(r["rpm"]), 0, 65535).astype(int)
    thr = np.round(r["thr"]).astype(int)
    pulses = np.floor(r["dist"] * PULSES_PER_M).astype(int)
    lat_acc = rng.normal(0, 30, n)                           # w zakręcie boczne ≈ 0
    vert = -5000 / np.cos(np.radians(r["lean"])) + rng.normal(0, 20, n)
    # telefon: przechył z przesunięciem 2°, szumem i opóźnieniem 0,2 s; GPS odświeżany co 1 s
    ph_lean = np.roll(r["lean"], 2) + 2.0 + rng.normal(0, 1.2, n)
    gps_v = r["v"][(np.arange(n) // 10) * 10] + rng.normal(0, 0.4, n)
    gps_alt = r["alt"][(np.arange(n) // 10) * 10]

    with open(path, "w") as f:
        f.write("# MySpin CAN log v1, start 2026-10-10T10:00:00Z (dane sztuczne)\n")
        f.write("M,0.000,start testu\n")
        for i in range(n):
            ti, ms, c = t[i], int(t[i] * 1000) + 5000, i % 16
            rows = [
                (0x1A1, 10, [rpm[i] >> 8, rpm[i], thr[i] >> 2, ((thr[i] & 3) << 6) | r["gear"][i], 4, 0, c, 0]),
                (0x1A5, 10, [lean_word[i] >> 8, lean_word[i], 0x80, 0, int((r["coolant"][i] + 30) * 255 / 160), 0, c, 0]),
                (0x181, 10, [0x80, 0x10, int(32768 + vert[i]) >> 8, int(32768 + vert[i]),
                             int(32768 + lat_acc[i]) >> 8, int(32768 + lat_acc[i]), c, rng.integers(0, 256)]),
                (0x221, 5, [0, pulses[i], rpm[i] // 2 >> 8, rpm[i] // 2, 0x80, 0, c, 0]),
                # ukryte: prędkość ×100 jako słowo, temperatura +40, wysokość jako słowo little-endian
                (0x2F1, 5, [int(r["v"][i] * 100) >> 8, int(r["v"][i] * 100), 0, 0, 0, 0, c, rng.integers(0, 256)]),
                (0x3A0, 1, [0x11, 0x22, int(r["coolant"][i] + 40), 0, 0, 0, c, 0]),
                (0x3C4, 1, [0, 0, 0, int(r["alt"][i]) & 0xFF, int(r["alt"][i]) >> 8, 0, c, 0]),
                (0x175, 20, list(rng.integers(0, 256, 6)) + [c, rng.integers(0, 256)]),   # szum żyroskopu
            ]
            for cid, cnt, data in rows:
                f.write(f"C,{ti:.3f},{ms},{cid:X},{cnt},{hexb(data)}\n")
            f.write(f"P,{ti:.3f},{max(0, gps_v[i]):.1f},{ph_lean[i]:.1f},0.10,49.700000,18.900000,"
                    f"{gps_alt[i]:.0f},90,5,17.5\n")
            if i == 6000:
                f.write(f"L,{ti:.3f},2\n")


def run(fn, **kw):
    buf = io.StringIO()
    with redirect_stdout(buf):
        code = fn(type("Args", (), kw)())
    return code, buf.getvalue()


def main():
    # `selftest.py --write PLIK` zostawia sztuczny log do ręcznych prób z canlog.py.
    if len(sys.argv) == 3 and sys.argv[1] == "--write":
        write_log(sys.argv[2], ride())
        print(f"zapisano {sys.argv[2]}")
        return 0
    failed = 0

    def check(name, ok, detail=""):
        nonlocal failed
        failed += 0 if ok else 1
        print(f"{'OK  ' if ok else 'FAIL'} {name}" + (f"  — {detail}" if detail and not ok else ""))

    with tempfile.TemporaryDirectory() as tmp:
        good, dead = os.path.join(tmp, "good.csv"), os.path.join(tmp, "dead.csv")
        r = ride()
        write_log(good, r, bike_lean_alive=True)
        write_log(dead, r, bike_lean_alive=False)

        log = canlog.load(good)
        check("wczytanie: 8 ID, telefon, znacznik, zgubione pakiety",
              len(log.ids) == 8 and len(log.phone_t) == len(r["t"]) and len(log.marks) == 1 and log.lost == 2,
              f"{len(log.ids)} ID, {len(log.phone_t)} P, {log.marks}, lost {log.lost}")
        check("częstość z licznika ramek (0x175 = 200/s)", abs(log.rate(0x175) - 200) < 2, f"{log.rate(0x175):.1f}")

        ks = canlog.known_series(log)
        check("dekodowanie: obroty", abs(ks["rpm"][1].mean() - np.clip(np.round(r["rpm"]), 0, 65535).mean()) < 0.5)
        check("dekodowanie: bieg bez bitów gazu", np.array_equal(ks["gear"][1], r["gear"]))
        check("dekodowanie: przechył co do 0,01°", np.abs(ks["lean"][1] - r["lean"]).max() < 0.01,
              f"{np.abs(ks['lean'][1] - r['lean']).max():.4f}")
        check("dekodowanie: gaz 10-bitowy", np.array_equal(ks["throttle10"][1], np.round(r["thr"])))

        code, out = run(canlog.cmd_check, log=good)
        check("check: żywy przechył potwierdzony", code == 0 and "działa w jeździe ✔" in out, out)
        check("check: licznik koła = prędkość, impulsy/m odtworzone",
              "to prędkość koła ✔" in out and f"{PULSES_PER_M:.2f} impulsu na metr" in out, out)
        check("check: przełożenie na 3. biegu odtworzone", f"bieg 3: {GEAR_KMH_PER_1000[3]:5.1f}" in out, out)

        code, out = run(canlog.cmd_check, log=dead)
        check("check: przechył ~0° w zakrętach odrzucony", code == 1 and "✘" in out, out)

        code, out = run(canlog.cmd_find, log=good, ref=None, top=3, min_r=0.6)
        sect = {}
        cur = None
        for line in out.splitlines():
            if line.startswith("  ") and line.strip().endswith(":") and not line.startswith("    "):
                cur = line.strip()[:-1]
                sect[cur] = []
            elif cur and line.startswith("    "):
                sect[cur].append(line.strip())
        check("find: prędkość → 0x2F1 w01 na pierwszym miejscu",
              sect.get("kmh", [""])[0].startswith("2F1 w01"), "\n".join(sect.get("kmh", [])))
        import re
        m = re.search(r"≈ ([0-9.eE+-]+) × pole", sect.get("kmh", [""])[0])
        # GPS odświeża się co sekundę, więc nachylenie wychodzi minimalnie zaniżone — tolerancja 2%.
        check("find: prędkość → skala 0,01 odtworzona z dokładnością 2%",
              m is not None and abs(float(m.group(1)) - 0.01) < 0.0002, sect.get("kmh", [""])[0])
        check("find: prędkość → tempo licznika koła też znalezione",
              any(s.startswith("221 b1/s") for s in sect.get("kmh", [])), "\n".join(sect.get("kmh", [])))
        check("find: wysokość → 0x3C4 słowo little-endian",
              sect.get("alt", [""])[0].startswith("3C4 w34le"), "\n".join(sect.get("alt", [])))
        check("find: przechył telefonu → 0x1A5 w01 (znane: lean)",
              sect.get("phone_lean", [""])[0].startswith("1A5 w01") and "znane: lean" in sect["phone_lean"][0],
              "\n".join(sect.get("phone_lean", [])))
        check("find: obroty → 0x221 w23 (połówka obrotów)",
              any(s.startswith("221 w23") for s in sect.get("rpm", [])[:3]), "\n".join(sect.get("rpm", [])))
        check("find: szum i liczniki kolejności nie trafiają do wyników",
              "175" not in out.replace("0x175", ""), out)

        code, out = run(canlog.cmd_profile, log=good)
        check("profile: licznik kolejności rozpoznany", " L " in out + " ", out)

        png = os.path.join(tmp, "ride.png")
        code, out = run(canlog.cmd_plot, log=good, out=png, start=None, end=None)
        check("plot: wykres zapisany", code == 0 and os.path.getsize(png) > 20_000, out)
        code, out = run(canlog.cmd_field, log=good, id="2F1", field="w01", ref="kmh", out=None)
        check("field: pole z korelacją do odniesienia", code == 0 and "r = +0.99" in out, out)
        code, out = run(canlog.cmd_field, log=good, id="221", field="b1/s", ref="kmh", out=None)
        check("field: tempo licznika", code == 0 and "r = +0.99" in out, out)

    print("WYNIK: wszystko OK" if failed == 0 else f"WYNIK: {failed} błędów")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
