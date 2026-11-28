# takwerx for Windows: host-name lookup inside Android. Pure functions (no PC state, no
# logging), so .github/ci/test_windows_dns.ps1 can load this file alone.
#
# On some Windows PCs the emulator cannot look up any host name (Chrome and ATAK both fail),
# while an address typed as numbers works (ops #1466, atak-terminal #44, Windows 11, 0.2.15).
# The reporter's fix was the emulator's own option: EMU_ARGS=-dns-server 1.1.1.1,8.8.8.8.
# Passing public DNS to every PC would cut off a TAK server that only the PC's own DNS knows
# (a VPN, NetBird, an office name), so takwerx adds it only on a PC where Android reaches
# 1.1.1.1 by number but cannot look up a name, and saves the choice as EMU_DNS=public.
$script:PublicDns = '1.1.1.1,8.8.8.8'

# The text of one `ping -c 1` run inside Android: true when a reply came back.
function Test-PingReply([string]$text) {
    return ("$text" -match '(?m)\b1 (packets )?received\b')
}

# Decides from the probes so far. $tries is one pair per try, @(ping of 1.1.1.1, ping of a
# public name); the name is '' when the number was not reachable (no point asking).
#   'ok'      a name resolved in some try: nothing to do.
#   'broken'  the number answered and the name did not, in the last two tries: fix it.
#   'offline' the number did not answer in the last three tries: no internet (or a LAN-only
#             PC), nothing can be said, nothing is changed.
#   'wait'    anything else (Android's network is often not up in the first seconds): try again.
function Get-DnsVerdict($tries) {
    $tries = @($tries)
    foreach ($t in $tries) { if (Test-PingReply $t[1]) { return 'ok' } }
    $n = $tries.Count
    if ($n -ge 2 -and (Test-PingReply $tries[$n - 1][0]) -and (Test-PingReply $tries[$n - 2][0])) { return 'broken' }
    if ($n -ge 3 -and -not (Test-PingReply $tries[$n - 1][0]) -and -not (Test-PingReply $tries[$n - 2][0]) -and -not (Test-PingReply $tries[$n - 3][0])) { return 'offline' }
    return 'wait'
}

# The emulator arguments for DNS, as an array to append to the argument list. $conf is EMU_DNS
# from the config: 'public' for 1.1.1.1,8.8.8.8, 'off' or '' for none, or a list of addresses
# the user wrote (up to four, comma separated). $emuArgs is EMU_ARGS: a -dns-server the user
# wrote there always wins and nothing is added.
function Get-EmuDnsArgs([string]$conf, [string]$emuArgs) {
    if ("$emuArgs" -match '(^|\s)-dns-server(\s|=|$)') { return @() }
    $c = "$conf".Trim()
    if ($c -eq '' -or $c -eq 'off') { return @() }
    if ($c -eq 'public') { return @('-dns-server', $script:PublicDns) }
    if ($c -match '^(\d{1,3}(\.\d{1,3}){3})(,\d{1,3}(\.\d{1,3}){3}){0,3}$') { return @('-dns-server', $c) }
    return @()
}
