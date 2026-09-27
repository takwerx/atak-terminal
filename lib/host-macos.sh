#!/usr/bin/env bash
# shellcheck shell=bash
# macOS host: vendored tools, bridged networking through socket_vmnet, and the app bundle.

LIMA_DIR="$TAKWERX_TOOLS/lima"
SCRCPY_DIR="$TAKWERX_TOOLS/scrcpy"
LIMACTL="$LIMA_DIR/bin/limactl"
SCRCPY_BIN="$SCRCPY_DIR/scrcpy"
SOCKET_VMNET_BIN=/opt/socket_vmnet/bin/socket_vmnet
LIMA_SUDOERS=/private/etc/sudoers.d/lima
APP_NAME="TAKwerx ATAK Terminal"
if [ -w /Applications ]; then APP_DIR="/Applications/$APP_NAME.app"; else APP_DIR="$HOME/Applications/$APP_NAME.app"; fi

host_check() {
  local ver major
  ver=$(sw_vers -productVersion); major=${ver%%.*}
  if [ "$major" -lt 13 ]; then die "macOS 13 or newer is required (this Mac runs $ver)"; fi
  # Downloaded as a ZIP from GitHub in a browser, every file carries the quarantine flag and
  # macOS refuses to run the maclocation helper. The curl one-liner never sets the flag; a
  # browser download does. Cleared here, on takwerx's own files only.
  xattr -dr com.apple.quarantine "$TAKWERX_APP" 2>/dev/null || true
  chmod +x "$TAKWERX_APP/takwerx" "$TAKWERX_APP/helpers/maclocation/maclocation" 2>/dev/null || true
  ok "macOS $ver, $HOST_ARCH"
}

# Lima (the VM manager) and scrcpy (the window, with its own adb) are downloaded from their
# GitHub releases at pinned versions. Nothing is installed system-wide and Homebrew is not used.
host_tools_install() {
  local tgz
  if [ "$(tool_version "$LIMA_DIR")" != "$LIMA_VERSION" ]; then
    tgz="$TAKWERX_CACHE/lima-$LIMA_VERSION-Darwin-$HOST_ARCH.tar.gz"
    download "https://github.com/lima-vm/lima/releases/download/v$LIMA_VERSION/lima-$LIMA_VERSION-Darwin-$HOST_ARCH.tar.gz" "$tgz"
    unpack_to "$tgz" "$LIMA_DIR" "$LIMA_VERSION"
  fi
  ok "Lima $LIMA_VERSION"
  if [ "$(tool_version "$SCRCPY_DIR")" != "$SCRCPY_VERSION" ]; then
    tgz="$TAKWERX_CACHE/scrcpy-macos-$SCRCPY_ARCH-v$SCRCPY_VERSION.tar.gz"
    download "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY_VERSION/scrcpy-macos-$SCRCPY_ARCH-v$SCRCPY_VERSION.tar.gz" "$tgz"
    unpack_to "$tgz" "$SCRCPY_DIR" "$SCRCPY_VERSION" 1
  fi
  ok "scrcpy $SCRCPY_VERSION"
}

# Puts `takwerx` on the PATH for new terminals. The app icon uses the same launcher.
path_setup() {
  ln -sfn "$TAKWERX_APP/takwerx" "$TAKWERX_BIN/takwerx"
  local line="export PATH=\"$TAKWERX_BIN:\$PATH\"" rc found=0
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
    if [ -f "$rc" ]; then
      found=1
      grep -qF "$TAKWERX_BIN" "$rc" || printf '\n# takwerx\n%s\n' "$line" >>"$rc"
    fi
  done
  if [ "$found" = 0 ]; then printf '# takwerx\n%s\n' "$line" >"$HOME/.zshrc"; fi
}

# Interface that carries the default route (Wi-Fi or Ethernet), e.g. en0 or en1.
default_interface() { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }
# This Mac's address on that interface; the only host allowed to reach Android's adb on the LAN.
host_lan_ip() { ipconfig getifaddr "$(default_interface)" 2>/dev/null || true; }
# This Mac's position via CoreLocation, the same Wi-Fi positioning a browser uses. The first
# run makes macOS ask for Location permission for the terminal or the app; it must be allowed.
mac_location() {
  local bin="$TAKWERX_APP/helpers/maclocation/maclocation"
  [ -x "$APP_DIR/Contents/MacOS/maclocation" ] && bin="$APP_DIR/Contents/MacOS/maclocation"
  [ -x "$bin" ] || return 1
  "$bin" 2>/dev/null
}
host_lan_ips() { ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | tr '\n' ' '; }

write_networks_yaml() {
  local iface=$1
  mkdir -p "$LIMA_HOME/_config"
  cat >"$LIMA_HOME/_config/networks.yaml" <<YAML
# Written by takwerx. Bridged interface: $iface
paths:
  socketVMNet: $SOCKET_VMNET_BIN
  varRun: /private/var/run/lima
  sudoers: $LIMA_SUDOERS
group: everyone
networks:
  shared:
    mode: shared
    gateway: 192.168.105.1
    dhcpEnd: 192.168.105.254
    netmask: 255.255.255.0
  bridged:
    mode: bridged
    interface: $iface
  host:
    mode: host
    gateway: 192.168.106.1
    dhcpEnd: 192.168.106.254
    netmask: 255.255.255.0
YAML
}

bridged_ready() { [ -x "$SOCKET_VMNET_BIN" ] && [ -f "$LIMA_SUDOERS" ]; }

# One admin password prompt. Installs socket_vmnet under /opt, root-owned as Lima requires,
# and the sudoers rule that lets Lima start it for the bridged network.
bridged_setup() {
  local iface; iface=$(default_interface)
  if [ -z "$iface" ]; then die "No default network interface found; connect to a network first"; fi
  write_networks_yaml "$iface"
  # Needs one admin password. Without a terminal, proceed only if sudo already has credentials.
  if ! have_tty && ! sudo -n true 2>/dev/null; then
    warn "Bridged networking needs your Mac password once. Run 'takwerx network bridged' in a terminal."
    return 1
  fi
  step "Bridged networking on $iface (asks for your Mac password once)"
  local tgz="$TAKWERX_CACHE/socket_vmnet-$SOCKET_VMNET_VERSION-$HOST_ARCH.tar.gz"
  download "https://github.com/lima-vm/socket_vmnet/releases/download/v$SOCKET_VMNET_VERSION/socket_vmnet-$SOCKET_VMNET_VERSION-$HOST_ARCH.tar.gz" "$tgz"
  # socket_vmnet must exist before Lima will generate the sudoers rule for it. sudo caches
  # the password, so the two calls are one prompt.
  sudo -p "Password for %u (bridged networking): " bash -c "
    set -e
    tar -xzf '$tgz' -C / --no-same-owner
    chown -R root:wheel /opt/socket_vmnet && chmod -R go-w /opt/socket_vmnet
  " || die "Could not install socket_vmnet"
  "$LIMACTL" sudoers >"$TAKWERX_STATE/sudoers.lima" || die "Lima could not generate the sudoers rule"
  sudo -p "Password for %u (bridged networking): " install -o root -g wheel -m 0644 "$TAKWERX_STATE/sudoers.lima" "$LIMA_SUDOERS" \
    || die "Could not install $LIMA_SUDOERS"
  "$LIMACTL" sudoers --check "$LIMA_SUDOERS" >/dev/null 2>&1 || warn "sudoers check reported a mismatch; run 'takwerx network bridged' again"
  config_set NETWORK_MODE bridged
  config_set BRIDGE_INTERFACE "$iface"
  ok "Bridged networking ready on $iface"
}

bridged_remove() {
  have_tty || return 0
  [ -f "$LIMA_SUDOERS" ] || [ -d /opt/socket_vmnet ] || return 0
  step "Removing bridged networking (asks for your Mac password)"
  sudo -p "Password for %u: " rm -rf "$LIMA_SUDOERS" /opt/socket_vmnet || warn "Could not remove $LIMA_SUDOERS or /opt/socket_vmnet"
}

# The app bundle is generated here, on this Mac, so it is never quarantined and needs no
# signing. scrcpy is copied inside it so the ATAK window carries this icon in the Dock.
app_build() {
  step "Creating $APP_DIR"
  local mac="$APP_DIR/Contents/MacOS" res="$APP_DIR/Contents/Resources" old
  # An earlier takwerx named the bundle ATAK.app; one with our identifier is replaced.
  old="$(dirname "$APP_DIR")/ATAK.app"
  if [ -d "$old" ] && grep -q com.takwerx.atak-desktop "$old/Contents/Info.plist" 2>/dev/null; then rm -rf "$old"; fi
  mkdir -p "$mac" "$res"
  cat >"$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.takwerx.atak-desktop</string>
  <key>CFBundleVersion</key><string>$TAKWERX_VERSION</string>
  <key>CFBundleShortVersionString</key><string>$TAKWERX_VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>atak</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Required, or CoreLocation denies the request outright and the app never appears
       in System Settings > Privacy & Security > Location Services, so there is no way
       to grant it. This is what makes "takwerx location here" possible at all. -->
  <key>NSLocationWhenInUseUsageDescription</key><string>Your Mac's position is sent to ATAK as its GPS fix, so the map knows where you are.</string>
</dict>
</plist>
PLIST
  cat >"$mac/atak" <<LAUNCHER
#!/bin/bash
# Launcher written by takwerx. Runs the engine without a terminal; output goes to the log.
export TAKWERX_FROM_APP=1
exec "$TAKWERX_BIN/takwerx" up >>"$TAKWERX_LOGS/app.log" 2>&1
LAUNCHER
  chmod +x "$mac/atak"
  cp -f "$SCRCPY_BIN" "$mac/scrcpy"
  cp -f "$SCRCPY_DIR/scrcpy.png" "$mac/scrcpy.png"
  [ -x "$TAKWERX_APP/helpers/maclocation/maclocation" ] && cp -f "$TAKWERX_APP/helpers/maclocation/maclocation" "$mac/maclocation"
  app_icon "$res/icon.icns"
  app_sign
  touch "$APP_DIR"
  ok "$APP_NAME.app ready"
  app_dock_add
}

# The bundle is signed ad hoc, every helper in it first, and the emulator binary (put
# there by emu_bundle) with the entitlements it needs, or it could not use the
# hypervisor; a --deep signature of the bundle would strip them. Then the bundle itself.
app_sign() {
  local mac="$APP_DIR/Contents/MacOS" ent="$TAKWERX_STATE/emulator.entitlements" b
  for b in scrcpy maclocation; do
    [ -f "$mac/$b" ] && codesign --force --sign - "$mac/$b" >/dev/null 2>&1 || true
  done
  if [ -f "$mac/qemu-system-aarch64" ] && [ -s "$ent" ]; then
    codesign --force --sign - --options runtime --entitlements "$ent" "$mac/qemu-system-aarch64" >/dev/null 2>&1 \
      || warn "Could not sign the emulator inside $APP_NAME.app"
  fi
  codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
}

# The icon is ATAK's own launcher art, taken from the APK the user downloaded (never
# shipped here): the largest ic_atak_launcher.png in it, 96 px in ATAK 5.8, which the
# Dock draws at 64 to 128 px. Before ATAK is installed, or if the APK has no such file,
# the takwerx icon (assets/icon.svg) is used.
# ATAK's launcher art from the APK. Release APKs scramble resource file names (res/3k.png),
# so a file called ic_atak_launcher.png exists only in the SDK's development build; the
# resource table maps the name to the file, and lib/apk-icon.pl reads it. Until 2026-09-27
# only the file name was looked for, and every release APK fell back to takwerx's icon.
app_icon_source() {
  local apk entry
  apk=$(config_get ATAK_APK ""); [ -f "$apk" ] || apk=$(find_atak_apk)
  [ -f "${apk:-}" ] || return 1
  entry=$(unzip -p "$apk" resources.arsc 2>/dev/null | perl "$TAKWERX_APP/lib/apk-icon.pl" ic_atak_launcher 2>/dev/null || true)
  [ -n "$entry" ] || entry=$(unzip -l "$apk" 2>/dev/null | awk '$4 ~ /ic_atak_launcher\.png$/ {print $1, $4}' | sort -rn | head -n1 | cut -d' ' -f2)
  [ -n "$entry" ] || return 1
  unzip -p "$apk" "$entry" >"$TAKWERX_STATE/icon/source.png" 2>/dev/null && [ -s "$TAKWERX_STATE/icon/source.png" ]
}

app_icon() {
  local out=$1 src="$TAKWERX_APP/assets/icon.svg" work="$TAKWERX_STATE/icon" s png
  rm -rf "$work"; mkdir -p "$work/icon.iconset"
  if app_icon_source; then
    png="$work/source.png"
  elif qlmanage -t -s 1024 -o "$work" "$src" >/dev/null 2>&1 && [ -f "$work/icon.svg.png" ]; then
    png="$work/icon.svg.png"
  else
    warn "Could not render the icon; the app keeps the default icon"
    return 0
  fi
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$png" --out "$work/icon.iconset/icon_${s}x${s}.png" >/dev/null 2>&1
    sips -z $((s*2)) $((s*2)) "$png" --out "$work/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$work/icon.iconset" -o "$out" 2>/dev/null || warn "iconutil failed; default icon kept"
}

# Pins the app to the Dock once. The Dock stores the path URL-encoded (spaces as %20);
# an earlier check looked for the plain path, never matched, and pinned the app again on
# every build, so any duplicates are removed first, then one tile is appended. Edits go
# through defaults export/import (PlistBuddy on the live plist is overwritten by
# cfprefsd). The Dock restarts to pick it up (a second of blank Dock).
app_dock_add() {
  local url="file://${APP_DIR// /%20}/" plist="$TAKWERX_STATE/dock.plist" i=0 u had=0 n
  defaults export com.apple.dock "$plist" 2>/dev/null || return 0
  while /usr/libexec/PlistBuddy -c "Print :persistent-apps:$i" "$plist" >/dev/null 2>&1; do i=$((i + 1)); done
  n=$i
  i=$((n - 1))
  while [ "$i" -ge 0 ]; do
    u=$(/usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:file-data:_CFURLString" "$plist" 2>/dev/null || true)
    case "$u" in
      *TAKwerx%20ATAK%20Terminal.app*) /usr/libexec/PlistBuddy -c "Delete :persistent-apps:$i" "$plist" >/dev/null 2>&1; had=$((had + 1)) ;;
    esac
    i=$((i - 1))
  done
  [ "$had" -eq 1 ] && { rm -f "$plist"; return 0; }
  i=$((n - had))   # appended at the end of the Dock
  /usr/libexec/PlistBuddy -c "Add :persistent-apps:$i dict" -c "Add :persistent-apps:$i:tile-type string file-tile" \
    -c "Add :persistent-apps:$i:tile-data dict" -c "Add :persistent-apps:$i:tile-data:file-data dict" \
    -c "Add :persistent-apps:$i:tile-data:file-data:_CFURLString string $url" -c "Add :persistent-apps:$i:tile-data:file-data:_CFURLStringType integer 15" "$plist" >/dev/null 2>&1 || { rm -f "$plist"; return 0; }
  defaults import com.apple.dock "$plist" 2>/dev/null || { rm -f "$plist"; return 0; }
  rm -f "$plist"
  killall Dock >/dev/null 2>&1 || true
  if [ "$had" -gt 1 ]; then ok "$APP_NAME is in the Dock once (was $had times)"; else ok "$APP_NAME is in the Dock"; fi
}

# Takes the app's tiles out of the Dock (same mechanics as app_dock_add), then the app.
app_dock_remove() {
  local plist="$TAKWERX_STATE/dock.plist" i=0 u had=0
  mkdir -p "$TAKWERX_STATE"
  defaults export com.apple.dock "$plist" 2>/dev/null || return 0
  while /usr/libexec/PlistBuddy -c "Print :persistent-apps:$i" "$plist" >/dev/null 2>&1; do i=$((i + 1)); done
  i=$((i - 1))
  while [ "$i" -ge 0 ]; do
    u=$(/usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:file-data:_CFURLString" "$plist" 2>/dev/null || true)
    case "$u" in
      *TAKwerx%20ATAK%20Terminal.app*) /usr/libexec/PlistBuddy -c "Delete :persistent-apps:$i" "$plist" >/dev/null 2>&1; had=$((had + 1)) ;;
    esac
    i=$((i - 1))
  done
  if [ "$had" -gt 0 ]; then defaults import com.apple.dock "$plist" 2>/dev/null && killall Dock >/dev/null 2>&1 || true; fi
  rm -f "$plist"
}

app_remove() { app_dock_remove; rm -rf "$APP_DIR"; }

host_doctor() {
  local ver; ver=$(sw_vers -productVersion)
  if [ "${ver%%.*}" -ge 13 ]; then ok "macOS $ver, $HOST_ARCH"; else warn "macOS $ver is too old; 13 or newer is required"; fi
  if [ -x "$LIMACTL" ]; then ok "Lima $(tool_version "$LIMA_DIR")"; else warn "Lima not installed (takwerx init)"; fi
  if [ -x "$SCRCPY_BIN" ]; then ok "scrcpy $(tool_version "$SCRCPY_DIR")"; else warn "scrcpy not installed (takwerx init)"; fi
  if bridged_ready; then ok "Bridged networking installed (socket_vmnet on $(config_get BRIDGE_INTERFACE '?'))"; else warn "Bridged networking not installed; Android is behind NAT (takwerx network bridged)"; fi
  if [ -d "$APP_DIR" ]; then ok "$APP_DIR"; else warn "App icon not created yet (takwerx init)"; fi
}
