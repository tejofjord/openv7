# OpenV7 — Numark V7 userspace driver (Apple-Silicon macOS)
BIN      := openv7
SRC      := src/main.c src/nonap.m
PREFIX   ?= /usr/local

CC       ?= clang
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
CFLAGS   += $(shell pkg-config --cflags libusb-1.0)
# CoreMIDI's MIDIPacketList API is deprecated on recent macOS but still works;
# silence the warnings for v1.
CFLAGS   += -Wno-deprecated-declarations
LDFLAGS  += $(shell pkg-config --libs libusb-1.0)
LDFLAGS  += -framework CoreMIDI -framework CoreFoundation -framework Foundation

.PHONY: all clean install uninstall app test
all: $(BIN)

$(BIN): $(SRC) src/ploytec.h
	$(CC) $(CFLAGS) $(SRC) -o $(BIN) $(LDFLAGS)

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
