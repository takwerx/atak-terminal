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
# And it leaves USB alone. An adb server claims every USB phone it sees, and two servers on
# one Mac race for each phone plugged in; the loser drops that phone until it is replugged.
# takwerx's ATAK runs in the VM or the emulator, never on a USB phone, so its server has no
# use for them, and a developer's own adb server keeps them (MacBook, 2026-10-24: a phone on
# USB that no adb listed until it was replugged).
export ADB_USB=0
# And it does not scan for emulators. A server tries ports 5555-5585 when it starts, and on
# redroid the VM's forward on 127.0.0.1:5555 answers: a server started while the VM was up
# (after any reboot of the Mac) took Android as emulator-5554 as well, and the next bridged
# restart left 127.0.0.1:5555 unseen for five minutes (Studio, 2026-10-24). The scan also
# claimed other emulators on the Mac. takwerx's own emulator does not need it: it registers
# with the server on 5038 itself, within a second of a fresh server starting.
# Both are read by the server only when it starts (adb_server_ensure, lib/android.sh).
export ADB_EMU=0
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
# On Linux there is only the emulator (Intel and AMD, with KVM).
if { [ "$HOST_OS" = macos ] && [ "$HOST_ARCH" = arm64 ]; } || [ "$HOST_OS" = linux ]; then RUNTIME_DEFAULT=emulator; else RUNTIME_DEFAULT=redroid; fi
# How messages name the computer.
if [ "$HOST_OS" = macos ]; then HOST_THIS="this Mac"; else HOST_THIS="this computer"; fi

# A program that must outlive the terminal that started it runs in a session of its own.
# Closing a Terminal window hangs up the terminal's session: the kernel sends SIGHUP to the
# foreground process group. QEMU (the Android emulator) takes SIGHUP as a power-off request and
# installs a handler of its own, so `nohup` does not protect it, and Android went off when the
# window that ran `takwerx init` was closed (Linux, ops #1411; Mac, ops #1431). macOS has no
# `setsid` command; perl, which lib/apk-icon.pl needs anyway, makes the same system call and
# then runs the program in place (same process, same command line). With neither, the program
# starts as before, under nohup alone.
#   own_session_init; nohup ${OWN_SESSION[@]+"${OWN_SESSION[@]}"} PROGRAM ARGS... &
# (the + form: the Mac's bash 3.2 calls an empty array an unset variable under set -u.)
own_session_init() {
  # shellcheck disable=SC2034  # read by the callers in lib/emulator.sh
  OWN_SESSION=()
  if command -v setsid >/dev/null 2>&1; then
    OWN_SESSION=(setsid)
  elif command -v perl >/dev/null 2>&1; then
    OWN_SESSION=(perl -MPOSIX -e 'POSIX::setsid(); exec { $ARGV[0] } @ARGV or die "takwerx: cannot run $ARGV[0]: $!\n"' --)
  fi
}

if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; DIM=''; NC=''
fi

LOG_FILE="$TAKWERX_LOGS/takwerx.log"
# No log folder (after `takwerx uninstall` deletes it): the message goes to the screen only.
log()  { [ -d "$TAKWERX_LOGS" ] || return 0; printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
say()  { printf '%s\n' "$*"; log "$*"; }
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$NC"; log "==> $*"; }
ok()   { printf '%s  ok%s  %s\n' "$GREEN" "$NC" "$*"; log "ok: $*"; }
warn() { printf '%s  !!%s  %s\n' "$YELLOW" "$NC" "$*" >&2; log "warn: $*"; }
die()  { printf '%sError:%s %s\n' "$RED" "$NC" "$*" >&2; log "error: $*"; alert "$*"; exit 1; }

# Takes out of each shell profile given what path_setup added: the export line, the
# "# takwerx" line above it and the blank line above that. Nothing else changes. The file
# is rewritten in place (cat >), so a profile that is a symlink stays one.
path_lines_remove() {
  local line="export PATH=\"$TAKWERX_BIN:\$PATH\"" rc tmp
  for rc in "$@"; do
    [ -f "$rc" ] && grep -qxF "$line" "$rc" || continue
    tmp=$(mktemp) || return 0
    awk -v line="$line" '
      function emit() { if (nb) print ""; if (hc) print "# takwerx"; nb = 0; hc = 0 }
      $0 == "" { if (hc) emit(); else if (nb) print ""; nb = 1; next }
      $0 == "# takwerx" { if (hc) emit(); hc = 1; next }
      $0 == line { nb = 0; hc = 0; next }
      { emit(); print }
      END { emit() }' "$rc" >"$tmp" && cat "$tmp" >"$rc"
    rm -f "$tmp"
  done
}

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

# Never go backwards (ops #1318). takwerx keeps the highest version it has run in
# $TAKWERX_STATE/highest (lines NAME=VALUE: takwerx, android_api), and refuses to move to a
# lower one unless TAKWERX_ALLOW_DOWNGRADE=1. A release version is exactly X.Y.Z; anything
# else that GitHub answers with (a captive-portal page, an error page) is not a version.
semver_ok() { [[ ${1:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
# ver_lt A B: A is older than B. Only for values that look like versions.
ver_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; }
# seen_get NAME: the recorded value, or nothing. It must always return 0: every install made by 0.2.15
# or older has no state/highest, and sed exits 2 on a missing file, which under `set -euo pipefail`
# (takwerx, install.sh) ended `takwerx init` silently (ops #1398).
seen_get() { [ -f "$TAKWERX_STATE/highest" ] || return 0; sed -n "s/^$1=//p" "$TAKWERX_STATE/highest" 2>/dev/null | tail -n1 || true; }
# seen_note NAME VALUE [force]: raises the record; a lower value never replaces a higher one,
# unless force (a downgrade the person asked for).
seen_note() {
  local name=$1 val=$2 force=${3:-} have f="$TAKWERX_STATE/highest"
  [[ $name =~ ^[a-z_]+$ ]] && [[ $val =~ ^[0-9][0-9A-Za-z._-]*$ ]] || return 0
  have=$(seen_get "$name")
  if [ -n "$have" ] && [ "$force" != force ] && ! ver_lt "$have" "$val"; then return 0; fi
  mkdir -p "$TAKWERX_STATE"
  { grep -v "^$name=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$name" "$val"; } >"$f.tmp" && mv "$f.tmp" "$f"
}
# takwerx_downgrade_refused CANDIDATE: prints why and returns 0 when CANDIDATE is older than
# the takwerx that is installed or the highest one that has run here. Returns 1 when it is fine.
takwerx_downgrade_refused() {
  local cand=$1 have
  [ "${TAKWERX_ALLOW_DOWNGRADE:-0}" = 1 ] && return 1
  semver_ok "$cand" || return 1
  for have in "$(tr -d '[:space:]' <"$TAKWERX_APP/VERSION" 2>/dev/null || true)" "$(seen_get takwerx)"; do
    have=${have%%-*}
    semver_ok "$have" || continue
    if ver_lt "$cand" "$have"; then
      printf 'takwerx %s is older than the takwerx you have (%s), so it was not installed. Nothing changed. To go back on purpose: TAKWERX_ALLOW_DOWNGRADE=1 takwerx update' "$cand" "$have"
      return 0
    fi
  done
  return 1
}
# tool_needs NAME DIR PIN: 0 when DIR must be (re)installed to PIN: nothing there, or an older
# version. A tool NEWER than the pin stays: a newer Lima or emulator was put there by a newer
# takwerx or by the person, and this takwerx has no business replacing it with an older build.
tool_needs() {
  local name=$1 have pin=$3
  have=$(tool_version "$2")
  [ "$have" != "$pin" ] || return 1
  if [[ $have =~ ^[0-9][0-9A-Za-z._-]*$ ]] && ver_lt "$pin" "$have"; then
    warn "$name $have is newer than the $pin this takwerx pins; keeping $have"
    return 1
  fi
  return 0
}

# Where takwerx comes from. Releases: the VERSION file on main names the newest one and
# the tag v<VERSION> holds it, so a push to main between releases reaches nobody until
# release.sh runs (DECISIONS 2026-09-27). TAKWERX_BRANCH=<branch> takes a development
# branch instead. Prints "URL<space>description", or fails. The version must be X.Y.Z.
takwerx_source() {
  local repo=${TAKWERX_REPO:-takwerx/atak-terminal} ver
  if [ -n "${TAKWERX_BRANCH:-}" ]; then
    printf 'https://github.com/%s/archive/refs/heads/%s.tar.gz branch %s\n' "$repo" "$TAKWERX_BRANCH" "$TAKWERX_BRANCH"; return 0
  fi
  ver=$(curl -fsSL --max-time 10 "https://raw.githubusercontent.com/$repo/main/VERSION" 2>/dev/null | tr -d '[:space:]') || return 1
  semver_ok "$ver" || return 1
  printf 'https://github.com/%s/archive/refs/tags/v%s.tar.gz release %s\n' "$repo" "$ver" "$ver"
}

# Is a newer takwerx released? The version on main is fetched once a day at most (three
# seconds, one small file, silent on failure) and kept in the stamp file. From the app icon
# ("notify") a notification goes out on the day the news arrives; in a terminal ("print",
# from up and status) one line is printed for as long as the install is behind.
update_check() {
  local mode=${1:-notify} stamp="$TAKWERX_STATE/update-check" latest fresh=0 repo=${TAKWERX_REPO:-takwerx/atak-terminal}
  mkdir -p "$TAKWERX_STATE"
  if [ ! -f "$stamp" ] || [ -z "$(find "$stamp" -mtime -1 2>/dev/null)" ]; then
    latest=$(curl -fsSL --max-time 3 "https://raw.githubusercontent.com/$repo/main/VERSION" 2>/dev/null | tr -d '[:space:]') || latest=""
    semver_ok "$latest" || latest=""
    printf '%s\n' "$latest" >"$stamp"; fresh=1
  fi
  latest=$(tr -d '[:space:]' <"$stamp" 2>/dev/null || true)
  semver_ok "$latest" || return 0
  [ "$latest" != "$TAKWERX_VERSION" ] || return 0
  [ "$(printf '%s\n%s\n' "$TAKWERX_VERSION" "$latest" | sort -V | tail -n1)" = "$latest" ] || return 0
  [ "$fresh" = 1 ] && log "update available: $latest"
  case "$mode" in
    notify) [ "$fresh" = 1 ] && notify "takwerx $latest is available (you have $TAKWERX_VERSION). In Terminal: takwerx update" ;;
    print)  printf '%s  --%s  takwerx %s is available (you have %s): takwerx update, then takwerx restart. Notes: https://github.com/%s/releases\n' "$YELLOW" "$NC" "$latest" "$TAKWERX_VERSION" "$repo" ;;
  esac
  return 0
}

sha256_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
# sed -i with no backup file: BSD sed (a Mac) wants an empty argument after -i, GNU sed (Linux) none.
sed_inplace() { if [ "$HOST_OS" = macos ]; then sed -i '' "$@"; else sed -i "$@"; fi; }
# Modification time in seconds: BSD stat on a Mac, GNU stat on Linux.
file_mtime() { if [ "$HOST_OS" = macos ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi 2>/dev/null || echo 0; }
# pin_sha256 NAME: the SHA-256 versions.env pins for this Mac's architecture, NAME_SHA256_ARM64
# or NAME_SHA256_X86_64. Fails when there is none, so nothing pinned is fetched unverified.
pin_sha256() {
  local v
  v="$1_SHA256_$(printf '%s' "$HOST_ARCH" | tr '[:lower:]' '[:upper:]')"
  [ -n "${!v:-}" ] || die "versions.env has no $v"
  printf '%s' "${!v}"
}

# download URL DEST [SHA256]: skips when DEST already exists, shows progress on a terminal.
# With SHA256, a cached DEST that does not match is fetched again, and a fresh download that
# does not match is deleted and refused before anything uses it.
download() {
  local url=$1 dest=$2 sha=${3:-} from=${4:-versions.env pins} have
  if [ -s "$dest" ]; then
    if [ -z "$sha" ] || [ "$(sha256_of "$dest")" = "$sha" ]; then return 0; fi
    warn "$(basename "$dest") in the cache does not match its pinned SHA-256; downloading it again"
    rm -f "$dest"
  fi
  step "Downloading $(basename "$dest")"
  local flags=(-fL --retry 3 --retry-delay 2 -o "$dest.part")
  if have_tty; then flags+=(--progress-bar); else flags+=(-sS); fi
  curl "${flags[@]}" "$url" || { rm -f "$dest.part"; die "Download failed: $url"; }
  if [ -n "$sha" ]; then
    have=$(sha256_of "$dest.part")
    if [ "$have" != "$sha" ]; then
      rm -f "$dest.part"
      die "Refused $(basename "$dest"): its SHA-256 is $have, but $from $sha. The file is deleted and nothing was installed. Run the command again; if this repeats, the download is being altered on the way, so report it"
    fi
  fi
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
    printf '%s\t%s\t%s\n' "$v" "$(file_mtime "$f")" "$f"
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
