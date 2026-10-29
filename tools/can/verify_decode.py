#!/usr/bin/env python3
"""Sprawdza tabelę sygnałów z canlog.py (KNOWN) na prawdziwych nagraniach z motocykla.

W tools/can/dowody/ leżą krótkie wycinki nagrań z testów na postoju (2026-10-10)
i ze zrzutów z Raspberry Pi (2026-06-25). Każdy test poniżej mówi: „w tej chwili
nagrania użytkownik miał ustawione X / wyświetlacz pokazywał Y” i sprawdza, że
dekodowanie daje to samo. Jeśli ktoś zmieni bajt, skalę albo offset w KNOWN —
ten skrypt to wyłapie.

    verify_decode.py            # sprawdź (wchodzi w skład `make can-test`)
    verify_decode.py --rebuild  # odtwórz wycinki z pełnych nagrań w canlogs/ (jeśli są)

Opis sygnałów dla ludzi: tools/can/SYGNALY.md.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import canlog  # noqa: E402  (sam przełącza się na pythona z numpy)
import numpy as np  # noqa: E402

DOWODY = os.path.join(HERE, "dowody")
ROOT = os.path.dirname(os.path.dirname(HERE))
STOL = os.path.join(ROOT, "canlogs", "stol")
PI = os.path.join(ROOT, "canlogs", "pi-2026-06-25")

# nazwa wycinka: (plik źródłowy, początek, koniec, ID, najkrótszy odstęp [s], zapis przy każdej zmianie)
# początek/koniec: sekundy od początku pliku, a dla wartości > 1e9 czas bezwzględny z nagrania
WYCINKI = {
    "postoj_nozka":   (os.path.join(STOL, "proba.log"), 0, 3, "1A1 1A5 231 181 17D 19D 221", 0.2, False),
    "czerwiec_zimny": (os.path.join(PI, "baseline.log"), 0, 3, "1A1 1A5 231", 0.2, False),
    "start_silnika":  (os.path.join(STOL, "runda1.log"), 126, 134, "1A1 1A5", 0.05, True),
    "sprzeglo_tryby": (os.path.join(STOL, "runda2.log"), 15, 90, "1A1 1A5 331 335 32D 1AD", 0.25, True),
    "trakcja":        (os.path.join(STOL, "chlodzenie.log"), 1791654440, 1791654525, "335 331", 0.5, True),
    "obciazenie_tryb": (os.path.join(STOL, "chlodzenie.log"), 1791654215, 1791654310, "1AD 32D 17D", 0.25, True),
    "tlumienie":      (os.path.join(STOL, "tlumienie.log"), 0, 40, "1AD 32D 17D", 0.25, True),
    "tlumienie_user": (os.path.join(STOL, "user_p2_m3.log"), 0, 2, "1AD 32D", 0.2, False),
    "tempomat_wl":    (os.path.join(STOL, "tempomat_on.log"), 0, 2, "341", 0.2, False),
    "tempomat_wyl":   (os.path.join(STOL, "tempomat_off.log"), 0, 2, "341", 0.2, False),
    "kolo_przod":     (os.path.join(STOL, "kolo_przod.log"), 25, 37, "19D 221", 0.02, False),
    "kolo_tyl":       (os.path.join(STOL, "kolo_tyl.log"), 8, 24, "19D 221", 0.02, False),
    "temperatury":    (os.path.join(STOL, "chlodzenie.log"), 1791653470, 1791654000, "1A5 231 1A1", 1.0, False),
    "kierowca_siada": (os.path.join(STOL, "obciazenie.log"), 0, 40, "17D 1A5", 0.1, False),
}


def rebuild():
    os.makedirs(DOWODY, exist_ok=True)
    for name, (src, a, b, ids, gap, on_change) in WYCINKI.items():
        if not os.path.exists(src):
            print(f"  pomijam {name}: brak {src}")
            continue
        ids = set(ids.split())
        last_t, last_d, t0, n = {}, {}, None, 0
        with open(src, errors="replace") as f, open(os.path.join(DOWODY, name + ".log"), "w") as out:
            for line in f:
                m = canlog._CANDUMP.match(line.strip())
                if not m:
                    continue
                t = float(m.group(1))
                if t0 is None:
                    t0 = t
                rel = t if a > 1e9 else t - t0
                if rel < a:
                    continue
                if rel > b:
                    break
                cid, data = m.group(2).upper(), m.group(3).upper()
                if cid not in ids or len(data) != 16:
                    continue
                body = data[:12]                      # bez licznika kolejności i sumy kontrolnej
                due = t - last_t.get(cid, -1e9) >= gap
                changed = on_change and body != last_d.get(cid) and t - last_t.get(cid, -1e9) >= 0.02
                if due or changed:
                    out.write(f"({t:.6f}) can0 {cid}#{data}\n")
                    last_t[cid], last_d[cid] = t, body
                    n += 1
        print(f"  {name}: {n} ramek")


# ── Sprawdzenia ──────────────────────────────────────────────────────────────

failed = 0
count = 0


def check(what, ok, got=""):
    global failed, count
    count += 1
    if not ok:
        failed += 1
    print(f"  {'OK  ' if ok else 'FAIL'} {what}" + (f"  — {got}" if got != "" else ""))


class Wycinek:
    def __init__(self, name):
        self.path = os.path.join(DOWODY, name + ".log")
        self.log = canlog.load(self.path)
        self.ks = canlog.known_series(self.log)
        with open(self.path) as f:
            self.t0 = float(f.readline().split(")")[0][1:])
        self.absolute = WYCINKI[name][1] > 1e9
        self.start = WYCINKI[name][1]

    def at(self, sig, when):
        """Wartość sygnału w chwili `when` (ta sama skala czasu co w WYCINKI)."""
        t, v = self.ks[sig]
        rel = when - self.t0 if self.absolute else when - self.start
        i = int(np.searchsorted(t, rel, side="right")) - 1
        return float(v[max(i, 0)])

    def bit(self, cid, byte, mask, when):
        t, d = self.log.t[cid], self.log.d[cid]
        rel = when - self.t0 if self.absolute else when - self.start
        i = int(np.searchsorted(t, rel, side="right")) - 1
        return bool(int(d[max(i, 0), byte]) & mask)

    def all(self, sig):
        return self.ks[sig][1]


def near(x, target, tol):
    return abs(x - target) <= tol


def run():
    missing = [n for n in WYCINKI if not os.path.exists(os.path.join(DOWODY, n + ".log"))]
    if missing:
        print("brak wycinków:", ", ".join(missing), "— uruchom z --rebuild przy obecnych canlogs/")
        return 1

    w = Wycinek("postoj_nozka")
    print("── postój na bocznej nóżce, zapłon włączony, silnik zgaszony ──")
    check("przebieg 22980 km (licznik motocykla 2026-10-10)", w.at("odo_km", 1) == 22980, w.at("odo_km", 1))
    check("przechył ok. −15° (nóżka = w lewo = ujemny)", near(w.at("lean", 1), -15.1, 0.5), round(w.at("lean", 1), 2))
    check("obroty 0, bieg N, gaz zamknięty", w.at("rpm", 1) == 0 and w.at("gear", 1) == 0 and w.at("throttle8", 1) == 0)
    check("oba koła stoją", w.all("speed_f").max() == 0 and w.all("speed_r").max() == 0)
    check("przyspieszenie pionowe ok. −1 g", near(w.at("acc_vert", 1), -0.97, 0.05), round(w.at("acc_vert", 1), 3))

    w = Wycinek("czerwiec_zimny")
    print("── zrzut z Raspberry Pi 2026-06-25, zimny silnik ──")
    check("przebieg 16221 km (30 czerwca licznik miał 16666)", w.at("odo_km", 1) == 16221, w.at("odo_km", 1))
    check("zimny silnik: płyn ≈ powietrze", near(w.at("temp_c", 1), w.at("air_c", 1), 1.5),
          f"{w.at('temp_c', 1):.1f} / {w.at('air_c', 1):.0f} °C")

    w = Wycinek("temperatury")
    print("── rozgrzewanie: odczyty użytkownika z wyświetlacza ──")
    for when, shown, tol, note in ((1791653480, 58, 2.5, "stygnie, ekran opóźniony w górę"),
                                   (1791653739, 70, 2.5, "rośnie szybko, ekran opóźniony w dół"),
                                   (1791653880, 80, 2.5, "rośnie"),
                                   (1791653960, 88, 1.5, "silnik zgaszony, prawie stoi")):
        got = w.at("temp_c", when)
        check(f"płyn: ekran {shown} °C ({note})", near(got, shown, tol), f"{got:.1f} °C")
    for when, shown in ((1791653685, 28), (1791653965, 32)):
        got = w.at("air_c", when)
        check(f"powietrze: ekran {shown} °C", near(got, shown, 1.0), f"{got:.0f} °C")

    w = Wycinek("start_silnika")
    print("── odpalenie silnika ──")
    check("przycisk startu (0x1A5 b5 bit 0x10) wciśnięty w 130,5 s", w.bit(0x1A5, 5, 0x10, 130.5))
    check("…i puszczony przed i po", not w.bit(0x1A5, 5, 0x10, 129.5) and not w.bit(0x1A5, 5, 0x10, 131.5))
    check("obroty: 0 przed, > 1000 po", w.at("rpm", 129.5) == 0 and w.at("rpm", 133) > 1000, w.at("rpm", 133))

    w = Wycinek("sprzeglo_tryby")
    print("── sprzęgło, biegi, tryb jazdy B→A→B→C→B ──")
    check("sprzęgło (0x1A5 b5 bit 0x04): puszczone 18 s, wciśnięte 30 s, puszczone 42 s",
          not w.bit(0x1A5, 5, 0x04, 18) and w.bit(0x1A5, 5, 0x04, 30) and not w.bit(0x1A5, 5, 0x04, 42))
    gears = [w.at("gear", t) for t in (45, 49.5, 51, 52.5, 54, 56.5, 58, 60, 69.5, 72)]
    check("biegi N→2→3→2→1→N→2→N→2→N", gears == [0, 2, 3, 2, 1, 0, 2, 0, 2, 0], gears)
    check("bieg zawsze w zakresie 0–6", set(np.unique(w.all("gear"))) <= set(range(7)))
    modes = [w.at("sdms", t) for t in (70, 80, 84, 87, 89)]
    check("tryb jazdy B, A, B, C, B = 2, 1, 2, 3, 2", modes == [2, 1, 2, 3, 2], modes)
    check("trakcja bieżącego trybu: B = 1, C = 4 (własna nastawa trybu C)",
          w.at("tc_level", 70) == 1 and w.at("tc_level", 87) == 4, (w.at("tc_level", 70), w.at("tc_level", 87)))
    check("tłumienie: w trybie A było U (3), w B i C — M (1)",
          w.at("damp_mode", 80) == 3 and w.at("damp_mode", 70) == 1 and w.at("damp_mode", 87) == 1)

    w = Wycinek("trakcja")
    print("── kontrola trakcji OFF→1→…→7 (tryb jazdy B) ──")
    t0 = 1791654440
    levels = [w.at("tc_level", t0 + s) for s in (30, 50.5, 54, 57, 60, 63.5, 67, 72)]
    check("poziomy OFF, 1, 2, 3, 4, 5, 6, 7", levels == [0, 1, 2, 3, 4, 5, 6, 7], levels)

    w = Wycinek("obciazenie_tryb")
    print("── tryb obciążenia SOLO→AUTO→SOLO→SOLO+bagaż→DUO→SOLO ──")
    t0 = 1791654215
    pm = [w.at("preload_mode", t0 + s) for s in (5, 22, 36, 48, 60, 80)]
    check("tryby 3, 2, 3, 4, 5, 3", pm == [3, 2, 3, 4, 5, 3], pm)
    rear = [w.at("susp_rear", t0 + s) for s in (5, 50, 62)]
    check("tył podnosi się z napięciem: SOLO < bagaż < DUO", rear[0] < rear[1] < rear[2], rear)

    w = Wycinek("tlumienie")
    print("── ACTIVE DAMPING M→H→M→S→U→S→M ──")
    dm = [w.at("damp_mode", s) for s in (10, 21, 25, 28, 30.5, 33, 36)]
    check("tryby 1, 0, 1, 2, 3, 2, 1", dm == [1, 0, 1, 2, 3, 2, 1], dm)
    check("nastawa tłumienia: H > M > S", w.at("damp_cmd", 22) > w.at("damp_cmd", 10) > w.at("damp_cmd", 28.5),
          (w.at("damp_cmd", 22), w.at("damp_cmd", 10), w.at("damp_cmd", 28.5)))

    w = Wycinek("tlumienie_user")
    print("── tryb U: przód +2, tył −3 ──")
    check("korekta przodu +2, tyłu −3", w.at("damp_user_f", 1) == 2 and w.at("damp_user_r", 1) == -3,
          (w.at("damp_user_f", 1), w.at("damp_user_r", 1)))
    check("tryb tłumienia U (3)", w.at("damp_mode", 1) == 3)

    print("── tempomat ──")
    on, off = Wycinek("tempomat_wl"), Wycinek("tempomat_wyl")
    check("włącznik tempomatu (0x341 b3 bit 0x10): włączony / wyłączony",
          on.bit(0x341, 3, 0x10, 1) and not off.bit(0x341, 3, 0x10, 1))

    w = Wycinek("kolo_przod")
    print("── przednie koło kręcone ręką na stojaku ──")
    check("prędkość przodu rośnie, tył stoi", w.all("speed_f").max() > 800 * 0.01 and w.all("speed_r").max() == 0,
          f"przód do {w.all('speed_f').max():.2f}")
    pulses = canlog.unwrap(w.all("wheel_cnt"), 65536)[-1]
    check("licznik impulsów przodu liczy (138 impulsów)", pulses == 138, pulses)
    t, v = w.ks["speed_f"]
    dist = float(np.sum((v[1:] + v[:-1]) / 2 * np.diff(t))) / 3.6
    check("całka prędkości ↔ licznik: ok. 50 impulsów na obrót koła (obwód 1,884 m)",
          near(pulses / (dist / 1.884), 50, 2.5), round(pulses / (dist / 1.884), 1))

    w = Wycinek("kolo_tyl")
    print("── tylne koło kręcone ręką na stojaku ──")
    check("prędkość tyłu rośnie, przód stoi", w.all("speed_r").max() > 5 and w.all("speed_f").max() == 0,
          f"tył do {w.all('speed_r').max():.2f}")
    check("licznik impulsów (przedni) stoi", np.ptp(w.all("wheel_cnt")) == 0)

    w = Wycinek("kierowca_siada")
    print("── kierowca (ok. 90 kg) siada na motocyklu ──")
    check("przód: nóżka 1290 → z kierowcą ok. 1119", w.at("susp_front", 2) == 1290 and near(w.at("susp_front", 18), 1119, 4),
          (w.at("susp_front", 2), w.at("susp_front", 18)))
    check("tył: nóżka 656 → z kierowcą poniżej 480", w.at("susp_rear", 2) == 656 and w.at("susp_rear", 18) < 480,
          (w.at("susp_rear", 2), w.at("susp_rear", 18)))
    check("przechył: nóżka −14,5° → pion ok. −1,5°", near(w.at("lean", 2), -14.5, 0.5) and near(w.at("lean", 18), -1.5, 1.5),
          (round(w.at("lean", 2), 1), round(w.at("lean", 18), 1)))

    print()
    print("WYNIK: wszystko OK" if failed == 0 else f"WYNIK: {failed} błędów", f"({count} sprawdzeń)")
    return 1 if failed else 0


if __name__ == "__main__":
    if "--rebuild" in sys.argv:
        rebuild()
    sys.exit(run())
