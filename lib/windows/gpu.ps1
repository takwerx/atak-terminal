# takwerx for Windows: which graphics chip the emulator draws on. Pure functions (no PC state,
# no logging), so .github/ci/test_windows_gpu.ps1 can load this file alone.
#
# The emulator refuses an NVIDIA driver older than 553.35 for Vulkan and exits at once:
#   "GPU driver is not supported to run avd: `terminal`. Your `NVIDIA NVS 510` GPU has Vulkan
#   API version `1.2.175`, driver version `475.14.0` and is not supported for Vulkan. Minimum
#   driver version required: `553.35.0`."
# (ops #590, atak-terminal #19: an NVS 510 beside an Intel UHD 630; Kepler cards stop at 475,
# so no driver update lifts it). By default the emulator draws on the discrete chip, so a PC
# with a second chip is steered to that one (EMU_GPU, ANDROID_EMU_VK_SELECT_GPU).
$script:MinNvidiaDriver = [version]'553.35'

# Windows reports an NVIDIA driver as 30.0.14.7514; NVIDIA's own number is the last five
# digits of the last two parts, 475.14. '' when the text is not that shape.
function ConvertTo-NvidiaDriver([string]$winVersion) {
    if ("$winVersion" -notmatch '^\d+\.\d+\.(\d+)\.(\d+)$') { return '' }
    $d = ($Matches[1] + $Matches[2]).PadLeft(5, '0')
    $d = $d.Substring($d.Length - 5)
    return ('{0}.{1}' -f [int]$d.Substring(0, 3), $d.Substring(3))
}

# $gpus: what Get-HostGpus returns, @(name, "vendor:device" ('' for a virtual display), Windows'
# driver version) each. Returns the word to give the emulator, 'Intel' or 'AMD', when an NVIDIA
# chip with a driver the emulator refuses is there and another real chip can take over;
# '' when nothing needs steering. $skip: PCI ids the emulator draws on the processor for.
function Get-GpuSteer($gpus, [string[]]$skip = @()) {
    $old = $false; $other = ''
    foreach ($g in @($gpus)) {
        if ("$($g[0])" -match 'Microsoft|Remote|Virtual|Basic') { continue }
        if ("$($g[1])" -like '10de:*') {
            $v = ConvertTo-NvidiaDriver "$($g[2])"
            if ($v -and ([version]$v) -lt $script:MinNvidiaDriver) { $old = $true }
        } elseif ($skip -notcontains "$($g[1])") {
            if ("$($g[1])" -like '8086:*' -and -not $other) { $other = 'Intel' }
            elseif ("$($g[1])" -like '1002:*' -and -not $other) { $other = 'AMD' }
        }
    }
    if ($old) { return $other }
    return ''
}

# The emulator's own refusal of a driver, from its log: the sentence, or ''.
function Get-GpuRefusal([string]$logText) {
    if ("$logText" -match '(?m)GPU driver is not supported to run avd[^\r\n]*') { return $Matches[0].TrimEnd('.', ' ') }
    return ''
}
