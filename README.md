# SpinMyCan

Własny ekran na kolorowy wyświetlacz TFT motocykla Suzuki GSX-S1000GX — z telefonu (iOS),
po protokole zgodnym z mySPIN — plus mostek **CAN → Bluetooth**, który czyta dane prosto
z szyny motocykla: obroty, bieg, przechył, temperatury, tryby jazdy i zawieszenia, przebieg.

*An open-source iOS dashboard for the Suzuki GSX-S1000GX TFT display (mySPIN-compatible
protocol) and an ESP32 CAN-to-BLE bridge that reads live data from the bike's CAN bus.
Documentation and code comments are in Polish.*

> **Niezależny projekt hobbystyczny.** Nie jest związany z Robert Bosch GmbH (właścicielem
> mySPIN) ani z Suzuki Motor Corporation, nie jest przez nie wspierany ani zatwierdzony.
> Nazwy mySPIN, Suzuki i GSX-S1000GX służą tu wyłącznie do opisania, z czym projekt
> współpracuje. Repozytorium nie zawiera kodu ani zasobów tych firm.

## ⚠️ Bezpieczeństwo — przeczytaj przed użyciem

- **Używasz na własne ryzyko.** Oprogramowanie jest dostarczane „tak jak jest”, bez żadnej
  gwarancji (zob. [LICENSE](LICENSE)). Autorzy nie odpowiadają za szkody w motocyklu,
  sprzęcie, zdrowiu ani za skutki prawne.
- **Nie obsługuj telefonu w czasie jazdy.** Patrz na drogę, nie na deskę.
- **Płytka domyślnie tylko słucha szyny** (tryb LISTEN_ONLY) i nic na nią nie wysyła.
  Wyjątkiem jest diagnostyka — odczyt i **kasowanie kodów błędów** — dostępna tylko na postoju,
  z wyłączonym silnikiem i nieruchomymi kołami, jedna komenda naraz. Skasowanie kodu
  **nie usuwa usterki**, tylko ją ukrywa: jeśli kontrolka wraca, jedź do serwisu.
- **Podłączenie do złącza diagnostycznego:** zanim cokolwiek podłączysz, sprawdź piny
  miernikiem (wtyczka widziana z naprzeciwka jest lustrzanym odbiciem gniazda), zapewnij
  wspólną masę płytki i motocykla i nigdy nie zwieraj linii CAN-H i CAN-L. Chwilowe zwarcie
  przy złączu potrafi zapalić kontrolki FI / E-SUS (opis w `tools/can/SYGNALY.md`).
- Grzebanie przy instalacji elektrycznej może naruszyć warunki gwarancji producenta.

## Co jest w środku

**Apka iOS** (`MySpin/`, Swift / SwiftUI) — strumieniuje gotowe klatki 864×320 na wyświetlacz
motocykla i obsługuje joystick z kierownicy:

- ekrany deski: klasyczny (prędkość, bieg, obroty, tryb jazdy / trakcja / zawieszenie,
  przebieg), przechył, nawigacja z mapą, muzyka (Spotify / odtwarzacz), pomiary osiągów,
  wideo (własne filmy, działają też przy zablokowanym telefonie), wspomnienia ze zdjęć,
  Terminal CAN, gry (wąż, sudoku);
- nagrywanie tras z GPS, danymi z silnika i piosenkami, biblioteka tras z odtwarzaniem,
  plakat trasy do udostępnienia (format relacji 9:16 / posta 4:5), kopia tras w folderze
  iCloud Drive;
- Dynamic Island / ekran blokady (rozszerzenie `ride_widget`), udostępnianie celu z Map Apple
  (`share_extension`).

**Mostek CAN → BLE** (`firmware/can-ble-bridge/`, ESP32-S3, PlatformIO) — płytka
Waveshare ESP32-S3-RS485-CAN na złączu diagnostycznym motocykla. Wysyła telefonowi telemetrię
(30 pakietów/s) i surowe ramki do logu, aktualizuje się przez Bluetooth (podpisane obrazy).

**Narzędzia** (`tools/`) — rozszyfrowane sygnały szyny (`tools/can/SYGNALY.md`, z logami-dowodami
w `tools/can/dowody/`), analiza logów (`canlog.py`), panel CAN w przeglądarce do oglądania
ramek i tras (`make can-panel`).

## Budowanie

Wymagania: macOS z Xcode 26 (iOS 26.4), telefon z iOS 26, Python 3, dla płytki PlatformIO.

1. W Xcode ustaw własny zespół podpisu (Signing & Capabilities) dla trzech celów: `MySpin`,
   `ride_widget`, `share_extension`. Zmień identyfikatory pakietów (`wassup.MySpin…`)
   i grupę aplikacji (`group.com.mikomaks.myspin`) na własne.
2. Symulator: `make sim-build`
3. Telefon: `make install DEVICE_UDID=<UDID>` (UDID: `xcrun devicectl list devices`)
4. Płytka: `make fw-key` (raz — własny klucz podpisu aktualizacji, zostaje tylko u ciebie),
   potem `make fw-flash` (kabel USB) albo `make fw-bundle` + `make install` (aktualizacja
   przez Bluetooth z apki).

Film wbudowany w ekran „Wideo” jest opcjonalny: wrzuć własny plik do `video/isle_of_man_tt.mp4`
i zrób `make video` (wymaga ffmpeg) — albo dodaj filmy w apce z Galerii / Plików.

## Współdziałanie

Format komunikacji z wyświetlaczem ustalono wyłącznie w celu współdziałania niezależnie
stworzonego programu z urządzeniem, które właściciel legalnie posiada (art. 6 dyrektywy
2009/24/WE; art. 75 ust. 2 polskiej ustawy o prawie autorskim). Sygnały szyny CAN odczytano
z własnego motocykla.

## Licencje

- Kod: [MIT](LICENSE)
- Czcionka Monocraft (`MySpin/Monocraft.ttf`) — © Idrees Hassan, SIL Open Font License 1.1,
  [licenses/Monocraft-OFL.txt](licenses/Monocraft-OFL.txt)
