#!/usr/bin/env bash
# Self-test for release_assets.sh (ops #1021): made-up GitHub release answers, exit code of each.
# The first case is what v0.2.13 and v0.2.14 looked like on GitHub: a release with no assets.
#   bash .github/ci/test_release_assets.sh
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/release_assets.sh"
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
bad=0

# case NAME EXPECTED_EXIT 'JSON'
case_() {
  printf '%s' "$3" >"$work/release.json"
  RELEASE_JSON="$work/release.json" bash "$script" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: wanted exit $2, got $got"; bad=1; fi
}

T=v0.2.14
TAR="{\"name\":\"atak-terminal-$T-source.tar.gz\"}"; SBOM="{\"name\":\"atak-terminal-$T.cdx.json\"}"; SUMS='{"name":"SHA256SUMS"}'
case_ "no assets at all (v0.2.14 on Nov 17)"  1 "{\"tag_name\":\"$T\",\"assets\":[]}"
case_ "assets key missing"                    1 "{\"tag_name\":\"$T\"}"
case_ "tarball only"                          1 "{\"tag_name\":\"$T\",\"assets\":[$TAR]}"
case_ "no SHA256SUMS"                         1 "{\"tag_name\":\"$T\",\"assets\":[$TAR,$SBOM]}"
case_ "files of an older version"             1 "{\"tag_name\":\"$T\",\"assets\":[{\"name\":\"atak-terminal-v0.2.12-source.tar.gz\"},{\"name\":\"atak-terminal-v0.2.12.cdx.json\"},$SUMS]}"
case_ "all three files"                       0 "{\"tag_name\":\"$T\",\"assets\":[$TAR,$SBOM,$SUMS]}"
case_ "all three plus an extra file"          0 "{\"tag_name\":\"$T\",\"assets\":[$TAR,$SBOM,$SUMS,{\"name\":\"extra.zip\"}]}"
case_ "answer is not a release (API error)"   2 '{"message":"Not Found"}'
case_ "answer is not JSON"                    2 'rate limited'
exit "$bad"
