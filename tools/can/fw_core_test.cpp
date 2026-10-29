// Test rdzenia programu płytki (firmware/can-ble-bridge/src/bridge_core.h) na komputerze.
//
// Ten sam kod, który chodzi na ESP32, dostaje tu:
//   1. ramki złożone ręcznie — i musi wydać DOKŁADNIE ten pakiet telemetrii, który
//      apka sprawdza w FeatureSelfTest.swift (wspólny wektor testowy obu stron),
//   2. prawdziwe nagrania szyny z Raspberry Pi (candump -l) w tempie z nagrania —
//      i ze strumienia surowego musi dać się odtworzyć każdą ramkę i każdy licznik.
//
// Uruchomienie: make fw-test   (albo: clang++ -std=c++17 -I firmware/can-ble-bridge/src
//               tools/can/fw_core_test.cpp -o /tmp/fw_core_test && /tmp/fw_core_test [katalog z logami])

#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <map>
#include <string>
#include <vector>

#include "bridge_core.h"
#include "ota_core.h"
#include "diag_core.h"

#include <CommonCrypto/CommonHMAC.h>   // wzorcowy HMAC-SHA256 z systemu (na płytce liczy go mbedtls)

static int failed = 0;

static void check(const std::string &name, bool ok, const std::string &detail = "") {
    if (!ok) failed++;
    printf("%s %s%s%s\n", ok ? "OK  " : "FAIL", name.c_str(), (!ok && !detail.empty()) ? "  — " : "",
           (!ok) ? detail.c_str() : "");
}

struct Frame {
    double t;
    uint32_t id;
    std::vector<uint8_t> data;
};

static std::vector<Frame> loadCandump(const std::string &path) {
    std::vector<Frame> out;
    FILE *f = fopen(path.c_str(), "r");
    if (!f) return out;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        double t;
        char iface[32], rest[128];
        if (sscanf(line, "(%lf) %31s %127s", &t, iface, rest) != 3) continue;
        std::string r(rest);
        size_t hash = r.find('#');
        if (hash == std::string::npos) continue;
        Frame fr;
        fr.t = t;
        fr.id = uint32_t(strtoul(r.substr(0, hash).c_str(), nullptr, 16));
        std::string hex = r.substr(hash + 1);
        for (size_t i = 0; i + 1 < hex.size(); i += 2)
            fr.data.push_back(uint8_t(strtoul(hex.substr(i, 2).c_str(), nullptr, 16)));
        out.push_back(fr);
    }
    fclose(f);
    return out;
}

// Odbiornik strumienia surowego — to, co robi apka (CanRawPacket.parse + BusTable).
struct Receiver {
    std::map<uint16_t, std::vector<uint8_t>> latest;
    std::map<uint16_t, long> counts;
    int packets = 0, seqGaps = 0, malformed = 0, tooLong = 0;
    int lastSeq = -1;

    void take(const uint8_t *buf, size_t len, size_t cap) {
        packets++;
        if (len > cap) tooLong++;
        if (len < bridge::RAW_HEADER || buf[0] != 2) { malformed++; return; }
        if (lastSeq >= 0 && uint8_t(lastSeq + 1) != buf[1]) seqGaps++;
        lastSeq = buf[1];
        size_t i = bridge::RAW_HEADER;
        while (i < len) {
            if (i + 4 > len) { malformed++; return; }
            uint16_t id = uint16_t(buf[i] | (buf[i + 1] << 8));
            uint8_t dlc = buf[i + 2], n = buf[i + 3];
            if (dlc > 8 || i + 4 + dlc > len) { malformed++; return; }
            latest[id] = std::vector<uint8_t>(buf + i + 4, buf + i + 4 + dlc);
            counts[id] += n;
            i += 4 + dlc;
        }
    }
};

// Przepuszcza nagranie przez rdzeń tak, jak robi to pętla na płytce: telemetria co 50 ms,
// zrzut surowy co 100 ms (jeden pakiet na „obieg"), raz na sekundę zrzut wszystkiego.
struct Replay {
    bridge::Core core;
    Receiver rx;
    bridge::Telemetry lastTele{};
    uint32_t now = 0;
    size_t cap;

    explicit Replay(size_t cap) : cap(cap) {}

    void drain(bool all) {
        uint8_t buf[244];
        bool done = false;
        int guard = 0;
        while (!done && guard++ < 1000) {
            size_t len = core.rawPacket(buf, cap, now, all, &done);
            if (len) rx.take(buf, len, cap);
        }
    }

    void run(const std::vector<Frame> &frames) {
        if (frames.empty()) return;
        double t0 = frames[0].t;
        uint32_t nextTele = 50, nextRaw = 100, nextAll = 1000, nextSecond = 1000;
        for (const Frame &f : frames) {
            now = uint32_t((f.t - t0) * 1000.0);
            while (now >= nextTele) { lastTele = core.telemetry(nextTele, false); nextTele += 50; }
            while (now >= nextRaw) {
                bool all = nextRaw >= nextAll;
                if (all) nextAll += 1000;
                uint32_t keep = now; now = nextRaw; drain(all); now = keep;
                nextRaw += 100;
            }
            while (now >= nextSecond) { core.secondTick(); nextSecond += 1000; }
            core.onFrame(f.id, false, uint8_t(f.data.size()), f.data.data(), now);
        }
        lastTele = core.telemetry(now, false);
        drain(true);   // końcowy zrzut wszystkiego, żeby odbiornik miał komplet
    }
};

static void testGolden() {
    printf("\n── Wspólny wektor testowy z apką ──\n");
    bridge::Core c;
    const uint8_t engine[8] = {0x15, 0x18, 40, 0x54, 4, 0, 1, 0};        // 5400 obr/min, gaz 40, bieg 4
    const uint8_t lean[8]   = {0x74, 0xE2, 0x80, 0, 0xC4, 0, 1, 0};      // 29922 = 15,63° w lewo
    const uint8_t accel[8]  = {0x80, 0x48, 0x6D, 0x3F, 0x85, 0x6C, 1, 0};
    c.onFrame(0x1A1, false, 8, engine, 1000);
    c.onFrame(0x1A5, false, 8, lean, 1000);
    c.onFrame(0x181, false, 8, accel, 1000);
    c.frameCount = 900;
    c.secondTick();
    c.seq = 7;
    bridge::Telemetry p = c.telemetry(1100, false);
    // Identyczne bajty jak `tele` w MySpin/FeatureSelfTest.swift (testBikeLink).
    const uint8_t expect[18] = {2, 0x07, 0x18, 0x15, 40, 0x54, 0xE2, 0x74,
                                0x48, 0x80, 0x3F, 0x6D, 0x6C, 0x85, 0x84, 0x03, 7, bridge::FW_VERSION};
    std::string got;
    for (size_t i = 0; i < sizeof(p); i++) { char b[4]; snprintf(b, sizeof(b), "%02X ", ((uint8_t *)&p)[i]); got += b; }
    check("pakiet telemetrii bajt w bajt taki, jakiego oczekuje apka", memcmp(&p, expect, 18) == 0, got);
    check("bez pozostałych ramek część rozszerzona ma tylko płyn (0xC4) i zera",
          p.flags2 == 0 && p.coolant == 0xC4 && p.switches == 0 && p.tps[0] == 4 && p.wheel[0] == 0 && p.cruise == 0, got);

    // Część rozszerzona (FW 4): prawdziwe ramki z testów na postoju 2026-10-10.
    // Identyczne bajty jak `teleExt` w MySpin/FeatureSelfTest.swift.
    const uint8_t fEngine[8] = {0x07, 0x08, 0x56, 0x82, 0x51, 0xC0, 1, 0};   // 1800 obr/min, gaz 346/690, bieg 2, przepustnica 327
    const uint8_t fLean[8]   = {0x75, 0x46, 0x80, 0, 0xBE, 0x04, 1, 0};      // płyn 190 → 88,75 °C, sprzęgło wciśnięte
    const uint8_t fWheel[8]  = {0x2E, 0xE0, 0x2F, 0xA8, 0, 0, 1, 0};         // koła 12000 i 12200
    const uint8_t fPulses[8] = {0x01, 0x28, 0, 0, 0x80, 0, 1, 0};            // licznik 296
    const uint8_t fSusp[8]   = {0x04, 0x5F, 0x01, 0xCA, 0x0A, 0, 1, 0};      // skok 1119 / 458, nastawa 10
    const uint8_t fEnv[8]    = {0x00, 0xBD, 0x05, 0x9C, 0x40, 0x3E, 1, 0};   // 22980 km, powietrze 32 °C
    const uint8_t fMode[8]   = {0, 0, 0x12, 0x31, 0x23, 0x30, 1, 0};         // tryb C
    const uint8_t fTc[8]     = {0x24, 0x61, 0x74, 0x40, 0, 0, 0, 1};         // A = 1, B = 7, C = 4, bieżąca 4
    const uint8_t fSet[8]    = {0x08, 0x99, 0x44, 0x37, 0x09, 0, 1, 0};      // U: przód +2, tył −3, SOLO
    const uint8_t fDamp[8]   = {0x43, 0x29, 0x94, 0x43, 0x70, 0x8C, 1, 0};   // tłumienie U
    const uint8_t fCruise[8] = {0, 0, 0, 0x10, 0, 0x04, 1, 0};               // tempomat włączony
    bridge::Core e;
    e.onFrame(0x1A1, false, 8, fEngine, 5000); e.onFrame(0x1A5, false, 8, fLean, 5000);
    e.onFrame(0x19D, false, 8, fWheel, 5000);  e.onFrame(0x221, false, 8, fPulses, 5000);
    e.onFrame(0x17D, false, 8, fSusp, 5000);   e.onFrame(0x231, false, 8, fEnv, 5000);
    e.onFrame(0x331, false, 8, fMode, 5000);   e.onFrame(0x335, false, 8, fTc, 5000);
    e.onFrame(0x1AD, false, 8, fSet, 5000);    e.onFrame(0x32D, false, 8, fDamp, 5000);
    e.onFrame(0x341, false, 8, fCruise, 5000);
    bridge::Telemetry q = e.telemetry(5100, false);
    const uint8_t expectExt[30] = {0xFF, 0xBE, 0x04, 0x51, 0xC0, 0x2E, 0xE0, 0x2F, 0xA8, 0x01, 0x28,
                                   0x04, 0x5F, 0x01, 0xCA, 0x0A, 0x05, 0x9C, 0x40, 0x3E, 0x30,
                                   0x61, 0x74, 0x40, 0x08, 0x99, 0x44, 0x37, 0x43, 0x10};
    got.clear();
    for (size_t i = 18; i < sizeof(q); i++) { char b[4]; snprintf(b, sizeof(b), "%02X ", ((uint8_t *)&q)[i]); got += b; }
    check("część rozszerzona pakietu bajt w bajt (bajty 18..47), bajt 48 zostaje dla Bluetooth",
          sizeof(q) == 49 && memcmp(((uint8_t *)&q) + 18, expectExt, 30) == 0 && q.connItvl == 0, got);
    check("świeżość licznika koła w bajcie flag (bit 3)", (q.flags & 0x0B) == 0x0B);
    bridge::Telemetry stale = e.telemetry(5700, false);
    check("po 0,5 s ciszy gasną też flagi części rozszerzonej, wartości zostają",
          stale.flags2 == 0 && (stale.flags & 0x08) == 0 && stale.coolant == 0xBE);
    check("licznik pakietów rośnie", c.telemetry(1150, false).seq == 8);
    check("po 0,5 s ciszy flagi świeżości gasną", c.telemetry(1600, false).flags == 0);
    check("program testowy ustawia bit symulacji", (c.telemetry(1600, true).flags & 0x80) != 0);

    printf("\n── Strumień surowy na ręcznych ramkach ──\n");
    Receiver rx;
    uint8_t buf[244];
    bool done = false;
    size_t len = c.rawPacket(buf, 244, 2000, false, &done);
    rx.take(buf, len, 244);
    check("pierwszy zrzut: trzy ID w jednym pakiecie", done && rx.latest.size() == 3 && len == 6 + 3 * 12);
    uint8_t seqAfter = c.rawSeq;
    len = c.rawPacket(buf, 244, 2100, false, &done);
    check("cisza na szynie: pusty zrzut nic nie wysyła", len == 0 && done);
    len = c.rawPacket(buf, 244, 2200, true, &done);
    check("cisza na szynie: numer pakietu nie rośnie", len == 0 && c.rawSeq == seqAfter);
    c.onFrame(0x1A1, false, 8, engine, 2300);          // ta sama treść → nie „zmieniona"
    len = c.rawPacket(buf, 244, 2300, false, &done);
    check("ramka bez zmian nie idzie w zwykłym zrzucie", len == 0);
    len = c.rawPacket(buf, 244, 3000, true, &done);
    check("…ale idzie w zrzucie co sekundę, z licznikiem ramek", len == 6 + 12 && buf[6] == 0xA1 && buf[7] == 0x01 && buf[9] == 1);
    const uint8_t ext[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    c.onFrame(0x18DAF110, true, 8, ext, 3100);
    check("ramka rozszerzona liczona, ale nie trafia do tablicy", c.rawUsed == 3 && c.frameCount == 2);
    for (int i = 0; i < 300; i++) c.onFrame(0x1A5, false, 8, lean, 3200);
    len = c.rawPacket(buf, 244, 4000, true, &done);
    check("licznik ramek nasyca się na 255", len == 6 + 12 && buf[9] == 255);

    // Mały pakiet (telefon nie wynegocjował większego): po jednym rekordzie, bez gubienia
    bridge::Core s;
    for (uint32_t id = 0x100; id < 0x105; id++) s.onFrame(id, false, 8, ext, 10);
    Receiver small;
    int calls = 0;
    done = false;
    while (!done && calls++ < 20) {
        len = s.rawPacket(buf, 20, 100, false, &done);
        if (len) small.take(buf, len, 20);
    }
    check("pakiet 20 B: pięć ID w pięciu pakietach, bez błędów",
          small.packets == 5 && small.latest.size() == 5 && small.malformed == 0 && small.tooLong == 0 && small.seqGaps == 0);
    bridge::Core full;
    for (uint32_t id = 0; id < 200; id++) full.onFrame(id, false, 1, ext, 10);
    check("tablica nie przepełnia się ponad 128 ID", full.rawUsed == bridge::RAW_SLOTS);
}

static void testLog(const std::string &dir, const std::string &name, size_t cap,
                    int wantGear, int wantThrottle, int wantLeanWord, int rpmMin, int rpmMax) {
    std::vector<Frame> frames = loadCandump(dir + "/" + name + ".log");
    if (frames.empty()) { printf("     (pomijam %s — brak pliku)\n", name.c_str()); return; }
    Replay r(cap);
    r.run(frames);

    std::map<uint16_t, std::vector<uint8_t>> last;
    std::map<uint16_t, long> n;
    for (const Frame &f : frames) { last[uint16_t(f.id)] = f.data; n[uint16_t(f.id)]++; }
    bool same = r.rx.latest == last, countsOk = r.rx.counts == n;
    char tag[96];
    snprintf(tag, sizeof(tag), "%s (pakiet %zu B, %zu ramek, %d pakietów)", name.c_str(), cap, frames.size(), r.rx.packets);
    check(std::string(tag) + ": ostatnia treść każdego ID odtworzona", same);
    check(std::string(tag) + ": suma liczników = liczba ramek na szynie", countsOk);
    check(std::string(tag) + ": pakiety poprawne, w rozmiarze, numery po kolei",
          r.rx.malformed == 0 && r.rx.tooLong == 0 && r.rx.seqGaps == 0);
    const bridge::Telemetry &t = r.lastTele;
    char got[128];
    snprintf(got, sizeof(got), "flagi %02X rpm %u gaz %u bieg %u przechył %u", t.flags, t.rpm, t.throttle, t.b3 & 15, t.lean);
    // 0x0F: silnik, przechył, przyspieszenia i licznik koła świeże; flags2 0xFF: wszystkie
    // osiem ramek części rozszerzonej jest w każdym nagraniu z motocykla.
    bool ok = t.version == 2 && t.flags == 0x0F && t.flags2 == 0xFF && t.fwVersion == bridge::FW_VERSION;
    if (wantGear >= 0) ok = ok && (t.b3 & 0x0F) == wantGear;
    if (wantThrottle >= 0) ok = ok && t.throttle == wantThrottle;
    if (wantLeanWord >= 0) ok = ok && t.lean == wantLeanWord;
    ok = ok && t.rpm >= rpmMin && t.rpm <= rpmMax;
    check(std::string(tag) + ": telemetria zgodna ze znaną treścią nagrania", ok, got);
}

// ── Aktualizacja przez Bluetooth: protokół na udawanej pamięci ──

static const uint8_t OTA_TEST_KEY[32] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
                                         17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32};

struct FakeFlash : bridge::ota::Platform {
    std::vector<uint8_t> slot;       // zapasowe miejsce w pamięci
    bool open = false, booted = false, failWrite = false, rejectImage = false;
    int aborts = 0;
    CCHmacContext ctx;
    bool begin(uint32_t size) override { slot.clear(); slot.reserve(size); open = true; return true; }
    bool write(const uint8_t *d, size_t n) override {
        if (failWrite || !open) return false;
        slot.insert(slot.end(), d, d + n);
        return true;
    }
    bool commit() override { if (rejectImage) return false; open = false; booted = true; return true; }
    void abort() override { open = false; aborts++; }
    void hmacStart() override { CCHmacInit(&ctx, kCCHmacAlgSHA256, OTA_TEST_KEY, sizeof(OTA_TEST_KEY)); }
    void hmacUpdate(const uint8_t *d, size_t n) override { CCHmacUpdate(&ctx, d, n); }
    void hmacFinish(uint8_t out[32]) override { CCHmacFinal(&ctx, out); }
};

static std::vector<uint8_t> otaBegin(const std::vector<uint8_t> &image, const uint8_t *key, uint8_t version) {
    std::vector<uint8_t> m(bridge::ota::BEGIN_LEN);
    uint32_t n = uint32_t(image.size());
    m[0] = bridge::ota::OP_BEGIN;
    memcpy(&m[1], &n, 4);
    m[5] = version;
    CCHmac(kCCHmacAlgSHA256, key, 32, image.data(), image.size(), &m[6]);
    return m;
}

static std::vector<uint8_t> otaData(const std::vector<uint8_t> &image, uint32_t off, size_t len) {
    if (off + len > image.size()) len = image.size() - off;
    std::vector<uint8_t> m(5 + len);
    m[0] = bridge::ota::OP_DATA;
    memcpy(&m[1], &off, 4);
    memcpy(&m[5], &image[off], len);
    return m;
}

static void testOta() {
    using namespace bridge::ota;
    printf("\n── Aktualizacja przez Bluetooth ──\n");
    std::vector<uint8_t> image(300000);
    for (size_t i = 0; i < image.size(); i++) image[i] = uint8_t(i * 31 + (i >> 8));
    const uint8_t endMsg[1] = {OP_END}, abortMsg[1] = {OP_ABORT};

    {   // pełna, poprawna aktualizacja paczkami po 240 bajtów
        FakeFlash f; Session s;
        auto b = otaBegin(image, OTA_TEST_KEY, 6);
        Reply r = s.onMessage(f, b.data(), b.size(), 1000, false);
        check("poprawny BEGIN → READY", r.send && r.status == READY && s.active && r.offset == 0);
        int acks = 0; bool order = true; uint32_t lastAck = 0;
        for (uint32_t off = 0; off < image.size(); off += 240) {
            auto d = otaData(image, off, 240);
            r = s.onMessage(f, d.data(), d.size(), 1000 + off / 100, false);
            if (r.send) { if (r.status != ACK || r.offset <= lastAck) order = false; lastAck = r.offset; acks++; }
        }
        check("potwierdzenia rosną i kończą się na pełnym rozmiarze", order && lastAck == image.size() && acks > 100,
              std::to_string(acks) + " potwierdzeń");
        r = s.onMessage(f, endMsg, 1, 9000, false);
        check("END z dobrym podpisem → DONE i przełączenie na nowy program",
              r.status == DONE && f.booted && s.done && !s.active && f.slot == image);
        auto d = otaData(image, 0, 240);
        r = s.onMessage(f, b.data(), b.size(), 9100, false);
        check("po przyjęciu obrazu kolejny BEGIN jest odrzucany", r.status == ERR_STATE && f.booted);
    }
    {   // zły podpis: inny klucz
        FakeFlash f; Session s;
        uint8_t wrongKey[32]; memcpy(wrongKey, OTA_TEST_KEY, 32); wrongKey[31] ^= 1;
        auto b = otaBegin(image, wrongKey, 6);
        s.onMessage(f, b.data(), b.size(), 0, false);
        for (uint32_t off = 0; off < image.size(); off += 240) { auto d = otaData(image, off, 240); s.onMessage(f, d.data(), d.size(), 1, false); }
        Reply r = s.onMessage(f, endMsg, 1, 2, false);
        check("podpis innym kluczem → ERR_TAG, stary program zostaje", r.status == ERR_TAG && !f.booted && !s.done && f.aborts == 1);
    }
    {   // jeden przekłamany bajt obrazu
        FakeFlash f; Session s;
        auto b = otaBegin(image, OTA_TEST_KEY, 6);
        s.onMessage(f, b.data(), b.size(), 0, false);
        std::vector<uint8_t> bad = image; bad[123456] ^= 0x40;
        for (uint32_t off = 0; off < bad.size(); off += 240) { auto d = otaData(bad, off, 240); s.onMessage(f, d.data(), d.size(), 1, false); }
        Reply r = s.onMessage(f, endMsg, 1, 2, false);
        check("jeden zmieniony bit w obrazie → ERR_TAG", r.status == ERR_TAG && !f.booted);
    }
    {   // odmowa w ruchu
        FakeFlash f; Session s;
        auto b = otaBegin(image, OTA_TEST_KEY, 6);
        Reply r = s.onMessage(f, b.data(), b.size(), 0, true);
        check("motocykl jedzie → ERR_MOVING, pamięć nietknięta", r.status == ERR_MOVING && !s.active && !f.open);
    }
    {   // zgubiona paczka: płytka prosi o powtórkę raz, telefon wraca i kończy
        FakeFlash f; Session s;
        auto b = otaBegin(image, OTA_TEST_KEY, 6);
        s.onMessage(f, b.data(), b.size(), 0, false);
        int naks = 0; uint32_t off = 0; bool dropped = false;
        while (off < image.size()) {
            if (!dropped && off == 240 * 50) { dropped = true; off += 240; continue; }   // ta jedna ginie
            auto d = otaData(image, off, 240);
            Reply r = s.onMessage(f, d.data(), d.size(), 1, false);
            if (r.send && r.status == ERR_OFFSET) {
                naks++;
                if (naks == 1) {
                    // telefon dosyła jeszcze 5 paczek z kolejki, zanim zareaguje — mają przejść bez echa
                    int extra = 0;
                    for (int k = 1; k <= 5; k++) { auto e = otaData(image, off + 240 * k, 240); if (s.onMessage(f, e.data(), e.size(), 1, false).send) extra++; }
                    check("po prośbie o powtórkę kolejne paczki z dziurą nie mnożą odpowiedzi", extra == 0);
                    off = r.offset; continue;
                }
            }
            off += 240;
        }
        Reply r = s.onMessage(f, endMsg, 1, 2, false);
        check("zgubiona paczka: jedna prośba o powtórkę i poprawne zakończenie", naks == 1 && r.status == DONE && f.slot == image,
              std::to_string(naks) + " próśb");
    }
    {   // END za wcześnie, cisza, przerwanie
        FakeFlash f; Session s;
        auto b = otaBegin(image, OTA_TEST_KEY, 6);
        s.onMessage(f, b.data(), b.size(), 0, false);
        auto d = otaData(image, 0, 240); s.onMessage(f, d.data(), d.size(), 10, false);
        Reply r = s.onMessage(f, endMsg, 1, 20, false);
        check("END przed końcem danych → ERR_OFFSET z pozycją, odbiór trwa", r.status == ERR_OFFSET && r.offset == 240 && s.active);
        check("krótka przerwa nie kończy aktualizacji", !s.tick(f, 10 + TIMEOUT_MS - 1).send && s.active);
        r = s.tick(f, 10 + TIMEOUT_MS + 1);
        check("telefon zamilkł → ERR_TIMEOUT i porzucenie zapisu", r.status == ERR_TIMEOUT && !s.active && f.aborts == 1 && !f.booted);
        r = s.onMessage(f, d.data(), d.size(), 30000, false);
        Reply r2 = s.onMessage(f, d.data(), d.size(), 30100, false);
        check("dane bez BEGIN → ERR_STATE, najwyżej raz na sekundę", r.status == ERR_STATE && !r2.send);
        s.onMessage(f, b.data(), b.size(), 40000, false);
        r = s.onMessage(f, abortMsg, 1, 40001, false);
        check("ABORT od telefonu → ABORTED", r.status == ABORTED && !s.active && !f.booted);
    }
    {   // rozmiary i błędy pamięci
        FakeFlash f; Session s;
        std::vector<uint8_t> tiny(1000, 7), huge(MAX_IMAGE + 1, 7);
        auto b1 = otaBegin(tiny, OTA_TEST_KEY, 6), b2 = otaBegin(huge, OTA_TEST_KEY, 6);
        check("za mały i za duży obraz → ERR_SIZE",
              s.onMessage(f, b1.data(), b1.size(), 0, false).status == ERR_SIZE &&
              s.onMessage(f, b2.data(), b2.size(), 0, false).status == ERR_SIZE && !s.active);
        auto b = otaBegin(image, OTA_TEST_KEY, 6);
        check("BEGIN o złej długości → ERR_SIZE", s.onMessage(f, b.data(), b.size() - 1, 0, false).status == ERR_SIZE);
        s.onMessage(f, b.data(), b.size(), 0, false);
        f.failWrite = true;
        auto d = otaData(image, 0, 240);
        check("błąd zapisu → ERR_FLASH i porzucenie", s.onMessage(f, d.data(), d.size(), 1, false).status == ERR_FLASH && !s.active);
        FakeFlash g; Session t; g.rejectImage = true;
        t.onMessage(g, b.data(), b.size(), 0, false);
        for (uint32_t off = 0; off < image.size(); off += 240) { auto x = otaData(image, off, 240); t.onMessage(g, x.data(), x.size(), 1, false); }
        check("dobry podpis, ale układ odrzuca obraz → ERR_FLASH, bez przełączenia",
              t.onMessage(g, endMsg, 1, 2, false).status == ERR_FLASH && !g.booted && !t.done);
        FakeFlash h; Session u;
        u.onMessage(h, b.data(), b.size(), 0, false);
        std::vector<uint8_t> longer = image; longer.resize(image.size() + 500, 9);
        Reply r;
        for (uint32_t off = 0; off < longer.size(); off += 240) { auto x = otaData(longer, off, 240); r = u.onMessage(h, x.data(), x.size(), 1, false); if (!u.active) break; }
        check("więcej danych niż zapowiedziano → ERR_SIZE", r.status == ERR_SIZE && !u.active && !h.booted);
    }
}


// ── Kody błędów (OBD na CAN): bezpieczeństwo i składanie odpowiedzi ──
static void testDiag() {
    printf("\n── Diagnostyka OBD (diag_core.h) ──\n");
    using namespace bridge::diag;
    Session s;
    bridge::diag::Frame out, fc;
    check("diag: odmowa przy pracującym silniku", s.start(CLEAR, 0, true, true, 10000) == ERR_MOVING && !s.active);
    check("diag: odmowa przy cichej szynie", s.start(READ, 0, false, false, 10000) == ERR_NO_BUS && !s.active);
    check("diag: nieznana komenda", s.start(0x09, 0, false, true, 10000) == ERR_OP);
    check("diag: nieznane adresowanie", s.start(READ, 3, false, true, 10000) == ERR_OP);
    check("diag: start odczytu", s.start(READ, FUNC11, false, true, 10000) == 0 && s.active);
    check("diag: zapytanie 7DF [01 03]", s.nextRequest(10000, out) && out.id == 0x7DF && !out.ext && out.data[0] == 0x01 && out.data[1] == 0x03);
    check("diag: tylko jedno zapytanie", !s.nextRequest(10600, out));
    check("diag: druga komenda w trakcie = zajęte", s.start(READ, 0, false, true, 10100) == ERR_BUSY);
    uint8_t other[8] = {0x02, 0x43, 0, 0, 0, 0, 0, 0};
    check("diag: zwykła ramka (0x441) ignorowana", !s.onFrame(0x441, false, 8, other, 10010, fc) && s.ecuCount == 0);
    uint8_t ff[8]  = {0x10, 12, 0x43, 0x05, 0xC1, 0x55, 0xC1, 0x23};
    uint8_t cf1[8] = {0x21, 0xC1, 0x32, 0xC0, 0x73, 0x16, 0x40, 0xAA};
    check("diag: pierwsza ramka → sterowanie przepływem do 7E0", s.onFrame(0x7E8, false, 8, ff, 10020, fc) && fc.id == 0x7E0 && !fc.ext && fc.data[0] == 0x30);
    check("diag: przed końcem nic do zgłoszenia", s.nextReport() == nullptr);
    uint8_t cfBad[8] = {0x23, 1, 2, 3, 4, 5, 6, 7};
    s.onFrame(0x7E8, false, 8, cfBad, 10025, fc);
    check("diag: zły numer kolejny odrzucony", s.ecus[0].len == 6 && !s.ecus[0].complete);
    s.onFrame(0x7E8, false, 8, cf1, 10030, fc);
    Response *r = s.nextReport();
    const uint8_t want[12] = {0x43, 0x05, 0xC1, 0x55, 0xC1, 0x23, 0xC1, 0x32, 0xC0, 0x73, 0x16, 0x40};
    check("diag: złożona odpowiedź 12 B (5 kodów)", r && r->id == 0x7E8 && r->len == 12 && memcmp(r->data, want, 12) == 0);
    check("diag: zgłoszona tylko raz", s.nextReport() == nullptr && s.reportedCount() == 1);
    uint8_t sf[8] = {0x02, 0x43, 0x00, 0, 0, 0, 0, 0};
    check("diag: pojedyncza ramka bez sterowania przepływem", !s.onFrame(0x7E9, false, 8, sf, 10040, fc));
    r = s.nextReport();
    check("diag: druga jednostka 7E9 [43 00]", r && r->id == 0x7E9 && r->len == 2 && r->data[1] == 0);
    check("diag: jeszcze nie koniec po 1,5 s", !s.finished(11540));
    check("diag: koniec po 2 s ciszy", s.finished(12040));
    s.end();
    check("diag: za szybko po poprzedniej = zajęte", s.start(CLEAR, 0, false, true, 12000) == ERR_BUSY);
    check("diag: kasowanie po 3 s", s.start(CLEAR, PHYS11, false, true, 13100) == 0 && s.nextRequest(13100, out) && out.id == 0x7E0 && out.data[1] == 0x04);
    uint8_t neg[8] = {0x03, 0x7F, 0x04, 0x22, 0, 0, 0, 0};
    s.onFrame(0x7E8, false, 8, neg, 13110, fc);
    r = s.nextReport();
    check("diag: odpowiedź odmowna przekazana dalej", r && r->len == 3 && r->data[0] == 0x7F && r->data[2] == 0x22);
    s.end();
    s.start(CLEAR, 0, false, true, 16200);
    s.nextRequest(16200, out);
    uint8_t pend[8] = {0x03, 0x7F, 0x04, 0x78, 0, 0, 0, 0};
    s.onFrame(0x7E8, false, 8, pend, 16210, fc);
    r = s.nextReport();
    check("diag: 78 przekazane telefonowi", r && r->data[2] == 0x78);
    check("diag: po 78 nie kończy po 2 s", !s.finished(18300));
    uint8_t ok44[8] = {0x01, 0x44, 0, 0, 0, 0, 0, 0};
    s.onFrame(0x7E8, false, 8, ok44, 19200, fc);
    r = s.nextReport();
    check("diag: późna odpowiedź [44] też przekazana", r && r->len == 1 && r->data[0] == 0x44);
    check("diag: koniec po ciszy i czasie oczekiwania", s.finished(21800));
    s.end();
    // PROBE: trzy zapytania co 250 ms, odpowiedź 29-bitowa i ramka nieznana
    check("diag: start PROBE", s.start(PROBE, 0, false, true, 30000) == 0);
    check("diag: PROBE 1/3 = 7DF", s.nextRequest(30000, out) && out.id == 0x7DF && !out.ext && out.data[1] == 0x03);
    check("diag: PROBE 2/3 czeka 250 ms", !s.nextRequest(30100, out));
    check("diag: PROBE 2/3 = 7E0", s.nextRequest(30250, out) && out.id == 0x7E0 && !out.ext);
    check("diag: PROBE 3/3 = 18DB33F1 (29-bit)", s.nextRequest(30500, out) && out.id == 0x18DB33F1 && out.ext && out.data[0] == 0x01 && out.data[1] == 0x03);
    check("diag: nie kończy przed wysłaniem wszystkich", s.queued == 3 && s.sent == 3);
    uint8_t ff29[8] = {0x10, 8, 0x43, 0x03, 0xC1, 0x55, 0xC1, 0x23};
    check("diag: 29-bit pierwsza ramka → sterowanie do 18DA10F1", s.onFrame(0x18DAF110, true, 8, ff29, 30520, fc) && fc.ext && fc.id == 0x18DA10F1);
    uint8_t cf29[8] = {0x21, 0xC1, 0x32, 0, 0, 0, 0, 0};
    s.onFrame(0x18DAF110, true, 8, cf29, 30530, fc);
    r = s.nextReport();
    check("diag: 29-bit odpowiedź złożona", r && r->ext && r->id == 0x18DAF110 && r->len == 8 && r->data[0] == 0x43 && r->data[7] == 0x32);
    uint8_t odd[8] = {0xAB, 0xCD, 1, 2, 3, 4, 5, 6};
    s.onFrame(0x7A1, false, 8, odd, 30540, fc);
    r = s.nextReport();
    check("diag: nieznana ramka 0x7A1 przekazana surowo", r && r->id == 0x7A1 && r->len == 8 && r->data[0] == 0xAB);
    uint8_t ext2[4] = {9, 8, 7, 6};
    s.onFrame(0x0CF00400, true, 4, ext2, 30550, fc);
    r = s.nextReport();
    check("diag: każda 29-bitowa przekazana surowo", r && r->ext && r->len == 4 && r->data[0] == 9);
    check("diag: nasze zapytania z szyny nie są odpowiedzią", !s.onFrame(0x7DF, false, 8, other, 30560, fc) && !s.onFrame(0x7E0, false, 8, other, 30560, fc) && s.nextReport() == nullptr);
    check("diag: PROBE kończy po 2 s ciszy", !s.finished(32000) && s.finished(32560));
    s.end();
    // limit ramek sterowania przepływem
    s.start(PING, 0, false, true, 40000);
    check("diag: ping 7DF [02 01 00]", s.nextRequest(40000, out) && out.data[0] == 0x02 && out.data[1] == 0x01 && out.data[2] == 0x00);
    int fcCount = 0;
    for (uint32_t id = 0x7E8; id <= 0x7EF; id++)
        for (int k = 0; k < 2; k++) if (s.onFrame(id, false, 8, ff, 40010, fc)) fcCount++;
    check("diag: najwyżej 8 ramek sterowania przepływem", fcCount == 8);
    s.end();
}

int main(int argc, char **argv) {
    testGolden();
    testOta();
    testDiag();

    std::string dir = argc > 1 ? argv[1] : "canlogs/pi-2026-06-25";
    DIR *d = opendir(dir.c_str());
    if (!d) {
        printf("\n(brak katalogu %s — pomijam testy na prawdziwych nagraniach)\n", dir.c_str());
    } else {
        closedir(d);
        printf("\n── Prawdziwe nagrania szyny (%s) ──\n", dir.c_str());
        //                         bieg  gaz  słowo przechyłu  obroty od–do
        testLog(dir, "lean_lewo",  244,  0,   0,  29922,   0,    0);
        testLog(dir, "lean_prawo", 244,  0,   0,  33534,   0,    0);
        testLog(dir, "gear_1",     244,  1,   0,  -1,      0,    0);
        testLog(dir, "gear_2",     244,  2,   0,  -1,      0,    0);
        testLog(dir, "thrMAX",     244,  0, 172,  -1,      0,    0);
        testLog(dir, "rev",        244,  0,  -1,  -1,   3000, 4200);
        testLog(dir, "idle",       244,  0,   0,  -1,   1500, 2000);
        testLog(dir, "rev",         20,  0,  -1,  -1,   3000, 4200);   // najmniejszy możliwy pakiet
        testLog(dir, "cal2500",    100,  0,  -1,  -1,   2200, 2800);
    }

    printf("\n%s\n", failed == 0 ? "WYNIK: wszystko OK" : "WYNIK: są błędy");
    return failed ? 1 : 0;
}
