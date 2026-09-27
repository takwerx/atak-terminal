#!/usr/bin/env bash
# shellcheck shell=bash
# The GPU runtime: Google's Android Emulator on the Mac's own GPU, instead of redroid in the
# VM. Chosen with `takwerx runtime emulator`. Every flag and the driver swap below has its
# reason in docs/DECISIONS.md, 2026-09-26.
#
# Self-contained: takwerx downloads Google's emulator and system image and Khronos's MoltenVK
# from their release servers at the versions pinned in versions.env, verifies them, and
# creates the AVD itself. No Android Studio, no Homebrew, no Java. Google's SDK licence is
# shown and accepted once, in `takwerx init`.

EMU_SDK="$TAKWERX_TOOLS/android-sdk"
EMU_SYSIMG_DIR="$EMU_SDK/system-images/android-$SYSIMG_API/$SYSIMG_TAG/arm64-v8a"
EMU_MVK_DIR="$TAKWERX_TOOLS/moltenvk"
EMU_DIR="$TAKWERX_TOOLS/emulator"
EMU_AVD=$(config_get EMU_AVD terminal)
EMU_AVD_HOME=$(config_get EMU_AVD_HOME "$TAKWERX_ROOT/avd")
EMU_PORT=$(config_get EMU_PORT 5574)
EMU_LOG="$TAKWERX_LOGS/emulator.log"
# The host Vulkan driver under Android's ANGLE. MoltenVK: it ran a 10-minute zoom stress
# without a hang, at 25-44 fps in a busy view. KosmicKrisp (mesa 26.2.3) is faster, 41-53
# fps, but lost fences under heavy zooming every 5-15 minutes and the emulator aborted
# (VK_TIMEOUT); still available for development if Homebrew's mesa is present. The emulator
# bundles older copies of both (MoltenVK 1.4.0 cannot build ANGLE's pipelines at all).
EMU_VK=$(config_get EMU_VK moltenvk)
# Extra emulator feature flags, comma-separated, for trials: e.g. "-VulkanNativeSwapchain"
# takes the host's native swapchain out of the presentation path, the suspect for ATAK's
# occasional "isn't responding" (DECISIONS 2026-09-26).
EMU_FEATURES=$(config_get EMU_FEATURES "")
# Extra emulator arguments, for trials only. "-grpc 8554" opens the emulator's gRPC bridge,
# which is how Extended Controls is opened without a click (DECISIONS 2026-09-27). Never
# set by default: -grpc listens on every interface, unauthenticated.
EMU_ARGS=$(config_get EMU_ARGS "")
# Google apps the image ships that the terminal has no use for. Off at provisioning, so
# they neither sit in memory nor fill the dock; Chrome stays. Override in the config to
# keep some, or set it empty to keep them all. Play services is in the list: its location
# providers take every GNSS fix and each one failed to reach its own dead callback, a
# 15-line stack trace up to 300 times a second in the system log (2026-09-26). Without
# it ATAK's GPS feed is untouched (the GNSS service is Android's), Chrome opens pages,
# and only a Google-account sign-in inside Chrome is lost. Settings Services
# (settings.intelligence) goes with it: it is what posts "Enable Google Play services"
# once Play services is off.
EMU_TRIM_APPS=$(config_get EMU_TRIM_APPS "com.google.android.gms com.google.android.gm com.google.android.youtube
  com.google.android.apps.youtube.music com.google.android.apps.photos
  com.google.android.apps.messaging com.google.android.dialer
  com.google.android.googlequicksearchbox com.google.android.apps.wellbeing
  com.google.android.apps.maps com.google.android.apps.docs com.google.android.calendar
  com.google.android.contacts com.google.android.deskclock com.google.android.as
  com.google.android.as.oss com.google.android.projection.gearhead
  com.google.android.settings.intelligence")
EMU_MVK_LIB="$EMU_MVK_DIR/libMoltenVK.dylib"
EMU_KK_LIB=/opt/homebrew/opt/mesa/lib/libvulkan_kosmickrisp.dylib
ANDROID_SDK_TERMS=https://developer.android.com/studio/terms

runtime() { config_get RUNTIME "$RUNTIME_DEFAULT"; }

# The emulator registers with the adb server named by ANDROID_ADB_SERVER_PORT when it
# starts, which common.sh points at takwerx's private server, so it appears there by serial.
if [ "$(runtime)" = emulator ]; then ADB_ENDPOINT="emulator-$EMU_PORT"; fi

emu_installed() { [ -x "$EMU_SDK/emulator/emulator" ] && [ -f "$EMU_SYSIMG_DIR/system.img" ] && [ -f "$EMU_MVK_LIB" ]; }

# Google's packages come from the same repository the SDK manager reads, under the same
# licence, which the SDK manager makes you accept and so does this. Once per install.
emu_license() {
  [ "$(config_get ANDROID_SDK_LICENSE)" = accepted ] && return 0
  printf '\n%sThe Android Emulator and its system image are Google'"'"'s, under the Android SDK licence:%s\n  %s\n' "$BOLD" "$NC" "$ANDROID_SDK_TERMS"
  if ! have_tty; then die "Accept the Android SDK licence first: run 'takwerx init' in a terminal"; fi
  confirm "Accept it and download them (about 2 GB)?" || die "The GPU runtime needs Google's emulator; declined"
  config_set ANDROID_SDK_LICENSE accepted
}

sha1_of() { shasum -a 1 "$1" | cut -d' ' -f1; }
verify_sha1() {
  local file=$1 want=$2 have
  have=$(sha1_of "$file")
  [ "$have" = "$want" ] || { rm -f "$file"; die "Checksum mismatch for $(basename "$file") (got $have, want $want); the download is deleted, run again"; }
}

# Emulator, system image and MoltenVK into ~/.takwerx/tools, each with a .version, each
# re-fetched only when its pin changes.
emu_sdk_install() {
  local zip tmp
  if [ "$(tool_version "$EMU_SDK/emulator")" != "$EMULATOR_VERSION" ]; then
    emu_license
    zip="$TAKWERX_CACHE/emulator-darwin_aarch64-$EMULATOR_BUILD.zip"
    download "https://dl.google.com/android/repository/emulator-darwin_aarch64-$EMULATOR_BUILD.zip" "$zip"
    verify_sha1 "$zip" "$EMULATOR_SHA1"
    step "Unpacking the emulator $EMULATOR_VERSION"
    tmp=$(mktemp -d "$TAKWERX_CACHE/unpack.XXXXXX")
    unzip -q -o "$zip" -d "$tmp" || die "Could not unpack $(basename "$zip")"
    rm -rf "$EMU_SDK/emulator"; mkdir -p "$EMU_SDK"; mv "$tmp/emulator" "$EMU_SDK/emulator"; rm -rf "$tmp"
    printf '%s\n' "$EMULATOR_VERSION" >"$EMU_SDK/emulator/.version"
    rm -rf "$EMU_DIR"  # the private copy is rebuilt from this
  fi
  ok "Android Emulator $EMULATOR_VERSION"
  if [ "$(tool_version "$EMU_SYSIMG_DIR")" != "$SYSIMG_REV" ]; then
    emu_license
    zip="$TAKWERX_CACHE/arm64-v8a-${SYSIMG_API}_r$SYSIMG_REV.zip"
    download "https://dl.google.com/android/repository/sys-img/$SYSIMG_TAG/arm64-v8a-${SYSIMG_API}_r$SYSIMG_REV.zip" "$zip"
    verify_sha1 "$zip" "$SYSIMG_SHA1"
    step "Unpacking Android $SYSIMG_API"
    tmp=$(mktemp -d "$TAKWERX_CACHE/unpack.XXXXXX")
    unzip -q -o "$zip" -d "$tmp" || die "Could not unpack $(basename "$zip")"
    rm -rf "$EMU_SYSIMG_DIR"; mkdir -p "$(dirname "$EMU_SYSIMG_DIR")"; mv "$tmp/arm64-v8a" "$EMU_SYSIMG_DIR"; rm -rf "$tmp"
    printf '%s\n' "$SYSIMG_REV" >"$EMU_SYSIMG_DIR/.version"
  fi
  ok "Android $SYSIMG_API system image r$SYSIMG_REV"
  if [ "$(tool_version "$EMU_MVK_DIR")" != "$MOLTENVK_VERSION" ]; then
    zip="$TAKWERX_CACHE/MoltenVK-macos-$MOLTENVK_VERSION.tar"
    download "https://github.com/KhronosGroup/MoltenVK/releases/download/v$MOLTENVK_VERSION/MoltenVK-macos.tar" "$zip"
    verify_sha1 "$zip" "$MOLTENVK_SHA1"
    rm -rf "$EMU_MVK_DIR"; mkdir -p "$EMU_MVK_DIR"
    tar -xf "$zip" -C "$EMU_MVK_DIR" --strip-components=5 MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib \
      && tar -xf "$zip" -C "$EMU_MVK_DIR" --strip-components=1 MoltenVK/LICENSE || die "Could not unpack MoltenVK"
    printf '%s\n' "$MOLTENVK_VERSION" >"$EMU_MVK_DIR/.version"
    rm -rf "$EMU_DIR"
  fi
  ok "MoltenVK $MOLTENVK_VERSION"
}

# takwerx's own copy of the emulator with the drivers it should have. The emulator loads
# lib64/vulkan/<driver>.dylib by file name and ignores the ICD json's library_path, so the
# files themselves are replaced -- in this copy, never in the unpacked SDK. An APFS clone, so
# it costs no disk. Rebuilt when any version changes.
# The emulator calls an SDK root without a platform-tools directory "broken" and refuses to
# start. It wants adb there; scrcpy's adb is the one takwerx uses everywhere, so it is that.
emu_sdk_layout() {
  mkdir -p "$EMU_SDK/platform-tools"
  [ -e "$EMU_SDK/platform-tools/adb" ] || ln -sfn "$ADB" "$EMU_SDK/platform-tools/adb"
}

# The trailing tag is emu_prepare's own revision: bump it when the copy is built differently.
emu_copy_revision() { printf 'emulator %s, moltenvk %s, r12\n' "$EMULATOR_VERSION" "$MOLTENVK_VERSION"; }
emu_copy_current()  { [ "$(tool_version "$EMU_DIR")" = "$(emu_copy_revision)" ]; }

emu_prepare() {
  local want
  emu_installed || emu_sdk_install
  emu_sdk_layout
  case "$EMU_VK" in
    moltenvk) ;;
    kosmickrisp) [ -f "$EMU_KK_LIB" ] || die "KosmicKrisp is missing; it is Homebrew's mesa, for development only" ;;
    *) die "EMU_VK must be moltenvk or kosmickrisp (is '$EMU_VK')" ;;
  esac
  want=$(emu_copy_revision)
  if [ "$(tool_version "$EMU_DIR")" != "$want" ]; then
    step "Preparing the GPU emulator ($want)"
    rm -rf "$EMU_DIR"
    cp -Rc "$EMU_SDK/emulator" "$EMU_DIR" 2>/dev/null || cp -R "$EMU_SDK/emulator" "$EMU_DIR" || die "Could not copy the emulator"
    cp -f "$EMU_MVK_LIB" "$EMU_DIR/lib64/vulkan/libMoltenVK.dylib" || die "Could not install MoltenVK into the emulator"
    if [ -f "$EMU_KK_LIB" ]; then cp -f "$EMU_KK_LIB" "$EMU_DIR/lib64/vulkan/libvulkan_kosmickrisp.dylib" || true; fi
    emu_retitle
    emu_bundle
    printf '%s\n' "$want" >"$EMU_DIR/.version"
  fi
}

# The window is titled from one format string, "%s Emulator - %s:%d" (product, AVD, port).
# It becomes "TAKwerx ATAK Terminal" in this copy: two characters longer than the slot, so
# it runs into the string that follows, "%s: %dx%d\n", a debug-only log format, which
# becomes "l". printf ignores the arguments neither string uses any more. The edit breaks
# Google's signature, so the copy is signed again locally with the entitlements it had (the
# hypervisor, and library validation off, which is also what lets it load the swapped
# drivers). macOS then sees a new app and may ask once for Local Network access. A failed
# patch leaves the stock title, nothing worse.
# The same pass takes away the emulator's own Dock icon: skin_winsys_set_window_icon
# hands Qt the Android-on-a-device picture at start (three PNGs compiled into the
# binary, emulator_icon_32/128/256.png, found by name in a table), and on macOS that
# sets the Dock tile over the app's icon. The three PNGs, each the only one of its size,
# get their first signature byte zeroed: the pixmap fails to load, the QIcon is null,
# Qt sets nothing, and the Dock keeps the app's icon, ATAK's. The slots are too small
# for ATAK's art itself (7.5 KB for 256 px). Misspelling the Qt resource name
# :/all/android_studio_icon, tried first, changed nothing: that is a different picture
# (2026-09-26).
# The same pass takes Qt's own path file out of the binary. A qt.conf is compiled in as
# a Qt resource, "Prefix = ../../lib64/qt": relative to the executable's directory, or
# to Contents/ for an executable inside an app, so from the app it names
# /Applications/lib64/qt. Nothing the emulator draws reads it (the launcher hands Qt its
# plugin directory), but the Location page of Extended Controls, the "..." button, is a
# Chromium view: it looked under that prefix for its helper process, found nothing and
# aborted the whole emulator, the first crash reported from the field; and its sandbox
# lets the helper read files only under that prefix, so pointing the helper elsewhere is
# not enough. One letter of the resource's name is changed (qt.conf to qt.conx): Qt then
# finds no qt.conf and does what it does everywhere else, takes the directory QtCore was
# loaded from, lib64/qt in the copy, the same answer the stock layout gives. Checked
# after signing; without it the emulator still runs, and the map stays blank
# (DECISIONS 2026-09-27).
emu_retitle() {
  local bin="$EMU_DIR/qemu/darwin-aarch64/qemu-system-aarch64" ent="$TAKWERX_STATE/emulator.entitlements"
  codesign -d --entitlements :- "$bin" >"$ent" 2>/dev/null && [ -s "$ent" ] || { warn "Could not read the emulator's entitlements; keeping its title"; return 0; }
  cp -p "$bin" "$bin.orig"
  perl -0777 -pi -e 's/%s Emulator - %s:%d\x00%s: %dx%d\n\x00/TAKwerx ATAK Terminal\x00: %dx%d\n\x00/;
    s/\x89(PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x20\x00\x00\x00\x20)/\x00$1/;
    s/\x89(PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x80\x00\x00\x00\x80)/\x00$1/;
    s/\x89(PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x01\x00\x00\x00\x01\x00)/\x00$1/;
    s/(\x00\x07.{4}\x00q\x00t\x00\.\x00c\x00o\x00n\x00)f/${1}x/s' "$bin"
  if cmp -s "$bin" "$bin.orig" || ! codesign --force --sign - --options runtime --entitlements "$ent" "$bin" >/dev/null 2>&1; then
    warn "Could not retitle the emulator window; keeping its title"
    mv -f "$bin.orig" "$bin"; return 0
  fi
  rm -f "$bin.orig"
  perl -0777 -ne 'exit(index($_, "\x00q\x00t\x00.\x00c\x00o\x00n\x00x") < 0)' "$bin" \
    || warn "Could not take Qt's path file out of the emulator; the map in Extended Controls will be blank"
}

# macOS names a running program after its app bundle, or after the executable file when
# there is none: "qemu-system-aarch64" in the Dock and at the top left of the screen,
# and a second Dock tile next to the pinned app. So the emulator runs from inside
# "TAKwerx ATAK Terminal.app" in Applications: the one app is what the user clicks and
# what runs, one tile, one name, the ATAK icon. The launcher execs the binary at a fixed
# path in the emulator copy, so that file becomes a two-line shell script that execs the
# copy inside the app. A symlink is not enough: macOS goes by the path exec'd, not where
# it leads (tried 2026-09-26). The launcher's DYLD_LIBRARY_PATH does not survive
# /bin/sh, which macOS strips of DYLD_* as a system binary, so the script sets it again
# from the launcher directory; without it dyld cannot find libandroid-emu-tracing. The
# retitled, signed binary stays in the copy as qemu-system-aarch64.bin, so the app can be
# rebuilt from it at any time (emu_start checks).
# The script also tells Qt WebEngine where its helper process and resources are, in Qt's
# own three variables. With Qt's path file taken out of the binary (emu_retitle) Qt works
# that out itself; these are the second line of defence for a build where that patch does
# not apply: the emulator then does not abort on the "..." button, only the map stays
# blank. A qt.conf in the app cannot do this: the compiled-in one is read first
# (DECISIONS 2026-09-27).
emu_bundle() {
  local dir="$EMU_DIR/qemu/darwin-aarch64" bin mac="$APP_DIR/Contents/MacOS"
  bin="$dir/qemu-system-aarch64"
  [ -d "$APP_DIR" ] || app_build
  if [ ! -f "$dir/qemu-system-aarch64.bin" ]; then
    mv -f "$bin" "$dir/qemu-system-aarch64.bin" || die "Could not set the emulator aside"
  fi
  mkdir -p "$mac"
  cp -cf "$dir/qemu-system-aarch64.bin" "$mac/qemu-system-aarch64" 2>/dev/null \
    || cp -f "$dir/qemu-system-aarch64.bin" "$mac/qemu-system-aarch64" || die "Could not put the emulator into $APP_NAME.app"
  cat >"$bin" <<WRAP
#!/bin/sh
# Written by takwerx. Starts the emulator from inside $APP_NAME.app, so macOS names it
# and draws its icon from that app instead of showing "qemu-system-aarch64". The
# launcher's DYLD_LIBRARY_PATH does not survive /bin/sh (macOS strips DYLD_* for system
# binaries), so it is set again here from the launcher directory.
E=\${ANDROID_EMULATOR_LAUNCHER_DIR:-\$(cd "\$(dirname "\$0")/../.." && pwd)}
export DYLD_LIBRARY_PATH="\$E/lib64/qt/lib:\$E/lib64/vulkan:\$E/lib64/gles_angle:\$E/lib64"
# Where Qt WebEngine (the Location page of Extended Controls) finds its helper process
# and resources, should Qt's own prefix be wrong from inside the app; without them Qt
# would look in /Applications/lib64/qt and abort the emulator.
export QTWEBENGINEPROCESS_PATH="\$E/lib64/qt/libexec/QtWebEngineProcess"
export QTWEBENGINE_RESOURCES_PATH="\$E/lib64/qt/resources"
export QTWEBENGINE_LOCALES_PATH="\$E/lib64/qt/translations/qtwebengine_locales"
exec "$mac/qemu-system-aarch64" "\$@"
WRAP
  chmod +x "$bin"
  app_sign
}

# ATAK pinned in Android's dock next to Chrome. The launcher keeps its dock in a SQLite
# database (one per grid size, launcher_<cols>_by_<rows>.db); a row with container -101
# is a dock slot. ATAK goes in slot 0, Chrome sits in slot 1 after the trim, and the
# launcher restarts to read it. What users saw before was the taskbar's "recent app"
# tile, there only while ATAK runs (2026-09-27). Needs root; skipped without it.
emu_dock_atak() {
  local db act now
  "$ADB" -s "$ADB_ENDPOINT" root >/dev/null 2>&1 || return 0
  with_timeout 30 "$ADB" -s "$ADB_ENDPOINT" wait-for-device >/dev/null 2>&1 || true
  db=$(adb_sh 'ls /data/data/com.google.android.apps.nexuslauncher/databases/launcher*.db 2>/dev/null' | head -n1)
  [ -n "$db" ] || return 0
  act=$(adb_sh cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$ATAK_PACKAGE" 2>/dev/null | tail -n1)
  [ -n "$act" ] || return 0
  adb_sh "sqlite3 $db \"select count(*) from favorites where container=-101 and intent like '%$ATAK_PACKAGE%'\"" 2>/dev/null | grep -q '^[1-9]' && return 0
  now=$(date +%s)000
  adb_sh "sqlite3 $db \"insert into favorites (title,intent,container,screen,cellX,cellY,spanX,spanY,itemType,appWidgetId,modified,restored,profileId,rank,options) values ('ATAK','#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;launchFlags=0x10200000;component=$act;end',-101,0,0,0,1,1,0,-1,$now,0,0,0,0)\"" >/dev/null 2>&1 || return 0
  adb_sh am force-stop com.google.android.apps.nexuslauncher >/dev/null 2>&1 || true
  log "ATAK pinned in Android's dock"
}

# The app's emulator copy is gone (the app was deleted or rebuilt from scratch): put it back.
emu_bundle_check() {
  [ -f "$EMU_DIR/qemu/darwin-aarch64/qemu-system-aarch64.bin" ] || return 0
  [ -f "$APP_DIR/Contents/MacOS/qemu-system-aarch64" ] || emu_bundle
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

# The AVD, written by hand: the same settings as the one this was developed on, with RAM
# and cores from the host. No Java, so no avdmanager. The emulator makes the data and cache
# images itself from the system image on first boot. No SD card: ATAK's /sdcard is the
# emulated storage on the data partition.
# Guest RAM and cores. A third of the Mac's memory, 4 to 8 GiB: at a quarter, a 16 GiB
# MacBook gave Android 4 GiB, which sat at 500 MiB free with swap in use once ATAK and
# the Google apps were up, and the display stack restarted under it (2026-09-26). Cores
# half the host's, 2 to 4. Re-applied to an existing AVD on every start (emu_configure_avd)
# so an older install picks the numbers up.
emu_sizing() {
  echo "$(clamp $(( $(host_mem_gb) * 1024 / 3 )) 4096 8192) $(clamp $(( $(host_cpus) / 2 )) 2 4)"
}

emu_avd_create() {
  local dir="$EMU_AVD_HOME/$EMU_AVD.avd" ram cores
  [ -f "$dir/config.ini" ] && return 0
  step "Creating the Android device ($EMU_AVD)"
  read -r ram cores <<<"$(emu_sizing)"
  mkdir -p "$dir"
  cat >"$EMU_AVD_HOME/$EMU_AVD.ini" <<INI
avd.ini.encoding=UTF-8
path=$dir
path.rel=avd/$EMU_AVD.avd
target=android-$SYSIMG_API
INI
  cat >"$dir/config.ini" <<INI
AvdId=$EMU_AVD
avd.ini.displayname=TAKwerx ATAK Terminal
avd.ini.encoding=UTF-8
PlayStore.enabled=no
abi.type=arm64-v8a
disk.dataPartition.size=10G
fastboot.forceColdBoot=yes
fastboot.forceFastBoot=no
hw.accelerometer=yes
hw.arc=false
hw.audioInput=yes
hw.audioOutput=yes
hw.battery=yes
hw.camera.back=none
hw.camera.front=none
hw.cpu.arch=arm64
hw.cpu.ncore=$cores
hw.dPad=no
hw.gps=yes
hw.gpu.enabled=yes
hw.gpu.mode=host
hw.gsmModem=yes
hw.gyroscope=yes
hw.initialOrientation=landscape
hw.keyboard=yes
hw.keyboard.charmap=qwerty2
hw.keyboard.lid=yes
hw.lcd.backlight=yes
hw.lcd.depth=32
hw.lcd.vsync=60
hw.mainKeys=no
hw.ramSize=$ram
hw.screen=multi-touch
hw.sdCard=no
hw.sensors.magnetic_field=yes
hw.sensors.orientation=yes
hw.sensors.proximity=no
hw.trackBall=no
hw.useext4=yes
image.sysdir.1=system-images/android-$SYSIMG_API/$SYSIMG_TAG/arm64-v8a/
kernel.newDeviceNaming=autodetect
kernel.supportsYaffs2=autodetect
showDeviceFrame=no
skin.dynamic=yes
tag.display=Google APIs
tag.id=$SYSIMG_TAG
target=android-$SYSIMG_API
vm.heapSize=256M
INI
  ok "Device $EMU_AVD: $cores cores, $ram MB"
}

# Written into the AVD before every boot, since the emulator reads the screen from it. The
# physical density is three quarters of the UI density: ATAK draws its map at the smaller of
# the two, and 150 against 200 is what redroid runs at (DECISIONS 2026-09-26). Every existing
# hw.lcd line goes first; appended duplicates are otherwise read last-wins.
emu_configure_avd() {
  local ini="$EMU_AVD_HOME/$EMU_AVD.avd/config.ini" w h dpi ram cores
  [ -f "$ini" ] || die "No AVD named $EMU_AVD (expected $ini)"
  read -r w h dpi <<<"$(emu_geometry)"
  read -r ram cores <<<"$(emu_sizing)"
  { grep -vE '^(hw\.lcd\.(width|height|density)|hw\.ramSize|hw\.cpu\.ncore)[[:space:]]*=' "$ini"
    printf 'hw.lcd.width=%s\nhw.lcd.height=%s\nhw.lcd.density=%s\nhw.ramSize=%s\nhw.cpu.ncore=%s\n' \
      "$w" "$h" $(( dpi * 3 / 4 )) "$ram" "$cores"; } >"$ini.tmp" && mv "$ini.tmp" "$ini"
  log "emulator screen ${w}x${h}, ui dpi $dpi, ${ram} MiB, ${cores} cores"
}

emu_pid()     { pgrep -f "qemu-system-aarch64 -avd $EMU_AVD " | head -n1; }
emu_running() { [ -n "$(emu_pid)" ]; }

# Guest ANGLE on Vulkan on a Metal driver: the only path found where ATAK both runs on the
# GPU and draws icons wider than 64 px. VirtioTablet makes the host pointer a real mouse in
# Android (wheel as ACTION_SCROLL, buttons, hover) instead of synthetic touch swipes.
# -WiFiPacketStream keeps Android's Wi-Fi on the emulator's own network stack instead of
# streaming every packet to the netsim process: inside Android a small request took about
# 800 ms that way against 41 ms without, and downloads ran at 3-4 MB/s against 8-10, which
# is why map tiles arrived slowly (DECISIONS 2026-09-27). Android still sees a validated
# Wi-Fi network; only netsim's device-to-device simulation is lost, which nothing here uses.
# No -grpc: it listens on every interface with no authentication.
emu_start() {
  [ -x "$ADB" ] || die "adb is missing (scrcpy is not installed). Run: takwerx init"
  emu_running && return 0
  emu_prepare
  emu_bundle_check
  mkdir -p "$EMU_AVD_HOME"
  emu_avd_create
  rm -f "$EMU_AVD_HOME/$EMU_AVD.avd/"*.lock
  emu_configure_avd
  step "Starting Android on the GPU ($EMU_AVD, $(emu_geometry | awk '{print $1"x"$2" at "$3" dpi"}'))"
  log "emulator start: $(tool_version "$EMU_DIR")${EMU_FEATURES:+, features $EMU_FEATURES}${EMU_ARGS:+, args $EMU_ARGS}"
  # shellcheck disable=SC2086  # EMU_ARGS is a list of arguments
  ANDROID_SDK_ROOT="$EMU_SDK" ANDROID_HOME="$EMU_SDK" ANDROID_AVD_HOME="$EMU_AVD_HOME" ANDROID_EMU_VK_SELECT_ICD="$EMU_VK" \
    nohup "$EMU_DIR/emulator" -avd "$EMU_AVD" -port "$EMU_PORT" -gpu host \
      -feature "Vulkan,GuestAngle,VirtioTablet,-WiFiPacketStream${EMU_FEATURES:+,$EMU_FEATURES}" -no-snapshot -no-boot-anim $EMU_ARGS \
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
# The stock Google apps: each one that is still enabled is switched off for the user.
# Cheap and idempotent, so it runs on every boot. A 16 GiB MacBook's 4 GiB guest had
# the Google app, YouTube, Wellbeing and System Intelligence resident at 80 to 180 MiB
# each while it swapped (2026-09-26).
emu_trim_apps() {
  local pkg enabled n=0
  [ -n "$EMU_TRIM_APPS" ] || return 0
  enabled=$(adb_sh pm list packages -e --user 0 2>/dev/null | sed 's/^package://')
  for pkg in $EMU_TRIM_APPS; do
    echo "$enabled" | grep -qx "$pkg" || continue
    adb_sh pm disable-user --user 0 "$pkg" >/dev/null 2>&1 && n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then
    log "switched off $n Google apps (Chrome stays)"
    # The taskbar keeps showing the old dock until the launcher restarts.
    adb_sh am force-stop com.google.android.apps.nexuslauncher >/dev/null 2>&1 || true
  fi
  return 0
}

emu_provision() {
  local tz w h dpi
  emu_trim_apps
  if atak_installed; then atak_grant; fi
  # Chrome on guest ANGLE: its GPU process cannot create the native fence sync objects
  # the SurfaceControl path needs ("Failed to create android native fence sync object",
  # then the GPU context is lost), exits, and restarts about every two seconds. Pages
  # showed black and the screen flashed (2026-09-26). Chrome reads this file on a
  # debuggable image, which the google_apis image is. ATAK's WebView is unaffected.
  adb_sh "echo 'chrome --disable-features=AndroidSurfaceControl' > /data/local/tmp/chrome-command-line; chmod 644 /data/local/tmp/chrome-command-line" >/dev/null 2>&1 || true
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
  # Dark mode, so ATAK's toasts are readable (the light toast draws white on white).
  adb_sh cmd uimode night yes >/dev/null 2>&1 || true
  # SystemUI restarts on every boot, after the two settings above. It starts before
  # provisioning can set ANGLE's override, and without it its shaders fail to compile
  # on MoltenVK: 70 log lines a second, and the same pipeline failure preceded a
  # display-stack restart on the MacBook. It also keeps the theme it started with for
  # the toasts it draws: after the dark-mode switch they were an empty pill until it
  # restarted (2026-09-26). Two seconds of status bar at boot, before ATAK is up.
  adb_sh pkill -f com.android.systemui >/dev/null 2>&1 || true
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
  # After takwerx update the emulator that is already running is the old build; the new
  # copy is made at the next start.
  if emu_running && ! emu_copy_current; then warn "Android is running the previous emulator build; takwerx restart loads the new one"; fi
  emu_start
  if ! android_online || ! android_booted; then
    step "Waiting for Android to boot"
    emu_wait 300 || die "Android did not come up (the emulator exited or took over 5 minutes). See $EMU_LOG"
  fi
  ok "Android is up"
  emu_awake
  emu_provision
  emu_location_apply
  emu_watchdog
}

# Until the presentation stall has a cause (DECISIONS 2026-09-26): when Android reports
# ATAK not responding, ATAK is restarted, which is what a person would do next. Polls the
# events log every 10 s; one restart per event; ends with the emulator.
emu_watchdog() {
  local pid; pid=$(emu_pid); [ -n "$pid" ] || return 0
  pgrep -f "takwerx-watchdog $pid" >/dev/null 2>&1 && return 0
  (
    exec -a "takwerx-watchdog $pid" bash -c '
      A=$1; D=$2; PKG=$3; LOGF=$4; QPID=$5; last=""
      while kill -0 "$QPID" 2>/dev/null; do
        sleep 10
        ev=$("$A" -s "$D" shell "logcat -b events -d -t 200" 2>/dev/null | grep -E "am_anr.*$PKG" | tail -n1)
        [ -n "$ev" ] && [ "$ev" != "$last" ] || continue
        last=$ev
        printf "%s watchdog: ATAK not responding; restarting it
" "$(date "+%F %T")" >>"$LOGF"
        "$A" -s "$D" shell am force-stop "$PKG" >/dev/null 2>&1
        sleep 2
        act=$("$A" -s "$D" shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$PKG" 2>/dev/null | tail -n1 | tr -d "
")
        [ -n "$act" ] && "$A" -s "$D" shell am start -n "$act" >/dev/null 2>&1
        sleep 25
        "$A" -s "$D" shell input keyevent KEYCODE_HOME >/dev/null 2>&1; sleep 1
        [ -n "$act" ] && "$A" -s "$D" shell am start -n "$act" >/dev/null 2>&1
        # ATAK counts the force-stop as an unclean exit and asks whether to load plugins.
        # Load them: the user did not choose to lose them. Up to 40 s for the box.
        for i in 1 2 3 4 5 6 7 8; do
          sleep 5
          box=$("$A" -s "$D" shell "uiautomator dump /sdcard/takwerx-ui.xml >/dev/null 2>&1; cat /sdcard/takwerx-ui.xml" 2>/dev/null | tr ">" "\n" | grep -E "text=\"Load Plugins\"" | grep -oE "bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" | grep -oE "[0-9]+" | paste -sd" " -)
          [ -n "$box" ] || continue
          set -- $box; "$A" -s "$D" shell input tap $(( ($1+$3)/2 )) $(( ($2+$4)/2 )) >/dev/null 2>&1
          printf "%s watchdog: answered the load-plugins question\n" "$(date "+%F %T")" >>"$LOGF"
          break
        done
      done' _ "$ADB" "$ADB_ENDPOINT" "$ATAK_PACKAGE" "$LOG_FILE" "$pid"
  ) >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
}

# The display stays on while the Terminal runs. When the Mac's display went to sleep and
# came back (18:28 to 18:55 on 2026-09-26), the emulator rebuilt its window surface and
# ATAK answered its first input 28 s later with "isn't responding". A map terminal is
# something one looks at; it does not go dark. caffeinate ends with the emulator.
emu_awake() {
  local pid; pid=$(emu_pid); [ -n "$pid" ] || return 0
  pgrep -f "caffeinate -d -i -w $pid" >/dev/null 2>&1 && return 0
  nohup caffeinate -d -i -w "$pid" >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
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

# ATAK sets shouldLoad-<package>=false on every plugin (re)install and asks in its Plugins
# screen. On this runtime adb root is available, so a plugin installed with `takwerx plugin`
# is switched on and ATAK restarted; the user chose to install it. Unrooted, it is the
# Plugins screen, as on a phone.
emu_plugins_enable() {
  local prefs=/data/data/$ATAK_PACKAGE/shared_prefs/${ATAK_PACKAGE}_preferences.xml
  "$ADB" -s "$ADB_ENDPOINT" root >/dev/null 2>&1 || return 0
  with_timeout 30 "$ADB" -s "$ADB_ENDPOINT" wait-for-device >/dev/null 2>&1 || true
  atak_quit
  # No prefs file before ATAK's first run: nothing to switch, ATAK asks on first start.
  adb_sh "sed -i 's|\"shouldLoad-\\([^\"]*\\)\" value=\"false\"|\"shouldLoad-\\1\" value=\"true\"|g' $prefs" >/dev/null 2>&1 || true
  # A plugin ATAK has registered but never been answered about has no entry at all and
  # is "!should load, skipping" (Map Depot on the MacBook, 2026-09-26): one is added for
  # every installed plugin package that lacks one.
  local pkg
  for pkg in $(adb_sh pm list packages 2>/dev/null | sed -n 's/^package:\(com\.atakmap\.android\..*\.plugin\)$/\1/p'); do
    adb_sh "grep -q 'shouldLoad-$pkg\"' $prefs || sed -i 's|</map>|    <boolean name=\"shouldLoad-$pkg\" value=\"true\" />\n</map>|' $prefs" >/dev/null 2>&1 || true
  done
  atak_launch
  emu_focus_fix
  ok "Plugin switched on; ATAK is restarting"
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
