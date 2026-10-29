#!/usr/bin/env python3
"""Narzędzia do rozszyfrowywania magistrali CAN motocykla (GSX-S1000GX).

Czyta dwa formaty:
  * log z apki MySpin (Documents/canlogs/can_*.csv): linie C (ramki, 10 Hz na ID),
    P (telefon: prędkość GPS, przechył, wysokość…), L (zgubione pakiety), M (znaczniki)
  * `candump -l` z Raspberry Pi: (czas) can0 ID#DANE

Polecenia:
  profile LOG            co jest na szynie: częstość, które bajty żyją, liczniki
  diff A B               co różni dwa nagrania (np. hamulec puszczony / wciśnięty)
  decode LOG [--csv F]   znane sygnały w czasie (obroty, bieg, gaz, przechył…)
  check LOG              czy znane sygnały zgadzają się z telefonem (przechył w jeździe!)
  find LOG [--ref R]     które bajty/słowa/liczniki chodzą razem z prędkością GPS,
                         przechyłem, wysokością, obrotami… (ranking kandydatów)
  plot LOG [--out F.png] przebiegi w czasie: prędkość, przechył motocykl/telefon,
                         obroty i bieg, gaz, przyspieszenia, temperatura (wymaga matplotlib)
  field LOG ID POLE      jedno pole w czasie obok kanału odniesienia, np. field L 2F1 w01

Wymaga numpy. Systemowy /usr/bin/python3 go ma; skrypt sam się na niego przełączy.
"""
import os
import re
import sys

try:
    import numpy as np
except ImportError:  # domyślny python3 z Homebrew nie ma numpy
    for alt in ("/usr/bin/python3", "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"):
        if os.path.exists(alt) and os.path.realpath(sys.executable) != os.path.realpath(alt):
            os.execv(alt, [alt] + sys.argv)
    raise

import argparse

# ── Znane sygnały ────────────────────────────────────────────────────────────
# Trzymać zgodne z firmware/can-ble-bridge/src/bridge_core.h i BikeLinkManager.swift.
# Opis dla ludzi: SYGNALY.md. Każdy wiersz jest sprawdzany na prawdziwych nagraniach
# przez verify_decode.py (make can-test) — po zmianie tutaj uruchomić test.
# kind: u8 | u16 (big-endian) | s16o (big-endian z przesunięciem 32768) | u20 (2 bajty + górna połówka trzeciego) | hi4 / lo4 (połówka bajtu)
KNOWN = [
    # nazwa        ID     bajt kind    skala          offset  jednostka  uwagi
    ("rpm",        0x1A1, 0, "u16",  1.0,            0.0, "obr/min", "potwierdzone kalibracją @2500"),
    ("throttle8",  0x1A1, 2, "u8",   1.0,            0.0, "surowe",  "0 = zamknięty, 172 = pełny"),
    ("gear",       0x1A1, 3, "lo4",  1.0,            0.0, "", "dolna połówka bajtu; 0 = luz, 1–6; w połowie zmiany biegu chwilowo 14 (widziane w jeździe) — traktować jako brak wartości"),
    ("lean",       0x1A5, 0, "s16o", 180.0 / 32768,  0.0, "°", "ujemny = lewo; nóżka −15°, a w jeździe 2026-10-13 zgodny z fizyką z GPS (0,98×); telefon zawyżał o ok. 25%"),
    ("clutch_raw", 0x1A5, 5, "u8",   1.0,            0.0, "bity",    "bit 2 (0x04) = sprzęgło wciśnięte (potwierdzone 2026-10-10); 0x10 = przycisk startu; 0x08 = nieustalone"),
    ("temp_c",     0x1A5, 4, "u8",   0.625,        -30.0, "°C",      "płyn chłodzący; potwierdzone z wyświetlaczem 2026-10-10 (88 °C przy 190; ekran opóźniony ~25 s)"),
    ("air_c",      0x231, 5, "u8",   1.0,          -30.0, "°C",      "powietrze jak na wyświetlaczu (potwierdzone 23/28/32 °C); ekran wygładza, szyna reaguje od razu"),
    ("odo_km",     0x231, 2, "u20",  1.0,            0.0, "km", "przebieg; 22980 km zgodne z licznikiem, w jeździe 2026-10-13 przybyło 20 km przy 19,3 km z GPS"),
    ("sdms",       0x331, 5, "hi4",  1.0,            0.0, "",        "górna połówka bajtu = tryb jazdy: 1 = A, 2 = B, 3 = C (potwierdzone 2026-10-10)"),
    ("susp_front", 0x17D, 0, "u16",  1.0,            0.0, "surowe",  "skok przedniego zawieszenia, mniejsza = bardziej ugięte: nóżka 1290, z kierowcą w pionie 1119 (potwierdzone 2026-10-10)"),
    ("susp_rear",  0x17D, 2, "u16",  1.0,            0.0, "surowe",  "skok tylnego zawieszenia, mniejsza = bardziej ugięte: nóżka 656, z kierowcą w pionie ~458; rośnie z napięciem wstępnym"),
    ("damp_cmd",   0x17D, 4, "u8",   1.0,            0.0, "surowe",  "nastawa tłumienia: rośnie z twardością (S 4, M 8–10, H 13) i z trybem obciążenia (SOLO ~8, bagaż 28, DUO 48)"),
    ("damp_mode",  0x32D, 0, "lo4",  1.0,            0.0, "",        "dolna połówka: ACTIVE DAMPING 0 = H, 1 = M, 2 = S, 3 = U (potwierdzone 2026-10-10); górna połówka zależy od trybu jazdy (A 3, B 4, C 5)"),
    ("damp_user_f",0x1AD, 1, "lo4",  1.0,            -7.0, "",        "korekta tłumienia przodu w trybie U, −3…+3 (bajt 0x99 = +2; potwierdzone 2026-10-10)"),
    ("damp_user_r",0x1AD, 2, "lo4",  1.0,            -7.0, "",        "korekta tłumienia tyłu w trybie U, −3…+3 (bajt 0x44 = −3)"),
    ("preload_mode",0x1AD,3, "hi4",  1.0,            0.0, "",        "górna połówka: 2 = AUTO, 3 = SOLO, 4 = SOLO+bagaż, 5 = DUO (potwierdzone 2026-10-10)"),
    ("tc_level",   0x335, 3, "hi4",  1.0,            0.0, "",        "górna połówka: kontrola trakcji w bieżącym trybie jazdy, 0 = OFF, 1–7 (potwierdzone 2026-10-10); to samo w 0x339 i 0x33D"),
    ("cruise_raw", 0x341, 3, "u8",   1.0,            0.0, "bity",    "bit 4 (0x10) = tempomat włączony (potwierdzone wł./wył. 2026-10-10); prędkość zadana do znalezienia w jeździe"),
    ("torque_req", 0x1A9, 2, "s16o", 1.0,            0.0, "surowe",  "kandydat: żądany moment (rośnie z manetką także przy zgaszonym silniku)"),
    ("tps10",      0x1A1, 4, "u16",  1.0 / 64,       0.0, "surowe",  "kandydat: otwarcie przepustnicy, 10 bitów (18 zamknięta, ~40 bieg jałowy, 327 pełny gaz)"),
    ("acc_long",   0x181, 0, "s16o", 1.0 / 5000,     0.0, "g", "filtrowane 100 Hz; DODATNIE = hamowanie (z jazdy: −1,06 × przyspieszenie z prędkości koła, r = −0,98)"),
    ("acc_vert",   0x181, 2, "s16o", 1.0 / 5000,     0.0, "g",       "≈ -1 g na postoju"),
    ("acc_lat",    0x181, 4, "s16o", 1.0 / 5000,     0.0, "g",       "boczne; NIE jest przechyłem"),
    ("gyro_a",     0x180, 0, "s16o", 1.0,            0.0, "surowe",  "żyroskop, skala i osie nieznane"),
    ("gyro_b",     0x180, 2, "s16o", 1.0,            0.0, "surowe",  ""),
    ("gyro_c",     0x180, 4, "s16o", 1.0,            0.0, "surowe",  ""),
    ("fuel_raw",   0x221, 2, "u16",  1.0,            0.0, "surowe",  "kandydat: dawka paliwa — żyje tylko przy pracującym silniku, ≈ obr/2 na ciepłym, do 0,9 × obr na zimnym"),
    ("wheel_cnt",  0x221, 0, "u16",  1.0,            0.0, "impulsy", "licznik impulsów PRZEDNIEGO koła (16 bitów); 26,97 impulsu na metr wg GPS na 19 km (ok. 50 na obrót)"),
    ("speed_f",    0x19D, 0, "u16",  0.01,           0.0, "km/h", "prędkość przedniego koła, jednostka 0,01 km/h — potwierdzona GPS-em w jeździe 2026-10-13 (koło × 1,010 = GPS, równo od 30 do 140 km/h)"),
    ("speed_r",    0x19D, 2, "u16",  0.01,           0.0, "km/h", "prędkość tylnego koła, ta sama jednostka; w równej jeździe czyta 1,5% mniej niż przód (tył/przód = 0,985)"),
]

PHONE_COLS = ["kmh", "phone_lean", "g", "lat", "lon", "alt", "heading", "gps_acc", "temp_c"]


class Log:
    """Ramki pogrupowane po ID + kanały telefonu."""

    def __init__(self):
        self.t = {}       # id -> np.array czasu [s]
        self.d = {}       # id -> np.array (N, 8) uint8
        self.dlc = {}     # id -> najczęstsza długość
        self.n = {}       # id -> np.array liczby ramek na rekord (apka) albo jedynki
        self.phone_t = np.zeros(0)
        self.phone = {}   # nazwa -> np.array (NaN = brak)
        self.lost = 0
        self.marks = []   # (t, tekst)
        self.songs = []   # (t, „wykonawca — tytuł”)
        self.tele = []    # (t, pakiety telemetrii/s, zgubione, najdłuższa przerwa ms)
        self.kind = "?"
        self.path = ""

    @property
    def ids(self):
        return sorted(self.t)

    @property
    def duration(self):
        ends = [v[-1] for v in self.t.values() if len(v)]
        starts = [v[0] for v in self.t.values() if len(v)]
        return (max(ends) - min(starts)) if ends else 0.0

    def rate(self, cid):
        """Ramek na sekundę na szynie (dla logu z apki — z licznika ramek w rekordach)."""
        t = self.t[cid]
        if len(t) < 2:
            return 0.0
        span = t[-1] - t[0]
        return float(self.n[cid][1:].sum() / span) if span > 0 else 0.0


_CANDUMP = re.compile(r"\((\d+\.\d+)\)\s+\w+\s+([0-9A-Fa-f]+)#([0-9A-Fa-f]*)")


def load(path):
    log = Log()
    log.path = path
    rows = {}     # id -> lista (t, bytes, n)
    phone = []
    t_first = None
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            c = line[0]
            if c == "(":
                m = _CANDUMP.match(line)
                if not m:
                    continue
                log.kind = "candump"
                t = float(m.group(1))
                if t_first is None:
                    t_first = t
                data = bytes.fromhex(m.group(3))
                rows.setdefault(int(m.group(2), 16), []).append((t - t_first, data, 1))
            elif c == "C":
                p = line.split(",")
                if len(p) < 6:
                    continue
                log.kind = "apka"
                try:
                    rows.setdefault(int(p[3], 16), []).append((float(p[1]), bytes.fromhex(p[5]), int(p[4])))
                except ValueError:
                    continue
            elif c == "P":
                p = line.split(",")
                vals = []
                for x in p[1:11]:
                    try:
                        vals.append(float(x))
                    except ValueError:
                        vals.append(float("nan"))
                while len(vals) < 10:
                    vals.append(float("nan"))
                phone.append(vals)
            elif c == "L":
                p = line.split(",")
                try:
                    log.lost += int(p[2])
                except (ValueError, IndexError):
                    pass
            elif c == "T":       # jakość łącza: czas, pakiety telemetrii/s, zgubione, najdłuższa przerwa [ms]
                p = line.split(",")
                try:
                    log.tele.append((float(p[1]), int(p[2]), int(p[3]), int(p[4])))
                except (ValueError, IndexError):
                    pass
            elif c == "M":
                p = line.split(",", 2)
                try:
                    log.marks.append((float(p[1]), p[2] if len(p) > 2 else ""))
                except (ValueError, IndexError):
                    pass
            elif c == "S":       # utwór zaczął grać (apka od v1.18.0)
                p = line.split(",", 2)
                try:
                    log.songs.append((float(p[1]), p[2].strip() if len(p) > 2 else ""))
                except (ValueError, IndexError):
                    pass
    for cid, r in rows.items():
        log.t[cid] = np.array([x[0] for x in r])
        arr = np.zeros((len(r), 8), dtype=np.uint8)
        lens = np.zeros(len(r), dtype=int)
        for i, x in enumerate(r):
            b = x[1][:8]
            arr[i, :len(b)] = np.frombuffer(b, dtype=np.uint8)
            lens[i] = len(b)
        log.d[cid] = arr
        log.dlc[cid] = int(np.bincount(lens).argmax()) if len(lens) else 0
        log.n[cid] = np.array([x[2] for x in r])
    if phone:
        a = np.array(phone)
        log.phone_t = a[:, 0]
        for i, name in enumerate(PHONE_COLS):
            log.phone[name] = a[:, i + 1]
        # brak fixu GPS: dokładność < 0 → prędkość i pozycja nieważne
        bad = ~(log.phone["gps_acc"] > 0)
        for name in ("kmh", "lat", "lon", "alt", "heading"):
            v = log.phone[name].copy()
            v[bad] = np.nan
            log.phone[name] = v
        h = log.phone["heading"].copy()
        h[h < 0] = np.nan
        log.phone["heading"] = h
    return log


# ── Dekodowanie pól ──────────────────────────────────────────────────────────

def field(log, cid, byte, kind):
    d = log.d[cid]
    if kind == "u8":
        return d[:, byte].astype(float)
    if kind == "hi4":      # górna połówka bajtu
        return (d[:, byte] >> 4).astype(float)
    if kind == "lo4":      # dolna połówka bajtu
        return (d[:, byte] & 0x0F).astype(float)
    hi, lo = d[:, byte].astype(np.int64), d[:, byte + 1].astype(np.int64)
    if kind == "u16":
        return (hi * 256 + lo).astype(float)
    if kind == "u16le":
        return (lo * 256 + hi).astype(float)
    if kind == "s16o":
        return (hi * 256 + lo - 32768).astype(float)
    if kind == "u20":      # 20 bitów: dwa bajty i górna połówka trzeciego
        return (hi * 4096 + lo * 16 + (d[:, byte + 2].astype(np.int64) >> 4)).astype(float)
    raise ValueError(kind)


def known_series(log):
    """Znane sygnały: nazwa -> (t, wartości w jednostkach fizycznych)."""
    out = {}
    for name, cid, byte, kind, scale, offset, _unit, _note in KNOWN:
        if cid not in log.t:
            continue
        v = field(log, cid, byte, kind)
        out[name] = (log.t[cid], v * scale + offset)
    if "throttle8" in out and 0x1A1 in log.d:
        d = log.d[0x1A1]
        out["throttle10"] = (log.t[0x1A1], d[:, 2].astype(float) * 4 + (d[:, 3] >> 6))
    return out


def unwrap(v, modulus):
    """Licznik zawijający się modulo → wartość narastająca."""
    step = np.diff(v)
    step = np.where(step < -modulus / 2, step + modulus, step)
    step = np.where(step > modulus / 2, step - modulus, step)
    return np.concatenate([[0.0], np.cumsum(step)])


def resample(t_src, v_src, t_dst):
    """Interpolacja liniowa z pominięciem NaN; poza zakresem → NaN."""
    ok = ~np.isnan(v_src)
    if ok.sum() < 2:
        return np.full(len(t_dst), np.nan)
    out = np.interp(t_dst, t_src[ok], v_src[ok])
    out[(t_dst < t_src[ok][0]) | (t_dst > t_src[ok][-1])] = np.nan
    return out


def corr(a, b):
    ok = ~(np.isnan(a) | np.isnan(b))
    if ok.sum() < 20:
        return 0.0, 0.0, 0.0, 0
    a, b = a[ok], b[ok]
    sa, sb = a.std(), b.std()
    if sa < 1e-9 or sb < 1e-9:
        return 0.0, 0.0, 0.0, int(ok.sum())
    r = float(((a - a.mean()) * (b - b.mean())).mean() / (sa * sb))
    k = r * sb / sa            # b ≈ k·a + c
    c = b.mean() - k * a.mean()
    return r, float(k), float(c), int(ok.sum())


def best_lag(t_a, a, t_b, b, max_lag=1.5, step=0.1):
    """Przesunięcie czasu b względem a (s), przy którym korelacja jest największa."""
    best = (0.0, 0.0)
    for lag in np.arange(-max_lag, max_lag + 1e-9, step):
        r = corr(a, resample(t_b + lag, b, t_a))[0]
        if abs(r) > abs(best[1]):
            best = (float(lag), r)
    return best


# ── Klasyfikacja bajtów ──────────────────────────────────────────────────────

def classify_byte(v):
    """'-' stały, 'L' licznik 0..15, 'S' szum (suma kontrolna albo młodszy bajt słowa),
    liczba = ile różnych wartości przyjmuje żywy, gładki bajt."""
    u = np.unique(v)
    if len(u) == 1:
        return "-"
    if len(v) > 20:
        x = v.astype(float)
        step = np.mod(np.diff(v.astype(int)), 16)
        if v.max() <= 15 and len(u) >= 8 and (step > 0).mean() > 0.9:
            return "L"
        # Szum poznajemy po braku pamięci: kolejne próbki nie mają ze sobą nic wspólnego.
        # Prawdziwy sygnał próbkowany 10+ razy na sekundę jest gładki.
        if len(u) > 24:
            a, b = x[:-1] - x.mean(), x[1:] - x.mean()
            den = np.sqrt((a * a).sum() * (b * b).sum())
            if den > 0 and (a * b).sum() / den < 0.3:
                return "S"
    return str(len(u))


# ── Polecenia ────────────────────────────────────────────────────────────────

def cmd_profile(args):
    log = load(args.log)
    total = sum(log.rate(c) for c in log.ids)
    print(f"{args.log}: format {log.kind}, {log.duration:.1f} s, {len(log.ids)} ID, "
          f"{total:.0f} ramek/s" + (f", zgubione pakiety BLE: {log.lost}" if log.lost else ""))
    print("  ID   ram/s dlc  przykład                  b0  b1  b2  b3  b4  b5  b6  b7")
    for cid in log.ids:
        d = log.d[cid]
        cls = [classify_byte(d[:, i]) for i in range(8)]
        ex = d[len(d) // 2][:log.dlc[cid]].tobytes().hex(" ")
        print(f"  {cid:03X} {log.rate(cid):6.0f} {log.dlc[cid]:3d}  {ex:24s} " + " ".join(f"{c:>3s}" for c in cls))
    print("  (- stały, L licznik kolejności, S suma kontrolna lub szum, liczba = ile różnych wartości)")
    if log.marks:
        print("  znaczniki:")
        for t, text in log.marks:
            print(f"    {t:8.1f} s  {text}")


def _field_stats(log, cid):
    """(etykieta, średnia, odchylenie) dla bajtów 0–5 i słów na parzystych pozycjach."""
    out = []
    d = log.d[cid]
    for i in range(min(log.dlc[cid], 8)):
        v = d[:, i].astype(float)
        out.append((f"b{i}", v.mean(), v.std(), classify_byte(d[:, i])))
    for i in range(0, min(log.dlc[cid], 8) - 1):
        v = field(log, cid, i, "u16")
        out.append((f"w{i}{i + 1}", v.mean(), v.std(), ""))
    return out


def cmd_diff(args):
    a, b = load(args.a), load(args.b)
    print(f"A = {args.a}\nB = {args.b}")
    print("  pole        A (śr ± odch)        B (śr ± odch)       różnica")
    for cid in sorted(set(a.ids) & set(b.ids)):
        fa, fb = _field_stats(a, cid), _field_stats(b, cid)
        for (name, ma, sa, ca), (_, mb, sb, cb) in zip(fa, fb):
            if "L" in (ca, cb) or "S" in (ca, cb):
                continue
            noise = max(sa, sb, 0.25 if name[0] == "b" else 2.0)
            if abs(mb - ma) > args.sigma * noise:
                print(f"  {cid:03X} {name:4s} {ma:10.1f} ± {sa:6.1f}  {mb:10.1f} ± {sb:6.1f}  {mb - ma:+10.1f}")
    for cid in sorted(set(a.ids) ^ set(b.ids)):
        print(f"  {cid:03X} tylko w {'A' if cid in a.t else 'B'}")


def cmd_decode(args):
    log = load(args.log)
    ks = known_series(log)
    if not ks:
        print("brak znanych ramek w logu")
        return
    print(f"{args.log}: {log.duration:.1f} s")
    print("  sygnał        min       śr      max   jednostka")
    units = {k[0]: k[6] for k in KNOWN}
    units["throttle10"] = "surowe (0..~690)"
    for name, (t, v) in ks.items():
        print(f"  {name:11s} {v.min():8.2f} {v.mean():8.2f} {v.max():8.2f}   {units.get(name, '')}")
    if args.csv:
        base = ks.get("lean") or next(iter(ks.values()))
        tt = np.arange(0, log.duration, args.step)
        cols = {"t": tt}
        for name, (t, v) in ks.items():
            cols[name] = resample(t, v, tt)
        for name, v in log.phone.items():
            cols["phone_" + name if not name.startswith("phone") else name] = resample(log.phone_t, v, tt)
        with open(args.csv, "w") as f:
            f.write(",".join(cols) + "\n")
            for i in range(len(tt)):
                f.write(",".join("" if np.isnan(c[i]) else f"{c[i]:.4f}" for c in cols.values()) + "\n")
        print(f"  zapisano {len(tt)} wierszy → {args.csv}")


def cmd_check(args):
    log = load(args.log)
    ks = known_series(log)
    print(f"{args.log}: {log.duration:.0f} s, {len(log.ids)} ID")
    if log.lost:
        print(f"  uwaga: zgubione pakiety BLE: {log.lost}")
    if log.tele:
        a = np.array(log.tele)
        got, lost = a[:, 1].sum(), a[:, 2].sum()
        print(f"  łącze (telemetria): średnio {a[:, 1].mean():.0f} pakietów/s, zgubione {100 * lost / max(got + lost, 1):.1f}%, "
              f"przerwa: mediana {np.median(a[:, 3]):.0f} ms, 95. percentyl {np.percentile(a[:, 3], 95):.0f} ms, max {a[:, 3].max():.0f} ms")
    if not len(log.phone_t):
        print("  brak linii telefonu (P) — nie ma z czym porównać")
        return 1
    kmh = log.phone["kmh"]
    moving = np.nan_to_num(kmh) > 15
    print(f"  jazda >15 km/h: {moving.mean() * 100:.0f}% czasu, vmax GPS {np.nanmax(kmh) if moving.any() else 0:.0f} km/h")
    ok = True

    # 1. Przechył z 0x1A5 kontra telefon — najważniejszy test: czy kąt motocykla żyje w zakrętach.
    if "lean" in ks:
        t, bike = ks["lean"]
        ph = resample(log.phone_t, log.phone["phone_lean"], t)
        mv = resample(log.phone_t, moving.astype(float), t) > 0.5
        span = np.nanpercentile(np.abs(ph[mv]), 95) if mv.sum() > 50 else 0.0
        print("\n  PRZECHYŁ (0x1A5) kontra telefon, tylko w jeździe:")
        if span < 8:
            print(f"    za mało zakrętów w logu (telefon: 95. percentyl |przechyłu| = {span:.1f}°) — test nierozstrzygnięty")
        else:
            lag, _ = best_lag(t[mv], bike[mv], log.phone_t, log.phone["phone_lean"])
            ph2 = resample(log.phone_t + lag, log.phone["phone_lean"], t)
            r, k, c, n = corr(bike[mv], ph2[mv])
            bspan = np.percentile(np.abs(bike[mv]), 95)
            print(f"    korelacja r = {r:+.3f} (próbek {n}), telefon ≈ {k:.2f} × motocykl {c:+.1f}°, opóźnienie telefonu {lag:+.1f} s")
            print(f"    95. percentyl |przechyłu|: motocykl {bspan:.1f}°, telefon {span:.1f}°")
            if r > 0.85 and 0.7 < k < 1.4:
                print("    WYNIK: kąt z motocykla działa w jeździe ✔")
            elif bspan < 0.35 * span:
                print("    WYNIK: motocykl pokazuje ~0° w zakrętach ✘ — to NIE jest kąt z fuzji; wyłączyć „Przechył z czujnika motocykla”")
                ok = False
            else:
                print("    WYNIK: niejednoznaczny — obejrzeć przebiegi (decode --csv)")
                ok = False

    # 2. Licznik impulsów koła kontra prędkość GPS.
    if "wheel_cnt" in ks:
        t, cnt = ks["wheel_cnt"]
        total = unwrap(cnt, 65536 if np.nanmax(cnt) > 255 else 256)   # starszy bajt bywa zerem w krótkich logach
        dt = 1.0
        tt = np.arange(t[0], t[-1], dt)
        rate = np.diff(np.interp(tt, t, total)) / dt
        v = resample(log.phone_t, kmh, tt[:-1] + dt / 2)
        r, k, c, n = corr(rate, v)
        print("\n  LICZNIK PRZEDNIEGO KOŁA (0x221 b0b1) kontra prędkość GPS:")
        if np.nanmax(np.nan_to_num(v)) < 20:
            print("    brak jazdy w logu — test nierozstrzygnięty")
        else:
            print(f"    korelacja r = {r:+.3f} (próbek {n}); km/h ≈ {k:.4f} × impulsy/s {c:+.1f}")
            if r > 0.95 and k > 0:
                per_m = 1 / (k / 3.6)
                print(f"    WYNIK: to prędkość koła ✔ — {per_m:.2f} impulsu na metr")
            else:
                print("    WYNIK: nie wygląda na prędkość ✘")

    # 3. Obroty: przełożenie na biegach (km/h na 1000 obr/min) — kontrola biegu i prędkości.
    if "rpm" in ks and "gear" in ks:
        t, rpm = ks["rpm"]
        gear = ks["gear"][1]
        v = resample(log.phone_t, kmh, t)
        print("\n  PRZEŁOŻENIA (km/h na 1000 obr/min, mediana na biegu):")
        any_gear = False
        for g in range(1, 7):
            m = (gear == g) & (rpm > 2500) & (np.nan_to_num(v) > 15)
            if m.sum() > 30:
                any_gear = True
                ratio = v[m] / rpm[m] * 1000
                print(f"    bieg {g}: {np.median(ratio):5.1f}  (rozrzut {np.percentile(ratio, 10):.1f}–{np.percentile(ratio, 90):.1f}, próbek {m.sum()})")
        if not any_gear:
            print("    brak jazdy na biegu w logu")
    return 0 if ok else 1


def _candidates(log, cid):
    """(etykieta, wartości) — każdy żywy bajt oraz słowa, których STARSZY bajt jest żywy.

    Młodszy bajt prawdziwego słowa wygląda jak szum (przewija się wiele razy), więc
    o słowie decyduje starszy: big-endian = (i, i+1), little-endian = (i+1 starszy, i).
    """
    d = log.d[cid]
    n = min(log.dlc[cid], 8)
    cls = [classify_byte(d[:, i]) for i in range(n)]
    live = [c not in "-LS" for c in cls]
    for i in range(n):
        if live[i]:
            yield f"b{i}", d[:, i].astype(float)
    for i in range(n - 1):
        if live[i] and cls[i + 1] not in "-L":
            yield f"w{i}{i + 1}", field(log, cid, i, "u16")
        if live[i + 1] and cls[i] not in "-L":
            yield f"w{i}{i + 1}le", field(log, cid, i, "u16le")


def _counter_rates(log, cid, dt=1.0):
    """Tempo narastania bajtów, które wyglądają na liczniki zawijające się (impulsy)."""
    d = log.d[cid]
    t = log.t[cid]
    n = min(log.dlc[cid], 8)
    if len(t) < 50 or t[-1] - t[0] < 5 * dt:
        return
    tt = np.arange(t[0], t[-1], dt)
    for i in range(n):
        v = d[:, i].astype(float)
        if len(np.unique(v)) < 8:
            continue
        step = np.diff(v)
        step = np.where(step < 0, step + 256, step)
        # licznik: prawie zawsze idzie w górę małymi krokami
        if (step < 128).mean() < 0.98:
            continue
        total = np.concatenate([[0.0], np.cumsum(step)])
        yield f"b{i}/s", tt[:-1] + dt / 2, np.diff(np.interp(tt, t, total)) / dt


def cmd_find(args):
    log = load(args.log)
    refs = {}
    if len(log.phone_t):
        kmh = log.phone["kmh"]
        refs["kmh"] = (log.phone_t, kmh)
        refs["phone_lean"] = (log.phone_t, log.phone["phone_lean"])
        refs["alt"] = (log.phone_t, log.phone["alt"])
        refs["temp_c"] = (log.phone_t, log.phone["temp_c"])
        refs["g"] = (log.phone_t, log.phone["g"])
        # przyspieszenie wzdłużne z GPS (hamowanie / gaz), wygładzone 1 s
        ok = ~np.isnan(kmh)
        if ok.sum() > 30:
            tt = np.arange(log.phone_t[ok][0], log.phone_t[ok][-1], 0.5)
            v = np.interp(tt, log.phone_t[ok], kmh[ok]) / 3.6
            refs["acc_gps"] = (tt[1:-1], (v[2:] - v[:-2]) / 1.0 / 9.81)
    for name, tv in known_series(log).items():
        if name in ("rpm", "lean", "gear", "throttle10"):
            refs[name] = tv
    if args.ref:
        refs = {k: v for k, v in refs.items() if k in args.ref}
    if not refs:
        print("brak kanałów odniesienia (potrzebne linie P z telefonu albo znane ramki)")
        return 1
    print(f"{args.log}: {log.duration:.0f} s, {len(log.ids)} ID; szukam powiązań z: {', '.join(refs)}")

    known_at = {(k[1], f"b{k[2]}" if k[3] == "u8" else f"w{k[2]}{k[2] + 1}"): k[0] for k in KNOWN}
    # Sygnał odniesienia wzięty z samej szyny nie może „znaleźć" własnych bajtów.
    own = {k[0]: (k[1], {k[2]} if k[3] == "u8" else {k[2], k[2] + 1}) for k in KNOWN}
    own["throttle10"] = (0x1A1, {2, 3})

    def label_bytes(label):
        digits = [int(ch) for ch in label.split("/")[0] if ch.isdigit()]
        return set(digits)
    for rname, (rt, rv) in refs.items():
        if np.nanstd(rv) < 1e-6:
            continue
        rows = []
        for cid in log.ids:
            t = log.t[cid]
            if len(t) < 50:
                continue
            ref = resample(rt, rv, t)
            for label, v in _candidates(log, cid):
                if rname in own and own[rname][0] == cid and label_bytes(label) & own[rname][1]:
                    continue
                r, k, c, n = corr(v, ref)
                if abs(r) >= args.min_r:
                    rows.append((abs(r), cid, label, r, k, c, n))
            for label, tc, v in _counter_rates(log, cid):
                r, k, c, n = corr(v, resample(rt, rv, tc))
                if abs(r) >= args.min_r:
                    rows.append((abs(r), cid, label, r, k, c, n))
        # Słowo zawiera swój starszy bajt — jeśli nie jest gorsze, sam bajt jest zbędny.
        got = {(cid, label): ar for ar, cid, label, *_ in rows}

        def subsumed(cid, label, ar):
            if not (label[0] == "b" and len(label) == 2):
                return False
            i = int(label[1])
            for word in (f"w{i}{i + 1}", f"w{i - 1}{i}le"):
                if got.get((cid, word), 0) >= ar - 0.003:
                    return True
            return False
        rows = [x for x in rows if not subsumed(x[1], x[2], x[0])]
        rows.sort(reverse=True)
        print(f"\n  {rname}:")
        if not rows:
            print(f"    nic powyżej |r| = {args.min_r}")
        for _, cid, label, r, k, c, n in rows[:args.top]:
            tag = known_at.get((cid, label.replace("le", "")), "")
            print(f"    {cid:03X} {label:7s} r = {r:+.3f}   {rname} ≈ {k:.5g} × pole {c:+.4g}   (próbek {n})"
                  + (f"   ← znane: {tag}" if tag else ""))
    return 0


def _window(t, v, t0, t1):
    m = (t >= t0) & (t <= t1)
    return t[m], v[m]


def cmd_plot(args):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    log = load(args.log)
    ks = known_series(log)
    t0 = args.start if args.start is not None else 0.0
    t1 = args.end if args.end is not None else log.duration
    have_phone = len(log.phone_t) > 0
    panels = []

    def speed(ax):
        if have_phone:
            ax.plot(*_window(log.phone_t, log.phone["kmh"], t0, t1), color="#1f77b4", lw=1.2, label="GPS km/h")
        if "wheel_cnt" in ks and have_phone:
            t, cnt = ks["wheel_cnt"]
            tt = np.arange(t[0], t[-1], 1.0)
            if len(tt) > 3:
                rate = np.diff(np.interp(tt, t, unwrap(cnt, 65536 if np.nanmax(cnt) > 255 else 256)))
                mid = tt[:-1] + 0.5
                r, k, c, n = corr(rate, resample(log.phone_t, log.phone["kmh"], mid))
                if r > 0.9:
                    ax.plot(*_window(mid, rate * k + c, t0, t1), color="#d62728", lw=1.0, ls="--",
                            label=f"koło 0x221 (r={r:.3f}, {1 / (k / 3.6):.2f} imp/m)")
                else:
                    ax2 = ax.twinx()
                    ax2.plot(*_window(mid, rate, t0, t1), color="#d62728", lw=0.8, alpha=0.7)
                    ax2.set_ylabel("0x221 b1 imp/s", color="#d62728")
        ax.set_ylabel("prędkość")

    def lean(ax):
        if "lean" in ks:
            ax.plot(*_window(*ks["lean"], t0, t1), color="#2ca02c", lw=1.2, label="motocykl 0x1A5")
        if have_phone:
            ax.plot(*_window(log.phone_t, log.phone["phone_lean"], t0, t1), color="#7f7f7f", lw=0.9, label="telefon")
        ax.axhline(0, color="k", lw=0.4)
        ax.set_ylabel("przechył °  (− lewo)")

    def engine(ax):
        if "rpm" in ks:
            ax.plot(*_window(*ks["rpm"], t0, t1), color="#ff7f0e", lw=1.0, label="obr/min")
        ax.set_ylabel("obr/min")
        if "gear" in ks:
            ax2 = ax.twinx()
            ax2.step(*_window(*ks["gear"], t0, t1), color="#9467bd", lw=1.0, where="post")
            ax2.set_ylim(-0.5, 6.5)
            ax2.set_ylabel("bieg", color="#9467bd")

    def throttle(ax):
        ax.plot(*_window(*ks["throttle10"], t0, t1), color="#8c564b", lw=1.0, label="gaz (0…~690)")
        ax.set_ylabel("gaz")

    def accel(ax):
        for name, col, lab in (("acc_long", "#1f77b4", "wzdłużne"), ("acc_lat", "#d62728", "boczne")):
            if name in ks:
                ax.plot(*_window(*ks[name], t0, t1), color=col, lw=0.8, label=lab)
        if "acc_vert" in ks:
            t, v = ks["acc_vert"]
            ax.plot(*_window(t, -v - 1, t0, t1), color="#2ca02c", lw=0.8, label="pionowe ponad 1 g")
        ax.axhline(0, color="k", lw=0.4)
        ax.set_ylabel("przyspieszenie g")

    def temp(ax):
        ax.plot(*_window(*ks["temp_c"], t0, t1), color="#e377c2", lw=1.0, label="płyn chłodzący")
        if "air_c" in ks:
            ax.plot(*_window(*ks["air_c"], t0, t1), color="#ff7f0e", lw=1.0, label="powietrze (motocykl)")
        if have_phone and not np.all(np.isnan(log.phone["temp_c"])):
            ax.plot(*_window(log.phone_t, log.phone["temp_c"], t0, t1), color="#17becf", lw=0.8, label="powietrze (prognoza)")
        ax.set_ylabel("temperatura °C")

    if have_phone or "wheel_cnt" in ks:
        panels.append(speed)
    if "lean" in ks or have_phone:
        panels.append(lean)
    if "rpm" in ks:
        panels.append(engine)
    if "throttle10" in ks:
        panels.append(throttle)
    if "acc_long" in ks:
        panels.append(accel)
    if "temp_c" in ks:
        panels.append(temp)
    if not panels:
        print("nie ma czego rysować")
        return 1

    fig, axes = plt.subplots(len(panels), 1, figsize=(15, 2.5 * len(panels)), sharex=True)
    axes = np.atleast_1d(axes)
    for ax, fn in zip(axes, panels):
        fn(ax)
        ax.grid(alpha=0.25)
        if ax.get_legend_handles_labels()[0]:
            ax.legend(loc="upper right", fontsize=8)
        for mt, text in log.marks:
            if t0 <= mt <= t1:
                ax.axvline(mt, color="k", lw=0.8, ls=":")
    for mt, text in log.marks:
        if t0 <= mt <= t1:
            axes[0].annotate(text[:40], (mt, 1.0), xycoords=("data", "axes fraction"),
                             fontsize=7, rotation=30, va="bottom")
    axes[-1].set_xlabel("czas od początku logu [s]")
    axes[-1].set_xlim(t0, t1)
    fig.suptitle(os.path.basename(args.log), fontsize=10, y=0.995)
    fig.tight_layout()
    out = args.out or os.path.splitext(args.log)[0] + ".png"
    fig.savefig(out, dpi=110)
    print(f"zapisano {out}")
    return 0


def cmd_field(args):
    """Jedno pole w czasie: do obejrzenia kandydata znalezionego przez `find`."""
    log = load(args.log)
    cid = int(args.id, 16)
    if cid not in log.t:
        print(f"brak ID {cid:03X} w logu")
        return 1
    m = re.fullmatch(r"(b|w)(\d)(\d)?(le)?(/s)?", args.field)
    if not m:
        print("pole: b3 | w23 | w23le | b1/s (tempo licznika)")
        return 1
    i = int(m.group(2))
    kind = "u8" if m.group(1) == "b" else ("u16le" if m.group(4) else "u16")
    t, v = log.t[cid], field(log, cid, i, kind)
    if m.group(5):
        tt = np.arange(t[0], t[-1], 1.0)
        v = np.diff(np.interp(tt, t, unwrap(v, 256 if kind == "u8" else 65536)))
        t = tt[:-1] + 0.5
    ref_t, ref_v = None, None
    if args.ref:
        if args.ref in log.phone:
            ref_t, ref_v = log.phone_t, log.phone[args.ref]
        elif args.ref in known_series(log):
            ref_t, ref_v = known_series(log)[args.ref]
    print(f"{cid:03X} {args.field}: próbek {len(v)}, min {v.min():.4g}, śr {v.mean():.4g}, max {v.max():.4g}")
    if ref_t is not None:
        r, k, c, n = corr(v, resample(ref_t, ref_v, t))
        print(f"  względem {args.ref}: r = {r:+.3f}, {args.ref} ≈ {k:.5g} × pole {c:+.4g}")
    if args.out:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(15, 4))
        ax.plot(t, v, color="#d62728", lw=1.0, label=f"{cid:03X} {args.field}")
        ax.set_ylabel(f"{cid:03X} {args.field}", color="#d62728")
        if ref_t is not None:
            ax2 = ax.twinx()
            ax2.plot(ref_t, ref_v, color="#1f77b4", lw=1.0, alpha=0.8)
            ax2.set_ylabel(args.ref, color="#1f77b4")
        ax.grid(alpha=0.25)
        ax.set_xlabel("czas [s]")
        fig.tight_layout()
        fig.savefig(args.out, dpi=110)
        print(f"  zapisano {args.out}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("profile"); p.add_argument("log"); p.set_defaults(fn=cmd_profile)
    p = sub.add_parser("diff"); p.add_argument("a"); p.add_argument("b")
    p.add_argument("--sigma", type=float, default=4.0, help="ile odchyleń musi dzielić średnie (domyślnie 4)")
    p.set_defaults(fn=cmd_diff)
    p = sub.add_parser("decode"); p.add_argument("log"); p.add_argument("--csv")
    p.add_argument("--step", type=float, default=0.1); p.set_defaults(fn=cmd_decode)
    p = sub.add_parser("check"); p.add_argument("log"); p.set_defaults(fn=cmd_check)
    p = sub.add_parser("find"); p.add_argument("log"); p.add_argument("--ref", action="append")
    p.add_argument("--top", type=int, default=8); p.add_argument("--min-r", type=float, default=0.6)
    p.set_defaults(fn=cmd_find)
    p = sub.add_parser("plot"); p.add_argument("log"); p.add_argument("--out")
    p.add_argument("--start", type=float); p.add_argument("--end", type=float); p.set_defaults(fn=cmd_plot)
    p = sub.add_parser("field"); p.add_argument("log"); p.add_argument("id"); p.add_argument("field")
    p.add_argument("--ref"); p.add_argument("--out"); p.set_defaults(fn=cmd_field)
    args = ap.parse_args()
    return args.fn(args) or 0


if __name__ == "__main__":
    sys.exit(main())
