# Proof test for ops #1425: on Windows, `takwerx update` and `takwerx restart` must not wait for ever
# when the emulator process is frozen and `adb emu kill` never answers. Twin of
# t_stop_frozen in .github/ci/test_update_edges.sh (ops #1423, the Mac and Linux engine).
#   1. Invoke-Timed (lib/windows/timed.ps1) on its own: a program that finishes, one that hangs,
#      one that is missing, an argument with a space, a program with a lot of output.
#   2. The real Stop-Emu, Adb and Invoke-Quiet (pulled out of lib/windows/ by the parser, nothing
#      else of those files runs) against a stand-in adb that hangs on `emu kill` and a stand-in
#      emulator process: Stop-Emu must come back in seconds and the emulator process must be gone.
#      Red on the base branch (it waits the stand-in's full 30 s), green with the fix.
# Runs on the hosted Linux runner under pwsh; nothing touches a PC.
#   pwsh -File .github/ci/test_windows_timed.ps1
$ErrorActionPreference = 'Stop'
Set-Location (git rev-parse --show-toplevel)
$root = (Get-Location).Path
$fail = 0
function Check([string]$name, [bool]$ok, [string]$why) {
    if ($ok) { Write-Host "ok   $name" } else { Write-Host "::error::FAIL $name : $why"; $script:fail++ }
}
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("takwerx-timed-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$self = (Get-Process -Id $PID).Path   # pwsh itself: a stand-in program that exists on every host

# --- 1. Invoke-Timed on its own -------------------------------------------------------------------
. ./lib/windows/timed.ps1

$t = Get-Date
$r = Invoke-Timed $self @('-NoProfile', '-Command', 'exit 3') 30
Check 'a program that finishes: true, at once' ($r -eq $true -and ((Get-Date) - $t).TotalSeconds -lt 25) "returned '$r' after $([int]((Get-Date) - $t).TotalSeconds) s"

$pidFile = Join-Path $work 'hang.pid'
$t = Get-Date
$r = Invoke-Timed $self @('-NoProfile', '-Command', "Set-Content -Path '$pidFile' -Value `$PID; Start-Sleep -Seconds 60") 2
$took = ((Get-Date) - $t).TotalSeconds
Check 'a program that hangs: false after the limit' ($r -eq $false -and $took -lt 20) "returned '$r' after $([int]$took) s"
$gone = $true
if (Test-Path $pidFile) {
    $hp = [int](Get-Content $pidFile -Raw).Trim()
    for ($i = 0; $i -lt 30; $i++) { if (-not (Get-Process -Id $hp -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 200 }
    $gone = -not (Get-Process -Id $hp -ErrorAction SilentlyContinue)
    if (-not $gone) { Stop-Process -Id $hp -Force -ErrorAction SilentlyContinue }
}
Check 'the hung program is stopped, not left running' (($gone) -and (Test-Path $pidFile)) 'the program never started or is still running'

Check 'a program that is not there: false, no error' ((Invoke-Timed (Join-Path $work 'no-such-program') @('x') 5) -eq $false) 'did not return false'

$argFile = Join-Path $work 'arg.txt'
$argScript = Join-Path $work 'arg.ps1'
Set-Content -Path $argScript -Value 'Set-Content -Path $args[0] -Value $args[1]'
[void](Invoke-Timed $self @('-NoProfile', '-File', $argScript, $argFile, 'one two') 30)
Check 'an argument with a space arrives as one argument' ((Test-Path $argFile) -and ((Get-Content $argFile -Raw).Trim() -eq 'one two')) 'argument was split or lost'

$t = Get-Date
$r = Invoke-Timed $self @('-NoProfile', '-Command', '1..200000 | ForEach-Object { "line $_" }') 60
Check 'a program with a lot of output does not block on its pipe' ($r -eq $true -and ((Get-Date) - $t).TotalSeconds -lt 55) "returned '$r' after $([int]((Get-Date) - $t).TotalSeconds) s"

# --- 2. the real Stop-Emu against a frozen emulator ----------------------------------------------------
if ($IsWindows) {
    Write-Host 'skip Stop-Emu stand-ins: the stand-in adb is a shell script (this part runs on the hosted Linux runner)'
} else {
    function Get-FunctionText([string]$file, [string]$name) {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errs)
        $f = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
        if (-not $f) { throw "$name not found in $file" }
        return $f.Extent.Text
    }
    Invoke-Expression (Get-FunctionText 'lib/windows/common.ps1' 'Invoke-Quiet')
    Invoke-Expression (Get-FunctionText 'lib/windows/android.ps1' 'Adb')
    Invoke-Expression (Get-FunctionText 'lib/windows/emulator.ps1' 'Stop-Emu')

    # The stand-in adb: hangs 30 s on `emu kill` (the frozen emulator never answers), answers the rest.
    $asked = Join-Path $work 'asked'
    $fakeAdb = Join-Path $work 'adb'
    Set-Content -Path $fakeAdb -Encoding ASCII -Value ("#!/usr/bin/env bash`ncase `"`$*`" in *`"emu kill`"*) : > '$asked'; exec sleep 30 ;; esac`nexit 0`n")
    & chmod +x $fakeAdb
    $script:Adb = $fakeAdb
    $script:Serial = 'emulator-5554'
    $env:EMU_KILL_TIMEOUT = '2'

    # The stand-in emulator process, and the facts Stop-Emu asks about it.
    $emu = Start-Process -FilePath 'sleep' -ArgumentList '300' -PassThru
    function Get-EmuProcess { if ($emu.HasExited) { return $null }; return [pscustomobject]@{ ProcessId = $emu.Id } }
    function Test-EmuRunning { return [bool](Get-EmuProcess) }
    function Test-AndroidOnline { return $false }
    function Step([string]$m) { }
    function Warn([string]$m) { }
    function Log([string]$m) { }
    function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }   # the 45 s wait and the 3 s pause cost nothing here

    $t = Get-Date
    Stop-Emu
    $took = ((Get-Date) - $t).TotalSeconds
    for ($i = 0; $i -lt 20; $i++) { if ($emu.HasExited) { break }; [System.Threading.Thread]::Sleep(100) }
    $alive = -not $emu.HasExited
    if ($alive) { $emu.Kill() }
    Check 'the stand-in adb was asked to emu kill (the test proves something)' (Test-Path $asked) 'adb emu kill was never run'
    Check 'Stop-Emu does not wait for a frozen adb emu kill' ($took -lt 20) "waited $([int]$took) s (limit: a few seconds; the stand-in hangs 30 s)"
    Check 'the frozen emulator process is stopped' (-not $alive) 'still running after Stop-Emu'
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail check(s) failed"; exit 1 }
Write-Host 'all checks passed'
