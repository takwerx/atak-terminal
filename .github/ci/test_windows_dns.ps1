# Proof test for the Windows DNS repair (ops #1466, atak-terminal #44). Loads lib/windows/dns.ps1
# alone and runs its pure functions on the ping texts Android prints. Nothing is run on a PC.
# On the base branch the file does not exist, so the dot-source below fails: red without the fix.
#   pwsh -File .github/ci/test_windows_dns.ps1
$ErrorActionPreference = 'Stop'
Set-Location (git rev-parse --show-toplevel)
. ./lib/windows/dns.ps1
$fail = 0
function Check([string]$name, $got, $want) {
    if ("$got" -ceq "$want") { Write-Host "ok   $name" } else { Write-Host "::error::FAIL $name : got '$got', want '$want'"; $script:fail++ }
}

# What Android's ping prints (toybox), for a reply, a lost packet, a dead network and a failed lookup.
$reply = "PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.`n64 bytes from 1.1.1.1: icmp_seq=1 ttl=255 time=13.1 ms`n`n--- 1.1.1.1 ping statistics ---`n1 packets transmitted, 1 received, 0% packet loss, time 0ms"
$lost  = "PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.`n`n--- 1.1.1.1 ping statistics ---`n1 packets transmitted, 0 received, 100% packet loss, time 0ms"
$noNet = 'connect: Network is unreachable'
$noName = 'ping: unknown host one.one.one.one'
$many  = "--- x ping statistics ---`n11 packets transmitted, 11 received, 0% packet loss"

Check 'a reply is a reply'                    (Test-PingReply $reply) 'True'
Check 'a lost packet is not'                  (Test-PingReply $lost) 'False'
Check 'network unreachable is not'            (Test-PingReply $noNet) 'False'
Check 'unknown host is not'                   (Test-PingReply $noName) 'False'
Check 'empty output is not'                   (Test-PingReply '') 'False'
Check '11 received is not one received'      (Test-PingReply $many) 'False'

# The reporter's PC: the number answers, the name never does.
$broken = @(, @($reply, $noName))
Check 'reporter PC, first try: wait for a second'  (Get-DnsVerdict $broken) 'wait'
Check 'reporter PC, two tries: broken'             (Get-DnsVerdict @(@($reply, $noName), @($reply, $noName))) 'broken'
Check 'network came up late: wait, not broken'     (Get-DnsVerdict @(@($noNet, ''), @($reply, $noName))) 'wait'
Check 'network came up late, then two bad tries'   (Get-DnsVerdict @(@($noNet, ''), @($reply, $noName), @($reply, $noName))) 'broken'
Check 'a working PC: ok at once'                   (Get-DnsVerdict @(, @($reply, $reply))) 'ok'
Check 'names work after a slow start: ok'          (Get-DnsVerdict @(@($reply, $noName), @($reply, $reply))) 'ok'
Check 'no internet, 3 tries: offline'              (Get-DnsVerdict @(@($noNet, ''), @($lost, ''), @($noNet, ''))) 'offline'
Check 'no internet, 2 tries: wait'                 (Get-DnsVerdict @(@($noNet, ''), @($noNet, ''))) 'wait'
Check 'no tries yet: wait'                         (Get-DnsVerdict @()) 'wait'

# The argument for the emulator.
Check 'nothing set: no argument'                   (@(Get-EmuDnsArgs '' '').Count) '0'
Check 'off: no argument'                           (@(Get-EmuDnsArgs 'off' '').Count) '0'
Check 'public: -dns-server 1.1.1.1,8.8.8.8'        ((Get-EmuDnsArgs 'public' '') -join ' ') '-dns-server 1.1.1.1,8.8.8.8'
Check 'own servers are passed on'                  ((Get-EmuDnsArgs '10.0.0.1,10.0.0.2' '') -join ' ') '-dns-server 10.0.0.1,10.0.0.2'
Check 'one own server'                             ((Get-EmuDnsArgs '192.168.1.1' '') -join ' ') '-dns-server 192.168.1.1'
Check 'five servers are refused'                   (@(Get-EmuDnsArgs '1.1.1.1,1.0.0.1,8.8.8.8,8.8.4.4,9.9.9.9' '').Count) '0'
Check 'words other than public are refused'        (@(Get-EmuDnsArgs 'google; calc' '').Count) '0'
Check 'user -dns-server in EMU_ARGS wins'          (@(Get-EmuDnsArgs 'public' '-dns-server 9.9.9.9').Count) '0'
Check 'user -dns-server after other args wins'     (@(Get-EmuDnsArgs 'public' '-grpc 8554 -dns-server 1.1.1.1,8.8.8.8').Count) '0'
Check 'other EMU_ARGS do not stop public DNS'      ((Get-EmuDnsArgs 'public' '-grpc 8554') -join ' ') '-dns-server 1.1.1.1,8.8.8.8'

# The engine must call it: dns.ps1 loaded, the argument added, the repair run after Android is up.
$engine = Get-Content ./lib/windows/emulator.ps1 -Raw
$main = Get-Content ./takwerx.ps1 -Raw
Check 'takwerx.ps1 loads dns.ps1'                  ($main -match "lib\\windows\\dns\.ps1") 'True'
Check 'Start-Emu adds the DNS argument'            ($engine -match 'Get-EmuDnsArgs \$EmuDns \$EmuArgs') 'True'
Check 'Invoke-EmuUp runs the repair'               ($engine -match 'if \(Repair-AndroidDns\)') 'True'

if ($fail) { Write-Host "$fail check(s) failed"; exit 1 }
Write-Host 'all checks passed'
