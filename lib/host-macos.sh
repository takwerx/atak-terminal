#!/usr/bin/env bash
# shellcheck shell=bash
# macOS host: vendored tools, bridged networking through socket_vmnet, and the app bundle.

LIMA_DIR="$TAKWERX_TOOLS/lima"
SCRCPY_DIR="$TAKWERX_TOOLS/scrcpy"
LIMACTL="$LIMA_DIR/bin/limactl"
SCRCPY_BIN="$SCRCPY_DIR/scrcpy"
SOCKET_VMNET_BIN=/opt/socket_vmnet/bin/socket_vmnet
LIMA_SUDOERS=/private/etc/sudoers.d/lima
APP_NAME="ATAK"
if [ -w /Applications ]; then APP_DIR="/Applications/$APP_NAME.app"; else APP_DIR="$HOME/Applications/$APP_NAME.app"; fi

host_check() {
  local ver major
  ver=$(sw_vers -productVersion); major=${ver%%.*}
  if [ "$major" -lt 13 ]; then die "macOS 13 or newer is required (this Mac runs $ver)"; fi
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
  local mac="$APP_DIR/Contents/MacOS" res="$APP_DIR/Contents/Resources"
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
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
  touch "$APP_DIR"
  ok "$APP_NAME.app ready"
}

app_icon() {
  local out=$1 src="$TAKWERX_APP/assets/icon.svg" work="$TAKWERX_STATE/icon" s
  rm -rf "$work"; mkdir -p "$work/icon.iconset"
  if ! qlmanage -t -s 1024 -o "$work" "$src" >/dev/null 2>&1 || [ ! -f "$work/icon.svg.png" ]; then
    warn "Could not render the icon; the app keeps the default icon"
    return 0
  fi
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$work/icon.svg.png" --out "$work/icon.iconset/icon_${s}x${s}.png" >/dev/null 2>&1
    sips -z $((s*2)) $((s*2)) "$work/icon.svg.png" --out "$work/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$work/icon.iconset" -o "$out" 2>/dev/null || warn "iconutil failed; default icon kept"
}

app_remove() { rm -rf "$APP_DIR"; }

host_doctor() {
  local ver; ver=$(sw_vers -productVersion)
  if [ "${ver%%.*}" -ge 13 ]; then ok "macOS $ver, $HOST_ARCH"; else warn "macOS $ver is too old; 13 or newer is required"; fi
  if [ -x "$LIMACTL" ]; then ok "Lima $(tool_version "$LIMA_DIR")"; else warn "Lima not installed (takwerx init)"; fi
  if [ -x "$SCRCPY_BIN" ]; then ok "scrcpy $(tool_version "$SCRCPY_DIR")"; else warn "scrcpy not installed (takwerx init)"; fi
  if bridged_ready; then ok "Bridged networking installed (socket_vmnet on $(config_get BRIDGE_INTERFACE '?'))"; else warn "Bridged networking not installed; Android is behind NAT (takwerx network bridged)"; fi
  if [ -d "$APP_DIR" ]; then ok "$APP_DIR"; else warn "App icon not created yet (takwerx init)"; fi
}
