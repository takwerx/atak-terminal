#!/usr/bin/env bash
# Release assets (ops #1021). Every release must list its source tarball, SBOM and SHA256SUMS
# (workers/RELEASE.md, "Release files"). v0.2.13 and v0.2.14 were cut with ./release.sh, which only
# makes the GitHub release, and nobody ran release-assets after it, so the newest release had no files.
# This checks the newest published release (the one GitHub shows as Latest). Run it the same way CI does:
#   bash .github/ci/release_assets.sh
#
# It fails (exit 1) when that release is missing any of
#   atak-terminal-vX.Y.Z-source.tar.gz   atak-terminal-vX.Y.Z.cdx.json   SHA256SUMS
# and fails with exit 2 when the check itself could not read the release (no network, bad answer).
# Fix a red check by attaching the files:  release-assets atak-terminal vX.Y.Z  (release worker).
#
# Environment: RELEASE_JSON is a file holding the GitHub API answer for one release (the self-test
# uses it). Otherwise it reads https://api.github.com/repos/$REPO/releases/latest, sending the
# CI token (GH_API_TOKEN) when one is set. REPO defaults to takwerx/atak-terminal.
set -uo pipefail

repo=${REPO:-takwerx/atak-terminal}
if [ -n "${RELEASE_JSON:-}" ]; then
  json=$(cat "$RELEASE_JSON") || { echo "::error::cannot read $RELEASE_JSON"; exit 2; }
else
  auth=()
  [ -n "${GH_API_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_API_TOKEN")
  json=""
  for attempt in 1 2 3; do
    json=$(curl -fsSL --max-time 30 ${auth[@]+"${auth[@]}"} -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$repo/releases/latest") && break
    json=""; sleep $((attempt * 3))
  done
  [ -n "$json" ] || { echo "::error::could not read the latest release of $repo from GitHub"; exit 2; }
fi

result=$(printf '%s' "$json" | python3 -I -c '
import json, sys
try:
    r = json.load(sys.stdin)
    tag = r["tag_name"]
    have = {a["name"] for a in r.get("assets", [])}
except Exception as e:
    print("BAD " + str(e)); sys.exit(0)
need = ["atak-terminal-%s-source.tar.gz" % tag, "atak-terminal-%s.cdx.json" % tag, "SHA256SUMS"]
missing = [n for n in need if n not in have]
print(("MISSING %s %s" % (tag, " ".join(missing))) if missing else ("OK " + tag))
')
# shellcheck disable=SC2086  # the MISSING answer is split on purpose: "TAG FILE FILE"
case "$result" in
  OK\ *)      echo "release assets passed (${result#OK } lists its tarball, SBOM and SHA256SUMS)" ;;
  MISSING\ *) set -- ${result#MISSING }; tag=$1; shift
              echo "::error::release $tag is missing: $*. Attach them: release-assets atak-terminal $tag (ops #1021)"
              echo "release assets FAILED" >&2; exit 1 ;;
  *)          echo "::error::could not read the release answer: ${result#BAD }"; exit 2 ;;
esac
