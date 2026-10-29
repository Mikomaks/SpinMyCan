#!/bin/bash
# Grafiki do README z klatek wyrenderowanych przez apkę (README_SHOTS=1 w symulatorze).
#   tools/readme_media.sh <katalog Documents/readme z symulatora>
# Wymaga ffmpeg. Wynik: docs/media/*.gif + still_*.png
set -e
SRC="$1"; OUT="$(dirname "$0")/../docs/media"
[ -d "$SRC" ] || { echo "Podaj katalog z klatkami (Documents/readme w kontenerze apki)"; exit 1; }
mkdir -p "$OUT"
for a in classic hacker lean; do
  ffmpeg -v error -y -framerate 12 -i "$SRC/anim_${a}_%04d.png" \
    -vf "split[s0][s1];[s0]palettegen=max_colors=192:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    -loop 0 "$OUT/$a.gif"
done
cp "$SRC"/still_*.png "$OUT"/
echo "Gotowe: $OUT"
