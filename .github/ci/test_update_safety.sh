#!/usr/bin/env bash
# Update safety test (ops #1319). Run it the same way CI does:
#   bash .github/ci/test_update_safety.sh
#
# Three things `takwerx update` and `takwerx init` did to a machine that already had Android:
#   - They replaced the emulator, the system image, scrcpy or Lima while Android was running.
#     Windows cannot delete the files of a running emulator, on Linux the emulator runs from the
#     folder that is replaced, and a running VM keeps the Lima that started it.
#   - A failed unzip left a cache/unpack.* folder of 1 to 4 GB behind, and the cache was never pruned.
#   - An Intel Mac got the Apple-Silicon (arm64) emulator zip, from `--runtime emulator`, or from a
#     saved runtime that came over with Migration Assistant, and failed late.
#   1. init stops a running Android BEFORE it replaces a tool, and starts it again after (emulator runtime)
#   2. init leaves a running Android alone when no tool changes
#   3. redroid: a running Android and (for Lima) the VM stop before the tools are replaced
#   4. emu_tools_stale says stale for a missing or other version, current for the pinned ones
#   5. a failed unzip leaves no unpack.* folder, and the run stops with the file named
#   6. cache_prune removes leftovers and tools no longer pinned, keeps the pinned zips
#   7. an Intel Mac never gets the emulator runtime: saved, asked for in init, asked for in `runtime`
#   8. an Apple Silicon Mac and Linux keep it
# Runs the real cmd_init, init_emulator, tools_swap_guard and friends with the heavy steps replaced
# by logging stubs. Needs no VM, no Android and no network.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0
check() { # check NAME COMMAND...
  local name=$1; shift
  if "$@" >"$WORK/out" 2>&1; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/       /' "$WORK/out"; FAILS=$((FAILS + 1)); fi
}

export HOME="$WORK/home" TAKWERX_ROOT="$WORK/home/.takwerx" CALLS="$WORK/calls"
mkdir -p "$HOME"

# load OS ARCH: the libraries as ./takwerx loads them, on a host that uname says is OS/ARCH, so the
# Intel-Mac cases run on any runner. The real functions under test are loaded; the rest are stubs.
load() {
  local os=${1:-Darwin} arch=${2:-arm64}
  set -euo pipefail
  rm -rf "$TAKWERX_ROOT"
  uname() { case "${1:-}" in -s) echo "$os" ;; -m) echo "$arch" ;; *) command uname "$@" ;; esac; }
  TAKWERX_APP=$REPO; TAKWERX_VERSION=$(cat "$REPO/VERSION")
  # shellcheck source=/dev/null
  . "$REPO/lib/common.sh"
  case "$os" in Darwin) . "$REPO/lib/host-macos.sh" ;; *) . "$REPO/lib/host-linux.sh" ;; esac
  # shellcheck source=/dev/null
  . "$REPO/lib/vm.sh"; . "$REPO/lib/android.sh"; . "$REPO/lib/emulator.sh"
  : >"$CALLS"
  eval "$(awk '/^cmd_init\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REPO/takwerx")"
  eval "$(awk '/^init_emulator\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REPO/takwerx")"
  eval "$(awk '/^cmd_runtime\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REPO/takwerx")"
  # every step that would touch a machine only logs its name
  host_check() { :; }; path_setup() { :; }; app_build() { :; }; emu_disk_check() { :; }
  emu_libs_check() { :; }; location_refresh() { :; }; emu_up() { echo emu_up >>"$CALLS"; }
  host_tools_install() { echo host_tools_install >>"$CALLS"; }
  emu_sdk_install() { echo emu_sdk_install >>"$CALLS"; }
  emu_stop() { echo emu_stop >>"$CALLS"; EMU_UP_NOW=0; }
  emu_running() { [ "${EMU_UP_NOW:-0}" = 1 ]; }
  emu_copy_current() { return 0; }; emu_image_current() { return 0; }
  atak_installed() { return 0; }; init_ask_apk() { return 0; }
  cmd_up() { echo cmd_up >>"$CALLS"; }
  container_stop() { echo container_stop >>"$CALLS"; }
  vm_stop() { echo vm_stop >>"$CALLS"; }
}
order() { tr '\n' ' ' <"$CALLS"; }

t_stop_first() {
  ( load Darwin arm64; config_set RUNTIME emulator; EMU_UP_NOW=1
    emu_tools_stale() { return 0; }; host_tools_stale() { return 1; }
    cmd_init --no-up >/dev/null 2>&1 || true
    local got; got=$(order)
    case "$got" in
      "emu_stop host_tools_install emu_sdk_install emu_up cmd_up ") ;;
      *) echo "calls, in order: $got"; echo "expected: emu_stop host_tools_install emu_sdk_install emu_up cmd_up"; exit 1 ;;
    esac )
}
check "init stops a running Android before replacing a tool, and starts it after (emulator)" t_stop_first

t_stop_first_host() {
  ( load Darwin arm64; config_set RUNTIME emulator; EMU_UP_NOW=1
    emu_tools_stale() { return 1; }; host_tools_stale() { return 0; }
    cmd_init --no-up >/dev/null 2>&1 || true
    local got; got=$(order)
    case "$got" in "emu_stop host_tools_install "*) ;; *) echo "calls, in order: $got"; exit 1 ;; esac )
}
check "init stops a running Android before a host tool (adb, scrcpy) is replaced" t_stop_first_host

t_no_stop() {
  ( load Darwin arm64; config_set RUNTIME emulator; EMU_UP_NOW=1
    emu_tools_stale() { return 1; }; host_tools_stale() { return 1; }
    cmd_init --no-up >/dev/null 2>&1 || true
    if grep -q 'emu_stop\|cmd_up' "$CALLS"; then echo "stopped or restarted Android though no tool changes: $(order)"; exit 1; fi )
}
check "init leaves a running Android alone when no tool changes" t_no_stop

t_redroid_guard() {
  ( load Darwin x86_64; config_set RUNTIME redroid
    vm_running() { return 0; }; container_running() { return 0; }
    host_tools_stale() { return 0; }; lima_stale() { return 0; }
    tools_swap_guard
    [ "$(order)" = "container_stop vm_stop " ] || { echo "Lima changes: calls were: $(order)"; exit 1; }
    : >"$CALLS"; lima_stale() { return 1; }
    tools_swap_guard
    [ "$(order)" = "container_stop " ] || { echo "scrcpy only: calls were: $(order)"; exit 1; }
    : >"$CALLS"; host_tools_stale() { return 1; }
    tools_swap_guard
    [ -z "$(order)" ] || { echo "nothing changes, but: $(order)"; exit 1; } )
}
check "redroid: a running Android (and the VM, when Lima changes) stops before the tools are replaced" t_redroid_guard

t_stale() {
  ( load Linux x86_64
    emu_tools_stale || { echo "a missing install is not stale"; exit 1; }
    mkdir -p "$EMU_SDK/emulator" "$EMU_SYSIMG_DIR"
    printf '%s\n' "$EMULATOR_VERSION" >"$EMU_SDK/emulator/.version"; printf '%s\n' "$SYSIMG_REV" >"$EMU_SYSIMG_DIR/.version"
    ! emu_tools_stale || { echo "pinned versions say stale"; exit 1; }
    printf '%s\n' 1.0.0 >"$EMU_SDK/emulator/.version"
    emu_tools_stale || { echo "an old emulator is not stale"; exit 1; }
    printf '%s\n' "$EMULATOR_VERSION" >"$EMU_SDK/emulator/.version"; printf '%s\n' 00 >"$EMU_SYSIMG_DIR/.version"
    emu_tools_stale || { echo "an old system image is not stale"; exit 1; } )
}
check "emu_tools_stale: missing or other versions are stale, the pinned ones are not" t_stale

# ops #1318 keeps a tool NEWER than the pin (tool_needs), so it is not replaced and must not stop Android either.
t_stale_newer() {
  ( load Linux x86_64
    mkdir -p "$EMU_SDK/emulator" "$EMU_SYSIMG_DIR" "$PLATFORM_TOOLS_DIR"
    printf '%s\n' "$SYSIMG_REV" >"$EMU_SYSIMG_DIR/.version"; printf '%s\n' "$PLATFORM_TOOLS_LINUX_VERSION" >"$PLATFORM_TOOLS_DIR/.version"
    printf '%s\n' 99.0.0 >"$EMU_SDK/emulator/.version"
    ! emu_tools_stale || { echo "an emulator newer than the pin stops Android though it is kept"; exit 1; }
    printf '%s\n' "$EMULATOR_VERSION" >"$EMU_SDK/emulator/.version"; printf '%s\n' 99.0.0 >"$PLATFORM_TOOLS_DIR/.version"
    ! host_tools_stale || { echo "platform-tools newer than the pin stop Android though they are kept"; exit 1; }
    printf '%s\n' 1.0.0 >"$PLATFORM_TOOLS_DIR/.version"
    host_tools_stale || { echo "old platform-tools do not count as stale"; exit 1; }
    load Darwin arm64
    mkdir -p "$LIMA_DIR" "$SCRCPY_DIR"
    printf '%s\n' 99.0.0 >"$LIMA_DIR/.version"; printf '%s\n' "$SCRCPY_VERSION" >"$SCRCPY_DIR/.version"
    ! host_tools_stale || { echo "a Lima newer than the pin stops Android though it is kept"; exit 1; }
    ! lima_stale || { echo "a Lima newer than the pin stops the VM though it is kept"; exit 1; } )
}
check "a tool newer than the pin is kept and does not stop Android (with ops #1318's rule)" t_stale_newer

t_unzip_cleanup() {
  ( load Linux x86_64
    . "$REPO/lib/emulator.sh"      # the real emu_sdk_install (load stubs it)
    emu_license() { :; }
    printf 'this is not a zip file' >"$WORK/bad.zip"
    download() { cp "$WORK/bad.zip" "$2"; }
    ( emu_sdk_install ) >"$WORK/sdk.out" 2>&1 && { echo "a failed unzip did not stop the run"; exit 1; }
    grep -q 'Could not unpack' "$WORK/sdk.out" || { echo "no message naming the file:"; cat "$WORK/sdk.out"; exit 1; }
    left=$(find "$TAKWERX_CACHE" -maxdepth 1 -name 'unpack.*' | head -n1)
    [ -z "$left" ] || { echo "left behind: $left"; exit 1; } )
}
check "a failed unzip leaves no unpack.* folder behind" t_unzip_cleanup

t_prune() {
  ( load Linux x86_64
    mkdir -p "$TAKWERX_CACHE/unpack.AbC123"; printf x >"$TAKWERX_CACHE/unpack.AbC123/big"
    printf x >"$TAKWERX_CACHE/something.part"
    printf x >"$TAKWERX_CACHE/emulator-linux_x64-1.zip"
    printf x >"$TAKWERX_CACHE/x86_64-34_r01.zip"
    printf x >"$TAKWERX_CACHE/emulator-$EMU_ZIP_OS-$EMULATOR_BUILD.zip"
    printf x >"$TAKWERX_CACHE/$EMU_ABI-${SYSIMG_API}_r$SYSIMG_REV.zip"
    printf x >"$TAKWERX_CACHE/ATAK-Plugin-TakwerxMarket-1.8--5.8.0-civ-release.apk"
    cache_prune
    for gone in unpack.AbC123 something.part emulator-linux_x64-1.zip x86_64-34_r01.zip; do
      [ ! -e "$TAKWERX_CACHE/$gone" ] || { echo "$gone was kept"; exit 1; }
    done
    for kept in "emulator-$EMU_ZIP_OS-$EMULATOR_BUILD.zip" "$EMU_ABI-${SYSIMG_API}_r$SYSIMG_REV.zip" ATAK-Plugin-TakwerxMarket-1.8--5.8.0-civ-release.apk; do
      [ -e "$TAKWERX_CACHE/$kept" ] || { echo "$kept was removed"; exit 1; }
    done )
}
check "cache_prune removes leftovers and tools no longer pinned, keeps the pinned zips and the Market APK" t_prune

t_intel() {
  ( load Darwin x86_64; config_set RUNTIME emulator
    [ "$(runtime)" = redroid ] || { echo "an Intel Mac saved as emulator reads as $(runtime)"; exit 1; }
    ! runtime_supported emulator || { echo "an Intel Mac supports the emulator"; exit 1; }
    ( cmd_init --runtime emulator --no-up ) >"$WORK/intel.out" 2>&1 && { echo "init --runtime emulator was accepted on an Intel Mac"; exit 1; }
    grep -q 'Apple Silicon' "$WORK/intel.out" || { echo "wrong message:"; cat "$WORK/intel.out"; exit 1; }
    ( cmd_runtime emulator ) >"$WORK/intel2.out" 2>&1 && { echo "runtime emulator was accepted on an Intel Mac"; exit 1; }
    grep -q 'Apple Silicon' "$WORK/intel2.out" || { echo "wrong message:"; cat "$WORK/intel2.out"; exit 1; }
    if [ -s "$CALLS" ]; then echo "did work before refusing: $(order)"; exit 1; fi )
}
check "an Intel Mac never gets the emulator runtime (saved, init --runtime, takwerx runtime)" t_intel

t_keep() {
  ( load Darwin arm64; config_set RUNTIME emulator
    [ "$(runtime)" = emulator ] || { echo "Apple Silicon reads as $(runtime)"; exit 1; }
    runtime_supported emulator || { echo "Apple Silicon does not support the emulator"; exit 1; }
    load Linux x86_64; config_set RUNTIME emulator
    [ "$(runtime)" = emulator ] || { echo "Linux reads as $(runtime)"; exit 1; }
    load Darwin x86_64; config_set RUNTIME redroid
    [ "$(runtime)" = redroid ] || { echo "an Intel Mac on redroid reads as $(runtime)"; exit 1; } )
}
check "Apple Silicon and Linux keep the emulator runtime; an Intel Mac keeps redroid" t_keep

[ "$FAILS" -eq 0 ] || { echo "$FAILS check(s) failed"; exit 1; }
echo "all update-safety checks passed"
