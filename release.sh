#!/usr/bin/env bash
# Cuts a takwerx release:   ./release.sh 0.1.2
# Before: write the "## 0.1.2 — <date>" section in CHANGELOG.md (it may be uncommitted).
# This bumps VERSION, commits, tags v0.1.2, pushes commit and tag in one atomic push, and
# creates the GitHub release with the CHANGELOG section as its notes. Installed Macs and
# PCs are told within a day and fetch this tag with `takwerx update`, which restarts
# Android onto it by itself (0.2.1 on); the install line fetches it from now on. If
# VERSION already says 0.1.2 and is committed, only the tag and release are made.
set -euo pipefail
cd "$(dirname "$0")"
v=${1:-}
die() { printf 'release: %s\n' "$*" >&2; exit 1; }
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: ./release.sh X.Y.Z"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "release from main"
command -v gh >/dev/null || die "the GitHub CLI (gh) is needed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in"
dirty=$(git status --porcelain | grep -vE ' (CHANGELOG\.md|VERSION)$' || true)
[ -z "$dirty" ] || die "commit or stash first:"$'\n'"$dirty"
git fetch -q origin
git merge-base --is-ancestor origin/main HEAD || die "main is behind origin/main; pull first"
git tag -l "v$v" | grep -q . && die "tag v$v exists already"
git ls-remote --exit-code --tags origin "refs/tags/v$v" >/dev/null 2>&1 && die "tag v$v exists on GitHub already"
grep -qE "^## $v( |$)" CHANGELOG.md || die "CHANGELOG.md has no section '## $v'"
notes=$(awk -v v="$v" '$0 ~ "^## "v"( |$)" {p=1; next} /^## / {p=0} p && (n || $0 != "") {l[++n]=$0} END {while (n && l[n]=="") n--; for (i=1;i<=n;i++) print l[i]}' CHANGELOG.md)
[ -n "$notes" ] || die "the CHANGELOG section for $v is empty"
if [ "$(tr -d '[:space:]' <VERSION)" != "$v" ] || ! git diff --quiet HEAD -- VERSION CHANGELOG.md; then
  printf '%s\n' "$v" >VERSION
  git add VERSION CHANGELOG.md
  git commit -q -m "takwerx $v" -m "$notes"
fi
git tag -a "v$v" -m "takwerx $v" -m "$notes"
git push --atomic origin main "v$v"
# The generic footer only where the section does not say how to get it itself.
footer="

---
Installed, on a Mac or Windows: \`takwerx update\`; it restarts Android by itself when it needs to. New install: the install line in the README."
case "$notes" in *"How to get it"*) footer='' ;; esac
gh release create "v$v" --title "takwerx $v" --notes "$notes$footer"
printf '\nReleased takwerx %s. Installed Macs and PCs hear of it within a day; takwerx update fetches it.\n' "$v"
