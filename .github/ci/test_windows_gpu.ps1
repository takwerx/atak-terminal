# Proof test for the Windows GPU choice (ops #590, atak-terminal #19). Loads lib/windows/gpu.ps1
# alone and runs its pure functions on the PC from the report: an NVIDIA NVS 510 (driver 475.14)
# beside an Intel UHD 630, and the emulator log that came back. Nothing is run on a PC.
#   pwsh -File .github/ci/test_windows_gpu.ps1
$ErrorActionPreference = 'Stop'
Set-Location (git rev-parse --show-toplevel)
. ./lib/windows/gpu.ps1
$fail = 0
function Check([string]$name, $got, $want) {
    if ("$got" -ceq "$want") { Write-Host "ok   $name" } else { Write-Host "::error::FAIL $name : got '$got', want '$want'"; $script:fail++ }
}
$nvs   = @('NVIDIA NVS 510', '10de:0ffd', '30.0.14.7514')
$uhd   = @('Intel(R) UHD Graphics 630', '8086:3e92', '31.0.101.2135')
$newNv = @('NVIDIA RTX 2000 Ada Generation', '10de:28b0', '32.0.15.9671')
$arc   = @('Intel(R) Arc(TM) Pro Graphics', '8086:7d55', '32.0.101.6078')
$amd   = @('AMD Radeon RX 6600', '1002:73ff', '31.0.21.1000')
$basic = @('Microsoft Basic Display Adapter', '', '10.0.26100.1')
$soft  = @('8086:3e92')

Check 'driver 30.0.14.7514 is 475.14'  (ConvertTo-NvidiaDriver '30.0.14.7514') '475.14'
Check 'driver 31.0.15.5586 is 555.86'  (ConvertTo-NvidiaDriver '31.0.15.5586') '555.86'
Check 'driver 32.0.15.9671 is 596.71'  (ConvertTo-NvidiaDriver '32.0.15.9671') '596.71'
Check 'driver 27.21.14.5671 is 456.71' (ConvertTo-NvidiaDriver '27.21.14.5671') '456.71'
Check 'driver text with no shape is empty' (ConvertTo-NvidiaDriver 'unknown') ''

Check 'reporter PC: NVS 510 + UHD 630 steers to Intel' (Get-GpuSteer @($nvs, $uhd)) 'Intel'
Check 'order does not matter'                           (Get-GpuSteer @($uhd, $nvs)) 'Intel'
Check 'old NVIDIA + AMD steers to AMD'                  (Get-GpuSteer @($nvs, $amd)) 'AMD'
Check 'old NVIDIA alone: nothing to steer to'           (Get-GpuSteer @(,$nvs)) ''
Check 'old NVIDIA + a chip drawn on the processor'      (Get-GpuSteer @($nvs, $uhd) $soft) ''
Check 'old NVIDIA + basic display: nothing to steer to' (Get-GpuSteer @($nvs, $basic)) ''
Check 'current NVIDIA + Intel: left to the emulator'    (Get-GpuSteer @($newNv, $arc)) ''
Check 'Intel alone: left to the emulator'               (Get-GpuSteer @(,$uhd)) ''
Check 'no GPUs found: left to the emulator'             (Get-GpuSteer @()) ''
Check 'driver unreadable: left to the emulator'         (Get-GpuSteer @(@('NVIDIA NVS 510', '10de:0ffd', ''), $uhd)) ''

$log = "INFO         |   Checking: hasSufficientHwGpu`r`nINFO         |      Error: GPU driver is not supported to run avd: ``terminal``. Your ``NVIDIA NVS 510`` GPU has Vulkan API version ``1.2.175``, driver version ``475.14.0`` and is not supported for Vulkan. Minimum driver version required: ``553.35.0``.`r`nFATAL        | GPU driver is not supported to run avd: ``terminal``. Your ``NVIDIA NVS 510`` GPU has Vulkan API version ``1.2.175``, driver version ``475.14.0`` and is not supported for Vulkan. Minimum driver version required: ``553.35.0``..`r`n"
$r = Get-GpuRefusal $log
Check 'refusal found in the emulator log' ($r -like 'GPU driver is not supported to run avd*475.14.0*553.35.0*') 'True'
Check 'refusal has no log prefix or CR'   ($r -match '[\r\n|]') 'False'
Check 'a clean log has no refusal'        (Get-GpuRefusal "INFO | Graphics backend: gfxstream`r`nINFO | boot completed") ''

# A PC with no usable graphics at all (ops #1436): a Windows 11 cloud PC with no GPU (Azure, Windows 11
# 24H2, 4 vCPU, 2026-11-27). The emulator's standard output, as it came back, ends Android's boot.
$gone = 'Could not detect GPU for Vulkan compatibility checks'
$noGpuLog = "ERROR        | emuglConfig_get_vulkan_hardware_gpu_support_info: Failed to create vulkan instance. Error: [VK_ERROR_INCOMPATIBLE_DRIVER] -9`r`nINFO         |      Error: Could not detect GPU for Vulkan compatibility checks. Please try updating your GPU Drivers`r`nFATAL        | Could not detect GPU for Vulkan compatibility checks. Please try updating your GPU Drivers.`r`n"
Check 'no-GPU log from the real PC'    (Get-GpuMissing $noGpuLog) $gone
Check 'no-GPU line, bare'              (Get-GpuMissing $gone) $gone
Check 'no-GPU line, with a log prefix' (Get-GpuMissing "INFO         |   Checking: hasSufficientHwGpu`r`nWARNING      | $gone`r`nINFO | next") $gone
Check 'a clean log is not no-GPU'      (Get-GpuMissing "INFO | Graphics backend: gfxstream`r`nINFO | boot completed") ''
Check 'the old-driver refusal is not no-GPU' (Get-GpuMissing $log) ''
Check 'no-GPU is not an old-driver refusal'  (Get-GpuRefusal $gone) ''

# What the person reads when Android does not come up: the real Invoke-EmuUp, from the file the
# product loads, with the PC and the emulator log stood in. Old-driver refusal first, then no GPU,
# then the generic line.
function Get-FunctionText([string]$file, [string]$name) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file).Path, [ref]$tokens, [ref]$errs)
    $f = $ast.Find({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $name) }, $true)
    if ($f) { return $f.Extent.Text }
    return ''
}
$t = Get-FunctionText 'lib/windows/emulator.ps1' 'Invoke-EmuUp'
if (-not $t) { throw 'Invoke-EmuUp is not in lib/windows/emulator.ps1' }
Invoke-Expression $t
$script:AvdHome = Join-Path ([System.IO.Path]::GetTempPath()) 'takwerx-no-avd'
$script:Avd = 'terminal'
$script:V = @{ SYSIMG_API = '35' }
$script:EmuLog = 'C:\takwerx\emulator.log'
$script:FixtureLog = ''
function Start-Emu { }
function Step([string]$m) { }
function Test-AndroidOnline { return $false }
function Test-AndroidBooted { return $false }
function Wait-Emu([int]$s) { return $false }
function Read-EmuLog { return $script:FixtureLog }
function Die([string]$m) { throw $m }
function Say-Up([string]$logText) {
    $script:FixtureLog = $logText
    try { Invoke-EmuUp; return 'no error' } catch { return $_.Exception.Message }
}
$m = Say-Up $noGpuLog
Check 'no GPU: the message names the missing graphics chip'  ($m -like '*no graphics chip it can use*') 'True'
Check 'no GPU: the message quotes the emulator line'         ($m -like "*$gone*") 'True'
Check 'no GPU: the message points to the log'                ($m -like '*emulator.log*') 'True'
Check 'no GPU: not the generic line'                         ($m -like 'Android did not come up*') 'False'
$m = Say-Up $log
Check 'old driver: still its own message'                    ($m -like '*refused this PC*graphics driver*') 'True'
$m = Say-Up ($noGpuLog + $log)
Check 'old driver beside the no-GPU line: the refusal wins'  ($m -like '*refused this PC*graphics driver*') 'True'
$m = Say-Up "INFO | Graphics backend: gfxstream"
Check 'neither: the generic line stays'                      ($m -like 'Android did not come up*') 'True'

if ($fail) { Write-Host "$fail check(s) failed"; exit 1 }
Write-Host 'all checks passed'
