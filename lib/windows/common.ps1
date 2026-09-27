# takwerx for Windows: shared paths, config, logging, prompts and downloads. Dot-sourced by
# takwerx.ps1. The bash engine (lib/common.sh) is the reference; names and behaviour follow
# it, so a rule changed on one side is changed on both (docs/PLAN-windows.md).
# Windows PowerShell 5.1 syntax only (no &&, ?:, ??), and ASCII only: 5.1 reads a script
# without a BOM as the ANSI code page.

$script:Root   = if ($env:TAKWERX_ROOT) { $env:TAKWERX_ROOT } else { Join-Path $env:LOCALAPPDATA 'takwerx' }
$script:Bin    = Join-Path $Root 'bin'
$script:Tools  = Join-Path $Root 'tools'
$script:Cache  = Join-Path $Root 'cache'
$script:Logs   = Join-Path $Root 'logs'
$script:State  = Join-Path $Root 'state'
$script:Config = Join-Path $Root 'config'
$script:LogFile = Join-Path $Logs 'takwerx.log'
foreach ($d in $Bin, $Tools, $Cache, $Logs, $State) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$script:AppName = 'TAKwerx ATAK Terminal'
$script:AppId   = 'TAKwerx.ATAKTerminal'
$script:AtakPackage = 'com.atakmap.app.civ'   # ATAK-CIV
# takwerx's own adb server, on its own port, so Android Studio or any other adb on this PC
# can never stop the server the ATAK window depends on.
$env:ANDROID_ADB_SERVER_PORT = '5038'

# versions.env, the one list of pinned versions both engines read.
$script:V = @{}
foreach ($line in Get-Content (Join-Path $App 'versions.env')) {
    if ($line -match '^\s*([A-Z0-9_]+)=(.*)$') { $V[$Matches[1]] = $Matches[2].Trim() }
}

# ---- logging -------------------------------------------------------------------------------
function Log([string]$m) { try { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) } catch {} }
function Say([string]$m)  { Write-Host $m; Log $m }
function Step([string]$m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor White; Log "==> $m" }
function Ok([string]$m)   { Write-Host '  ok  ' -ForegroundColor Green -NoNewline; Write-Host $m; Log "ok: $m" }
function Warn([string]$m) { Write-Host '  !!  ' -ForegroundColor Yellow -NoNewline; Write-Host $m; Log "warn: $m" }
function Die([string]$m) {
    Write-Host 'Error: ' -ForegroundColor Red -NoNewline; Write-Host $m
    Log "error: $m"
    Show-Alert $m
    throw [System.OperationCanceledException]::new('takwerx: ' + $m)
}

# ---- prompts, dialogs, notifications ---------------------------------------------------------
function Test-Interactive { return (-not $script:FromApp) -and [Environment]::UserInteractive -and ($Host.Name -eq 'ConsoleHost') }
function Confirm-Yes([string]$prompt) {
    if (-not (Test-Interactive)) { return $false }
    $a = Read-Host "$prompt [y/N]"
    return ($a -match '^[Yy]')
}

function Show-Alert([string]$m) {
    if (-not $script:FromApp) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($m, $AppName, 'OK', 'Error') | Out-Null
    } catch {}
}

# A Windows notification under the app's own name and icon (the Start Menu shortcut carries
# the AppUserModelID it is filed under). Silent if Windows will not show it.
function Notify([string]$m) {
    Log "notify: $m"
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $t = $xml.GetElementsByTagName('text')
        [void]$t.Item(0).AppendChild($xml.CreateTextNode($AppName))
        [void]$t.Item(1).AppendChild($xml.CreateTextNode($m))
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
    } catch {}
}

# ---- config (the same key=value file as the Mac's ~/.takwerx/config) ------------------------
function Get-Conf([string]$key, [string]$default = '') {
    if (Test-Path $Config) {
        $v = $null
        foreach ($l in Get-Content $Config) { if ($l -match ('^' + [regex]::Escape($key) + '=(.*)$')) { $v = $Matches[1] } }
        if ($v) { return $v }
    }
    return $default
}
function Set-Conf([string]$key, [string]$value) {
    $lines = @()
    if (Test-Path $Config) { $lines = @(Get-Content $Config | Where-Object { $_ -notmatch ('^' + [regex]::Escape($key) + '=') }) }
    $lines += "$key=$value"
    Set-Content -Path $Config -Value $lines -Encoding UTF8
}
function Remove-Conf([string]$key) {
    if (-not (Test-Path $Config)) { return }
    $lines = @(Get-Content $Config | Where-Object { $_ -notmatch ('^' + [regex]::Escape($key) + '=') })
    Set-Content -Path $Config -Value $lines -Encoding UTF8
}

# ---- native commands ------------------------------------------------------------------------
# Runs a program and returns its standard output as one string, never throwing: Windows
# PowerShell 5.1 turns a native program's stderr into errors under 'Stop'.
function Invoke-Quiet {
    $exe = $args[0]
    $rest = @()
    if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }
    # A program that is not there (yet) gives no output rather than stopping takwerx.
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { $global:LASTEXITCODE = 127; return '' }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $exe @rest 2>$null } finally { $ErrorActionPreference = $old }
    if ($null -eq $o) { return '' }
    return ((@($o) | ForEach-Object { "$_" }) -join "`n").Replace("`r", '').TrimEnd()
}

# Quotes one argument for a Windows command line (Start-Process joins an array unquoted).
function Quote-Arg([string]$a) {
    if ($a -notmatch '[\s"]' -and $a.Length -gt 0) { return $a }
    return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# A hidden background run of this script: the jobs the Mac forks with ( ... ) & disown.
function Start-Background {
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $TakwerxScript) + @($args)
    $line = ($argv | ForEach-Object { Quote-Arg "$_" }) -join ' '
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $line -WindowStyle Hidden | Out-Null
}

# ---- downloads ------------------------------------------------------------------------------
function Get-Sha1([string]$path) { return (Get-FileHash -Algorithm SHA1 -Path $path).Hash.ToLowerInvariant() }

# Get-Download URL DEST [SHA1]: curl.exe, which shows real progress (Invoke-WebRequest
# crawls on large files), skipped when DEST is already there and verifies.
function Get-Download([string]$url, [string]$dest, [string]$sha1 = '') {
    if ((Test-Path $dest) -and ((-not $sha1) -or ((Get-Sha1 $dest) -eq $sha1))) { return }
    Step ("Downloading " + (Split-Path $dest -Leaf))
    $part = "$dest.part"
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & curl.exe -fL --retry 3 --retry-delay 2 -o $part $url } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $part)) { Remove-Item $part -ErrorAction SilentlyContinue; Die "Download failed: $url" }
    if ($sha1) {
        $have = Get-Sha1 $part
        if ($have -ne $sha1) { Remove-Item $part -Force; Die ("Checksum mismatch for {0} (got {1}, want {2}); the download is deleted, run again" -f (Split-Path $dest -Leaf), $have, $sha1) }
    }
    Move-Item -Force $part $dest
}

# Expand-Zip ZIP DIR [STRIP]: Windows' own bsdtar. Expand-Archive fails on the 1.5 GB system
# image ("A local file header is corrupt", DECISIONS 2026-09-27).
function Expand-Zip([string]$zip, [string]$dir, [int]$strip = 0) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if ($strip -gt 0) { & tar.exe -xf $zip -C $dir --strip-components=$strip } else { & tar.exe -xf $zip -C $dir }
    } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { Die "Could not unpack $(Split-Path $zip -Leaf)" }
}
function Get-ToolVersion([string]$dir) { $f = Join-Path $dir '.version'; if (Test-Path $f) { return (Get-Content $f -Raw).Trim() } return '' }
function Set-ToolVersion([string]$dir, [string]$v) { Set-Content -Path (Join-Path $dir '.version') -Value $v -Encoding ASCII }

# ---- where takwerx comes from, and updates ---------------------------------------------------
# Releases, as on the Mac: VERSION on main names the newest one, the tag v<VERSION> holds it.
# TAKWERX_BRANCH takes a branch; TAKWERX_SOURCE any zip URL (a development server).
function Get-TakwerxSource {
    $repo = if ($env:TAKWERX_REPO) { $env:TAKWERX_REPO } else { 'takwerx/atak-terminal' }
    if ($env:TAKWERX_SOURCE) { return @($env:TAKWERX_SOURCE, 'development source') }
    if ($env:TAKWERX_BRANCH) { return @("https://github.com/$repo/archive/refs/heads/$($env:TAKWERX_BRANCH).zip", "branch $($env:TAKWERX_BRANCH)") }
    $ver = (Invoke-Quiet curl.exe -fsSL --max-time 10 "https://raw.githubusercontent.com/$repo/main/VERSION").Trim()
    if (-not $ver) { return $null }
    return @("https://github.com/$repo/archive/refs/tags/v$ver.zip", "release $ver")
}

# Once a day at most, three seconds, one small file, silent on failure. From the icon a
# notification the day the news arrives; in a terminal a line for as long as it is behind.
function Update-Check([string]$mode = 'notify') {
    $repo = if ($env:TAKWERX_REPO) { $env:TAKWERX_REPO } else { 'takwerx/atak-terminal' }
    $stamp = Join-Path $State 'update-check'
    $fresh = $false
    if (-not (Test-Path $stamp) -or ((Get-Item $stamp).LastWriteTime -lt (Get-Date).AddDays(-1))) {
        $latest = (Invoke-Quiet curl.exe -fsSL --max-time 3 "https://raw.githubusercontent.com/$repo/main/VERSION").Trim()
        Set-Content -Path $stamp -Value $latest -Encoding ASCII
        $fresh = $true
    }
    $latest = (Get-Content $stamp -Raw).Trim()
    if (-not $latest -or $latest -eq $TakwerxVersion) { return }
    try { if ([version]$latest -le [version]$TakwerxVersion) { return } } catch { return }
    if ($fresh) { Log "update available: $latest" }
    if ($mode -eq 'notify' -and $fresh) { Notify "takwerx $latest is available (you have $TakwerxVersion). In PowerShell: takwerx update" }
    if ($mode -eq 'print') {
        Write-Host '  --  ' -ForegroundColor Yellow -NoNewline
        Write-Host "takwerx $latest is available (you have $TakwerxVersion): takwerx update, then takwerx restart. Notes: https://github.com/$repo/releases"
    }
}

# ---- the host --------------------------------------------------------------------------------
function Get-HostMemMB { return [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB) }
function Get-HostCpus  { return [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors }
function Clamp([int]$v, [int]$lo, [int]$hi) { if ($v -lt $lo) { return $lo } if ($v -gt $hi) { return $hi } return $v }

# ---- the ATAK APK ------------------------------------------------------------------------------
# ATAK-5.8.0.4-174b425-civ-release.apk, ATAK-CIV-5.8.0.4-...apk -> 5.8.0.4. Must say civ and
# start with ATAK and a version; plugins (ATAK-Plugin-...) give nothing.
function Get-ApkVersionFromName([string]$path) {
    $n = Split-Path $path -Leaf
    if ($n -notmatch '(?i)civ') { return '' }
    if ($n -match '(?i)^atak-(civ-)?(\d+(\.\d+)+)[-.].*\.apk$') { return $Matches[2] }
    return ''
}
# The newest ATAK by version number in Downloads or next to takwerx; same version twice,
# the newer file.
function Find-AtakApk {
    $dirs = @((Join-Path $env:USERPROFILE 'Downloads'), $App, (Split-Path $App -Parent))
    $best = $null; $bestV = $null
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        foreach ($f in Get-ChildItem -Path $d -Filter '*.apk' -File -ErrorAction SilentlyContinue) {
            $v = Get-ApkVersionFromName $f.FullName
            if (-not $v) { continue }
            $vv = [version]$v
            if ($null -eq $best -or $vv -gt $bestV -or ($vv -eq $bestV -and $f.LastWriteTime -gt $best.LastWriteTime)) { $best = $f; $bestV = $vv }
        }
    }
    if ($best) { return $best.FullName }
    return ''
}

# Windows' own file picker for the one thing takwerx cannot fetch (tak.gov needs a login).
function Select-AtakApk {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Title = 'Pick the ATAK-CIV APK you downloaded from tak.gov'
        $d.Filter = 'Android app (*.apk)|*.apk'
        $d.InitialDirectory = Join-Path $env:USERPROFILE 'Downloads'
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.FileName }
    } catch { Warn "Could not open a file picker: $($_.Exception.Message)" }
    return ''
}
# From the icon: a question first, so the picker does not appear out of nowhere.
function Request-AtakApk {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $r = [System.Windows.Forms.MessageBox]::Show("ATAK is not installed yet.`n`nDownload ATAK-CIV from tak.gov (it needs a login), then pick the file.`n`nOpen tak.gov now?", $AppName, 'YesNoCancel', 'Information')
        if ($r -eq 'Cancel') { return '' }
        if ($r -eq 'Yes') { Start-Process 'https://tak.gov/products/atak-civ' }
    } catch {}
    return (Select-AtakApk)
}
