#!/usr/bin/env python3
"""Nagrywa surowe ramki CAN z płytki mostka przez USB (komputer wpięty kablem USB-C).

Płytka po wysłaniu 'r' wypisuje KAŻDĄ ramkę z szyny (`1A1 [8] 00 11 …`). Ten skrypt
włącza zrzut, przez zadany czas zapisuje ramki w formacie `candump -l` (czyta go
canlog.py) i na koniec zrzut wyłącza. Do szukania sygnałów na postoju:

    sercap.py --seconds 8 --out canlogs/stol/baza.log        # nic nie ruszać
    sercap.py --seconds 8 --out canlogs/stol/hamulec.log     # trzymać hamulec
    canlog.py diff canlogs/stol/baza.log canlogs/stol/hamulec.log

Bez zależności (port otwierany przez termios). Przy pełnej szynie (~2000 ramek/s)
USB potrafi zgubić część linii — do porównań stanów to nie przeszkadza; uszkodzone
linie są odrzucane (liczba bajtów musi zgadzać się z długością ramki).
"""
import argparse
import glob
import os
import re
import select
import sys
import termios
import time

FRAME = re.compile(rb"^([0-9A-F]{3,8}) \[(\d)\]((?: [0-9A-F]{2})*)$")


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attr = termios.tcgetattr(fd)
    attr[0] = 0                                   # iflag: bez tłumaczenia znaków
    attr[1] = 0                                   # oflag
    attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attr[3] = 0                                   # lflag: tryb surowy
    attr[6][termios.VMIN] = 0
    attr[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    return fd


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="domyślnie pierwszy /dev/cu.usbmodem*")
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--quiet", action="store_true", help="bez tabeli ID na końcu")
    args = ap.parse_args()

    port = args.port
    if not port:
        ports = sorted(glob.glob("/dev/cu.usbmodem*"))
        if not ports:
            sys.exit("Płytka nie jest podłączona przez USB (brak /dev/cu.usbmodem*)")
        port = ports[0]

    fd = open_port(port)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    buf = b""
    frames = 0
    bad = 0
    ids = {}
    stats = ""
    rejected = []
    dumping = False
    asked = 0.0
    t0 = None          # czas pierwszej ramki — od niej liczymy długość nagrania
    opened = time.time()

    with open(args.out, "w") as out:
        while True:
            now = time.time()
            if t0 is not None and now - t0 >= args.seconds:
                break
            if t0 is None and now - opened > 6.0:
                break
            # Zrzut jest przełącznikiem: wysyłamy 'r' dopiero, gdy przez chwilę nie widać ramek.
            if not dumping and now - opened > 0.5 and now - asked > 1.5:
                os.write(fd, b"r")
                asked = now
            r, _, _ = select.select([fd], [], [], 0.2)
            if not r:
                continue
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                continue
            if not chunk:
                continue
            now = time.time()
            buf += chunk
            lines = buf.split(b"\n")
            buf = lines.pop()
            for raw in lines:
                line = raw.strip()
                m = FRAME.match(line)
                if not m:
                    if line.startswith(b"fw=") or line.startswith(b"SYMULACJA"):
                        stats = line.decode(errors="replace")
                    elif line:
                        bad += 1
                        if len(rejected) < 5:
                            rejected.append(line[:60].decode(errors="replace"))
                    continue
                dlc = int(m.group(2))
                data = m.group(3).replace(b" ", b"")
                if len(data) != 2 * dlc:
                    bad += 1
                    continue
                dumping = True
                if t0 is None:
                    t0 = now
                cid = int(m.group(1), 16)
                ids[cid] = ids.get(cid, 0) + 1
                frames += 1
                out.write("(%.6f) can0 %03X#%s\n" % (now, cid, data.decode()))

    if dumping:
        os.write(fd, b"r")      # wyłącz zrzut, żeby płytka nie mieliła USB bez potrzeby
        time.sleep(0.2)
    os.close(fd)

    if t0 is None:
        print("Brak ramek z płytki.", "Ostatni stan: " + stats if stats else "Płytka nic nie wypisała.")
        sys.exit(1)
    span = max(time.time() - t0, 0.001)
    print("%s: %d ramek, %d ID, %.0f ramek/s, odrzucone linie: %d" % (args.out, frames, len(ids), frames / span, bad))
    if rejected:
        print("odrzucone:", " | ".join(rejected))
    if stats:
        print("płytka:", stats)
    if not args.quiet:
        print("  ".join("%03X:%d" % (k, v) for k, v in sorted(ids.items())))


if __name__ == "__main__":
    main()
