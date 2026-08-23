#!/usr/bin/env bash
# Verify a built Mach-O carries version stamps that will launch on a user's Mac.
#
# A Mach-O records a floor (minos) and the SDK it was built against, and BOTH
# gate launch: too high a floor locks out older macOS, and an sdk from a major
# that has not shipped yet makes the binary unlaunchable ANYWHERE except the
# machine running that seed, with "You can't use this version of the application
# with this version of macOS".
#
# This runs on the built artifact rather than on the inputs, deliberately. The
# SDK can be forced by an SDKROOT in the environment (xcrun exports one) or by a
# command-line `make SDKROOT=...`, which no amount of care in variable assignment
# can intercept -- a command-line assignment outranks anything a makefile says.
# Checking the output is the only check that cannot be routed around.
#
# usage: tools/check-stamps.sh <binary> <expected-minos>
set -euo pipefail

bin="${1:?usage: check-stamps.sh <binary> <expected-minos>}"
want_min="${2:?usage: check-stamps.sh <binary> <expected-minos>}"
here="$(cd "$(dirname "$0")" && pwd)"
max="$("$here/pick-sdk.sh" --max)"

build="$(vtool -show-build "$bin")"
got_min="$(printf '%s\n' "$build" | awk '/^ *minos /{print $2; exit}')"
got_sdk="$(printf '%s\n' "$build" | awk '/^ *sdk /{print $2; exit}')"

[ -n "$got_min" ] && [ -n "$got_sdk" ] || {
  echo "ERROR: $bin has no LC_BUILD_VERSION to check" >&2; exit 1; }

printf '    %-16s minos %-8s sdk %s\n' "$(basename "$bin")" "$got_min" "$got_sdk"

[ "$got_min" = "$want_min" ] || {
  echo "ERROR: $bin minos $got_min != expected $want_min" >&2; exit 1; }

[ "${got_sdk%%.*}" -le "$max" ] || {
  { echo "ERROR: $bin is stamped sdk $got_sdk, from a macOS major newer than $max."
    echo "       Such a build fails to launch on every Mac that is not running that"
    echo "       seed, with \"You can't use this version of the application with this"
    echo "       version of macOS\". Unset SDKROOT, or bump MACOS_SDK_MAX in"
    echo "       tools/pick-sdk.sh if that major has publicly shipped."; } >&2
  exit 1; }
