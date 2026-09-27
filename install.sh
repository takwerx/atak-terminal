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
if [ -n "${TAKWERX_BRANCH:-}" ]; then
  REF="heads/$TAKWERX_BRANCH"; WHAT="branch $TAKWERX_BRANCH"
else
  VER=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/VERSION" | tr -d '[:space:]') \
    || { echo "Could not read the current takwerx version from GitHub" >&2; exit 1; }
  REF="tags/v$VER"; WHAT="release $VER"
fi
echo "==> Downloading takwerx ($REPO, $WHAT)"
curl -fsSL "https://github.com/$REPO/archive/refs/$REF.tar.gz" -o "$ROOT/cache/app.tar.gz" \
  || { echo "Could not download takwerx ($WHAT)" >&2; exit 1; }
rm -rf "$APP.new"; mkdir -p "$APP.new"
tar -xzf "$ROOT/cache/app.tar.gz" -C "$APP.new" --strip-components=1
rm -rf "$APP"; mv "$APP.new" "$APP"
chmod +x "$APP/takwerx"
exec "$APP/takwerx" init "$@"
