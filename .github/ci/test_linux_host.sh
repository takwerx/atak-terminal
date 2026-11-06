#!/usr/bin/env bash
# Tests for the Linux host (ops #528, atak-terminal #17). Runs on any Linux x86-64 machine,
# needs no KVM, no download and no Android: it loads takwerx's libraries the way ./takwerx
# does, in a throwaway HOME, and checks the pieces that are pure shell.
#
#   bash .github/ci/test_linux_host.sh
#
# Before the Linux port, ./takwerx died at start on Linux ("Linux hosts are next on the
# list"), so every check below failed.
set -uo pipefail

[ "$(uname -s)" = Linux ] || { echo "SKIP: this test is for a Linux host"; exit 0; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0
check() { # check NAME COMMAND...
  local name=$1; shift
  if "$@" >"$WORK/out" 2>&1; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/       /' "$WORK/out"; FAILS=$((FAILS + 1)); fi
}

export HOME="$WORK/home" TAKWERX_ROOT="$WORK/home/.takwerx"
mkdir -p "$HOME/Downloads"

# --- 1. versions.env carries every Linux pin, as a real SHA-256 -------------------------------
pins() {
  # shellcheck source=/dev/null
  . "$REPO/versions.env"
  local v
  for v in EMULATOR_LINUX_SHA256 PLATFORM_TOOLS_LINUX_SHA256 SYSIMG_X86_SHA256; do
    [[ ${!v:-} =~ ^[0-9a-f]{64}$ ]] || { echo "$v is missing or not a SHA-256"; return 1; }
  done
  [ -n "${PLATFORM_TOOLS_LINUX_VERSION:-}" ] || { echo "PLATFORM_TOOLS_LINUX_VERSION is missing"; return 1; }
}
check "versions.env has the Linux pins" pins

# --- 2. the engine starts on Linux and answers help, status and doctor ------------------------
check "takwerx help starts on Linux" bash -c "'$REPO/takwerx' help | grep -q 'ATAK on your desktop'"
check "takwerx status runs" bash -c "'$REPO/takwerx' status | grep -q 'emulator'"
check "takwerx doctor runs and checks KVM" bash -c "'$REPO/takwerx' doctor 2>&1 | grep -qi kvm"
check "takwerx runtime redroid is refused on Linux" bash -c "! '$REPO/takwerx' runtime redroid 2>&1 | grep -qv 'emulator runtime only' || '$REPO/takwerx' runtime redroid 2>&1 | grep -q 'emulator runtime only'"

# --- 3. the library functions, loaded as ./takwerx loads them ---------------------------------
# A subshell per check, so one check's variables never leak into the next.
load() {
  set -euo pipefail
  TAKWERX_APP=$REPO; TAKWERX_VERSION=$(cat "$REPO/VERSION")
  # shellcheck source=/dev/null
  . "$REPO/lib/common.sh"; . "$REPO/lib/host-linux.sh"; . "$REPO/lib/vm.sh"; . "$REPO/lib/android.sh"; . "$REPO/lib/emulator.sh"
}

t_runtime_default() { ( load; [ "$RUNTIME_DEFAULT" = emulator ] && [ "$(runtime)" = emulator ] ); }
check "Linux defaults to the emulator runtime" t_runtime_default

t_abi() { ( load; [ "$EMU_ABI" = x86_64 ] && [ "$EMU_QEMU" = qemu-system-x86_64 ] && [ "$EMU_DIR" = "$EMU_SDK/emulator" ] \
  && [ "$(emu_sysdir)" = "system-images/android-$SYSIMG_API/$SYSIMG_TAG/x86_64/" ] ); }
check "x86-64 image, Google's emulator used in place" t_abi

t_adb() { ( load; [ "$ADB" = "$TAKWERX_TOOLS/android-sdk/platform-tools/adb" ] ); }
check "adb comes from the SDK's platform-tools" t_adb

# The newest ATAK by version, then by file date. BSD `stat -f %m` printed filesystem
# information on GNU, which broke the sort and picked an old APK.
t_find_apk() {
  ( load
    : >"$HOME/Downloads/ATAK-5.7.0.1-aaaaaaa-civ-release.apk"
    : >"$HOME/Downloads/ATAK-5.8.0.4-bbbbbbb-civ-release.apk"
    : >"$HOME/Downloads/ATAK-Plugin-foo-1.0-5.8.0-civ-release.apk"
    touch -d '2026-01-01' "$HOME/Downloads/ATAK-5.8.0.4-bbbbbbb-civ-release.apk"
    [ "$(find_atak_apk)" = "$HOME/Downloads/ATAK-5.8.0.4-bbbbbbb-civ-release.apk" ]
    [ "$(file_mtime "$HOME/Downloads/ATAK-5.8.0.4-bbbbbbb-civ-release.apk")" -gt 0 ] ); }
check "find_atak_apk picks the newest version on GNU userland" t_find_apk

t_sed_sha() {
  ( load
    printf 'a=1\nb=2\n' >"$WORK/f"; sed_inplace -e 's/^a=.*/a=9/' "$WORK/f"
    [ "$(cat "$WORK/f")" = "$(printf 'a=9\nb=2')" ]
    printf abc >"$WORK/h"
    [ "$(sha256_of "$WORK/h")" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ] ); }
check "sed_inplace and sha256_of work on GNU userland" t_sed_sha

# Screen size: from xrandr when there is a desktop, the tablet preset when there is none.
t_geometry() {
  ( load
    mkdir -p "$WORK/bin"
    printf '#!/bin/sh\necho "Screen 0: minimum 8 x 8, current 1920 x 1080, maximum 32767 x 32767"\necho "HDMI-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 527mm x 296mm"\n' >"$WORK/bin/xrandr"
    chmod +x "$WORK/bin/xrandr"
    [ "$(PATH="$WORK/bin:$PATH" emu_geometry_linux)" = "1840 980 200" ] || { echo "got: $(PATH="$WORK/bin:$PATH" emu_geometry_linux)"; exit 1; }
    printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/xrandr"; printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/xdpyinfo"; chmod +x "$WORK/bin/xdpyinfo"
    [ "$(PATH="$WORK/bin:$PATH" emu_geometry_linux)" = "2560 1440 200" ] ); }
check "screen size from xrandr, tablet preset without a desktop" t_geometry

# The launcher entry: written, executable, runs the engine, removed again.
t_app() {
  ( load
    app_build >/dev/null
    [ -f "$APP_DIR" ] && grep -q '^Name=TAKwerx ATAK Terminal$' "$APP_DIR" && grep -q "^Exec=$APP_LAUNCHER$" "$APP_DIR"
    [ -x "$APP_LAUNCHER" ] && grep -q 'takwerx" up' "$APP_LAUNCHER"
    app_remove
    [ ! -e "$APP_DIR" ] && [ ! -e "$APP_LAUNCHER" ] ); }
check "launcher entry is written and removed" t_app

# Other hardware is refused up front, with the reason.
t_arm() { ( load; HOST_ARCH=arm64; out=$(host_check 2>&1 || true); [[ $out == *"Intel and AMD"* ]] ); }
check "Linux on ARM is refused with a reason" t_arm

echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "all Linux host checks passed"
