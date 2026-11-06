#!/usr/bin/env bash
# shellcheck shell=bash
# Linux host: Intel or AMD (x86-64) with KVM, the emulator runtime only. Google's Android
# Emulator and system image and Google's platform-tools (adb) are downloaded at the pinned
# versions in versions.env and verified. No Lima, no scrcpy, no redroid, no root: the one
# thing a user may have to do once is join the kvm group.

APP_NAME="TAKwerx ATAK Terminal"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
APP_ID=takwerx-atak-terminal
APP_DIR="$APPS_DIR/$APP_ID.desktop"   # the launcher entry; "the app" on this host
APP_LAUNCHER="$TAKWERX_BIN/takwerx-app"
# The redroid runtime's tools do not exist here. Defined so the shared code, which names them
# in places this host never reaches, runs under `set -u`.
LIMA_DIR="$TAKWERX_TOOLS/lima"
LIMACTL=""
SCRCPY_DIR=""
SCRCPY_BIN=""
# Google's platform-tools go where the emulator expects them: next to it, in the SDK root.
PLATFORM_TOOLS_DIR="$TAKWERX_TOOLS/android-sdk/platform-tools"
ADB_BIN="$PLATFORM_TOOLS_DIR/adb"

app_label() { printf '%s' "$APP_NAME"; }
app_home()  { printf 'your applications menu'; }

# Everything Linux needs checked before a single byte is downloaded.
host_check() {
  local c missing=()
  [ "$HOST_ARCH" = x86_64 ] || die "Linux on $(uname -m) is not supported: Google ships the Android Emulator for Linux on Intel and AMD (x86-64) only. A Mac with Apple Silicon or a Windows PC runs takwerx today"
  for c in curl unzip perl awk; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ "${#missing[@]}" -eq 0 ] || die "Missing tools: ${missing[*]}. Install them with your package manager (for example: sudo apt install ${missing[*]}), then run this again"
  kvm_check
  if [ "$(host_mem_gb)" -lt 8 ]; then die "This computer has $(host_mem_gb) GB of memory; takwerx needs 8 GB at least (16 GB is comfortable)"; fi
  [ "$(host_mem_gb)" -ge 16 ] || warn "$(host_mem_gb) GB of memory is below the 16 GB that is comfortable; Android gets $(emu_sizing | cut -d' ' -f1) MB of it"
  [ "$(host_cpus)" -ge 4 ] || warn "$(host_cpus) CPU threads; 4 or more is recommended"
  ok "Linux $(uname -r), $HOST_ARCH, $(host_mem_gb) GB, $(host_cpus) threads"
}

# The emulator uses KVM for speed and refuses to start without it. /dev/kvm is there when the
# CPU's virtualization is on in the firmware (and, in a cloud VM, when the VM allows nested
# virtualization); it is usable when the user is in the kvm group (or the device is open).
kvm_check() {
  if [ ! -e /dev/kvm ]; then
    die "/dev/kvm is missing, so Android cannot be accelerated. Turn on virtualization (Intel VT-x or AMD-V, sometimes called SVM) in the computer's BIOS/UEFI setup. In a virtual machine, its host must allow nested virtualization"
  fi
  if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    die "You are not allowed to use /dev/kvm. Run once: sudo usermod -aG kvm \$USER   then log out and back in, and run this again"
  fi
}

# Google's platform-tools (adb) at the pinned version, verified before they are unpacked.
host_tools_install() {
  local zip tmp
  if [ "$(tool_version "$PLATFORM_TOOLS_DIR")" != "$PLATFORM_TOOLS_LINUX_VERSION" ]; then
    zip="$TAKWERX_CACHE/platform-tools_r$PLATFORM_TOOLS_LINUX_VERSION-linux.zip"
    download "https://dl.google.com/android/repository/platform-tools_r$PLATFORM_TOOLS_LINUX_VERSION-linux.zip" "$zip" "$PLATFORM_TOOLS_LINUX_SHA256"
    tmp=$(mktemp -d "$TAKWERX_CACHE/unpack.XXXXXX")
    unzip -q -o "$zip" -d "$tmp" || { rm -rf "$tmp"; die "Could not unpack $(basename "$zip")"; }
    rm -rf "$PLATFORM_TOOLS_DIR"; mkdir -p "$(dirname "$PLATFORM_TOOLS_DIR")"
    mv "$tmp/platform-tools" "$PLATFORM_TOOLS_DIR"; rm -rf "$tmp"
    printf '%s\n' "$PLATFORM_TOOLS_LINUX_VERSION" >"$PLATFORM_TOOLS_DIR/.version"
  fi
  ok "adb (platform-tools $PLATFORM_TOOLS_LINUX_VERSION)"
}

# Puts `takwerx` on the PATH for new terminals. The launcher entry uses the same command.
path_setup() {
  ln -sfn "$TAKWERX_APP/takwerx" "$TAKWERX_BIN/takwerx"
  local line="export PATH=\"$TAKWERX_BIN:\$PATH\"" rc found=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    found=1
    grep -qF "$TAKWERX_BIN" "$rc" || printf '\n# takwerx\n%s\n' "$line" >>"$rc"
  done
  if [ "$found" = 0 ]; then printf '# takwerx\n%s\n' "$line" >"$HOME/.bashrc"; fi
}

# Android's position from the desktop's own location service, if it has one: GeoClue's
# demo client prints "Latitude: 12.3456789°", "Longitude: ...", "Accuracy: 20.0 meters".
# Most Linux desktops have none; then `takwerx location` takes coordinates or the IP.
mac_location() {
  local bin out lat lon acc
  for bin in /usr/libexec/geoclue-2.0/demos/where-am-i /usr/lib/geoclue-2.0/demos/where-am-i; do
    [ -x "$bin" ] && break
    bin=""
  done
  [ -n "$bin" ] || return 1
  out=$(with_timeout 20 "$bin" -t 15 2>/dev/null) || return 1
  lat=$(printf '%s' "$out" | sed -nE 's/^Latitude: *(-?[0-9.]+).*/\1/p' | head -n1)
  lon=$(printf '%s' "$out" | sed -nE 's/^Longitude: *(-?[0-9.]+).*/\1/p' | head -n1)
  acc=$(printf '%s' "$out" | sed -nE 's/^Accuracy: *([0-9]+).*/\1/p' | head -n1)
  [ -n "$lat" ] && [ -n "$lon" ] || return 1
  printf '%s,%s,%s\n' "$lat" "$lon" "${acc:-100}"
}

# ATAK's own launcher art from the APK the user downloaded (the same lookup as the Mac:
# app_icon_source, kept here because it is the host's), else takwerx's icon.
app_icon_source() {
  local apk entry
  apk=$(config_get ATAK_APK ""); [ -f "$apk" ] || apk=$(find_atak_apk)
  [ -f "${apk:-}" ] || return 1
  entry=$(unzip -p "$apk" resources.arsc 2>/dev/null | perl "$TAKWERX_APP/lib/apk-icon.pl" ic_atak_launcher 2>/dev/null || true)
  [ -n "$entry" ] || entry=$(unzip -l "$apk" 2>/dev/null | awk '$4 ~ /ic_atak_launcher\.png$/ {print $1, $4}' | sort -rn | head -n1 | cut -d' ' -f2)
  [ -n "$entry" ] || return 1
  mkdir -p "$TAKWERX_STATE/icon"
  unzip -p "$apk" "$entry" >"$TAKWERX_STATE/icon/source.png" 2>/dev/null && [ -s "$TAKWERX_STATE/icon/source.png" ]
}

# The launcher entry in the applications menu (and so the app grid and search). Generated
# here, on this computer, so there is nothing to trust or sign. It runs the engine without a
# terminal, as the Mac app does, with output in app.log.
app_build() {
  step "Creating the $APP_NAME launcher"
  local icon=$APP_ID
  mkdir -p "$APPS_DIR" "$TAKWERX_BIN" "$TAKWERX_LOGS"
  cat >"$APP_LAUNCHER" <<LAUNCHER
#!/bin/bash
# Launcher written by takwerx. Runs the engine without a terminal; output goes to the log.
export TAKWERX_FROM_APP=1
exec "$TAKWERX_BIN/takwerx" up >>"$TAKWERX_LOGS/app.log" 2>&1
LAUNCHER
  chmod +x "$APP_LAUNCHER"
  if app_icon_source; then
    mkdir -p "$ICONS_DIR/256x256/apps"
    cp -f "$TAKWERX_STATE/icon/source.png" "$ICONS_DIR/256x256/apps/$APP_ID.png"
    rm -f "$ICONS_DIR/scalable/apps/$APP_ID.svg"
  elif [ -f "$TAKWERX_APP/assets/icon.svg" ]; then
    mkdir -p "$ICONS_DIR/scalable/apps"
    cp -f "$TAKWERX_APP/assets/icon.svg" "$ICONS_DIR/scalable/apps/$APP_ID.svg"
  else
    icon=applications-internet
  fi
  cat >"$APP_DIR" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Real ATAK in a window on your desktop
Exec=$APP_LAUNCHER
Icon=$icon
Terminal=false
Categories=Utility;Network;
StartupNotify=false
DESKTOP
  chmod +x "$APP_DIR"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$ICONS_DIR" >/dev/null 2>&1 || true
  ok "$APP_NAME is in your applications menu"
}

app_remove() {
  rm -f "$APP_DIR" "$APP_LAUNCHER" "$ICONS_DIR/256x256/apps/$APP_ID.png" "$ICONS_DIR/scalable/apps/$APP_ID.svg"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
}
# Nothing outside the home folder was installed (no bridged networking on Linux).
bridged_remove() { return 0; }

host_doctor() {
  local c
  if [ "$HOST_ARCH" = x86_64 ]; then ok "Linux $(uname -r), $HOST_ARCH"; else warn "Linux on $(uname -m): Google's emulator needs Intel or AMD (x86-64)"; fi
  for c in curl unzip perl; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c"; else warn "$c is missing (install it with your package manager)"; fi
  done
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ok "KVM usable"
  elif [ -e /dev/kvm ]; then warn "/dev/kvm exists but you may not use it: sudo usermod -aG kvm \$USER, then log out and in"
  else warn "/dev/kvm is missing: turn on virtualization in the BIOS, or allow nested virtualization in the VM"; fi
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then ok "Desktop session ($([ -n "${WAYLAND_DISPLAY:-}" ] && echo Wayland || echo X11))"; else warn "No desktop session (DISPLAY is empty); the emulator will run without a window"; fi
  if [ -e /dev/dri/renderD128 ] || [ -e /dev/nvidia0 ]; then ok "A graphics device is present"; else warn "No graphics device (/dev/dri): Android is drawn by the processor, which is slow"; fi
  if [ -x "$ADB_BIN" ]; then ok "adb $(tool_version "$PLATFORM_TOOLS_DIR")"; else warn "adb not installed (takwerx init)"; fi
  if [ -f "$APP_DIR" ]; then ok "$APP_DIR"; else warn "Launcher not created yet (takwerx init)"; fi
}
