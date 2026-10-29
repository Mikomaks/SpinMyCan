// Wzór pliku z kluczem do podpisywania programu płytki (aktualizacja przez Bluetooth).
//
// Prawdziwy plik nazywa się ota_key.h, leży obok i NIE trafia do repozytorium.
// Tworzy go `make fw-key` (32 losowe bajty). Ten sam klucz musi mieć płytka
// (wkompilowany przy wgraniu kablem) i komputer, który podpisuje kolejne wersje
// (`make fw-bundle`). Kto ma klucz, może wgrać płytce program przez Bluetooth —
// nie wysyłać go nikomu i nie wklejać do apki.
//
// Utrata klucza nie jest groźna: wystarczy wygenerować nowy i raz wgrać płytkę kablem.

#pragma once
#include <stdint.h>

static const uint8_t OTA_KEY[32] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
