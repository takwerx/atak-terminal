#!/usr/bin/env bash
# Market plugin lookup test (ops #1274). Run it the same way CI does:
#   bash .github/ci/test_market_lookup.sh
#
# `market_install` found the Market release through api.github.com with no token. GitHub gives
# that API 60 calls an hour per address, and a shared address (office, hotspot, VPN) runs out. The
# answer is then HTTP 403 "API rate limit exceeded", and takwerx printed "Could not reach GitHub",
# so the install ended with no Market plugin and a retry in the same hour failed the same way.
# Now it reads the release from the github.com pages when the API fails, and says "GitHub is
# limiting requests" only when it really cannot get the release either way.
#
# This runs the real market_install and market_asset_url from ./takwerx with a fake curl (one
# mode per case), a fake adb and a fake download. Needs no network, no Android and no VM.
#   1. API rate-limited (403), github.com pages work: the Market for this ATAK is installed
#   2. API fine: the API answer is used and the web pages are not asked
#   3. API rate-limited and the pages fail: "GitHub is limiting requests", not "Could not reach"
#   4. nothing answers: "Could not reach GitHub"
#   5. API rate-limited, pages work, but the release has no build for this ATAK: "No Market build"
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0
check() { # check NAME COMMAND...
  local name=$1; shift
  if "$@" >"$WORK/out" 2>&1; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/       /' "$WORK/out"; FAILS=$((FAILS + 1)); fi
}

mkdir -p "$WORK/bin"
# A fake curl. FAKE_API is ok, limited or down; FAKE_WEB is ok or down. It handles the flags
# takwerx uses: -f (fail on HTTP errors, exit 22), -o FILE, -w FORMAT, and prints what a real
# curl would for the three github URLs. Every call is appended to $FAKE_LOG.
cat > "$WORK/bin/curl" <<'EOS'
#!/usr/bin/env bash
fail=0; out=''; fmt=''; url=''; prev=''
for a in "$@"; do
  case "$prev" in -o) out=$a ;; -w) fmt=$a ;; esac
  case "$a" in --*) ;; -*f*) fail=1 ;; esac
  case "$a" in http*) url=$a ;; esac
  prev=$a
done
echo "$url" >> "$FAKE_LOG"
emit() { # emit CODE BODY [EFFECTIVE_URL]
  local code=$1 body=$2 eff=${3:-$url}
  if [ "$fail" = 1 ] && [ "$code" -ge 400 ]; then exit 22; fi
  if [ -n "$out" ] && [ "$out" != /dev/null ]; then printf '%s' "$body" > "$out"; elif [ -z "$out" ]; then printf '%s' "$body"; fi
  fmt=${fmt//%\{http_code\}/$code}; fmt=${fmt//%\{url_effective\}/$eff}
  printf '%s' "$fmt"; exit 0
}
asset() { printf 'https://github.com/takwerx/takwerx-market/releases/download/v1.8/ATAK-Plugin-TakwerxMarket-1.8--%s-civ-release.apk' "$1"; }
case "$url" in
  https://api.github.com/repos/takwerx/takwerx-market/releases/latest)
    case "$FAKE_API" in
      ok)      emit 200 "{\"assets\":[{\"browser_download_url\": \"$(asset 5.7.0)\"},{\"browser_download_url\": \"$(asset 5.8.0)\"}]}" ;;
      limited) emit 403 '{"message":"API rate limit exceeded for 203.0.113.9. (But here is the good news: Authenticated requests get a higher rate limit.)"}' ;;
      *)       exit 6 ;;
    esac ;;
  https://github.com/takwerx/takwerx-market/releases/latest)
    [ "$FAKE_WEB" = ok ] || exit 6
    emit 200 '' https://github.com/takwerx/takwerx-market/releases/tag/v1.8 ;;
  https://github.com/takwerx/takwerx-market/releases/expanded_assets/v1.8)
    [ "$FAKE_WEB" = ok ] || exit 6
    emit 200 "<a href=\"/takwerx/takwerx-market/releases/download/v1.8/ATAK-Plugin-TakwerxMarket-1.8--5.7.0-civ-release.apk\">a</a>
<a href=\"/takwerx/takwerx-market/releases/download/v1.8/ATAK-Plugin-TakwerxMarket-1.8--5.8.0-civ-release.apk\">b</a>" ;;
  *) echo "fake curl: unexpected URL $url" >&2; exit 7 ;;
esac
EOS
chmod +x "$WORK/bin/curl"

# A fake adb that accepts every install.
cat > "$WORK/adb" <<'EOS'
#!/usr/bin/env bash
case "$*" in *install*) echo "Success" ;; *) echo ok ;; esac
EOS
chmod +x "$WORK/adb"

export HOME="$WORK/home" TAKWERX_ROOT="$WORK/home/.takwerx" ADB_BIN="$WORK/adb" FAKE_LOG="$WORK/curl.log"
mkdir -p "$HOME"
export PATH="$WORK/bin:$PATH"

# run_market ATAK_VERSION: runs the real market_install, prints its screen output and what it
# downloaded ("DOWNLOAD url"). Needs FAKE_API and FAKE_WEB in the environment.
run_market() {
  # shellcheck disable=SC2034  # the sourced libraries and market_install read these
  ( set -euo pipefail
    TAKWERX_APP=$REPO; TAKWERX_VERSION=$(cat "$REPO/VERSION")
    # shellcheck source=/dev/null
    . "$REPO/lib/common.sh"
    eval "$(awk '/^market_asset_url\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REPO/takwerx")"
    eval "$(awk '/^market_install\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REPO/takwerx")"
    ATAK=$1; atak_version() { echo "$ATAK"; }
    download() { echo "DOWNLOAD $1"; }
    config_set() { :; }
    ADB=$WORK/adb; ADB_ENDPOINT=fake; TAKWERX_CACHE=$WORK/cache; mkdir -p "$TAKWERX_CACHE"
    market_install ) 2>&1
}

APK58='releases/download/v1.8/ATAK-Plugin-TakwerxMarket-1.8--5.8.0-civ-release.apk'

t_limited_web_ok() {
  : > "$FAKE_LOG"
  local o; o=$(FAKE_API=limited FAKE_WEB=ok run_market 5.8.0.1)
  grep -qF "DOWNLOAD https://github.com/takwerx/takwerx-market/$APK58" <<<"$o" || { echo "did not download the 5.8.0 Market:"; echo "$o"; return 1; }
  grep -q 'Market 1.8 installed' <<<"$o" || { echo "did not install the Market:"; echo "$o"; return 1; }
  ! grep -q 'Could not reach' <<<"$o" || { echo "still says Could not reach GitHub:"; echo "$o"; return 1; }
}
check "API rate-limited (403), github.com pages work: the Market is installed" t_limited_web_ok

t_api_ok() {
  : > "$FAKE_LOG"
  local o; o=$(FAKE_API=ok FAKE_WEB=down run_market 5.7.0.3)
  grep -qF "DOWNLOAD https://github.com/takwerx/takwerx-market/releases/download/v1.8/ATAK-Plugin-TakwerxMarket-1.8--5.7.0-civ-release.apk" <<<"$o" || { echo "did not download the 5.7.0 Market:"; echo "$o"; return 1; }
  ! grep -q 'expanded_assets\|github.com/takwerx/takwerx-market/releases/latest' "$FAKE_LOG" || { echo "asked the web pages though the API answered:"; cat "$FAKE_LOG"; return 1; }
}
check "API answers: its answer is used, the web pages are not asked" t_api_ok

t_limited_both() {
  local o; o=$(FAKE_API=limited FAKE_WEB=down run_market 5.8.0.1)
  grep -q "GitHub is limiting requests from your address; run 'takwerx market' again in an hour" <<<"$o" || { echo "wrong message:"; echo "$o"; return 1; }
  ! grep -q 'Could not reach' <<<"$o" || { echo "says Could not reach GitHub for a rate limit:"; echo "$o"; return 1; }
}
check "API rate-limited and the pages fail: says GitHub is limiting requests" t_limited_both

t_down() {
  local o; o=$(FAKE_API=down FAKE_WEB=down run_market 5.8.0.1)
  grep -q "Could not reach GitHub; run 'takwerx market' when online" <<<"$o" || { echo "wrong message:"; echo "$o"; return 1; }
  ! grep -q 'limiting' <<<"$o" || { echo "blames a rate limit when nothing answered:"; echo "$o"; return 1; }
}
check "nothing answers: says Could not reach GitHub" t_down

t_nobuild() {
  local o; o=$(FAKE_API=limited FAKE_WEB=ok run_market 5.9.0.1)
  grep -q 'No Market build for ATAK 5.9.0 in the latest release' <<<"$o" || { echo "wrong message:"; echo "$o"; return 1; }
}
check "pages work but the release has no build for this ATAK: says No Market build" t_nobuild

[ "$FAILS" -eq 0 ] || { echo "$FAILS check(s) failed"; exit 1; }
echo "all market-lookup checks passed"
