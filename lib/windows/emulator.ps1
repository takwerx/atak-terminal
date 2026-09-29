# takwerx for Windows: Google's Android Emulator on the PC's GPU. Mirrors lib/emulator.sh;
# every setting has its reason in docs/DECISIONS.md, 2026-09-26 (the Mac) and 2026-09-27
# (measured on Windows). What differs on Windows:
#   - x86-64 Android 14 google_apis image; ATAK-CIV ships x86-64 native libraries.
#   - Guest ANGLE on the GPU's own Vulkan driver; no MoltenVK, and no ANGLE override (that
#     was MoltenVK's). About 50 fps on an RTX 2000, 41-44 on Intel Arc.
#   - The hypervisor is Windows' own (WHPX), checked with `emulator -accel-check`.
#   - The emulator binary is never patched: title, icon and taskbar identity are set on its
#     windows at run time by the watcher.

$script:Sdk       = Join-Path $Tools 'android-sdk'
$script:EmuDir    = Join-Path $Sdk 'emulator'
$script:Emulator  = Join-Path $EmuDir 'emulator.exe'
$script:SysImgDir = Join-Path $Sdk ("system-images\android-{0}\{1}\x86_64" -f $V.SYSIMG_API, $V.SYSIMG_TAG)
$script:PtDir     = Join-Path $Sdk 'platform-tools'
$script:AvdHome   = Get-Conf 'EMU_AVD_HOME' (Join-Path $Root 'avd')
$script:Avd       = Get-Conf 'EMU_AVD' 'terminal'
$script:EmuPort   = [int](Get-Conf 'EMU_PORT' '5574')
$script:Serial    = "emulator-$EmuPort"
$script:EmuLog    = Join-Path $Logs 'emulator.log'
# Which GPU the emulator renders on, for a laptop with two: its own Vulkan device choice
# (ANDROID_EMU_VK_SELECT_GPU, matched against the device name); Windows' per-app GPU
# preference does not reach Vulkan. Empty: the emulator's choice, the discrete GPU.
$script:EmuGpu    = Get-Conf 'EMU_GPU' ''
$script:EmuFeatures = Get-Conf 'EMU_FEATURES' ''
$script:EmuArgs   = Get-Conf 'EMU_ARGS' ''
# Google apps the terminal has no use for, switched off at every boot; Chrome stays (it
# opens TAK Portal enrolment links). Play services goes too: its location providers flooded
# the log (DECISIONS 2026-09-26).
$script:TrimApps = Get-Conf 'EMU_TRIM_APPS' ('com.google.android.gms com.google.android.gm com.google.android.youtube ' +
    'com.google.android.apps.youtube.music com.google.android.apps.photos com.google.android.apps.messaging ' +
    'com.google.android.dialer com.google.android.googlequicksearchbox com.google.android.apps.wellbeing ' +
    'com.google.android.apps.maps com.google.android.apps.docs com.google.android.calendar com.google.android.contacts ' +
    'com.google.android.deskclock com.google.android.as com.google.android.as.oss ' +
    'com.google.android.projection.gearhead com.google.android.settings.intelligence')

function Test-EmuInstalled { return (Test-Path $Emulator) -and (Test-Path (Join-Path $SysImgDir 'system.img')) -and (Test-Path $Adb) }

# ---- will this PC run it --------------------------------------------------------------------------
# Graphics the emulator refuses, Google's two lists in the pinned build
# (emulator/lib/emu-original-feature-flags.protobuf: "Use Swiftshader on old GPUs on Windows,
# where we don't get a good Vulkan support", and "Just use Swiftshader on older Intel
# systems"). On these it sets ForceSwiftshader and draws Android on the processor: on an
# Intel HD 520 (2026-09-28) the window stayed blank and Android never finished booting, and
# ATAK would be far too slow anywhere. By chip, so no driver update lifts it.
$script:SoftwareGpus = @(
    '8086:0046', '8086:0102', '8086:0116', '8086:0126', '8086:0152', '8086:0156', '8086:015a',
    '8086:0162', '8086:0166', '8086:016a', '8086:0402', '8086:0412', '8086:0416', '8086:041e',
    '8086:0a16', '8086:0a1e', '8086:0f31', '8086:1616', '8086:1916', '8086:22b1', '8086:5916',
    '8086:a001', '8086:a002', '8086:a011', '8086:a012',
    '1002:6779', '1002:6840', '1002:68f9', '10de:0a65', '10de:0dfc', '1414:008c')

# The PC's graphics as @(name, "vendor:device"); remote and virtual displays have no PCI id.
function Get-HostGpus {
    $out = @()
    foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
        $id = ''
        if ("$($g.PNPDeviceID)" -match 'VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})') { $id = ('{0}:{1}' -f $Matches[1], $Matches[2]).ToLowerInvariant() }
        $out += , @("$($g.Name)", $id)
    }
    return $out
}
function Stop-SoftwareGpu([string]$names) {
    Die ("This PC's graphics ({0}) are on Google's list of chips too old for the Android Emulator. It would draw Android on the processor, far too slow for ATAK, and a driver update does not change that. takwerx needs newer graphics, such as Intel Iris Xe or Arc, or a recent NVIDIA or AMD" -f $names)
}

# Before anything is downloaded: graphics the emulator will use, and the disk space for
# what this run fetches. Sizes from Google's zips: the emulator 0.44 GB and 1.1 unpacked,
# Android 15 1.74 and 3.75 unpacked, both zips kept in the cache; a new device's data
# grows with ATAK's maps (10 GB on the Mac Studio's oldest). The Mac's twin is
# emu_disk_check.
function Test-EmuHost {
    $pci = @(Get-HostGpus | Where-Object { $_[1] })
    $bad = @($pci | Where-Object { ($SoftwareGpus -contains $_[1]) -or ($_[0] -match 'Microsoft Basic') })
    if ($pci.Count -gt 0 -and $bad.Count -eq $pci.Count) {
        $names = ($bad | ForEach-Object { $_[0] }) -join ', '
        if ($names -match 'Microsoft Basic') { Die "Windows has no driver for this PC's graphics ($names). Install the graphics driver from the PC's maker or Windows Update, then run the install line again" }
        Stop-SoftwareGpu $names
    }
    if ($bad.Count -gt 0) { Warn ("{0} is on Google's list of graphics too old for the Android Emulator; if the emulator picks it, takwerx stops and says so" -f (($bad | ForEach-Object { $_[0] }) -join ', ')) }
    elseif ($pci.Count -gt 0) { Ok ("Graphics: " + (($pci | ForEach-Object { $_[0] }) -join ', ')) }
    $need = 0.0
    if ((Get-ToolVersion $EmuDir) -ne $V.EMULATOR_VERSION) { $need += 1.6 }
    if ((Get-ToolVersion $SysImgDir) -ne $V.SYSIMG_REV) { $need += 5.5 }
    if (-not (Test-Path (Join-Path $AvdHome "$Avd.avd\config.ini"))) { $need += 4 }
    if ($need -eq 0) { return }
    $need += 2
    $drive = Get-PSDrive -Name ((Split-Path $Root -Qualifier).TrimEnd(':'))
    $free = $drive.Free / 1GB
    if ($free -lt $need) { Die ("Not enough free disk space on {0}: {1:N1} GB free, and Android with its tools needs about {2:N0} GB. Free some space, then run the install line again" -f $drive.Root, $free, $need) }
    Ok ("Disk: {0:N0} GB free on {1}" -f $free, $drive.Root)
}

# The emulator's own word, from its log: it chose software drawing anyway (a chip Google
# added after this list, or one of two graphics it picked). Not when asked for on purpose.
function Test-EmuSoftwareGpu {
    if ("$EmuFeatures $EmuArgs" -match '(?i)swiftshader') { return $false }
    try {
        $fs = [System.IO.File]::Open($EmuLog, 'Open', 'Read', 'ReadWrite')
        try { $text = (New-Object System.IO.StreamReader $fs).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return $false }
    return ($text -match "'ForceSwiftshader' is set")
}

# ---- Google's packages -------------------------------------------------------------------------
function Confirm-SdkLicense {
    if ((Get-Conf 'ANDROID_SDK_LICENSE') -eq 'accepted') { return }
    Write-Host ''
    Write-Host "The Android Emulator and its system image are Google's, under the Android SDK licence:" -ForegroundColor White
    Write-Host '  https://developer.android.com/studio/terms'
    if (-not (Test-Interactive)) { Die "Accept the Android SDK licence first: run 'takwerx init' in PowerShell" }
    if (-not (Confirm-Yes 'Accept it and download them (about 2 GB)?')) { Die "The emulator is Google's; declined" }
    Set-Conf 'ANDROID_SDK_LICENSE' 'accepted'
}

# A download already on this PC with the right checksum is used instead of fetching it
# again: takwerx's cache, or the measuring script's folder (tools/windows-measure.ps1).
function Get-Pinned([string]$url, [string]$name, [string]$sha1, [string[]]$seeds) {
    $dest = Join-Path $Cache $name
    if (-not (Test-Path $dest)) {
        foreach ($s in $seeds) {
            if ((Test-Path $s) -and (Get-Sha1 $s) -eq $sha1) { Copy-Item $s $dest; Ok "Reusing $s"; break }
        }
    }
    Get-Download $url $dest $sha1
    return $dest
}

function Install-EmuSdk {
    $measure = Join-Path $env:LOCALAPPDATA 'takwerx-accel'
    if ((Get-ToolVersion $EmuDir) -ne $V.EMULATOR_VERSION) {
        Confirm-SdkLicense
        $zip = Get-Pinned "https://dl.google.com/android/repository/emulator-windows_x64-$($V.EMULATOR_BUILD).zip" `
            "emulator-windows_x64-$($V.EMULATOR_BUILD).zip" $V.EMULATOR_WIN_SHA1 @((Join-Path $measure 'emu.zip'))
        Step "Unpacking the emulator $($V.EMULATOR_VERSION)"
        if (Test-Path $EmuDir) { Remove-Item -Recurse -Force $EmuDir }
        Expand-Zip $zip $Sdk
        Set-ToolVersion $EmuDir $V.EMULATOR_VERSION
    }
    Ok "Android Emulator $($V.EMULATOR_VERSION)"
    # The hypervisor is asked through the emulator, so right after it and before the 1.7 GB
    # image: a PC that needs a restart first has fetched 0.44 GB, not 2.2.
    Test-Hypervisor
    if ((Get-ToolVersion $SysImgDir) -ne $V.SYSIMG_REV) {
        Confirm-SdkLicense
        $zip = Get-Pinned "https://dl.google.com/android/repository/sys-img/$($V.SYSIMG_TAG)/x86_64-$($V.SYSIMG_API)_r$($V.SYSIMG_REV).zip" `
            "x86_64-$($V.SYSIMG_API)_r$($V.SYSIMG_REV).zip" $V.SYSIMG_X86_SHA1 @((Join-Path $measure 'sysimg.zip'))
        Step "Unpacking Android $($V.SYSIMG_API) (1.5 GB, a minute or two)"
        $parent = Split-Path $SysImgDir -Parent
        if (Test-Path $SysImgDir) { Remove-Item -Recurse -Force $SysImgDir }
        Expand-Zip $zip $parent
        if (-not (Test-Path (Join-Path $SysImgDir 'system.img'))) { Die 'The Android image did not unpack' }
        Set-ToolVersion $SysImgDir $V.SYSIMG_REV
    }
    Ok "Android $($V.SYSIMG_API) system image r$($V.SYSIMG_REV)"
    if ((Get-ToolVersion $PtDir) -ne $V.PLATFORM_TOOLS_WIN_VERSION) {
        $zip = Get-Pinned "https://dl.google.com/android/repository/platform-tools_r$($V.PLATFORM_TOOLS_WIN_VERSION)-win.zip" `
            "platform-tools_r$($V.PLATFORM_TOOLS_WIN_VERSION)-win.zip" $V.PLATFORM_TOOLS_WIN_SHA1 @()
        if (Test-Path $Adb) { [void](Invoke-Quiet $Adb 'kill-server') }
        if (Test-Path $PtDir) { Remove-Item -Recurse -Force $PtDir }
        Expand-Zip $zip $Sdk
        Set-ToolVersion $PtDir $V.PLATFORM_TOOLS_WIN_VERSION
    }
    Ok "Android platform tools $($V.PLATFORM_TOOLS_WIN_VERSION)"
}

# Windows' own hypervisor platform, the one thing that needs an administrator, once. Already
# on where virtualization-based security runs, as on a managed Dell (DECISIONS 2026-09-27).
function Test-Hypervisor {
    $r = Invoke-Quiet $Emulator '-accel-check'
    if ($r -match 'is installed and usable') { Ok ("Hypervisor: " + (($r -split "`n") | Where-Object { $_ -match 'usable' } | Select-Object -First 1).Trim()); return }
    Log "accel-check: $r"
    Write-Host ''
    Write-Host 'Windows Hypervisor Platform is off. Android needs it, and switching it on needs an administrator once, then a restart:' -ForegroundColor Yellow
    Write-Host '  Start, type "Turn Windows features on or off", tick Windows Hypervisor Platform, OK, restart'
    Write-Host '  or, in PowerShell as Administrator:  Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All'
    Write-Host '  Virtualization (Intel VT-x or AMD SVM) must also be on in the PC''s firmware; Task Manager,'
    Write-Host '  Performance, CPU shows "Virtualization: Enabled". On a work PC, ask IT. Then run the install line again.'
    if (Confirm-Yes 'Switch it on now (Windows asks for an administrator)?') {
        try {
            Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -Wait -ArgumentList '-NoProfile -Command "Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart"'
            Die 'Restart Windows, then run: takwerx init'
        } catch [System.OperationCanceledException] { throw } catch { Die "Could not switch it on ($($_.Exception.Message)); ask your IT department to enable Windows Hypervisor Platform" }
    }
    Die 'Windows Hypervisor Platform is needed; takwerx init again once it is on'
}

# ---- the device -----------------------------------------------------------------------------------
# Android's screen, "W H DPI". The emulator scales a fixed Android screen into its window, so
# by default Android gets the screen's work area less the window's title bar and side
# toolbar: a maximized window is 1:1. DPI 200 per 96 of Windows' scaling, as the Mac's 200
# per point, so a dp is the same physical size on both.
function Get-EmuGeometry {
    $preset = Get-Conf 'EMU_DISPLAY' 'screen'
    switch ($preset) {
        'tablet'  { return @(2560, 1600, 320) }
        'desktop' { return @(1920, 1080, 240) }
        'phone'   { return @(1080, 2340, 440) }
        'ultra'   { return @(3440, 1440, 280) }
    }
    if ($preset -match '^(\d+)x(\d+)@(\d+)$') { return @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
    $wa = $null
    if (Import-Native) { try { $wa = ([Takwerx.Native]::WorkArea() -split ' ') } catch {} }
    if (-not $wa) { return @(2560, 1600, 320) }
    $k = [double]$wa[2] / 96.0
    $w = [int]$wa[0] - [int](90 * $k); $h = [int]$wa[1] - [int](50 * $k)
    $w -= $w % 2; $h -= $h % 2
    return @($w, $h, [int][Math]::Round(200 * $k))
}

# Guest RAM a third of the PC's, 4 to 8 GB; cores half, 2 to 4 (emu_sizing).
function Get-EmuSizing { return @((Clamp ([int]((Get-HostMemMB) / 3)) 4096 8192), (Clamp ([int]((Get-HostCpus) / 2)) 2 4)) }

function New-Avd {
    $dir = Join-Path $AvdHome "$Avd.avd"
    if (Test-Path (Join-Path $dir 'config.ini')) { return }
    Step "Creating the Android device ($Avd)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $s = Get-EmuSizing
    Set-Content -Path (Join-Path $AvdHome "$Avd.ini") -Encoding ASCII -Value @(
        'avd.ini.encoding=UTF-8', "path=$dir", "path.rel=avd\$Avd.avd", "target=android-$($V.SYSIMG_API)")
    Set-Content -Path (Join-Path $dir 'config.ini') -Encoding ASCII -Value @(
        "AvdId=$Avd", "avd.ini.displayname=$AppName", 'avd.ini.encoding=UTF-8', 'PlayStore.enabled=no',
        'abi.type=x86_64', 'disk.dataPartition.size=10G', 'fastboot.forceColdBoot=yes', 'fastboot.forceFastBoot=no',
        'hw.accelerometer=yes', 'hw.arc=false', 'hw.audioInput=yes', 'hw.audioOutput=yes', 'hw.battery=yes',
        'hw.camera.back=none', 'hw.camera.front=none', 'hw.cpu.arch=x86_64', "hw.cpu.ncore=$($s[1])", 'hw.dPad=no',
        'hw.gps=yes', 'hw.gpu.enabled=yes', 'hw.gpu.mode=host', 'hw.gsmModem=yes', 'hw.gyroscope=yes',
        'hw.initialOrientation=landscape', 'hw.keyboard=yes', 'hw.keyboard.charmap=qwerty2', 'hw.keyboard.lid=yes',
        'hw.lcd.backlight=yes', 'hw.lcd.depth=32', 'hw.lcd.vsync=60', 'hw.mainKeys=no', "hw.ramSize=$($s[0])",
        'hw.screen=multi-touch', 'hw.sdCard=no', 'hw.sensors.magnetic_field=yes', 'hw.sensors.orientation=yes',
        'hw.sensors.proximity=no', 'hw.trackBall=no', 'hw.useext4=yes',
        "image.sysdir.1=system-images/android-$($V.SYSIMG_API)/$($V.SYSIMG_TAG)/x86_64/",
        'kernel.newDeviceNaming=autodetect', 'kernel.supportsYaffs2=autodetect', 'showDeviceFrame=no', 'skin.dynamic=yes',
        'tag.display=Google APIs', "tag.id=$($V.SYSIMG_TAG)", "target=android-$($V.SYSIMG_API)", 'vm.heapSize=256M')
    Ok ("Device {0}: {1} cores, {2} MB" -f $Avd, $s[1], $s[0])
}

# An existing device moves to the pinned Android image with its data (emu_upgrade_image on
# the Mac): the emulator keeps the image's build number in version_num.cache and discards
# the data partition when it changes, while Android upgrades the data in place as an OS
# update does. So the new build number is written first. A copy of the device is kept until
# Android has booted once, when the drive has room for it (NTFS copies for real).
function Get-AvdSysdir { return ("system-images/android-{0}/{1}/x86_64/" -f $V.SYSIMG_API, $V.SYSIMG_TAG) }
function Test-AvdImageCurrent {
    $ini = Join-Path $AvdHome "$Avd.avd\config.ini"
    if (-not (Test-Path $ini)) { return $true }
    return [bool](Select-String -Path $ini -SimpleMatch -Pattern ("image.sysdir.1=" + (Get-AvdSysdir)) -Quiet)
}
function Update-AvdImage {
    if (Test-AvdImageCurrent) { return }
    $dir = Join-Path $AvdHome "$Avd.avd"; $ini = Join-Path $dir 'config.ini'
    $old = ''
    foreach ($l in Get-Content $ini) { if ($l -match '^image\.sysdir\.1=system-images/android-(\d+)/') { $old = $Matches[1] } }
    $build = ''
    $prop = Join-Path $SysImgDir 'build.prop'
    if (Test-Path $prop) { foreach ($l in Get-Content $prop) { if ($l -match '^ro\.build\.version\.incremental=(.+)$') { $build = $Matches[1].Trim(); break } } }
    Step "Moving Android $old to Android $($V.SYSIMG_API); ATAK and its data stay (the first start takes a little longer)"
    $keep = "$dir.before-android$($V.SYSIMG_API)"
    if ((Test-Path (Join-Path $dir 'userdata-qemu.img.qcow2')) -and -not (Test-Path $keep)) {
        $size = (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum
        $free = (Get-PSDrive -Name ((Split-Path $dir -Qualifier).TrimEnd(':'))).Free
        if ($free -gt 2 * $size) {
            Copy-Item -Recurse $dir $keep -ErrorAction SilentlyContinue
            Get-ChildItem $keep -Filter '*.lock' -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
        } else { Warn ("Not enough free space to keep a copy of Android {0}'s data ({1:N1} GB); carrying on without one" -f $old, ($size / 1GB)) }
    }
    if ($build) { [System.IO.File]::WriteAllText((Join-Path $dir 'version_num.cache'), $build) }
    else { Warn "No build number in the Android $($V.SYSIMG_API) image; the emulator may start with empty data" }
    $lines = Get-Content $ini | ForEach-Object {
        if ($_ -match '^image\.sysdir\.1=') { 'image.sysdir.1=' + (Get-AvdSysdir) }
        elseif ($_ -match '^target=') { "target=android-$($V.SYSIMG_API)" }
        else { $_ }
    }
    Set-Content -Path $ini -Value $lines -Encoding ASCII
    $top = Join-Path $AvdHome "$Avd.ini"
    if (Test-Path $top) { Set-Content -Path $top -Encoding ASCII -Value (Get-Content $top | ForEach-Object { if ($_ -match '^target=') { "target=android-$($V.SYSIMG_API)" } else { $_ } }) }
    Log "AVD $Avd moved from android-$old to android-$($V.SYSIMG_API) (build $build)"
}
function Complete-AvdUpgrade {
    $keep = Join-Path $AvdHome "$Avd.avd.before-android$($V.SYSIMG_API)"
    if ((Test-Path $keep) -and (Test-AndroidBooted)) {
        Remove-Item -Recurse -Force $keep -ErrorAction SilentlyContinue
        Log "Android $($V.SYSIMG_API) booted with the device's data; the copy from before is removed"
    }
}

# Written before every boot: the screen, RAM and cores. The physical density is three
# quarters of the UI density, as on the Mac (ATAK draws its map at the smaller of the two).
function Set-AvdConfig {
    $ini = Join-Path $AvdHome "$Avd.avd\config.ini"
    if (-not (Test-Path $ini)) { Die "No Android device named $Avd (expected $ini)" }
    Update-AvdImage
    $g = Get-EmuGeometry; $s = Get-EmuSizing
    $lines = @(Get-Content $ini | Where-Object { $_ -notmatch '^(hw\.lcd\.(width|height|density)|hw\.ramSize|hw\.cpu\.ncore)\s*=' })
    $lines += @("hw.lcd.width=$($g[0])", "hw.lcd.height=$($g[1])", ("hw.lcd.density={0}" -f [int]($g[2] * 3 / 4)), "hw.ramSize=$($s[0])", "hw.cpu.ncore=$($s[1])")
    Set-Content -Path $ini -Value $lines -Encoding ASCII
    Log ("emulator screen {0}x{1}, ui dpi {2}, {3} MiB, {4} cores" -f $g[0], $g[1], $g[2], $s[0], $s[1])
}

# ---- running it ---------------------------------------------------------------------------------------
function Get-EmuProcess {
    $p = Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match ('-avd\s+' + [regex]::Escape($Avd) + '(\s|$)') } | Select-Object -First 1
    return $p
}
function Test-EmuRunning { return [bool](Get-EmuProcess) }

# Guest ANGLE on Vulkan; VirtioTablet makes the pointer a real mouse in Android; the Wi-Fi
# packet stream off, or every tile request detours through netsim (800 ms against 45).
# No -grpc: it would listen on every interface, unauthenticated.
function Start-Emu {
    if (Test-EmuRunning) { return }
    if (-not (Test-EmuInstalled)) { Die 'Not installed yet. Run: takwerx init' }
    # Another emulator on this port (another AVD, Android Studio, the measuring script) would
    # answer on emulator-5574 in place of ours, and be set up as if it were takwerx's.
    $other = Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match ('-port\s+' + $EmuPort + '(\s|$)') } | Select-Object -First 1
    if ($other) { Die ("Another Android Emulator is running (process {0}); close its window or stop it first, then try again" -f $other.ProcessId) }
    New-Item -ItemType Directory -Force -Path $AvdHome | Out-Null
    New-Avd
    Get-ChildItem (Join-Path $AvdHome "$Avd.avd") -Filter '*.lock' -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    Set-AvdConfig
    $g = Get-EmuGeometry
    Step ("Starting Android on the GPU ({0}, {1}x{2} at {3} dpi)" -f $Avd, $g[0], $g[1], $g[2])
    $env:ANDROID_SDK_ROOT = $Sdk; $env:ANDROID_HOME = $Sdk; $env:ANDROID_AVD_HOME = $AvdHome
    if ($EmuGpu) { $env:ANDROID_EMU_VK_SELECT_GPU = $EmuGpu } else { Remove-Item Env:ANDROID_EMU_VK_SELECT_GPU -ErrorAction SilentlyContinue }
    $features = 'Vulkan,GuestAngle,VirtioTablet,-WiFiPacketStream'
    if ($EmuFeatures) { $features += ",$EmuFeatures" }
    $argv = @('-avd', $Avd, '-port', "$EmuPort", '-gpu', 'host', '-feature', $features, '-no-snapshot', '-no-boot-anim')
    if ($EmuArgs) { $argv += ($EmuArgs -split '\s+') }
    Log ("emulator start: {0}, {1}" -f (Get-ToolVersion $EmuDir), ($argv -join ' '))
    Start-Process -FilePath $Emulator -ArgumentList (($argv | ForEach-Object { Quote-Arg $_ }) -join ' ') -WorkingDirectory $EmuDir `
        -WindowStyle Hidden -RedirectStandardOutput $EmuLog -RedirectStandardError "$EmuLog.err" | Out-Null
}

# The watcher starts as soon as the emulator's process does, not after the boot: until it
# gives the window the app's identity, the taskbar button is bare qemu-system-x86_64.exe,
# and a pin made then (as takwerx invites) or its jump-list entry starts qemu without the
# emulator's lib64, one "libandroid-emu-agents.dll was not found" box per DLL (a 4-core,
# 8 GB PC, 2026-09-28, where the boot outlasted the user's patience).
function Wait-Emu([int]$seconds = 300) {
    $start = Get-Date
    Start-AdbServer
    $watched = $false
    while (((Get-Date) - $start).TotalSeconds -lt $seconds) {
        if (-not $watched) { $watched = Start-Watcher }
        if (((Get-Date) - $start).TotalSeconds -lt 90 -and (Test-EmuSoftwareGpu)) {
            $p = Get-EmuProcess
            if ($p) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-SoftwareGpu ((Get-HostGpus | ForEach-Object { $_[0] }) -join ', ')
        }
        if ((Test-AndroidOnline) -and (Test-AndroidBooted)) { return $true }
        if (-not (Test-EmuRunning) -and ((Get-Date) - $start).TotalSeconds -gt 30) { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}

# Idempotent settings for a desktop instance, on every boot (emu_provision). One script,
# pushed and run inside Android, then the splash and ATAK's own files.
function Invoke-Provision {
    $g = Get-EmuGeometry
    [void](Enable-AdbRoot)
    $body = @'
DPI=$1; shift
EN=$(pm list packages -e --user 0)
for P in "$@"; do echo "$EN" | grep -qx "package:$P" && pm disable-user --user 0 "$P" >/dev/null 2>&1 && TRIMMED=1; done
[ -n "$TRIMMED" ] && am force-stop com.google.android.apps.nexuslauncher
echo 'chrome --disable-features=AndroidSurfaceControl' > /data/local/tmp/chrome-command-line; chmod 644 /data/local/tmp/chrome-command-line
settings put system screen_off_timeout 2147483647
settings put global stay_on_while_plugged_in 7
svc power stayon true
locksettings set-disabled true >/dev/null 2>&1
settings put secure show_ime_with_hard_keyboard 0
settings put secure stylus_handwriting_enabled 0
cmd uimode night yes >/dev/null
pkill -f com.android.systemui
wm size reset
wm density $DPI
mkdir -p /sdcard/atak && touch /sdcard/atak/opengl.broken
F=/sdcard/atak/devopts.properties
grep -q "^mapengine.glmapview.use-pbo-cull=" "$F" 2>/dev/null || echo "mapengine.glmapview.use-pbo-cull=0" >> "$F"
echo provisioned
'@
    # Chrome on guest ANGLE: SurfaceControl's fences fail and its GPU process restarts every
    # two seconds without the flag. Dark mode, so ATAK's toasts are readable; SystemUI
    # restarted so it takes it. opengl.broken: ATAK did not stay up on either GPU path
    # without it (DECISIONS 2026-09-27). The CPU terrain cull, as ATAK's own Apple build.
    $argv = @("$($g[2])") + ($TrimApps -split '\s+' | Where-Object { $_ })
    [void](Invoke-AndroidScript 'takwerx-provision.sh' $body $argv)
    Set-AtakSplash $g[0] $g[1]
}

# The takwerx version the running Android was brought up under, from its watcher; empty
# when the watcher predates 0.2.1 or none runs. `takwerx update` restarts Android when it
# differs, so the running system is the new one.
function Get-RunningVersion {
    $marker = Join-Path $State 'watcher.pid'
    if (-not (Test-Path $marker)) { return '' }
    $f = (Get-Content $marker -Raw).Trim() -split ' '
    if ($f.Count -ge 3) { return $f[2] }
    return ''
}

# True once a watcher is on the running emulator. The marker is "watcher qemu version"
# since 0.2.1, and before that "watcher qemu".
function Start-Watcher {
    $p = Get-EmuProcess
    if (-not $p) { return $false }
    $marker = Join-Path $State 'watcher.pid'
    if (Test-Path $marker) {
        $old = (Get-Content $marker -Raw).Trim() -split ' '
        if ($old.Count -ge 2 -and $old[1] -eq "$($p.ProcessId)" -and (Get-Process -Id ([int]$old[0]) -ErrorAction SilentlyContinue)) { return $true }
    }
    Start-Background '_watch' "$($p.ProcessId)"
    return $true
}

$script:Provisioned = $false
function Invoke-EmuUp {
    Start-Emu
    if (-not ((Test-AndroidOnline) -and (Test-AndroidBooted))) {
        Step 'Waiting for Android to boot'
        if (-not (Wait-Emu 300)) {
            $keep = Join-Path $AvdHome "$Avd.avd.before-android$($V.SYSIMG_API)"
            $extra = if (Test-Path $keep) { ". The device from before the move to Android $($V.SYSIMG_API) is kept at $keep" } else { '' }
            Die "Android did not come up (the emulator exited or took over 5 minutes). See $EmuLog$extra"
        }
    }
    Ok 'Android is up'
    Complete-AvdUpgrade
    [void](Start-Watcher)
    if (-not $script:Provisioned) {
        Invoke-Provision
        # ATAK's permissions, again at every start: Android keeps them across a restart, and
        # yet ATAK asked for file access after one on the Dell (2026-09-27). Idempotent.
        if (Test-AtakInstalled) { Grant-Atak }
        $script:Provisioned = $true
    }
    Send-Position
}

# A clean power-off: ATAK stopped, sync, then Android's own shutdown; the emulator exits by
# itself. `adb emu kill` is a pulled plug and cost a plugin its saved layers on the Mac.
function Stop-Emu {
    if (-not (Test-EmuRunning)) { return }
    Step 'Stopping Android'
    if (Test-AndroidOnline) {
        Stop-Atak
        [void](AdbSh 'sync')
        [void](AdbSh 'reboot' '-p')
    }
    for ($i = 0; $i -lt 45; $i++) { if (-not (Test-EmuRunning)) { return }; Start-Sleep -Seconds 1 }
    Warn 'Android did not power off within 45 seconds; stopping the emulator'
    [void](Adb 'emu' 'kill')
    Start-Sleep -Seconds 3
    $p = Get-EmuProcess
    if ($p) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
}

# The long-running companion of a running emulator, one per emulator process, hidden:
#   - the window's title, taskbar identity and ATAK's icon, re-applied when Qt changes them;
#   - the display stays on (a map terminal does not go dark; caffeinate on the Mac);
#   - ATAK restarted when Android reports it not responding (emu_watchdog), and ATAK's
#     load-plugins question after that restart answered, since the user chose those plugins.
function Invoke-Watch([int]$qemuPid) {
    Set-Content -Path (Join-Path $State 'watcher.pid') -Value "$PID $qemuPid $TakwerxVersion" -Encoding ASCII
    if (Import-Native) { [Takwerx.Native]::StayAwake() }
    $last = ''; $tick = 0
    while (Get-Process -Id $qemuPid -ErrorAction SilentlyContinue) {
        try { [void](Set-WindowIdentity $qemuPid) } catch { Log "watcher: window identity: $($_.Exception.Message)" }
        Start-Sleep -Seconds 3
        $tick += 3
        if ($tick % 12 -ne 0) { continue }
        $ev = (AdbSh 'logcat' '-b' 'events' '-d' '-t' '200') -split "`n" | Where-Object { $_ -match "am_anr.*$([regex]::Escape($AtakPackage))" } | Select-Object -Last 1
        if (-not $ev -or $ev -eq $last) { continue }
        $last = $ev
        Log 'watchdog: ATAK not responding; restarting it'
        [void](AdbSh 'am' 'force-stop' $AtakPackage)
        Start-Sleep -Seconds 2
        Start-Atak
        Start-Sleep -Seconds 25
        [void](AdbSh 'input' 'keyevent' 'KEYCODE_HOME'); Start-Sleep -Seconds 1; Start-Atak
        for ($i = 0; $i -lt 8; $i++) {
            Start-Sleep -Seconds 5
            $ui = AdbSh 'uiautomator dump /sdcard/takwerx-ui.xml >/dev/null 2>&1; cat /sdcard/takwerx-ui.xml'
            if ($ui -match 'text="Load Plugins"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"') {
                [void](AdbSh 'input' 'tap' ([int](([int]$Matches[1] + [int]$Matches[3]) / 2)) ([int](([int]$Matches[2] + [int]$Matches[4]) / 2)))
                Log 'watchdog: answered the load-plugins question'
                break
            }
        }
    }
}
