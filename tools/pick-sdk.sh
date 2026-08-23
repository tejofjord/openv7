#!/usr/bin/env bash
# Print the path of the macOS SDK builds should use — the newest installed SDK
# that is NOT from an unreleased macOS major.
#
# Why this exists: a Mach-O records the SDK it was built against, and macOS
# refuses to launch a GUI app whose recorded SDK comes from a future major OS,
# reporting "You can't use this version of the application with this version of
# macOS". Bare `clang` does not use the SDK `xcrun` reports — it resolves to the
# Command Line Tools SDK, which on a machine running a macOS seed is the SEED's
# SDK. That is how a DMG built on a macOS 27 seed ended up stamped `sdk 27.0`:
# perfect on the build machine, unlaunchable on every other Mac.
#
# Bump MACOS_SDK_MAX the day the next major publicly ships. Until then a seed SDK
# must never reach a user's Mac.
#
# Usage:
#   tools/pick-sdk.sh            # path of the SDK to build against
#   tools/pick-sdk.sh --version  # its version
#   tools/pick-sdk.sh --max      # the MACOS_SDK_MAX ceiling
#   SDKROOT=/path/to.sdk make    # override (still checked by the build's guard)
set -euo pipefail

MACOS_SDK_MAX=26

sdk_version() { /usr/libexec/PlistBuddy -c 'Print :Version' "$1/SDKSettings.plist" 2>/dev/null; }

# Both locations: Xcode and the Command Line Tools ship independent SDK sets, and
# a seed SDK usually lands in the CLT set first.
sdk_dirs() {
  local dev; dev="$(xcode-select -p 2>/dev/null || true)"
  [ -n "$dev" ] && printf '%s\n' "$dev/Platforms/MacOSX.platform/Developer/SDKs"/MacOSX*.sdk
  printf '%s\n' /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk
}

list_usable() {
  local d v
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    v="$(sdk_version "$d")" || continue
    [ -n "$v" ] || continue
    case "$v" in ''|*[!0-9.]*) continue ;; esac
    [ "${v%%.*}" -le "$MACOS_SDK_MAX" ] || continue
    printf '%s\t%s\n' "$v" "$d"
  done < <(sdk_dirs) | sort -V | tail -1
}

case "${1:-}" in
  --max) echo "$MACOS_SDK_MAX"; exit 0 ;;
esac

if [ -n "${SDKROOT:-}" ] && [ -d "${SDKROOT:-}" ]; then
  chosen_ver="$(sdk_version "$SDKROOT")"; chosen="$SDKROOT"
else
  line="$(list_usable)"
  [ -n "$line" ] || {
    {
      echo "ERROR: no macOS SDK installed with major version <= $MACOS_SDK_MAX."
      echo "       Installed SDKs:"
      while IFS= read -r d; do
        [ -d "$d" ] && printf '         %-10s %s\n' "$(sdk_version "$d")" "$d"
      done < <(sdk_dirs)
      echo "       Install Xcode or Command Line Tools for macOS $MACOS_SDK_MAX, or bump"
      echo "       MACOS_SDK_MAX in $0 if macOS $((MACOS_SDK_MAX + 1)) has publicly shipped."
    } >&2
    exit 1
  }
  chosen_ver="${line%%	*}"; chosen="${line#*	}"
fi

case "${1:-}" in
  --version) echo "$chosen_ver" ;;
  *)         echo "$chosen" ;;
esac
