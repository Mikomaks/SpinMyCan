#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Przerabia film na gotowe klatki JPEG dla wyświetlacza motocykla (ekran „Wideo TT”).

    tools/video_frames.py video/isle_of_man_tt.mp4 MySpin/video_tt.mjpg

Po co: apka nie dekoduje filmu w telefonie. Odtwarzacz iOS (AVPlayer) i odświeżanie
ekranu (CADisplayLink) stają, gdy telefon jest zablokowany albo apka jest w tle — a tak
się jeździ. Gotowe klatki apka tylko podaje według zegara: zero dekodowania, zero GPU,
działa w tle. Klatki mają od razu rozmiar wyświetlacza (864×320, wypełnienie z przycięciem).

Format pliku (little-endian):
    "MSV1"  u16 fps  u16 0  u32 liczba_klatek  (liczba+1) × u32 przesunięcie od początku danych
    potem klatki JPEG jedna za drugą.

Wymaga ffmpeg (brew install ffmpeg) z dekoderem AV1 (libdav1d) — film źródłowy jest w AV1.
"""
import argparse
import glob
import os
import shutil
import struct
import subprocess
import sys
import tempfile

W, H = 864, 320


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--fps", type=int, default=15, help="wyświetlacz bierze średnio ~13, najwyżej ~20 klatek/s")
    ap.add_argument("--q", type=int, default=6, help="jakość JPEG ffmpeg (2 najlepsza … 31); 6 ≈ 25 kB/klatkę")
    args = ap.parse_args()

    if not shutil.which("ffmpeg"):
        sys.exit("Brak ffmpeg — zainstaluj: brew install ffmpeg")
    tmp = tempfile.mkdtemp(prefix="video_frames_")
    try:
        vf = "fps=%d,scale=%d:%d:force_original_aspect_ratio=increase:flags=lanczos,crop=%d:%d" % (args.fps, W, H, W, H)
        subprocess.run(["ffmpeg", "-v", "error", "-i", args.src, "-an", "-vf", vf, "-q:v", str(args.q),
                        "-f", "image2", os.path.join(tmp, "%06d.jpg")], check=True)
        frames = sorted(glob.glob(os.path.join(tmp, "*.jpg")))
        if not frames:
            sys.exit("ffmpeg nie dał żadnej klatki")
        offsets, pos = [], 0
        for f in frames:
            offsets.append(pos)
            pos += os.path.getsize(f)
        offsets.append(pos)
        part = args.out + ".part"
        with open(part, "wb") as out:
            out.write(b"MSV1" + struct.pack("<HHI", args.fps, 0, len(frames)))
            out.write(struct.pack("<%dI" % len(offsets), *offsets))
            for f in frames:
                with open(f, "rb") as fh:
                    out.write(fh.read())
        os.replace(part, args.out)
        print("%s: %d klatek, %d kl./s (%.0f s), średnio %.1f kB, razem %.1f MB"
              % (args.out, len(frames), args.fps, len(frames) / args.fps, pos / len(frames) / 1024, pos / 1048576))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
