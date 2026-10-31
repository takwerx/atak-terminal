#!/usr/bin/env bash
# Release hygiene (ops #370). Users receive tags: `install.sh` and `takwerx update` read VERSION on
# main and fetch the tarball of tag v<VERSION>, and the daily notice fires when VERSION moves
# (docs/DECISIONS.md 2026-09-27, "releases"). So these must always agree. Run it the same way CI does:
#   bash .github/ci/release_hygiene.sh
#
#   1. VERSION is X.Y.Z, or X.Y.Z-dev on a branch other than main.
#   2. VERSION without its -dev suffix is never behind the newest tag vX.Y.Z.
#   3. No -dev suffix: VERSION equals the newest tag. With -dev: equal or ahead of it (a dev bump
#      that is already ahead of the tag is fine).
#   4. The newest "## X.Y.Z" section of CHANGELOG.md is VERSION (suffix stripped). A -dev version
#      that is ahead of the tag may still show the tag's section while its own notes are unwritten.
#   5. That section is not empty. Words a user would not know (issue or PR numbers, commit ids, file
#      paths) only print a warning: release notes are for testers, in plain words.
#
# Environment: BASE_REF is the branch the PR targets (CI sets it; main forbids -dev, default is
# "dev"). TAGS (space separated) replaces `git tag`, for the self-test. Exit 1 = a rule failed,
# exit 2 = the check itself could not run (no tags fetched), which also fails the PR.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
fail=0
err() { echo "::error file=${2:-VERSION}::$1"; fail=1; }

base_ref=${BASE_REF:-dev}
version=$(tr -d '[:space:]' <VERSION 2>/dev/null) || version=""
[ -n "$version" ] || { err "VERSION is missing or empty"; exit 1; }
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-dev)?$ ]]; then
  err "VERSION is '$version'; it must look like 0.2.11 (or 0.2.12-dev on a branch other than main)"
  exit 1
fi
stripped=${version%-dev}
is_dev=0; [ "$stripped" != "$version" ] && is_dev=1

# Newest release tag, by version order (not by date or name).
if [ -n "${TAGS+x}" ]; then tags=$TAGS; else tags=$(git for-each-ref --format='%(refname:short)' refs/tags); fi
tag=$(printf '%s\n' $tags | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)
[ -n "$tag" ] || { echo "no release tag (vX.Y.Z) found; fetch tags (fetch-depth: 0)" >&2; exit 2; }

newest() { printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1; }
ahead=0
if [ "$stripped" != "$tag" ]; then
  if [ "$(newest "$stripped" "$tag")" = "$stripped" ]; then ahead=1
  else err "VERSION is $version but the newest tag is v$tag: VERSION is behind the release users get. Set VERSION to $tag (or later)."
  fi
fi
if [ "$ahead" = 1 ] && [ "$is_dev" = 0 ]; then
  err "VERSION is $version but the newest tag is v$tag. Users would be told about $version and fetch a tag that does not exist. Release with ./release.sh $version, or mark a development bump $version-dev."
fi
if [ "$is_dev" = 1 ] && [ "$base_ref" = main ]; then
  err "VERSION is $version: a -dev version must not reach main (users get what main's VERSION names)."
fi

# Release notes: the newest "## X.Y.Z" section.
[ -f CHANGELOG.md ] || { err "CHANGELOG.md is missing" CHANGELOG.md; exit 1; }
heading=$(grep -m1 -E '^## ' CHANGELOG.md || true)
top=$(printf '%s\n' "$heading" | sed -nE 's/^## ([0-9]+\.[0-9]+\.[0-9]+)([^0-9.].*)?$/\1/p')
if [ -z "$top" ]; then
  err "the newest CHANGELOG.md heading is '${heading:-none}'; expected '## X.Y.Z — date'" CHANGELOG.md
elif [ "$top" != "$stripped" ] && ! { [ "$ahead" = 1 ] && [ "$is_dev" = 1 ] && [ "$top" = "$tag" ]; }; then
  err "the newest CHANGELOG.md section is $top but VERSION is $version. Write '## $stripped' at the top of the notes (newest first)." CHANGELOG.md
else
  body=$(awk 'f && /^## /{exit} f{print} /^## /{f=1}' CHANGELOG.md)
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    err "the CHANGELOG.md section for $top is empty" CHANGELOG.md
  else
    jargon=$(printf '%s\n' "$body" | grep -v 'https\?://' | grep -E '(^|[^[:alnum:]])(PR|issue|ops) ?#[0-9]+|(^|[^[:alnum:]])[0-9a-f]{9,40}([^[:alnum:]]|$)|(^|[^[:alnum:]])(lib|helpers|tools|\.github)/[A-Za-z0-9_./-]+|[A-Za-z0-9_-]+\.(sh|ps1|cs|yml|pl)([^[:alnum:]]|$)' || true)
    if [ -n "$jargon" ]; then
      printf '%s\n' "$jargon" | head -n 5 | while IFS= read -r l; do
        echo "::warning file=CHANGELOG.md::notes for $top say something a tester would not know: ${l:0:100}. Plain words for the testers, please."
      done
    fi
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "release hygiene FAILED" >&2
  exit 1
fi
echo "release hygiene passed (VERSION $version, newest tag v$tag, newest notes $top)"
