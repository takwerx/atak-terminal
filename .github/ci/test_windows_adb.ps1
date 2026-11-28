# Proof test for the Windows wait for Android (ops #1436). On a Windows 11 cloud PC with no GPU,
# `takwerx up` printed "Waiting for Android to boot" for 30 minutes: one `adb shell getprop
# sys.boot_completed` never returned, and Wait-Emu checks its 5 minutes only between calls.
# This loads the REAL Test-AndroidOnline, Test-AndroidBooted and Wait-Emu from the repo and runs
# them against a fake adb that answers, answers slowly, or never answers. Nothing runs on a PC.
#   pwsh -File .github/ci/test_windows_adb.ps1      (Linux or Mac; the fake adb is a shell script)
$ErrorActionPreference = 'Stop'
Set-Location (git rev-parse --show-toplevel)
$fail = 0
function Check([string]$name, $got, $want) {
    if ("$got" -ceq "$want") { Write-Host "ok   $name" } else { Write-Host "::error::FAIL $name : got '$got', want '$want'"; $script:fail++ }
}
# A function's text, straight from the file the product loads: the test runs the shipped code.
function Get-FunctionText([string]$file, [string]$name) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file).Path, [ref]$tokens, [ref]$errs)
    $f = $ast.Find({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $name) }, $true)
    if ($f) { return $f.Extent.Text }
    return ''
}
foreach ($n in 'Quote-Arg', 'Invoke-Quiet', 'Invoke-Limited') {
    $t = Get-FunctionText 'lib/windows/common.ps1' $n
    if ($t) { Invoke-Expression $t }
}
$t = Get-FunctionText 'lib/windows/emulator.ps1' 'Wait-Emu'
if (-not $t) { throw 'Wait-Emu is not in lib/windows/emulator.ps1' }
Invoke-Expression $t

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("takwerx-adb-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:Tools = $tmp
$script:State = $tmp
. ./lib/windows/android.ps1

# The fake adb: get-state answers at once; getprop answers, answers after 2 s, or never (mode).
# It writes its own process id first, then becomes `sleep`, so the id is the one that must go.
$pids = Join-Path $tmp 'pids.txt'
$fake = Join-Path $tmp 'adb'
[System.IO.File]::WriteAllText($fake, @'
#!/bin/sh
echo $$ >> "$FAKE_ADB_PIDS"
case "$*" in
  *get-state*) echo device ;;
  *getprop*)
    case "$FAKE_ADB_MODE" in
      hang) exec sleep 40 ;;
      slow) sleep 2; echo 1 ;;
      *) echo 1 ;;
    esac ;;
esac
'@.Replace("`r`n", "`n"))
chmod +x $fake
$script:Adb = $fake
$script:Serial = 'emulator-5574'
$env:FAKE_ADB_PIDS = $pids
$script:logLines = @()
function Log([string]$m) { $script:logLines += $m }
function Start-AdbServer { }
function Start-Watcher { return $true }
function Test-EmuSoftwareGpu { return $false }
function Get-EmuProcess { return $null }
function Test-EmuRunning { return $true }
function Stop-SoftwareGpu([string]$n) { }
function Get-HostGpus { return @() }
function Time-It([scriptblock]$b) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $b
    $sw.Stop()
    return @($r, $sw.Elapsed.TotalSeconds)
}

try {
    # Answers: nothing changes for a PC where adb is healthy.
    $env:FAKE_ADB_MODE = 'ok'
    Check 'get-state device is online'            (Test-AndroidOnline) 'True'
    Check 'getprop 1 is booted'                   (Test-AndroidBooted) 'True'
    $env:FAKE_ADB_MODE = 'slow'
    Check 'a probe that answers after 2 s is still booted' (Test-AndroidBooted) 'True'

    # One adb call that never answers: "not up yet" within the limit, and the adb is gone.
    $env:FAKE_ADB_MODE = 'hang'
    Remove-Item $pids -ErrorAction SilentlyContinue
    $r = Time-It { Test-AndroidBooted 3 }
    Check 'a blocked getprop counts as not booted' $r[0] 'False'
    Check 'a blocked getprop returns within its limit (3 s, under 12 s)' ($r[1] -lt 12) 'True'
    $last = @(Get-Content $pids)[-1]
    Check 'the blocked adb process was stopped' ([bool](Get-Process -Id ([int]$last) -ErrorAction SilentlyContinue)) 'False'

    # The wait itself: its 5 minutes (here 6 s) hold even when getprop never returns.
    $script:logLines = @()
    $r = Time-It { Wait-Emu 6 }
    Check 'Wait-Emu gives up false when getprop never answers' $r[0] 'False'
    Check 'Wait-Emu ends near its own limit (6 s, under 20 s)' ($r[1] -lt 20) 'True'
    Check 'the log says adb gave no answer' ((@($script:logLines) -join '|') -like '*adb gave no answer*') 'True'
    $env:FAKE_ADB_MODE = 'ok'
    $r = Time-It { Wait-Emu 6 }
    Check 'Wait-Emu returns true when Android is up' $r[0] 'True'
    Check 'Wait-Emu returns at once when Android is up (under 6 s)' ($r[1] -lt 6) 'True'
    $env:FAKE_ADB_MODE = 'slow'
    $r = Time-It { Wait-Emu 20 }
    Check 'Wait-Emu waits through a slow answer' $r[0] 'True'

    # No adb at all: no answer, no error.
    $script:Adb = Join-Path $tmp 'not-there'
    Check 'no adb: not online'                    (Test-AndroidOnline) 'False'
    Check 'no adb: not booted'                    (Test-AndroidBooted) 'False'
    $script:Adb = $fake

    # The helper itself: arguments with spaces arrive whole, the exit code is kept.
    if (Get-Command Invoke-Limited -ErrorAction SilentlyContinue) {
        $o = Invoke-Limited 5 '/bin/echo' @('a b', 'c')
        Check 'Invoke-Limited passes an argument with a space' $o 'a b c'
        [void](Invoke-Limited 5 '/bin/sh' @('-c', 'exit 3'))
        Check 'Invoke-Limited keeps the exit code' $global:LASTEXITCODE 3
    } else {
        Check 'Invoke-Limited exists in lib/windows/common.ps1' 'no' 'yes'
    }
} finally {
    if (Test-Path $pids) { foreach ($x in @(Get-Content $pids)) { Stop-Process -Id ([int]$x) -Force -ErrorAction SilentlyContinue } }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($fail) { Write-Host "$fail check(s) failed"; exit 1 }
Write-Host 'all checks passed'
