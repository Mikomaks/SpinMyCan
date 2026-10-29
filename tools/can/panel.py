#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Panel w przeglądarce do oglądania ramek CAN na żywo albo z nagrania.

    make can-panel                       # otwiera http://127.0.0.1:8765
    tools/can/panel.py --replay canlogs/stol/kolo_przod.log

Źródła:
  * płytka wpięta kablem USB (to samo, co robi sercap.py: włącza zrzut ramek 'r'),
  * nagrania `candump -l` (canlogs/stol/*.log, tools/can/dowody/*.log) i logi z apki (can_*.csv).

Serwer tylko podaje ramki; całe oglądanie (tabela, bity, przebiegi, tłumaczenie znanych
sygnałów) robi strona w tools/can/panel/index.html. Tabela znanych sygnałów jest brana
wprost z canlog.py (KNOWN), więc panel nie ma własnej, drugiej kopii.

Bez zależności poza bibliotekami standardowymi; CSV z apki wymaga numpy (/usr/bin/python3 je ma).
"""
import argparse
import atexit
import bisect
import collections
import glob
import json
import os
import select
import signal
import sys
import threading
import time
import webbrowser
from array import array
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

import sercap  # noqa: E402  (open_port i wzorzec linii z płytki)


def known_signals():
    """KNOWN z canlog.py jako lista słowników (jedno źródło prawdy)."""
    import canlog
    return [dict(name=n, id=cid, byte=b, kind=k, scale=s, offset=o, unit=u, note=note)
            for n, cid, b, k, s, o, u, note in canlog.KNOWN]


# ── Rozgłaszanie ramek do przeglądarek ───────────────────────────────────────

class Hub:
    """Kolejka partii ramek; każda przeglądarka (SSE) czyta od swojego kursora."""

    def __init__(self):
        self.cond = threading.Condition()
        self.seq = 0
        self.epoch = 0
        self.batches = collections.deque(maxlen=400)   # (seq, epoch, [[t, id, hex], ...])
        self.status = {"mode": "idle", "info": "start"}

    def push(self, frames):
        if not frames:
            return
        with self.cond:
            self.seq += 1
            self.batches.append((self.seq, self.epoch, frames))
            self.cond.notify_all()

    def reset(self):
        """Nowy przebieg (przewinięcie, zmiana źródła) — przeglądarka czyści historię."""
        with self.cond:
            self.epoch += 1
            self.batches.clear()
            self.cond.notify_all()

    def set_status(self, **kw):
        with self.cond:
            self.status.update(kw)
            self.cond.notify_all()


HUB = Hub()


# ── Źródło: płytka przez USB ─────────────────────────────────────────────────

class LiveSource(threading.Thread):
    def __init__(self, port=None):
        super().__init__(daemon=True)
        self.port = port
        self.stop_ev = threading.Event()

    def run(self):
        fd = None
        dumping = False
        try:
            while not self.stop_ev.is_set():
                if fd is None:
                    path = self.port or next(iter(sorted(glob.glob("/dev/cu.usbmodem*"))), None)
                    if not path:
                        HUB.set_status(mode="live", info="Płytka nie jest podłączona przez USB — czekam…", connected=False)
                        self.stop_ev.wait(1.5)
                        continue
                    try:
                        fd = sercap.open_port(path)
                    except OSError as e:
                        HUB.set_status(mode="live", info="Nie mogę otworzyć %s: %s" % (path, e), connected=False)
                        self.stop_ev.wait(1.5)
                        continue
                    opened = time.time()
                    asked = 0.0
                    dumping = False
                    buf = b""
                    t0 = None
                    HUB.reset()
                    HUB.set_status(mode="live", info="Połączono z %s" % path, connected=True)
                now = time.time()
                if not dumping and now - opened > 0.5 and now - asked > 1.5:
                    os.write(fd, b"r")          # 'r' to przełącznik — pytamy dopiero, gdy cisza
                    asked = now
                try:
                    r, _, _ = select.select([fd], [], [], 0.05)
                    chunk = os.read(fd, 65536) if r else b""
                except (BlockingIOError, InterruptedError):
                    continue
                except OSError:                  # płytkę wyciągnięto
                    os.close(fd)
                    fd = None
                    continue
                if not chunk:
                    continue
                now = time.time()
                buf += chunk
                lines = buf.split(b"\n")
                buf = lines.pop()
                out = []
                for raw in lines:
                    line = raw.strip()
                    m = sercap.FRAME.match(line)
                    if not m:
                        if line.startswith(b"fw="):
                            HUB.set_status(board=line.decode(errors="replace"))
                        continue
                    dlc = int(m.group(2))
                    data = m.group(3).replace(b" ", b"")
                    if len(data) != 2 * dlc:
                        continue
                    dumping = True
                    if t0 is None:
                        t0 = now
                        HUB.set_status(start=t0)        # zegar w panelu: godzina = start + czas ramki
                    out.append([round(now - t0, 4), int(m.group(1), 16), data.decode()])
                HUB.push(out)
        finally:
            if fd is not None:
                if dumping:
                    try:
                        os.write(fd, b"r")      # wyłącz zrzut, żeby płytka nie mieliła USB bez potrzeby
                    except OSError:
                        pass
                os.close(fd)

    def stop(self):
        self.stop_ev.set()
        self.join(2.0)


# ── Źródło: nagranie ─────────────────────────────────────────────────────────

PHONE_ID = 0x7F0   # sztuczna ramka z danymi telefonu w logu z apki (opis w index.html)


def _phone_bytes(kmh, lean, g, acc):
    def u16(v, scale):
        return max(0, min(65535, int(round(v * scale)))) if v == v else 0
    def s16o(v, scale):
        return max(0, min(65535, int(round(v * scale)) + 32768)) if v == v else 32768
    a, b, c = u16(kmh, 100), s16o(lean, 100), u16(g, 1000)
    return bytes([a >> 8, a & 255, b >> 8, b & 255, c >> 8, c & 255, max(0, min(255, int(acc))) if acc == acc else 255, 0])


def log_start(path):
    """Czas startu logu z apki (nagłówek „start 2026-10-17T15:16:25Z”) jako unix; None gdy brak."""
    import calendar
    try:
        with open(path, "r", errors="replace") as f:
            head = f.readline()
        stamp = head.split("start", 1)[1].strip()
        return calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))
    except (IndexError, ValueError, OSError):
        return None


JOY = {30: "▲", 31: "▼", 32: "◀", 33: "▶", 12: "OK"}


def load_marks(path, duration):
    """Znaczniki dla logu z apki: M z samego logu + zdarzenia E z dziennika łącza z tej samej jazdy."""
    marks = []
    if not path.endswith(".csv"):
        return marks
    start = log_start(path)
    with open(path, "r", errors="replace") as f:
        for line in f:
            if line.startswith("M,") or line.startswith("S,"):
                p = line.rstrip("\n").split(",", 2)
                text = p[2] if len(p) > 2 else "●"
                try:
                    marks.append({"t": float(p[1]), "text": ("♪ " + text) if line[0] == "S" else text,
                                  "src": "m"})
                except (ValueError, IndexError):
                    pass
    if start is None:
        return marks
    for lp in glob.glob(os.path.join(os.path.dirname(path), "link_*.csv")):
        with open(lp, "r", errors="replace") as f:
            for line in f:
                if not line.startswith("E,"):
                    continue
                p = line.rstrip("\n").split(",", 3)
                try:
                    t = float(p[1]) - start
                except (ValueError, IndexError):
                    continue
                if t > duration + 5:
                    break
                if t < -5:
                    continue
                text = p[3] if len(p) > 3 else ""
                if "Joystick" in text:
                    if "↓" not in text:
                        continue
                    try:
                        key = int(text.split("keyId=")[1].split()[0])
                    except (IndexError, ValueError):
                        key = -1
                    marks.append({"t": t, "text": JOY.get(key, "key %d" % key), "src": "joy"})
                    continue
                if text.startswith("  ") or "ścieżka TCP" in text:
                    continue          # szczegóły handshake i zmiany ścieżki — za dużo szumu
                marks.append({"t": t, "text": "%s: %s" % (p[2], text.strip()), "src": p[2]})
    marks.sort(key=lambda m: m["t"])
    return marks


def load_track(path):
    """Trasa GPS z logu z apki: [[t, lat, lon, km/h], ...] co ok. 0,5 s (tylko punkty z fixem)."""
    if not path.endswith(".csv"):
        return []
    import canlog
    log = canlog.load(path)
    ph, out, last = log.phone, [], -1.0
    for i, t in enumerate(log.phone_t):
        lat, lon = ph["lat"][i], ph["lon"][i]
        if lat != lat or lon != lon or (lat == 0 and lon == 0) or t - last < 0.5:
            continue
        last = float(t)
        kmh = ph["kmh"][i]
        out.append([round(float(t), 2), round(float(lat), 6), round(float(lon), 6), round(float(kmh), 1) if kmh == kmh else None])
    return out


def load_frames(path):
    """-> (czasy, identyfikatory, dane 8 bajtów na ramkę, czas unix startu albo None).

    Czas ramek jest względny: od startu logu z apki albo od pierwszej ramki candump."""
    ts, ids, data = array("d"), array("I"), bytearray()
    if path.endswith(".csv"):
        import canlog
        log = canlog.load(path)
        rows = []
        for cid in log.t:
            for t, d in zip(log.t[cid], log.d[cid]):
                rows.append((float(t), cid, bytes(int(x) for x in d)))
        ph = log.phone
        for i, t in enumerate(log.phone_t):
            rows.append((float(t), PHONE_ID, _phone_bytes(ph["kmh"][i], ph["phone_lean"][i], ph["g"][i], ph["gps_acc"][i])))
        rows.sort(key=lambda r: r[0])
        for t, cid, d in rows:
            ts.append(t)
            ids.append(cid)
            data += d.ljust(8, b"\0")[:8]
    else:
        with open(path, "r") as f:
            for line in f:
                try:
                    t = float(line[1:line.index(")")])
                    rest = line.split(" ", 2)[2].strip()
                    cid, hexdata = rest.split("#")
                    d = bytes.fromhex(hexdata)
                    ts.append(t)
                    ids.append(int(cid, 16))
                    data += d.ljust(8, b"\0")[:8]
                except (ValueError, IndexError):
                    continue
    if not len(ts):
        raise ValueError("w pliku nie ma ramek")
    t0 = 0.0 if path.endswith(".csv") else ts[0]
    start = log_start(path) if path.endswith(".csv") else ts[0]
    for i in range(len(ts)):
        ts[i] -= t0
    return ts, ids, data, start


class ReplaySource(threading.Thread):
    # Ramki sprzed miejsca przewinięcia, żeby ekran i wykresy od razu były pełne:
    # do 30 min wstecz, ale nie więcej niż 60 tys. ramek (log z apki: ~8 min, pełna szyna: ~30 s).
    PREROLL = 1800.0
    PREROLL_MAX = 60000

    def __init__(self, path):
        super().__init__(daemon=True)
        self.path = path
        self.stop_ev = threading.Event()
        self.lock = threading.Lock()
        self.paused = False
        self.speed = 1.0
        self.loop = True
        self.seek_to = 0.0       # sekundy w nagraniu; None = brak żądania
        self.name = os.path.relpath(path, ROOT) if path.startswith(ROOT) else path
        self.marks = []
        self.track = []

    def frame(self, i):
        return [round(self.ts[i], 4), self.ids[i], self.data[i * 8:i * 8 + 8].hex().upper()]

    def run(self):
        HUB.set_status(mode="replay", info="Wczytuję %s…" % self.name, connected=True)
        try:
            self.ts, self.ids, self.data, self.start = load_frames(self.path)
        except Exception as e:                      # noqa: BLE001 — pokaż użytkownikowi
            HUB.set_status(mode="replay", info="Błąd wczytywania: %s" % e)
            return
        n = len(self.ts)
        dur = self.ts[-1]
        try:
            self.marks = load_marks(self.path, dur)
        except Exception:                           # noqa: BLE001 — znaczniki są dodatkiem
            self.marks = []
        try:
            self.track = load_track(self.path)
        except Exception:                           # noqa: BLE001 — trasa też
            self.track = []
        HUB.set_status(extras=HUB.status.get("extras", 0) + 1)   # strona dociąga znaczniki i trasę
        pos = 0.0
        idx = 0
        last = time.monotonic()
        while not self.stop_ev.is_set():
            now = time.monotonic()
            dt, last = now - last, now
            with self.lock:
                seek, self.seek_to = self.seek_to, None
                paused, speed, loop = self.paused, self.speed, self.loop
            if seek is not None:
                pos = max(0.0, min(seek, dur))
                HUB.reset()
                idx = bisect.bisect_left(self.ts, pos)
                start = max(bisect.bisect_left(self.ts, pos - self.PREROLL), idx - self.PREROLL_MAX)
                HUB.push([self.frame(i) for i in range(start, idx)])
            if not paused:
                pos += dt * speed
                end = bisect.bisect_right(self.ts, pos, idx)
                out = [self.frame(i) for i in range(idx, min(end, idx + 6000))]
                idx = idx + len(out)
                HUB.push(out)
                if idx >= n:
                    if loop:
                        with self.lock:
                            self.seek_to = 0.0
                    else:
                        with self.lock:
                            self.paused = True
            HUB.set_status(mode="replay", info=self.name, connected=True, pos=round(pos, 2), dur=round(dur, 2), start=self.start,
                           frames=n, paused=self.paused, speed=self.speed, loop=self.loop)
            self.stop_ev.wait(0.02)

    def control(self, body):
        with self.lock:
            if "paused" in body:
                self.paused = bool(body["paused"])
            if "speed" in body:
                self.speed = max(0.05, min(float(body["speed"]), 120.0))
            if "loop" in body:
                self.loop = bool(body["loop"])
            if "seek" in body:
                self.seek_to = float(body["seek"])

    def stop(self):
        self.stop_ev.set()
        self.join(2.0)


class Sources:
    def __init__(self):
        self.cur = None
        self.lock = threading.Lock()

    def start(self, kind, path=None):
        with self.lock:
            if self.cur:
                self.cur.stop()
                self.cur = None
            HUB.reset()
            HUB.status = {"mode": "idle", "info": "…"}
            self.cur = LiveSource() if kind == "live" else ReplaySource(path)
            self.cur.start()

    def stop(self):
        with self.lock:
            if self.cur:
                self.cur.stop()
                self.cur = None


SOURCES = Sources()


def list_files():
    pats = ["canlogs/**/*.log", "canlogs/can_*.csv", "tools/can/dowody/*.log"]
    out = []
    for p in pats:
        for f in glob.glob(os.path.join(ROOT, p), recursive=True):
            try:
                size = os.path.getsize(f)
            except OSError:
                continue
            if size:
                out.append({"path": os.path.relpath(f, ROOT), "size": size, "mtime": os.path.getmtime(f)})
    out.sort(key=lambda x: -x["mtime"])
    return out


# ── HTTP ─────────────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            with open(os.path.join(HERE, "panel", "index.html"), "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif path == "/api/known":
            self.send_json(known_signals())
        elif path == "/api/marks":
            cur = SOURCES.cur
            self.send_json(cur.marks if isinstance(cur, ReplaySource) else [])
        elif path == "/api/track":
            cur = SOURCES.cur
            self.send_json(cur.track if isinstance(cur, ReplaySource) else [])
        elif path == "/api/files":
            self.send_json(list_files())
        elif path == "/stream":
            self.stream()
        else:
            self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self.send_json({"error": "zły JSON"}, 400)
        if path == "/api/source":
            if body.get("type") == "live":
                SOURCES.start("live")
            elif body.get("type") == "replay":
                full = os.path.realpath(os.path.join(ROOT, body.get("path", "")))
                if not full.startswith(ROOT + os.sep) or not os.path.isfile(full):
                    return self.send_json({"error": "nie ma takiego pliku w projekcie"}, 400)
                SOURCES.start("replay", full)
            else:
                return self.send_json({"error": "nieznane źródło"}, 400)
            return self.send_json({"ok": True})
        if path == "/api/ctl":
            cur = SOURCES.cur
            if isinstance(cur, ReplaySource):
                cur.control(body)
            return self.send_json({"ok": True})
        self.send_error(404)

    def stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        cursor = HUB.seq
        epoch = -1
        try:
            while True:
                with HUB.cond:
                    HUB.cond.wait(0.25)
                    ep = HUB.epoch
                    frames = []
                    for seq, e, fr in list(HUB.batches):
                        if seq > cursor and e == ep:
                            frames.extend(fr)
                    cursor = HUB.seq
                    status = dict(HUB.status)
                msg = {"e": ep, "reset": ep != epoch, "s": status, "f": frames}
                epoch = ep
                self.wfile.write(b"data: " + json.dumps(msg, separators=(",", ":")).encode() + b"\n\n")
                self.wfile.flush()
                time.sleep(0.03)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--replay", help="zacznij od nagrania zamiast od płytki")
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    atexit.register(SOURCES.stop)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if args.replay:
        SOURCES.start("replay", os.path.abspath(args.replay))
    else:
        SOURCES.start("live")

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    srv.daemon_threads = True
    url = "http://127.0.0.1:%d" % args.port
    print("Panel CAN: %s   (Ctrl+C kończy)" % url)
    if not args.no_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        SOURCES.stop()


if __name__ == "__main__":
    main()
