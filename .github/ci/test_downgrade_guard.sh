#!/usr/bin/env bash
# Never-go-backwards test (ops #1318). Run it the same way CI does:
#   bash .github/ci/test_downgrade_guard.sh
#
# The trap (same as the Authentik redis crash loop, ops #1306): an update fetched whatever VERSION on
# main named, with no look at what was installed, and replaced a newer tool or Android device with
# the older pinned one. Every case below runs the real install.sh, the real `takwerx update`, the
# real tool_needs, emu_upgrade_image, emu_upgrade_done and release.sh, in a scratch home, with a fake
# curl. It needs no network, no Android and no VM.
#
#   install.sh and takwerx update
#    1. a lower version than the installed one: refused, nothing changes
#    2. a lower version than the highest one that ever ran here (state file): refused
#    3. TAKWERX_ALLOW_DOWNGRADE=1: goes through
#    4. a higher version: installed (the new copy runs init)
#    5. GitHub answers with a web page instead of X.Y.Z: refused, nothing changes
#    6. a tag whose files say another version: refused, the old copy stays
#    7. a swap an earlier run left half done (app.old only): the old copy comes back
#   tools
#    8. a tool newer than the pin is kept; an older one or none is installed
#   Android device
#    9. a device on android-36 (image present): untouched. Image not present: stops, untouched
#   10. a device on android-34: moved to 35 with a whole copy of its data, build number written
#   11. no build number in the image: stops, nothing changed. Copy fails: stops, nothing changed
#   12. a half-made copy from an earlier try is thrown away and made again
#   13. data that has run on Android 36 is not moved down to 35
#   14. the copy is removed only when Android booted AND ATAK is there (where takwerx put ATAK)
#   release.sh
#   15. a version lower than the newest release: refused
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0
check() { # check NAME COMMAND...
  local name=$1; shift
  if "$@" >"$WORK/out" 2>&1; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/       /' "$WORK/out"; FAILS=$((FAILS + 1)); fi
}

# ---- a fake curl: the VERSION file on main, and the release tarball --------------------------------
# FAKE_VERSION is the text raw.githubusercontent.com answers; FAKE_TARBALL is the file the archive
# URL answers. Every call is logged to $FAKE_LOG.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/curl" <<'EOS'
#!/usr/bin/env bash
out=''; url=''; prev=''
for a in "$@"; do
  [ "$prev" = -o ] && out=$a
  case "$a" in http*) url=$a ;; esac
  prev=$a
done
echo "$url" >>"$FAKE_LOG"
case "$url" in
  https://raw.githubusercontent.com/*/main/VERSION) printf '%s' "$FAKE_VERSION" ;;
  https://github.com/*/archive/refs/*) cp "$FAKE_TARBALL" "$out" ;;
  *) exit 6 ;;
esac
EOS
chmod +x "$WORK/bin/curl"

# make_release VERSION DIR [CLAIMED]: a tarball like a GitHub archive (one top folder). takwerx in it is a
# stub that says it ran init; CLAIMED is the VERSION file inside, when it differs from the tag.
make_release() {
  local ver=$1 out=$2 claimed=${3:-$1} d="$WORK/rel-$1-$$-$RANDOM"
  mkdir -p "$d/atak-terminal-$ver/lib"
  printf '%s\n' "$claimed" >"$d/atak-terminal-$ver/VERSION"
  printf '#!/usr/bin/env bash\necho "STUB takwerx %s ran: $*"\n' "$claimed" >"$d/atak-terminal-$ver/takwerx"
  chmod +x "$d/atak-terminal-$ver/takwerx"
  tar -czf "$out" -C "$d" "atak-terminal-$ver"
}

# fresh_home NAME INSTALLED [HIGHEST]: a home with the real takwerx tree installed as INSTALLED
fresh_home() {
  local h="$WORK/home-$1"
  rm -rf "$h"; mkdir -p "$h/app" "$h/state"
  (cd "$REPO" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - | tar -xf - -C "$h/app")
  printf '%s\n' "$2" >"$h/app/VERSION"
  [ -n "${3:-}" ] && printf 'takwerx=%s\n' "$3" >"$h/state/highest"
  printf '%s' "$h"
}
export FAKE_LOG="$WORK/curl.log"

# run_install HOME: the real install.sh against the fake curl; its exit status and output in $WORK/inst.out
run_install() {
  : >"$FAKE_LOG"
  PATH="$WORK/bin:$PATH" HOME="$1/hm" TAKWERX_ROOT="$1" bash "$REPO/install.sh" >"$WORK/inst.out" 2>&1
}
# run_update HOME: the real `takwerx update` from the installed copy
run_update() {
  : >"$FAKE_LOG"
  PATH="$WORK/bin:$PATH" HOME="$1/hm" TAKWERX_ROOT="$1" "$1/app/takwerx" update >"$WORK/upd.out" 2>&1
}

tarball() { make_release "$1" "$WORK/t-$1.tgz" "${2:-$1}"; printf '%s' "$WORK/t-$1.tgz"; }

# --- 1. lower than installed
t_lower_installed() {
  local h out; h=$(fresh_home 1 0.2.15)
  export FAKE_VERSION=0.2.14 FAKE_TARBALL; FAKE_TARBALL=$(tarball 0.2.14)
  run_install "$h" && { echo "install.sh went through"; return 1; }
  grep -q 'older than the takwerx you have (0.2.15)' "$WORK/inst.out" || { cat "$WORK/inst.out"; return 1; }
  [ "$(cat "$h/app/VERSION")" = 0.2.15 ] || { echo "installed copy changed"; return 1; }
  run_update "$h" && { echo "takwerx update went through"; return 1; }
  grep -q 'older than the takwerx you have (0.2.15)' "$WORK/upd.out" || { cat "$WORK/upd.out"; return 1; }
  [ "$(cat "$h/app/VERSION")" = 0.2.15 ] || { echo "installed copy changed by update"; return 1; }
  [ ! -e "$h/app.old" ] && [ ! -e "$h/app.new" ] || { echo "left a folder behind"; return 1; }
}
check "1 a lower version than the installed one is refused (install line and update)" t_lower_installed

# --- 2. lower than the highest that ever ran, though the installed copy is older (a reinstall)
t_lower_than_seen() {
  local h; h=$(fresh_home 2 0.2.10 0.2.16)
  export FAKE_VERSION=0.2.15 FAKE_TARBALL; FAKE_TARBALL=$(tarball 0.2.15)
  run_install "$h" && { echo "install.sh went through"; return 1; }
  grep -q '(0.2.16)' "$WORK/inst.out" || { cat "$WORK/inst.out"; return 1; }
  run_update "$h" && { echo "takwerx update went through"; return 1; }
  grep -q '(0.2.16)' "$WORK/upd.out" || { cat "$WORK/upd.out"; return 1; }
  [ "$(cat "$h/app/VERSION")" = 0.2.10 ] || { echo "installed copy changed"; return 1; }
}
check "2 a version below the highest one that ran here is refused" t_lower_than_seen

# --- 3. on purpose
t_allow() {
  local h; h=$(fresh_home 3 0.2.15 0.2.15)
  export FAKE_VERSION=0.2.14 FAKE_TARBALL; FAKE_TARBALL=$(tarball 0.2.14)
  TAKWERX_ALLOW_DOWNGRADE=1 run_install "$h" || { cat "$WORK/inst.out"; return 1; }
  [ "$(cat "$h/app/VERSION")" = 0.2.14 ] || { echo "not installed"; return 1; }
  h=$(fresh_home 3b 0.2.15 0.2.15)
  TAKWERX_ALLOW_DOWNGRADE=1 run_update "$h" || { cat "$WORK/upd.out"; return 1; }
  [ "$(cat "$h/app/VERSION")" = 0.2.14 ] || { echo "update did not go back"; return 1; }
}
check "3 TAKWERX_ALLOW_DOWNGRADE=1 goes back on purpose" t_allow

# --- 4. higher, and the same version
t_higher() {
  local h; h=$(fresh_home 4 0.2.15 0.2.15)
  export FAKE_VERSION=0.2.16 FAKE_TARBALL; FAKE_TARBALL=$(tarball 0.2.16)
  run_install "$h" || { cat "$WORK/inst.out"; return 1; }
  grep -q 'STUB takwerx 0.2.16 ran: init' "$WORK/inst.out" || { cat "$WORK/inst.out"; return 1; }
  [ "$(cat "$h/app/VERSION")" = 0.2.16 ] && [ ! -e "$h/app.old" ] || { echo "not installed cleanly"; return 1; }
  h=$(fresh_home 4b 0.2.15 0.2.15)
  run_update "$h" || { cat "$WORK/upd.out"; return 1; }
  grep -q 'STUB takwerx 0.2.16 ran: init' "$WORK/upd.out" || { cat "$WORK/upd.out"; return 1; }
  h=$(fresh_home 4c 0.2.16 0.2.16)
  run_install "$h" || { cat "$WORK/inst.out"; return 1; }   # the same version again: a plain reinstall
}
check "4 a higher or equal version installs, and the new copy runs init" t_higher

# --- 5. not a version
t_not_a_version() {
  local h; h=$(fresh_home 5 0.2.15 0.2.15)
  export FAKE_TARBALL; FAKE_TARBALL=$(tarball 0.2.16)
  local bad
  for bad in '<html><body>Please log in to the hotel Wi-Fi</body></html>' '0.2' 'latest' '0.2.16-beta' '../../x'; do
    FAKE_VERSION=$bad
    run_install "$h" && { echo "install.sh accepted '$bad'"; return 1; }
    grep -q 'did not answer with a takwerx version number' "$WORK/inst.out" || { echo "no message for '$bad'"; cat "$WORK/inst.out"; return 1; }
    run_update "$h" && { echo "update accepted '$bad'"; return 1; }
    ! grep -q 'archive/refs' "$FAKE_LOG" || { echo "downloaded a tarball for '$bad'"; return 1; }
  done
  [ "$(cat "$h/app/VERSION")" = 0.2.15 ] || { echo "installed copy changed"; return 1; }
}
check "5 an answer that is not X.Y.Z is refused and nothing is downloaded" t_not_a_version

# --- 6. the tag holds another version than its name
t_wrong_tag() {
  local h; h=$(fresh_home 6 0.2.15 0.2.15)
  export FAKE_VERSION=0.2.16 FAKE_TARBALL; FAKE_TARBALL=$(tarball 0.2.16 0.2.99)
  run_install "$h" && { echo "install.sh went through"; return 1; }
  [ "$(cat "$h/app/VERSION")" = 0.2.15 ] || { echo "installed copy changed"; return 1; }
  run_update "$h" && { echo "update went through"; return 1; }
  [ "$(cat "$h/app/VERSION")" = 0.2.15 ] && [ ! -e "$h/app.new" ] || { echo "installed copy changed or app.new left"; return 1; }
}
check "6 a tag that holds another version than its name is refused, old copy stays" t_wrong_tag

# --- 7. half-done swap
t_half_swap() {
  local h; h=$(fresh_home 7 0.2.15 0.2.15)
  mv "$h/app" "$h/app.old"
  export FAKE_VERSION=0.2.16 FAKE_TARBALL; FAKE_TARBALL=$(tarball 0.2.16)
  # a download that fails halfway: the fake tarball is not there
  FAKE_TARBALL="$WORK/does-not-exist.tgz" run_install "$h" && { echo "install.sh went through"; return 1; }
  [ "$(cat "$h/app/VERSION" 2>/dev/null)" = 0.2.15 ] || { echo "the old copy did not come back"; return 1; }
}
check "7 a half-done swap puts the old copy back" t_half_swap

# ---- the pieces that need lib/common.sh and lib/emulator.sh -----------------------------------------
# lib() HOME: source the real libraries in this shell, in a scratch home (call inside a subshell).
lib() {
  export TAKWERX_ROOT="$1" HOME="$1/hm" TAKWERX_APP="$REPO"
  mkdir -p "$HOME"
  TAKWERX_VERSION=$(cat "$REPO/VERSION")
  # shellcheck source=/dev/null
  . "$REPO/lib/common.sh"
  case "$HOST_OS" in macos) . "$REPO/lib/host-macos.sh" ;; linux) . "$REPO/lib/host-linux.sh" ;; esac
  . "$REPO/lib/vm.sh"; . "$REPO/lib/android.sh"; . "$REPO/lib/emulator.sh"
  alert() { :; }
}

# --- 8. tool pins
t_tool_needs() {
  (
    lib "$WORK/home-tools"
    d="$WORK/home-tools/tool"; mkdir -p "$d"
    printf '2.3.0\n' >"$d/.version"
    tool_needs Lima "$d" 2.3.0 && { echo "the same version needs an install"; exit 1; }
    printf '2.4.0\n' >"$d/.version"
    tool_needs Lima "$d" 2.3.0 2>/dev/null && { echo "a NEWER Lima (2.4.0) would be replaced by 2.3.0"; exit 1; }
    printf '2.2.1\n' >"$d/.version"
    tool_needs Lima "$d" 2.3.0 || { echo "an OLDER Lima is not replaced"; exit 1; }
    printf '10\n' >"$d/.version"
    tool_needs "Android image" "$d" 09 2>/dev/null && { echo "image r10 would be replaced by r09"; exit 1; }
    printf '37.1.11\n' >"$d/.version"
    tool_needs emulator "$d" 37.2.0 || { echo "an older emulator is not replaced"; exit 1; }
    rm -f "$d/.version"
    tool_needs emulator "$d" 37.1.11 || { echo "a missing tool is not installed"; exit 1; }
    printf 'garbage text\n' >"$d/.version"
    tool_needs emulator "$d" 37.1.11 || { echo "an unreadable version is not replaced"; exit 1; }
  )
}
check "8 a tool newer than the pin is kept; older, missing or unreadable is installed" t_tool_needs

# An AVD for the Android cases. avd_make NAME API [with-data]: leaves the scratch home in $WORK/home-NAME
avd_make() {
  local h="$WORK/home-$1" d
  rm -rf "$h"; mkdir -p "$h"
  d="$h/avd/terminal.avd"; mkdir -p "$d"
  printf 'image.sysdir.1=system-images/android-%s/google_apis/%s/\ntarget=android-%s\nhw.ramSize=2048\n' "$2" "$(uname -m | sed 's/arm64/arm64-v8a/; s/aarch64/arm64-v8a/')" "$2" >"$d/config.ini"
  printf 'target=android-%s\n' "$2" >"$h/avd/terminal.ini"
  [ "${3:-}" = with-data ] && printf 'precious ATAK data\n' >"$d/userdata-qemu.img.qcow2"
  printf '%s' "$h"
}
sysimg_make() { # sysimg_make HOME API [BUILD]
  local d="$1/tools/android-sdk/system-images/android-$2/google_apis/$(uname -m | sed 's/arm64/arm64-v8a/; s/aarch64/arm64-v8a/')"
  [ "$(uname -s)" = Linux ] && d="$1/tools/android-sdk/system-images/android-$2/google_apis/x86_64"
  mkdir -p "$d"; : >"$d/system.img"
  [ -n "${3:-}" ] && printf 'ro.build.version.incremental=%s\n' "$3" >"$d/build.prop"
  return 0
}
cfg() { sed -n 's/^image.sysdir.1=system-images\/android-\([0-9]*\)\/.*/\1/p' "$1/avd/terminal.avd/config.ini"; }

# --- 9. newer device
t_newer_device() {
  local h; h=$(avd_make newer 36 with-data); sysimg_make "$h" 36 B36; sysimg_make "$h" 35 B35
  ( lib "$h"; emu_upgrade_image ) >"$WORK/o" 2>&1 || { cat "$WORK/o"; return 1; }
  [ "$(cfg "$h")" = 36 ] || { echo "the android-36 device was moved to $(cfg "$h")"; return 1; }
  [ ! -e "$h/avd/terminal.avd/version_num.cache" ] && [ ! -d "$h/avd/terminal.avd.before-android35" ] || { echo "it was touched"; return 1; }
  h=$(avd_make newer2 36 with-data); sysimg_make "$h" 35 B35   # image 36 is not here
  ( lib "$h"; emu_upgrade_image ) >"$WORK/o" 2>&1 && { echo "went on with an Android 36 device and no 36 image"; return 1; }
  [ "$(cfg "$h")" = 36 ] && [ ! -e "$h/avd/terminal.avd/version_num.cache" ] || { echo "it was touched"; return 1; }
  h=$(avd_make odd 36 with-data); sed -i.bak 's#^image.sysdir.1=.*#image.sysdir.1=something/odd/#' "$h/avd/terminal.avd/config.ini"; sysimg_make "$h" 35 B35
  ( lib "$h"; emu_upgrade_image ) >"$WORK/o" 2>&1 && { echo "went on with an image it does not recognise"; return 1; }
  grep -q 'something/odd' "$h/avd/terminal.avd/config.ini" || { echo "odd config rewritten"; return 1; }
}
check "9 a device on a newer (or odd) Android image is not rewritten to the pin" t_newer_device

# --- 10. older device, the good path
t_older_device() {
  local h k; h=$(avd_make older 34 with-data); sysimg_make "$h" 35 BUILD35
  k="$h/avd/terminal.avd.before-android35"
  ( lib "$h"; emu_upgrade_image ) >"$WORK/o" 2>&1 || { cat "$WORK/o"; return 1; }
  [ "$(cfg "$h")" = 35 ] || { echo "not moved"; return 1; }
  [ "$(cat "$h/avd/terminal.avd/version_num.cache")" = BUILD35 ] || { echo "build number not written"; return 1; }
  [ "$(cat "$k/userdata-qemu.img.qcow2")" = 'precious ATAK data' ] || { echo "the copy of the data is not whole"; return 1; }
  [ ! -e "$k.partial" ] || { echo ".partial left"; return 1; }
}
check "10 a device on an older Android moves to the pin with a whole copy of its data" t_older_device

# --- 11. no build number; copy fails
t_unsafe_move() {
  local h; h=$(avd_make nobuild 34 with-data); sysimg_make "$h" 35   # build.prop missing
  ( lib "$h"; emu_upgrade_image ) >"$WORK/o" 2>&1 && { echo "moved with no build number"; return 1; }
  [ "$(cfg "$h")" = 34 ] && [ ! -e "$h/avd/terminal.avd/version_num.cache" ] && [ ! -d "$h/avd/terminal.avd.before-android35" ] || { echo "it was touched"; return 1; }
  h=$(avd_make emptybuild 34 with-data); sysimg_make "$h" 35 ''; printf 'ro.build.version.incremental=\n' >"$(find "$h/tools" -name system.img -exec dirname {} \;)/build.prop"
  ( lib "$h"; emu_upgrade_image ) >"$WORK/o" 2>&1 && { echo "moved with an empty build number"; return 1; }
  [ "$(cfg "$h")" = 34 ] || { echo "empty build.prop: it was touched"; return 1; }
  # a copy that fails (cp is broken): the device must not be moved without its copy
  h=$(avd_make nocopy 34 with-data); sysimg_make "$h" 35 BUILD35
  mkdir -p "$WORK/badcp"; printf '#!/bin/sh\nexit 1\n' >"$WORK/badcp/cp"; chmod +x "$WORK/badcp/cp"
  ( PATH="$WORK/badcp:$PATH"; lib "$h"; emu_upgrade_image ) >"$WORK/o" 2>&1 && { echo "moved though the copy failed"; return 1; }
  [ "$(cfg "$h")" = 34 ] && [ ! -e "$h/avd/terminal.avd/version_num.cache" ] || { echo "copy failed: it was touched"; return 1; }
  [ ! -d "$h/avd/terminal.avd.before-android35" ] && [ ! -d "$h/avd/terminal.avd.before-android35.partial" ] || { echo "copy failed: a folder is left"; return 1; }
}
check "11 no build number, or no copy of the data: stops with nothing changed" t_unsafe_move

# --- 12. a half-made copy
t_half_copy() {
  local h k; h=$(avd_make half 34 with-data); sysimg_make "$h" 35 BUILD35
  k="$h/avd/terminal.avd.before-android35"
  mkdir -p "$k.partial"; printf 'junk' >"$k.partial/userdata-qemu.img.qcow2"
  ( lib "$h"; emu_upgrade_image ) >"$WORK/o" 2>&1 || { cat "$WORK/o"; return 1; }
  [ "$(cat "$k/userdata-qemu.img.qcow2")" = 'precious ATAK data' ] && [ ! -e "$k.partial" ] || { echo "the half copy was kept or blocked the real one"; return 1; }
  # and a whole copy from before stays as it is
  [ "$(cfg "$h")" = 35 ] || { echo "not moved"; return 1; }
}
check "12 a half-made copy is thrown away and made again" t_half_copy

# --- 13. data that ran on 36
t_seen_newer() {
  local h; h=$(avd_make seen 34 with-data); sysimg_make "$h" 35 BUILD35
  mkdir -p "$h/state"; printf 'android_api=36\n' >"$h/state/highest"
  ( lib "$h"; emu_upgrade_image ) >"$WORK/o" 2>&1 && { echo "moved data that ran on Android 36 down to 35"; return 1; }
  [ "$(cfg "$h")" = 34 ] || { echo "it was touched"; return 1; }
}
check "13 data that has run on a newer Android is not moved down" t_seen_newer

# --- 14. when the copy goes
t_done() {
  local h k; h=$(avd_make done 35 with-data)
  k="$h/avd/terminal.avd.before-android35"
  # booted, ATAK was installed by takwerx but is not there: keep
  mkdir -p "$k"
  ( lib "$h"; config_set ATAK_APK /x/atak.apk; android_booted() { return 0; }; atak_installed() { return 1; }; emu_upgrade_done )
  [ -d "$k" ] || { echo "the copy was removed though ATAK is gone"; return 1; }
  # not booted: keep
  ( lib "$h"; config_set ATAK_APK /x/atak.apk; android_booted() { return 1; }; atak_installed() { return 0; }; emu_upgrade_done )
  [ -d "$k" ] || { echo "the copy was removed before Android booted"; return 1; }
  # booted and ATAK there: remove
  ( lib "$h"; config_set ATAK_APK /x/atak.apk; android_booted() { return 0; }; atak_installed() { return 0; }; emu_upgrade_done )
  [ ! -d "$k" ] || { echo "the copy stayed though all is well"; return 1; }
  # takwerx never installed ATAK (no APK on record): booting is enough
  mkdir -p "$k"; rm -f "$h/config"
  ( lib "$h"; android_booted() { return 0; }; atak_installed() { return 1; }; emu_upgrade_done )
  [ ! -d "$k" ] || { echo "the copy stayed on a device that never had ATAK"; return 1; }
}
check "14 the copy goes only when Android booted and ATAK is there" t_done

# --- 15. release.sh
t_release_lower() {
  local d="$WORK/rel15"; rm -rf "$d"; mkdir -p "$d" && cd "$d" || return 1
  git init -q -b main . && git config user.email t@t && git config user.name t
  cp "$REPO/release.sh" . && echo 0.3.0 >VERSION && printf '# Changelog\n\n## 0.2.9 - today\n\n- a thing\n' >CHANGELOG.md
  git add -A && git -c commit.gpgsign=false commit -q -m init
  git update-ref refs/tags/v0.3.0 HEAD   # the newest release
  bash release.sh 0.2.9 >out.txt 2>&1 && { echo "release.sh took 0.2.9 after 0.3.0"; return 1; }
  grep -q 'lower than the newest release 0.3.0' out.txt || { cat out.txt; return 1; }
  bash release.sh 0.3.1 >out.txt 2>&1; ! grep -q 'lower than the newest' out.txt || { echo "refused a higher version"; cat out.txt; return 1; }
  cd "$WORK" || return 1
}
check "15 release.sh refuses a version lower than the newest release" t_release_lower

[ "$FAILS" -eq 0 ] || { echo "downgrade guard tests FAILED ($FAILS)"; exit 1; }
echo "downgrade guard tests passed"
