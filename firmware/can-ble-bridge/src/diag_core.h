// Odczyt i kasowanie kodów błędów przez OBD na CAN (ISO 15765-4).
//
// Niezależne od sprzętu (testowane na komputerze: tools/can/fw_core_test.cpp).
// main.cpp na czas JEDNEJ komendy przełącza sterownik CAN z LISTEN_ONLY na NORMAL,
// wysyła ramki zwrócone przez tę sesję i wraca do nasłuchu.
//
// Zasady bezpieczeństwa (tu, nie w main.cpp, żeby dało się je przetestować):
//   - komenda tylko na prośbę telefonu, najwyżej raz na 3 s,
//   - odmowa, gdy silnik pracuje albo koło się kręci (ten sam warunek co aktualizacja),
//   - odmowa, gdy szyna milczy (zapłon wyłączony) — nie ma z kim rozmawiać,
//   - najwyżej 3 zapytania na komendę i najwyżej 8 ramek sterowania przepływem;
//     koniec po 2 s ciszy (5,5 s po „przetwarzam”), twardy limit w main.cpp,
//   - main.cpp wysyła każdą ramkę jednorazowo (bez powtórek przy braku potwierdzenia).
//
// GX nie odpowiedział na zwykłe zapytanie 11-bitowe 0x7DF (2026-10-25), więc są trzy
// sposoby adresowania, a komenda PROBE wysyła odczyt kodów wszystkimi po kolei:
//   0 = ogólne 11-bit 0x7DF (odpowiedzi 0x7E8–0x7EF)
//   1 = bezpośrednio do sterownika silnika 11-bit 0x7E0 (odpowiedź 0x7E8)
//   2 = ogólne 29-bit 0x18DB33F1 (odpowiedzi 0x18DAF1xx)
// W oknie komendy do telefonu idzie też KAŻDA ramka wyglądająca na diagnostyczną
// (11-bit 0x700–0x7FF i wszystkie 29-bit), nawet jeśli nie da się jej złożyć —
// żeby zobaczyć, czy i jak motocykl w ogóle odpowiada.
//
// Komenda z telefonu (charakterystyka DIAG_UUID): [op][adresowanie]
//   op 0x01 = ping (usługa 01, PID 00), 0x03 = odczyt kodów, 0x04 = SKASOWANIE kodów,
//   0x05 = PROBE (odczyt kodów wszystkimi trzema sposobami). Brak drugiego bajtu = 0.
// Powiadomienia do telefonu:
//   [0x00][op][ID b0][ID b1][ID b2][ID b3 | 0x80 gdy 29-bit][długość][dane ...]
//   [kod zakończenia][op][liczba odpowiedzi][wysłane][odrzucone][licznik błędów nadawania]

#pragma once
#include <stdint.h>
#include <string.h>

namespace bridge {
namespace diag {

enum Op : uint8_t { PING = 0x01, READ = 0x03, CLEAR = 0x04, PROBE = 0x05 };
enum Addr : uint8_t { FUNC11 = 0, PHYS11 = 1, FUNC29 = 2 };

enum Status : uint8_t {
    RESPONSE   = 0x00,  // odpowiedź jednego sterownika (dane w powiadomieniu)
    DONE       = 0x30,  // koniec komendy
    ERR_MOVING = 0x20,  // silnik pracuje albo koło się kręci
    ERR_BUSY   = 0x21,  // poprzednia komenda trwa albo za szybko po niej
    ERR_NO_BUS = 0x22,  // szyna milczy (zapłon wyłączony) albo CAN nie działa
    ERR_TX     = 0x23,  // ramki nie udało się wysłać
    ERR_OP     = 0x24,  // nieznana komenda albo adresowanie
};

static const uint32_t QUIET_MS = 2000;       // koniec po tylu ms bez odpowiedzi (od ostatniego zapytania)
static const uint32_t PENDING_MS = 5500;     // po „czekaj, przetwarzam” (7F xx 78) — czas na właściwą odpowiedź
static const uint32_t MIN_GAP_MS = 3000;     // najkrótszy odstęp między komendami
static const uint32_t PROBE_STEP_MS = 250;   // odstęp między zapytaniami w PROBE
static const uint8_t  MAX_FC = 8;            // limit ramek sterowania przepływem na komendę
static const uint8_t  MAX_ECU = 8;
static const uint8_t  MAX_PAYLOAD = 96;

struct Frame {
    uint32_t id = 0;
    bool ext = false;
    uint8_t data[8] = {0};
};

struct Response {
    uint32_t id = 0;
    bool ext = false;
    uint8_t len = 0;           // ile bajtów już złożonych
    uint8_t total = 0;         // ile ma być (z nagłówka ISO-TP)
    uint8_t nextSeq = 1;
    bool complete = false;
    bool reported = false;
    uint8_t data[MAX_PAYLOAD] = {0};
};

// Zapytanie o usługę `service` danym sposobem adresowania.
inline Frame request(uint8_t service, uint8_t addr) {
    Frame f;
    if (addr == FUNC29) { f.id = 0x18DB33F1; f.ext = true; }
    else f.id = addr == PHYS11 ? 0x7E0 : 0x7DF;
    if (service == PING) { f.data[0] = 0x02; f.data[1] = 0x01; f.data[2] = 0x00; }
    else { f.data[0] = 0x01; f.data[1] = service; }
    return f;
}

class Session {
public:
    bool active = false;
    uint8_t op = 0;
    uint8_t fcSent = 0;
    uint32_t lastActivity = 0, lastStart = 0, pendingUntil = 0;
    bool everStarted = false;
    Response ecus[MAX_ECU];
    uint8_t ecuCount = 0;
    // zaplanowane zapytania
    Frame queue[3];
    uint8_t queued = 0, sent = 0;

    // Start komendy. 0 = OK (zapytania odbierać z nextRequest), inaczej kod błędu.
    uint8_t start(uint8_t command, uint8_t addr, bool moving, bool busAlive, uint32_t now) {
        if (command != PING && command != READ && command != CLEAR && command != PROBE) return ERR_OP;
        if (addr > FUNC29) return ERR_OP;
        if (active || (everStarted && now - lastStart < MIN_GAP_MS)) return ERR_BUSY;
        if (!busAlive) return ERR_NO_BUS;
        if (moving) return ERR_MOVING;
        active = true;
        everStarted = true;
        op = command;
        fcSent = 0;
        ecuCount = 0;
        for (auto &e : ecus) e = Response();
        lastStart = lastActivity = pendingUntil = now;
        queued = sent = 0;
        if (command == PROBE) {
            queue[queued++] = request(READ, FUNC11);
            queue[queued++] = request(READ, PHYS11);
            queue[queued++] = request(READ, FUNC29);
        } else {
            queue[queued++] = request(command, addr);
        }
        return 0;
    }

    // Następne zapytanie do wysłania teraz (PROBE: co 250 ms), albo false.
    bool nextRequest(uint32_t now, Frame &out) {
        if (!active || sent >= queued) return false;
        if (now - lastStart < uint32_t(sent) * PROBE_STEP_MS) return false;
        out = queue[sent++];
        lastActivity = now;
        return true;
    }

    // Ramka z szyny. Zwraca true, gdy trzeba wysłać ramkę sterowania przepływem `fc`.
    bool onFrame(uint32_t id, bool ext, uint8_t dlc, const uint8_t *d, uint32_t now, Frame &fc) {
        if (!active || dlc < 1 || dlc > 8) return false;
        bool std7E8 = !ext && id >= 0x7E8 && id <= 0x7EF;
        bool resp29 = ext && (id & 0xFFFFFF00u) == 0x18DAF100u;
        bool diagLike = (!ext && id >= 0x700 && id <= 0x7FF && id != 0x7DF && !(id >= 0x7E0 && id <= 0x7E7)) || ext;
        if (!diagLike) return false;
        uint8_t pci = d[0] >> 4;
        Response *r = find(id, ext);
        if (!r) return false;
        lastActivity = now;
        bool isoTp = std7E8 || resp29;
        if (!isoTp || pci > 2) {                          // nieznana odpowiedź — surowe bajty
            memcpy(r->data, d, dlc);
            r->len = r->total = dlc;
            r->complete = true;
            r->reported = false;
            return false;
        }
        if (pci == 0) {                                   // pojedyncza ramka
            uint8_t n = d[0] & 0x0F;
            if (n > 7 || n + 1 > dlc) return false;
            memcpy(r->data, d + 1, n);
            r->len = r->total = n;
            r->complete = true;
            r->reported = false;                          // nowa odpowiedź tego samego sterownika też idzie dalej
            if (n >= 3 && d[1] == 0x7F && d[3] == 0x78) pendingUntil = now + PENDING_MS;
        } else if (pci == 1) {                            // pierwsza ramka dłuższej odpowiedzi
            if (dlc < 8) return false;
            uint16_t n = uint16_t((d[0] & 0x0F) << 8) | d[1];
            r->total = n > MAX_PAYLOAD ? MAX_PAYLOAD : uint8_t(n);
            memcpy(r->data, d + 2, 6);
            r->len = r->total < 6 ? r->total : 6;
            r->nextSeq = 1;
            r->complete = r->len >= r->total;
            r->reported = false;
            if (fcSent >= MAX_FC) return false;
            fcSent++;
            fc = Frame();
            fc.ext = ext;
            // adres fizyczny tego sterownika: 11-bit 7E8→7E0, 29-bit 18DAF1xx→18DAxxF1
            fc.id = ext ? (0x18DA00F1u | ((id & 0xFF) << 8)) : id - 8;
            fc.data[0] = 0x30;                            // „wysyłaj dalej”, bez bloków i przerw
            return true;
        } else if (pci == 2 && !r->complete && r->total > 0) {   // kolejna ramka
            if ((d[0] & 0x0F) != (r->nextSeq & 0x0F)) return false;
            r->nextSeq++;
            uint8_t take = r->total - r->len;
            if (take > 7) take = 7;
            if (take > dlc - 1) take = dlc - 1;
            memcpy(r->data + r->len, d + 1, take);
            r->len += take;
            r->complete = r->len >= r->total;
        }
        return false;
    }

    // Następna gotowa, jeszcze nie zgłoszona odpowiedź (do wysłania telefonowi) albo nullptr.
    Response *nextReport() {
        for (uint8_t i = 0; i < ecuCount; i++)
            if (ecus[i].complete && !ecus[i].reported) { ecus[i].reported = true; return &ecus[i]; }
        return nullptr;
    }

    // true = komenda zakończona (wszystkie zapytania wysłane, cisza); main.cpp wraca wtedy do nasłuchu.
    bool finished(uint32_t now) const {
        return active && sent >= queued && now - lastActivity >= QUIET_MS && int32_t(now - pendingUntil) >= 0;
    }

    uint8_t reportedCount() const {
        uint8_t n = 0;
        for (uint8_t i = 0; i < ecuCount; i++) n += ecus[i].reported;
        return n;
    }

    void end() { active = false; }

private:
    Response *find(uint32_t id, bool ext) {
        for (uint8_t i = 0; i < ecuCount; i++) if (ecus[i].id == id && ecus[i].ext == ext) return &ecus[i];
        if (ecuCount >= MAX_ECU) return nullptr;
        ecus[ecuCount] = Response();
        ecus[ecuCount].id = id;
        ecus[ecuCount].ext = ext;
        return &ecus[ecuCount++];
    }
};

}  // namespace diag
}  // namespace bridge
