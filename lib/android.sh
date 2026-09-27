#!/usr/bin/env bash
# shellcheck shell=bash
# Android: the redroid container in the VM, adb from the host, ATAK provisioning, the window.

# with_timeout SECONDS CMD...: SIGALRM survives exec, so a blackholed adb connection cannot hang us.
with_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# Always the adb that ships with scrcpy, talking to takwerx's private server (see common.sh).
ADB="$SCRCPY_DIR/adb"; export ADB
adb_server_ensure() { with_timeout 20 "$ADB" start-server >/dev/null 2>&1 || true; }
adb_()   { "$ADB" -s "$ADB_ENDPOINT" "$@"; }
adb_sh() { with_timeout 30 "$ADB" -s "$ADB_ENDPOINT" shell "$@" | tr -d '\r'; }

android_state()  { with_timeout 10 "$ADB" -s "$ADB_ENDPOINT" get-state 2>/dev/null || true; }
android_online() { [ "$(android_state)" = device ]; }
android_booted() { [ "$(adb_sh getprop sys.boot_completed 2>/dev/null)" = 1 ]; }

# Connect over Lima's loopback forward and wait for Android to finish booting.
android_wait() {
  local deadline=$(( $(date +%s) + ${1:-300} )) state out restarted=0
  adb_server_ensure
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state=$(android_state)
    if [ "$state" = device ] && android_booted; then return 0; fi
    if [ "$state" = offline ] || [ "$state" = device ]; then "$ADB" disconnect "$ADB_ENDPOINT" >/dev/null 2>&1 || true; fi
    out=$(with_timeout 15 "$ADB" connect "$ADB_ENDPOINT" 2>&1 || true)
    # macOS Local Network privacy: an adb server started earlier by another app may lack
    # permission to reach LAN addresses and fails with "No route to host". Ours will prompt once.
    if [ "$restarted" = 0 ] && printf '%s' "$out" | grep -q 'No route to host'; then
      warn "The running adb server cannot reach the LAN (macOS Local Network permission); restarting it"
      "$ADB" kill-server >/dev/null 2>&1 || true
      "$ADB" start-server >/dev/null 2>&1 || true
      restarted=1
    fi
    sleep 3
  done
  return 1
}

container_exists()  { vm_run "podman container exists $CONTAINER_NAME" 2>/dev/null; }
container_running() { [ "$(vm_run "podman inspect -f '{{.State.Running}}' $CONTAINER_NAME 2>/dev/null" 2>/dev/null | tr -d '\r')" = true ]; }
image_present() { vm_run "podman image exists $REDROID_IMAGE" 2>/dev/null; }
image_pull() {
  step "Downloading Android ($REDROID_IMAGE, about 800 MB)"
  vm_run "podman pull $REDROID_IMAGE" || die "Could not pull $REDROID_IMAGE"
}

# Presets are "width height dpi". Layout room in dp is pixels * 160 / dpi, so lowering the
# dpi buys toolbar space without rendering more pixels.
display_geometry() {
  case "$1" in
    ultra)   printf '2960 1848 240' ;;   # Galaxy Tab S11 Ultra
    tablet)  printf '2560 1440 200' ;;   # default: same dp width as the Ultra, fewer pixels
    desktop) printf '2560 1440 160' ;;   # most toolbar room, small touch targets
    phone)   printf '1440 3120 450' ;;   # for checking phone layouts
    *) if [[ $1 =~ ^([0-9]+)x([0-9]+)@([0-9]+)$ ]]; then printf '%s %s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; else return 1; fi ;;
  esac
}

# ---- LAN identity (bridged mode) --------------------------------------------------------
# Android gets its own MAC on a macvlan network over the VM's bridged interface, and a real
# DHCP lease from the LAN router. redroid snapshots eth0 as a static config when Android
# boots, so the lease is obtained inside the container's network namespace between
# `podman init` and `podman start`, and a udhcpc daemon in the VM keeps renewing it.
LAN_NETWORK=takwerx-lan
LAN_PARENT=lima0
LEASE_FILE=/run/takwerx-lease
UDHCPC_PID=/run/takwerx-udhcpc.pid
UDHCPC_SCRIPT=/usr/local/lib/takwerx/udhcpc.script

lan_network_ensure() {
  vm_run "podman network exists $LAN_NETWORK || podman network create -d macvlan -o parent=$LAN_PARENT --ipam-driver none $LAN_NETWORK >/dev/null"
}
# One locally administered MAC per install, so the router hands out the same lease every time.
android_mac() {
  local mac; mac=$(config_get ANDROID_MAC)
  if [ -z "$mac" ]; then
    mac=$(printf '02:54:41:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
    config_set ANDROID_MAC "$mac"
  fi
  printf '%s' "$mac"
}
lan_dns() { vm_run "resolvectl dns $LAN_PARENT 2>/dev/null" 2>/dev/null | tr -d '\r' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true; }
lease_stop() { vm_run "if [ -f $UDHCPC_PID ]; then kill \$(cat $UDHCPC_PID) 2>/dev/null; rm -f $UDHCPC_PID; fi; rm -f $LEASE_FILE" >/dev/null 2>&1 || true; }
lease_acquire() {
  local ns
  ns=$(vm_run "podman inspect -f '{{.NetworkSettings.SandboxKey}}' $CONTAINER_NAME" 2>/dev/null | tr -d '\r')
  [ -n "$ns" ] || return 1
  # Without -f udhcpc daemonizes once bound and keeps renewing; -n makes it fail instead of wait;
  # -a ARP-probes the offered address and declines it if some other device already holds it.
  vm_run "rm -f $LEASE_FILE; nsenter --net=$ns busybox udhcpc -i eth0 -n -a -t 6 -T 3 -x hostname:ATAK -p $UDHCPC_PID -s $UDHCPC_SCRIPT >/dev/null 2>&1; test -s $LEASE_FILE"
}
lease_info() { vm_run "cat $LEASE_FILE 2>/dev/null" 2>/dev/null | tr -d '\r'; }
# Second opinion from the VM: its own macvlan child cannot answer this, so any reply is a
# foreign device holding the same address. Found the hard way with a router that leased an
# address a static device was already using.
lan_ip_conflict() { vm_run "busybox arping -I $LAN_PARENT -c 2 -w 2 $1 2>/dev/null | grep -q 'Unicast reply'"; }

# adb always goes through Lima's loopback forward: in NAT mode podman publishes 5555 there; in
# bridged mode a relay in the VM does, over a macvlan shim to the container. The Mac never
# opens a LAN connection for adb, so macOS's Local Network permission never comes into play
# (it was denied once mid-session here and took every adb server down with it).
ADB_ENDPOINT=127.0.0.1:5555

# The VM's own address on the bridged interface: source of the relayed adb connections.
vm_lan_ip() { vm_run "ip -4 -o addr show $LAN_PARENT 2>/dev/null" 2>/dev/null | tr -d '\r' | awk '{print $4}' | cut -d/ -f1 | head -n1; }

# A macvlan sibling interface on the VM, since a macvlan parent cannot talk to its children.
# It borrows the VM's own address as a /32 with a host route to the container.
lan_shim_ensure() {
  local ip=$1
  vm_run "ip link show takwerx-shim >/dev/null 2>&1 || ip link add takwerx-shim link $LAN_PARENT type macvlan mode bridge
    VMIP=\$(ip -4 -o addr show $LAN_PARENT | awk '{print \$4}' | cut -d/ -f1 | head -n1)
    ip addr replace \$VMIP/32 dev takwerx-shim && ip link set takwerx-shim up && ip route replace $ip/32 dev takwerx-shim src \$VMIP"
}

# redroid's adbd has no authentication. On the LAN, only the VM (the relay) may reach it.
adb_firewall() {
  [ "$(config_get CONTAINER_MODE nat)" = bridged ] || return 0
  local ips rules='' ip
  ips=$(vm_lan_ip)
  [ -n "$ips" ] || return 0
  for ip in $ips; do rules="$rules iptables -A takwerx -s $ip -j RETURN;"; done
  vm_run "podman exec $CONTAINER_NAME /system/bin/sh -c '
    iptables -N takwerx 2>/dev/null; iptables -F takwerx; $rules
    iptables -A takwerx -j DROP
    iptables -C INPUT -p tcp --dport 5555 -j takwerx 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 5555 -j takwerx'" >/dev/null 2>&1 \
    || warn "Could not restrict adb to this Mac inside Android"
}

# ---- container lifecycle ------------------------------------------------------------------
# The 64-bit-only image: Apple Silicon cannot execute 32-bit ARM code, so the regular image's
# 32-bit zygote crash-loops and pins every CPU. use_memfd replaces ashmem, gone from kernels
# after 5.18. The binderfs nodes are bind-mounted because symlinks do not survive into
# podman's /dev and mknod'ed copies do not carry the binderfs inode the driver checks.
container_create() {
  local preset w h dpi mode common boot
  preset=$(config_get DISPLAY_PRESET tablet); mode=$(config_get NETWORK_MODE nat)
  read -r w h dpi <<<"$(display_geometry "$preset" || display_geometry tablet)"
  vm_run "podman volume exists $VOLUME_NAME || podman volume create $VOLUME_NAME >/dev/null"
  # Cap the container 1.5 GiB below the VM so Android's lmkd trims apps before the VM's OOM
  # killer reaches Lima's guest agent, which is what took the window down once.
  local capmb; capmb=$(vm_run "awk '/MemTotal/{print int(\$2/1024)-1536}' /proc/meminfo" 2>/dev/null | tr -d '\r'); [ "${capmb:-0}" -gt 2048 ] || capmb=2048
  # Pinned to all cores but one: Android is privileged and sets real-time priorities, and
  # under load (terrain from DTED on software GL) it starved sshd, the adb relay and the
  # position feeder and wedged the VM. One core stays the VM's own whatever Android does.
  local cpus cpuset=''
  cpus=$(config_get VM_CPUS 2)
  if [ "$cpus" -ge 2 ]; then cpuset="--cpuset-cpus=1-$((cpus - 1))"; fi
  common="--name $CONTAINER_NAME --privileged $cpuset --memory ${capmb}m -v $VOLUME_NAME:/data -v /dev/binderfs/binder:/dev/binder -v /dev/binderfs/hwbinder:/dev/hwbinder -v /dev/binderfs/vndbinder:/dev/vndbinder"
  local fps; fps=$(config_get MAX_FPS 60)
  boot="androidboot.redroid_width=$w androidboot.redroid_height=$h androidboot.redroid_dpi=$dpi androidboot.redroid_gpu_mode=guest androidboot.redroid_fps=$fps androidboot.use_memfd=true"
  if [ "$mode" = bridged ]; then
    if container_create_lan "$common" "$boot" "$preset: ${w}x${h} at ${dpi} dpi"; then return 0; fi
    warn "Android is running behind NAT instead; fix the LAN and run 'takwerx network bridged' again"
  fi
  step "Creating the Android instance ($preset: ${w}x${h} at ${dpi} dpi, NAT)"
  vm_run "podman run -d $common -p 127.0.0.1:5555:5555 $REDROID_IMAGE $boot >/dev/null" || die "Could not start the Android container"
  config_unset ANDROID_IP; config_set CONTAINER_MODE nat
}

container_create_lan() {
  local common=$1 boot=$2 desc=$3 mac dns ip lease
  step "Creating the Android instance ($desc, on the LAN)"
  lan_network_ensure || { warn "Could not create the macvlan network on $LAN_PARENT"; return 1; }
  mac=$(android_mac); dns=$(lan_dns); [ -n "$dns" ] || dns=1.1.1.1
  local attempt
  for attempt in 1 2; do
    vm_run "podman create $common --network $LAN_NETWORK --mac-address $mac --hostname ATAK $REDROID_IMAGE $boot androidboot.redroid_net_ndns=1 androidboot.redroid_net_dns1=$dns >/dev/null && podman init $CONTAINER_NAME >/dev/null" \
      || { warn "Could not create the LAN container"; container_remove; return 1; }
    if ! lease_acquire; then
      warn "No DHCP lease from the LAN within 20 seconds"
      container_remove; return 1
    fi
    lease=$(lease_info); ip=${lease%% *}
    if ! lan_ip_conflict "$ip"; then break; fi
    warn "Another device on the LAN already uses $ip; asking the router for a different address"
    container_remove
    if [ "$attempt" = 2 ]; then return 1; fi
    config_unset ANDROID_MAC; mac=$(android_mac)
  done
  vm_run "podman start $CONTAINER_NAME >/dev/null" || { warn "Could not start the LAN container"; container_remove; return 1; }
  lan_shim_ensure "$ip" || warn "Could not set up the VM-side path to Android; adb may not connect"
  config_set ANDROID_IP "$ip"; config_set CONTAINER_MODE bridged
  ok "Android is on the LAN at $ip (MAC $mac, DHCP from $(printf '%s' "$lease" | awk '{print $3}'), DNS $dns)"
}

# Widen the binderfs nodes and load uhid before every start; a rebooted VM gets them from the
# oneshot service and modules-load, but this costs nothing and removes two silent failure modes.
# Also survives an Ubuntu kernel upgrade: the modules-extra package (binder, uhid) is per
# kernel version, and a VM that rebooted into a new kernel has none until this installs it.
binder_ready() {
  vm_run 'set -e
    if [ ! -d "/lib/modules/$(uname -r)/kernel/drivers/android" ]; then
      DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 -qq install -y "linux-modules-extra-$(uname -r)" >/dev/null 2>&1
    fi
    modprobe binder_linux 2>/dev/null || true; modprobe uhid 2>/dev/null || true
    [ -e /dev/binderfs/binder ] || systemctl restart dev-binderfs.mount takwerx-binderfs.service 2>/dev/null || true
    test -e /dev/binderfs/binder && chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder'
}

container_start() {
  local mode; mode=$(config_get NETWORK_MODE nat)
  if container_running; then
    if [ "$(config_get CONTAINER_MODE nat)" = "$mode" ]; then return 0; fi
    step "Network mode changed to $mode; recreating Android"
    container_stop
  fi
  binder_ready || die "binder is not available in the VM (takwerx doctor)"
  if container_exists; then
    # A bridged container gets a fresh network namespace on every start and so needs a fresh
    # lease before Android boots; a container built for the other mode is stale. Recreate both.
    if [ "$mode" = bridged ] || [ "$(config_get CONTAINER_MODE nat)" != "$mode" ]; then
      container_remove
      container_create
    else
      step "Starting Android"
      vm_run "podman start $CONTAINER_NAME >/dev/null" || die "Could not start the Android container"
    fi
  else
    container_create
  fi
}
atak_quit() {
  atak_running || return 0
  adb_sh am broadcast -a com.atakmap.app.QUITAPP --ez FORCE_QUIT true >/dev/null 2>&1 || true
  local i; for i in 1 2 3 4 5 6 7 8; do atak_running || return 0; sleep 1; done
}
container_stop() {
  if container_running; then
    step "Stopping Android"
    # Ask ATAK to quit first so it does not report an unclean exit next time; then Android's
    # init ignores SIGTERM, so sync the filesystems and let podman kill it quickly.
    atak_quit
    adb_sh sync >/dev/null 2>&1 || true
    vm_run "podman stop -t 3 $CONTAINER_NAME >/dev/null 2>&1" || warn "Android stop reported an error"
  fi
  lease_stop
}
container_remove() { lease_stop; vm_run "podman rm -f $CONTAINER_NAME >/dev/null 2>&1 || true"; }
volume_remove()    { vm_run "podman volume rm -f $VOLUME_NAME >/dev/null 2>&1 || true"; }
container_logs()   { vm_run "podman logs --tail ${1:-200} $CONTAINER_NAME"; }

# scrcpy's HID keyboard needs /dev/uhid, which the container creates root-only. adb runs as the
# shell user, but podman can open it from the VM side; the node lives on the container's own /dev.
uhid_enable() { vm_run "podman exec $CONTAINER_NAME /system/bin/chmod 666 /dev/uhid" >/dev/null 2>&1 || true; }
uhid_usable() { adb_sh test -w /dev/uhid 2>/dev/null; }

# Idempotent Android settings for a desktop instance: never sleep, no lock screen, host timezone.
android_provision() {
  local tz w h dpi
  uhid_enable
  adb_firewall
  adb_sh settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
  adb_sh settings put global stay_on_while_plugged_in 7 >/dev/null 2>&1 || true
  adb_sh svc power stayon true >/dev/null 2>&1 || true
  adb_sh settings put secure immersive_mode_confirmations confirmed >/dev/null 2>&1 || true
  adb_sh locksettings set-disabled true >/dev/null 2>&1 || true
  # The Mac keyboard arrives as a hardware keyboard; keep Android's on-screen keyboard away.
  adb_sh settings put secure show_ime_with_hard_keyboard 0 >/dev/null 2>&1 || true
  tz=$(host_timezone)
  if [ -n "$tz" ]; then adb_sh setprop persist.sys.timezone "$tz" >/dev/null 2>&1 || true; fi
  read -r w h dpi <<<"$(display_geometry "$(config_get DISPLAY_PRESET tablet)" || display_geometry tablet)"
  atak_splash_apply "$w" "$h"
  # Gesture navigation: the tablet taskbar then auto-hides and ATAK gets the whole screen.
  # Only switched once, because the switch restarts the launcher.
  if ! adb_sh cmd overlay list 2>/dev/null | grep -q '\[x\] com.android.internal.systemui.navbar.gestural$'; then
    adb_sh cmd overlay enable com.android.internal.systemui.navbar.gestural >/dev/null 2>&1 || true
    adb_sh cmd overlay disable com.android.internal.systemui.navbar.threebutton >/dev/null 2>&1 || true
    sleep 3
  fi
}

# ATAK shows atak/support/atak_splash.png (under 4096 px a side) in place of its own splash
# image: its own supported customisation, read at every start; nothing in ATAK is modified.
# ATAK stretches it to cover the screen and crops the rest, so 16:9 art on a 21:9 screen
# lost a quarter of its height ("cut off or zoomed in", 2026-09-26). The art is therefore
# fitted whole onto a canvas of the screen's own shape, black at the sides or top, with
# sips, which every Mac has. atak_splash_apply WIDTH HEIGHT of the Android screen.
atak_splash_apply() {
  local w=$1 h=$2 src="$TAKWERX_APP/assets/atak_splash.png" out aw ah want have
  [ -f "$src" ] || return 0
  [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || return 0
  out="$TAKWERX_STATE/atak_splash-${w}x${h}.png"
  if [ ! -f "$out" ] || [ "$src" -nt "$out" ]; then
    aw=$(sips -g pixelWidth "$src" 2>/dev/null | awk '/pixelWidth/{print $2}')
    ah=$(sips -g pixelHeight "$src" 2>/dev/null | awk '/pixelHeight/{print $2}')
    [ -n "$aw" ] && [ -n "$ah" ] || { warn "Could not read the splash image"; return 0; }
    # Contain: scale by whichever side hits its limit first, then pad the other.
    if [ $(( aw * h )) -gt $(( w * ah )) ]; then
      sips -s format png --resampleWidth "$w" "$src" --out "$out.tmp" >/dev/null 2>&1
    else
      sips -s format png --resampleHeight "$h" "$src" --out "$out.tmp" >/dev/null 2>&1
    fi
    sips -p "$h" "$w" --padColor 000000 "$out.tmp" --out "$out" >/dev/null 2>&1 || { warn "Could not fit the splash to the screen"; rm -f "$out" "$out.tmp"; return 0; }
    rm -f "$out.tmp"
  fi
  want=$(md5 -q "$out" 2>/dev/null || md5sum "$out" | cut -d' ' -f1)
  # No file yet on a fresh device: md5sum fails, and under set -e a failing substitution
  # ends the whole command. Hence the || true (it did end `takwerx up`, 2026-09-26).
  have=$(adb_sh md5sum /sdcard/atak/support/atak_splash.png 2>/dev/null | cut -d' ' -f1 || true)
  [ "$want" = "$have" ] && return 0
  adb_sh mkdir -p /sdcard/atak/support >/dev/null 2>&1 || true
  adb_ push "$out" /sdcard/atak/support/atak_splash.png >/dev/null 2>&1 || warn "Could not install the splash screen"
}

atak_installed() { adb_sh pm path "$ATAK_PACKAGE" 2>/dev/null | grep -q '^package:'; }
atak_version()   { adb_sh dumpsys package "$ATAK_PACKAGE" 2>/dev/null | sed -nE 's/^ *versionName=(.*)$/\1/p' | head -n1; }
atak_running()   { adb_sh pidof "$ATAK_PACKAGE" >/dev/null 2>&1; }
atak_launch() {
  local act
  act=$(adb_sh cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$ATAK_PACKAGE" 2>/dev/null | tail -n1)
  [ -n "$act" ] || return 0
  adb_sh am start -n "$act" >/dev/null 2>&1 || true
}

atak_install() {
  local apk=$1
  [ -f "$apk" ] || die "APK not found: $apk"
  step "Installing $(basename "$apk") (a minute or two over adb)"
  "$ADB" -s "$ADB_ENDPOINT" install -r -g "$apk" >/dev/null || die "adb install failed for $apk"
  atak_grant
  config_set ATAK_APK "$apk"
  ok "ATAK $(atak_version) installed"
}

# Grants everything ATAK would otherwise ask for on first run, including the two that
# live outside the runtime-permission model: all-files access and installing APKs.
# The second is what lets the TAKWERX Market plugin update plugins from inside ATAK.
atak_grant() {
  local op perm
  for op in MANAGE_EXTERNAL_STORAGE REQUEST_INSTALL_PACKAGES SYSTEM_ALERT_WINDOW; do
    adb_sh appops set "$ATAK_PACKAGE" "$op" allow >/dev/null 2>&1 || true
  done
  for perm in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION POST_NOTIFICATIONS \
              READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE CAMERA RECORD_AUDIO READ_PHONE_STATE \
              BLUETOOTH_CONNECT BLUETOOTH_SCAN NEARBY_WIFI_DEVICES; do
    adb_sh pm grant "$ATAK_PACKAGE" "android.permission.$perm" >/dev/null 2>&1 || true
  done
}

plugin_install() {
  local apk=$1
  [ -f "$apk" ] || die "APK not found: $apk"
  step "Installing plugin $(basename "$apk")"
  "$ADB" -s "$ADB_ENDPOINT" install -r -g "$apk" >/dev/null || die "adb install failed for $apk"
  ok "Installed; if ATAK does not offer to load it, open Plugin Manager inside ATAK"
}

datapackage_install() {
  local zip=$1 name
  [ -f "$zip" ] || die "Not found: $zip"
  name=$(basename "$zip")
  step "Importing data package $name"
  adb_ push "$zip" "/sdcard/Download/$name" >/dev/null || die "adb push failed"
  adb_sh am start -a android.intent.action.VIEW -d "file:///sdcard/Download/$name" -t application/zip -p "$ATAK_PACKAGE" >/dev/null 2>&1 || true
  ok "Pushed to Download/$name; if ATAK did not import it, use Import Manager > Local SD"
}

display_apply() {
  local preset=$1 w='' h='' dpi=''
  read -r w h dpi <<<"$(display_geometry "$preset" || true)"
  [ -n "$w" ] || die "Unknown preset '$preset' (ultra, tablet, desktop, phone, or WIDTHxHEIGHT@DPI)"
  adb_sh wm size "${w}x${h}" >/dev/null || die "wm size failed"
  adb_sh wm density "$dpi" >/dev/null || die "wm density failed"
  config_set DISPLAY_PRESET "$preset"
  ok "Display $preset: ${w}x${h} at ${dpi} dpi, $((w*160/dpi))x$((h*160/dpi)) dp of layout room"
}

# The window. Mouse stays a normal desktop pointer with hover forwarded; right-click goes to
# Android as a secondary button; shift+right/middle/4th/5th map to back/home/switch/notifications.
# The keyboard is a real HID keyboard so ATAK sees hardware shortcuts.
window_open() {
  local bin="$SCRCPY_BIN"
  if [ "$HOST_OS" = macos ] && [ -x "${APP_DIR:-/nonexistent}/Contents/MacOS/scrcpy" ]; then bin="$APP_DIR/Contents/MacOS/scrcpy"; fi
  # uhid presents the Mac keyboard as a hardware keyboard, which is best at the machine. Over a
  # remote desktop (AnyDesk, Screen Sharing) keystrokes arrive as injected events without
  # scancodes and uhid forwards nothing; sdk injects text through adb and works everywhere.
  local keyboard kbflags
  keyboard=$(config_get KEYBOARD_MODE auto)
  if [ "$keyboard" = auto ]; then if uhid_usable; then keyboard=uhid; else keyboard=sdk; fi; fi
  kbflags=(--keyboard="$keyboard")
  [ "$keyboard" = sdk ] && kbflags+=(--prefer-text)
  step "Opening the ATAK window (keyboard: $keyboard)"
  # scrcpy exits 2 when adb drops the device. If that happens, reconnect and reopen once.
  local attempt rc started
  for attempt in 1 2; do
    started=$(date +%s)
    SCRCPY_SERVER_PATH="$SCRCPY_DIR/scrcpy-server" SCRCPY_ICON_PATH="$SCRCPY_DIR/scrcpy.png" ADB="$ADB" \
      "$bin" -s "$ADB_ENDPOINT" --window-title=ATAK \
        --mouse=sdk --mouse-bind=++++:bhsn "${kbflags[@]}" \
        --no-audio --max-fps="$(config_get MAX_FPS 60)" --video-bit-rate=8M "$@" && rc=0 || rc=$?
    if [ "$rc" != 2 ] || [ "$attempt" = 2 ]; then return "$rc"; fi
    # A deliberate `takwerx down` stops the VM; do not fight it. Anything else, bring it back.
    # The VM is still running for a while during a stop, hence the marker as well.
    [ -f "$TAKWERX_STATE/stopping" ] && return "$rc"
    vm_running || return "$rc"
    warn "The window lost its connection to Android; reconnecting"
    android_up || return "$rc"
    if atak_installed && ! atak_running; then atak_launch; fi
  done
}

# ---- position ----------------------------------------------------------------------------
# There is no GPS in the container, and ATAK 5.8 will not trust a mock provider. It does trust
# NMEA on UDP 4349, the input a Bluetooth or USB GPS uses, so a service in the VM streams GGA
# and RMC sentences for /etc/takwerx/location into the container once a second.
LOCATION_FILE=/etc/takwerx/location
location_set() {
  local lat=$1 lon=$2 acc=$3 source=$4
  config_set LOCATION "$lat,$lon"; config_set LOCATION_ACCURACY "$acc"; config_set LOCATION_SOURCE "$source"
  if [ "$(runtime)" = emulator ]; then
    if android_online; then emu_location_apply; fi
  else
    vm_run "mkdir -p /etc/takwerx && printf '%s %s %s\n' '$lat' '$lon' '$acc' >$LOCATION_FILE" || die "Could not store the position in the VM"
  fi
  ok "Position $lat, $lon (about $acc m, from $source). ATAK shows it as a GPS fix within a few seconds"
}
# The Mac's own Wi-Fi position, refreshed on every launch, because a laptop moves and a
# rough public-IP fix is 5 km wrong. Run from the app bundle this is also what raises
# macOS's "ATAK would like to use your location" prompt: Location Services is granted per
# responsible process, and the bundle is the one a user can actually grant -- which is why
# this lives on the launch path and not behind a terminal command.
#
# A position the user typed in by hand is never overwritten. A denial is silent and costs
# nothing: maclocation returns immediately with kCLErrorDenied, and whatever position is
# already set stays. Only a rough or previously-Mac-derived fix is upgraded.
location_refresh() {
  local src pos lat lon acc
  src=$(config_get LOCATION_SOURCE)
  case "$src" in you) return 0 ;; esac
  pos=$(mac_location) || return 0
  IFS=, read -r lat lon acc <<<"$pos"
  [[ $lat =~ ^-?[0-9]+(\.[0-9]+)?$ && $lon =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || return 0
  location_set "$lat" "$lon" "${acc:-50}" "this Mac"
}

location_off() {
  vm_run "rm -f $LOCATION_FILE" >/dev/null 2>&1 || true
  config_unset LOCATION; config_unset LOCATION_ACCURACY; config_unset LOCATION_SOURCE
  ok "Position feed off; ATAK reports no GPS again shortly"
}
# Rough position from the public IP, a few kilometres at best; honest accuracy is reported.
ip_location() {
  local json
  json=$(curl -fsSL --max-time 10 https://ipinfo.io/json 2>/dev/null) || return 1
  printf '%s' "$json" | sed -nE 's/.*"loc": *"([-0-9.]+),([-0-9.]+)".*/\1,\2,5000/p' | head -n1 | grep .
}
