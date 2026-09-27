# takwerx measure: the Windows brief's measure-first phase (docs/PLAN-windows.md), run by
# hand on a Windows PC in a normal PowerShell. Everything lands in %LOCALAPPDATA%\takwerx-accel.
#   .\measure.ps1                       stock GPU path (-gpu host, the emulator's own translator)
#   .\measure.ps1 -Mode angle           guest ANGLE on the host's Vulkan driver (the Mac recipe)
#   .\measure.ps1 -Mode angle -AngleOverride   ...with the ANGLE pipeline warm-up switched off
#   .\measure.ps1 -AtakTweaks           also ATAK's opengl.broken and CPU terrain cull, as on the Mac
#   .\measure.ps1 -Gpu nvidia|intel|auto  which GPU Windows gives the emulator on a two-GPU laptop
#   .\measure.ps1 -Location "lat,lon"    the GPS fix Android gets (the Mac sends the Mac's own; here a fixed one)
#   .\measure.ps1 -EnablePlugins        switch every installed plugin on in ATAK and restart it (the Mac's takwerx plugin)
#   .\measure.ps1 -NetTest              time the same downloads on Windows and inside Android; look for a VPN or proxy
#   .\measure.ps1 -Wheel                record what one mouse-wheel click sends into Android (Cursorwerx's zoom step)
#   .\measure.ps1 -Stop                 power Android off
# At the end the results folder is zipped and sent to the Mac on the switch (-Mac host:port),
# where tools/measure-server.py serves this script and the ATAK APK and receives the results:
#   python3 tools/measure-server.py <mac-ip> 8000   (from a folder holding this script and ATAK.apk)
# A development tool, not part of the product; findings in docs/DECISIONS.md, 2026-09-27.
param(
  [ValidateSet('stock','angle')][string]$Mode = 'stock',
  [switch]$AngleOverride, [switch]$AtakTweaks, [switch]$Stop, [switch]$EnablePlugins, [switch]$NetTest, [switch]$Wheel,
  [ValidateSet('auto','nvidia','intel')][string]$Gpu = 'auto',
  [string]$Location = '33.576257,-117.240598',
  [string]$Mac = '192.168.123.99:8000'
)
$ErrorActionPreference = 'Continue'
$root = Join-Path $env:LOCALAPPDATA 'takwerx-accel'
New-Item -ItemType Directory -Force $root | Out-Null
Set-Location $root
$adb = Join-Path $root 'platform-tools\adb.exe'
$emu = Join-Path $root 'emulator\emulator.exe'
$serial = 'emulator-5574'
$pkg = 'com.atakmap.app.civ'
$env:ANDROID_SDK_ROOT = $root; $env:ANDROID_HOME = $root
$env:ANDROID_AVD_HOME = Join-Path $root 'avd'; $env:ANDROID_ADB_SERVER_PORT = '5038'

function EmuProcs { Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'qemu-system-*' } }
if ($Stop) {
  & $adb -s $serial shell reboot -p 2>$null | Out-Null
  Write-Host 'Powering Android off...'
  for ($i = 0; $i -lt 45 -and (EmuProcs); $i++) { Start-Sleep 1 }
  if (EmuProcs) { Write-Host 'Android did not power off in 45 s; stopping the emulator.'; EmuProcs | Stop-Process -Force }
  & $adb kill-server 2>$null | Out-Null
  Write-Host 'Android is off.'
  exit 0
}

# ATAK sets shouldLoad-<package>=false on every plugin it installs and asks in its Plugins
# screen; a plugin it was never asked about has no entry at all and is skipped. As on the
# Mac (emu_plugins_enable): ATAK quits cleanly, every entry is set true and the missing
# ones added, ATAK starts again. The edit runs from a script pushed to Android, since a
# sed expression does not survive PowerShell's quoting on its way through adb.
if ($EnablePlugins) {
  $sh = @'
PKG=com.atakmap.app.civ
P=/data/data/$PKG/shared_prefs/${PKG}_preferences.xml
am broadcast -a com.atakmap.app.QUITAPP --ez FORCE_QUIT true >/dev/null 2>&1
i=0; while [ $i -lt 10 ] && pidof $PKG >/dev/null; do sleep 1; i=$((i+1)); done
am force-stop $PKG
[ -f "$P" ] || { echo "ATAK has no preferences yet (never run)"; exit 0; }
sed -i 's|"shouldLoad-\([^"]*\)" value="false"|"shouldLoad-\1" value="true"|g' "$P"
for pkg in $(pm list packages | sed -n 's/^package:\(com\.atakmap\.android\..*\.plugin\)$/\1/p'); do
  grep -q "shouldLoad-$pkg\"" "$P" || sed -i "s|</map>|    <boolean name=\"shouldLoad-$pkg\" value=\"true\" />\n</map>|" "$P"
done
echo "plugins switched on: $(grep -c 'shouldLoad-[^"]*" value="true"' "$P")"
'@
  $local = Join-Path $root 'enable-plugins.sh'
  [IO.File]::WriteAllText($local, ($sh -replace "`r`n", "`n"))
  & $adb -s $serial root 2>$null | Out-Null; Start-Sleep 3; & $adb -s $serial wait-for-device 2>$null
  & $adb -s $serial push $local /data/local/tmp/enable-plugins.sh 2>$null | Out-Null
  & $adb -s $serial shell sh /data/local/tmp/enable-plugins.sh
  $act = ((& $adb -s $serial shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $pkg 2>$null) -split "`n" | Select-Object -Last 1).Trim()
  & $adb -s $serial shell am start -n $act 2>$null | Out-Null
  Write-Host 'ATAK is restarting with its plugins on.'
  exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $root ("results-{0}-{1}" -f $Mode, $stamp)
New-Item -ItemType Directory -Force $out | Out-Null
$log = Join-Path $out 'measure.txt'
function Say([string]$m) { $l = ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $m); Write-Host $l; Add-Content -Path $log -Value $l }
# A plain function on purpose: with a param() block PowerShell would read -d, -W and -c as its own switches.
function AdbOut { (& $adb -s $serial @args 2>$null) -join "`n" }

Say ("takwerx measure, mode {0}{1}{2}" -f $Mode, $(if ($AngleOverride) { ' + AngleOverride' }), $(if ($AtakTweaks) { ' + AtakTweaks' }))


# ---- network: why tiles arrive slowly -------------------------------------------------------
# The same downloads timed on Windows and inside Android, and what sits in the path on Windows.
if ($NetTest) {
  try {
    Say 'network: timing downloads on Windows'
    $u = 'http://dl.google.com/android/repository/platform-tools-latest-windows.zip'
    for ($i = 1; $i -le 3; $i++) { Say ("windows throughput: " + (& curl.exe -s -o NUL -w "%{size_download} bytes in %{time_total}s = %{speed_download} B/s" $u)) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le 20; $i++) { & curl.exe -s -o NUL http://www.google.com/generate_204 }
    Say ("windows round trip: 20 requests in {0} ms = {1} ms each" -f $sw.ElapsedMilliseconds, [int]($sw.ElapsedMilliseconds / 20))
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if ($route) { Say ("default route via: {0}" -f $route.InterfaceAlias) }
    Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object { Say ("adapter up: {0} ({1}), {2}" -f $_.Name, $_.InterfaceDescription, $_.LinkSpeed) }
    Say ("winhttp proxy: " + ((netsh winhttp show proxy) -join ' ' -replace '\s+', ' ').Trim())
    $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    Say ("user proxy: enabled={0} server={1} pac={2}" -f $ie.ProxyEnable, $ie.ProxyServer, $ie.AutoConfigURL)
    $agents = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)zscaler|zsatunnel|zsaservice|globalprotect|pangp|vpnagent|anyconnect|netskope|stagent|forti|csfalcon|sentinel|cylance|tanium|umbrella|ciscod' } | Select-Object -ExpandProperty ProcessName -Unique
    Say ("network and security agents running: " + $(if ($agents) { $agents -join ', ' } else { 'none recognised' }))
    try { $mp = Get-MpComputerStatus -ErrorAction Stop; Say ("defender: real-time {0}, mode {1}" -f $mp.RealTimeProtectionEnabled, $mp.AMRunningMode) } catch { Say 'defender: status not readable' }
    if ([bool](EmuProcs)) {
      Say 'network: timing the same inside Android'
      $sh = @'
# Timed HTTP from inside Android, over the emulator's network. No curl in the image: the request
# goes through toybox nc; the clock is /proc/uptime (10 ms steps).
now() { cut -d' ' -f1 /proc/uptime | tr -d .; }
get() { printf 'GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: takwerx\r\nConnection: close\r\n\r\n' "$2" "$1" | nc -w 10 -q 30 "$1" 80 2>/dev/null | wc -c; }
for i in 1 2 3; do
  s=$(now); n=$(get dl.google.com /android/repository/platform-tools-latest-windows.zip); e=$(now)
  ms=$(( (e - s) * 10 )); [ "$ms" -gt 0 ] || ms=1
  echo "android throughput: $n bytes in $ms ms = $(( n / ms )) KB/s"
done
# Tiles are small, so the round trip is what a user feels: 20 requests one after another.
s=$(now); for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do get www.google.com /generate_204 >/dev/null; done; e=$(now)
echo "android round trip: 20 requests in $(( (e - s) * 10 )) ms = $(( (e - s) / 2 )) ms each"
'@
      $local = Join-Path $root 'nettest.sh'
      [IO.File]::WriteAllText($local, ($sh -replace "`r`n", "`n"))
      & $adb -s $serial push $local /data/local/tmp/nettest.sh 2>$null | Out-Null
      (& $adb -s $serial shell sh /data/local/tmp/nettest.sh 2>$null) | ForEach-Object { Say $_ }
    } else { Say 'Android is not running; the in-Android half is skipped' }
  } catch { Say ("FAILED: {0}" -f $_.Exception.Message) }
}

# ---- the mouse wheel: what one click becomes inside Android -----------------------------------
# Cursorwerx zooms one step per wheel click and counts a click as 8 units from the emulator's
# virtio tablet, which is what the Mac's emulator sends. This records the raw events while the
# operator clicks the wheel five times, so Windows' unit is known rather than guessed.
if ($Wheel) {
  try {
    $dev = ''
    $cur = ''
    foreach ($line in ((& $adb -s $serial shell getevent -pl 2>$null) -split "`n")) {
      if ($line -match '^add device \d+: (\S+)') { $cur = $Matches[1] }
      if ($line -match 'name:\s+"(.*)"' -and $Matches[1] -match 'Virtio Tablet') { $dev = $cur }
    }
    if (-not $dev) { Say 'wheel: no QEMU Virtio Tablet in getevent'; }
    else {
      Say ("wheel: tablet is {0}" -f $dev)
      Write-Host ''
      Write-Host '>>> Put the mouse over the map. In the next 12 seconds click the wheel 5 times TOWARDS you,' -ForegroundColor Yellow
      Write-Host '>>> slowly, one click per second. Nothing else.' -ForegroundColor Yellow
      Start-Sleep 2
      Write-Host '    go' -ForegroundColor Green
      $ev = (& $adb -s $serial shell "timeout 12 getevent -lt $dev" 2>$null) -split "`n" | Where-Object { $_ -match 'REL_WHEEL|REL_HWHEEL|0008|000b' }
      Set-Content (Join-Path $out 'wheel-events.txt') $ev
      $lo = @($ev | Where-Object { $_ -match 'REL_WHEEL\s' -and $_ -notmatch 'HI_RES' })
      $hi = @($ev | Where-Object { $_ -match 'REL_WHEEL_HI_RES' })
      function Val($l) { $h = ($l.Trim() -split '\s+')[-1]; try { [int32][Convert]::ToInt32($h, 16) } catch { 0 } }
      $loVals = $lo | ForEach-Object { Val $_ }; $hiVals = $hi | ForEach-Object { Val $_ }
      Say ("wheel: REL_WHEEL events {0}, values {1}, sum {2}" -f $lo.Count, (($loVals | Select-Object -Unique) -join ','), (($loVals | Measure-Object -Sum).Sum))
      Say ("wheel: REL_WHEEL_HI_RES events {0}, values {1}, sum {2}" -f $hi.Count, (($hiVals | Select-Object -Unique) -join ','), (($hiVals | Measure-Object -Sum).Sum))
      Say 'wheel: Cursorwerx takes one zoom step per 8 units of REL_WHEEL (one Mac click); the sum over 5 clicks should be 40 for the same feel'
    }
  } catch { Say ("FAILED: {0}" -f $_.Exception.Message) }
}
if (-not ($NetTest -or $Wheel)) { try {
# ---- the machine ---------------------------------------------------------------------------
$cs = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Say ("Machine: {0} {1}; {2:N0} MB RAM; {3} logical CPUs; {4} build {5}" -f $cs.Manufacturer, $cs.Model, ($cs.TotalPhysicalMemory / 1MB), $cs.NumberOfLogicalProcessors, $os.Caption, $os.BuildNumber)
Say ("CPU: {0}" -f $cpu.Name.Trim())
$gpus = @(Get-CimInstance Win32_VideoController)
foreach ($g in $gpus) { Say ("GPU: {0}; driver {1}; {2}x{3}" -f $g.Name, $g.DriverVersion, $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution) }
$dpiScale = 1.0
try { $dpiScale = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics').AppliedDPI / 96 } catch {}
Say ("Display scaling: {0}%" -f [int]($dpiScale * 100))

# ---- Google's pieces, checksums as in versions.env -----------------------------------------
function Unzip($zip, $dest) { & tar.exe -xf $zip -C $dest; if ($LASTEXITCODE -ne 0) { throw "could not unpack $zip" } }
function Fetch($url, $dest, $sha1) {
  if (Test-Path $dest) { Say "have $dest"; return }
  Say "downloading $dest"
  & curl.exe -fL -o $dest $url
  if ($LASTEXITCODE -ne 0) { throw "download failed: $url" }
  if ($sha1 -and (Get-FileHash $dest -Algorithm SHA1).Hash -ne $sha1.ToUpper()) { Remove-Item $dest; throw "checksum mismatch: $dest" }
}
if (-not (Test-Path $emu)) {
  Fetch 'https://dl.google.com/android/repository/emulator-windows_x64-15917651.zip' 'emu.zip' '54fa750822ff462d57e04fc8e98e60f08df2bb61'
  Unzip 'emu.zip' '.'
}
Say ("Hypervisor: " + ((& $emu -accel-check 2>$null) -join ' | '))
$sysdir = 'system-images\android-34\google_apis'
if (-not (Test-Path "$sysdir\x86_64\.takwerx-unpacked")) {
  Fetch 'https://dl.google.com/android/repository/sys-img/google_apis/x86_64-34_r14.zip' 'sysimg.zip' 'e0f6c9a0691aa27bd597d0deb1bcfdc943ac8ca7'
  if (Test-Path "$sysdir\x86_64") { Remove-Item "$sysdir\x86_64" -Recurse -Force }
  New-Item -ItemType Directory -Force $sysdir | Out-Null
  Say 'unpacking the Android image (1.5 GB, a minute or two)'
  Unzip 'sysimg.zip' $sysdir
  if (-not (Test-Path "$sysdir\x86_64\system.img")) { throw 'the Android image did not unpack' }
  Set-Content -Path "$sysdir\x86_64\.takwerx-unpacked" -Value 'ok'
}
if (-not (Test-Path $adb)) {
  Fetch 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' 'pt.zip' $null
  Unzip 'pt.zip' '.'
}
# Which GPU Windows hands the emulator (a per-user setting, the same one as Settings > Display >
# Graphics). 2 = high performance (the NVIDIA), 1 = power saving (the Intel), none = Windows decides.
$qemuExe = Join-Path $root 'emulator\qemu\windows-x86_64\qemu-system-x86_64.exe'
$prefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
if ($Gpu -ne 'auto') {
  New-Item -Path $prefKey -Force | Out-Null
  New-ItemProperty -Path $prefKey -Name $qemuExe -Value $(if ($Gpu -eq 'nvidia') { 'GpuPreference=2;' } else { 'GpuPreference=1;' }) -PropertyType String -Force | Out-Null
  Say ("GPU preference for the emulator: {0}" -f $Gpu)
} else {
  Remove-ItemProperty -Path $prefKey -Name $qemuExe -ErrorAction SilentlyContinue
  Say 'GPU preference for the emulator: Windows decides'
}
# The Windows preference above steers OpenGL and DirectX only. On ANGLE the emulator renders
# through Vulkan and picks the Vulkan device itself (the discrete one by default); this is its
# own switch, matched against the device name. Read at start, so it needs a fresh boot.
if ($Gpu -eq 'intel') { $env:ANDROID_EMU_VK_SELECT_GPU = 'Intel' }
elseif ($Gpu -eq 'nvidia') { $env:ANDROID_EMU_VK_SELECT_GPU = 'NVIDIA' }
else { Remove-Item Env:ANDROID_EMU_VK_SELECT_GPU -ErrorAction SilentlyContinue }

# ---- the AVD, written by hand as on the Mac (lib/emulator.sh emu_avd_create) ----------------
$avdDir = Join-Path $env:ANDROID_AVD_HOME 'atak.avd'
New-Item -ItemType Directory -Force $avdDir | Out-Null
$ram = [math]::Min(8192, [math]::Max(4096, [int]($cs.TotalPhysicalMemory / 1MB / 3)))
$cores = [math]::Min(4, [math]::Max(2, [int]($cs.NumberOfLogicalProcessors / 2)))
$g0 = $gpus | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
$w = [int]$g0.CurrentHorizontalResolution - [int](80 * $dpiScale); $h = [int]$g0.CurrentVerticalResolution - [int](120 * $dpiScale)
$w -= $w % 2; $h -= $h % 2
$dpi = [int][math]::Round(200 * $dpiScale); $density = [int]($dpi * 3 / 4)
Say ("AVD: {0}x{1} at density {2} (ui dpi {3}), {4} MB, {5} cores" -f $w, $h, $density, $dpi, $ram, $cores)
$ini = @"
AvdId=atak
avd.ini.displayname=TAKwerx ATAK Terminal
avd.ini.encoding=UTF-8
PlayStore.enabled=no
abi.type=x86_64
disk.dataPartition.size=10G
fastboot.forceColdBoot=yes
fastboot.forceFastBoot=no
hw.accelerometer=yes
hw.arc=false
hw.audioInput=yes
hw.audioOutput=yes
hw.battery=yes
hw.camera.back=none
hw.camera.front=none
hw.cpu.arch=x86_64
hw.cpu.ncore=$cores
hw.dPad=no
hw.gps=yes
hw.gpu.enabled=yes
hw.gpu.mode=host
hw.gsmModem=yes
hw.gyroscope=yes
hw.initialOrientation=landscape
hw.keyboard=yes
hw.keyboard.charmap=qwerty2
hw.keyboard.lid=yes
hw.lcd.backlight=yes
hw.lcd.density=$density
hw.lcd.depth=32
hw.lcd.height=$h
hw.lcd.vsync=60
hw.lcd.width=$w
hw.mainKeys=no
hw.ramSize=$ram
hw.screen=multi-touch
hw.sdCard=no
hw.sensors.magnetic_field=yes
hw.sensors.orientation=yes
hw.sensors.proximity=no
hw.trackBall=no
hw.useext4=yes
image.sysdir.1=system-images/android-34/google_apis/x86_64/
kernel.newDeviceNaming=autodetect
kernel.supportsYaffs2=autodetect
showDeviceFrame=no
skin.dynamic=yes
tag.display=Google APIs
tag.id=google_apis
target=android-34
vm.heapSize=256M
"@
Set-Content -Path (Join-Path $avdDir 'config.ini') -Value $ini -Encoding ASCII
Set-Content -Path (Join-Path $env:ANDROID_AVD_HOME 'atak.ini') -Value "avd.ini.encoding=UTF-8`npath=$avdDir`npath.rel=avd\atak.avd`ntarget=android-34" -Encoding ASCII

# ---- start ----------------------------------------------------------------------------------
& $adb start-server 2>$null | Out-Null
# Running means an emulator process and a booted Android, not one still shutting down.
$running = [bool](EmuProcs) -and ((& $adb -s $serial shell getprop sys.boot_completed 2>$null) -join '').Trim() -eq '1'
if ((EmuProcs) -and -not $running) {
  Write-Host 'An emulator is still shutting down; waiting for it...'
  for ($i = 0; $i -lt 45 -and (EmuProcs); $i++) { Start-Sleep 1 }
  if (EmuProcs) { EmuProcs | Stop-Process -Force; Start-Sleep 2 }
}
if ($running) {
  Say 'Android is already running; using it (run .\measure.ps1 -Stop first for a fresh boot)'
} else {
  # Stale locks from a previous run; on Windows the emulator's locks are folders, hence -Recurse.
  Get-ChildItem $avdDir -Filter '*.lock' -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
  # -WiFiPacketStream: Android's Wi-Fi on the emulator's own network stack, not streamed to netsim
  # (on the Mac a small request went from about 800 ms to 41 ms; DECISIONS 2026-09-27).
  $features = 'VirtioTablet,-WiFiPacketStream'; if ($Mode -eq 'angle') { $features = 'Vulkan,GuestAngle,VirtioTablet,-WiFiPacketStream' }
  $emuArgs = @('-avd', 'atak', '-port', '5574', '-gpu', 'host', '-feature', $features, '-no-snapshot', '-no-boot-anim')
  Say ("starting: emulator {0}" -f ($emuArgs -join ' '))
  $t0 = Get-Date
  $proc = Start-Process -FilePath $emu -ArgumentList $emuArgs -WorkingDirectory $root -PassThru `
    -RedirectStandardOutput (Join-Path $root 'emulator.log') -RedirectStandardError (Join-Path $root 'emulator.err')
  $deadline = (Get-Date).AddMinutes(6); $booted = $false
  while ((Get-Date) -lt $deadline) {
    if ((AdbOut shell getprop sys.boot_completed).Trim() -eq '1') { $booted = $true; break }
    if ($proc.HasExited) { break }
    Start-Sleep 3
  }
  if (-not $booted) { Say 'Android did not boot within 6 minutes (or the emulator exited). See emulator.log / emulator.err in the results.'; $skip = $true }
  else { Say ("Android booted in {0} s" -f [int]((Get-Date) - $t0).TotalSeconds) }
  Get-Content (Join-Path $root 'emulator.log') -ErrorAction SilentlyContinue |
    Where-Object { $_ -match 'ANDROID_EMU_VK_SELECT_GPU|Physical device \[|Selecting GPU|Selecting Vulkan device|Could not select the GPU' } |
    ForEach-Object { Say ("emulator: " + $_.Trim()) }
}

if (-not $skip) {
  # ---- what the guest draws with --------------------------------------------------------
  Say ("GLES: " + ((AdbOut shell dumpsys SurfaceFlinger) -split "`n" | Select-String 'GLES:' | Select-Object -First 1))
  foreach ($p in 'ro.hardware.egl', 'ro.hardware.vulkan', 'ro.boot.qemu.gltransport.name', 'ro.kernel.qemu.gles', 'ro.boot.hardware.gltransport') {
    $v = (AdbOut shell getprop $p).Trim(); if ($v) { Say ("{0} = {1}" -f $p, $v) }
  }
  # ---- the settings that carry over from the Mac (emu_provision), the safe subset --------
  $rooted = ((AdbOut root) -match 'restarting|already running as root')
  Start-Sleep 3
  Say ("adb root: {0}" -f $(if ($rooted) { 'yes' } else { 'no' }))
  if ($AngleOverride -and $rooted) { AdbOut shell setprop debug.angle.feature_overrides_disabled warmUpPipelineCacheAtLink | Out-Null; Say 'ANGLE pipeline warm-up switched off' }
  AdbOut shell settings put system screen_off_timeout 2147483647 | Out-Null
  AdbOut shell svc power stayon true | Out-Null
  AdbOut shell settings put secure stylus_handwriting_enabled 0 | Out-Null
  AdbOut shell cmd uimode night yes | Out-Null
  AdbOut shell wm density $dpi | Out-Null
  # The emulator's own GPS, which ATAK takes as a real provider; not kept across boots.
  if ($Location -match '^\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*$') {
    AdbOut emu geo fix $Matches[2] $Matches[1] | Out-Null
    Say ("position sent to Android: {0}" -f $Location)
  }
  if ($AtakTweaks) { AdbOut shell 'mkdir -p /sdcard/atak && touch /sdcard/atak/opengl.broken && (grep -q use-pbo-cull /sdcard/atak/devopts.properties 2>/dev/null || echo mapengine.glmapview.use-pbo-cull=0 >> /sdcard/atak/devopts.properties)' | Out-Null; Say 'ATAK tweaks applied (opengl.broken, CPU terrain cull)' }

  # ---- ATAK from Downloads, or from the Mac on the switch ---------------------------------
  $installed = (AdbOut shell pm list packages $pkg) -match $pkg
  if (-not $installed) {
    $apk = Get-ChildItem (Join-Path $env:USERPROFILE 'Downloads\*.apk') -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '(?i)^atak-(civ-)?(\d+(\.\d+)+)' -and $_.Name -match '(?i)civ' -and $_.Name -notmatch '(?i)plugin' } |
      Sort-Object { [version]([regex]::Match($_.Name, '(?i)^atak-(?:civ-)?(\d+(?:\.\d+)+)').Groups[1].Value) } -Descending | Select-Object -First 1
    Say ("APKs in Downloads: {0}" -f ((Get-ChildItem (Join-Path $env:USERPROFILE 'Downloads\*.apk') -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '))
    if ($apk) { $apkPath = $apk.FullName } else {
      $apkPath = Join-Path $root 'ATAK.apk'
      if (-not (Test-Path $apkPath)) { Say 'no ATAK APK in Downloads; fetching it from the Mac'; & curl.exe -fL -o $apkPath "http://$Mac/ATAK.apk" }
    }
    Say ("installing {0}" -f (Split-Path $apkPath -Leaf))
    $r = (& $adb -s $serial install -r -g $apkPath 2>&1) -join ' '
    Say ("install: {0}" -f $r.Trim())
  } else { Say 'ATAK is already installed' }
  Say ("ATAK version installed: {0}" -f (((AdbOut shell dumpsys package $pkg) -split "`n" | Select-String 'versionName' | Select-Object -First 1) -replace '\s+', ' ').Trim())
  $act = ((AdbOut shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $pkg) -split "`n" | Select-Object -Last 1).Trim()
  Say ("launching {0}" -f $act)
  Say ("am start: " + (((AdbOut shell am start -W -n $act) -split "`n" | Where-Object { $_ -match 'Status|Error|Warning|TotalTime' }) -join '; '))
  Start-Sleep 20
  if ((AdbOut shell pidof $pkg).Trim()) {
    Say 'ATAK is running.'
    # The TAKWERX Market, as on the Mac (takwerx market_install): the latest release carries one
    # APK per ATAK version line; installed while ATAK runs, ATAK registers it and offers to load it.
    $atakVer = [regex]::Match((AdbOut shell dumpsys package $pkg), 'versionName=(\d+\.\d+\.\d+)').Groups[1].Value
    if (-not ((AdbOut shell pm list packages) -match 'takwerxmarket')) {
      try {
        $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/takwerx/takwerx-market/releases/latest' -TimeoutSec 20
        $asset = $rel.assets | Where-Object { $_.name -match ('--' + [regex]::Escape($atakVer) + '-civ-release\.apk$') } | Select-Object -First 1
        if ($asset) {
          $mapk = Join-Path $root $asset.name
          if (-not (Test-Path $mapk)) { & curl.exe -fsSL -o $mapk $asset.browser_download_url }
          $r = (& $adb -s $serial install -r -g $mapk 2>&1) -join ' '
          Say ("Market {0} for ATAK {1}: {2}" -f $asset.name, $atakVer, $r.Trim())
        } else { Say ("no Market build for ATAK {0} in release {1}" -f $atakVer, $rel.tag_name) }
      } catch { Say ("Market: could not fetch the release ({0})" -f $_.Exception.Message) }
    } else { Say 'Market is already installed' }
  } else {
    Say 'ATAK is NOT running 20 s after launch. What the log says about it:'
    (AdbOut logcat -d) -split "`n" | Where-Object { $_ -match '(?i)atak|AndroidRuntime|DEBUG|am_proc_died|am_kill|died|Fatal' } | Select-Object -Last 30 | ForEach-Object { Say ("  " + $_) }
  }
  Write-Host ''
  Write-Host '>>> Over to you: go through ATAK''s first-run screens, then pan and zoom the map continuously.' -ForegroundColor Yellow
  Write-Host '>>> In 90 s the script takes over the map for 40 s and samples the frame rate three times.' -ForegroundColor Yellow
  Write-Host ''
  AdbOut shell dumpsys SurfaceFlinger --timestats -enable | Out-Null
  AdbOut shell dumpsys SurfaceFlinger --timestats -clear | Out-Null
  for ($i = 90; $i -gt 0; $i -= 10) { Write-Host ("    sampling in {0} s" -f $i); Start-Sleep 10 }

  # ---- frame rate from SurfaceFlinger's per-layer frame counters (timestats) --------------------
  # Enabled when the countdown starts (further up); each dump lists every layer with its
  # totalFrames, and the map is ATAK's SurfaceView (BLAST) layer. Frames between two dumps over
  # the seconds between them is the rate. The raw dumps are kept for reading later.
  function MapFrames {
    $dump = (AdbOut shell dumpsys SurfaceFlinger --timestats -dump) -split "`n"
    $name = ''; $count = $null; $seen = ''; $avg = $null
    foreach ($line in $dump) {
      if ($line -match '^\s*layerName\s*=\s*(.*)$') { $name = $Matches[1].Trim(); continue }
      if ($line -match '^\s*averageFPS\s*=\s*([\d.]+)') { $a = [double]$Matches[1]; if ($name -eq $seen) { $avg = $a } }
      if ($line -match '^\s*totalFrames\s*=\s*(\d+)') {
        $c = [int64]$Matches[1]
        if ($name -match [regex]::Escape($pkg) -and $name -match 'SurfaceView' -and $name -notmatch 'Background') {
          if ($count -eq $null -or $c -gt $count) { $count = $c; $seen = $name }
        }
      }
    }
    return New-Object PSObject -Property @{ Frames = $count; Layer = $seen; Avg = $avg; At = (Get-Date); Raw = ($dump -join "`n") }
  }
  $prev = MapFrames
  $prev.Raw | Set-Content (Join-Path $out 'timestats-0.txt')
  $layerNow = ((AdbOut shell dumpsys SurfaceFlinger --list) -split "`n" | Where-Object { $_ -match $pkg -and $_ -match 'BLAST' } | Select-Object -First 1)
  if ($layerNow) { (AdbOut shell dumpsys SurfaceFlinger --latency $layerNow.Trim()) | Set-Content (Join-Path $out 'latency-raw.txt') }
  # Continuous panning per window, driven from here, so the number does not depend on whose
  # hand is on the mouse: three 3-second drags across the map, alternating direction, so the
  # map is in motion for nine of every eleven seconds.
  function PanMap {
    $cx = [int]($w * 0.45); $cy = [int]($h * 0.5); $d = [int]($w * 0.25)
    foreach ($k in 0, 1, 2) {
      $dx = @(1, -1, 1)[$k] * $d; $dy = @(1, -1, 0)[$k] * [int]($d / 3)
      & $adb -s $serial shell input swipe ($cx - [int]($dx / 2)) ($cy - [int]($dy / 2)) ($cx + [int]($dx / 2)) ($cy + [int]($dy / 2)) 3000 2>$null | Out-Null
    }
  }
  Write-Host '    the script pans the map now; hands off the mouse for 40 s' -ForegroundColor Yellow
  for ($n = 1; $n -le 3; $n++) {
    PanMap
    $cur = MapFrames
    if ($cur.Frames -ne $null -and $prev.Frames -ne $null) {
      $sec = ($cur.At - $prev.At).TotalSeconds
      Say ("frames {0}: {1:N1} fps ({2} frames in {3:N1} s; SurfaceFlinger's own average since the countdown {4}; layer {5})" -f $n, (($cur.Frames - $prev.Frames) / $sec), ($cur.Frames - $prev.Frames), $sec, $cur.Avg, $cur.Layer)
    } else { Say ("frames {0}: no map layer in timestats (raw dump kept)" -f $n) }
    $cur.Raw | Set-Content (Join-Path $out ("timestats-{0}.txt" -f $n))
    $prev = $cur
    AdbOut shell screencap -p /sdcard/takwerx-shot.png | Out-Null
    & $adb -s $serial pull /sdcard/takwerx-shot.png (Join-Path $out ("shot-{0}.png" -f $n)) 2>$null | Out-Null
  }
  Say ("ATAK memory: " + (((AdbOut shell dumpsys meminfo $pkg) -split "`n" | Select-String 'TOTAL PSS|TOTAL:' | Select-Object -First 1)))
  (AdbOut logcat -d) | Set-Content (Join-Path $out 'logcat.txt')
  (AdbOut logcat -d -b events) | Set-Content (Join-Path $out 'events.txt')
  (AdbOut logcat -d -b crash) | Set-Content (Join-Path $out 'crash.txt')
  # ATAK keeps its own logs under atak/support/logs; the newest two cover more than the buffer does.
  $atakLogs = (AdbOut shell ls -t /sdcard/atak/support/logs) -split "`n" | Where-Object { $_ -match '\.txt$' } | Select-Object -First 2
  foreach ($f in $atakLogs) { & $adb -s $serial pull "/sdcard/atak/support/logs/$($f.Trim())" (Join-Path $out ("atak-" + $f.Trim())) 2>$null | Out-Null }
  (AdbOut shell "cat /data/data/$pkg/shared_prefs/${pkg}_preferences.xml 2>/dev/null | grep -i shouldLoad") | Set-Content (Join-Path $out 'shouldload.txt')
  (AdbOut shell pm list packages -f) -split "`n" | Where-Object { $_ -match 'atakmap' } | Set-Content (Join-Path $out 'packages.txt')
  (AdbOut shell dumpsys SurfaceFlinger) | Set-Content (Join-Path $out 'surfaceflinger.txt')
  Copy-Item (Join-Path $avdDir 'config.ini') $out -ErrorAction SilentlyContinue
}
} catch { Say ("FAILED: {0}" -f $_.Exception.Message) } }

# ---- ship the results to the Mac ------------------------------------------------------------
foreach ($f in 'emulator.log', 'emulator.err') { try { Get-Content -Raw (Join-Path $root $f) -ErrorAction Stop | Set-Content (Join-Path $out $f) } catch {} }
& curl.exe -fsS -T $log ("http://{0}/upload/{1}-measure.txt" -f $Mac, (Split-Path $out -Leaf))
$zip = "$out.zip"
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -Force
& curl.exe -fsS -T $zip ("http://{0}/upload/{1}" -f $Mac, (Split-Path $zip -Leaf))
if ($LASTEXITCODE -eq 0) { Say ("results sent to the Mac: {0}" -f (Split-Path $zip -Leaf)) } else { Say ("could not send the results; the zip is at {0}" -f $zip) }
Write-Host ''
Write-Host 'Done. Android stays running; keep using ATAK. .\measure.ps1 -Stop powers it off.' -ForegroundColor Green
