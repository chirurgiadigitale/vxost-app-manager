# XAMPP — build senza Xcode, solo Command Line Tools.
#
#   make          compila e crea build/XAMPP.app
#   make icon     rigenera Resources/AppIcon.icns dal logo ufficiale
#   make run      compila e avvia
#   make install  copia l'app in /Applications/XAMPP/
#   make clean    rimuove build/

APP_NAME  := XAMPP
BUNDLE    := build/$(APP_NAME).app
CONTENTS  := $(BUNDLE)/Contents
MACOS_DIR := $(CONTENTS)/MacOS
RES_DIR   := $(CONTENTS)/Resources

SOURCES := $(wildcard src/*.m)
LOGO    := Resources/xampp-logo.svg
ICON    := Resources/AppIcon.icns

# -fobjc-arc: gestione automatica della memoria
# -Wall -Wextra: nessun warning tollerato
CFLAGS  := -fobjc-arc -Wall -Wextra -Wno-unused-parameter -O2
LDFLAGS := -framework Cocoa

.PHONY: all icon run install clean uninstall

# La ricetta è su un target phony e non sul bundle: il percorso contiene una
# directory con estensione .app e make lo tratterebbe come file da datare.
all: $(ICON)
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	@clang $(CFLAGS) $(LDFLAGS) -o "$(MACOS_DIR)/$(APP_NAME)" $(SOURCES)
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp $(ICON) "$(RES_DIR)/AppIcon.icns"
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

run: all
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@open "$(BUNDLE)"

install: all
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@rm -rf "/Applications/XAMPP/$(APP_NAME).app"
	@cp -R "$(BUNDLE)" "/Applications/XAMPP/"
	@echo "Installata in /Applications/XAMPP/$(APP_NAME).app"

uninstall:
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@rm -rf "/Applications/XAMPP/$(APP_NAME).app"
	@echo "Rimossa da /Applications/XAMPP/"

clean:
	@rm -rf build
	@echo "Pulito."
