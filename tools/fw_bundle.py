#!/usr/bin/env python3
"""Klucz i podpis programu płytki do aktualizacji przez Bluetooth.

    fw_bundle.py key                 # utwórz firmware/can-ble-bridge/src/ota_key.h (jeśli go nie ma)
    fw_bundle.py sign BIN OUT_DIR    # podpisz BIN i połóż w OUT_DIR jako bridge_fw.bin + bridge_fw.json

Podpis to HMAC-SHA256 całego pliku kluczem z ota_key.h. Apka dostaje tylko gotowy
podpis (bridge_fw.json), nigdy klucz — sama niczego nie podpisze.
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY_H = os.path.join(ROOT, "firmware", "can-ble-bridge", "src", "ota_key.h")
CORE_H = os.path.join(ROOT, "firmware", "can-ble-bridge", "src", "bridge_core.h")


def read_key():
    if not os.path.exists(KEY_H):
        sys.exit("Brak klucza — najpierw: make fw-key")
    body = open(KEY_H).read()
    block = re.search(r"OTA_KEY\[32\]\s*=\s*\{([^}]*)\}", body)
    key = bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", block.group(1))) if block else b""
    if len(key) != 32:
        sys.exit("ota_key.h: nie znalazłem 32 bajtów klucza")
    if key == bytes(32):
        sys.exit("ota_key.h zawiera same zera — to wzór, nie klucz (make fw-key)")
    return key


def cmd_key():
    if os.path.exists(KEY_H):
        read_key()
        print("Klucz już jest:", os.path.relpath(KEY_H, ROOT), "(nie nadpisuję)")
        return
    key = secrets.token_bytes(32)
    rows = [", ".join("0x%02X" % b for b in key[i:i + 16]) for i in (0, 16)]
    # 0600 od chwili utworzenia — bez okienka, w którym plik jest czytelny dla innych
    with os.fdopen(os.open(KEY_H, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
        f.write("// Klucz do podpisywania programu płytki. NIE trafia do repozytorium, nie wysyłać nikomu.\n"
                "// Opis: ota_key.example.h.\n\n#pragma once\n#include <stdint.h>\n\n"
                "static const uint8_t OTA_KEY[32] = {\n    %s,\n    %s,\n};\n" % (rows[0], rows[1]))
    print("Utworzono klucz:", os.path.relpath(KEY_H, ROOT))
    print("Płytka pozna go dopiero po wgraniu kablem (make fw-flash).")


def fw_version(override=None):
    if override is not None:
        return int(override)
    m = re.search(r"#else\s*\nstatic const uint8_t FW_VERSION = (\d+);", open(CORE_H).read())
    if not m:
        sys.exit("bridge_core.h: nie znalazłem FW_VERSION")
    return int(m.group(1))


def cmd_sign(bin_path, out_dir, version=None):
    key = read_key()
    data = open(bin_path, "rb").read()
    if len(data) < 64 * 1024 or data[0] != 0xE9:
        sys.exit("%s nie wygląda na program płytki" % bin_path)
    tag = hmac.new(key, data, hashlib.sha256).hexdigest()
    os.makedirs(out_dir, exist_ok=True)
    shutil.copyfile(bin_path, os.path.join(out_dir, "bridge_fw.bin"))
    meta = {"version": fw_version(version), "size": len(data), "hmac": tag,
            "sha256": hashlib.sha256(data).hexdigest()}
    with open(os.path.join(out_dir, "bridge_fw.json"), "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print("Podpisano program v%d, %d bajtów → %s" % (meta["version"], meta["size"], out_dir))


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["key"]:
        cmd_key()
    elif a[:1] == ["sign"] and len(a) in (3, 4):
        cmd_sign(a[1], a[2], a[3] if len(a) == 4 else None)
    else:
        sys.exit(__doc__)
