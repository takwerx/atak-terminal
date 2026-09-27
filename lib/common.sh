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

# A native file picker for the ATAK-CIV APK, the one thing takwerx cannot fetch itself
# (tak.gov, behind a login; the official GitHub releases carry no APK). Prints the path,
# or nothing when the user cancels or picks something that is not an APK.
atak_pick() {
  local f=""
  case "$HOST_OS" in
    macos) f=$(osascript -e 'POSIX path of (choose file with prompt "Pick the ATAK-CIV APK you downloaded from tak.gov" default location (path to downloads folder))' 2>/dev/null || true) ;;
    linux) command -v zenity >/dev/null 2>&1 && f=$(zenity --file-selection --title="Pick the ATAK-CIV APK you downloaded from tak.gov" --filename="$HOME/Downloads/" 2>/dev/null || true) ;;
  esac
  f=${f%$'\n'}
  [ -n "$f" ] || return 0
  case "$f" in
    *.apk) printf '%s\n' "$f" ;;
    *) warn "$(basename "$f") is not an APK; nothing installed" ;;
  esac
}

# The app icon's version: a dialog first, so the picker does not appear out of nowhere.
atak_ask_pick() {
  local b
  case "$HOST_OS" in
    macos)
      b=$(osascript -e 'button returned of (display dialog "ATAK is not installed yet.\n\nDownload ATAK-CIV from tak.gov (it needs a login), then pick the file here." with title "TAKwerx ATAK Terminal" buttons {"Open tak.gov", "Choose the APK"} default button 2 with icon note)' 2>/dev/null || true)
      case "$b" in
        "Choose the APK") atak_pick ;;
        "Open tak.gov") open "https://tak.gov/products/atak-civ" >/dev/null 2>&1 || true; atak_pick ;;
      esac ;;
    *) atak_pick ;;
  esac
}

# Once a day, from the app icon: is a newer takwerx published? Three seconds at most,
# nothing sent but the request for one small file, and silent on any failure.
update_check() {
  local stamp="$TAKWERX_STATE/update-check" latest repo=${TAKWERX_REPO:-takwerx/atak-terminal}
  if [ -f "$stamp" ] && [ -n "$(find "$stamp" -mtime -1 2>/dev/null)" ]; then return 0; fi
  mkdir -p "$TAKWERX_STATE"; touch "$stamp"
  latest=$(curl -fsSL --max-time 3 "https://raw.githubusercontent.com/$repo/main/VERSION" 2>/dev/null | tr -d '[:space:]') || return 0
  [ -n "$latest" ] && [ "$latest" != "$TAKWERX_VERSION" ] || return 0
  [ "$(printf '%s\n%s\n' "$TAKWERX_VERSION" "$latest" | sort -V | tail -n1)" = "$latest" ] || return 0
  notify "takwerx $latest is available (you have $TAKWERX_VERSION). In Terminal: takwerx update"
  log "update available: $latest"
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
# The newest ATAK by version number, not by file date: a Downloads folder holds several
# (this Mac had 5.1 to 5.8.0.5), and an older one copied later would otherwise win.
# Plugins are named ATAK-Plugin-... and are never ATAK; the name must be ATAK-<version>
# or ATAK-CIV-<version>. Same version twice: the newer file.
find_atak_apk() {
  local f v
  for f in "$TAKWERX_APP"/../*.apk "$TAKWERX_APP"/*.apk "$HOME"/Downloads/*.apk; do
    [ -f "$f" ] || continue
    v=$(apk_version_from_name "$f"); [ -n "$v" ] || continue
    printf '%s\t%s\t%s\n' "$v" "$(stat -f %m "$f" 2>/dev/null || echo 0)" "$f"
  done | sort -t "$(printf '\t')" -k1,1V -k2,2n | tail -n1 | cut -f3- || true
}
# ATAK-5.8.0.4-174b425-civ-release.apk, ATAK-CIV-5.8.0.4-...apk, the civ "small" build:
# -> 5.8.0.4. The name must say civ somewhere (this runtime is for ATAK-CIV's package)
# and start with ATAK and a version; plugins (ATAK-Plugin-...) give nothing.
apk_version_from_name() {
  local n; n=$(basename "$1")
  printf '%s' "$n" | grep -qi civ || return 0
  printf '%s' "$n" | sed -nE 's/^[Aa][Tt][Aa][Kk]-([Cc][Ii][Vv]-)?([0-9]+(\.[0-9]+)+)[-.].*\.apk$/\2/p'
}
