#!/usr/bin/env bash
# Android image and data volume test (ops #1319). Run it the same way CI does:
#   bash .github/ci/test_android_image.sh
#
# On the redroid runtime Android's data lives in the takwerx-data volume and outlasts the
# container. takwerx reused a stopped container with `podman start`, so a new REDROID_IMAGE pin
# never reached an existing install, and nothing recorded which image had written the volume:
# a takwerx moved back to an older pin (a rollback, an old install.sh) would have booted older
# Android code on data a newer image had migrated, the Authentik pattern. Today the old and the
# new pin are the same image, so nothing broke yet. Now:
#   1. redroid_age / redroid_older read the date in the tag (14.0.0_64only-240527), never a floating tag
#   2. a pin older than the image that wrote the data is refused, and nothing is created
#   3. a stopped container made from another pin is replaced, the volume stays, and the new pin is recorded
#   4. a running container made from another pin is stopped and replaced
#   5. a container made from this pin is only started, not recreated
#   6. a container made before the label existed is judged by the image name podman recorded
#   7. a data record for a volume that is gone (limactl delete) is dropped, not obeyed
#   8. a new container carries the label, and reset (volume_remove) drops the record
#   9. an install with no record (every install before this) keeps working and gets one
# Runs the real container_start and friends from lib/android.sh with a fake VM. Needs no VM,
# no Android and no network.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0
check() { # check NAME COMMAND...
  local name=$1; shift
  if "$@" >"$WORK/out" 2>&1; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/       /' "$WORK/out"; FAILS=$((FAILS + 1)); fi
}

export HOME="$WORK/home" TAKWERX_ROOT="$WORK/home/.takwerx" CMDS="$WORK/cmds"
mkdir -p "$HOME"

# The pins as takwerx has them and some others.
PIN_OLD='docker.io/redroid/redroid:14.0.0_64only-240101@sha256:1111111111111111111111111111111111111111111111111111111111111111'
PIN_NEW='docker.io/redroid/redroid:14.0.0_64only-240527@sha256:0a611199ba2e0b5d60af39b3327a517f6407231f4352114ed3bd3cbfe2be69aa'
PIN_NEXT='docker.io/redroid/redroid:15.0.0_64only-250301@sha256:2222222222222222222222222222222222222222222222222222222222222222'

# load [PIN]: the libraries as ./takwerx loads them, then a fake VM. vm_run logs every command and
# answers from the environment: VOL (volume exists: yes/no), EXISTS (container exists), RUNNING,
# LABEL (the container's takwerx_image label, or empty for none), IMGNAME (podman's ImageName).
load() {
  set -euo pipefail
  rm -rf "$TAKWERX_ROOT"
  TAKWERX_APP=$REPO; TAKWERX_VERSION=$(cat "$REPO/VERSION")
  # shellcheck source=/dev/null
  . "$REPO/lib/common.sh"
  case "$(uname -s)" in Darwin) . "$REPO/lib/host-macos.sh" ;; *) . "$REPO/lib/host-linux.sh" ;; esac
  # shellcheck source=/dev/null
  . "$REPO/lib/vm.sh"; . "$REPO/lib/android.sh"
  if [ -n "${1:-}" ]; then REDROID_IMAGE=$1; fi
  : >"$CMDS"
  vm_run() {
    printf '%s\n' "$1" >>"$CMDS"
    case "$1" in
      "podman volume exists"*) [ "${VOL:-yes}" = yes ]; return ;;
      "podman container exists"*) [ "${EXISTS:-no}" = yes ]; return ;;
      *State.Running*) printf '%s\n' "${RUNNING:-false}"; return 0 ;;
      *takwerx_image*) if [ -n "${LABEL:-}" ]; then printf '%s\n' "$LABEL"; else printf '<no value>\n'; fi; return 0 ;;
      *ImageName*) printf '%s\n' "${IMGNAME:-}"; return 0 ;;
      *MemTotal*) printf '6000\n'; return 0 ;;
    esac
    return 0
  }
  binder_ready() { return 0; }
  # a stop is only logged: the real one talks to ATAK and adb
  container_stop() { printf 'STOP\n' >>"$CMDS"; }
  lease_stop() { :; }
}
ran() { grep -q -- "$1" "$CMDS"; }

t_age() {
  ( load
    [ "$(redroid_age "$PIN_NEW")" = 14.0.0.240527 ] || { echo "age of the pin: $(redroid_age "$PIN_NEW")"; exit 1; }
    ! redroid_age docker.io/redroid/redroid:14.0.0_64only-latest || { echo "a floating tag has an age"; exit 1; }
    redroid_older "$PIN_OLD" "$PIN_NEW" || { echo "240101 is not older than 240527"; exit 1; }
    ! redroid_older "$PIN_NEW" "$PIN_OLD" || { echo "240527 is older than 240101"; exit 1; }
    ! redroid_older "$PIN_NEW" "$PIN_NEW" || { echo "an image is older than itself"; exit 1; }
    redroid_older "$PIN_NEW" "$PIN_NEXT" || { echo "Android 14 is not older than Android 15"; exit 1; }
    ! redroid_older docker.io/redroid/redroid:14.0.0_64only-latest "$PIN_NEW" || { echo "a floating tag counts as older"; exit 1; } )
}
check "redroid_age and redroid_older read the date in the tag; a floating tag is never older" t_age

t_refuse() {
  ( load "$PIN_NEW"; config_set DATA_IMAGE "$PIN_NEXT"
    VOL=yes EXISTS=yes RUNNING=false container_start ) >"$WORK/refuse.out" 2>&1
  local rc=$?
  [ "$rc" -ne 0 ] || { echo "a pin older than the data was started:"; cat "$WORK/refuse.out"; return 1; }
  grep -q "written by a newer Android image" "$WORK/refuse.out" || { echo "wrong message:"; cat "$WORK/refuse.out"; return 1; }
  grep -q "takwerx reset" "$WORK/refuse.out" || { echo "the message does not name the way out:"; cat "$WORK/refuse.out"; return 1; }
  if grep -qE 'podman (run|create|start|rm)' "$CMDS"; then echo "touched the container though it refused:"; cat "$CMDS"; return 1; fi
  grep -qxF "DATA_IMAGE=$PIN_NEXT" "$TAKWERX_ROOT/config" || { echo "the data record changed"; return 1; }
}
check "a pin older than the image that wrote the data is refused, nothing is created or started" t_refuse

t_recreate_stopped() {
  ( load "$PIN_NEW"; config_set DATA_IMAGE "$PIN_OLD"
    VOL=yes EXISTS=yes RUNNING=false LABEL="$PIN_OLD" container_start >/dev/null
    ran 'podman rm -f' || { echo "the old container was not removed"; cat "$CMDS"; exit 1; }
    ran 'podman run -d' || { echo "no new container was made"; cat "$CMDS"; exit 1; }
    ran "$PIN_NEW" || { echo "the new container does not use the pin"; cat "$CMDS"; exit 1; }
    if ran 'podman volume rm'; then echo "the data volume was removed"; exit 1; fi
    [ "$(config_get DATA_IMAGE)" = "$PIN_NEW" ] || { echo "DATA_IMAGE is $(config_get DATA_IMAGE)"; exit 1; } )
}
check "a stopped container made from another pin is replaced, the volume stays, the new pin is recorded" t_recreate_stopped

t_recreate_running() {
  ( load "$PIN_NEW"; config_set DATA_IMAGE "$PIN_OLD"
    VOL=yes EXISTS=yes RUNNING=true LABEL="$PIN_OLD" container_start >/dev/null
    grep -qx STOP "$CMDS" || { echo "the running container was not stopped first"; cat "$CMDS"; exit 1; }
    ran 'podman run -d' || { echo "no new container was made"; cat "$CMDS"; exit 1; } )
}
check "a running container made from another pin is stopped and replaced" t_recreate_running

t_same_pin() {
  ( load "$PIN_NEW"; config_set DATA_IMAGE "$PIN_NEW"
    VOL=yes EXISTS=yes RUNNING=false LABEL="$PIN_NEW" container_start >/dev/null
    ran 'podman start' || { echo "the container was not started"; cat "$CMDS"; exit 1; }
    if ran 'podman rm' || ran 'podman run' || ran 'podman create'; then echo "recreated a container made from this pin:"; cat "$CMDS"; exit 1; fi )
}
check "a container made from this pin is only started" t_same_pin

t_legacy() {
  ( load "$PIN_NEW"
    # made before the label existed: judged by the image name podman recorded
    VOL=yes EXISTS=yes RUNNING=false LABEL='' IMGNAME="$PIN_NEW" container_start >/dev/null
    ran 'podman start' || { echo "a same-image legacy container was not just started"; cat "$CMDS"; exit 1; }
    if ran 'podman run' || ran 'podman create'; then echo "recreated a legacy container made from this pin"; exit 1; fi
    : >"$CMDS"
    VOL=yes EXISTS=yes RUNNING=false LABEL='' IMGNAME="$PIN_OLD" container_start >/dev/null
    ran 'podman run -d' || { echo "a legacy container made from another image was kept"; cat "$CMDS"; exit 1; } )
}
check "a container made before the label existed is judged by podman's image name" t_legacy

t_volume_gone() {
  ( load "$PIN_NEW"; config_set DATA_IMAGE "$PIN_NEXT"
    VOL=no EXISTS=no RUNNING=false container_start >/dev/null
    ran 'podman run -d' || { echo "did not start: a record for a deleted volume was obeyed"; cat "$CMDS"; exit 1; }
    [ "$(config_get DATA_IMAGE)" = "$PIN_NEW" ] || { echo "DATA_IMAGE is $(config_get DATA_IMAGE)"; exit 1; } )
}
check "a data record for a volume that no longer exists is dropped, not obeyed" t_volume_gone

t_label_reset() {
  ( load "$PIN_NEW"
    VOL=yes EXISTS=no RUNNING=false container_start >/dev/null
    grep -q -- "--label takwerx_image=$PIN_NEW" "$CMDS" || { echo "the new container has no takwerx_image label:"; cat "$CMDS"; exit 1; }
    [ "$(config_get DATA_IMAGE)" = "$PIN_NEW" ] || { echo "DATA_IMAGE not recorded"; exit 1; }
    volume_remove
    [ -z "$(config_get DATA_IMAGE)" ] || { echo "reset kept DATA_IMAGE"; exit 1; } )
}
check "a new container carries the label and the record; volume_remove drops the record" t_label_reset

t_no_record() {
  ( load "$PIN_NEW"
    [ -z "$(config_get DATA_IMAGE)" ] || { echo "setup: a record exists"; exit 1; }
    redroid_data_check || { echo "refused an install with no record"; exit 1; }
    VOL=yes EXISTS=yes RUNNING=false LABEL="$PIN_NEW" container_start >/dev/null || { echo "did not start"; exit 1; }
    ran 'podman start' || { echo "the container was not started"; cat "$CMDS"; exit 1; }
    : >"$CMDS"
    VOL=yes EXISTS=no container_start >/dev/null
    [ "$(config_get DATA_IMAGE)" = "$PIN_NEW" ] || { echo "no record after a create: $(config_get DATA_IMAGE)"; exit 1; } )
}
check "an install with no record (made before this change) starts as before" t_no_record

[ "$FAILS" -eq 0 ] || { echo "$FAILS check(s) failed"; exit 1; }
echo "all Android image checks passed"
