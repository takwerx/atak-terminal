#!/usr/bin/env bash
# Lima pin test (ops #825). Run it the same way CI does:
#   bash .github/ci/test_lima_pin.sh
#
# Lima is the VM tool takwerx installs on the Mac. Lima before 2.3.0 has two public advisories
# (GHSA-566x-598w-h7w7, GHSA-4wvf-9pjc-cpfp), so versions.env must never go back below it, and
# its SHA-256 pins must be the ones the Lima release itself publishes. With the old pin
# (2.2.1) checks 1 and 3 fail; with 2.3.0 and its pins all four pass.
#
#   1. LIMA_VERSION is at least 2.3.0
#   2. both Lima SHA-256 pins are 64 hex digits
#   3. both pins equal the line for that tarball in the release's own SHA256SUMS (one small
#      download from github.com; a download failure fails the test, it is never skipped)
#   4. the VM template asks for the vz driver and mounts nothing, which is why the two
#      advisories do not reach takwerx users even on the old version: if either changes, the
#      advisories must be read again
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0
check() { # check NAME COMMAND...
  local name=$1; shift
  if "$@" >"$WORK/out" 2>&1; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/       /' "$WORK/out"; FAILS=$((FAILS + 1)); fi
}

# shellcheck source=/dev/null
. "$REPO/versions.env"
MIN_LIMA=2.3.0

t_version() {
  [[ ${LIMA_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "LIMA_VERSION '${LIMA_VERSION:-}' is not X.Y.Z"; return 1; }
  [ "$(printf '%s\n%s\n' "$MIN_LIMA" "$LIMA_VERSION" | sort -V | head -n1)" = "$MIN_LIMA" ] \
    || { echo "LIMA_VERSION is $LIMA_VERSION; below $MIN_LIMA it has GHSA-566x-598w-h7w7 and GHSA-4wvf-9pjc-cpfp"; return 1; }
}
check "Lima is $MIN_LIMA or newer" t_version

t_hex() {
  local v
  for v in LIMA_SHA256_ARM64 LIMA_SHA256_X86_64; do
    [[ ${!v:-} =~ ^[0-9a-f]{64}$ ]] || { echo "$v is missing or not a SHA-256"; return 1; }
  done
}
check "both Lima pins are SHA-256 values" t_hex

t_sums() {
  local sums="$WORK/SHA256SUMS" arch want got
  curl -fsSL --retry 3 --retry-delay 2 -o "$sums" \
    "https://github.com/lima-vm/lima/releases/download/v$LIMA_VERSION/SHA256SUMS" \
    || { echo "could not download the SHA256SUMS of Lima $LIMA_VERSION"; return 1; }
  for arch in ARM64 X86_64; do
    case $arch in ARM64) want=$LIMA_SHA256_ARM64; file="lima-$LIMA_VERSION-Darwin-arm64.tar.gz" ;;
                  *)     want=$LIMA_SHA256_X86_64; file="lima-$LIMA_VERSION-Darwin-x86_64.tar.gz" ;; esac
    got=$(awk -v f="$file" '$2 == f { print $1 }' "$sums")
    [ -n "$got" ] || { echo "$file is not in the release's SHA256SUMS"; return 1; }
    [ "$got" = "$want" ] || { echo "$file: versions.env pins $want, the release publishes $got"; return 1; }
  done
}
check "pins match the Lima release's own SHA256SUMS" t_sums

t_template() {
  grep -qE '^vmType: vz$' "$REPO/lima/takwerx.yaml.tmpl" || { echo "the VM template no longer sets vmType: vz"; return 1; }
  grep -qE '^mounts: \[\]$' "$REPO/lima/takwerx.yaml.tmpl" || { echo "the VM template no longer has mounts: []"; return 1; }
  if grep -rnE 'limactl.*shell.*--sync|LIMACTL.*shell.*--sync' "$REPO/takwerx" "$REPO/lib" "$REPO/install.sh"; then
    echo "a script calls limactl shell --sync; read GHSA-4wvf-9pjc-cpfp again"; return 1
  fi
}
check "VM template: vz driver, no mounts, no limactl shell --sync" t_template

[ "$FAILS" -eq 0 ] || { echo "$FAILS check(s) failed"; exit 1; }
echo "all Lima pin checks passed"
