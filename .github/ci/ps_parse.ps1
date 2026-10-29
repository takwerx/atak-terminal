# Parse every tracked .ps1 with the PowerShell parser and require ASCII (ops #329). Nothing is run.
#   pwsh -File .github/ci/ps_parse.ps1
$ErrorActionPreference = 'Stop'
Set-Location (git rev-parse --show-toplevel)
$files = @(git ls-files '*.ps1')
$bad = 0
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $tokens = $null; $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $f).Path, [ref]$tokens, [ref]$errs) | Out-Null
    foreach ($e in $errs) {
        $bad++
        Write-Host "::error file=$f,line=$($e.Extent.StartLineNumber)::$($e.Message)"
    }
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $f).Path)) {
        $n++
        if ($line -match '[^\x00-\x7F]') {
            $bad++
            Write-Host "::error file=$f,line=${n}::non-ASCII character (Windows PowerShell 5.1 needs ASCII-only scripts)"
        }
    }
}
Write-Host "parsed $($files.Count) PowerShell file(s), $bad problem(s)"
if ($bad) { exit 1 }
