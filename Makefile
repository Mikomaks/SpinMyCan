# Makefile — MySpin iOS
# Użycie:
#   make          → build + install + uruchom (fizyczny telefon)
#   make build    → tylko build (telefon)
#   make install  → odnów podpis (7 dni) + build + install (telefon)
#   make launch   → uruchom zainstalowaną aplikację (telefon)
#   make devices  → pokaż widziane urządzenia
#   make sim      → build + install + uruchom na Simulatorze iPhone 17
#   make log      → pokaż logi aplikacji (Console)
#   make canlogs  → ściągnij z telefonu logi magistrali CAN do ./canlogs
#   make cancheck → sprawdź najnowszy log (przechył w jeździe, prędkość, nowe sygnały)
#   make can-test → testy bez sprzętu: rdzeń programu płytki na prawdziwych nagraniach + narzędzia
#   make can-cap NAME=hamulec [SEC=8] → nagraj ramki z płytki przez USB do ./canlogs/stol/hamulec.log
#   make fw-flash  → wgraj program płytki kablem USB (pierwszy raz i ratunkowo)
#   make fw-bundle → zbuduj i podpisz program płytki, dołącz go do apki; po `make install`
#                    apka sama zaproponuje aktualizację płytki przez Bluetooth
#   make fw-key    → klucz do podpisu (raz; plik poza repozytorium, płytka poznaje go przy fw-flash)
#   make fw-flash → skompiluj i wgraj program płytki CAN (płytka na USB)
#   make fw-monitor → podgląd tego, co płytka wypisuje na USB
#   make clean    → usuń DerivedData
#
# WERYFIKACJA WYNIKU (ważne):
#   `xcrun devicectl` zwraca kod wyjścia 0 NAWET GDY SIĘ WYWALI (np. telefon
#   odpięty) — dlatego sukces sprawdzamy po markerze w wyjściu ("App installed",
#   "Launched application"), a nie po $?. Podobnie xcodebuild: status z pipeline
#   `cmd | grep | sed` to status OSTATNIEGO ogniwa, więc build czytamy z pliku
#   logu + markera "BUILD SUCCEEDED", nie z $? po potoku.

SHELL := /bin/bash

# Osobiste ustawienia (NIE w repozytorium — local.mk jest w .gitignore), np.:
#   DEVICE_UDID      = 00000000-0000-0000-0000-000000000000
#   DEVELOPMENT_TEAM = ABCDE12345
-include local.mk

SCHEME        = MySpin
BUNDLE_ID     = wassup.MySpin
# UDID telefonu: xcrun devicectl list devices (albo w local.mk, albo: make install DEVICE_UDID=...)
DEVICE_UDID  ?= TWOJ-UDID-TELEFONU
# Zespół podpisu Apple (Xcode ▸ Settings ▸ Accounts) — w local.mk; pusty = ten z projektu Xcode
DEVELOPMENT_TEAM ?=
# Uwaga: budujemy do /tmp żeby ominąć iCloud Drive xattr pollution (com.apple.FinderInfo)
# która psuje codesign gdy projekt jest na Desktop synchronizowanym przez iCloud.
DERIVED_DATA  = /tmp/SpinMyCan_build
BUILD_LOG     = /tmp/SpinMyCan_build.log
# Projekt leży na Pulpicie synchronizowanym z iCloud. Gdy iCloud (fileproviderd) mieli,
# trzyma blokadę na MySpin.xcodeproj i xcodebuild czeka bez końca, nic nie pisząc.
# Dlatego budujemy z kopii poza iCloud (rsync kopiuje tylko zmienione pliki, sekundy).
SRC_COPY      = /tmp/SpinMyCan_src
SYNC_SRC      = mkdir -p $(SRC_COPY) && rsync -a --delete --exclude .git --exclude canlogs \
                  --exclude build --exclude firmware --exclude web --exclude video ./ $(SRC_COPY)/
SIM_LOG       = /tmp/SpinMyCan_sim.log

# Kolory
GREEN  = \033[0;32m
YELLOW = \033[0;33m
RED    = \033[0;31m
RESET  = \033[0m

SIM_NAME      = iPhone 17
SIM_DERIVED   = /tmp/SpinMyCan_sim

# Klatki dla ekranu „Wideo TT” (reguła niżej, przy `video`)
VIDEO_SRC = video/isle_of_man_tt.mp4
VIDEO_OUT = MySpin/video_tt.mjpg
# Film wbudowany jest opcjonalny (nie ma go w repozytorium): bez pliku źródłowego build go pomija.
VIDEO_DEP = $(if $(wildcard $(VIDEO_SRC)),$(VIDEO_OUT),)

.PHONY: all build install clean-old-builds launch refresh expiry clear-profiles restore-profiles devices sim sim-build sim-launch log clean canlogs cancheck can-test can-cap can-panel video fw-build fw-key fw-bundle fw-flash fw-monitor

# ── Domyślny cel: build → install → launch ──────────────────────────────────
all: install launch

# ── Build ────────────────────────────────────────────────────────────────────
# Flagi:
#   ENABLE_ON_DEMAND_RESOURCES=NO           → wyłącza ODR (fix: actool simulator runtime check)
#   ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT=YES → pomija warianty App Store
#   ONLY_ACTIVE_ARCH=YES                    → tylko arm64
build: $(VIDEO_DEP)
	@echo -e "$(YELLOW)▶ Building $(SCHEME) → $(DERIVED_DATA) (z kopii $(SRC_COPY))$(RESET)"
	@$(SYNC_SRC)
	@xcodebuild \
		-project $(SRC_COPY)/$(SCHEME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Debug \
		-sdk iphoneos \
		-derivedDataPath $(DERIVED_DATA) \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates \
		$(if $(DEVELOPMENT_TEAM),DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM),) \
		ENABLE_ON_DEMAND_RESOURCES=NO \
		ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT=YES \
		ONLY_ACTIVE_ARCH=YES \
		SUPPORTED_PLATFORMS=iphoneos \
		build > $(BUILD_LOG) 2>&1; \
	STATUS=$$?; \
	grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" $(BUILD_LOG) \
		| grep -v "actool\|appintents\|note:\|DVTCoreSimulator" \
		| sed 's/error:/$(RED)error:$(RESET)/g' | head -40; \
	if [ $$STATUS -ne 0 ] || ! grep -q "BUILD SUCCEEDED" $(BUILD_LOG); then \
		echo -e "$(RED)❌ Build FAILED (xcodebuild status=$$STATUS)$(RESET)"; \
		if grep -qE "No Accounts|missing Xcode-Token|Invalid credentials" $(BUILD_LOG); then \
			echo -e "$(RED)   PRZYCZYNA: Xcode nie jest zalogowany do konta Apple.$(RESET)"; \
			echo -e "$(YELLOW)   → Otwórz Xcode ▸ Settings ▸ Accounts i zaloguj się ponownie (wymaga Twojego hasła).$(RESET)"; \
		fi; \
		echo -e "$(RED)   ostatnie linie logu:$(RESET)"; \
		tail -15 $(BUILD_LOG) | sed 's/^/   /'; \
		echo -e "$(RED)   pełny log: $(BUILD_LOG)$(RESET)"; \
		$(MAKE) --no-print-directory restore-profiles; \
		exit 1; \
	fi; \
	APP=$$(find $(DERIVED_DATA) -name "$(SCHEME).app" -not -path "*/PlugIns/*" 2>/dev/null | head -1); \
	if [ -z "$$APP" ]; then \
		echo -e "$(RED)❌ Build zgłosił sukces, ale nie ma .app — coś jest nie tak$(RESET)"; exit 1; \
	fi; \
	VER=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$$APP/Info.plist" 2>/dev/null); \
	echo -e "$(GREEN)✅ Build OK — v$$VER — $$APP$(RESET)"

# ── Install ──────────────────────────────────────────────────────────────────
# devicectl kłamie kodem wyjścia (0 mimo błędu) → sukces potwierdzamy markerem.
# UWAGA: `install` ZAWSZE kasuje cache profili (patrz clear-profiles), żeby jedna
# komenda dawała pełne 7 dni. Szybka ścieżka bez odnawiania: make install SKIP_REFRESH=1
install: clear-profiles build
	@APP=$$(find $(DERIVED_DATA) -name "$(SCHEME).app" -not -path "*/PlugIns/*" 2>/dev/null | head -1); \
	if [ -z "$$APP" ]; then echo -e "$(RED)❌ .app nie znaleziony$(RESET)"; exit 1; fi; \
	VER=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$$APP/Info.plist" 2>/dev/null); \
	echo -e "$(YELLOW)▶ Instaluję v$$VER na $(DEVICE_UDID)...$(RESET)"; \
	OUT=$$(xcrun devicectl device install app --device $(DEVICE_UDID) "$$APP" 2>&1); \
	if echo "$$OUT" | grep -q "App installed"; then \
		echo "$$OUT" | grep -E "bundleID|installationURL" | sed 's/^/   /'; \
		echo -e "$(GREEN)✅ Zainstalowano v$$VER$(RESET)"; \
	else \
		echo -e "$(RED)❌ INSTALACJA NIEUDANA — aplikacja NIE została wgrana$(RESET)"; \
		echo "$$OUT" | grep -iE "error|unable|failed" | head -5 | sed 's/^/   /'; \
		echo -e "$(YELLOW)   Sprawdź: kabel podpięty? telefon odblokowany? komputer zaufany?$(RESET)"; \
		echo -e "$(YELLOW)   Podłączone urządzenia:  make devices$(RESET)"; \
		exit 1; \
	fi
	@$(MAKE) --no-print-directory expiry
	@$(MAKE) --no-print-directory clean-old-builds

# ── Sprzątanie po udanej instalacji ─────────────────────────────────────────
# Stare buildy MySpin z Xcode (DerivedData; nasze buildy są w $(DERIVED_DATA) i zostają,
# żeby kolejne szły szybko) oraz pliki systemu iPhone'a (iOS DeviceSupport, ~5–6 GB na
# wersję iOS) — WSZYSTKIE: do instalacji nie są potrzebne (devicectl wgrywa bez nich),
# służą tylko do debugowania w Xcode, a Xcode ściąga je od nowa przy podpięciu kablem.
clean-old-builds:
	@BEFORE=$$(df -k / | awk 'NR==2 {print $$4}'); \
	rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/$(SCHEME)-*; \
	rm -rf "$(HOME)/Library/Developer/Xcode/iOS DeviceSupport/"*; \
	AFTER=$$(df -k / | awk 'NR==2 {print $$4}'); \
	echo -e "$(GREEN)🧹 Stare buildy usunięte (zwolnione ok. $$(( (AFTER - BEFORE) / 1024 )) MB, wolne $$(( AFTER / 1048576 )) GB)$(RESET)"

# ── Launch ───────────────────────────────────────────────────────────────────
launch:
	@echo -e "$(YELLOW)▶ Uruchamiam $(BUNDLE_ID)...$(RESET)"
	@OUT=$$(xcrun devicectl device process launch --device $(DEVICE_UDID) --terminate-existing $(BUNDLE_ID) 2>&1); \
	if echo "$$OUT" | grep -q "Launched application"; then \
		echo -e "$(GREEN)✅ Aplikacja uruchomiona$(RESET)"; \
	else \
		echo -e "$(RED)❌ URUCHOMIENIE NIEUDANE$(RESET)"; \
		echo "$$OUT" | grep -iE "error|unable|failed" | head -5 | sed 's/^/   /'; \
		exit 1; \
	fi

# ── Odświeżenie podpisu (PEŁNE 7 dni) ────────────────────────────────────────
# Darmowe konto Apple = profil ważny 7 DNI. xcodebuild REUŻYWA profil z cache
# dopóki ten jest ważny — więc sam build w 6. dniu dawałby tylko 1 dzień życia,
# nie 7 (to dlatego apka padała w trasie mimo świeżego builda).
# Dlatego `install` kasuje cache ZAWSZE → Apple wystawia nowy profil na 7 dni.
# Wymaga sieci i zalogowanego konta w Xcode. Szybka ścieżka bez odnawiania:
#   make install SKIP_REFRESH=1
PROF_DIR  = $(HOME)/Library/Developer/Xcode/UserData/Provisioning Profiles
PROF_BAK  = /tmp/SpinMyCan_profiles_backup
clear-profiles:
	@if [ -z "$(SKIP_REFRESH)" ]; then \
		echo -e "$(YELLOW)▶ Odnawiam podpis (kasuję cache profili → pełne 7 dni)...$(RESET)"; \
		rm -rf "$(PROF_BAK)"; mkdir -p "$(PROF_BAK)"; \
		cp "$(PROF_DIR)"/*.mobileprovision "$(PROF_BAK)"/ 2>/dev/null || true; \
		rm -f "$(PROF_DIR)"/*.mobileprovision 2>/dev/null || true; \
	else \
		echo -e "$(YELLOW)▶ SKIP_REFRESH=1 — używam istniejącego podpisu$(RESET)"; \
	fi

# Przywraca profile skasowane przez clear-profiles. Wołane gdy build padnie —
# bez tego zerwana sesja Apple w Xcode zostawiała cię BEZ ŻADNEGO profilu
# (kasujemy stary, a nowego nie da się pobrać bez zalogowania).
restore-profiles:
	@if [ -d "$(PROF_BAK)" ] && [ -n "$$(ls -A "$(PROF_BAK)" 2>/dev/null)" ]; then \
		cp "$(PROF_BAK)"/*.mobileprovision "$(PROF_DIR)"/ 2>/dev/null || true; \
		echo -e "$(YELLOW)   ↩︎ przywrócono poprzednie profile z kopii$(RESET)"; \
	fi

# Alias — `install` i tak odnawia, zostawiony dla pamięci mięśniowej.
refresh: install

# ── Ile dni zostało do wygaśnięcia podpisu ───────────────────────────────────
expiry:
	@APP=$$(find $(DERIVED_DATA) -name "$(SCHEME).app" -not -path "*/PlugIns/*" 2>/dev/null | head -1); \
	if [ -z "$$APP" ] || [ ! -f "$$APP/embedded.mobileprovision" ]; then \
		echo -e "$(YELLOW)   Brak zbudowanej apki — uruchom: make build$(RESET)"; exit 0; fi; \
	security cms -D -i "$$APP/embedded.mobileprovision" > /tmp/myspin_prof.plist 2>/dev/null; \
	EXP=$$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" /tmp/myspin_prof.plist 2>/dev/null); \
	EXP_TS=$$(date -j -f "%a %b %d %H:%M:%S %Z %Y" "$$EXP" +%s 2>/dev/null); \
	NOW_TS=$$(date +%s); \
	DAYS=$$(( ($$EXP_TS - $$NOW_TS) / 86400 )); \
	if [ $$DAYS -lt 0 ]; then \
		echo -e "$(RED)⏳ Podpis WYGASŁ ($$EXP) — apka nie odpali się. Zrób: make refresh$(RESET)"; \
	elif [ $$DAYS -le 2 ]; then \
		echo -e "$(RED)⏳ Podpis wygasa za $$DAYS dni ($$EXP) — przed wyjazdem zrób: make refresh$(RESET)"; \
	else \
		echo -e "$(GREEN)⏳ Podpis ważny jeszcze $$DAYS dni (do $$EXP)$(RESET)"; \
	fi

# ── Urządzenia (diagnostyka gdy install nie działa) ──────────────────────────
devices:
	@echo -e "$(YELLOW)▶ Urządzenia widziane przez devicectl:$(RESET)"
	@xcrun devicectl list devices 2>&1 | sed 's/^/   /'
	@echo -e "$(YELLOW)   Uwaga: „available (paired)\" = sparowane kiedyś, NIE znaczy podłączone teraz.$(RESET)"

# ── Log (Console — live logi z aplikacji) ────────────────────────────────────
log:
	@echo -e "$(YELLOW)▶ Logi z aplikacji (Ctrl+C żeby zatrzymać)...$(RESET)"
	@idevicesyslog -u $(DEVICE_UDID) 2>/dev/null \
		|| xcrun devicectl device syslog \
			--device $(DEVICE_UDID) \
		|| echo -e "$(RED)Zainstaluj libimobiledevice: brew install libimobiledevice$(RESET)"

# ── Simulator: build → install → launch ─────────────────────────────────────
# Szybszy niż device: brak codesign provisioning, brak kabla.
# Przydatny do pracy nad UI — razem z Xcode Canvas (#Preview w FrameRenderer.swift).
sim: sim-build sim-launch

sim-build: $(VIDEO_DEP)
	@echo -e "$(YELLOW)▶ Building for Simulator ($(SIM_NAME))...$(RESET)"
	@$(SYNC_SRC)
	@xcodebuild \
		-project $(SRC_COPY)/$(SCHEME).xcodeproj \
		-scheme $(SCHEME) \
		-configuration Debug \
		-sdk iphonesimulator \
		-derivedDataPath $(SIM_DERIVED) \
		-destination 'platform=iOS Simulator,name=$(SIM_NAME)' \
		ENABLE_ON_DEMAND_RESOURCES=NO \
		ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT=YES \
		ONLY_ACTIVE_ARCH=YES \
		build > $(SIM_LOG) 2>&1; \
	STATUS=$$?; \
	grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" $(SIM_LOG) \
		| grep -v "actool\|appintents\|note:" \
		| sed 's/error:/$(RED)error:$(RESET)/g' | head -40; \
	if [ $$STATUS -ne 0 ] || ! grep -q "BUILD SUCCEEDED" $(SIM_LOG); then \
		echo -e "$(RED)❌ Sim build FAILED (status=$$STATUS)$(RESET)"; \
		tail -15 $(SIM_LOG) | sed 's/^/   /'; \
		echo -e "$(RED)   pełny log: $(SIM_LOG)$(RESET)"; \
		exit 1; \
	fi; \
	APP=$$(find $(SIM_DERIVED) -name "$(SCHEME).app" -not -path "*/PlugIns/*" 2>/dev/null | head -1); \
	if [ -z "$$APP" ]; then echo -e "$(RED)❌ Sim build: brak .app$(RESET)"; exit 1; fi; \
	echo -e "$(GREEN)✅ Sim build OK — $$APP$(RESET)"

sim-launch:
	@echo -e "$(YELLOW)▶ Uruchamiam Simulator + instaluję...$(RESET)"
	@open -a Simulator 2>/dev/null; sleep 1
	@UDID=$$(xcrun simctl list devices available | grep "$(SIM_NAME)" | head -1 \
		| grep -o '[A-F0-9-]\{36\}'); \
	APP=$$(find $(SIM_DERIVED) -name "$(SCHEME).app" -not -path "*/PlugIns/*" 2>/dev/null | head -1); \
	if [ -z "$$UDID" ]; then echo -e "$(RED)❌ Nie znalazłem symulatora „$(SIM_NAME)\"$(RESET)"; exit 1; fi; \
	if [ -z "$$APP" ]; then echo -e "$(RED)❌ Brak .app — uruchom najpierw: make sim-build$(RESET)"; exit 1; fi; \
	echo "   Simulator UDID: $$UDID"; \
	xcrun simctl boot "$$UDID" 2>/dev/null || true; \
	xcrun simctl install "$$UDID" "$$APP" || { echo -e "$(RED)❌ simctl install nieudany$(RESET)"; exit 1; }; \
	xcrun simctl launch "$$UDID" $(BUNDLE_ID) || { echo -e "$(RED)❌ simctl launch nieudany$(RESET)"; exit 1; }; \
	echo -e "$(GREEN)✅ Aplikacja uruchomiona na Simulatorze$(RESET)"

# ── Clean ────────────────────────────────────────────────────────────────────
clean:
	@echo -e "$(YELLOW)▶ Czyszczę $(DERIVED_DATA)/...$(RESET)"
	@rm -rf $(DERIVED_DATA)
	@echo -e "$(GREEN)✅ Wyczyszczone$(RESET)"

# ── Mostek CAN: logi z telefonu i program płytki ────────────────────────────
CANLOG_DIR = canlogs
FW_DIR     = firmware/can-ble-bridge
# canlog.py potrzebuje numpy — systemowy python go ma, ten z Homebrew nie.
CAN_PY     = /usr/bin/python3 tools/can/canlog.py

canlogs:
	@mkdir -p $(CANLOG_DIR)
	@echo -e "$(YELLOW)▶ Kopiuję Documents/canlogs z telefonu → $(CANLOG_DIR)/$(RESET)"
	@xcrun devicectl device copy from --device $(DEVICE_UDID) \
		--domain-type appDataContainer --domain-identifier $(BUNDLE_ID) \
		--source Documents/canlogs --destination $(CANLOG_DIR) > /tmp/SpinMyCan_canlogs.log 2>&1; \
	N=$$(find $(CANLOG_DIR) -maxdepth 2 -name "can_*.csv" | wc -l | tr -d ' '); \
	if [ "$$N" = "0" ]; then \
		echo -e "$(RED)❌ Brak logów (telefon odpięty albo nic nie nagrano) — /tmp/SpinMyCan_canlogs.log$(RESET)"; exit 1; \
	fi; \
	echo -e "$(GREEN)✅ Logów: $$N$(RESET)"; find $(CANLOG_DIR) -maxdepth 2 -name "can_*.csv" -exec ls -lh {} +

cancheck:
	@F=$$(find $(CANLOG_DIR) -maxdepth 2 -name "can_*.csv" 2>/dev/null | sort | tail -1); \
	if [ -z "$$F" ]; then echo -e "$(RED)❌ Brak logów — najpierw: make canlogs$(RESET)"; exit 1; fi; \
	echo -e "$(YELLOW)▶ $$F$(RESET)"; \
	$(CAN_PY) profile "$$F"; echo; $(CAN_PY) check "$$F"; echo; $(CAN_PY) find "$$F"

# Nagranie przez USB (płytka wpięta kablem do komputera): każda ramka z szyny przez SEC sekund.
# Porównanie dwóch stanów: $(CAN_PY) diff canlogs/stol/baza.log canlogs/stol/hamulec.log
SEC ?= 8
can-cap:
	@if [ -z "$(NAME)" ]; then echo -e "$(RED)❌ Podaj nazwę: make can-cap NAME=baza$(RESET)"; exit 1; fi
	@/usr/bin/python3 tools/can/sercap.py --seconds $(SEC) --out $(CANLOG_DIR)/stol/$(NAME).log

# Panel w przeglądarce: ramki na żywo z płytki (USB) albo z nagrania, bity, przebiegi, tłumaczenie.
# `make can-panel` otwiera http://127.0.0.1:8765; z nagraniem: make can-panel REPLAY=canlogs/stol/kolo_przod.log
can-panel:
	@/usr/bin/python3 tools/can/panel.py $(if $(REPLAY),--replay $(REPLAY))

# Ekran „Wideo TT”: film → gotowe klatki 864×320 dla wyświetlacza (apka ich nie dekoduje,
# więc grają też przy zablokowanym telefonie). Plik wynikowy nie jest w gicie — robi się
# sam przed buildem, gdy go brak albo film się zmienił. Wymaga ffmpeg (brew install ffmpeg).
$(VIDEO_OUT): $(VIDEO_SRC) tools/video_frames.py
	@echo -e "$(YELLOW)▶ Klatki wideo dla wyświetlacza (ffmpeg, ok. minuty)...$(RESET)"
	@/usr/bin/python3 tools/video_frames.py $(VIDEO_SRC) $(VIDEO_OUT)
video: $(VIDEO_OUT)

# Rdzeń programu płytki skompilowany na komputerze (z nagraniami z canlogs/pi-2026-06-25,
# jeśli są) oraz test narzędzi analizy na sztucznej jeździe.
can-test:
	@clang++ -std=c++17 -Wall -Wextra -Wno-deprecated-declarations -I $(FW_DIR)/src tools/can/fw_core_test.cpp -o /tmp/fw_core_test \
		&& /tmp/fw_core_test | grep -E "FAIL|WYNIK|pomijam|brak katalogu"
	@/usr/bin/python3 tools/can/selftest.py | grep -E "FAIL|WYNIK"
	@/usr/bin/python3 tools/can/verify_decode.py | grep -E "FAIL|WYNIK|brak wycinków"

fw-build:
	@cd $(FW_DIR) && pio run -e waveshare-s3-can

# Aktualizacja płytki przez Bluetooth: klucz (raz) i podpisany program dołączany do apki.
# Po `fw-bundle` trzeba zbudować i wgrać apkę — to ona niesie program do płytki.
fw-key:
	@/usr/bin/python3 tools/fw_bundle.py key

fw-bundle: fw-build
	@/usr/bin/python3 tools/fw_bundle.py sign $(FW_DIR)/.pio/build/waveshare-s3-can/firmware.bin MySpin

fw-flash:
	@PORT=$$(ls /dev/cu.usbmodem* 2>/dev/null | head -1); \
	if [ -z "$$PORT" ]; then echo -e "$(RED)❌ Płytka nie jest podłączona przez USB$(RESET)"; exit 1; fi; \
	cd $(FW_DIR) && pio run -e waveshare-s3-can -t upload --upload-port $$PORT

fw-monitor:
	@PORT=$$(ls /dev/cu.usbmodem* 2>/dev/null | head -1); \
	if [ -z "$$PORT" ]; then echo -e "$(RED)❌ Płytka nie jest podłączona przez USB$(RESET)"; exit 1; fi; \
	echo "('r' + Enter przełącza zrzut surowych ramek, Ctrl+C kończy)"; \
	cd $(FW_DIR) && pio device monitor --port $$PORT --baud 115200
