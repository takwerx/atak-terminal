#!/usr/bin/env bash
# `takwerx init --runtime redroid` endpoint test (ops #861). Run it the same way CI does:
#   bash .github/ci/test_init_runtime.sh
#
# On an Apple-silicon Mac the default runtime is the emulator, so lib/emulator.sh fixed the adb
# endpoint at emulator-5574 when it loaded. `init --runtime redroid` then saved the new runtime
# but kept that endpoint, and its wait for the first boot looked for emulator-5574 while Android
# booted in the VM on 127.0.0.1:5555. The wait ran out ("Android did not come up", 300 s) and the
# next command, which read the saved runtime, found Android at once.
#
# This runs the real cmd_init from ./takwerx with the VM steps stubbed, a saved runtime of
# `emulator` (the Apple-silicon starting point) and a fake adb that only knows Android on
# 127.0.0.1:5555. Needs no VM, no Android and no network.
#   1. init --runtime redroid reaches Android (first-boot wait passes) and provisions it on 127.0.0.1:5555
#   2. the endpoint is emulator-5574 again when the runtime is emulator
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0
check() { # check NAME COMMAND...
  local name=$1; shift
  if "$@" >"$WORK/out" 2>&1; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/       /' "$WORK/out"; FAILS=$((FAILS + 1)); fi
}

# A fake adb that knows Android only on serial 127.0.0.1:5555 (redroid through Lima's forward).
cat > "$WORK/adb" <<'EOS'
#!/usr/bin/env bash
serial=""; prev=""
for a in "$@"; do [ "$prev" = -s ] && serial=$a; prev=$a; done
case "$*" in
  *connect*|*disconnect*|*start-server*|*kill-server*) echo "ok"; exit 0 ;;
esac
if [ "$serial" != 127.0.0.1:5555 ]; then echo "error: device '$serial' not found" >&2; exit 1; fi
case "$*" in
  *get-state*) echo device ;;
  *"getprop sys.boot_completed"*) echo 1 ;;
  *) echo ok ;;
esac
EOS
chmod +x "$WORK/adb"

export HOME="$WORK/home" TAKWERX_ROOT="$WORK/home/.takwerx" ADB_BIN="$WORK/adb"
mkdir -p "$HOME/Downloads"

# Load the libraries the way ./takwerx does, then the real cmd_init with the VM steps stubbed.
# uname is stubbed to say "Apple-silicon Mac" so this runs the same on a Linux CI runner: init
# refuses --runtime redroid on Linux before it reaches the endpoint code, and the bug is the
# Apple-silicon path (host-macos.sh only defines functions when sourced, so it loads anywhere).
load() {
  set -euo pipefail
  uname() { case "${1:-}" in -s) echo Darwin ;; -m) echo arm64 ;; *) command uname "$@" ;; esac; }
  TAKWERX_APP=$REPO; TAKWERX_VERSION=$(cat "$REPO/VERSION")
  # shellcheck source=/dev/null
  . "$REPO/lib/common.sh"
  case "$(uname -s)" in Darwin) . "$REPO/lib/host-macos.sh" ;; *) . "$REPO/lib/host-linux.sh" ;; esac
  # shellcheck source=/dev/null
  . "$REPO/lib/vm.sh"; . "$REPO/lib/android.sh"; . "$REPO/lib/emulator.sh"
  adb_server_ensure() { :; }                       # never touch a real adb server
  eval "$(awk '/^cmd_init\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REPO/takwerx")"
  host_check() { :; }; host_tools_install() { :; }; path_setup() { :; }; vm_defaults() { :; }
  vm_exists() { return 0; }; vm_start() { :; }; vm_run() { return 0; }; image_present() { return 0; }
  app_build() { :; }; container_start() { :; }
  android_provision() { echo "PROVISION endpoint=$ADB_ENDPOINT"; exit 0; }   # stops init here
}

t_init_redroid() {
  ( load; config_set RUNTIME emulator            # the Apple-silicon default, saved before init
    . "$REPO/lib/emulator.sh"                      # a fresh load sees runtime=emulator: endpoint emulator-5574
    [ "$ADB_ENDPOINT" = "emulator-$EMU_PORT" ] || { echo "setup: expected the emulator endpoint, got $ADB_ENDPOINT"; exit 1; }
    cmd_init --runtime redroid --no-bridged --no-up ) >"$WORK/init.out" 2>&1 &
  local pid=$! n=0
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
    echo "init was still waiting for Android after 30 s: it looks for the wrong adb endpoint"; tail -n 5 "$WORK/init.out"; return 1
  fi
  wait "$pid"
  grep -q 'PROVISION endpoint=127.0.0.1:5555' "$WORK/init.out" \
    || { echo "init did not provision Android on 127.0.0.1:5555:"; tail -n 8 "$WORK/init.out"; return 1; }
}
check "init --runtime redroid finds Android on 127.0.0.1:5555 with the emulator saved as runtime" t_init_redroid

t_endpoint_emulator() {
  ( load; config_set RUNTIME redroid; . "$REPO/lib/emulator.sh"
    [ "$ADB_ENDPOINT" = 127.0.0.1:5555 ] || { echo "redroid: got $ADB_ENDPOINT"; exit 1; }
    config_set RUNTIME emulator; adb_endpoint_set
    [ "$ADB_ENDPOINT" = "emulator-$EMU_PORT" ] || { echo "emulator: got $ADB_ENDPOINT"; exit 1; } )
}
check "the endpoint follows the runtime in both directions" t_endpoint_emulator

[ "$FAILS" -eq 0 ] || { echo "$FAILS check(s) failed"; exit 1; }
echo "all init-runtime checks passed"
