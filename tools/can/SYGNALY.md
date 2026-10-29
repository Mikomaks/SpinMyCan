# Sygnały na szynie CAN — Suzuki GSX-S1000GX

Szyna na złączu diagnostycznym (czerwone 6-pin pod siedzeniem): 500 kbit/s, 28 ID,
ok. 1970 ramek/s, wszystkie ramki 8-bajtowe, ID 11-bitowe. Tylko nasłuch.

To jest opis dla ludzi. Źródłem prawdy dla programów jest tabela `KNOWN` w
[canlog.py](canlog.py); test [verify_decode.py](verify_decode.py) sprawdza ją na
wycinkach prawdziwych nagrań z katalogu [dowody/](dowody/) (`make can-test`).
Przy każdej zmianie tutaj trzeba zmienić też `KNOWN`, a jeśli sygnał idzie do apki —
`firmware/can-ble-bridge/src/bridge_core.h` i `MySpin/BikeLinkManager.swift`.

Zapis: bajty liczone od 0; słowa 16-bitowe są big-endian (starszy bajt pierwszy);
„górna/dolna połówka” = starsze/młodsze 4 bity bajtu. W większości ramek bajt 6 to
licznik kolejności (0–15), a bajt 7 bywa sumą kontrolną — oba pomijać.

## Potwierdzone

Potwierdzone = sprawdzone w obie strony (włącz/wyłącz, kolejne nastawy) albo porównane
z liczbą na wyświetlaczu motocykla.

| Sygnał | ID | Gdzie | Przeliczenie | Jak potwierdzono |
|---|---|---|---|---|
| Obroty silnika | `1A1` | bajty 0–1 | wprost, obr/min | kalibracja przy 2500 obr/min (06.2026) |
| Manetka gazu | `1A1` | bajt 2 + górne 2 bity bajtu 3 | `(b2 << 2) \| (b3 >> 6)`: 0 = zamknięta, ok. 690 = do oporu | zamknięta / do oporu |
| Bieg | `1A1` | bajt 3, dolna połówka | 0 = luz, 1–6 | sekwencja N→2→3→2→1→N |
| Przechył | `1A5` | bajty 0–1 | `(słowo − 32768) × 180 / 32768` stopni, ujemny = w lewo | nóżka −15°, pion −1,5°; w jeździe zgodny z przechyłem wyliczonym z GPS (prędkość × tempo skrętu): 0,98× w wyraźnych zakrętach |
| Płyn chłodzący | `1A5` | bajt 4 | `0,625 × b − 30` °C | wyświetlacz 58 / 70 / 80 / 88 °C |
| Sprzęgło | `1A5` | bajt 5, bit `0x04` | 1 = wciśnięte | wciśnięte 18 s, puszczone |
| Przycisk startu | `1A5` | bajt 5, bit `0x10` | 1 = wciśnięty | odpalenie silnika |
| Powietrze | `231` | bajt 5 | `b − 30` °C | wyświetlacz 23 / 28 / 32 °C |
| Przebieg | `231` | bajty 2–3 + górna połówka bajtu 4 | 20 bitów, km | 22980 km = licznik; w czerwcu 16221; w jeździe +20 km przy 19,3 km z GPS |
| Tryb jazdy (SDMS) | `331` | bajt 5, górna połówka | 1 = A, 2 = B, 3 = C | B→A→B→C→B |
| Trakcja, bieżąca | `335` | bajt 3, górna połówka | 0 = OFF, 1–7 | OFF→1→…→7 |
| Trakcja zapisana dla trybu B | `335` | bajt 2, górna połówka | 0–7 | zmieniała się w B, stała w C |
| Tryb obciążenia | `1AD` | bajt 3, górna połówka | 2 = AUTO, 3 = SOLO, 4 = SOLO+bagaż, 5 = DUO | SOLO→AUTO→SOLO→bagaż→DUO→SOLO |
| ACTIVE DAMPING | `32D` | bajt 0, dolna połówka | 0 = H, 1 = M, 2 = S, 3 = U | M→H→M→S→U→S→M |
| Korekta tłumienia U, przód | `1AD` | bajt 1, dolna połówka | `n − 7`, od −3 do +3 | ustawione +2 |
| Korekta tłumienia U, tył | `1AD` | bajt 2, dolna połówka | `n − 7`, od −3 do +3 | ustawione −3 |
| Skok przedniego zawieszenia | `17D` | bajty 0–1 | surowe; mniejsza = bardziej ugięte | nóżka 1290, z kierowcą 1119; w jeździe: równo ok. 1000, hamowanie ok. 700, przyspieszanie ok. 1240 |
| Skok tylnego zawieszenia | `17D` | bajty 2–3 | surowe; mniejsza = bardziej ugięte | nóżka 656, z kierowcą ok. 458, skakanie 422–510 |
| Prędkość przedniego koła | `19D` | bajty 0–1 | `słowo × 0,01` km/h | stojak + jazda: koło × 1,010 = GPS, równo od 30 do 140 km/h; z niego bierze prędkość wyświetlacz |
| Prędkość tylnego koła | `19D` | bajty 2–3 | `słowo × 0,01` km/h | stojak; w równej jeździe tył/przód = 0,985 |
| Licznik impulsów przedniego koła | `221` | bajty 0–1 | 16 bitów, zawija się; 26,97 impulsu na metr | liczy tylko przy obrocie przodu; 520 tys. impulsów na 19,3 km z GPS |
| Tempomat włączony | `341` | bajt 3, bit `0x10` | 1 = włączony | włącz / wyłącz |
| Przyspieszenia | `181` | bajty 0–1, 2–3, 4–5 | `(słowo − 32768) / 5000` g: wzdłużne (**dodatnie = hamowanie**), pionowe, boczne | pionowe ≈ −1 g na postoju; wzdłużne = −1,06 × przyspieszenie z prędkości koła (r = −0,98) w jeździe |

Uwagi:

- **Wyświetlacz motocykla wygładza i opóźnia** temperatury i prędkość (płyn ok. 25 s).
  Szyna reaguje od razu, więc przy szybkich zmianach liczby się rozjeżdżają — to nie błąd.
- **Bieg w połowie zmiany**: pole biegu podaje wtedy chwilowo 14. Na postoju nie dało się
  tego odtworzyć (dźwignia między N a 2 dawała 2), ale w logu z jazdy 2026-10-13 wartość 14
  wystąpiła. Apka od v1.11.2 ignoruje wszystko spoza 0–6 i trzyma ostatni pełny bieg.
- **Telefon zawyżał przechył.** W tej samej jeździe telefon pokazywał ok. 1,25× tego, co
  wynika z fizyki (i 1,36× tego, co czujnik motocykla). Rekordy przechyłu z czasów sprzed
  mostka są więc zawyżone mniej więcej o jedną czwartą.
- **Zimny start** (2026-10-13): płyn 13 °C, powietrze 14 °C, prognoza 12 °C — oba wzory
  temperatur zgadzają się też na dole skali. W korku płyn doszedł do 106 °C.
- **Każdy tryb jazdy pamięta własną trakcję.** Ramka `335` trzyma je naraz: jeden odczyt
  `24 61 74 40` przy A = 1, B = 7, C = 4 sugeruje bajt 1 dolna połówka = A, bajt 2 górna = B,
  bajt 2 dolna = C. Pola A i C nie były zmieniane, więc to tylko zgodność jednego odczytu.
- Te same nastawy są powielone: `339` i `33D` = `335`; `351` = `1AD`; tryb obciążenia także
  w `32D` bajt 3 dolna połówka; korekty tłumienia także w `32D` bajty 1–3.

## Kody błędów i kontrolki (odkryte 2026-10-25)

Po chwilowym zwarciu linii CAN przy złączu diagnostycznym zapaliły się FI i trójkąt
(log `canlogs/can_20261025_170920.csv`, porównanie z 11 jazdami z 10–17.10):

| ID | co | jak odczytać |
|----|----|----|
| `441` | **lista zapisanych kodów błędów** (9 Hz) | b3 = liczba kodów, b4 = numer pozycji 1…n (krąży), b1b2 = kod w formacie SAE J2012: bity 7–6 b1 = litera (00 P, 01 C, 10 B, 11 U), bity 5–4 = pierwsza cyfra, młodsza połówka b1 i cały b2 = reszta. Bez błędów: same zera. |
| `341` | kontrolki ostrzegawcze | b4 bit 0x08 i b6 bit 0x20 — zawsze 0 we wszystkich wcześniejszych jazdach, przy świecącym FI + trójkącie stale 1 (który bit to która lampka — nieustalone) |

Kody z 2026-10-25 (5 pozycji): U0155 (utrata komunikacji z zegarami), U0123 (z modułem
czujnika obrotu/IMU), U0132 (ze sterownikiem zawieszenia — stąd E-SUS), U0073 (szyna CAN
„bus off”), P1640 (kod producenta, znaczenie u Suzuki nieznane). Wszystkie poza P1640 to
błędy komunikacji — zgodne ze zwarciem; w tym samym logu są wszystkie ramki z normalną
częstością, więc to kody zapisane, nie bieżąca usterka. Interpretacja `441` jako listy
kodów to wniosek z budowy ramki (licznik pozycji, liczba = 5, sensowne kody U), nie
z dokumentacji Suzuki.

## Kandydaci (do potwierdzenia w jeździe)

| Sygnał | ID | Gdzie | Co wiadomo |
|---|---|---|---|
| Otwarcie przepustnicy | `1A1` | bajty 4–5, górne 10 bitów | 18 zamknięta, ok. 40 na biegu jałowym przy puszczonej manetce, 327 przy pełnym gazie |
| Żądany moment | `1A9` | bajty 2–3 (środek 32768) | rośnie z manetką także przy zgaszonym silniku |
| Dawka paliwa | `221` | bajty 2–3 | zero przy zgaszonym silniku; ≈ obr/2 na ciepłym, do 0,9 × obr na zimnym. **To nie są obroty.** |
| Nastawa tłumienia | `17D` | bajt 4 | H 13, M 8–10, S 4–5; +20 na stopień obciążenia; spada przy dociążeniu |
| Zmiana nastawy tłumienia | `17E` | bajty 0–1 (spoczynek 32766) | wychyla się w górę przy utwardzaniu, w dół przy zmiękczaniu |
| Prądy zaworów tłumienia | `17E` | bajty 2–3 i 4–5 | 0 na postoju, ok. 400–430, gdy którekolwiek koło się kręci |
| Coś z przedniego koła | `1A9` | bajty 4–5 | rośnie tylko z przednim kołem, inna skala niż prędkość |
| Żyroskop | `180` (100 Hz), `175` (200 Hz) | trzy słowa, środek 32768 | osie i skala nieznane |
| Przyspieszenia, surowe 200 Hz | `179` | trzy słowa, środek 32768 | to samo co `181`, bez filtra |
| Pochylenie przód–tył? | `1A5` | bajty 2–3 | na postoju równo 32768; sprawdzić przy hamowaniu i przyspieszaniu |
| Prędkość zadana tempomatu | `341` | reszta ramki | na postoju zera |
| Przyciski zmiany trybu | `1D1` | bajt 4 | impulsy `80→40` i `08→04` przy naciśnięciu |
| Stan menu wyświetlacza | `1D1`, `321` | bajty 0–1 | zmienia się przy wejściu w wybór trybu |

Niewyjaśnione: `1A5` bajt 5 bit `0x08` (zapalił się na 6 s tuż przed odpaleniem;
kandydaci: wyłącznik silnika, boczna nóżka), `231` bajty 0–1 (`00 BD`, stałe od czerwca),
`235`, `3B1` (stałe), `431` (w czerwcu zera, teraz `00 C1 23 01 01`), `1AD` bajt 3 dolna
połówka i bajt 4, `32D` bajty 4–5 (inne niż w czerwcu), `19D` bajty 4–5 (zera).

## Łącze Bluetooth na motocyklu

Na biurku nie ginął żaden pakiet, na motocyklu 18–41% strumienia surowego: iPhone dzieli
radio między Bluetooth a WiFi do wyświetlacza i odbiera wolniej. Kolejka w płytce (kilkanaście
buforów) zapełniała się, pakiety docierały spóźnione, a nadmiar przepadał — stąd wrażenie
„czasem duże opóźnienie, czasem żadne". Program płytki od wersji 7 nadaje 30 pakietów
telemetrii na sekundę i 5 zrzutów surowych, a gdy wolnych buforów ubywa, wstrzymuje najpierw
strumień surowy, potem telemetrię (pakiet wysłany później jest świeższy niż odstany w kolejce).
Apka mierzy skutek: wiersz „Łącze" w karcie mostka oraz dziennik `canlogs/link_*.csv`
(T = Bluetooth z płytką, F = wysyłka klatek na wyświetlacz).

## Do sprawdzenia (lista życzeń)

| Co | Jak sprawdzić |
|---|---|
| Dzień / noc (czujnik światła wyświetlacza) | Zasłonić czujnik światła na liczniku na ok. 10 s, aż ekran przejdzie w tryb nocny, i odsłonić. Jeśli żaden bajt się nie zmieni, to wyświetlacz trzyma tę informację u siebie. Gdyby była na szynie, apka mogłaby sama przełączać motyw deski. |
| Poziom paliwa | Nagranie przed i po tankowaniu, z liczbą kresek przed i po. |
| `1A5` bajt 5 bit `0x08` | Osobno: czerwony wyłącznik silnika off/on, boczna nóżka złożona/rozłożona. |
| Prędkość zadana tempomatu | W jeździe 2026-10-13 włącznik był załączony przez większość czasu, a reszta ramki `341` stała (poza bajtem 5, dwie wartości). Trzeba jazdy z tempomatem faktycznie trzymającym zapamiętaną prędkość. |

## Czego na tej szynie nie ma

Sprawdzone testem, w którym użytkownik wykonał czynność, a żaden bajt się nie zmienił:

- kierunkowskazy, światła długie, awaryjne,
- hamulce przedni i tylny — także w ruchu: w jeździe 2026-10-13 mocne hamowanie (52 s poniżej −0,25 g wg prędkości koła) różniło się od równej jazdy tylko zamkniętym gazem i ujemnym żądaniem momentu, dokładnie tak samo jak hamowanie silnikiem,
- napięcie akumulatora (sprawdzone dwa razy: 06.2026 i 10.2026),
- tripy, średnie spalanie, średnia prędkość, czas jazdy (wyświetlacz liczy je sam),
- poziom paliwa — nie znaleziony z jednego odczytu (3/4 baku); rozstrzygnie porównanie
  nagrań sprzed i po tankowaniu.

## Co z tego trafia do apki

Płytka (program od wersji 4) wysyła 20 razy na sekundę pakiet 48 bajtów: pierwsze 18
jak dotąd (obroty, gaz, bieg, przechył, przyspieszenia), dalej surowe bajty ramek
`1A5`, `1A1`, `19D`, `221`, `17D`, `231`, `331`, `335`, `1AD`, `32D`, `341`. Układ pakietu
jest opisany na początku `firmware/can-ble-bridge/src/main.cpp`, a przeliczenia robi
apka w `BikeTelemetry.parse` (`MySpin/BikeLinkManager.swift`) — zmiana skali nie wymaga
więc wgrywania płytki. Wspólny wektor testowy: `tools/can/fw_core_test.cpp` i
`MySpin/FeatureSelfTest.swift` (`teleExt`).

Na desce (od apki v1.12.0): tryb jazdy z trakcją, płyn chłodzący, pasek gazu, powietrze
w nagłówku, słupki ugięcia zawieszenia, przechył bez obcinania. Prędkość z przedniego
koła zastępuje GPS dopiero, gdy apka sama potwierdzi przelicznik GPS-em
(`WheelSpeedCalibration`).

## Jak dopisać nowy sygnał

1. Nagranie: płytka na USB, `make can-cap NAME=opis SEC=30` (każda ramka, zapis w `canlogs/stol/`),
   albo jazda z apką (zapisuje sama) i `make canlogs`.
2. Szukanie: `canlog.py diff A B` dla dwóch stanów, `canlog.py find LOG` dla sygnałów ciągłych.
3. Wpis do `KNOWN` w `canlog.py`, wiersz w tej tabeli, wycinek i sprawdzenie w
   `verify_decode.py` (`--rebuild` odtwarza wycinki z pełnych nagrań).
