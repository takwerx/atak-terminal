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
    # A swap an earlier run left half done: put the old copy back before anything else.
    if (-not (Test-Path $app) -and (Test-Path "$app.old")) { Rename-Item "$app.old" (Split-Path $app -Leaf) }

    $ver = ''
    if ($env:TAKWERX_SOURCE) { $url = $env:TAKWERX_SOURCE; $what = 'development source' }
    elseif ($env:TAKWERX_BRANCH) { $url = "https://github.com/$repo/archive/refs/heads/$($env:TAKWERX_BRANCH).zip"; $what = "branch $($env:TAKWERX_BRANCH)" }
    else {
        $ver = ''
        try { $ver = (Invoke-RestMethod -UseBasicParsing -TimeoutSec 15 "https://raw.githubusercontent.com/$repo/main/VERSION").ToString().Trim() } catch {}
        if (-not $ver) { Write-Host 'Could not read the current takwerx version from GitHub' -ForegroundColor Red; return }
        # Never go backwards (ops #1318): a release version is exactly X.Y.Z, and a takwerx older than the
        # one installed, or than the highest that has run here, is not installed. TAKWERX_ALLOW_DOWNGRADE=1
        # goes back on purpose. (lib\windows\guard.ps1 has the same rule; this runs before it is downloaded.)
        if ($ver -notmatch '^\d+\.\d+\.\d+$') {
            $shown = $ver; if ($shown.Length -gt 40) { $shown = $shown.Substring(0, 40) }
            Write-Host "GitHub did not answer with a takwerx version number (got: $shown). Nothing changed" -ForegroundColor Red; return
        }
        if ($env:TAKWERX_ALLOW_DOWNGRADE -ne '1') {
            $haves = @()
            $vf = Join-Path $app 'VERSION'
            if (Test-Path $vf) { $haves += (Get-Content $vf -Raw).Trim() }
            $sf = Join-Path (Join-Path $root 'state') 'highest'
            if (Test-Path $sf) { foreach ($l in Get-Content $sf) { if ($l -match '^takwerx=(.*)$') { $haves += $Matches[1].Trim() } } }
            foreach ($h in $haves) {
                $h = ($h -split '-')[0]
                if ($h -notmatch '^\d+\.\d+\.\d+$') { continue }
                if ([version]$ver -lt [version]$h) {
                    Write-Host "takwerx $ver is older than the takwerx you have ($h), so it was not installed. Nothing changed. To go back on purpose: set TAKWERX_ALLOW_DOWNGRADE=1, then run the install line again" -ForegroundColor Red
                    return
                }
            }
        }
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
    # The tag must hold what its name says, before it replaces the working copy.
    if ($ver) {
        $nv = ''
        $nf = Join-Path $new 'VERSION'
        if (Test-Path $nf) { $nv = (Get-Content $nf -Raw).Trim() }
        if ($nv -ne $ver) { Remove-Item -Recurse -Force $new; Write-Host "The download says it is not takwerx $ver. Nothing changed" -ForegroundColor Red; return }
    }
    # Swap, keeping the old copy until the new one is in place.
    $old = "$app.old"
    if (Test-Path $old) { Remove-Item -Recurse -Force $old }
    if (Test-Path $app) { Rename-Item $app (Split-Path $old -Leaf) }
    try { Rename-Item $new (Split-Path $app -Leaf) }
    catch {
        if (Test-Path $old) { Rename-Item $old (Split-Path $app -Leaf) }
        Write-Host 'Could not put the new takwerx in place; the old one is back' -ForegroundColor Red; return
    }
    if (Test-Path $old) { Remove-Item -Recurse -Force $old -ErrorAction SilentlyContinue }
    # A child PowerShell with the policy relaxed for this one script, so a PC whose policy
    # blocks scripts still runs it; the files came over curl, so they carry no web mark.
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'takwerx.ps1') init
}
