#!/usr/bin/env bash
# Self-test for release_hygiene.sh (ops #370): runs it in a scratch repo against made-up VERSION,
# CHANGELOG and tag lists, and checks the exit code of each case.
#   bash .github/ci/test_release_hygiene.sh
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/release_hygiene.sh"
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q
bad=0

# case NAME EXPECTED_EXIT VERSION "TOP_HEADING" "TAGS" [BASE_REF] [BODY]
case_() {
  local name=$1 want=$2 ver=$3 head=$4 tags=$5 base=${6:-dev} body=${7:-- A thing that works better.}
  printf '%s\n' "$ver" >"$work/VERSION"
  printf '# Changelog\n\nNewest first.\n\n%s\n\n%s\n\n## 0.1.0 — 2026-09-01\n\n- Old.\n' "$head" "$body" >"$work/CHANGELOG.md"
  (cd "$work" && TAGS="$tags" BASE_REF=$base bash "$script" >/dev/null 2>&1)
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: wanted exit $want, got $got"; bad=1; fi
}

T="v0.1.0 v0.2.9 v0.2.10 v0.2.11"
case_ "version = tag, notes match"                0 0.2.11     "## 0.2.11 — 2026-10-25" "$T"
case_ "tag order is numeric, not alphabetical"    0 0.2.11     "## 0.2.11 — 2026-10-25" "v0.2.9 v0.2.11 v0.2.10"
case_ "heading without a date"                    0 0.2.11     "## 0.2.11" "$T"
case_ "version behind the newest tag"             1 0.2.10     "## 0.2.10 — 2026-10-22" "$T"
case_ "version ahead of the tag, no -dev"         1 0.2.12     "## 0.2.12 — 2026-10-31" "$T"
case_ "-dev ahead of the tag, notes still at tag" 0 0.2.12-dev "## 0.2.11 — 2026-10-25" "$T"
case_ "-dev ahead of the tag, own notes written"  0 0.2.12-dev "## 0.2.12 — 2026-10-31" "$T"
case_ "-dev ahead of the tag, wrong notes"        1 0.2.12-dev "## 0.2.13 — 2026-10-31" "$T"
case_ "-dev equal to the tag"                     0 0.2.11-dev "## 0.2.11 — 2026-10-25" "$T"
case_ "-dev behind the tag"                       1 0.2.10-dev "## 0.2.10 — 2026-10-22" "$T"
case_ "-dev must not reach main"                  1 0.2.12-dev "## 0.2.12 — 2026-10-31" "$T" main
case_ "main: version = tag"                       0 0.2.11     "## 0.2.11 — 2026-10-25" "$T" main
case_ "notes newest section is older"             1 0.2.11     "## 0.2.10 — 2026-10-22" "$T"
case_ "notes newest section is newer"             1 0.2.11     "## 0.2.12 — 2026-10-31" "$T"
case_ "notes section empty"                       1 0.2.11     "## 0.2.11 — 2026-10-25" "$T" dev " "
case_ "developer words only warn"                 0 0.2.11     "## 0.2.11 — 2026-10-25" "$T" dev "- Fixed lib/emulator.sh (ops #12, abc1234def)."
case_ "VERSION not a version"                     1 latest     "## 0.2.11 — 2026-10-25" "$T"
case_ "two-part VERSION"                          1 0.2        "## 0.2.11 — 2026-10-25" "$T"
case_ "no tags fetched"                           2 0.2.11     "## 0.2.11 — 2026-10-25" ""
case_ "non-release tags ignored"                  0 0.2.11     "## 0.2.11 — 2026-10-25" "$T v9.9.9-rc1 nightly"
exit "$bad"
