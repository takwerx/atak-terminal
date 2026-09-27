#!/usr/bin/env bash
# shellcheck shell=bash
# Shared paths, config, logging and prompts. Sourced by ./takwerx, never run directly.

TAKWERX_ROOT="${TAKWERX_ROOT:-$HOME/.takwerx}"
TAKWERX_BIN="$TAKWERX_ROOT/bin"
TAKWERX_TOOLS="$TAKWERX_ROOT/tools"
TAKWERX_CACHE="$TAKWERX_ROOT/cache"
TAKWERX_LOGS="$TAKWERX_ROOT/logs"
TAKWERX_STATE="$TAKWERX_ROOT/state"
TAKWERX_CONFIG="$TAKWERX_ROOT/config"
# Lima keeps its instances and network config here, isolated from any Lima the user already runs.
export LIMA_HOME="${LIMA_HOME:-$TAKWERX_ROOT/lima}"

VM_NAME=takwerx
CONTAINER_NAME=takwerx-atak
# takwerx runs its own adb server on its own port, so Android Studio, Gradle or any other adb
# client on this machine can never kill the server that the ATAK window depends on.
export ANDROID_ADB_SERVER_PORT=5038
export ADB_SERVER_SOCKET=tcp:127.0.0.1:5038
VOLUME_NAME=takwerx-data
ADB_ENDPOINT=127.0.0.1:5555
ATAK_PACKAGE=com.atakmap.app.civ   # ATAK-CIV; the mil build is com.atakmap.app

# shellcheck source=../versions.env
. "$TAKWERX_APP/versions.env"

mkdir -p "$TAKWERX_BIN" "$TAKWERX_TOOLS" "$TAKWERX_CACHE" "$TAKWERX_LOGS" "$TAKWERX_STATE" "$LIMA_HOME"

case "$(uname -s)" in
  Darwin) HOST_OS=macos ;;
  Linux)  HOST_OS=linux ;;
  *) echo "Unsupported host: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) HOST_ARCH=arm64;  SCRCPY_ARCH=aarch64 ;;
  x86_64)        HOST_ARCH=x86_64; SCRCPY_ARCH=x86_64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
# The runtime a fresh install gets: the Android Emulator on the GPU on Apple Silicon (fast,
# full-size icons, no VM, no admin password); redroid in the VM elsewhere, until the
# emulator path is built for those hosts. `takwerx runtime` switches.
if [ "$HOST_OS" = macos ] && [ "$HOST_ARCH" = arm64 ]; then RUNTIME_DEFAULT=emulator; else RUNTIME_DEFAULT=redroid; fi

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; DIM=''; NC=''
fi

LOG_FILE="$TAKWERX_LOGS/takwerx.log"
log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
say()  { printf '%s\n' "$*"; log "$*"; }
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$NC"; log "==> $*"; }
ok()   { printf '%s  ok%s  %s\n' "$GREEN" "$NC" "$*"; log "ok: $*"; }
warn() { printf '%s  !!%s  %s\n' "$YELLOW" "$NC" "$*" >&2; log "warn: $*"; }
die()  { printf '%sError:%s %s\n' "$RED" "$NC" "$*" >&2; log "error: $*"; alert "$*"; exit 1; }

# True when a terminal is available for prompts, even when stdin is a pipe (curl | bash).
have_tty() { [ -r /dev/tty ] && [ -w /dev/tty ] && { : </dev/tty; } 2>/dev/null; }

# ask PROMPT [DEFAULT]: prints the answer. Runs without a terminal get DEFAULT.
ask() {
  local prompt=$1 default=${2:-} ans=''
  if have_tty; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r ans </dev/tty || ans=''
  fi
  printf '%s' "${ans:-$default}"
}
confirm() { local a; a=$(ask "$1 [y/N] " n); [[ $a == [Yy]* ]]; }

config_get() {
  local key=$1 default=${2:-} val=''
  if [ -f "$TAKWERX_CONFIG" ]; then
    val=$(grep -E "^${key}=" "$TAKWERX_CONFIG" | tail -n1 | cut -d= -f2- || true)
  fi
  printf '%s' "${val:-$default}"
}
config_set() {
  local key=$1 val=$2
  touch "$TAKWERX_CONFIG"
  { grep -vE "^${key}=" "$TAKWERX_CONFIG" || true; printf '%s=%s\n' "$key" "$val"; } >"$TAKWERX_CONFIG.tmp"
  mv "$TAKWERX_CONFIG.tmp" "$TAKWERX_CONFIG"
}
config_unset() {
  [ -f "$TAKWERX_CONFIG" ] || return 0
  { grep -vE "^$1=" "$TAKWERX_CONFIG" || true; } >"$TAKWERX_CONFIG.tmp"
  mv "$TAKWERX_CONFIG.tmp" "$TAKWERX_CONFIG"
}

# Desktop notification and error dialog, so a run started from the app icon is never silent.
notify() {
  log "notify: $1"
  case "$HOST_OS" in
    macos) osascript -e "display notification \"${1//\"/\\\"}\" with title \"TAKWERX\"" >/dev/null 2>&1 || true ;;
    linux) command -v notify-send >/dev/null 2>&1 && notify-send "TAKWERX" "$1" || true ;;
  esac
}
alert() {
  [ "${TAKWERX_FROM_APP:-0}" = 1 ] || return 0
  case "$HOST_OS" in
    macos) osascript -e "display dialog \"${1//\"/\\\"}\" with title \"TAKWERX\" buttons {\"OK\"} default button 1 with icon stop" >/dev/null 2>&1 || true ;;
    linux) command -v zenity >/dev/null 2>&1 && zenity --error --text="$1" || true ;;
  esac
}

# download URL DEST: skips when DEST already exists, shows progress on a terminal.
download() {
  local url=$1 dest=$2
  if [ -s "$dest" ]; then return 0; fi
  step "Downloading $(basename "$dest")"
  local flags=(-fL --retry 3 --retry-delay 2 -o "$dest.part")
  if have_tty; then flags+=(--progress-bar); else flags+=(-sS); fi
  curl "${flags[@]}" "$url" || die "Download failed: $url"
  mv "$dest.part" "$dest"
}

# unpack_to TGZ DIR VERSION [STRIP]: replaces DIR with the archive and records VERSION.
unpack_to() {
  local tgz=$1 dir=$2 version=$3 strip=${4:-0}
  rm -rf "$dir"; mkdir -p "$dir"
  tar -xzf "$tgz" -C "$dir" --strip-components="$strip"
  printf '%s\n' "$version" >"$dir/.version"
}
tool_version() { cat "$1/.version" 2>/dev/null || true; }

host_mem_gb() {
  case "$HOST_OS" in
    macos) echo $(( $(sysctl -n hw.memsize) / 1073741824 )) ;;
    linux) awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo ;;
  esac
}
host_cpus() {
  case "$HOST_OS" in
    macos) sysctl -n hw.ncpu ;;
    linux) nproc ;;
  esac
}
host_timezone() {
  case "$HOST_OS" in
    macos) readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##' ;;
    linux) cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##' ;;
  esac
}
clamp() {
  local v=$1 lo=$2 hi=$3
  if [ "$v" -lt "$lo" ]; then v=$lo; fi
  if [ "$v" -gt "$hi" ]; then v=$hi; fi
  echo "$v"
}

# Newest ATAK CIV APK next to takwerx (the folder it was downloaded in) or in ~/Downloads.
find_atak_apk() {
  ls -t "$TAKWERX_APP"/../ATAK-*civ-release.apk "$TAKWERX_APP"/ATAK-*civ-release.apk "$HOME"/Downloads/ATAK-*civ-release.apk 2>/dev/null | head -n1 || true
}
# ATAK-5.8.0.4-174b425-civ-release.apk -> 5.8.0.4
apk_version_from_name() { basename "$1" | sed -nE 's/^ATAK-([0-9]+(\.[0-9]+)+)-.*/\1/p'; }
