#!/usr/bin/env bash
# shellcheck shell=bash
# The GPU runtime: Google's Android Emulator on the Mac's own GPU, instead of redroid in the
# VM. Chosen with `takwerx runtime emulator`. Every flag and the driver swap below has its
# reason in docs/DECISIONS.md, 2026-09-26.
#
# What it needs that takwerx does not install yet: an Android SDK with the emulator and an
# arm64 system image, an AVD (config.ini in DECISIONS), and Homebrew's molten-vk (or mesa,
# for KosmicKrisp).

EMU_DIR="$TAKWERX_TOOLS/emulator"
EMU_AVD=$(config_get EMU_AVD atak34)
EMU_PORT=$(config_get EMU_PORT 5574)
EMU_LOG="$TAKWERX_LOGS/emulator.log"
# The host Vulkan driver under Android's ANGLE. MoltenVK by default: it is the one that ran
# a 10-minute zoom stress without a hang, at 25-44 fps in a busy view. KosmicKrisp (mesa
# 26.2.3) is faster, 41-53 fps, but lost fences under heavy zooming every 5-15 minutes and
# the emulator aborted (VK_TIMEOUT). The emulator bundles older copies of both (MoltenVK
# 1.4.0; KosmicKrisp a Mesa 26.1 snapshot at 11 fps), so Homebrew's are used.
EMU_VK=$(config_get EMU_VK moltenvk)
EMU_MVK_LIB=/opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib
EMU_KK_LIB=/opt/homebrew/opt/mesa/lib/libvulkan_kosmickrisp.dylib

runtime() { config_get RUNTIME redroid; }

# The emulator registers with the adb server named by ANDROID_ADB_SERVER_PORT when it
# starts, which common.sh points at takwerx's private server, so it appears there by serial.
if [ "$(runtime)" = emulator ]; then ADB_ENDPOINT="emulator-$EMU_PORT"; fi

# The SDK that holds the system image and the emulator takwerx copies.
emu_sdk() {
  local d
  for d in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/Library/Android/sdk" /opt/homebrew/share/android-commandlinetools; do
    if [ -n "$d" ] && [ -d "$d/system-images" ] && [ -x "$d/emulator/emulator" ]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}
brew_version() { basename "$(readlink "/opt/homebrew/opt/$1" 2>/dev/null)" 2>/dev/null; }

# takwerx's own copy of the SDK's emulator with Homebrew's drivers in it. The emulator loads
# lib64/vulkan/<driver>.dylib by file name and ignores the ICD json's library_path, so the
# files themselves are replaced -- in this copy, never in the SDK. An APFS clone, so it costs
# no disk. Rebuilt when any version changes.
emu_prepare() {
  local sdk rev mv kv want
  sdk=$(emu_sdk) || die "No Android SDK with the emulator found (Android Studio, or brew install --cask android-commandlinetools)"
  case "$EMU_VK" in
    moltenvk)    [ -f "$EMU_MVK_LIB" ] || die "MoltenVK is missing; install it with: brew install molten-vk" ;;
    kosmickrisp) [ -f "$EMU_KK_LIB" ] || die "KosmicKrisp is missing; install it with: brew install mesa" ;;
    *) die "EMU_VK must be moltenvk or kosmickrisp (is '$EMU_VK')" ;;
  esac
  mv=$(brew_version molten-vk); kv=$(brew_version mesa)
  rev=$(sed -n 's/^Pkg.Revision=//p' "$sdk/emulator/source.properties")
  # The trailing tag is this function's own revision: bump it when the copy is built differently.
  want="emulator $rev, molten-vk ${mv:-none}, mesa ${kv:-none}, r6"
  if [ "$(tool_version "$EMU_DIR")" != "$want" ]; then
    step "Preparing the GPU emulator ($want)"
    rm -rf "$EMU_DIR"
    cp -Rc "$sdk/emulator" "$EMU_DIR" 2>/dev/null || cp -R "$sdk/emulator" "$EMU_DIR" || die "Could not copy the emulator"
    if [ -f "$EMU_MVK_LIB" ]; then cp -f "$EMU_MVK_LIB" "$EMU_DIR/lib64/vulkan/libMoltenVK.dylib" || die "Could not install MoltenVK into the emulator"; fi
    if [ -f "$EMU_KK_LIB" ]; then cp -f "$EMU_KK_LIB" "$EMU_DIR/lib64/vulkan/libvulkan_kosmickrisp.dylib" || die "Could not install KosmicKrisp into the emulator"; fi
    emu_retitle
    printf '%s\n' "$want" >"$EMU_DIR/.version"
  fi
}

# The window is titled from one format string, "%s Emulator - %s:%d" (product, AVD, port).
# It becomes "TAKwerx ATAK Terminal" in this copy: two characters longer than the slot, so
# it runs into the string that follows, "%s: %dx%d\n", a debug-only log format, which
# becomes "l". printf ignores the arguments neither string uses any more. The edit breaks Google's signature, so the copy is signed again locally with
# the entitlements it had (the hypervisor, and library validation off, which is also what
# lets it load Homebrew's drivers). macOS then sees a new app and may ask once for
# Local Network access. A failed patch leaves the stock title, nothing worse.
emu_retitle() {
  local bin="$EMU_DIR/qemu/darwin-aarch64/qemu-system-aarch64" ent="$TAKWERX_STATE/emulator.entitlements"
  codesign -d --entitlements :- "$bin" >"$ent" 2>/dev/null && [ -s "$ent" ] || { warn "Could not read the emulator's entitlements; keeping its title"; return 0; }
  cp -p "$bin" "$bin.orig"
  perl -0777 -pi -e 's/%s Emulator - %s:%d\x00%s: %dx%d\n\x00/TAKwerx ATAK Terminal\x00: %dx%d\n\x00/' "$bin"
  if cmp -s "$bin" "$bin.orig" || ! codesign --force --sign - --options runtime --entitlements "$ent" "$bin" >/dev/null 2>&1; then
    warn "Could not retitle the emulator window; keeping its title"
    mv -f "$bin.orig" "$bin"; return 0
  fi
  rm -f "$bin.orig"
}

# Android's screen, "W H DPI". The emulator scales a fixed Android screen into whatever size
# the window is dragged to; it cannot follow a free resize (only preset sizes). So by default
# ("screen") Android gets the main display's usable area less the window's title bar and
# side toolbar: a maximized window is then 1:1 and any smaller one scales down from full
# resolution. At 2560x1440 in a window dragged to 1656x932, ATAK was drawn at 65% and its
# labels and toolbar read small and soft (2026-09-26). DPI 200 per point, as the tablet
# preset, so a dp is 1.25 points on any Mac, Retina or not.
emu_geometry() {
  # Its own key: redroid's DISPLAY_PRESET is a fixed tablet size, the wrong default here.
  local preset; preset=$(config_get EMU_DISPLAY screen)
  if [ "$preset" != screen ]; then display_geometry "$preset" && return 0; fi
  local g w h k
  g=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var s=$.NSScreen.mainScreen, f=s.visibleFrame;
      [Math.round(f.size.width), Math.round(f.size.height), s.backingScaleFactor].join(" ")' 2>/dev/null) || g=''
  read -r w h k <<<"$g"
  [[ ${w:-} =~ ^[0-9]+$ && ${h:-} =~ ^[0-9]+$ && ${k:-} =~ ^[0-9]+$ ]] || { display_geometry tablet; return 0; }
  w=$(( (w - 80) * k / 2 * 2 )); h=$(( (h - 30) * k / 2 * 2 ))
  printf '%s %s %s' "$w" "$h" $(( 200 * k ))
}

# Written into the AVD before every boot, since the emulator reads the screen from it. The
# physical density is three quarters of the UI density: ATAK draws its map at the smaller of
# the two, and 150 against 200 is what redroid runs at (DECISIONS 2026-09-26). Every existing
# hw.lcd line goes first; appended duplicates are otherwise read last-wins.
emu_configure_avd() {
  local ini="$HOME/.android/avd/$EMU_AVD.avd/config.ini" w h dpi
  [ -f "$ini" ] || die "No AVD named $EMU_AVD (expected $ini)"
  read -r w h dpi <<<"$(emu_geometry)"
  { grep -vE '^hw\.lcd\.(width|height|density)[[:space:]]*=' "$ini"
    printf 'hw.lcd.width=%s\nhw.lcd.height=%s\nhw.lcd.density=%s\n' "$w" "$h" $(( dpi * 3 / 4 )); } >"$ini.tmp" && mv "$ini.tmp" "$ini"
  log "emulator screen ${w}x${h}, ui dpi $dpi"
}

emu_pid()     { pgrep -f "qemu-system-aarch64 -avd $EMU_AVD " | head -n1; }
emu_running() { [ -n "$(emu_pid)" ]; }

# Guest ANGLE on Vulkan on a Metal driver: the only path found where ATAK both runs on the
# GPU and draws icons wider than 64 px. VirtioTablet makes the host pointer a real mouse in
# Android (wheel as ACTION_SCROLL, buttons, hover) instead of synthetic touch swipes.
# No -grpc: it listens on every interface with no authentication.
emu_start() {
  emu_running && return 0
  emu_prepare
  local sdk; sdk=$(emu_sdk)
  rm -f "$HOME/.android/avd/$EMU_AVD.avd/"*.lock
  emu_configure_avd
  step "Starting Android on the GPU ($EMU_AVD, $(emu_geometry | awk '{print $1"x"$2" at "$3" dpi"}'))"
  log "emulator start: $(tool_version "$EMU_DIR")"
  ANDROID_SDK_ROOT="$sdk" ANDROID_HOME="$sdk" ANDROID_EMU_VK_SELECT_ICD="$EMU_VK" \
    nohup "$EMU_DIR/emulator" -avd "$EMU_AVD" -port "$EMU_PORT" -gpu host \
      -feature Vulkan,GuestAngle,VirtioTablet -no-snapshot -no-boot-anim \
      >>"$EMU_LOG" 2>&1 </dev/null &
  disown 2>/dev/null || true
}

emu_wait() {
  local start; start=$(date +%s)
  adb_server_ensure
  while [ "$(date +%s)" -lt $(( start + ${1:-300} )) ]; do
    if android_online && android_booted; then return 0; fi
    # The launcher takes a few seconds to start qemu; only then is "not running" a failure.
    if ! emu_running && [ "$(date +%s)" -gt $(( start + 30 )) ]; then return 1; fi
    sleep 2
  done
  return 1
}

# Idempotent settings for a desktop instance on this runtime. The screen size is the AVD's
# own (emu_configure_avd); only the UI density is applied over it.
emu_provision() {
  local tz w h dpi
  # Before ATAK starts, and on every boot (a debug property does not persist). ANGLE builds
  # each program's pipeline at link time with float placeholders for integer attributes of
  # its own; Metal rejects that pipeline ("uint2 cannot be read using ...Float4"), the link
  # fails and ATAK aborts in its line shader. Without the warm-up ATAK runs; the placeholder
  # pipelines still fail later, and nothing visible is missing (2026-09-26). The property is
  # the one ANGLE reads; the boot property the emulator passes through for it is not.
  if "$ADB" -s "$ADB_ENDPOINT" root >/dev/null 2>&1; then
    with_timeout 30 "$ADB" -s "$ADB_ENDPOINT" wait-for-device >/dev/null 2>&1 || true
    adb_sh setprop debug.angle.feature_overrides_disabled warmUpPipelineCacheAtLink >/dev/null 2>&1 \
      || warn "Could not set ANGLE's override; ATAK may not start on MoltenVK"
  else
    warn "adb root refused; ATAK may not start on MoltenVK (a google_apis image allows it)"
  fi
  adb_sh settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
  adb_sh settings put global stay_on_while_plugged_in 7 >/dev/null 2>&1 || true
  adb_sh svc power stayon true >/dev/null 2>&1 || true
  adb_sh locksettings set-disabled true >/dev/null 2>&1 || true
  adb_sh settings put secure show_ime_with_hard_keyboard 0 >/dev/null 2>&1 || true
  # The pointer is a tablet that Android also takes for a stylus; without this Android 14
  # offers stylus handwriting over every text field (a floating icon under the cursor).
  adb_sh settings put secure stylus_handwriting_enabled 0 >/dev/null 2>&1 || true
  # Android in dark mode. Since Android 12 a toast's text colour comes from the app's
  # theme (ATAK's is dark: white text) and its pill from the system's (light by default:
  # a white pill). White on white, unreadable. ATAK itself looks the same either way.
  adb_sh cmd uimode night yes >/dev/null 2>&1 || true
  tz=$(host_timezone)
  if [ -n "$tz" ]; then adb_sh setprop persist.sys.timezone "$tz" >/dev/null 2>&1 || true; fi
  read -r w h dpi <<<"$(emu_geometry)"
  atak_splash_apply "$w" "$h"
  adb_sh wm size reset >/dev/null 2>&1 || true
  adb_sh wm density "$dpi" >/dev/null 2>&1 || true
  # ATAK on this path. opengl.broken makes ATAK take a generic EGL config (the Metal
  # translator had none with stencil; not re-tested under ANGLE). The devopts key swaps
  # ATAK's GPU terrain cull for its CPU one, as ATAK's own Apple build always does: the
  # PBO readback is a fence round trip every frame here. Added only if missing, since the
  # file may hold the operator's own options.
  adb_sh 'mkdir -p /sdcard/atak && touch /sdcard/atak/opengl.broken
    f=/sdcard/atak/devopts.properties
    grep -q "^mapengine.glmapview.use-pbo-cull=" "$f" 2>/dev/null || echo "mapengine.glmapview.use-pbo-cull=0" >>"$f"' >/dev/null 2>&1 || true
}

# The emulator's own GPS, which ATAK takes as a real provider. Not kept across boots, so
# re-sent after every start.
emu_location_apply() {
  local pos lat lon
  pos=$(config_get LOCATION); [ -n "$pos" ] || return 0
  IFS=, read -r lat lon <<<"$pos"
  "$ADB" -s "$ADB_ENDPOINT" emu geo fix "$lon" "$lat" >/dev/null 2>&1 || warn "Could not send the position to Android"
}

emu_up() {
  emu_start
  if ! android_online || ! android_booted; then
    step "Waiting for Android to boot"
    emu_wait 300 || die "Android did not come up (the emulator exited or took over 5 minutes). See $EMU_LOG"
  fi
  ok "Android is up"
  emu_provision
  emu_location_apply
}

# A clean power-off. `adb emu kill` is a pulled plug: a plugin mid-save lost its whole saved
# layer list to it (DECISIONS 2026-09-26). The emulator process exits when Android is off.
emu_stop() {
  emu_running || return 0
  step "Stopping Android"
  if android_online; then
    atak_quit
    adb_sh sync >/dev/null 2>&1 || true
    adb_sh reboot -p >/dev/null 2>&1 || true
  fi
  local i
  for i in $(seq 1 45); do emu_running || return 0; sleep 1; done
  warn "Android did not power off within 45 seconds; stopping the emulator"
  "$ADB" -s "$ADB_ENDPOINT" emu kill >/dev/null 2>&1 || kill "$(emu_pid)" 2>/dev/null || true
}

# ATAK starts behind an "ATAK Loading" window. Under the emulator the hand-over from it
# loses the focus report ("Unknown focus tokens, dropping reportFocusChanged"), so the main
# window never gets input-method focus: no text field on ATAK's main screen can be typed
# into, in any plugin or in ATAK itself, while its Settings screen (a new window) works
# (2026-09-26). Sending ATAK home and back once re-runs the focus hand-over. Waits for the
# loading window to go, in the background, so `takwerx up` returns at once.
emu_focus_fix() {
  (
    local i focus windows
    for i in $(seq 1 60); do
      sleep 2
      # Captured first: under pipefail, `adb_sh ... | grep -q` fails whenever grep stops
      # reading early, i.e. exactly when it matches.
      focus=$(adb_sh dumpsys window 2>/dev/null || true)
      windows=$(adb_sh dumpsys window windows 2>/dev/null || true)
      if [[ $focus == *mCurrentFocus=*ATAKActivity* && $windows != *"ATAK Loading"* ]]; then
        sleep 3
        adb_sh input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
        sleep 1
        atak_launch
        log "emulator: re-ran ATAK's window focus after start"
        return 0
      fi
    done
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# The emulator draws its own window; opening ATAK means bringing it forward.
emu_front() {
  local pid; pid=$(emu_pid); [ -n "$pid" ] || return 0
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
}
