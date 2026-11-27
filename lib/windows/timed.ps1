# takwerx for Windows: run a program with a time limit (ops #1425). No takwerx state and no
# network, so .github/ci/test_windows_timed.ps1 can run it alone, as test_windows_guard.ps1 does
# guard.ps1. The bash engine's twin is with_timeout in lib/common.sh.
# Windows PowerShell 5.1 syntax only, and ASCII only.

# Invoke-Timed EXE ARGS SECONDS: runs the program hidden, with its output thrown away, and waits at
# most SECONDS for it. Returns $true when it finished by itself (any exit code), $false when it
# had to be stopped, was not found, or could not start. Invoke-Quiet (common.ps1) has no time
# limit: `adb emu kill` to a frozen emulator never answers, and update and restart waited for ever.
function Invoke-Timed([string]$Exe, [string[]]$ArgList, [int]$Seconds) {
    $line = ''
    if ($ArgList) {
        $line = ($ArgList | ForEach-Object {
            if ($_ -notmatch '[\s"]' -and $_.Length -gt 0) { $_ } else { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
        }) -join ' '
    }
    $p = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $line
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        # Read in the background so a program with a lot of output cannot block on a full pipe.
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if ($p.WaitForExit($Seconds * 1000)) { return $true }
        try { $p.Kill() } catch { }
        return $false
    } catch {
        return $false
    } finally {
        if ($p) { $p.Dispose() }
    }
}
