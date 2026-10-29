// Aktualizacja programu płytki przez Bluetooth — sam protokół, bez sprzętu.
//
// Tak jak bridge_core.h: czysta logika na bajtach, żeby ten sam kod, który chodzi
// na płytce, dało się przetestować na komputerze (tools/can/fw_core_test.cpp),
// razem z przypadkami, których na motocyklu nie chcemy ćwiczyć: zły podpis,
// urwana transmisja, dziura w danych.
//
// BEZPIECZEŃSTWO. Płytka siedzi na szynie motocykla, więc nowy program przyjmuje
// tylko, gdy spełnione są WSZYSTKIE warunki:
//   1. motocykl stoi i silnik nie pracuje (sprawdza wywołujący, parametr `moving`),
//   2. cały obraz ma poprawny podpis HMAC-SHA256 kluczem znanym tylko płytce
//      i komputerowi, na którym powstaje program (klucza nie ma w apce —
//      apka niesie gotowy podpis, więc nie potrafi podpisać niczego innego),
//   3. obraz przechodzi kontrolę samego układu (suma w nagłówku programu).
// Dopiero wtedy płytka przełącza się na nowy program. Do tego czasu zapis idzie
// do zapasowego miejsca w pamięci, a działający program zostaje nietknięty.
//
// Wiadomości od telefonu (charakterystyka OTA, pierwszy bajt = rodzaj):
//   01 BEGIN  [rozmiar u32 LE][wersja u8][podpis 32 B]
//   02 DATA   [pozycja u32 LE][dane…]          (zapis bez potwierdzenia)
//   03 END
//   04 ABORT
// Odpowiedzi płytki (powiadomienie, 6 bajtów): [stan][pozycja u32 LE][wersja u8]
//   pozycja = ile bajtów obrazu płytka już przyjęła (dla ERR_OFFSET: od której
//   pozycji telefon ma wysyłać dalej).

#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace bridge {
namespace ota {

static const uint8_t OP_BEGIN = 1, OP_DATA = 2, OP_END = 3, OP_ABORT = 4;

enum Status : uint8_t {
    READY       = 0x10,   // BEGIN przyjęty, można wysyłać dane
    ACK         = 0x11,   // przyjęto dane do podanej pozycji
    DONE        = 0x12,   // obraz sprawdzony, płytka zaraz się zrestartuje
    ERR_MOVING  = 0x20,   // motocykl jedzie albo pracuje silnik — odmowa
    ERR_SIZE    = 0x21,   // rozmiar poza zakresem albo danych więcej, niż zapowiedziano
    ERR_FLASH   = 0x22,   // błąd zapisu albo obraz odrzucony przez układ
    ERR_OFFSET  = 0x23,   // dziura w danych — wyślij od podanej pozycji
    ERR_TAG     = 0x24,   // zły podpis — obraz odrzucony
    ERR_TIMEOUT = 0x25,   // telefon zamilkł — aktualizacja porzucona
    ERR_STATE   = 0x26,   // wiadomość nie pasuje do stanu (np. dane bez BEGIN)
    ABORTED     = 0x27,   // przerwane na życzenie telefonu
};

static const size_t   TAG_LEN    = 32;
static const size_t   BEGIN_LEN  = 1 + 4 + 1 + TAG_LEN;
static const uint32_t MIN_IMAGE  = 64 * 1024;       // mniejszy „program" to na pewno pomyłka
static const uint32_t MAX_IMAGE  = 0x140000;        // rozmiar miejsca na program w pamięci
static const uint32_t ACK_EVERY  = 2048;            // co tyle bajtów płytka potwierdza odbiór
static const uint32_t TIMEOUT_MS = 8000;            // tyle ciszy kończy aktualizację

// To, co zależy od sprzętu: zapis do pamięci i liczenie podpisu.
struct Platform {
    virtual bool begin(uint32_t size) = 0;                       // otwórz zapasowe miejsce
    virtual bool write(const uint8_t *data, size_t len) = 0;     // dopisz kolejne bajty
    virtual bool commit() = 0;                                   // sprawdź obraz i ustaw go do startu
    virtual void abort() = 0;                                    // porzuć zapis
    virtual void hmacStart() = 0;
    virtual void hmacUpdate(const uint8_t *data, size_t len) = 0;
    virtual void hmacFinish(uint8_t out[TAG_LEN]) = 0;
    virtual ~Platform() {}
};

struct Reply {
    bool     send = false;
    uint8_t  status = 0;
    uint32_t offset = 0;
};

struct Session {
    bool     active = false;     // trwa odbiór obrazu
    bool     done = false;       // obraz przyjęty — czeka restart
    uint32_t size = 0;
    uint32_t received = 0;
    uint8_t  version = 0;
    uint8_t  tag[TAG_LEN] = {0};
    uint32_t lastAck = 0;
    uint32_t lastActivity = 0;
    uint32_t nakFor = 0xFFFFFFFF;    // dla której pozycji poszła już prośba o powtórkę
    uint32_t stateErrAt = 0;
    bool     stateErrSent = false;

    Reply onMessage(Platform &p, const uint8_t *d, size_t n, uint32_t now, bool moving) {
        if (n == 0) return {};
        switch (d[0]) {
        case OP_BEGIN: return begin(p, d, n, now, moving);
        case OP_DATA:  return data(p, d, n, now);
        case OP_END:   return end(p);
        case OP_ABORT:
            if (!active) return {};
            stop(p);
            return make(ABORTED);
        default:
            return {};
        }
    }

    // Wołać regularnie: porzuca aktualizację, gdy telefon zamilkł.
    Reply tick(Platform &p, uint32_t now) {
        if (!active || now - lastActivity <= TIMEOUT_MS) return {};
        stop(p);
        return make(ERR_TIMEOUT);
    }

  private:
    Reply make(uint8_t status) {
        Reply r;
        r.send = true;
        r.status = status;
        r.offset = received;
        return r;
    }

    void stop(Platform &p) {
        p.abort();
        active = false;
    }

    static uint32_t le32(const uint8_t *d) {
        return uint32_t(d[0]) | uint32_t(d[1]) << 8 | uint32_t(d[2]) << 16 | uint32_t(d[3]) << 24;
    }

    Reply begin(Platform &p, const uint8_t *d, size_t n, uint32_t now, bool moving) {
        if (done) return make(ERR_STATE);              // obraz już przyjęty, czeka restart
        if (active) stop(p);                           // ponowny BEGIN = zaczynamy od zera
        received = 0;
        if (moving) return make(ERR_MOVING);
        if (n != BEGIN_LEN) return make(ERR_SIZE);
        uint32_t sz = le32(d + 1);
        if (sz < MIN_IMAGE || sz > MAX_IMAGE) return make(ERR_SIZE);
        if (!p.begin(sz)) return make(ERR_FLASH);
        size = sz;
        version = d[5];
        memcpy(tag, d + 6, TAG_LEN);
        lastAck = 0;
        lastActivity = now;
        nakFor = 0xFFFFFFFF;
        stateErrSent = false;
        p.hmacStart();
        active = true;
        return make(READY);
    }

    Reply data(Platform &p, const uint8_t *d, size_t n, uint32_t now) {
        if (!active) {
            // Po przerwaniu telefon może jeszcze dosyłać paczki z kolejki — jedna odpowiedź
            // na sekundę wystarczy, żeby się zorientował, bez zalewania łącza.
            if (stateErrSent && now - stateErrAt < 1000) return {};
            stateErrSent = true;
            stateErrAt = now;
            return make(ERR_STATE);
        }
        if (n < 6) return {};
        uint32_t off = le32(d + 1);
        const uint8_t *body = d + 5;
        size_t len = n - 5;
        if (off != received) {
            if (off + len <= received) return {};      // powtórka czegoś, co już mamy
            if (nakFor == received) return {};         // o tę pozycję już prosiliśmy
            nakFor = received;
            return make(ERR_OFFSET);
        }
        if (received + len > size) {
            stop(p);
            return make(ERR_SIZE);
        }
        if (!p.write(body, len)) {
            stop(p);
            return make(ERR_FLASH);
        }
        p.hmacUpdate(body, len);
        received += uint32_t(len);
        lastActivity = now;
        nakFor = 0xFFFFFFFF;
        if (received - lastAck >= ACK_EVERY || received == size) {
            lastAck = received;
            return make(ACK);
        }
        return {};
    }

    Reply end(Platform &p) {
        if (!active) return make(ERR_STATE);
        if (received != size) return make(ERR_OFFSET);   // brakuje danych — telefon ma dosłać
        uint8_t got[TAG_LEN];
        p.hmacFinish(got);
        uint8_t diff = 0;                                // porównanie w stałym czasie
        for (size_t i = 0; i < TAG_LEN; i++) diff |= uint8_t(got[i] ^ tag[i]);
        if (diff != 0) {
            stop(p);
            return make(ERR_TAG);
        }
        if (!p.commit()) {
            stop(p);
            return make(ERR_FLASH);
        }
        active = false;
        done = true;
        return make(DONE);
    }
};

}  // namespace ota
}  // namespace bridge
