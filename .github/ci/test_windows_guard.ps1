# Proof test for "never go backwards" on Windows (ops #1318). Loads lib/windows/guard.ps1 alone and runs
# its pure decisions: the same rules .github/ci/test_downgrade_guard.sh proves for the Mac and Linux
# engine. Nothing is run on a PC.
#   pwsh -File .github/ci/test_windows_guard.ps1
$ErrorActionPreference = 'Stop'
Set-Location (git rev-parse --show-toplevel)
. ./lib/windows/guard.ps1
$fail = 0
function Check([string]$name, $got, $want) {
    if ("$got" -ceq "$want") { Write-Host "ok   $name" } else { Write-Host "::error::FAIL $name : got '$got', want '$want'"; $script:fail++ }
}

# A release version is exactly X.Y.Z
Check 'semver 0.2.15'              (Test-Semver '0.2.15') 'True'
Check 'semver two parts'           (Test-Semver '0.2') 'False'
Check 'semver with a suffix'       (Test-Semver '0.2.16-beta') 'False'
Check 'semver a web page'          (Test-Semver '<html>Please log in</html>') 'False'
Check 'semver empty'               (Test-Semver '') 'False'
Check 'semver a path'              (Test-Semver '../../x') 'False'

# Comparing versions as numbers
Check '0.2.9 is older than 0.2.10' (Test-VersionOlder '0.2.9' '0.2.10') 'True'
Check '0.2.15 is not older than 0.2.15' (Test-VersionOlder '0.2.15' '0.2.15') 'False'
Check '0.3.0 is not older than 0.2.15'  (Test-VersionOlder '0.3.0' '0.2.15') 'False'
Check 'image r09 is older than r10'     (Test-VersionOlder '09' '10') 'True'
Check 'emulator 37.1.11 older than 37.2.0' (Test-VersionOlder '37.1.11' '37.2.0') 'True'

# takwerx itself: a lower version than installed, or than the highest that ran here, is refused
Check 'lower than installed: refused'      ((Get-DowngradeMessage '0.2.14' '0.2.15' '') -like '*older than the takwerx you have (0.2.15)*') 'True'
Check 'lower than the highest seen: refused' ((Get-DowngradeMessage '0.2.15' '0.2.10' '0.2.16') -like '*(0.2.16)*') 'True'
Check 'equal: fine'                        (Get-DowngradeMessage '0.2.15' '0.2.15' '0.2.15') ''
Check 'higher: fine'                       (Get-DowngradeMessage '0.2.16' '0.2.15' '0.2.15') ''
Check 'a -dev copy of the same version: fine' (Get-DowngradeMessage '0.2.16' '0.2.16-dev' '') ''
Check 'a made-up candidate is not a downgrade (the version check refuses it)' (Get-DowngradeMessage 'latest' '0.2.15' '') ''
Check 'nothing recorded: fine'             (Get-DowngradeMessage '0.1.0' '' '') ''

# tools: newer than the pin stays; older, missing or unreadable is installed
Check 'tool at the pin: nothing to do'     (Test-ToolNeeds '2.3.0' '2.3.0') 'False'
Check 'tool newer than the pin: kept'      (Test-ToolNeeds '2.4.0' '2.3.0') 'False'
Check 'image r10 over pin r09: kept'       (Test-ToolNeeds '10' '09') 'False'
Check 'tool older than the pin: installed' (Test-ToolNeeds '2.2.1' '2.3.0') 'True'
Check 'tool missing: installed'            (Test-ToolNeeds '' '2.3.0') 'True'
Check 'tool unreadable: installed'         (Test-ToolNeeds 'garbage text' '2.3.0') 'True'

# the Android device (35 is the pin)
Check 'device on 36, image here: left alone'     (Get-AvdMovePlan '36' '35' '' $true $true) 'leave'
Check 'device on 36, image not here: stop'       (Get-AvdMovePlan '36' '35' '' $true $false) 'stop-img'
Check 'device on 35 (other flavor), image here'  (Get-AvdMovePlan '35' '35' '' $true $true) 'leave'
Check 'image with no number: stop'               (Get-AvdMovePlan '' '35' '' $true $true) 'stop-id'
Check 'device on 34: moves'                      (Get-AvdMovePlan '34' '35' '' $true $false) 'move'
Check 'device on 34, no build number: stop'      (Get-AvdMovePlan '34' '35' '' $false $false) 'stop-bld'
Check 'device on 34 whose data ran on 36: stop'  (Get-AvdMovePlan '34' '35' '36' $true $false) 'stop-new'
Check 'device on 34, data last on 35: moves'     (Get-AvdMovePlan '34' '35' '35' $true $false) 'move'

# when the copy of the old device may go
Check 'not booted: keep'                         (Test-CopyMayGo $false $true $true) 'False'
Check 'booted, ATAK recorded but gone: keep'     (Test-CopyMayGo $true $true $false) 'False'
Check 'booted, ATAK recorded and here: remove'   (Test-CopyMayGo $true $true $true) 'True'
Check 'booted, ATAK never installed: remove'     (Test-CopyMayGo $true $false $false) 'True'

if ($fail -gt 0) { Write-Host "::error::$fail check(s) failed"; exit 1 }
Write-Host 'all Windows guard checks passed'
