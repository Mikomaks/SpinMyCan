<p align="center">
  <img src="docs/media/classic.gif" width="864" alt="Deska SpinMyCan na wyświetlaczu motocykla — animacja">
</p>

<h1 align="center">SpinMyCan</h1>

<p align="center">
  <b>Własna deska na kolorowym TFT Suzuki GSX-S1000GX — prosto z iPhone'a.</b><br>
  Przechył, prędkość, nawigacja, muzyka, nagrywanie tras… a z opcjonalną płytką CAN także
  obroty, bieg, tryby jazdy i zawieszenia, temperatury i przebieg prosto z szyny motocykla.
</p>

<p align="center">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white">
  <img alt="iOS 26" src="https://img.shields.io/badge/iOS-26-000000?logo=apple&logoColor=white">
  <img alt="ESP32-S3" src="https://img.shields.io/badge/ESP32--S3-CAN%20%E2%86%92%20BLE-E7352C?logo=espressif&logoColor=white">
  <img alt="MIT" src="https://img.shields.io/badge/licencja-MIT-blue">
  <img alt="Bez płytki też działa" src="https://img.shields.io/badge/p%C5%82ytka%20CAN-opcjonalna-2ea44f">
  <a href="https://github.com/Mikomaks/SpinMyCan/releases"><img alt="Wersja" src="https://img.shields.io/github/v/release/Mikomaks/SpinMyCan"></a>
</p>

<p align="center"><a href="README.md">🇬🇧 English version</a></p>

> *An open-source iOS dashboard for the Suzuki GSX-S1000GX TFT (mySPIN-compatible protocol),
> with an optional ESP32 CAN-to-BLE bridge for live engine data. Works great with just the phone.
> Docs and code comments are in Polish.*

> [!NOTE]
> Niezależny projekt hobbystyczny — **niezwiązany z Robert Bosch GmbH (mySPIN) ani z Suzuki**,
> nie jest przez nie wspierany. Nazwy służą tylko do opisania, z czym projekt współpracuje.
> Grafiki w tym README są wyrenderowane przez apkę na **danych pokazowych**.

---

## 📱 Wystarczy sam telefon

**Płytka CAN jest dodatkiem, nie wymaganiem.** Bez niej apka działa w pełni: prędkość bierze
z GPS, przechył i przeciążenie z czujników telefonu w uchwycie (z kalibracją), a resztę —
nawigację, muzykę, nagrywanie tras, wideo, gry — robi sama. Płytka dokłada to, czego telefon
nie wie: obroty, bieg, gaz, tryby, temperatury, zawieszenie, przebieg i dokładny przechył
z czujnika motocykla.

| Sam telefon | Telefon + płytka CAN |
|:---:|:---:|
| <img src="docs/media/still_classic_phone.png" width="420"> | <img src="docs/media/still_classic_can.png" width="420"> |
| prędkość z GPS, przechył z telefonu, muzyka | + bieg, obroty, gaz, tryb B / TC 3 / zawieszenie M, płyn, przebieg, ugięcie zawieszenia |

## ✨ Co potrafi

- **11 ekranów deski** przełączanych joystickiem z kierownicy (kolejność ustawiasz w apce)
- **Przechył** na żywo z rekordami lewo / prawo, przeciążenie, kurs, wysokość, pogoda
- **Nawigacja** z Apple Maps na desce — wyślij cel z Map przez „Udostępnij”
- **Muzyka**: okładka, postęp i ekran *Disco* z tekstem piosenki; sterowanie joystickiem
- **Trasy**: nagrywają się same po połączeniu z motocyklem — GPS, przechył, bieg, obroty
  i piosenki; biblioteka z odtwarzaniem na mapie, eksport CSV, kopia w iCloud Drive
- **Plakat trasy** do relacji / posta na Instagram — konfigurowalny, z biegami i „utworem trasy”
- **Wideo**: własne filmy na desce (grają też przy zablokowanym telefonie)
- **Terminal CAN** — surowe ramki szyny z dekodowaniem na żywo
- **Gry**: wąż i sudoku 🐍 (na postoju, proszę)
- **Dynamic Island** i ekran blokady z prędkością i biegiem
- Jasny i ciemny motyw (skrót ▲▼▲▼ na joysticku), ostra pikselowa czcionka 1:1 z wyświetlaczem

## 🖼️ Ekrany

| | |
|:---:|:---:|
| <img src="docs/media/lean.gif" width="420"><br>**Przechył** | <img src="docs/media/still_nav.png" width="420"><br>**Nawigacja + deska** |
| <img src="docs/media/still_disco.png" width="420"><br>**Disco** — okładka i tekst | <img src="docs/media/still_nav_full.png" width="420"><br>**Nawigacja** na cały ekran |
| <img src="docs/media/still_classic_can_light.png" width="420"><br>**Jasny motyw** na pełne słońce | <img src="docs/media/still_perf.png" width="420"><br>**Pomiary** 0–100, ¼ mili |
| <img src="docs/media/still_snake.png" width="420"><br>**Wąż** | <img src="docs/media/still_sudoku.png" width="420"><br>**Sudoku** |

### 🟩 Terminal CAN

<p align="center"><img src="docs/media/hacker.gif" width="864" alt="Terminal CAN — przewijające się ramki"></p>

Ramki z szyny motocykla w stylu `candump`, zmienione bajty podświetlone, po prawej odczyt
sygnałów i lista kodów błędów.

## 📲 Apka

| Ekran główny | Trasa | Plakat | Ustawienia |
|:---:|:---:|:---:|:---:|
| <img src="docs/media/app_main.jpg" width="200"> | <img src="docs/media/app_ride.jpg" width="200"> | <img src="docs/media/app_poster.jpg" width="200"> | <img src="docs/media/app_settings.jpg" width="200"> |

### Plakat trasy

<p align="center">
  <img src="docs/media/poster_story.jpg" height="520" alt="Plakat trasy — relacja 9:16">
  &nbsp;
  <img src="docs/media/poster_post.jpg" height="420" alt="Plakat trasy — post 4:5">
</p>

Mapa z kolorem prędkości, rekordy, biegi (słupki albo wykres kołowy z czasem na każdym biegu),
piosenka, która grała najdłużej, i cała ścieżka dźwiękowa trasy. Format relacji 9:16, posta 4:5
albo pełny plakat.

## ⚙️ Jak to działa

```mermaid
flowchart LR
    subgraph Motocykl
        CAN["Szyna CAN<br/>(złącze diagnostyczne)"]
        TFT["Wyświetlacz TFT"]
        JOY["Joystick"]
    end
    BOARD["Płytka ESP32-S3<br/>(opcjonalna, tylko słucha)"]
    PHONE["iPhone<br/>SpinMyCan"]
    CAN -- "500 kbit/s" --> BOARD
    BOARD -- "Bluetooth LE<br/>30 pakietów/s" --> PHONE
    PHONE -- "WiFi: klatki JPEG 864×320" --> TFT
    JOY -- "przyciski" --> PHONE
```

Telefon rysuje każdą klatkę deski sam i wysyła ją na wyświetlacz jako gotowy obrazek —
dlatego deska może wyglądać jak chcesz. Joystick z kierownicy wraca do telefonu i przełącza
ekrany, muzykę, wideo, gry.

## 🔌 Płytka CAN (opcjonalna)

[Waveshare ESP32-S3-RS485-CAN](https://www.waveshare.com/) wpięta w złącze diagnostyczne
motocykla. Domyślnie **tylko słucha** szyny i wysyła telefonowi telemetrię przez Bluetooth;
aktualizuje się bezprzewodowo z apki (podpisane obrazy). Program w `firmware/can-ble-bridge/`.

<details>
<summary><b>Rozszyfrowane sygnały GSX-S1000GX</b> (pełny opis: <code>tools/can/SYGNALY.md</code>)</summary>

| Sygnał | ID | Sygnał | ID |
|---|---|---|---|
| Obroty, gaz, bieg | `1A1` | Przechył, płyn, sprzęgło | `1A5` |
| Przebieg, powietrze | `231` | Tryb jazdy A / B / C | `331` |
| Trakcja (każdy tryb osobno) | `335` | Tryb obciążenia (SOLO / DUO…) | `1AD` |
| Tłumienie H / M / S / U | `32D` | Skok zawieszenia przód / tył | `17D` |
| Prędkość kół | `19D` | Przyspieszenia 3 osie | `181` |
| Tempomat | `341` | Zapisane kody błędów | `441` |

Każdy sygnał ma nagranie-dowód w `tools/can/dowody/`. Do analizy: `tools/can/canlog.py`
i panel w przeglądarce `make can-panel` (ramki na żywo albo z logu, trasa GPS na mapie).
</details>

## ⚠️ Bezpieczeństwo

- **Używasz na własne ryzyko** — oprogramowanie jest „tak jak jest”, bez gwarancji ([LICENSE](LICENSE)).
- **Nie obsługuj telefonu w czasie jazdy.** Patrz na drogę, nie na deskę.
- Płytka wysyła cokolwiek na szynę wyłącznie przy **diagnostyce** (odczyt / kasowanie kodów
  błędów): tylko na postoju, z wyłączonym silnikiem, jedna komenda naraz. Skasowanie kodu
  **nie naprawia usterki** — jeśli kontrolka wraca, jedź do serwisu.
- Przed podłączeniem do złącza **sprawdź piny miernikiem** (wtyczka z naprzeciwka to lustrzane
  odbicie gniazda), zapewnij wspólną masę i nie zwieraj CAN-H z CAN-L — chwilowe zwarcie
  potrafi zapalić FI / E-SUS.
- Ingerencja w instalację elektryczną może naruszyć gwarancję producenta.

## 🛠️ Budowanie

<details>
<summary>Apka iOS i płytka</summary>

Wymagania: macOS z Xcode 26, iPhone z iOS 26, Python 3; dla płytki PlatformIO.

1. W Xcode ustaw własny zespół podpisu dla celów `MySpin`, `ride_widget`, `share_extension`
   oraz własne identyfikatory (`wassup.MySpin…`, `group.com.mikomaks.myspin`).
2. Symulator: `make sim-build`
3. Telefon: `make install DEVICE_UDID=<UDID>` (UDID: `xcrun devicectl list devices`)
4. Płytka (opcjonalnie): `make fw-key` (raz — twój klucz podpisu aktualizacji), potem
   `make fw-flash` po USB albo `make fw-bundle` + `make install` (aktualizacja z apki).

Film wbudowany w ekran „Wideo” jest opcjonalny: `video/isle_of_man_tt.mp4` + `make video`
(ffmpeg) — albo dodaj własne filmy w apce z Galerii / Plików.

Grafiki do tego README robi sama apka: `README_SHOTS=1` w symulatorze (`MySpin/ReadmeMedia.swift`), a `tools/readme_media.sh` składa z nich animacje.
</details>

## 📜 Współdziałanie i licencje

Format komunikacji z wyświetlaczem ustalono wyłącznie w celu współdziałania niezależnie
stworzonego programu z urządzeniem, które właściciel legalnie posiada (art. 6 dyrektywy
2009/24/WE; art. 75 ust. 2 ustawy o prawie autorskim). Repozytorium nie zawiera kodu ani zasobów
Boscha ani Suzuki. Sygnały CAN odczytano z własnego motocykla.

- Kod: [MIT](LICENSE)
- Czcionka Monocraft — © Idrees Hassan, SIL Open Font License 1.1 ([licenses/Monocraft-OFL.txt](licenses/Monocraft-OFL.txt))
