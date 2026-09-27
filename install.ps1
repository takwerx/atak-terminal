# takwerx for Windows, the one-line install, in PowerShell:
#   irm https://raw.githubusercontent.com/takwerx/atak-terminal/main/install.ps1 | iex
# Downloads takwerx into %LOCALAPPDATA%\takwerx\app and runs `takwerx init`, which does
# everything else. The newest release: VERSION on main names it, the tag v<VERSION> holds
# it. TAKWERX_BRANCH takes a branch, TAKWERX_SOURCE any zip URL (development).
# No administrator needed, unless Windows Hypervisor Platform is off; init says so.

& {
    # Inside the block, so the session that ran `irm | iex` keeps its own setting.
    $ErrorActionPreference = 'Stop'
    $repo = if ($env:TAKWERX_REPO) { $env:TAKWERX_REPO } else { 'takwerx/atak-terminal' }
    $root = if ($env:TAKWERX_ROOT) { $env:TAKWERX_ROOT } else { Join-Path $env:LOCALAPPDATA 'takwerx' }
    $app = Join-Path $root 'app'
    $cache = Join-Path $root 'cache'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null

    if ($env:TAKWERX_SOURCE) { $url = $env:TAKWERX_SOURCE; $what = 'development source' }
    elseif ($env:TAKWERX_BRANCH) { $url = "https://github.com/$repo/archive/refs/heads/$($env:TAKWERX_BRANCH).zip"; $what = "branch $($env:TAKWERX_BRANCH)" }
    else {
        $ver = ''
        try { $ver = (Invoke-RestMethod -UseBasicParsing -TimeoutSec 15 "https://raw.githubusercontent.com/$repo/main/VERSION").ToString().Trim() } catch {}
        if (-not $ver) { Write-Host 'Could not read the current takwerx version from GitHub' -ForegroundColor Red; return }
        $url = "https://github.com/$repo/archive/refs/tags/v$ver.zip"; $what = "release $ver"
    }
    Write-Host "==> Downloading takwerx ($repo, $what)"
    $zip = Join-Path $cache 'app.zip'
    Remove-Item $zip -ErrorAction SilentlyContinue
    & curl.exe -fsSL -o $zip $url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zip)) { Write-Host "Could not download takwerx ($what)" -ForegroundColor Red; return }
    $new = "$app.new"
    if (Test-Path $new) { Remove-Item -Recurse -Force $new }
    New-Item -ItemType Directory -Force -Path $new | Out-Null
    & tar.exe -xf $zip -C $new --strip-components=1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $new 'takwerx.ps1'))) {
        Write-Host "That takwerx ($what) has no Windows engine yet; Windows ships in a coming release" -ForegroundColor Red
        return
    }
    if (Test-Path $app) { Remove-Item -Recurse -Force $app }
    Rename-Item $new (Split-Path $app -Leaf)
    # A child PowerShell with the policy relaxed for this one script, so a PC whose policy
    # blocks scripts still runs it; the files came over curl, so they carry no web mark.
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'takwerx.ps1') init
}
