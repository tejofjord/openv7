#!/usr/bin/env bash
# OpenV7 -- build from source and install on this Mac, in one command.
#
#   ./install.sh                      build + install OpenV7.app (menu bar)
#   ./install.sh --audio-driver       ...and the "Numark V7" CoreAudio device,
#                                     so the deck's own RCA outputs play audio.
#                                     Asks for your password (it goes in
#                                     /Library/Audio/Plug-Ins/HAL).
#   ./install.sh --uninstall-audio-driver
#
# Everything it prints is also appended to build/install.log.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
LOG="$PWD/build/install.log"
exec > >(tee -a "$LOG") 2>&1
echo
echo "===== install.sh $(date '+%Y-%m-%d %H:%M:%S') $* ====="

step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\n!!  %s\n    (full log: build/install.log)\n' "$*"; exit 1; }

HAL_DIR=/Library/Audio/Plug-Ins/HAL
DRIVER=0
UNINSTALL_DRIVER=0
for a in "$@"; do
  case "$a" in
    --audio-driver)           DRIVER=1 ;;
    --uninstall-audio-driver) UNINSTALL_DRIVER=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $a (try --help)" ;;
  esac
done

restart_coreaudio() {
  # Every app's audio blips for a second while this happens.
  sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null \
    || sudo killall -9 coreaudiod
  sleep 3
}

driver_visible() {
  local devs
  devs="$(system_profiler SPAudioDataType 2>/dev/null || true)"
  grep -q "Numark V7:" <<<"$devs"
}

if [ "$UNINSTALL_DRIVER" = 1 ]; then
  step "Removing the Numark V7 audio device"
  sudo rm -rf "$HAL_DIR/NumarkV7.driver"
  restart_coreaudio
  echo "    removed. OpenV7.app keeps working for control."
  exit 0
fi

# The audio sources must be in the Makefile. A copy updated out-of-tree may be
# sitting next to it as Makefile.new, waiting to be reviewed and moved in.
if ! grep -q 'src/audio.c' Makefile; then
  if [ -f Makefile.new ]; then
    die "Apply the updated Makefile first -- review it, then:  mv Makefile.new Makefile"
  fi
  die "This Makefile does not build the audio sources (src/audio.c, src/v7ring.c)."
fi

# Zip downloads can drop the executable bit.
chmod +x tools/*.sh dist/*.sh driver/*.sh 2>/dev/null || true

step "macOS $(sw_vers -productVersion) on $(uname -m)"

step "Checking the Xcode command line tools"
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find clang >/dev/null 2>&1; then
  xcode-select --install 2>/dev/null || true
  die "The Command Line Tools are not installed. Finish the installer that just opened, then run ./install.sh again."
fi
echo "    $(xcode-select -p)"
./tools/pick-sdk.sh >/dev/null || die "No usable macOS SDK (see the message above)."
echo "    SDK $(./tools/pick-sdk.sh --version)"

step "Checking Homebrew (libusb comes from it, at build time only)"
BREW="$(command -v brew || true)"
[ -z "$BREW" ] && [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
[ -z "$BREW" ] && [ -x /usr/local/bin/brew ] && BREW=/usr/local/bin/brew
[ -n "$BREW" ] || die "Homebrew is not installed. Install it from https://brew.sh, then run ./install.sh again."
eval "$("$BREW" shellenv)"
brew list libusb >/dev/null 2>&1 || brew install libusb
command -v pkg-config >/dev/null 2>&1 || brew install pkgconf
echo "    libusb $(pkg-config --modversion libusb-1.0)"

run_quiet() {   # run_quiet <label> <cmd...>: show output only if it fails
  local label="$1"; shift
  local out
  out="build/$(echo "$label" | tr ' ' '-').log"
  if "$@" >"$out" 2>&1; then echo "    $label: ok"
  else cat "$out"; die "$label failed"; fi
}

step "Building the bridge and running the tests"
rm -f openv7     # force a fresh link (NOT `make clean`: that deletes build/, logs included)
run_quiet "build openv7" make
run_quiet "midi tests" make test
run_quiet "corpus test" make corpus
run_quiet "audio tests" make audiotest
if grep -q '^feedbacktest:' Makefile; then
  run_quiet "feedback tests" make feedbacktest
else
  run_quiet "feedback tests" bash -c 'cc -O2 -std=c11 tests/feedback_test.c -o build/feedback_test -lm && ./build/feedback_test'
fi

step "Building OpenV7.app"
run_quiet "build app" make app

if [ "$DRIVER" = 1 ]; then
  step "Building the Numark V7 audio device"
  run_quiet "build driver" make driver
  run_quiet "driver tests" make drivertest

  step "Installing it (your password is needed for $HAL_DIR)"
  echo "    All audio on this Mac will pause for a second while CoreAudio restarts."
  sudo mkdir -p "$HAL_DIR"
  sudo rm -rf "$HAL_DIR/NumarkV7.driver"
  sudo cp -R build/NumarkV7.driver "$HAL_DIR/"
  sudo chown -R root:wheel "$HAL_DIR/NumarkV7.driver"
  # coreaudiod reads plug-ins as its own user: owner-only files (a umask of 077,
  # or a checkout that kept 600 modes) make it skip the bundle without a word.
  sudo chmod -R u=rwX,go=rX "$HAL_DIR/NumarkV7.driver"
  restart_coreaudio
  if driver_visible; then
    echo "    \"Numark V7\" is now an audio device on this Mac."
  else
    echo "    !! CoreAudio did not list \"Numark V7\" yet. Wait ten seconds and run"
    echo "         system_profiler SPAudioDataType | grep -A3 'Numark V7'"
    echo "       If it is still missing, macOS refused to load the plug-in. Its reason is in"
    echo "         log show --last 5m --predicate 'process CONTAINS \"coreaudiod\" OR process CONTAINS \"Core Audio\"' | grep -i -e numark -e NumarkV7"
    echo "       A Developer ID signature usually fixes that:"
    echo "         DEVELOPER_ID=\"Developer ID Application: ...\" ./install.sh --audio-driver"
  fi
fi

step "Installing OpenV7.app to /Applications"
if pgrep -f "/OpenV7.app/Contents/MacOS/OpenV7" >/dev/null 2>&1; then
  osascript -e 'tell application id "com.openv7.app" to quit' >/dev/null 2>&1 || true
  sleep 2
  pkill -f "/OpenV7.app/Contents/MacOS/" 2>/dev/null || true
fi
pkill -x openv7 2>/dev/null || true
sleep 2
rm -rf /Applications/OpenV7.app
cp -R build/OpenV7.app /Applications/
open /Applications/OpenV7.app
echo "    installed and started -- look for the V7 icon in the menu bar."

step "Done"
if [ "$DRIVER" = 1 ] || [ -d "$HAL_DIR/NumarkV7.driver" ]; then
cat <<'EOF'
    Control: pick "Numark V7" as the MIDI controller in your DJ app.
    Audio:   pick "Numark V7" as the audio OUTPUT. Channels 1-2 -> DECK A
             outputs, 3-4 -> DECK B. macOS will ask once whether OpenV7 may use
             the "microphone" -- say yes: that is the Numark V7 device, not a mic.
EOF
else
cat <<'EOF'
    Control: pick "Numark V7" as the MIDI controller in your DJ app.
    Audio:   to hear the deck's own outputs, first prove the USB audio path:
               1. quit OpenV7 from its menu-bar icon
               2. turn your mixer down, then run:   ./openv7 --tone --diag
                  -> 440 Hz from DECK A's RCA outputs, 660 Hz from DECK B's
               3. Ctrl-C, then:                      ./install.sh --audio-driver
EOF
fi
