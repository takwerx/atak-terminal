# takwerx for Windows: never go backwards (ops #1318). The pure decisions, with no files and no
# network, so .github/ci/test_windows_guard.ps1 can run them alone, as test_windows_gpu.ps1 does
# gpu.ps1. The bash engine (lib/common.sh: semver_ok, ver_lt, tool_needs, takwerx_downgrade_refused)
# is the reference; a rule changed there is changed here.
# Windows PowerShell 5.1 syntax only, and ASCII only.

# A release version is exactly X.Y.Z. Anything else GitHub answers with (a captive-portal page, an
# error page) is not a version.
function Test-Semver([string]$v) { return [bool]($v -match '^\d+\.\d+\.\d+$') }

# Compare-VersionText A B: -1 when A is older than B, 0 when equal, 1 when newer. Splits on . - _ and
# compares number against number; "09" and "10" compare as numbers, "37.1.11" against "37.2.0" part by part.
function Compare-VersionText([string]$a, [string]$b) {
    $pa = @($a -split '[._-]')
    $pb = @($b -split '[._-]')
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = '0'; if ($i -lt $pa.Count) { $x = $pa[$i] }
        $y = '0'; if ($i -lt $pb.Count) { $y = $pb[$i] }
        if (($x -match '^\d+$') -and ($y -match '^\d+$')) {
            $dx = [decimal]$x; $dy = [decimal]$y
            if ($dx -lt $dy) { return -1 }
            if ($dx -gt $dy) { return 1 }
        } else {
            $c = [string]::CompareOrdinal($x, $y)
            if ($c -lt 0) { return -1 }
            if ($c -gt 0) { return 1 }
        }
    }
    return 0
}
function Test-VersionOlder([string]$a, [string]$b) { return ((Compare-VersionText $a $b) -lt 0) }

# Test-ToolNeeds HAVE PIN: $true when the tool must be (re)installed to PIN: nothing there, something
# unreadable, or an older version. A tool NEWER than the pin stays: a newer emulator or adb was put there
# by a newer takwerx, and this one has no business replacing it with an older build.
function Test-ToolNeeds([string]$have, [string]$pin) {
    if ($have -eq $pin) { return $false }
    if ($have -notmatch '^\d[0-9A-Za-z._-]*$') { return $true }
    if (Test-VersionOlder $pin $have) { return $false }
    return $true
}

# Get-DowngradeMessage CANDIDATE INSTALLED SEEN: the refusal text when CANDIDATE is older than the takwerx
# installed or the highest one that has run here, else ''. A -dev suffix on a version is ignored.
function Get-DowngradeMessage([string]$cand, [string]$installed, [string]$seen) {
    if (-not (Test-Semver $cand)) { return '' }
    foreach ($have in @($installed, $seen)) {
        $h = ("$have" -split '-')[0]
        if (-not (Test-Semver $h)) { continue }
        if (Test-VersionOlder $cand $h) {
            return "takwerx $cand is older than the takwerx you have ($h), so it was not installed. Nothing changed. To go back on purpose, set TAKWERX_ALLOW_DOWNGRADE=1 and run takwerx update again"
        }
    }
    return ''
}

# Get-AvdMovePlan DEVICEAPI PINAPI SEENAPI HASBUILD IMAGEHERE: what to do with an existing device.
#   leave    the device is on the pinned Android or a newer one and its image is installed: untouched
#   stop-img the device is on a newer Android whose image is not installed: stop, nothing changed
#   stop-new the device's data has run on an Android newer than the pin: not moved down, stop
#   stop-id  the image is not one takwerx can read the number of: stop
#   stop-bld the pinned image has no build number: stop, nothing changed
#   move     the device is on an older Android: move it (with a whole copy of its data first)
function Get-AvdMovePlan([string]$deviceApi, [string]$pinApi, [string]$seenApi, [bool]$hasBuild, [bool]$imageHere) {
    if ($deviceApi -notmatch '^\d+$') { return 'stop-id' }
    if ([int]$deviceApi -ge [int]$pinApi) {
        if ($imageHere) { return 'leave' }
        return 'stop-img'
    }
    if (($seenApi -match '^\d+$') -and ([int]$seenApi -gt [int]$pinApi)) { return 'stop-new' }
    if (-not $hasBuild) { return 'stop-bld' }
    return 'move'
}

# Test-CopyMayGo BOOTED ATAKRECORDED ATAKHERE: the copy of the old device goes only when Android booted AND
# the device still has what the old one had. An empty device boots too, so booting alone proves nothing:
# where takwerx installed ATAK, ATAK must be there.
function Test-CopyMayGo([bool]$booted, [bool]$atakRecorded, [bool]$atakHere) {
    if (-not $booted) { return $false }
    if ($atakRecorded -and -not $atakHere) { return $false }
    return $true
}
