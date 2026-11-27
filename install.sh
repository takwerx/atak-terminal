#!/usr/bin/env bash
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.sh | bash
# Downloads takwerx into ~/.takwerx/app and runs `takwerx init`, which does everything else.
set -euo pipefail
REPO=${TAKWERX_REPO:-takwerx/atak-terminal}
ROOT=${TAKWERX_ROOT:-$HOME/.takwerx}
APP="$ROOT/app"
case "$(uname -s)" in
  Darwin|Linux) ;;
  *) echo "takwerx runs on macOS and Linux; on Windows use install.ps1" >&2; exit 1 ;;
esac
mkdir -p "$ROOT/cache"
# The newest release: the VERSION file on main names it, and the tag v<VERSION> holds it.
# TAKWERX_BRANCH=<branch> takes a development branch instead.
# Never go backwards (ops #1318): if a newer takwerx is installed, or has run here, the install
# line stops and changes nothing. TAKWERX_ALLOW_DOWNGRADE=1 goes back on purpose. A release
# version is exactly X.Y.Z; a captive-portal or error page is not one.
semver_ok() { [[ ${1:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
if [ ! -d "$APP" ] && [ -d "$APP.old" ]; then mv "$APP.old" "$APP"; fi  # a swap an earlier run left half done
VER=''
if [ -n "${TAKWERX_BRANCH:-}" ]; then
  REF="heads/$TAKWERX_BRANCH"; WHAT="branch $TAKWERX_BRANCH"
else
  VER=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/VERSION" | tr -d '[:space:]') \
    || { echo "Could not read the current takwerx version from GitHub" >&2; exit 1; }
  semver_ok "$VER" || { echo "GitHub did not answer with a takwerx version number (got: ${VER:0:40}). Nothing changed" >&2; exit 1; }
  if [ "${TAKWERX_ALLOW_DOWNGRADE:-0}" != 1 ]; then
    # `tr <file 2>/dev/null` still prints "No such file" when the file is missing: the shell opens the
    # file before the 2>/dev/null takes effect. A fresh install has no VERSION yet (ops #1411).
    for have in "$([ -r "$APP/VERSION" ] && tr -d '[:space:]' <"$APP/VERSION" || true)" "$(sed -n 's/^takwerx=//p' "$ROOT/state/highest" 2>/dev/null | tail -n1)"; do
      have=${have%%-*}
      semver_ok "$have" || continue
      if [ "$VER" != "$have" ] && [ "$(printf '%s\n%s\n' "$VER" "$have" | sort -V | head -n1)" = "$VER" ]; then
        echo "takwerx $VER is older than the takwerx you have ($have), so it was not installed. Nothing changed. To go back on purpose: TAKWERX_ALLOW_DOWNGRADE=1, then the install line again" >&2
        exit 1
      fi
    done
  fi
  REF="tags/v$VER"; WHAT="release $VER"
fi
echo "==> Downloading takwerx ($REPO, $WHAT)"
curl -fsSL "https://github.com/$REPO/archive/refs/$REF.tar.gz" -o "$ROOT/cache/app.tar.gz" \
  || { echo "Could not download takwerx ($WHAT)" >&2; exit 1; }
rm -rf "$APP.new"; mkdir -p "$APP.new"
tar -xzf "$ROOT/cache/app.tar.gz" -C "$APP.new" --strip-components=1
# The tag must hold what its name says, before it replaces the working copy.
[ -f "$APP.new/takwerx" ] || { rm -rf "$APP.new"; echo "The download is not takwerx. Nothing changed" >&2; exit 1; }
if [ -n "$VER" ] && [ "$(tr -d '[:space:]' <"$APP.new/VERSION" 2>/dev/null)" != "$VER" ]; then
  rm -rf "$APP.new"; echo "The download says it is not takwerx $VER. Nothing changed" >&2; exit 1
fi
# Swap, keeping the old copy until the new one is in place.
rm -rf "$APP.old"
if [ -d "$APP" ]; then mv "$APP" "$APP.old"; fi
if mv "$APP.new" "$APP"; then rm -rf "$APP.old"
else [ -d "$APP.old" ] && mv "$APP.old" "$APP"; echo "Could not put the new takwerx in place; the old one is back" >&2; exit 1; fi
chmod +x "$APP/takwerx"
exec "$APP/takwerx" init "$@"
