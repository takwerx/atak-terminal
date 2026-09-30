# takwerx for Windows: real ATAK in a window on your PC. One line installs it (install.ps1),
# one icon runs it. The same commands as the Mac's takwerx; see README.md.
# Windows PowerShell 5.1 syntax, ASCII only.

$ErrorActionPreference = 'Stop'
$script:TakwerxScript = $PSCommandPath
$script:App = Split-Path -Parent $PSCommandPath
$script:TakwerxVersion = (Get-Content (Join-Path $App 'VERSION') -Raw).Trim()
$script:FromApp = ($args -contains '--from-app')
$argv = @($args | Where-Object { $_ -ne '--from-app' })

. (Join-Path $App 'lib\windows\common.ps1')
. (Join-Path $App 'lib\windows\host.ps1')
. (Join-Path $App 'lib\windows\android.ps1')
. (Join-Path $App 'lib\windows\emulator.ps1')

function Show-Usage {
    @"
takwerx $TakwerxVersion`: ATAK on your PC

  takwerx init [--apk FILE] [--no-up]   install everything, then open ATAK
  takwerx up                           start Android and open the ATAK window
  takwerx down                         stop Android, keep all data
  takwerx restart                      restart Android (keeps data)
  takwerx atak                         restart ATAK only (if it stops responding)
  takwerx status                       what is running, versions, position

  takwerx apk [FILE]          install or replace ATAK (defaults to the newest in Downloads)
  takwerx plugin FILE         install a plugin APK and switch it on
  takwerx market              install the TAKWERX Market plugin matching your ATAK
  takwerx app                 rebuild the Start Menu and desktop shortcuts and the icon
  takwerx datapackage FILE    import a data package zip
  takwerx display PRESET      screen (fit this PC's screen) | tablet | desktop | phone | ultra | WIDTHxHEIGHT@DPI
  takwerx fullscreen [on|off] Android on the whole screen, no title bar or taskbar; F11 switches
  takwerx gpu [NAME]          which GPU renders: a name such as Intel or NVIDIA, or auto
  takwerx location WHERE      LAT,LON [ACCURACY_M] | here (this PC's location) | ip (rough) | off

  takwerx shell               adb shell into Android
  takwerx screenshot [FILE]   save a PNG of the Android screen
  takwerx logs [--android|--emulator]   takwerx log; logcat; the emulator's own log
  takwerx reset               wipe Android (ATAK settings, certs, maps)
  takwerx update              update takwerx and its pinned tools
  takwerx uninstall           remove everything takwerx installed
"@ | Write-Host
}

function Assert-Installed { if (-not (Test-EmuInstalled)) { Die 'Not installed yet. Run: takwerx init' } }
function Invoke-AndroidUp { Assert-Installed; Invoke-EmuUp }

function Invoke-Init([string[]]$a) {
    $apk = ''; $open = $true
    for ($i = 0; $i -lt $a.Count; $i++) {
        switch ($a[$i]) {
            '--apk' { $apk = $a[$i + 1]; $i++ }
            '--no-up' { $open = $false }
            default { Die "Unknown option: $($a[$i])" }
        }
    }
    Step "takwerx $TakwerxVersion"
    Test-HostWindows
    Test-EmuHost
    Install-EmuSdk
    Set-TakwerxPath
    Build-App
    if (-not $open) {
        Ok 'Installed'
        # After `takwerx update`: an Android brought up by an older takwerx is restarted, so
        # everything running is the new version. A clean power-off; ATAK and its data return.
        if ((Test-EmuRunning) -and (((Get-RunningVersion) -ne $TakwerxVersion) -or -not (Test-AvdImageCurrent))) {
            Step "Restarting Android under takwerx $TakwerxVersion (about a minute; ATAK and its data come back)"
            Stop-Emu
            Invoke-Up
        }
        return
    }
    Invoke-EmuUp
    if (-not $apk -and -not (Test-AtakInstalled)) {
        $found = Find-AtakApk
        if ($found -and (Confirm-Yes "Found $(Split-Path $found -Leaf) in Downloads. Install it?")) { $apk = $found }
        if (-not $apk) {
            Say 'ATAK-CIV comes from https://tak.gov/products/atak-civ (login needed). A file picker opens now; cancel it if you have not downloaded it yet.'
            $apk = Select-AtakApk
        }
    }
    $first = $false
    if ($apk) { Install-Atak $apk; Install-Market; Build-App; $first = $true }
    Update-Position
    if (-not (Test-AtakInstalled)) {
        Write-Host ''
        Write-Host "No ATAK yet. Download ATAK-CIV from https://tak.gov/products/atak-civ, then open $AppName from the Start Menu: it asks for the file. Or: takwerx apk" -ForegroundColor White
    }
    Write-Host ''
    Write-Host 'Done. ' -ForegroundColor Green -NoNewline
    Write-Host "$AppName is in the Start Menu and on the desktop; new PowerShell windows have the takwerx command."
    Invoke-Up
    if ($first) { Start-Background '_market-after-first-run' }
}

function Invoke-Up {
    if ($FromApp) { Notify 'Starting ATAK'; Update-Check 'notify' } else { Update-Check 'print' }
    Invoke-AndroidUp
    Update-Position
    if (Test-AtakInstalled) {
        if (-not (Test-AtakRunning)) { Start-Atak; Start-Background '_focus-fix' }
    } else {
        $apk = if ($FromApp) { Request-AtakApk } else { Find-AtakApk }
        if ($apk) {
            Install-Atak $apk; Install-Market; Build-App; Start-Atak
            Start-Background '_focus-fix'
            Start-Background '_market-after-first-run'
        } else {
            Warn 'ATAK is not installed yet: takwerx apk (opens a file picker)'
            if ($FromApp) { Notify 'ATAK is not installed. Open the app again when the APK is downloaded.' }
        }
    }
    $p = Get-EmuProcess
    if ($p) { Show-EmulatorWindow ([int]$p.ProcessId) }
}

function Invoke-Status {
    Write-Host "takwerx $TakwerxVersion" -ForegroundColor White
    Update-Check 'print'
    $run = if (Test-EmuRunning) { 'running' } else { 'stopped' }
    $gpu = if ($EmuGpu) { $EmuGpu } else { 'auto' }
    Write-Host ("  Runtime:  emulator {0} on the GPU ({1}), {2}" -f (Get-ToolVersion $EmuDir), $gpu, $run)
    if (Test-AndroidOnline) {
        $g = Get-EmuGeometry
        $d = if (Test-EmuFullscreen) { 'full screen' } else { Get-Conf 'EMU_DISPLAY' 'screen' }
        Write-Host ("  Android:  {0}, display {1} ({2}x{3} at {4} dpi)" -f $Serial, $d, $g[0], $g[1], $g[2])
        if (Test-AtakInstalled) { $r = if (Test-AtakRunning) { ', running' } else { '' }; Write-Host "  ATAK:     $(Get-AtakVersion)$r" } else { Write-Host '  ATAK:     not installed' }
    }
    if (Get-Conf 'LOCATION') { Write-Host ("  Position: {0} (about {1} m, from {2})" -f (Get-Conf 'LOCATION'), (Get-Conf 'LOCATION_ACCURACY'), (Get-Conf 'LOCATION_SOURCE')) }
    Write-Host "  Logs:     $LogFile, $EmuLog"
}

function Invoke-LocationCmd([string[]]$a) {
    $arg = if ($a.Count -gt 0) { $a[0] } else { 'status' }
    switch -regex ($arg) {
        '^status$' {
            if (Get-Conf 'LOCATION') { Write-Host ("Position: {0} (about {1} m, from {2})" -f (Get-Conf 'LOCATION'), (Get-Conf 'LOCATION_ACCURACY'), (Get-Conf 'LOCATION_SOURCE')) }
            else { Write-Host "No position set. ATAK reports no location until you run one of:`n  takwerx location LAT,LON`n  takwerx location here`n  takwerx location ip" }
        }
        '^off$' { Remove-Conf 'LOCATION'; Remove-Conf 'LOCATION_ACCURACY'; Remove-Conf 'LOCATION_SOURCE'; Ok 'Position cleared; the next start leaves ATAK without a fix' }
        '^here$' {
            $p = Get-PcLocation
            if (-not $p) { Die 'Could not get this PC''s location. Turn on Settings > Privacy & security > Location, and "Let desktop apps access your location", then try again, or use: takwerx location LAT,LON' }
            Set-Position $p[0] $p[1] $p[2] 'this PC'
        }
        '^ip$' { $p = Get-IpLocation; if (-not $p) { Die 'Could not look up a position from the public IP' }; Set-Position $p[0] $p[1] $p[2] 'public IP' }
        default {
            $pos = ($arg -replace ' ', ',') -split ','
            $acc = if ($a.Count -gt 1) { $a[1] } else { '10' }
            if ($pos.Count -ne 2 -or $pos[0] -notmatch '^-?\d+(\.\d+)?$' -or $pos[1] -notmatch '^-?\d+(\.\d+)?$' -or $acc -notmatch '^\d+$') { Die 'Usage: takwerx location LAT,LON [ACCURACY_M] | here | ip | off' }
            Set-Position $pos[0] $pos[1] $acc 'you'
        }
    }
}

function Invoke-Update {
    Step 'Updating takwerx'
    $src = Get-TakwerxSource
    if (-not $src) { Die 'Could not read the current takwerx version from GitHub' }
    Step "Fetching takwerx ($($src[1]))"
    $zip = Join-Path $Cache 'app.zip'
    Remove-Item $zip -ErrorAction SilentlyContinue
    Get-Download $src[0] $zip
    $new = "$App.new"
    if (Test-Path $new) { Remove-Item -Recurse -Force $new }
    Expand-Zip $zip $new 1
    if (-not (Test-Path (Join-Path $new 'takwerx.ps1'))) { Die 'That takwerx has no Windows engine yet' }
    $old = "$App.old"
    if (Test-Path $old) { Remove-Item -Recurse -Force $old }
    Rename-Item $App (Split-Path $old -Leaf)
    Rename-Item $new (Split-Path $App -Leaf)
    Remove-Item -Recurse -Force $old -ErrorAction SilentlyContinue
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'takwerx.ps1') init --no-up
    # The new takwerx's init has restarted a running Android if it was the old one's.
    $newVersion = (Get-Content (Join-Path $App 'VERSION') -Raw).Trim()
    if ($newVersion -eq $TakwerxVersion) { Ok "takwerx $newVersion is current" } else { Ok "takwerx $TakwerxVersion -> $newVersion" }
}

function Invoke-Main([string[]]$a) {
    $cmd = if ($a.Count -gt 0) { $a[0] } else { 'help' }
    $rest = @(); if ($a.Count -gt 1) { $rest = $a[1..($a.Count - 1)] }
    Log ("takwerx {0} {1}" -f $cmd, ($rest -join ' '))
    switch ($cmd) {
        'init'    { Invoke-Init $rest }
        'up'      { Invoke-Up }
        'down'    { Stop-Emu; Ok 'Stopped. Data is kept; takwerx up brings it back' }
        'restart' { Stop-Emu; Invoke-Up }
        'atak'    {
            Assert-Installed
            if (-not (Test-AndroidOnline)) { Die 'Android is not running (takwerx up)' }
            if (-not (Test-AtakInstalled)) { Die 'ATAK is not installed (takwerx apk)' }
            Step 'Restarting ATAK'; Stop-Atak; Start-Sleep -Seconds 2; Start-Atak; Start-Background '_focus-fix'; Ok 'ATAK is starting'
        }
        'status'  { Invoke-Status }
        'apk'     {
            $apk = if ($rest.Count -gt 0) { $rest[0] } else { Find-AtakApk }
            if (-not $apk) { $apk = Select-AtakApk }
            if (-not $apk) { Die 'No ATAK APK given, none in Downloads, and nothing picked' }
            Invoke-AndroidUp; Install-Atak $apk; Install-Market; Build-App
            Say "Run 'takwerx up' to open it."
        }
        'plugin'  { if ($rest.Count -lt 1) { Die 'Usage: takwerx plugin FILE.apk' }; Invoke-AndroidUp; Install-Plugin $rest[0]; Enable-Plugins }
        'market'  { Invoke-AndroidUp; Install-Market }
        'app'     { Build-App }
        'datapackage' { if ($rest.Count -lt 1) { Die 'Usage: takwerx datapackage FILE.zip' }; Invoke-AndroidUp; Install-DataPackage $rest[0] }
        'display' {
            if ($rest.Count -lt 1) { Die 'Usage: takwerx display screen|tablet|desktop|phone|ultra|WxH@DPI' }
            if ($rest[0] -notmatch '^(screen|tablet|desktop|phone|ultra|\d+x\d+@\d+)$') { Die "Unknown preset '$($rest[0])'" }
            Set-Conf 'EMU_DISPLAY' $rest[0]; Remove-Conf 'EMU_FULLSCREEN'
            $g = Get-EmuGeometry
            Ok ("Display {0} ({1}x{2} at {3} dpi); the emulator takes a new screen size at start: takwerx restart" -f $rest[0], $g[0], $g[1], $g[2])
        }
        'fullscreen' {
            $want = if ($rest.Count -gt 0) { $rest[0] } else { '' }
            if ($want -notin 'on', 'off') {
                $cur = if (Test-EmuFullscreen) { 'on' } else { 'off' }
                Write-Host "Full screen: $cur (takwerx fullscreen on|off)"; return
            }
            if ($want -eq 'on') { Set-Conf 'EMU_FULLSCREEN' 'on' } else { Remove-Conf 'EMU_FULLSCREEN' }
            $g = Get-EmuGeometry
            $how = if ($want -eq 'on') { 'on. F11 switches to a normal window and back' } else { 'off' }
            Ok ("Full screen {0} (Android {1}x{2})" -f $how, $g[0], $g[1])
            # Android's screen size is fixed at start: a running one restarts onto the new size.
            if (Test-EmuRunning) { Step 'Restarting Android at the new size (about a minute; ATAK and its data come back)'; Stop-Emu; Invoke-Up }
        }
        'gpu'     {
            if ($rest.Count -lt 1) { $cur = if ($EmuGpu) { $EmuGpu } else { 'auto' }; Write-Host "GPU: $cur"; return }
            if ($rest[0] -eq 'auto') { Remove-Conf 'EMU_GPU' } else { Set-Conf 'EMU_GPU' $rest[0] }
            Ok "GPU: $($rest[0]). takwerx restart applies it"
        }
        'location' { Assert-Installed; Invoke-LocationCmd $rest }
        'shell'   { Assert-Installed; & $Adb -s $Serial shell @rest }
        'screenshot' {
            $out = if ($rest.Count -gt 0) { $rest[0] } else { Join-Path ([Environment]::GetFolderPath('Desktop')) ("atak-{0}.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
            if (-not (Test-AndroidOnline)) { Die 'Android is not running' }
            [void](AdbSh 'screencap' '-p' '/sdcard/takwerx-shot.png'); [void](Adb 'pull' '/sdcard/takwerx-shot.png' $out)
            Ok $out
        }
        'logs'    {
            if ($rest -contains '--android') { if (-not (Test-AndroidOnline)) { Die 'Android is not running' }; Adb 'logcat' '-d' '-t' '500' }
            elseif ($rest -contains '--emulator' -or $rest -contains '--container') { Get-Content $EmuLog -Tail 300 }
            else { Get-Content $LogFile -Tail 100 }
        }
        'reset'   {
            Assert-Installed
            if (-not (Confirm-Yes 'This wipes Android: ATAK settings, server connections, certificates, maps and plugins. Continue?')) { Say 'Cancelled.'; return }
            Stop-Emu
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $AvdHome "$Avd.avd"), (Join-Path $AvdHome "$Avd.ini")
            Remove-Conf 'ATAK_APK'; Remove-Conf 'MARKET_APK'
            Ok "Android wiped. 'takwerx up' starts clean and asks for ATAK"
        }
        'update'  { Invoke-Update }
        'uninstall' {
            if (-not (Confirm-Yes "Remove Android and everything under $Root, plus the shortcuts?")) { Say 'Cancelled.'; return }
            Stop-Emu
            [void](Invoke-Quiet $Adb 'kill-server')
            Remove-App
            Set-Location $env:USERPROFILE
            Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue
            Ok 'Removed.'
        }
        'version' { Write-Host $TakwerxVersion }
        # Background jobs, started hidden by takwerx itself.
        '_watch'  { Invoke-Watch ([int]$rest[0]) }
        '_focus-fix' { Repair-AtakFocus }
        '_market-after-first-run' { Wait-MarketRegistration }
        { $_ -in 'help', '-h', '--help' } { Show-Usage }
        default   { Show-Usage; Die "Unknown command: $cmd" }
    }
}

try {
    Invoke-Main $argv
} catch [System.OperationCanceledException] {
    exit 1
} catch {
    Log ("error: " + $_.Exception.Message + ' ' + $_.InvocationInfo.PositionMessage)
    Write-Host 'Error: ' -ForegroundColor Red -NoNewline
    Write-Host $_.Exception.Message
    Show-Alert $_.Exception.Message
    exit 1
}
