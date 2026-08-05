$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\diagnose-zerotier-path.ps1"

function Assert-Equal {
    param(
        [object] $Expected,
        [object] $Actual,
        [string] $Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message (expected '$Expected', got '$Actual')"
    }
}

$pass = Get-Diagnosis -DidActiveProbe $true -PlanetFresh $true -MoonFresh $false `
    -AnyOnline $true -UdpDnsWorks $true -AnyPublicFallbackWorks $true
Assert-Equal 0 $pass.Code 'fresh Planet traffic should pass'
Assert-Equal 'PASS' $pass.Label 'fresh Planet label'

$suspected = Get-Diagnosis -DidActiveProbe $true -PlanetFresh $false -MoonFresh $true `
    -AnyOnline $true -UdpDnsWorks $true -AnyPublicFallbackWorks $true
Assert-Equal 2 $suspected.Code 'fresh Moon without Planet should be suspicious'
Assert-Equal 'SUSPECTED_PLANET_FILTER' $suspected.Label 'Planet filtering label'

$passive = Get-Diagnosis -DidActiveProbe $false -PlanetFresh $false -MoonFresh $true `
    -AnyOnline $true -UdpDnsWorks $true -AnyPublicFallbackWorks $true
Assert-Equal 3 $passive.Code 'passive observation must not claim filtering'
Assert-Equal 'INCONCLUSIVE' $passive.Label 'passive observation label'

$generalUdp = Get-Diagnosis -DidActiveProbe $true -PlanetFresh $false -MoonFresh $false `
    -AnyOnline $false -UdpDnsWorks $true -AnyPublicFallbackWorks $true
Assert-Equal 3 $generalUdp.Code 'no ZeroTier root should be inconclusive'
Assert-Equal 'ZEROTIER_UDP_UNAVAILABLE' $generalUdp.Label 'general ZeroTier UDP label'

$endpoint = Split-TcpEndpoint -Endpoint '47.57.180.218:22'
Assert-Equal '47.57.180.218' $endpoint.HostName 'TCP host parsing'
Assert-Equal 22 $endpoint.Port 'TCP port parsing'

$script:fixtureReceiveTime = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 1000
function Invoke-ZeroTierJson {
    param(
        [string] $CliPath,
        [string] $Command
    )

    if ($Command -eq 'info') {
        return [pscustomobject]@{ address = 'b4feedc625'; online = $true; version = '1.14.2' }
    }
    return @([pscustomobject]@{
        address = '778cde7190'
        latency = 20
        role = 'PLANET'
        tunneled = $false
        paths = @([pscustomobject]@{
            active = $true
            address = '103.195.103.66/9993'
            expired = $false
            lastReceive = $script:fixtureReceiveTime
            preferred = $true
        })
    })
}

$freshSnapshot = Get-ZeroTierSnapshot -CliPath 'fixture' -FreshWindowSeconds 60 `
    -ReceiveNotBeforeMs ($script:fixtureReceiveTime - 1)
Assert-Equal $true $freshSnapshot.Peers[0].Fresh 'post-probe receive should be fresh'

$preProbeSnapshot = Get-ZeroTierSnapshot -CliPath 'fixture' -FreshWindowSeconds 60 `
    -ReceiveNotBeforeMs ($script:fixtureReceiveTime + 1)
Assert-Equal $false $preProbeSnapshot.Peers[0].Fresh 'pre-probe receive must not count after restart'

$launcherPath = Join-Path $PSScriptRoot '..\docs\run.ps1'
$launcherErrors = $null
$launcherTokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $launcherPath,
    [ref]$launcherTokens,
    [ref]$launcherErrors
)
Assert-Equal 0 $launcherErrors.Count 'hosted launcher PowerShell syntax'
$launcherSource = Get-Content -Raw $launcherPath
if ($launcherSource -notmatch [regex]::Escape('/releases/latest/download/diagnose-zerotier-path.ps1')) {
    throw 'hosted launcher must download the diagnostic from the latest release'
}

Write-Host 'all diagnostic tests passed'
