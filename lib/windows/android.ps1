# takwerx for Windows: Android over adb, and ATAK in it. Mirrors lib/android.sh and the
# ATAK parts of the takwerx CLI.

$script:Adb = Join-Path $Tools 'android-sdk\platform-tools\adb.exe'

function Adb { Invoke-Quiet $script:Adb '-s' $script:Serial @args }
function AdbSh { Invoke-Quiet $script:Adb '-s' $script:Serial 'shell' @args }
function Start-AdbServer { [void](Invoke-Quiet $script:Adb 'start-server') }

function Test-AndroidOnline { return ((Invoke-Quiet $script:Adb '-s' $script:Serial 'get-state') -eq 'device') }
function Test-AndroidBooted { return ((AdbSh 'getprop' 'sys.boot_completed') -eq '1') }

# Runs a shell script inside Android. Pushed as a file, so no quoting survives the trip
# through PowerShell 5.1 and adb (it drops embedded double quotes).
function Invoke-AndroidScript([string]$name, [string]$body, [string[]]$argv = @()) {
    $local = Join-Path $State $name
    [System.IO.File]::WriteAllText($local, ($body -replace "`r`n", "`n"))
    [void](Adb 'push' $local "/data/local/tmp/$name")
    $cmd = @('sh', "/data/local/tmp/$name") + $argv
    return (AdbSh @cmd)
}

function Enable-AdbRoot {
    $r = Adb 'root'
    Start-Sleep -Seconds 2
    [void](Adb 'wait-for-device')
    return ($r -match 'restarting|already running as root')
}

# ---- ATAK ---------------------------------------------------------------------------------------
function Test-AtakInstalled { return ((AdbSh 'pm' 'path' $AtakPackage) -match '^package:') }
function Get-AtakVersion {
    $o = AdbSh 'dumpsys' 'package' $AtakPackage
    if ($o -match 'versionName=(.+)') { return $Matches[1].Trim() }
    return ''
}
function Test-AtakRunning { return [bool](AdbSh 'pidof' $AtakPackage) }
function Get-AtakActivity {
    $o = AdbSh 'cmd' 'package' 'resolve-activity' '--brief' '-c' 'android.intent.category.LAUNCHER' $AtakPackage
    return (($o -split "`n") | Select-Object -Last 1).Trim()
}
function Start-Atak {
    $act = Get-AtakActivity
    if ($act) { [void](AdbSh 'am' 'start' '-n' $act) }
}
# ATAK takes no quit from outside: QUITAPP lives on its in-process bus. Home first, so its
# onPause and onStop save, then force-stop (DECISIONS 2026-09-27, as atak_quit on the Mac).
function Stop-Atak {
    if (-not (Test-AtakRunning)) { return }
    [void](AdbSh 'input' 'keyevent' 'KEYCODE_HOME')
    Start-Sleep -Seconds 2
    [void](AdbSh 'am' 'force-stop' $AtakPackage)
    for ($i = 0; $i -lt 5; $i++) { if (-not (Test-AtakRunning)) { return }; Start-Sleep -Seconds 1 }
    Warn 'ATAK is still running after being stopped'
}

# Everything ATAK would ask for on first run, including all-files access and installing
# APKs, which is what lets the Market update plugins from inside ATAK.
function Grant-Atak {
    $body = @'
P=$1
for op in MANAGE_EXTERNAL_STORAGE REQUEST_INSTALL_PACKAGES SYSTEM_ALERT_WINDOW; do appops set $P $op allow >/dev/null 2>&1; done
for perm in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION POST_NOTIFICATIONS \
  READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE CAMERA RECORD_AUDIO READ_PHONE_STATE \
  BLUETOOTH_CONNECT BLUETOOTH_SCAN NEARBY_WIFI_DEVICES; do pm grant $P android.permission.$perm >/dev/null 2>&1; done
echo granted
'@
    [void](Invoke-AndroidScript 'takwerx-grant.sh' $body @($AtakPackage))
}

function Install-Atak([string]$apk) {
    if (-not (Test-Path $apk)) { Die "APK not found: $apk" }
    Step ("Installing {0} (a minute or two over adb)" -f (Split-Path $apk -Leaf))
    $r = Adb 'install' '-r' '-g' $apk
    if ($r -notmatch 'Success') { Die "adb install failed for $apk`: $r" }
    Grant-Atak
    Set-Conf 'ATAK_APK' $apk
    Ok ("ATAK {0} installed" -f (Get-AtakVersion))
    Set-AtakInDock
}

function Install-Plugin([string]$apk) {
    if (-not (Test-Path $apk)) { Die "APK not found: $apk" }
    Step ("Installing plugin " + (Split-Path $apk -Leaf))
    $r = Adb 'install' '-r' '-g' $apk
    if ($r -notmatch 'Success') { Die "adb install failed for $apk`: $r" }
    Ok 'Installed'
}

# ATAK sets shouldLoad-<package>=false on every plugin (re)install and asks in its Plugins
# screen; a plugin never asked about has no entry at all. With root: ATAK stopped, every
# entry true and the missing ones added, ATAK started again (emu_plugins_enable).
function Enable-Plugins {
    if (-not (Enable-AdbRoot)) { return }
    Stop-Atak
    $body = @'
PKG=$1
P=/data/data/$PKG/shared_prefs/${PKG}_preferences.xml
[ -f "$P" ] || { echo "no preferences yet"; exit 0; }
sed -i 's|"shouldLoad-\([^"]*\)" value="false"|"shouldLoad-\1" value="true"|g' "$P"
for pkg in $(pm list packages | sed -n 's/^package:\(com\.atakmap\.android\..*\.plugin\)$/\1/p'); do
  grep -q "shouldLoad-$pkg\"" "$P" || sed -i "s|</map>|    <boolean name=\"shouldLoad-$pkg\" value=\"true\" />\n</map>|" "$P"
done
echo "plugins on: $(grep -c 'shouldLoad-[^"]*" value="true"' "$P")"
'@
    $r = Invoke-AndroidScript 'takwerx-plugins.sh' $body @($AtakPackage)
    Start-Atak
    Start-Background '_focus-fix'
    Ok "Plugins switched on ($r); ATAK is restarting"
}

function Install-DataPackage([string]$zip) {
    if (-not (Test-Path $zip)) { Die "Not found: $zip" }
    $name = Split-Path $zip -Leaf
    Step "Importing data package $name"
    [void](Adb 'push' $zip "/sdcard/Download/$name")
    [void](AdbSh 'am' 'start' '-a' 'android.intent.action.VIEW' '-d' "file:///sdcard/Download/$name" '-t' 'application/zip' '-p' $AtakPackage)
    Ok "Pushed to Download/$name; if ATAK did not import it, use Import Manager > Local SD"
}

# ---- the TAKWERX Market -------------------------------------------------------------------------
# The latest Market release carries one APK per ATAK version; the one for the installed ATAK.
function Install-Market {
    $ver = ''
    if ((Get-AtakVersion) -match '^(\d+\.\d+\.\d+)') { $ver = $Matches[1] }
    if (-not $ver) { Warn 'ATAK is not installed; the Market is installed after ATAK'; return }
    Step "TAKWERX Market plugin for ATAK $ver"
    try { $rel = Invoke-RestMethod -UseBasicParsing -TimeoutSec 20 'https://api.github.com/repos/takwerx/takwerx-market/releases/latest' }
    catch { Warn "Could not reach GitHub; run 'takwerx market' when online"; return }
    $asset = $rel.assets | Where-Object { $_.name -match ('--' + [regex]::Escape($ver) + '-civ-release\.apk$') } | Select-Object -First 1
    if (-not $asset) { Warn "No Market build for ATAK $ver in the latest release"; return }
    $apk = Join-Path $Cache $asset.name
    Get-Download $asset.browser_download_url $apk
    $r = Adb 'install' '-r' '-g' $apk
    if ($r -notmatch 'Success') { Warn "Market install failed: $r"; return }
    Set-Conf 'MARKET_APK' $apk
    Ok ("Market {0} installed" -f ($asset.name -replace '^.*Market-([0-9.]+)--.*$', '$1'))
}

# A plugin installed before ATAK's first run gets no "should load" entry and is skipped; one
# installed again while ATAK runs is registered and ATAK offers to load it. So after a first
# install this waits, in the background, for ATAK to get past its first run, then installs the
# Market again over itself (market_register_after_first_run).
function Wait-MarketRegistration {
    $apk = Get-Conf 'MARKET_APK'
    if (-not $apk -or -not (Test-Path $apk)) { return }
    if (-not (Enable-AdbRoot)) { return }
    $prefs = "/data/data/$AtakPackage/shared_prefs/${AtakPackage}_preferences.xml"
    for ($i = 0; $i -lt 400; $i++) {
        Start-Sleep -Seconds 3
        if (-not (Test-AtakRunning)) { continue }
        # Past the EULA: ATAK writes AgreedToEULA=true when it is accepted (EulaHelper).
        # A reinstall on the EULA screen registered the plugin and ATAK never asked.
        if ((AdbSh 'grep' '-c' 'AgreedToEULA.*true' $prefs) -notmatch '^[1-9]') { continue }
        if ((AdbSh 'dumpsys' 'window' 'windows') -match 'ATAK Loading') { continue }
        Start-Sleep -Seconds 10
        if ((Adb 'install' '-r' '-g' $apk) -match 'Success') { Log "Market installed again after ATAK's first run, so ATAK registers it" }
        return
    }
}

# ATAK starts behind an "ATAK Loading" window, and under the emulator the hand-over loses the
# focus report, so no text field on the main screen takes typing until ATAK is sent home and
# back once (emu_focus_fix, DECISIONS 2026-09-26).
function Repair-AtakFocus {
    # Android 15 no longer needs it (emu_focus_fix on the Mac, 2026-09-29): ATAK's window has
    # focus on a fresh start, and the bounce showed as ATAK opening, closing and opening
    # again. EMU_FOCUS_FIX=on in the config brings it back.
    if ((Get-Conf 'EMU_FOCUS_FIX' 'off') -ne 'on') { return }
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        $focus = AdbSh 'dumpsys' 'window'
        $windows = AdbSh 'dumpsys' 'window' 'windows'
        if ($focus -match 'mCurrentFocus=.*ATAKActivity' -and $windows -notmatch 'ATAK Loading') {
            Start-Sleep -Seconds 3
            [void](AdbSh 'input' 'keyevent' 'KEYCODE_HOME')
            Start-Sleep -Seconds 1
            Start-Atak
            Log "emulator: re-ran ATAK's window focus after start"
            return
        }
    }
}

# Why ATAK last stopped responding: Android's reasons from the event log, and from the newest
# trace in /data/anr the main and GL threads of the process it names, the file saved whole
# to the logs folder. The hang collector of 2026-09-27 (a served collect.ps1), built in.
function Show-AtakAnr {
    if (-not (Test-AndroidOnline)) { Die 'Android is not running (takwerx up)' }
    [void](Enable-AdbRoot)
    $pat = 'am_anr.*' + [regex]::Escape($AtakPackage)
    $events = @((AdbSh 'logcat' '-b' 'events' '-d') -split "`n" | Where-Object { $_ -match $pat } | Select-Object -Last 5)
    if ($events.Count -eq 0) { Say "No ATAK 'not responding' in Android's event log since Android started" }
    else { Write-Host "Android's reasons, newest last:" -ForegroundColor White; foreach ($e in $events) { Write-Host "  $($e.Trim())" } }
    $file = @((AdbSh 'ls' '-t' '/data/anr') -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^anr_' }) | Select-Object -First 1
    if (-not $file) { Say 'No trace file in /data/anr'; return }
    $text = AdbSh 'cat' "/data/anr/$file"
    $out = Join-Path $Logs "$file.txt"
    [System.IO.File]::WriteAllText($out, $text)
    Write-Host ''
    Write-Host "Trace $file (saved whole to $out):" -ForegroundColor White
    # The process that did not respond comes first in the file; its section ends where the
    # next process begins.
    $lines = $text -split "`n"
    $pids = 0; $shown = 0
    for ($i = 0; $i -lt $lines.Count -and $shown -lt 4; $i++) {
        if ($lines[$i] -match '^----- pid ') { $pids++; if ($pids -gt 1) { break } }
        if ($lines[$i] -match '^Cmd line:') { Write-Host "  $($lines[$i].Trim())" }
        if ($lines[$i] -match '^"(main|GLThread[^"]*)"') {
            Write-Host ''
            for ($j = $i; $j -lt [Math]::Min($i + 30, $lines.Count) -and $lines[$j].Trim(); $j++) { Write-Host "  $($lines[$j].TrimEnd())" }
            $shown++
        }
    }
}

# ATAK in Android's dock next to Chrome (emu_dock_atak): a row in the launcher's database.
function Set-AtakInDock {
    if (-not (Enable-AdbRoot)) { return }
    $act = Get-AtakActivity
    if (-not $act) { return }
    $body = @'
PKG=$1; ACT=$2
DB=$(ls /data/data/com.google.android.apps.nexuslauncher/databases/launcher*.db 2>/dev/null | head -n1)
[ -n "$DB" ] || exit 0
N=$(sqlite3 $DB "select count(*) from favorites where container=-101 and intent like '%$PKG%'")
[ "$N" = 0 ] || exit 0
NOW=$(date +%s)000
sqlite3 $DB "insert into favorites (title,intent,container,screen,cellX,cellY,spanX,spanY,itemType,appWidgetId,modified,restored,profileId,rank,options) values ('ATAK','#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;launchFlags=0x10200000;component=$ACT;end',-101,0,0,0,1,1,0,-1,$NOW,0,0,0,0)" && am force-stop com.google.android.apps.nexuslauncher && echo pinned
'@
    if ((Invoke-AndroidScript 'takwerx-dock.sh' $body @($AtakPackage, $act)) -match 'pinned') { Log "ATAK pinned in Android's dock" }
}

# ---- the splash ------------------------------------------------------------------------------------
# ATAK shows atak/support/atak_splash.png in place of its own splash, its own supported
# customisation. It stretches the image to cover the screen and crops the rest, so the art is
# fitted whole onto a canvas of the screen's shape, black around it (atak_splash_apply).
function Set-AtakSplash([int]$w, [int]$h) {
    $src = Join-Path $App 'assets\atak_splash.png'
    if (-not (Test-Path $src) -or $w -le 0 -or $h -le 0) { return }
    $out = Join-Path $State "atak_splash-${w}x${h}.png"
    if (-not (Test-Path $out) -or (Get-Item $src).LastWriteTime -gt (Get-Item $out).LastWriteTime) {
        try {
            Add-Type -AssemblyName System.Drawing
            $img = [System.Drawing.Image]::FromFile($src)
            try {
                $scale = [Math]::Min($w / $img.Width, $h / $img.Height)
                $dw = [int]($img.Width * $scale); $dh = [int]($img.Height * $scale)
                $bmp = New-Object System.Drawing.Bitmap $w, $h
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.Clear([System.Drawing.Color]::Black)
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.DrawImage($img, [int](($w - $dw) / 2), [int](($h - $dh) / 2), $dw, $dh)
                $g.Dispose()
                $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
            } finally { $img.Dispose() }
        } catch { Warn "Could not fit the splash to the screen ($($_.Exception.Message))"; return }
    }
    # SHA-256, not MD5: a Windows in FIPS mode (a managed laptop) refuses MD5 outright.
    $want = (Get-FileHash -Algorithm SHA256 $out).Hash.ToLowerInvariant()
    $have = ((AdbSh 'sha256sum' '/sdcard/atak/support/atak_splash.png') -split '\s+')[0]
    if ($want -eq $have) { return }
    [void](AdbSh 'mkdir' '-p' '/sdcard/atak/support')
    [void](Adb 'push' $out '/sdcard/atak/support/atak_splash.png')
}

# ---- position ----------------------------------------------------------------------------------------
# The emulator's own GPS, which ATAK takes as a real provider. Not kept across boots.
function Send-Position {
    $pos = Get-Conf 'LOCATION'
    if (-not $pos) { return }
    $p = $pos -split ','
    [void](Adb 'emu' 'geo' 'fix' $p[1] $p[0])
}
function Set-Position([string]$lat, [string]$lon, [string]$acc, [string]$source) {
    Set-Conf 'LOCATION' "$lat,$lon"; Set-Conf 'LOCATION_ACCURACY' $acc; Set-Conf 'LOCATION_SOURCE' $source
    if (Test-AndroidOnline) { Send-Position }
    Ok "Position $lat, $lon (about $acc m, from $source). ATAK shows it as a GPS fix within a few seconds"
}
# Windows' own location service (Settings > Privacy > Location, desktop apps allowed).
function Get-PcLocation {
    try {
        Add-Type -AssemblyName System.Device
        $w = New-Object System.Device.Location.GeoCoordinateWatcher ([System.Device.Location.GeoPositionAccuracy]::High)
        $w.Start()
        # Up to 10 s for a fix; out at once when location is denied, and after 2 s when
        # Windows reports it switched off, so a PC without it does not stall every start.
        for ($i = 0; $i -lt 50 -and ($w.Status -ne 'Ready' -or $w.Position.Location.IsUnknown); $i++) {
            if ($w.Permission -eq 'Denied') { break }
            if ($i -ge 10 -and $w.Status -in 'Disabled', 'NoData') { break }
            Start-Sleep -Milliseconds 200
        }
        $loc = $w.Position.Location
        $w.Stop()
        if ($loc.IsUnknown) { return $null }
        $acc = [int][Math]::Max(1, $loc.HorizontalAccuracy)
        return @($loc.Latitude.ToString([Globalization.CultureInfo]::InvariantCulture), $loc.Longitude.ToString([Globalization.CultureInfo]::InvariantCulture), "$acc")
    } catch { return $null }
}
# Rough position from the public IP, a few kilometres at best, reported honestly.
function Get-IpLocation {
    try {
        $j = Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 'https://ipinfo.io/json'
        $p = $j.loc -split ','
        return @($p[0], $p[1], '5000')
    } catch { return $null }
}
# At every start, as on the Mac: this PC's own position, unless one was typed in by hand.
function Update-Position {
    if ((Get-Conf 'LOCATION_SOURCE') -eq 'you') { return }
    $p = Get-PcLocation
    if ($p) { Set-Position $p[0] $p[1] $p[2] 'this PC' }
    elseif (Get-Conf 'LOCATION') { Send-Position }
}
