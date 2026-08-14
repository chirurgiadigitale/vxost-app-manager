# VXOST, build senza Xcode, solo Command Line Tools.
#
#   make          compila e crea build/VXOST.app
#   make icon     rigenera Resources/AppIcon.icns dal logo ufficiale
#   make run      compila e avvia
#   make wizardtest  prova il wizard senza aprire interfacce
#   make install  copia l'app in /Applications/VXOST/
#   make clean    rimuove build/

APP_NAME  := VXOST
BUNDLE    := build/$(APP_NAME).app
CONTENTS  := $(BUNDLE)/Contents
MACOS_DIR := $(CONTENTS)/MacOS
RES_DIR   := $(CONTENTS)/Resources

VERSION   := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DIST_DIR  := dist

SOURCES := $(wildcard src/*.m)
LOGO    := Resources/vxost-logo.svg
ICON    := Resources/AppIcon.icns

# -fobjc-arc: gestione automatica della memoria
# -Wall -Wextra: nessun warning tollerato
# Universal binary: Apple Silicon runs it natively, Intel Macs run it at all.
# Building for one architecture only would silently exclude every Mac made
# before 2020.
ARCHS   := -arch arm64 -arch x86_64
CFLAGS  := -fobjc-arc -Wall -Wextra -Wno-unused-parameter -O2 $(ARCHS)
# Security serve al portachiavi, dove sta la password di root di MySQL:
# tenerla in un file di configurazione dell'app la lascerebbe in chiaro.
LDFLAGS := -framework Cocoa -framework UniformTypeIdentifiers -framework Security

.PHONY: all icon strings run install clean uninstall dist wizardtest

# La ricetta è su un target phony e non sul bundle: il percorso contiene una
# directory con estensione .app e make lo tratterebbe come file da datare.
all: $(ICON) strings
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	@clang $(CFLAGS) $(LDFLAGS) -o "$(MACOS_DIR)/$(APP_NAME)" $(SOURCES)
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp $(ICON) "$(RES_DIR)/AppIcon.icns"
	@# Le traduzioni: senza le .lproj nel bundle l'app mostrerebbe le chiavi.
	@cp -R Resources/*.lproj "$(RES_DIR)/"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Firma ad-hoc: non serve un account sviluppatore, ma evita che macOS
	@# consideri il bundle danneggiato dopo una modifica.
	@codesign --force --deep --sign - "$(BUNDLE)" 2>/dev/null || true
	@# Il Finder tiene in cache le icone per percorso: senza questo tocco
	@# continuerebbe a mostrare quella vecchia dopo una rigenerazione.
	@touch "$(BUNDLE)"
	@echo "Creato: $(BUNDLE)"

# L'icona si rigenera solo se manca o se il logo è più recente.
$(ICON): $(LOGO) tools/make-icon.m
	@mkdir -p build
	@clang $(CFLAGS) $(LDFLAGS) -o build/make-icon tools/make-icon.m
	@./build/make-icon $(LOGO) build/AppIcon.iconset
	@iconutil -c icns build/AppIcon.iconset -o $(ICON)
	@echo "Icona rigenerata: $(ICON)"

icon:
	@rm -f $(ICON)
	@$(MAKE) --no-print-directory $(ICON)

# Rigenera i Localizable.strings delle 15 lingue dal catalogo unico.
# Fallisce se una lingua è incompleta o se un segnaposto non coincide.
#
# Va definito dopo `all`: in make il primo target del file è quello di
# default, e metterlo prima farebbe eseguire solo questo a `make` nudo.
strings:
	@python3 tools/i18n/build-strings.py

run: all
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@open "$(BUNDLE)"

# Prova il wizard senza aprire una sola finestra: nomi di database, versioni
# di PHP e lo script privilegiato, a cui si passa `sh -n` invece di eseguirlo.
#
# ⚠️ Non tocca httpd-vhosts.conf e non scrive niente su MySQL. E va lanciato
# senza sudo: come root leggerebbe un portachiavi diverso da quello
# dell'utente e direbbe che la password non c'è.
wizardtest:
	@mkdir -p build
	@clang $(CFLAGS) $(LDFLAGS) -Isrc -o build/wizardtest \
		tests/wizardtest.m $(filter-out src/main.m,$(SOURCES))
	@./build/wizardtest

# L'app va in /Applications, non dentro la cartella dello stack.
#
# Il manager originale stava in /Applications/XAMPP/, e chi non e' pratico non
# lo trovava: non compare in Launchpad, non lo suggerisce Spotlight, e in
# /Applications non c'e'. Messa al primo livello si comporta come qualsiasi
# altra applicazione. La cartella dello stack resta /Applications/VXOST/ e le
# due si distinguono a colpo d'occhio, una ha l'icona dell'app e l'altra
# quella di una cartella.
install: all
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@rm -rf "/Applications/$(APP_NAME).app" "/Applications/VXOST/$(APP_NAME).app"
	@cp -R "$(BUNDLE)" "/Applications/$(APP_NAME).app"
	@echo "Installata in /Applications/$(APP_NAME).app"

uninstall:
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@rm -rf "/Applications/$(APP_NAME).app" "/Applications/VXOST/$(APP_NAME).app"
	@echo "Rimossa da /Applications/"

# Pacchetti pronti da pubblicare: uno zip e un'immagine disco.
#
# L'app è firmata ad-hoc, non con un Developer ID Apple: su un altro Mac
# Gatekeeper la bloccherà al primo avvio e l'utente dovrà autorizzarla dalle
# Impostazioni di Sistema. È il prezzo di non avere l'abbonamento sviluppatore
# e va spiegato a chi scarica, non nascosto.
dist: all
	@rm -rf $(DIST_DIR) build/dmg
	@mkdir -p $(DIST_DIR) build/dmg
	@# ditto è il modo corretto di archiviare un bundle: zip normale
	@# perderebbe i metadati e invaliderebbe la firma.
	@ditto -c -k --sequesterRsrc --keepParent "$(BUNDLE)" "$(DIST_DIR)/$(APP_NAME)-$(VERSION).zip"
	@cp -R "$(BUNDLE)" build/dmg/
	@ln -s /Applications build/dmg/Applications
	@hdiutil create -volname "$(APP_NAME) $(VERSION)" -srcfolder build/dmg \
		-ov -format UDZO -quiet "$(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg"
	@rm -rf build/dmg
	@shasum -a 256 $(DIST_DIR)/* | sed 's|$(DIST_DIR)/||' > $(DIST_DIR)/SHA256SUMS.txt
	@echo "Pacchetti in $(DIST_DIR)/:"
	@ls -lh $(DIST_DIR) | tail -n +2 | awk '{printf "  %-28s %s\n", $$9, $$5}'

clean:
	@rm -rf build $(DIST_DIR)
	@echo "Pulito."
