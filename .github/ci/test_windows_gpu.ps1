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

if ($fail) { Write-Host "$fail check(s) failed"; exit 1 }
Write-Host 'all checks passed'
