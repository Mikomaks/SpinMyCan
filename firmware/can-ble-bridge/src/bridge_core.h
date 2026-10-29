// Rdzeń mostka CAN -> BLE: dekodowanie ramek i składanie pakietów dla telefonu.
//
// Celowo bez Arduino, Bluetooth i sterownika CAN — sama logika na bajtach. Dzięki
// temu ten sam kod, który chodzi na płytce, da się skompilować na komputerze
// i przepuścić przez niego prawdziwe nagrania szyny (tools/can/fw_core_test.cpp,
// `make fw-test`). Formaty pakietów opisane w main.cpp.

#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace bridge {

// Numer wydania programu — podbijać przy każdej zmianie; apka pokazuje go w karcie mostka.
#ifdef FW_VERSION_OVERRIDE          // tylko programy testowe aktualizacji (platformio.ini)
static const uint8_t FW_VERSION = FW_VERSION_OVERRIDE;
#else
static const uint8_t FW_VERSION = 10;
#endif

static const uint32_t ID_ENGINE = 0x1A1;   // obroty, gaz, bieg
static const uint32_t ID_LEAN   = 0x1A5;   // kąt przechyłu policzony przez motocykl
static const uint32_t ID_ACCEL  = 0x181;   // przyspieszenia (filtrowane)
static const uint32_t FRESH_MS  = 500;
static const int      RAW_SLOTS = 128;
static const size_t   RAW_HEADER = 6;

struct __attribute__((packed)) Telemetry {
    uint8_t  version;
    uint8_t  flags;
    uint16_t rpm;
    uint8_t  throttle;
    uint8_t  b3;
    uint16_t lean;
    uint16_t accel[3];
    uint16_t busFps;
    uint8_t  seq;
    uint8_t  fwVersion;
    // ── Od FW 4: surowe bajty kolejnych ramek, w kolejności jak na szynie. ──
    // Dekoduje je apka (tools/can/SYGNALY.md), więc nowa skala nie wymaga wgrywania płytki.
    // Pierwsze 18 bajtów zostaje bez zmian — starsza apka czyta je jak dotąd.
    uint8_t  flags2;       // 18: świeżość ramek z tabeli EXTRA (bit = pozycja w tabeli)
    uint8_t  coolant;      // 19: 0x1A5 b4
    uint8_t  switches;     // 20: 0x1A5 b5
    uint8_t  tps[2];       // 21: 0x1A1 b4..b5
    uint8_t  wheel[4];     // 23: 0x19D b0..b3 (koło przednie, tylne)
    uint8_t  pulses[2];    // 27: 0x221 b0..b1
    uint8_t  susp[5];      // 29: 0x17D b0..b4
    uint8_t  env[4];       // 34: 0x231 b2..b5 (przebieg, powietrze)
    uint8_t  rideMode;     // 38: 0x331 b5
    uint8_t  tc[3];        // 39: 0x335 b1..b3
    uint8_t  suspSet[4];   // 42: 0x1AD b0..b3
    uint8_t  dampMode;     // 46: 0x32D b0
    uint8_t  cruise;       // 47: 0x341 b3
    // ── Od FW 8 ──
    uint8_t  connItvl;     // 48: odstęp połączenia Bluetooth przyznany przez telefon [×1,25 ms];
                           //     wpisuje go main.cpp (rdzeń nie zna Bluetooth), 0 = nieznany
};
static_assert(sizeof(Telemetry) == 49, "format pakietu ma 49 bajtow");

// Ramki przepisywane do pakietu bajt w bajt: skąd, ile i dokąd. Pozycja w tabeli
// = numer bitu świeżości w flags2.
struct Extra { uint16_t id; uint8_t from, len, to; };
static const Extra EXTRA[8] = {
    {0x19D, 0, 4, 23},   // bit0: prędkości kół
    {0x17D, 0, 5, 29},   // bit1: zawieszenie
    {0x231, 2, 4, 34},   // bit2: przebieg i powietrze
    {0x331, 5, 1, 38},   // bit3: tryb jazdy
    {0x335, 1, 3, 39},   // bit4: kontrola trakcji
    {0x1AD, 0, 4, 42},   // bit5: nastawy zawieszenia
    {0x32D, 0, 1, 46},   // bit6: tryb tłumienia
    {0x341, 3, 1, 47},   // bit7: tempomat
};
static const uint32_t ID_PULSES = 0x221;   // licznik impulsów przedniego koła

// Ostatnia zawartość jednego ID na szynie (strumień surowy).
struct RawSlot {
    uint16_t id;
    uint8_t  dlc;
    uint8_t  count;      // ramki od poprzedniego zrzutu (nasyca się na 255)
    uint8_t  data[8];
    bool     dirty;      // zawartość zmieniła się od poprzedniego zrzutu
};

struct Core {
    // Zdekodowane wartości (ostatnie widziane)
    uint16_t rpm = 0;
    uint8_t  throttle = 0, b3 = 0;
    uint16_t leanWord = 32768;
    uint16_t accel[3] = {32768, 32768, 32768};
    uint32_t engineAt = 0, leanAt = 0, accelAt = 0;
    bool     engineSeen = false, leanSeen = false, accelSeen = false;
    uint8_t  coolant = 0, switches = 0, tps[2] = {0, 0}, pulses[2] = {0, 0};
    uint32_t pulsesAt = 0;
    bool     pulsesSeen = false;
    uint8_t  extra[48] = {0};          // obraz bajtów 18..47 pakietu (indeksowany jak pakiet)
    uint32_t extraAt[8] = {0};
    bool     extraSeen[8] = {false};

    uint32_t frameCount = 0;
    uint16_t busFps = 0;
    uint8_t  seq = 0;

    RawSlot  rawSlots[RAW_SLOTS];
    int      rawUsed = 0;
    int      rawCursor = 0;   // gdzie skończył poprzedni pakiet bieżącego zrzutu
    uint8_t  rawSeq = 0;

    // Jedna ramka z szyny. Ramki rozszerzone i RTR tylko liczymy.
    void onFrame(uint32_t id, bool extdOrRtr, uint8_t dlcIn, const uint8_t *data, uint32_t now) {
        frameCount++;
        if (extdOrRtr) return;
        uint8_t dlc = dlcIn > 8 ? 8 : dlcIn;
        rawStore(uint16_t(id), dlc, data);
        if (id == ID_ENGINE && dlc >= 4) {
            rpm = uint16_t((uint16_t(data[0]) << 8) | data[1]);
            throttle = data[2];
            b3 = data[3];
            if (dlc >= 6) { tps[0] = data[4]; tps[1] = data[5]; }
            engineAt = now;
            engineSeen = true;
        } else if (id == ID_LEAN && dlc >= 2) {
            leanWord = uint16_t((uint16_t(data[0]) << 8) | data[1]);
            if (dlc >= 6) { coolant = data[4]; switches = data[5]; }
            leanAt = now;
            leanSeen = true;
        } else if (id == ID_PULSES && dlc >= 2) {
            pulses[0] = data[0]; pulses[1] = data[1];
            pulsesAt = now;
            pulsesSeen = true;
        } else if (id == ID_ACCEL && dlc >= 6) {
            for (int i = 0; i < 3; i++) accel[i] = uint16_t((uint16_t(data[2 * i]) << 8) | data[2 * i + 1]);
            accelAt = now;
            accelSeen = true;
        }
        for (int i = 0; i < 8; i++) {
            const Extra &e = EXTRA[i];
            if (id != e.id || dlc < e.from + e.len) continue;
            memcpy(extra + e.to, data + e.from, e.len);
            extraAt[i] = now;
            extraSeen[i] = true;
        }
    }

    // Raz na sekundę: zamyka licznik ramek.
    void secondTick() {
        busFps = frameCount > 65535 ? 65535 : uint16_t(frameCount);
        frameCount = 0;
    }

    Telemetry telemetry(uint32_t now, bool fake) {
        Telemetry p;
        memset(&p, 0, sizeof(p));
        p.version = 2;
        if (engineSeen && now - engineAt < FRESH_MS) p.flags |= 0x01;
        if (leanSeen && now - leanAt < FRESH_MS) p.flags |= 0x02;
        if (accelSeen && now - accelAt < FRESH_MS) p.flags |= 0x04;
        if (pulsesSeen && now - pulsesAt < FRESH_MS) p.flags |= 0x08;
        if (fake) p.flags |= 0x80;
        memcpy(((uint8_t *)&p) + 18, extra + 18, 48 - 18);         // najpierw obraz ramek (bajty 18..47)…
        p.flags2 = 0;                                               // …potem pola liczone tutaj
        for (int i = 0; i < 8; i++)
            if (extraSeen[i] && now - extraAt[i] < FRESH_MS) p.flags2 |= uint8_t(1 << i);
        p.coolant = coolant;
        p.switches = switches;
        memcpy(p.tps, tps, 2);
        memcpy(p.pulses, pulses, 2);
        p.rpm = rpm;
        p.throttle = throttle;
        p.b3 = b3;
        p.lean = leanWord;
        memcpy(p.accel, accel, sizeof(accel));
        p.busFps = busFps;
        p.seq = seq++;
        p.fwVersion = FW_VERSION;
        return p;
    }

    // Składa jeden pakiet strumienia surowego do `buf` (najwyżej `cap` bajtów) i zwraca
    // jego długość; 0 = nie ma czego wysłać. `*done` = bieżący zrzut doszedł do końca
    // tablicy (następne wywołanie zaczyna nowy). `all` bierze także ID bez zmian.
    size_t rawPacket(uint8_t *buf, size_t cap, uint32_t now, bool all, bool *done) {
        buf[0] = 2;
        memcpy(buf + 2, &now, 4);
        size_t len = RAW_HEADER;
        *done = true;
        while (rawCursor < rawUsed) {
            RawSlot &sl = rawSlots[rawCursor];
            if (sl.count == 0 || !(sl.dirty || all)) { rawCursor++; continue; }
            if (len + 4 + sl.dlc > cap) { *done = false; break; }   // reszta w następnym pakiecie
            buf[len++] = uint8_t(sl.id & 0xFF);
            buf[len++] = uint8_t(sl.id >> 8);
            buf[len++] = sl.dlc;
            buf[len++] = sl.count;
            memcpy(buf + len, sl.data, sl.dlc);
            len += sl.dlc;
            sl.count = 0;
            sl.dirty = false;
            rawCursor++;
        }
        if (*done) rawCursor = 0;
        if (len == RAW_HEADER) return 0;
        // Numer dostaje tylko pakiet faktycznie wysłany — pusty zrzut (cisza na szynie)
        // nie może wyglądać w telefonie jak zgubiony pakiet.
        buf[1] = rawSeq++;
        return len;
    }

  private:
    void rawStore(uint16_t id, uint8_t dlc, const uint8_t *data) {
        RawSlot *slot = nullptr;
        for (int i = 0; i < rawUsed; i++) {
            if (rawSlots[i].id == id) { slot = &rawSlots[i]; break; }
        }
        if (!slot) {
            if (rawUsed >= RAW_SLOTS) return;
            slot = &rawSlots[rawUsed++];
            slot->id = id;
            slot->dlc = 0xFF;   // wymusza „zmianę" przy pierwszej ramce
            slot->count = 0;
            slot->dirty = false;
        }
        if (slot->dlc != dlc || memcmp(slot->data, data, dlc) != 0) {
            slot->dlc = dlc;
            memcpy(slot->data, data, dlc);
            slot->dirty = true;
        }
        if (slot->count < 255) slot->count++;
    }
};

}  // namespace bridge
