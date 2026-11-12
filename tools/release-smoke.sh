#!/usr/bin/env bash
# Pre-release install-and-update smoke (ops #693). Run it before ./release.sh:
#
#   ./tools/release-smoke.sh X.Y.Z            full smoke (downloads the pinned tools, about 1 minute)
#   ./tools/release-smoke.sh X.Y.Z --quick    no downloads; never accepted by release.sh
#
# Why: installed Macs and PCs update themselves from the newest tag within a day, so a
# release that cannot install or update reaches every user. This builds the exact tree the
# tag will hold (HEAD, with VERSION set to X.Y.Z) and, in a scratch home that never touches
# a real install, checks what a user does:
#   1. fresh install: the candidate unpacks the way install.sh does, `takwerx version` and
#      `takwerx help` run, and the pinned Lima and scrcpy download and match their SHA-256.
#   2. update: the previous release is installed, then replaced by the candidate the way
#      `takwerx update` swaps the app, its pinned tools are brought up to the candidate's
#      pins, and the previous release's saved settings are still read.
# On success it writes reports/smoke-X.Y.Z.pass. release.sh refuses to run without that file
# for this commit. There is no way around it: a failed smoke is fixed, not skipped.
#
# NOT covered, and still needed by the T&E before a release ask: ATAK itself (start the
# emulator, load ATAK, connect to a TAK Server, run a command) and the Windows engine
# (parsed in CI, run on a PC). This smoke proves the install and update machinery only.
set -euo pipefail
cd "$(dirname "$0")/.."
v=${1:-}
quick=0; [ "${2:-}" = "--quick" ] && quick=1
die() { printf 'release-smoke: %s\n' "$*" >&2; exit 1; }
pass() { printf '  PASS  %s\n' "$*"; steps+=("$*"); }
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: ./tools/release-smoke.sh X.Y.Z [--quick]"
steps=()

# Only VERSION and CHANGELOG.md may differ from HEAD (release.sh commits them).
dirty=$(git status --porcelain | grep -vE ' (CHANGELOG\.md|VERSION)$' || true)
[ -z "$dirty" ] || die "commit or stash first:"$'\n'"$dirty"
head=$(git rev-parse HEAD)

S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/home" "$S/cand"
git archive HEAD | tar -x -C "$S/cand"
printf '%s\n' "$v" >"$S/cand/VERSION"
echo "Smoke for takwerx $v (commit ${head:0:9}); scratch folder $S"

# tools_install APPDIR ROOT: the install step that downloads and unpacks Lima and scrcpy,
# run from that app's own scripts, with a scratch home and root.
tools_install() {
  (
    export HOME="$S/home" TAKWERX_ROOT="$2" TAKWERX_APP="$1"
    # shellcheck disable=SC1091
    . "$1/lib/common.sh"
    case "$HOST_OS" in
      macos) . "$1/lib/host-macos.sh" ;;
      linux) . "$1/lib/host-linux.sh" ;;
    esac
    host_tools_install
  ) >"$S/tools.log" 2>&1 || { tail -n 20 "$S/tools.log" >&2; return 1; }
}
# engine APPDIR ROOT ARGS...: run that app's takwerx with the scratch home.
engine() { local app=$1 root=$2; shift 2; HOME="$S/home" TAKWERX_ROOT="$root" "$app/takwerx" "$@"; }
# setting_set / setting_get APPDIR ROOT KEY [VALUE]: the saved settings file, through the app's own functions.
setting() {
  (
    export HOME="$S/home" TAKWERX_ROOT="$2" TAKWERX_APP="$1"
    # shellcheck disable=SC1091
    . "$1/lib/common.sh"
    if [ $# -ge 4 ]; then config_set "$3" "$4"; else config_get "$3" ""; fi
  )
}

echo "== 1. fresh install of the candidate"
R1="$S/fresh/.takwerx"; mkdir -p "$R1"
mv "$S/cand" "$R1/app" 2>/dev/null || true
[ -x "$R1/app/takwerx" ] || chmod +x "$R1/app/takwerx"
[ "$(engine "$R1/app" "$R1" version)" = "$v" ] || die "the candidate's 'takwerx version' is not $v"
pass "takwerx version prints $v"
engine "$R1/app" "$R1" help | grep -q "takwerx $v" || die "'takwerx help' does not name $v"
pass "takwerx help runs"
if [ "$quick" = 0 ]; then
  tools_install "$R1/app" "$R1" || die "the pinned tools did not download and verify"
  pass "pinned Lima and scrcpy download and match their SHA-256"
fi

echo "== 2. update from the previous release"
prev=$(git for-each-ref --format='%(refname:strip=2)' 'refs/tags/v[0-9]*' | sort -V | tail -n1)
if [ -z "$prev" ]; then
  pass "no earlier release to update from (first release)"
else
  R2="$S/update/.takwerx"; mkdir -p "$R2/app"
  git archive "$prev" | tar -x -C "$R2/app"
  if [ "$(uname -s)" = Linux ] && [ ! -f "$R2/app/lib/host-linux.sh" ]; then
    pass "$prev has no Linux host, update step skipped on this computer"
  else
    pv=$(tr -d '[:space:]' <"$R2/app/VERSION")
    [ "$(engine "$R2/app" "$R2" version)" = "$pv" ] || die "the previous release ($prev) does not run"
    pass "previous release $prev runs"
    [ "$quick" = 1 ] || { tools_install "$R2/app" "$R2" || die "the previous release's tools did not install"; }
    setting "$R2/app" "$R2" SMOKE_KEEP ok
    # takwerx update's swap: the new tree replaces app/, state next to it stays.
    cp -R "$R1/app" "$R2/app.new"
    rm -rf "$R2/app.old"; mv "$R2/app" "$R2/app.old"; mv "$R2/app.new" "$R2/app"; rm -rf "$R2/app.old"
    [ "$(engine "$R2/app" "$R2" version)" = "$v" ] || die "after the update 'takwerx version' is not $v"
    pass "after the update takwerx is $v"
    [ "$(setting "$R2/app" "$R2" SMOKE_KEEP)" = ok ] || die "the saved settings from $prev are lost after the update"
    pass "settings saved by $prev survive the update"
    if [ "$quick" = 0 ]; then
      tools_install "$R2/app" "$R2" || die "the candidate could not bring the tools to its pins"
      pass "tools are at the candidate's pins after the update"
    fi
  fi
fi

if [ "$quick" = 1 ]; then
  echo "Quick smoke passed (no downloads). release.sh does not accept it; run without --quick."
  exit 0
fi
mkdir -p reports
{
  echo "version $v"
  echo "commit $head"
  echo "date $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'step %s\n' "${steps[@]}"
} >"reports/smoke-$v.pass"
echo "Smoke passed. Wrote reports/smoke-$v.pass; now: ./release.sh $v"
