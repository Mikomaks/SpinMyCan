// Mostek CAN -> BLE dla MySpin.
//
// Płytka słucha szyny napędowej GSX-S1000GX (500 kb/s) i 30 razy na sekundę
// wysyła do telefonu obroty, gaz, bieg, kąt przechyłu i przyspieszenia przez
// Bluetooth LE.
//
// BEZPIECZEŃSTWO: sterownik CAN działa w trybie LISTEN_ONLY — nie potwierdza
// ramek, nie wysyła ramek błędów i niczego nie nadaje. Nadajnik TJA1051 ma na tej
// płytce pin S zwarty do masy (zawsze aktywny), więc jedyną gwarancją ciszy jest
// ten tryb. JEDYNY wyjątek (od FW 9): komenda diagnostyczna z telefonu (odczyt albo
// skasowanie kodów błędów, diag_core.h) — tylko przy zgaszonym silniku i stojącym
// motocyklu, na czas jednej komendy (najwyżej kilka sekund), każda ramka wysyłana
// jednorazowo bez powtórek; potem powrót do LISTEN_ONLY.
//
// Piny wg schematu Waveshare ESP32-S3-RS485-CAN: CAN TX = GPIO15, RX = GPIO16.
//
// Pakiet telemetrii (pierwsze 18 bajtów, little-endian), charakterystyka TELE_UUID:
//   0      wersja formatu (2)
//   1      flagi świeżości (<0,5 s): bit0 = 0x1A1 (silnik), bit1 = 0x1A5 (przechył),
//          bit2 = 0x181 (przyspieszenia); bit7 = dane SZTUCZNE (program testowy fakebus)
//   2..3   obroty silnika [obr/min]
//   4      gaz, bajt b2 ramki 0x1A1 (0 = zamknięty, ~172 = pełny)
//   5      bajt b3 ramki 0x1A1: górna połówka = dodatkowe bity gazu, dolna = bieg
//   6..7   kąt przechyłu policzony przez motocykl: słowo b0b1 ramki 0x1A5.
//          stopnie = (wartość - 32768) * 180 / 32768; ujemne = przechył w lewo.
//          Zgodne z kątem z akcelerometru co do stałej 0,5 st. w 21 zrzutach z postoju.
//   8..13  przyspieszenia z ramki 0x181 (filtrowane, 100 Hz): wzdłużne, pionowe,
//          boczne; każde jako słowo z przesunięciem 32768, 1 g = ok. 5000
//   14..15 liczba ramek na szynie w ostatniej sekundzie (diagnostyka)
//   16     licznik pakietów
//   17     wersja programu płytki (FW_VERSION; 0 = wersja sprzed tego pola)
// Od FW 4 pakiet ma 48 bajtów: za powyższymi idą SUROWE bajty kolejnych ramek,
// w kolejności jak na szynie (przeliczenia robi apka — patrz tools/can/SYGNALY.md):
//   18     flagi świeżości: bit0 0x19D, bit1 0x17D, bit2 0x231, bit3 0x331,
//          bit4 0x335, bit5 0x1AD, bit6 0x32D, bit7 0x341
//          (świeżość 0x221 siedzi w bajcie 1, bit3)
//   19     0x1A5 b4      płyn chłodzący
//   20     0x1A5 b5      sprzęgło (0x04), przycisk startu (0x10)
//   21..22 0x1A1 b4..b5  otwarcie przepustnicy
//   23..26 0x19D b0..b3  prędkość koła przedniego i tylnego
//   27..28 0x221 b0..b1  licznik impulsów przedniego koła
//   29..33 0x17D b0..b4  skok zawieszenia przód, tył; nastawa tłumienia
//   34..37 0x231 b2..b5  przebieg (20 bitów), powietrze
//   38     0x331 b5      tryb jazdy
//   39..41 0x335 b1..b3  kontrola trakcji
//   42..45 0x1AD b0..b3  nastawy zawieszenia
//   46     0x32D b0      tryb tłumienia
//   47     0x341 b3      tempomat
// Od FW 8 dochodzi bajt 48: odstęp połączenia Bluetooth przyznany przez telefon,
// w jednostkach 1,25 ms (0 = nieznany) — do diagnozy opóźnień.
// Starsza apka czyta tylko pierwsze 18 bajtów, więc nic jej to nie psuje. Gdyby
// telefon nie wynegocjował większego MTU, pakiet zostanie ucięty do 20 bajtów
// i apka potraktuje go jak stary.
//
// Uwaga: bajt b4 ramek 0x179/0x181 to przyspieszenie BOCZNE, nie przechył — na
// postoju rośnie z pochyleniem, ale w zakręcie jest bliski zera.
//
// Strumień surowy (charakterystyka RAW_UUID, tylko gdy telefon ją zasubskrybuje)
// służy do rozszyfrowywania kolejnych ramek: 5 razy na sekundę idzie ostatnia
// zawartość każdego ID, które się zmieniło, a co 2 sekundy — wszystkich.
// Zrzut jest rozłożony w czasie: jeden pakiet na obieg pętli, żeby nie zapychać
// kolejki Bluetooth serią kilku dużych pakietów naraz.
// Pakiet: nagłówek 6 bajtów, potem rekordy aż do końca pakietu.
//   0      typ (2)
//   1      licznik pakietów (dziura = zgubiony pakiet)
//   2..5   millis() płytki w chwili złożenia pakietu
//   rekord: [ID lo][ID hi][dlc][liczba ramek od poprzedniego zrzutu][dane × dlc]

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <esp_task_wdt.h>
#include "driver/twai.h"
#include "nimble/porting/nimble/include/os/os_mbuf.h"   // licznik wolnych buforów stosu Bluetooth

#include "bridge_core.h"   // dekodowanie i pakiety — ten sam kod testowany na komputerze
#include "ota_core.h"      // protokół aktualizacji przez Bluetooth — też testowany na komputerze
#include "diag_core.h"     // kody błędów przez OBD — też testowany na komputerze

// Aktualizacja przez Bluetooth jest wbudowana tylko, gdy istnieje plik z kluczem
// (src/ota_key.h, poza repozytorium — patrz ota_key.example.h i `make fw-key`).
// Bez klucza płytka w ogóle nie wystawia tej funkcji i da się ją wgrać tylko kablem.
#if __has_include("ota_key.h")
#include "ota_key.h"
#define OTA_ENABLED 1
#include <esp_ota_ops.h>
#include <mbedtls/md.h>
#include <freertos/message_buffer.h>
#else
#define OTA_ENABLED 0
#endif

// Pętla, która stanie na dłużej, restartuje płytkę (zamiast wisieć do wyłączenia zapłonu).
static const uint32_t WDT_SECONDS = 8;

static const gpio_num_t CAN_TX = GPIO_NUM_15;
static const gpio_num_t CAN_RX = GPIO_NUM_16;

static const char *DEVICE_NAME = "MySpin-CAN";
static const char *SVC_UUID  = "E298C31B-A001-46D9-8045-3E60B3B38DC6";
static const char *TELE_UUID = "531855D0-77DE-44E5-B26C-6DD5A615D194";
static const char *RAW_UUID  = "7C0A6F52-3B1E-4D7A-9E55-0A2C4B8F1D93";
static const char *OTA_UUID  = "9E0B6C1D-52A7-4F3E-8D14-6B7C2A905E31";
static const char *DIAG_UUID = "3D8F1A62-7C4B-4E19-A0D5-5B2E9C71F084";

// Tempo dobrane do tego, co łącze faktycznie przenosi na motocyklu. iPhone dzieli radio
// między Bluetooth a WiFi do wyświetlacza i odbiera wtedy dużo mniej pakietów niż na
// biurku: przy 50 + 20 pakietach na sekundę w logach z jazdy ginęło 18–41%, a reszta
// stała w kolejce i docierała spóźniona. 30 pakietów telemetrii na sekundę to wciąż dwa
// na każdą klatkę wyświetlacza.
static const uint32_t NOTIFY_MS = 33;
static const uint32_t RAW_MS    = 200;   // zrzut zmienionych ID 5 razy na sekundę
static const uint32_t RAW_ALL_MS = 2000; // zrzut wszystkich ID co 2 s

static NimBLECharacteristic *teleChar = nullptr;
static NimBLECharacteristic *rawChar = nullptr;
static volatile bool bleConnected = false;
static volatile bool rawSubscribed = false;
static volatile uint16_t peerMtu = 23;

static bridge::Core core;

static bool canRunning = false;
static uint32_t lastCanTry = 0;
static uint32_t lostCount = 0;
static bool rawDump = false;

// Odstęp połączenia Bluetooth decyduje, jak często telefon w ogóle odbiera pakiety.
// Prosimy o najkrótszy, na jaki godzi się iPhone: 15 ms. Apple odrzuca prośby spoza
// swoich reguł (m.in. czas nadzoru w zakresie 2–6 s w starszych wytycznych i 6–18 s
// w nowszych — 6 s mieści się w obu; poprzednie 4 s i 2 s mogły być odrzucane, a w logu
// z jazdy pakiety docierały paczkami co ok. 100 ms). Telefon może też zignorować prośbę
// wysłaną tuż po połączeniu, dlatego pętla ponawia ją dwa razy, póki odstęp jest dłuższy.
static volatile uint16_t connHandle = 0;
static volatile uint32_t connectedAt = 0;
static volatile uint8_t connAsks = 0;

static void askConnParams(NimBLEServer *server) {
    // 1. i 2. próba: dokładnie 15 ms; 3.: 15–30 ms (gdyby telefon nie chciał samego 15).
    server->updateConnParams(connHandle, 12, connAsks < 2 ? 12 : 24, 0, 600);
    connAsks++;
}

static uint16_t connInterval() {     // w jednostkach 1,25 ms; 0 = brak połączenia
    NimBLEServer *server = NimBLEDevice::getServer();
    if (!server || !bleConnected) return 0;
    return server->getPeerInfo(0).getConnInterval();
}

class ServerEvents : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer *server, ble_gap_conn_desc *desc) override {
        bleConnected = true;
        connHandle = desc->conn_handle;
        connectedAt = millis();
        connAsks = 0;
        askConnParams(server);
    }
    void onDisconnect(NimBLEServer *server) override {
        bleConnected = false;
        rawSubscribed = false;
        peerMtu = 23;
        NimBLEDevice::startAdvertising();
    }
    void onMTUChange(uint16_t mtu, ble_gap_conn_desc *desc) override {
        peerMtu = mtu;
    }
};

class RawEvents : public NimBLECharacteristicCallbacks {
    void onSubscribe(NimBLECharacteristic *c, ble_gap_conn_desc *desc, uint16_t subValue) override {
        rawSubscribed = subValue != 0;
    }
};

#if OTA_ENABLED
// ── Aktualizacja programu przez Bluetooth ────────────────────────────────────
// Protokół i zabezpieczenia: ota_core.h. Tu tylko to, co zależy od układu:
// zapis do zapasowego miejsca w pamięci, podpis (mbedtls) i kolejka wiadomości.
//
// Wiadomości z Bluetooth przychodzą w zadaniu stosu radiowego — tam tylko kopiujemy
// je do kolejki, a zapis do pamięci robi pętla główna (zapis blokuje na milisekundy).
// Nowy program startuje „na próbę": zostaje na stałe dopiero, gdy telefon połączy
// się z nim i utrzyma połączenie przez 3 s. Reset przed tym momentem (zawieszenie,
// błąd, brak łączności) = układ sam wraca do poprzedniego programu.

struct EspOta : bridge::ota::Platform {
    esp_ota_handle_t handle = 0;
    const esp_partition_t *part = nullptr;
    mbedtls_md_context_t md;
    bool mdOpen = false;

    bool begin(uint32_t size) override {
        part = esp_ota_get_next_update_partition(NULL);
        if (!part || size > part->size) return false;
        // Kasowanie na bieżąco, sektor po sektorze — bez kilkusekundowej pauzy na starcie.
        return esp_ota_begin(part, OTA_WITH_SEQUENTIAL_WRITES, &handle) == ESP_OK;
    }
    bool write(const uint8_t *d, size_t n) override { return esp_ota_write(handle, d, n) == ESP_OK; }
    bool commit() override {
        esp_err_t e = esp_ota_end(handle);      // sprawdza nagłówek i sumę obrazu
        handle = 0;
        closeMd();
        return e == ESP_OK && esp_ota_set_boot_partition(part) == ESP_OK;
    }
    void abort() override {
        if (handle) { esp_ota_abort(handle); handle = 0; }
        closeMd();
    }
    void hmacStart() override {
        closeMd();
        mbedtls_md_init(&md);
        mbedtls_md_setup(&md, mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), 1);
        mbedtls_md_hmac_starts(&md, OTA_KEY, sizeof(OTA_KEY));
        mdOpen = true;
    }
    void hmacUpdate(const uint8_t *d, size_t n) override { if (mdOpen) mbedtls_md_hmac_update(&md, d, n); }
    void hmacFinish(uint8_t out[32]) override {
        if (!mdOpen) { memset(out, 0, 32); return; }
        mbedtls_md_hmac_finish(&md, out);
        closeMd();
    }
    void closeMd() { if (mdOpen) { mbedtls_md_free(&md); mdOpen = false; } }
};

static EspOta otaFlash;
static bridge::ota::Session otaSession;
static NimBLECharacteristic *otaChar = nullptr;
static MessageBufferHandle_t otaQueue = nullptr;
static uint32_t otaRestartAt = 0;
static uint8_t otaLastStatus = 0;
static bool imageConfirmed = false;

// Rdzeń Arduino pyta o to przy starcie: „true" = sami potwierdzimy nowy program (później).
extern "C" bool verifyRollbackLater() { return true; }

class OtaEvents : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic *c) override {
        NimBLEAttValue v = c->getValue();
        // Pełna kolejka = paczka przepada; płytka poprosi telefon o powtórkę od tej pozycji.
        if (otaQueue && v.length() > 0) xMessageBufferSend(otaQueue, v.data(), v.length(), 0);
    }
};

static void otaNotify(const bridge::ota::Reply &r) {
    if (!r.send || !otaChar) return;
    uint8_t m[6] = {r.status, uint8_t(r.offset), uint8_t(r.offset >> 8), uint8_t(r.offset >> 16),
                    uint8_t(r.offset >> 24), bridge::FW_VERSION};
    otaLastStatus = r.status;
    otaChar->setValue(m, sizeof(m));
    otaChar->notify();
}
#endif

// Wolne bufory stosu Bluetooth. Każdy pakiet czekający na wysłanie zajmuje jeden;
// gdy telefon odbiera wolniej, niż nadajemy, wolnych ubywa. Wtedy lepiej NIE dokładać:
// pakiet wysłany później jest świeższy niż ten, który odstałby swoje w kolejce.
static int bleFreeBufs() { return os_msys_num_free(); }
static int bleTotalBufs() { static int n = os_msys_count(); return n; }
static uint32_t teleSkipped = 0, rawSkipped = 0;

static bool otaBusy() {
#if OTA_ENABLED
    return otaSession.active || otaSession.done;
#else
    return false;
#endif
}

// Domyślnie wyłącznie nasłuch. NORMAL tylko na czas komendy diagnostycznej (patrz loop).
static bool canStart(twai_mode_t mode = TWAI_MODE_LISTEN_ONLY) {
    twai_general_config_t g = TWAI_GENERAL_CONFIG_DEFAULT(CAN_TX, CAN_RX, mode);
    // Szyna niesie ok. 2000 ramek/s; 256 miejsc to ponad 100 ms zapasu na zajętą pętlę.
    g.rx_queue_len = 256;
    twai_timing_config_t t = TWAI_TIMING_CONFIG_500KBITS();
    twai_filter_config_t f = TWAI_FILTER_CONFIG_ACCEPT_ALL();
    if (twai_driver_install(&g, &t, &f) != ESP_OK) return false;
    if (twai_start() != ESP_OK) {
        twai_driver_uninstall();
        return false;
    }
    return true;
}

// Zrzut tablicy do telefonu, jeden pakiet na wywołanie; zwraca true, gdy bieżący
// zrzut doszedł do końca. `all` wysyła także ID bez zmian (raz na sekundę).
static bool sendRawPacket(uint32_t now, bool all) {
    uint8_t buf[244];
    size_t cap = peerMtu > 3 ? size_t(peerMtu) - 3 : 20;
    if (cap > sizeof(buf)) cap = sizeof(buf);
    bool done = true;
    size_t len = core.rawPacket(buf, cap, now, all, &done);
    if (len > 0) {
        rawChar->setValue(buf, len);
        rawChar->notify();
    }
    return done;
}

// ── Kody błędów (OBD) ──
static NimBLECharacteristic *diagChar = nullptr;
static volatile uint8_t diagPending = 0;      // komenda od telefonu czekająca na pętlę
static volatile uint8_t diagPendingAddr = 0;  // sposób adresowania (diag_core.h)
static uint8_t diagTxOk = 0, diagTxFail = 0;  // wysłane / odrzucone przez sterownik ramki komendy
static bridge::diag::Session diag;
static uint32_t diagHardStop = 0;             // twardy limit czasu komendy
static uint8_t diagLastStatus = 0;

class DiagEvents : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic *c) override {
        NimBLEAttValue v = c->getValue();
        if (v.length() >= 1 && !diagPending) {
            diagPendingAddr = v.length() >= 2 ? v.data()[1] : 0;
            diagPending = v.data()[0];
        }
    }
};

static void diagNotify(const uint8_t *m, size_t n) {
    if (!diagChar || !bleConnected) return;
    diagChar->setValue(m, n);
    diagChar->notify();
}

static void diagFinish(uint8_t status, uint8_t op, uint8_t count, uint8_t txErr = 0) {
    uint8_t m[6] = {status, op, count, diagTxOk, diagTxFail, txErr};
    diagLastStatus = status;
    diagNotify(m, sizeof(m));
}

// Jednorazowe wysłanie ramki (bez powtórek, gdy nikt nie potwierdzi).
static bool diagSend(const bridge::diag::Frame &f) {
    twai_message_t m = {};
    m.identifier = f.id;
    m.extd = f.ext ? 1 : 0;
    m.data_length_code = 8;
    m.ss = 1;
    memcpy(m.data, f.data, 8);
    bool ok = twai_transmit(&m, pdMS_TO_TICKS(20)) == ESP_OK;
    if (ok) diagTxOk++; else diagTxFail++;
    return ok;
}

// Powrót do samego nasłuchu — zawsze, czymkolwiek skończyła się komenda.
static void diagBackToListen() {
    diag.end();
    diagHardStop = 0;
    if (canRunning) { twai_stop(); twai_driver_uninstall(); }
    pinMode(CAN_TX, OUTPUT);
    digitalWrite(CAN_TX, HIGH);
    canRunning = canStart();
    lastCanTry = millis();
}

static void diagPoll(uint32_t now, bool busAlive, bool moving) {
    if (diagPending) {
        uint8_t op = diagPending, addr = diagPendingAddr;
        diagPending = 0;
        diagTxOk = diagTxFail = 0;
        uint8_t err = otaBusy() ? uint8_t(bridge::diag::ERR_BUSY) : diag.start(op, addr, moving, busAlive, now);
        if (err) { diagFinish(err, op, 0); return; }
        // Na czas komendy: tryb NORMAL (potwierdzanie ramek + nadawanie).
        twai_stop();
        twai_driver_uninstall();
        canRunning = canStart(TWAI_MODE_NORMAL);
        if (!canRunning) {
            diagBackToListen();
            diagFinish(bridge::diag::ERR_TX, op, 0);
            return;
        }
        diagHardStop = now + 9000;   // twardy limit, nawet gdy sterownik każe czekać
        Serial.printf("diag: komenda %02X wyslana\n", op);
    }
    if (!diag.active) return;
    bridge::diag::Frame req;
    while (diag.nextRequest(now, req)) diagSend(req);
    while (bridge::diag::Response *r = diag.nextReport()) {
        uint8_t m[7 + bridge::diag::MAX_PAYLOAD];
        m[0] = bridge::diag::RESPONSE; m[1] = diag.op;
        m[2] = uint8_t(r->id); m[3] = uint8_t(r->id >> 8); m[4] = uint8_t(r->id >> 16);
        m[5] = uint8_t((r->id >> 24) & 0x1F) | (r->ext ? 0x80 : 0);
        m[6] = r->len;
        memcpy(m + 7, r->data, r->len);
        diagNotify(m, 7 + r->len);
    }
    if (diag.finished(now) || (diagHardStop && int32_t(now - diagHardStop) >= 0)) {
        uint8_t op = diag.op, count = diag.reportedCount();
        twai_status_info_t st = {};
        uint8_t txErr = 0;
        if (canRunning && twai_get_status_info(&st) == ESP_OK) {
            txErr = st.tx_error_counter > 255 ? 255 : uint8_t(st.tx_error_counter);
            diagTxFail += uint8_t(st.tx_failed_count);      // jednorazowe ramki bez potwierdzenia
        }
        diagBackToListen();
        diagFinish(bridge::diag::DONE, op, count, txErr);
        Serial.printf("diag: koniec %02X, odpowiedzi %u, z powrotem tylko nasluch\n", op, (unsigned)count);
    }
}

static void handleFrame(const twai_message_t &m, uint32_t now) {
    if (rawDump) {
        Serial.printf("%03X [%d]", (unsigned)m.identifier, m.data_length_code);
        for (int i = 0; i < m.data_length_code; i++) Serial.printf(" %02X", m.data[i]);
        Serial.println();
    }
    core.onFrame(m.identifier, m.extd || m.rtr, m.data_length_code, m.data, now);
    if (diag.active && !m.rtr) {
        bridge::diag::Frame fc;
        if (diag.onFrame(m.identifier, m.extd, m.data_length_code, m.data, now, fc)) diagSend(fc);
    }
}

static void sendTelemetry(uint32_t now) {
#ifdef FAKE_BUS
    bridge::Telemetry p = core.telemetry(now, true);
#else
    bridge::Telemetry p = core.telemetry(now, false);
#endif
    uint16_t itvl = connInterval();
    p.connItvl = itvl > 255 ? 255 : uint8_t(itvl);
    teleChar->setValue((uint8_t *)&p, sizeof(p));
    teleChar->notify();
}

#ifdef FAKE_BUS
// Program testowy na biurko (NIE do wgrania na motocykl): zamiast słuchać szyny
// podaje do reszty programu sztuczne ramki w tempie zbliżonym do prawdziwego
// (ok. 2000/s, 28 ID). Pozwala sprawdzić Bluetooth, apkę i zapis logu pod pełnym
// obciążeniem bez motocykla. Pakiety telemetrii mają ustawiony bit7 flag, więc
// apka pokazuje, że to symulacja. Sterownik CAN w tym programie w ogóle nie startuje.
static const uint16_t FAKE_IDS[] = {
    0x175, 0x179, 0x17D, 0x17E, 0x180, 0x181, 0x19D, 0x1A1, 0x1A5, 0x1A9, 0x1AD, 0x1D1, 0x221, 0x231,
    0x235, 0x321, 0x32D, 0x331, 0x335, 0x339, 0x33D, 0x341, 0x351, 0x355, 0x3B1, 0x431, 0x441, 0x451};
static const uint8_t FAKE_PERIOD_MS[] = {
    5, 5, 5, 5, 10, 10, 10, 10, 10, 10, 10, 10, 20, 20,
    20, 50, 50, 50, 50, 50, 50, 50, 50, 50, 100, 100, 100, 100};
static uint32_t fakeNext[sizeof(FAKE_IDS) / sizeof(FAKE_IDS[0])];
static uint8_t fakeCounter[sizeof(FAKE_IDS) / sizeof(FAKE_IDS[0])];

static void handleFrame(const twai_message_t &m, uint32_t now);

static void fakeBusPoll(uint32_t now) {
    float t = now / 1000.0f;
    // Jazda w kółko: prędkość 0..150 km/h, biegi wg prędkości, przechył do ±40 st.
    float kmh = 75.0f + 75.0f * sinf(t / 23.0f);
    static const float perK[] = {0, 9.6f, 12.9f, 15.9f, 18.6f, 21.0f, 23.4f};
    int gear = kmh < 2 ? 0 : kmh < 35 ? 1 : kmh < 60 ? 2 : kmh < 85 ? 3 : kmh < 110 ? 4 : kmh < 140 ? 5 : 6;
    uint16_t rpmNow = gear == 0 ? 1300 : uint16_t(kmh / perK[gear] * 1000.0f);
    float lean = 40.0f * sinf(t / 5.0f) * (kmh > 20 ? 1.0f : 0.0f);
    uint16_t leanW = uint16_t(32768.0f + lean * 32768.0f / 180.0f);
    uint16_t thr = uint16_t(120.0f + 100.0f * sinf(t / 3.0f));
    static float pulses = 0;
    static uint32_t lastT = 0;
    if (lastT) pulses += kmh / 3.6f * 26.5f * (now - lastT) / 1000.0f;   // ok. 50 impulsów na obrót
    lastT = now;

    for (size_t i = 0; i < sizeof(FAKE_IDS) / sizeof(FAKE_IDS[0]); i++) {
        if (int32_t(now - fakeNext[i]) < 0) continue;
        fakeNext[i] = now + FAKE_PERIOD_MS[i];
        twai_message_t m = {};
        m.identifier = FAKE_IDS[i];
        m.data_length_code = 8;
        m.data[6] = fakeCounter[i]++ & 0x0F;
        m.data[7] = uint8_t(esp_random());
        switch (FAKE_IDS[i]) {
        case 0x1A1:
            m.data[0] = rpmNow >> 8; m.data[1] = rpmNow & 0xFF;
            m.data[2] = thr >> 2; m.data[3] = uint8_t(((thr & 3) << 6) | gear);
            m.data[4] = 4; m.data[7] = 0;
            break;
        case 0x1A5:
            m.data[0] = leanW >> 8; m.data[1] = leanW & 0xFF;
            m.data[2] = 0x80; m.data[4] = uint8_t(150 + (now / 4000) % 60); m.data[7] = 0;
            break;
        case 0x181: case 0x179: {
            uint16_t vert = uint16_t(32768.0f - 5000.0f / cosf(lean * 0.01745f));
            m.data[0] = 0x80; m.data[1] = 0x40;
            m.data[2] = vert >> 8; m.data[3] = vert & 0xFF;
            m.data[4] = 0x80; m.data[5] = uint8_t(esp_random() & 0x3F);
            break;
        }
        case 0x19D: {   // koła: tył o 2% szybszy przy mocnym gazie
            uint16_t vf = uint16_t(kmh * 100.0f), vr = uint16_t(kmh * (thr > 200 ? 102.0f : 100.0f));
            m.data[0] = vf >> 8; m.data[1] = vf & 0xFF; m.data[2] = vr >> 8; m.data[3] = vr & 0xFF;
            break;
        }
        case 0x17D: {   // zawieszenie pracuje wokół położenia z kierowcą
            uint16_t f = uint16_t(1119.0f + 60.0f * sinf(t * 2.1f)), r = uint16_t(458.0f + 40.0f * sinf(t * 1.7f));
            m.data[0] = f >> 8; m.data[1] = f & 0xFF; m.data[2] = r >> 8; m.data[3] = r & 0xFF; m.data[4] = 10;
            break;
        }
        case 0x231:     // 22980 km, powietrze 18 °C
            m.data[0] = 0x00; m.data[1] = 0xBD; m.data[2] = 0x05; m.data[3] = 0x9C; m.data[4] = 0x40; m.data[5] = 48; m.data[7] = 0;
            break;
        case 0x331:     // tryb jazdy zmienia się co 20 s: A, B, C
            m.data[5] = uint8_t((1 + (now / 20000) % 3) << 4); m.data[7] = 0;
            break;
        case 0x335:     // trakcja: A = 1, B = 3, C = 5; bieżąca wg trybu
            m.data[0] = 0x24; m.data[1] = 0x61; m.data[2] = 0x35;
            m.data[3] = uint8_t((1 + 2 * ((now / 20000) % 3)) << 4); m.data[6] = 0; m.data[7] = fakeCounter[i] & 0x0F;
            break;
        case 0x1AD:     // tłumienie M, bez korekt, SOLO
            m.data[0] = 0x07; m.data[1] = 0x77; m.data[2] = 0x77; m.data[3] = 0x37; m.data[4] = 0x09; m.data[7] = 0;
            break;
        case 0x32D:
            m.data[0] = 0x41; m.data[1] = 0x24; m.data[2] = 0x44; m.data[3] = 0x43; m.data[7] = 0;
            break;
        case 0x341:
            m.data[3] = kmh > 100 ? 0x10 : 0x00; m.data[5] = 0x04; m.data[7] = 0;
            break;
        case 0x221:
            m.data[0] = uint8_t(uint32_t(pulses) >> 8);
            m.data[1] = uint8_t(uint32_t(pulses));
            m.data[2] = (rpmNow / 2) >> 8; m.data[3] = (rpmNow / 2) & 0xFF;
            m.data[4] = 0x80; m.data[7] = 0;
            break;
        case 0x175: case 0x180:
            for (int k = 0; k < 6; k += 2) { m.data[k] = 0x80; m.data[k + 1] = uint8_t(esp_random() & 0x1F); }
            break;
        default:
            m.data[0] = uint8_t(FAKE_IDS[i]); m.data[1] = 0xAA; m.data[7] = 0;
            break;
        }
        handleFrame(m, now);
    }
}
#endif

#ifdef TX_FLOAT_TEST
// Diagnostyka na biurku (NIE do wgrania na motocykl): sprawdza, co nadajnik robi,
// gdy pin TX procesora „wisi" — tak jak przez chwilę po włączeniu zasilania,
// zanim ruszy program. RX niski = nadajnik wystawia stan dominujący na szynę.
static uint32_t floatLow = 0, floatTotal = 0, pullLow = 0, pullTotal = 0, highLow = 0, highTotal = 0;
static uint32_t ctrlLow = 0, ctrlTotal = 0;
static void sampleRx(uint32_t us, uint32_t &low, uint32_t &total) {
    uint32_t t0 = micros();
    while (micros() - t0 < us) {
        if (digitalRead(CAN_RX) == LOW) low++;
        total++;
    }
}
static void txFloatTest() {
    pinMode(CAN_RX, INPUT);
    pinMode(CAN_TX, OUTPUT);
    digitalWrite(CAN_TX, HIGH);
    delay(20);
    sampleRx(10000, highLow, highTotal);      // TX wysoko: punkt odniesienia
    digitalWrite(CAN_TX, LOW);                // próba kontrolna: TX nisko → RX musi pokazać nisko
    sampleRx(500, ctrlLow, ctrlTotal);
    digitalWrite(CAN_TX, HIGH);
    delay(20);
    pinMode(CAN_TX, INPUT);                   // TX wisi, jak w czasie startu
    sampleRx(20000, floatLow, floatTotal);
    pinMode(CAN_TX, OUTPUT);
    digitalWrite(CAN_TX, HIGH);
    delay(20);
    pinMode(CAN_TX, INPUT_PULLUP);            // TX wisi z wewnętrznym podciąganiem
    sampleRx(20000, pullLow, pullTotal);
    pinMode(CAN_TX, OUTPUT);
    digitalWrite(CAN_TX, HIGH);
}
#endif

void setup() {
    // Zanim cokolwiek innego: linia nadawania w stan spoczynkowy (recesywny).
    pinMode(CAN_TX, OUTPUT);
    digitalWrite(CAN_TX, HIGH);
#ifdef TX_FLOAT_TEST
    txFloatTest();
#endif
#ifndef FAKE_BUS
    canRunning = canStart();
#endif
    lastCanTry = millis();

    esp_task_wdt_init(WDT_SECONDS, true);
    esp_task_wdt_add(NULL);

    Serial.begin(115200);
    // Bez komputera na USB zapis do portu nie może blokować pętli.
    Serial.setTxTimeoutMs(0);

    NimBLEDevice::init(DEVICE_NAME);
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);
    NimBLEDevice::setMTU(247);
    NimBLEServer *server = NimBLEDevice::createServer();
    server->setCallbacks(new ServerEvents());
    NimBLEService *svc = server->createService(SVC_UUID);
    teleChar = svc->createCharacteristic(TELE_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
    rawChar = svc->createCharacteristic(RAW_UUID, NIMBLE_PROPERTY::NOTIFY);
    rawChar->setCallbacks(new RawEvents());
#if OTA_ENABLED
    otaQueue = xMessageBufferCreate(12 * 1024);
    otaChar = svc->createCharacteristic(OTA_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::NOTIFY);
    otaChar->setCallbacks(new OtaEvents());
#endif
#ifndef FAKE_BUS
    diagChar = svc->createCharacteristic(DIAG_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY);
    diagChar->setCallbacks(new DiagEvents());
#endif
    svc->start();

    NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
    adv->addServiceUUID(SVC_UUID);
    adv->setScanResponse(true);
    adv->start();
}

void loop() {
    static uint32_t lastNotify = 0, lastStats = 0, lastRaw = 0, lastRawAll = 0;
    static bool rawActive = false, rawAll = false;
    uint32_t now = millis();
    esp_task_wdt_reset();

#ifdef FAKE_BUS
    fakeBusPoll(now);
    delay(1);
#else
    if (!canRunning && !otaBusy() && now - lastCanTry > 1000) {
        lastCanTry = now;
        canRunning = canStart();
    }
#endif

#if OTA_ENABLED
    {
        // Odmowa, gdy motocykl jedzie albo pracuje silnik. Cicha szyna (zapłon wyłączony,
        // płytka na samym USB) nie blokuje — wtedy nic się nie rusza.
        bool busAlive = canRunning && core.busFps > 0;
        bool moving = busAlive && (core.rpm > 0 || core.extra[23] || core.extra[24] || core.extra[25] || core.extra[26]);
        uint8_t msg[300];
        size_t n;
        while (otaQueue && (n = xMessageBufferReceive(otaQueue, msg, sizeof(msg), 0)) > 0) {
            bool was = otaSession.active;
            bridge::ota::Reply r = otaSession.onMessage(otaFlash, msg, n, millis(), moving);
            if (!was && otaSession.active && canRunning) {
                // Na czas aktualizacji płytka odpina się od szyny; linia nadawania w spoczynku.
                twai_stop();
                twai_driver_uninstall();
                canRunning = false;
                pinMode(CAN_TX, OUTPUT);
                digitalWrite(CAN_TX, HIGH);
            }
            otaNotify(r);
            if (r.send && r.status == bridge::ota::DONE) otaRestartAt = millis() + 1500;
            esp_task_wdt_reset();
        }
        otaNotify(otaSession.tick(otaFlash, millis()));
        if (otaRestartAt && int32_t(millis() - otaRestartAt) >= 0) {
            Serial.println("OTA: nowy program przyjety, restart");
            delay(100);
            ESP.restart();
        }
        // Potwierdzenie programu startującego „na próbę": telefon połączony od 3 s.
        static uint32_t connectedSince = 0;
        if (!bleConnected) connectedSince = 0;
        else if (!connectedSince) connectedSince = millis() | 1;
#ifndef OTA_NEVER_CONFIRM
        if (!imageConfirmed && connectedSince && millis() - connectedSince > 3000) {
            esp_ota_mark_app_valid_cancel_rollback();
            imageConfirmed = true;
        }
#endif
    }
    now = millis();
#endif

    if (canRunning) {
        twai_message_t m;
        // Pierwsze czekanie oddaje procesor, reszta opróżnia kolejkę do końca.
        TickType_t wait = pdMS_TO_TICKS(5);
        while (twai_receive(&m, wait) == ESP_OK) {
            handleFrame(m, now);
            wait = 0;
        }
    } else {
#ifndef FAKE_BUS
        delay(5);
#endif
    }

    now = millis();
#ifndef FAKE_BUS
    {
        bool busAlive = canRunning && core.busFps > 0;
        bool moving = busAlive && (core.rpm > 0 || core.extra[23] || core.extra[24] || core.extra[25] || core.extra[26]);
        diagPoll(now, busAlive, moving);
    }
#endif
    // Ponowienie prośby o krótki odstęp połączenia: po 3 s i po 8 s, jeśli telefon go nie dał.
    if (bleConnected && connAsks < 3 && now - connectedAt > (connAsks == 1 ? 3000u : 8000u) && connInterval() > 12) {
        askConnParams(NimBLEDevice::getServer());
    }
    if (now - lastNotify >= NOTIFY_MS) {
        lastNotify = now;
        if (bleConnected && !otaBusy()) {                     // w trakcie aktualizacji całe łącze dla niej
            // Telemetria ma pierwszeństwo, ale przy prawie pełnej kolejce też czeka na następny takt.
            // Najwyżej dwa takty z rzędu — telemetria nie może zamilknąć, cokolwiek pokaże licznik.
            static uint8_t skipRun = 0;
            if (bleFreeBufs() * 4 >= bleTotalBufs() || skipRun >= 2) { sendTelemetry(now); skipRun = 0; }
            else { teleSkipped++; skipRun++; }
        }
    }

    if (!(bleConnected && rawSubscribed) || otaBusy()) {
        rawActive = false;
        core.rawCursor = 0;
    } else {
        if (!rawActive && now - lastRaw >= RAW_MS) {
            lastRaw = now;
            rawActive = true;
            rawAll = now - lastRawAll >= RAW_ALL_MS;
            if (rawAll) lastRawAll = now;
        }
        // Strumień do logu idzie tylko, gdy kolejka jest prawie pusta — nigdy kosztem telemetrii.
        if (rawActive) {
            if (bleFreeBufs() * 4 >= bleTotalBufs() * 3) { if (sendRawPacket(now, rawAll)) rawActive = false; }
            else rawSkipped++;
        }
    }

    if (now - lastStats >= 1000) {
        lastStats = now;
        core.secondTick();
        if (canRunning) {
            twai_status_info_t st;
            if (twai_get_status_info(&st) == ESP_OK) {
                lostCount = st.rx_missed_count + st.rx_overrun_count;
                // W trybie tylko-odbiór sterownik nie powinien wypaść z pracy, ale gdyby
                // jednak stanął — stawiamy go od nowa (nadal LISTEN_ONLY, patrz canStart).
                if (st.state != TWAI_STATE_RUNNING) {
                    if (diag.active) { diag.end(); diagHardStop = 0; diagFinish(bridge::diag::ERR_TX, diag.op, 0); }
                    twai_stop();
                    twai_driver_uninstall();
                    canRunning = false;
                    lastCanTry = now;
                }
            }
        }
#ifdef FAKE_BUS
        Serial.print("SYMULACJA ");
#endif
        Serial.printf("fw=%u can=%s ramki/s=%u zgubione=%u id=%d | rpm=%u gaz=%u bieg=%u przechyl=%.1f"
                      " plyn=%.0f kolo=%u/%u tryb=%u tc=%u | ble=%s%s mtu=%u\n",
                      (unsigned)bridge::FW_VERSION, canRunning ? "ok" : (otaBusy() ? "stop(ota)" : "BLAD"), (unsigned)core.busFps,
                      (unsigned)lostCount, core.rawUsed,
                      (unsigned)core.rpm, (unsigned)core.throttle, (unsigned)(core.b3 & 0x0F),
                      (int(core.leanWord) - 32768) * 180.0 / 32768.0,
                      core.coolant * 0.625 - 30.0,
                      (unsigned)((core.extra[23] << 8) | core.extra[24]), (unsigned)((core.extra[25] << 8) | core.extra[26]),
                      (unsigned)(core.extra[38] >> 4), (unsigned)(core.extra[41] >> 4),
                      bleConnected ? "polaczony" : "czeka", rawSubscribed ? "+raw" : "", (unsigned)peerMtu);
        Serial.printf("diag: %s ostatni=%02X\n", diag.active ? "TRWA (NORMAL)" : "nasluch", (unsigned)diagLastStatus);
        Serial.printf("lacze: bufory %d/%d, telemetria pominieta %u, surowe wstrzymane %u, odstep %.2f ms (prosby %u)\n",
                      bleFreeBufs(), bleTotalBufs(), (unsigned)teleSkipped, (unsigned)rawSkipped,
                      connInterval() * 1.25, (unsigned)connAsks);
        teleSkipped = 0;
        rawSkipped = 0;
#if OTA_ENABLED
        Serial.printf("ota: %s %u/%u stan=%02X program=%s\n",
                      otaSession.done ? "przyjety" : (otaSession.active ? "odbior" : "czeka"),
                      (unsigned)otaSession.received, (unsigned)otaSession.size, (unsigned)otaLastStatus,
                      imageConfirmed ? "potwierdzony" : "na probe");
#endif
    }

#ifdef TX_FLOAT_TEST
    static uint32_t lastT = 0;
    if (now - lastT >= 1000) {
        lastT = now;
        Serial.printf("TXTEST kontrola(TX nisko): %u/%u nisko | wysoko: %u/%u nisko | wisi: %u/%u nisko | wisi+pullup: %u/%u nisko\n",
                      (unsigned)ctrlLow, (unsigned)ctrlTotal,
                      (unsigned)highLow, (unsigned)highTotal, (unsigned)floatLow, (unsigned)floatTotal,
                      (unsigned)pullLow, (unsigned)pullTotal);
    }
#endif

    // 'r' w monitorze portu włącza/wyłącza zrzut surowych ramek, 'x' restartuje płytkę.
    while (Serial.available()) {
        int ch = Serial.read();
        if (ch == 'r') rawDump = !rawDump;
        if (ch == 'x') ESP.restart();       // do testów: restart bez wyjmowania kabla
    }
}
