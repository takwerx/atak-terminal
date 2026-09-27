# takwerx for Windows: the host side. The Mac's app bundle and Dock tile become a Start Menu
# and desktop shortcut carrying an AppUserModelID, and the emulator's windows carry the same
# ID, name and ATAK's icon, so Windows shows one taskbar button, "TAKwerx ATAK Terminal",
# that a right-click pins. Windows gives programs no way to pin themselves.

$script:IconFile = Join-Path $State 'icon.ico'

# The Start Menu (Programs) and desktop shortcuts, resolved when used.
function Get-ShortcutPaths {
    $paths = @()
    foreach ($folder in 'Programs', 'Desktop') {
        $d = [Environment]::GetFolderPath($folder)
        if ($d) { $paths += (Join-Path $d "$AppName.lnk") }
    }
    return $paths
}

# The C# helpers (lib/windows/native.cs), compiled once per process.
function Import-Native {
    if ('Takwerx.Native' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $App 'lib\windows\native.cs')) -Language CSharp -ErrorAction Stop
        return $true
    } catch {
        Warn "Windows helpers unavailable ($($_.Exception.Message.Split([char]10)[0])); the window keeps the emulator's own title and icon"
        return $false
    }
}

function Test-HostWindows {
    $os = Get-CimInstance Win32_OperatingSystem
    if (-not [Environment]::Is64BitOperatingSystem) { Die 'takwerx needs 64-bit Windows' }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { Die 'Windows on ARM has no Android Emulator from Google; takwerx needs an Intel or AMD PC' }
    $build = [int]$os.BuildNumber
    if ($build -lt 19041) { Die "Windows 10 2004 or newer is needed (this PC runs build $build)" }
    $mem = Get-HostMemMB
    if ($mem -lt 8000) { Warn "This PC has $([int]($mem/1024)) GB of memory; 16 GB or more is recommended" }
    Ok ("{0}, build {1}, {2} GB, {3} cores" -f $os.Caption, $build, [int]($mem / 1024), (Get-HostCpus))
}

# ---- the takwerx command in new terminals ---------------------------------------------------
function Set-TakwerxPath {
    $cmd = Join-Path $Bin 'takwerx.cmd'
    $script = Join-Path $Root 'app\takwerx.ps1'
    # One line that runs and exits: cmd reads a batch file as it goes, and `takwerx uninstall`
    # deletes this file under it ("The system cannot find the path specified").
    Set-Content -Path $cmd -Encoding ASCII -Value @(
        '@echo off',
        ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" %* & exit /b' -f $script)
    )
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $user) { $user = '' }
    if (($user -split ';') -notcontains $Bin) {
        [Environment]::SetEnvironmentVariable('Path', (($user.TrimEnd(';') + ';' + $Bin).TrimStart(';')), 'User')
        Ok 'New PowerShell windows have the takwerx command'
    }
}

# ---- the icon -----------------------------------------------------------------------------------
# ATAK's own launcher art, the largest ic_atak_launcher.png in the APK on this PC (96 px in
# 5.8), as on the Mac; nothing of ATAK's is shipped. Before ATAK is installed, takwerx's.
function Get-AtakIconPng([string]$out) {
    $apk = Get-Conf 'ATAK_APK'
    if (-not $apk -or -not (Test-Path $apk)) { $apk = Find-AtakApk }
    if (-not $apk -or -not (Test-Path $apk)) { return $false }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [System.IO.Compression.ZipFile]::OpenRead($apk)
        try {
            # Release builds: the resource table names the scrambled file. The SDK's
            # development build: the file itself is called ic_atak_launcher.png.
            $e = $null
            $table = $z.GetEntry('resources.arsc')
            if ($table -and (Import-Native)) {
                $ms = New-Object System.IO.MemoryStream
                $st = $table.Open(); $st.CopyTo($ms); $st.Dispose()
                $path = [Takwerx.Apk]::ResourcePath($ms.ToArray(), 'ic_atak_launcher')
                if ($path) { $e = $z.GetEntry($path) }
            }
            if (-not $e) { $e = $z.Entries | Where-Object { $_.FullName -like '*ic_atak_launcher.png' } | Sort-Object Length -Descending | Select-Object -First 1 }
            if (-not $e) { Log "no ic_atak_launcher in $apk"; return $false }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
            Log ("ATAK's icon: {0} from {1}" -f $e.FullName, (Split-Path $apk -Leaf))
            return $true
        } finally { $z.Dispose() }
    } catch { Log "ATAK's icon: $($_.Exception.Message)"; return $false }
}

# A Windows icon file with PNG images at 256, 64, 48, 32 and 16 px, scaled from one PNG.
function Write-IconFromPng([string]$png, [string]$ico) {
    Add-Type -AssemblyName System.Drawing
    $src = [System.Drawing.Image]::FromFile($png)
    $images = @()
    try {
        foreach ($s in 256, 64, 48, 32, 16) {
            $bmp = New-Object System.Drawing.Bitmap $s, $s
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.DrawImage($src, 0, 0, $s, $s)
            $g.Dispose()
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $images += , @($s, $ms.ToArray())
        }
    } finally { $src.Dispose() }
    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $out
    $w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($im in $images) {
        $s = $im[0]; $bytes = $im[1]
        $dim = if ($s -ge 256) { 0 } else { $s }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([UInt16]1); $w.Write([UInt16]32); $w.Write([UInt32]$bytes.Length); $w.Write([UInt32]$offset)
        $offset += $bytes.Length
    }
    foreach ($im in $images) { $w.Write([byte[]]$im[1]) }
    $w.Flush()
    [System.IO.File]::WriteAllBytes($ico, $out.ToArray())
    $w.Dispose()
}

function Update-Icon {
    $png = Join-Path $State 'icon-source.png'
    try {
        if (Get-AtakIconPng $png) { Write-IconFromPng $png $IconFile; return 'ATAK' }
    } catch { Warn "Could not make ATAK's icon ($($_.Exception.Message)); using takwerx's" }
    Copy-Item -Force (Join-Path $App 'assets\icon.ico') $IconFile
    return 'takwerx'
}

# ---- the shortcuts --------------------------------------------------------------------------------
# powershell.exe, hidden, running `takwerx up` as the Mac's app launcher does. Started
# minimized as well, so the console does not flash up before -WindowStyle Hidden takes it.
function Get-LaunchCommand {
    $script = Join-Path $Root 'app\takwerx.ps1'
    $ps = Join-Path $PSHOME 'powershell.exe'
    $a = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" up --from-app' -f $script
    return @($ps, $a)
}

function Build-App {
    $which = Update-Icon
    if (-not (Import-Native)) { Warn 'Shortcuts not created'; return }
    $cmd = Get-LaunchCommand
    foreach ($lnk in Get-ShortcutPaths) {
        try {
            [Takwerx.Native]::CreateShortcut($lnk, $cmd[0], $cmd[1], $Root, $IconFile,
                'ATAK on this PC, on its GPU', $AppId, 7)
        } catch { Warn "Could not write $lnk ($($_.Exception.Message))" }
    }
    Ok "$AppName in the Start Menu and on the desktop, with $which's icon. Right-click its taskbar button once it runs to pin it"
}

function Remove-App {
    foreach ($lnk in Get-ShortcutPaths) { Remove-Item -Force -ErrorAction SilentlyContinue $lnk }
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($user) {
        $kept = ($user -split ';' | Where-Object { $_ -and $_ -ne $Bin }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $kept, 'User')
    }
}

# ---- the window -----------------------------------------------------------------------------------
# The emulator's windows get the app's title, taskbar identity and icon. Qt sets its own
# at start, so the watcher (a long-running background takwerx) applies these and re-applies
# them if they change; the icon handles belong to that process, and die with it.
$script:IconHandles = $null
$script:IconStamp = $null
function Set-WindowIdentity([int]$qemuPid) {
    if (-not (Import-Native)) { return 0 }
    $stamp = if (Test-Path $IconFile) { (Get-Item $IconFile).LastWriteTimeUtc } else { $null }
    if ($null -eq $IconHandles -or $stamp -ne $IconStamp) {
        $script:IconHandles = @([Takwerx.Native]::LoadIcon($IconFile, 32), [Takwerx.Native]::LoadIcon($IconFile, 256))
        $script:IconStamp = $stamp
    }
    $cmd = Get-LaunchCommand
    $relaunch = (Quote-Arg $cmd[0]) + ' ' + $cmd[1]
    $n = 0
    foreach ($h in [Takwerx.Native]::WindowsOf($qemuPid)) {
        $t = [Takwerx.Native]::TitleOf($h)
        if ($t -like '*Emulator - *') { [Takwerx.Native]::SetTitle($h, $AppName) }
        [void][Takwerx.Native]::SetAppIdentity($h, $AppId, $relaunch, $AppName, "$IconFile,0")
        [Takwerx.Native]::SetIcons($h, $IconHandles[0], $IconHandles[1])
        $n++
    }
    return $n
}

function Show-EmulatorWindow([int]$qemuPid) {
    if (-not (Import-Native)) { return }
    foreach ($h in [Takwerx.Native]::WindowsOf($qemuPid)) {
        $t = [Takwerx.Native]::TitleOf($h)
        if ($t -eq $AppName -or $t -like '*Emulator - *') { [Takwerx.Native]::Front($h); return }
    }
}
