#!/usr/bin/env bash
# Rough edges found in the 0.2.16 T&E (ops #1411). Run it the same way CI does:
#   bash .github/ci/test_update_edges.sh
#
#   1. a fresh `install.sh` (no ~/.takwerx/app yet) prints no "No such file" line
#   2. emu_stop returns only when the emulator process is gone (after the 45 s limit and the forced stop)
#   2b. emu_stop still finishes when `adb emu kill` never answers (frozen emulator process; ops #1423)
#   3. init_emulator does not open the APK file picker while Android is not answering on adb
#      (the update sat 7 minutes on a macOS dialog), and still asks first when Android answers and ATAK is missing
#   4. closing the terminal that started the emulator on Linux does not hang it up (QEMU shuts down on SIGHUP)
# Needs no Android, no VM and no network. Check 4 runs on Linux only (setsid).
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0
check() { # check NAME COMMAND...
  local name=$1; shift
  if "$@" >"$WORK/out" 2>&1; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/       /' "$WORK/out"; FAILS=$((FAILS + 1)); fi
}
export HOME="$WORK/home" TAKWERX_ROOT="$WORK/home/.takwerx"
mkdir -p "$HOME"

# --- 1. install.sh on a computer that has never had takwerx -------------------------------------------
# A fake curl: the VERSION file answers, the download fails. install.sh stops there ("Could not
# download"); what matters is what it printed on the way.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOS'
#!/usr/bin/env bash
case "$*" in *VERSION*) echo 9.9.9; exit 0 ;; esac
exit 22
EOS
chmod +x "$WORK/bin/curl"
t_install_quiet() {
  PATH="$WORK/bin:$PATH" bash "$REPO/install.sh" >"$WORK/inst.out" 2>"$WORK/inst.err"
  if grep -q 'No such file' "$WORK/inst.err"; then echo "install.sh printed a raw error on a fresh computer:"; cat "$WORK/inst.err"; return 1; fi
  grep -q 'Could not download takwerx' "$WORK/inst.err" || { echo "install.sh did not reach the download step:"; cat "$WORK/inst.err"; return 1; }
}
check "install.sh on a fresh computer prints no 'No such file' line" t_install_quiet

# --- libraries, loaded the way ./takwerx loads them ---------------------------------------------------
load() {
  set -euo pipefail
  TAKWERX_APP=$REPO; TAKWERX_VERSION=$(cat "$REPO/VERSION")
  # shellcheck source=/dev/null
  . "$REPO/lib/common.sh"
  case "$(uname -s)" in Darwin) . "$REPO/lib/host-macos.sh" ;; *) . "$REPO/lib/host-linux.sh" ;; esac
  # shellcheck source=/dev/null
  . "$REPO/lib/vm.sh"; . "$REPO/lib/android.sh"; . "$REPO/lib/emulator.sh"
  adb_server_ensure() { :; }
  sleep() { :; }                                   # the waits are counted, not slept
}

# --- 2. emu_stop waits for the process after the forced stop ------------------------------------------
t_stop_waits() {
  ( load
    printf '#!/usr/bin/env bash\ncase "$*" in *"emu kill"*) : > "%s/killed" ;; esac\nexit 0\n' "$WORK" > "$WORK/adb"; chmod +x "$WORK/adb"
    ADB=$WORK/adb
    rm -f "$WORK/killed"; polls=0
    # Running until the kill, then still listed for four more looks (the process takes a moment to exit).
    emu_running() { if [ -e "$WORK/killed" ]; then polls=$((polls + 1)); [ "$polls" -le 4 ]; else return 0; fi; }
    emu_pid() { echo 99999999; }
    android_online() { return 1; }
    emu_stop
    if emu_running; then echo "emu_stop returned while the emulator was still listed as running"; exit 1; fi )
}
check "emu_stop returns only when the emulator process is gone" t_stop_waits

# --- 2b. a frozen emulator: `adb emu kill` never answers (ops #1423) -----------------------------------
# The stand-in adb hangs for 30 s on `emu kill`; the stand-in emulator ignores SIGTERM. emu_stop must
# give up on adb after EMU_KILL_TIMEOUT (2 s here), then finish through kill and kill -9 in well under 30 s.
t_stop_frozen() {
  ( load
    printf '#!/usr/bin/env bash\ncase "$*" in *"emu kill"*) : > "%s/asked"; exec sleep 30 ;; esac\nexit 0\n' "$WORK" > "$WORK/adb-frozen"; chmod +x "$WORK/adb-frozen"
    ADB=$WORK/adb-frozen EMU_KILL_TIMEOUT=2
    rm -f "$WORK/asked"
    ( trap '' TERM; exec sleep 300 ) & fpid=$!
    emu_pid() { echo "$fpid"; }
    emu_running() { case "$(ps -o stat= -p "$fpid" 2>/dev/null)" in ''|*Z*) return 1 ;; esac; return 0; }
    android_online() { return 1; }
    start=$SECONDS
    emu_stop
    took=$((SECONDS - start))
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do emu_running || break; command sleep 0.1; done
    alive=0; emu_running && alive=1
    kill -9 "$fpid" 2>/dev/null || true
    [ -e "$WORK/asked" ] || { echo "the stand-in adb was never asked to emu kill: the test proves nothing"; exit 1; }
    if [ "$took" -ge 20 ]; then echo "emu_stop waited ${took} s for a frozen adb emu kill (limit: a few seconds)"; exit 1; fi
    if [ "$alive" = 1 ]; then echo "the emulator process that ignores SIGTERM is still running after emu_stop"; exit 1; fi )
}
check "emu_stop finishes when adb emu kill never answers (frozen emulator)" t_stop_frozen

# --- 3. the APK question waits for Android ------------------------------------------------------------
t_init() { # t_init ONLINE(1|0): the order of "ASKED" and "UP" in init_emulator
  ( load
    eval "$(awk '/^init_emulator\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REPO/takwerx")"
    mkdir -p "$EMU_AVD_HOME/$EMU_AVD.avd"; : > "$EMU_AVD_HOME/$EMU_AVD.avd/config.ini"
    emu_disk_check() { :; }; emu_sdk_install() { :; }; app_build() { :; }; location_refresh() { :; }
    emu_running() { return 0; }; emu_copy_current() { return 0; }; emu_image_current() { return 0; }
    atak_installed() { return 1; }
    if [ "$1" = 1 ]; then android_online() { return 0; }; else android_online() { return 1; }; fi
    init_ask_apk() { echo ASKED >>"$WORK/order"; }
    emu_up() { echo UP >>"$WORK/order"; }
    app_label() { echo app; }; app_home() { echo home; }
    rm -f "$WORK/order"
    init_emulator "" 0 >/dev/null 2>&1 )
  head -n1 "$WORK/order"
}
t_adb_offline() { [ "$(t_init 0)" = UP ] || { echo "the APK picker came before Android started, with adb offline:"; cat "$WORK/order"; return 1; }; }
t_adb_online()  { [ "$(t_init 1)" = ASKED ] || { echo "Android answers and ATAK is missing: the question should come before emu_up:"; cat "$WORK/order"; return 1; }; }
check "init_emulator does not open the APK picker while adb is offline" t_adb_offline
check "init_emulator still asks first when Android answers and ATAK is missing" t_adb_online

# --- 4. a hangup on the terminal does not stop the emulator (Linux) -----------------------------------
t_hangup() {
  mkdir -p "$WORK/fakeemu"
  # A stand-in for QEMU: its own SIGHUP handler (nohup's "ignore" is replaced, as QEMU does), a marker when hung up.
  cat > "$WORK/fakeemu/emulator" <<EOS
#!/usr/bin/env python3
import os, signal, sys, time
def hup(*_):
    open("$WORK/hup", "w").write("hangup")
    os._exit(0)
signal.signal(signal.SIGHUP, hup)
open("$WORK/emu.pid", "w").write(str(os.getpid()))
time.sleep(25)
EOS
  chmod +x "$WORK/fakeemu/emulator"
  cat > "$WORK/start.sh" <<EOS
set -euo pipefail
export HOME="$HOME" TAKWERX_ROOT="$TAKWERX_ROOT" DISPLAY=""
TAKWERX_APP="$REPO"; TAKWERX_VERSION=\$(cat "$REPO/VERSION")
. "$REPO/lib/common.sh"; . "$REPO/lib/host-linux.sh"; . "$REPO/lib/vm.sh"; . "$REPO/lib/android.sh"; . "$REPO/lib/emulator.sh"
EMU_DIR="$WORK/fakeemu"
emu_libs_check() { :; }; emu_gpu_mode() { echo swiftshader_indirect; }; emu_geometry() { echo "1 1 1"; }
tool_version() { echo fake; }; step() { :; }; warn() { :; }; log() { :; }
emu_start_linux
sleep 20
EOS
  rm -f "$WORK/hup" "$WORK/emu.pid"
  python3 -I - "$WORK" <<'EOP'
import os, pty, sys, time
work = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", work + "/start.sh"])
for _ in range(100):
    if os.path.exists(work + "/emu.pid"): break
    time.sleep(0.1)
time.sleep(0.5)
os.close(fd)                 # the terminal window closes: the kernel hangs up the session
time.sleep(2)
try:
    os.kill(pid, 9)
except OSError:
    pass
EOP
  [ -s "$WORK/emu.pid" ] || { echo "the stand-in emulator never started"; return 1; }
  local epid; epid=$(cat "$WORK/emu.pid")
  local alive=0; kill -0 "$epid" 2>/dev/null && alive=1
  kill -9 "$epid" 2>/dev/null || true
  if [ -e "$WORK/hup" ] || [ "$alive" = 0 ]; then echo "the emulator got SIGHUP when the terminal closed (Android would power off)"; return 1; fi
}
if [ "$(uname -s)" = Linux ] && command -v setsid >/dev/null 2>&1; then
  check "closing the terminal does not hang up the emulator (Linux)" t_hangup
else
  echo "skip closing the terminal (Linux with setsid only)"
fi

[ "$FAILS" -eq 0 ] || { echo "$FAILS check(s) failed"; exit 1; }
echo "all update-edge checks passed"
