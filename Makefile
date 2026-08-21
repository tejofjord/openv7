# OpenV7 — Numark V7 userspace driver (Apple-Silicon macOS)
BIN      := openv7
SRC      := src/main.c
PREFIX   ?= /usr/local

CC       ?= clang
CFLAGS   ?= -O2 -Wall -Wextra -std=c11
CFLAGS   += $(shell pkg-config --cflags libusb-1.0)
# CoreMIDI's MIDIPacketList API is deprecated on recent macOS but still works;
# silence the warnings for v1.
CFLAGS   += -Wno-deprecated-declarations
LDFLAGS  += $(shell pkg-config --libs libusb-1.0)
LDFLAGS  += -framework CoreMIDI -framework CoreFoundation

.PHONY: all clean install uninstall
all: $(BIN)

$(BIN): $(SRC) src/ploytec.h
	$(CC) $(CFLAGS) $(SRC) -o $(BIN) $(LDFLAGS)

clean:
	rm -f $(BIN)

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 0755 $(BIN) $(PREFIX)/bin/$(BIN)

uninstall:
	rm -f $(PREFIX)/bin/$(BIN)
