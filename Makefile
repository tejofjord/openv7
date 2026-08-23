# OpenV7 — Numark V7 userspace driver (Apple-Silicon macOS)
BIN      := openv7
SRC      := src/main.c src/nonap.m
PREFIX   ?= /usr/local

CC       ?= clang
CFLAGS   ?= -O2 -Wall -Wextra -std=c11

# Version stamps. A Mach-O records a floor (minos) and the SDK it was built
# against, and BOTH gate launch. With neither flag set, clang stamps the build
# host's SDK into both -- so a binary built on a macOS seed refuses to run
# anywhere but that seed. MACOS_MIN tracks LSMinimumSystemVersion in
# app/Info.plist; tools/pick-sdk.sh keeps the SDK off unreleased majors and is
# shared with dist/build-app.sh so the two build paths cannot drift.
MACOS_MIN ?= $(shell /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' app/Info.plist)
SDKROOT   ?= $(shell ./tools/pick-sdk.sh)

# Fail loudly on an empty value. An empty -isysroot does not error: it silently
# consumes the NEXT flag as its argument, so the build would lose its version
# stamp and look fine while producing exactly the binary this is here to prevent.
ifeq ($(strip $(SDKROOT)),)
$(error could not determine an SDK -- run ./tools/pick-sdk.sh to see why)
endif
ifeq ($(strip $(MACOS_MIN)),)
$(error could not read LSMinimumSystemVersion from app/Info.plist)
endif

CFLAGS   += -isysroot $(SDKROOT) -mmacosx-version-min=$(MACOS_MIN)
LDFLAGS  += -isysroot $(SDKROOT) -mmacosx-version-min=$(MACOS_MIN)
CFLAGS   += $(shell pkg-config --cflags libusb-1.0)
# CoreMIDI's MIDIPacketList API is deprecated on recent macOS but still works;
# silence the warnings for v1.
CFLAGS   += -Wno-deprecated-declarations
LDFLAGS  += $(shell pkg-config --libs libusb-1.0)
LDFLAGS  += -framework CoreMIDI -framework CoreFoundation -framework Foundation

.PHONY: all clean install uninstall app test

# Delete a target whose recipe failed. Without this, a binary rejected by the
# stamp check stays on disk newer than its sources, so the very next `make
# install` would consider it up to date and install the build we just refused.
.DELETE_ON_ERROR:

all: $(BIN)

$(BIN): $(SRC) src/ploytec.h
	$(CC) $(CFLAGS) $(SRC) -o $(BIN) $(LDFLAGS)
	@# Check the ARTIFACT, not the inputs. SDKROOT can arrive from the environment
	@# (xcrun exports one) or from a command-line `make SDKROOT=...`, which outranks
	@# anything assigned here -- so validating the variable is not enough.
	@./tools/check-stamps.sh $(BIN) $(MACOS_MIN)

build:
	mkdir -p build

# Build the self-contained menu-bar app (OpenV7.app) + drag-to-install DMG.
app:
	./dist/build-app.sh

# Unit tests. tests/midi_test.c includes src/main.c directly (main() renamed) so
# it can reach the static MIDI splitter.
test: | build
	$(CC) $(CFLAGS) tests/midi_test.c src/nonap.m -o build/midi_test $(LDFLAGS)
	./build/midi_test

clean:
	rm -f $(BIN)
	rm -rf build

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 0755 $(BIN) $(PREFIX)/bin/$(BIN)

uninstall:
	rm -f $(PREFIX)/bin/$(BIN)
