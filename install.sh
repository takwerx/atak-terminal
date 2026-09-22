#!/usr/bin/env bash
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/takwerx/takwerx-desktop/main/install.sh | bash
# Downloads takwerx into ~/.takwerx/app and runs `takwerx init`, which does everything else.
set -euo pipefail
REPO=${TAKWERX_REPO:-takwerx/takwerx-desktop}
BRANCH=${TAKWERX_BRANCH:-main}
ROOT=${TAKWERX_ROOT:-$HOME/.takwerx}
APP="$ROOT/app"
case "$(uname -s)" in
  Darwin|Linux) ;;
  *) echo "takwerx runs on macOS and Linux; on Windows use install.ps1" >&2; exit 1 ;;
esac
mkdir -p "$ROOT/cache"
echo "==> Downloading takwerx ($REPO, $BRANCH)"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" -o "$ROOT/cache/app.tar.gz"
rm -rf "$APP.new"; mkdir -p "$APP.new"
tar -xzf "$ROOT/cache/app.tar.gz" -C "$APP.new" --strip-components=1
rm -rf "$APP"; mv "$APP.new" "$APP"
chmod +x "$APP/takwerx"
exec "$APP/takwerx" init "$@"
