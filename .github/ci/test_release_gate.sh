#!/usr/bin/env bash
# Scenario tests for the release gate in release.sh (ops #693): it must refuse to run unless the
# install-and-update smoke (tools/release-smoke.sh) passed for this exact tree. Throwaway repos, no
# network, no GitHub: the gate sits before release.sh's first `gh` call, and a fake `gh` that is not
# logged in shows which scenarios got past the gate. Run it the same way CI does:
#   bash .github/ci/test_release_gate.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0

mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/gh"; chmod +x "$WORK/bin/gh"

# scenario NAME EXPECT SETUP_FUNCTION
#   EXPECT is "smoke" (refused by the smoke gate) or "through" (got past it: stops later at gh's login).
scenario() {
  local name=$1 expect=$2 setup=$3
  local d="$WORK/$name"
  mkdir -p "$d" && cd "$d" || exit 2
  git init -q -b main . && git config user.email t@t && git config user.name t
  cp "$REPO_ROOT/release.sh" . && echo 0.1.0 >VERSION && printf '# Changelog\n\n## 0.1.1 - today\n\n- a thing\n' >CHANGELOG.md
  printf 'reports/\n' >.gitignore
  git add -A && git -c commit.gpgsign=false commit -q -m init
  "$setup"
  PATH="$WORK/bin:$PATH" bash release.sh 0.1.1 >out.txt 2>&1
  local got=$? blocked=0
  grep -qE 'smoke' out.txt && blocked=1
  if { [ "$expect" = smoke ] && [ "$got" -ne 0 ] && [ "$blocked" -eq 1 ]; } \
     || { [ "$expect" = through ] && [ "$got" -ne 0 ] && grep -q 'gh is not logged in' out.txt; }; then
    echo "ok   $name"
  else
    echo "FAIL $name: wanted '$expect', exit $got"; sed 's/^/     /' out.txt; fails=$((fails + 1))
  fi
  cd "$WORK" || exit 2
}

write_pass() {  # VERSION COMMIT
  mkdir -p reports
  printf 'version %s\ncommit %s\ndate now\nstep x\n' "$1" "$2" >reports/smoke-0.1.1.pass
}
s_none() { :; }
s_other_version() { write_pass 0.1.0 "$(git rev-parse HEAD)"; }
s_unknown_commit() { write_pass 0.1.1 0000000000000000000000000000000000000000; }
s_ok() { write_pass 0.1.1 "$(git rev-parse HEAD)"; }
s_code_changed_after() { write_pass 0.1.1 "$(git rev-parse HEAD)"; echo '# new code' >>release.sh; git add -A; git -c commit.gpgsign=false commit -q -m "more code"; }
s_changelog_after() { write_pass 0.1.1 "$(git rev-parse HEAD)"; echo '- more' >>CHANGELOG.md; echo 0.1.1 >VERSION; git add -A; git -c commit.gpgsign=false commit -q -m "notes"; }

scenario no-smoke-file        smoke   s_none
scenario smoke-for-other-ver  smoke   s_other_version
scenario smoke-on-unknown-sha smoke   s_unknown_commit
scenario code-changed-since   smoke   s_code_changed_after
scenario smoke-passed         through s_ok
scenario only-notes-changed   through s_changelog_after

[ "$fails" -eq 0 ] || { echo "release gate tests FAILED ($fails)"; exit 1; }
echo "release gate tests passed"
